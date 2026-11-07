//! compact.zig: keeps the conversation inside the context window. Masking
//! is the default: "The Complexity Trap" (JetBrains/TUM, 2025) found it
//! halves cost and matches model-written summaries. Masking happens in one
//! batch when the trigger is crossed, so the provider's prompt cache is
//! invalidated rarely.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const proc = @import("../base/proc.zig");
const history = @import("../io/history.zig");
const History = history.History;
const Message = history.Message;
const spec_mod = @import("spec.zig");
const tool_exec = @import("tool_exec.zig");
const llm = @import("../model/llm.zig");
const agent_mod = @import("../agent/agent.zig");
const Agent = agent_mod.Agent;

const masked_prefix = "[output cleared";
const default_summary_prompt =
    "You are compacting an agent's working memory. Summarize the work below " ++
    "so the agent can continue without it: the goal, what was tried and the " ++
    "results (keep the numbers), the current state of files, open problems, " ++
    "and the next steps. Be specific and brief; keep exact paths, commands " ++
    "and values.";

/// The estimate scaled by what the provider reported for the last call.
pub fn currentTokens(a: *const Agent) i64 {
    const estimate = a.messages.estimateTokens();
    if (a.estimate_at_call > 0 and a.tokens_at_call > 0) {
        return @intCast(@divTrunc(@as(i128, estimate) * a.tokens_at_call, a.estimate_at_call));
    }
    return estimate;
}

/// The token count that triggers compaction.
fn limit(a: *const Agent) i64 {
    const window = json.num(a.spec.root, "context_window", 128000);
    const tokens = window * json.num(a.spec.root, "compaction.trigger", 0.7);
    return if (tokens < 9e18) @intFromFloat(@max(tokens, 0)) else std.math.maxInt(i64);
}

/// A tool call in an assistant message, and the message that owns it.
const CallRef = struct {
    message: *Message,
    call: *json.Value,
};

/// Finds the assistant tool call with `id`.
fn findCall(messages: *const History, id: []const u8) ?CallRef {
    for (messages.slice()) |m| {
        const calls = json.getPtr(&m.value, "tool_calls") orelse continue;
        if (calls.* != .array) continue;
        for (calls.array.items) |*call| {
            if (std.mem.eql(u8, json.strOr(call.*, "id", ""), id)) return .{ .message = m, .call = call };
        }
    }
    return null;
}

/// Replaces every tool output except the newest `keep` with a pointer to
/// its file. Returns how many were masked.
fn mask(a: *Agent) Allocator.Error!usize {
    const root = a.spec.root;
    const keep = json.int(root, "compaction.keep", 5);
    const clear_inputs = json.boolean(root, "compaction.clear_inputs", false);
    const exclude = json.items(json.get(root, "compaction.exclude_tools"));
    var total: i64 = 0;
    for (a.messages.slice()) |m| total += @intFromBool(std.mem.eql(u8, m.role(), "tool"));
    var seen: i64 = 0;
    var masked: usize = 0;
    for (a.messages.slice()) |m| {
        if (seen >= total - keep) break;
        if (!std.mem.eql(u8, m.role(), "tool")) continue;
        seen += 1;
        const content = json.strOr(m.value, "content", "");
        if (std.mem.startsWith(u8, content, masked_prefix)) continue;
        const ref = findCall(&a.messages, json.strOr(m.value, "tool_call_id", ""));
        const tool_name = if (ref) |r| json.strOr(r.call.*, "function.name", "") else "";
        const excluded = for (exclude) |item| {
            if (item == .string and std.mem.eql(u8, item.string, tool_name)) break true;
        } else false;
        if (excluded) continue;
        const note = try m.allocator().print("{s} to save context: {d} bytes; the full output is in {s}]", .{
            masked_prefix, content.len, json.strOr(m.value, "_out", "the session folder"),
        });
        try json.put(m.allocator(), &m.value, "content", .{ .string = note });
        if (clear_inputs) {
            if (ref) |r| {
                if (json.getPtr(r.call, "function")) |function| {
                    if (function.* == .object) try json.put(r.message.allocator(), function, "arguments", json.string("{}"));
                }
            }
        }
        masked += 1;
    }
    return masked;
}

/// The index where the last `keep` turns start (an assistant message).
fn cutIndex(messages: *const History, keep: i64) ?usize {
    var count: i64 = 0;
    for (messages.slice()) |m| count += @intFromBool(std.mem.eql(u8, m.role(), "assistant"));
    var cut: ?usize = null;
    for (messages.slice(), 0..) |m, i| {
        if (!std.mem.eql(u8, m.role(), "assistant")) continue;
        if (count == keep) cut = i;
        count -= 1;
    }
    return cut;
}

/// Renders messages [from, to) as plain text for the summarizer.
fn plainHistory(gpa: Allocator, messages: *const History, from: usize, to: usize) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (messages.slice()[from..to]) |m| {
        const content = try util.truncate(gpa, json.strOr(m.value, "content", ""), 2000);
        defer gpa.free(content);
        try out.print(gpa, "\n## {s}\n{s}\n", .{ json.strOr(m.value, "role", "?"), content });
        for (json.items(json.field(m.value, "tool_calls"))) |call| {
            const args = try util.truncate(gpa, json.strOr(call, "function.arguments", ""), 300);
            defer gpa.free(args);
            try out.print(gpa, "-> {s}({s})\n", .{ json.strOr(call, "function.name", "?"), args });
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Summarizes everything between the first user message and the last
/// `keep` turns with one model call. Returns whether it changed the history.
fn summarize(a: *Agent) !?bool {
    const gpa = a.ctx.gpa;
    const keep = @max(json.int(a.spec.root, "compaction.keep", 5), 1);
    const cut = cutIndex(&a.messages, keep) orelse return false;
    if (cut <= 2) return false;
    const prompt = try spec_mod.text(a.ctx, gpa, a.spec.doc(), json.get(a.spec.root, "compaction.prompt"), null);
    defer if (prompt) |p| gpa.free(p);
    const plain = try plainHistory(gpa, &a.messages, 1, cut);
    defer gpa.free(plain);
    var request: History = .init(gpa);
    defer request.deinit();
    try request.append(try Message.text(gpa, "system", prompt orelse default_summary_prompt));
    try request.append(try Message.text(gpa, "user", plain));
    var why: std.ArrayList(u8) = .empty;
    defer why.deinit(gpa);
    const result = try llm.chat(a, &request, null, false, &why);
    const reply = switch (result) {
        .ok => |r| r,
        else => {
            try a.note("Summarizing the context failed: {s}", .{why.items});
            return null;
        },
    };
    defer reply.message.destroy(gpa);
    const s = &a.session.?;
    s.tokens_in += reply.tokens_in;
    s.tokens_out += reply.tokens_out;
    s.cost += reply.cost;
    const summary = try std.mem.concat(gpa, u8, &.{
        "[Summary of the work so far, written before the context was compacted]\n",
        json.strOr(reply.message.value, "content", ""),
    });
    defer gpa.free(summary);
    const note = try Message.text(gpa, "user", summary);
    // Keep the system prompt and the task, then the summary, then the last
    // `keep` turns; free the rest.
    const old = a.messages.slice();
    var fresh: std.ArrayList(*Message) = .empty;
    defer fresh.deinit(gpa);
    fresh.ensureTotalCapacity(gpa, 3 + old.len - cut) catch |err| {
        note.destroy(gpa);
        return err;
    };
    fresh.appendSliceAssumeCapacity(old[0..2]);
    fresh.appendAssumeCapacity(note);
    fresh.appendSliceAssumeCapacity(old[cut..]);
    for (old[2..cut]) |m| m.destroy(gpa);
    a.messages.items.clearRetainingCapacity();
    a.messages.items.appendSliceAssumeCapacity(fresh.items);
    return true;
}

/// Starts over from the system prompt and the first message (Ralph-style),
/// then `message` when there is one.
fn restart(a: *Agent, message: ?[]const u8) Allocator.Error!void {
    const gpa = a.ctx.gpa;
    const system = try agent_mod.systemPrompt(a);
    defer gpa.free(system);
    const first = try agent_mod.firstMessage(a, a.prompt orelse "");
    defer gpa.free(first);
    a.messages.clear();
    try a.messages.append(try Message.text(gpa, "system", system));
    try a.messages.append(try Message.text(gpa, "user", first));
    if (message) |m| if (m.len > 0) try a.messages.append(try Message.text(gpa, "user", m));
}

/// Runs an external compactor: {"messages", "usage", "context_window"} in,
/// {"messages": [...]} out. Returns true when it changed the history, false
/// when it returned it unchanged, and null when it failed.
fn external(a: *Agent, strategy: []const u8) Allocator.Error!?bool {
    const gpa = a.ctx.gpa;
    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    const w = &input.writer;
    (blk: {
        w.writeAll("{\"messages\":") catch |e| break :blk e;
        a.messages.write(w, false) catch |e| break :blk e;
        w.print(",\"usage\":{{\"prompt_tokens\":{d}}},\"context_window\":", .{currentTokens(a)}) catch |e| break :blk e;
        json.write(w, json.number(json.num(a.spec.root, "context_window", 128000)), .compact) catch |e| break :blk e;
        w.writeByte('}') catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    const named = json.str(json.field(a.spec.root, "compactors"), strategy);
    const path = try util.pathJoin(gpa, a.spec.dir, named orelse strategy);
    defer gpa.free(path);
    var env = try tool_exec.environ(a, null, a.depth); // the same ARX_* variables tools and hooks get
    defer env.deinit();
    var out: proc.Collector = .init(gpa);
    defer out.deinit();
    const r = proc.run(a.ctx, .{ .argv = &.{path}, .stdin = input.written(), .timeout = 120, .environ = &env, .stdout = out.sink() });
    if (!r.ok()) return null;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const result = try json.parseObject(arena.allocator(), out.output()) orelse return null;
    const items = json.items(json.field(result, "messages"));
    if (items.len == 0) return null;
    for (items) |m| if (json.str(m, "role") == null) return null;
    const current = a.messages.slice();
    const same = items.len == current.len and for (items, current) |x, y| {
        if (!json.equal(x, y.value)) break false;
    } else true;
    if (same) return false;
    var fresh: std.ArrayList(*Message) = .empty;
    defer fresh.deinit(gpa);
    errdefer for (fresh.items) |m| m.destroy(gpa);
    for (items) |m| {
        const copy = try Message.fromValue(gpa, m);
        fresh.append(gpa, copy) catch |err| {
            copy.destroy(gpa);
            return err;
        };
    }
    try a.messages.replace(fresh.items);
    fresh.clearRetainingCapacity();
    return true;
}

/// Compacts with `strategy`: mask (clear old tool outputs, the default),
/// summarize (one model call), hybrid (mask, then summarize if still over),
/// restart (fresh context; `message` is added after it), a name from the
/// spec's `compactors:` (plugins add theirs there), or a path to an
/// executable that rewrites {"messages": [...]}. Records a transcript reset
/// and a compact event. Returns false when nothing could be compacted.
pub fn compact(a: *Agent, strategy: []const u8, message: ?[]const u8) !bool {
    const before = currentTokens(a);
    var changed: bool = undefined;
    if (std.mem.eql(u8, strategy, "mask")) {
        changed = try mask(a) > 0;
    } else if (std.mem.eql(u8, strategy, "summarize")) {
        changed = (try summarize(a)) orelse false;
    } else if (std.mem.eql(u8, strategy, "hybrid")) {
        changed = try mask(a) > 0;
        if (currentTokens(a) > limit(a) and ((try summarize(a)) orelse false)) changed = true;
    } else if (std.mem.eql(u8, strategy, "restart")) {
        try restart(a, message);
        changed = true;
    } else if (try external(a, strategy)) |result| {
        changed = result;
    } else {
        try a.note("The compactor {s} failed; masking was used instead.", .{strategy});
        changed = try mask(a) > 0;
    }
    if (!changed) return false;
    try a.recordReset();
    var event = try a.events.begin("compact");
    defer event.deinit();
    try event.str("strategy", strategy);
    try event.int("tokens_before", before);
    try event.int("tokens_after", currentTokens(a));
    try a.events.send(&event);
    return true;
}

/// Compacts with the spec's strategy when the prompt is over
/// compaction.trigger x context_window.
pub fn maybeCompact(a: *Agent) !void {
    if (currentTokens(a) <= limit(a)) return;
    _ = try compact(a, json.strOr(a.spec.root, "compaction.strategy", "mask"), null);
}
