//! loop.zig: the turn loop. Before each model call it hot-reloads the
//! harness if any of its files changed, reads the inbox, hands harness
//! notes to the agent and compacts the context. After the call it runs the
//! tool calls through the before_tool and after_tool hooks, and asks the
//! stop hook whether to go on when the agent stops calling tools.

const std = @import("std");
const Allocator = std.mem.Allocator;

const sys = @import("../base/sys.zig");
const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const render = @import("../io/render.zig");
const Event = @import("../io/events.zig").Event;
const Message = @import("../io/history.zig").Message;
const spec_mod = @import("../harness/spec.zig");
const signature = @import("../harness/signature.zig");
const tools = @import("../harness/tools.zig");
const tool_exec = @import("../harness/tool_exec.zig");
const hooks = @import("../harness/hooks.zig");
const compact = @import("../harness/compact.zig");
const llm = @import("../model/llm.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const Exit = util.Exit;

/// Returns Exit.cap when a cap or limit is reached, else null.
fn checkCaps(a: *Agent) Allocator.Error!?Exit {
    const s = &a.session.?;
    var max_turns = json.int(a.spec.root, "limits.max_turns", 200);
    if (a.caps.turns >= 0 and a.caps.turns < max_turns) max_turns = a.caps.turns;
    const tokens: f64 = @floatFromInt(s.tokens_in + s.tokens_out);
    const which: []const u8 = if (s.turns >= max_turns)
        "turns"
    else if (a.caps.tokens >= 0 and tokens >= a.caps.tokens)
        "tokens"
    else if (a.caps.usd >= 0 and s.cost >= a.caps.usd)
        "usd"
    else if (a.caps.wall >= 0 and util.now(a.ctx.io) - a.start >= a.caps.wall)
        "wall"
    else
        return null;
    var event = try a.events.begin("note");
    defer event.deinit();
    try event.put("text", .{ .string = try event.arena.allocator().print("stopped: the {s} limit was reached", .{which}) });
    try a.events.send(&event);
    return .cap;
}

/// Reloads the spec, tools and prompt when any harness file changed. A bad
/// edit keeps the previous version and tells the agent why.
fn maybeReload(a: *Agent) Allocator.Error!void {
    const ctx = a.ctx;
    const gpa = ctx.gpa;
    const sig = try signature.compute(ctx, &a.spec);
    if (sig == a.spec.sig) return;
    const start = util.now(ctx.io);
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(gpa);
    var event = try a.events.begin("harness.reload");
    defer event.deinit();
    if (try spec_mod.load(ctx, a.spec_path, a.sets, &err)) |fresh| {
        a.spec.deinit(gpa);
        a.spec = fresh;
        try tools.build(a);
        const system = try agent_mod.systemPrompt(a);
        defer gpa.free(system);
        if (a.messages.len() > 0) {
            const first = a.messages.slice()[0];
            if (!std.mem.eql(u8, json.strOr(first.value, "content", ""), system)) {
                try json.putString(first.allocator(), &first.value, "content", system);
                try a.recordReset();
            }
        }
        try event.boolean("ok", true);
        try event.int("tools", @intCast(a.tools.items.len));
    } else {
        a.spec.sig = sig; // report this version once, not every turn
        try a.note("Your harness edit was rejected; the previous version is still in use:\n{s}", .{err.items});
        try event.boolean("ok", false);
        try event.truncated("errors", err.items, 2000);
    }
    try event.num("ms", (util.now(ctx.io) - start) * 1000);
    try a.events.send(&event);
}

/// Applies `arx ctl` commands: notes for the agent, and stop.
fn readInbox(a: *Agent) Allocator.Error!void {
    var arena: std.heap.ArenaAllocator = .init(a.ctx.gpa);
    defer arena.deinit();
    for (try a.session.?.readInbox(a.ctx, arena.allocator())) |command| {
        const cmd = json.strOr(command, "cmd", "");
        if (std.mem.eql(u8, cmd, "stop")) {
            a.stop_requested = true;
        } else if (std.mem.eql(u8, cmd, "note")) {
            try a.note("Note from your operator: {s}", .{json.strOr(command, "text", "")});
        }
    }
}

/// Gives queued harness notes to the agent as one user message.
fn flushNotes(a: *Agent) Allocator.Error!void {
    if (a.notes.items.len == 0) return;
    const gpa = a.ctx.gpa;
    const text = try std.mem.concat(gpa, u8, &.{ "[harness]\n", a.notes.items });
    defer gpa.free(text);
    try a.addMessage("user", text);
    var event = try a.events.begin("note");
    defer event.deinit();
    try event.truncated("text", a.notes.items, 1000);
    try a.events.send(&event);
    a.notes.clearRetainingCapacity();
}

/// A one-line summary of a tool call for the terminal view: the command,
/// path or task when there is one, else the raw arguments.
fn preview(arena: Allocator, args: []const u8) Allocator.Error![]u8 {
    const parsed = try json.parseObject(arena, args);
    const s = json.str(parsed, "command") orelse json.str(parsed, "path") orelse json.str(parsed, "task") orelse args;
    const text = try util.truncate(arena, s, 120);
    std.mem.replaceScalar(u8, text, '\n', ' ');
    return text;
}

/// Runs the before_tool hook. Returns a denial message, or null to go on.
fn beforeTool(a: *Agent, arena: Allocator, name: []const u8, args: []const u8) Allocator.Error!?[]const u8 {
    var tool = json.object();
    try json.putString(arena, &tool, "name", name);
    const parsed = json.parse(arena, args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => json.Value{ .string = try arena.dupe(u8, args) },
    };
    try json.put(arena, &tool, "args", parsed);
    var input = json.object();
    try json.put(arena, &input, "tool", tool);
    const outcome = try hooks.run(a, arena, "before_tool", input);
    if (outcome.status == .failed) return "denied: the before_tool hook failed (fail: closed)";
    if (std.mem.eql(u8, json.strOr(outcome.output, "decision", ""), "deny")) {
        return try arena.print("denied by the before_tool hook: {s}", .{json.strOr(outcome.output, "reason", "no reason given")});
    }
    return null;
}

/// Runs the after_tool hook. Returns a note to append, or null.
fn afterTool(a: *Agent, arena: Allocator, name: []const u8, result: []const u8, is_error: bool) Allocator.Error!?[]const u8 {
    var tool = json.object();
    try json.putString(arena, &tool, "name", name);
    var res = json.object();
    try json.put(arena, &res, "text", .{ .string = try util.truncate(arena, result, 8192) });
    try json.put(arena, &res, "error", .{ .bool = is_error });
    var input = json.object();
    try json.put(arena, &input, "tool", tool);
    try json.put(arena, &input, "result", res);
    const outcome = try hooks.run(a, arena, "after_tool", input);
    return json.str(outcome.output, "note");
}

/// Runs one tool call with its hooks and sends `end` as soon as the tool
/// finishes, before the after_tool hook. Returns the result (caller owns it).
fn runOne(a: *Agent, id: []const u8, name: []const u8, args: []const u8, out_path: *?[]u8, end: *Event) ![]u8 {
    const gpa = a.ctx.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = arena.allocator();
    {
        var start = try a.events.begin("tool.start");
        defer start.deinit();
        try start.str("id", id);
        try start.str("name", name);
        try start.str("preview", try preview(t, args));
        try a.events.send(&start);
    }
    var is_error = true;
    var text: []u8 = undefined;
    if (try beforeTool(a, t, name, args)) |denial| {
        text = try gpa.dupe(u8, denial);
    } else {
        const outcome = try tool_exec.call(a, name, args, end);
        text = outcome.text;
        is_error = outcome.is_error;
        out_path.* = outcome.output_path;
    }
    errdefer gpa.free(text);
    try end.boolean("error", is_error);
    const first_line = text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len];
    try end.truncated("preview", first_line, 100);
    try a.events.send(end);
    if (try afterTool(a, t, name, text, is_error)) |note| {
        const joined = try std.mem.concat(gpa, u8, &.{ text, "\n[after_tool] ", note });
        gpa.free(text);
        text = joined;
    }
    return text;
}

/// Runs every tool call of an assistant message and records the results.
/// Calls after a Ctrl-C still get a result, so the history stays valid.
fn runToolCalls(a: *Agent, calls: []const json.Value) !void {
    const gpa = a.ctx.gpa;
    for (calls) |call| {
        const id = json.strOr(call, "id", "");
        const name = json.strOr(call, "function.name", "");
        const args = json.strOr(call, "function.arguments", "{}");
        var out_path: ?[]u8 = null;
        defer if (out_path) |p| gpa.free(p);
        var end = try a.events.begin("tool.end");
        defer end.deinit();
        try end.str("id", id);
        try end.str("name", name);
        const text = if (sys.isInterrupted()) blk: {
            try a.events.send(&end);
            break :blk try gpa.dupe(u8, "[interrupted before this tool ran]");
        } else try runOne(a, id, name, args, &out_path, &end);
        defer gpa.free(text);
        const m = try Message.create(gpa);
        {
            errdefer m.destroy(gpa);
            const ma = m.allocator();
            try json.putString(ma, &m.value, "role", "tool");
            try json.putString(ma, &m.value, "tool_call_id", id);
            try json.putString(ma, &m.value, "content", text);
            if (out_path) |p| try json.putString(ma, &m.value, "_out", p);
        }
        try a.messages.append(m);
        try a.record(m);
    }
}

/// Asks the stop hook whether to go on. Returns true to keep going.
fn stopHook(a: *Agent) !bool {
    var arena: std.heap.ArenaAllocator = .init(a.ctx.gpa);
    defer arena.deinit();
    const t = arena.allocator();
    var input = json.object();
    try json.put(t, &input, "last_message", .{ .string = try util.truncate(t, a.final_output orelse "", 8192) });
    const outcome = try hooks.run(a, t, "stop", input);
    const decision = json.strOr(outcome.output, "decision", "");
    if (std.mem.eql(u8, decision, "continue")) {
        try a.addMessage("user", json.strOr(outcome.output, "message", "Continue."));
        return true;
    }
    if (std.mem.eql(u8, decision, "restart")) {
        _ = try compact.compact(a, "restart", json.str(outcome.output, "message"));
        return true;
    }
    return false;
}

/// Calls the model; if the prompt is too long, compacts once and retries.
/// Returns the reply, or the exit code to stop with.
fn callModel(a: *Agent) !union(enum) { reply: llm.Reply, exit: Exit } {
    const gpa = a.ctx.gpa;
    const tools_json = try a.tools.toJson(gpa);
    defer gpa.free(tools_json);
    var why: std.ArrayList(u8) = .empty;
    defer why.deinit(gpa);
    a.estimate_at_call = a.messages.estimateTokens();
    var result = try llm.chat(a, &a.messages, tools_json, true, &why);
    if (result == .context) {
        const s = json.strOr(a.spec.root, "compaction.strategy", "mask");
        if (try compact.compact(a, if (std.mem.eql(u8, s, "mask")) "hybrid" else s, null)) {
            why.clearRetainingCapacity();
            a.estimate_at_call = a.messages.estimateTokens();
            result = try llm.chat(a, &a.messages, tools_json, true, &why);
        }
    }
    switch (result) {
        .ok => |reply| return .{ .reply = reply },
        .interrupted => return .{ .exit = .interrupted },
        else => {},
    }
    const message = if (why.items.len > 0) why.items else "the model call failed";
    var event = try a.events.begin("error");
    defer event.deinit();
    try event.truncated("error", message, 1000);
    try a.events.send(&event);
    if (!a.events.view.enabled) render.printErr(a.ctx.io, "arx: {s}\n", .{why.items});
    return .{ .exit = if (result == .auth) .auth else .@"error" };
}

/// Adds a reply's usage to the session and reports it.
fn account(a: *Agent, r: llm.Reply) Allocator.Error!void {
    const s = &a.session.?;
    s.tokens_in += r.tokens_in;
    s.tokens_out += r.tokens_out;
    s.cost += r.cost;
    a.tokens_at_call = r.tokens_in;
    var event = try a.events.begin("model.message");
    defer event.deinit();
    try event.int("tokens_in", r.tokens_in);
    try event.int("tokens_out", r.tokens_out);
    try event.num("cost", r.cost);
    try event.int("tool_calls", @intCast(json.items(json.field(r.message.value, "tool_calls")).len));
    try a.events.send(&event);
}

/// Runs model turns until the agent stops (no tool calls and the stop hook
/// does not continue), a cap is reached, or an error or interrupt happens.
pub fn runTurns(a: *Agent) !Exit {
    while (true) {
        if (sys.isInterrupted()) return .interrupted;
        if (try checkCaps(a)) |code| return code;
        try maybeReload(a);
        try readInbox(a);
        if (a.stop_requested) return .done;
        try flushNotes(a);
        try compact.maybeCompact(a);
        const s = &a.session.?;
        s.turns += 1;
        a.events.turn = s.turns;
        try a.events.sendPlain("turn.start");
        const reply = switch (try callModel(a)) {
            .reply => |r| r,
            .exit => |code| return code,
        };
        try a.messages.append(reply.message);
        try account(a, reply);
        try a.record(reply.message);
        const calls = json.items(json.field(reply.message.value, "tool_calls"));
        if (calls.len > 0) {
            try runToolCalls(a, calls);
        } else {
            try a.setFinalOutput(json.strOr(reply.message.value, "content", ""));
            if (!try stopHook(a)) return .done;
        }
        try s.writeMeta(a.ctx, "running");
    }
}
