//! model_call.zig: one model call through its hooks. before_model gets the
//! request and may replace any part of it; messages it returns become the
//! history, so the transcript shows exactly what the model got. after_model
//! gets the reply and may replace it. When the provider says the prompt is
//! too long, before_model runs again with reason context_overflow, or the
//! built-in compaction strategy runs when no hook changed anything; then
//! the call is retried once.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const render = @import("../io/render.zig");
const history = @import("../io/history.zig");
const Message = history.Message;
const History = history.History;
const hooks = @import("../harness/hooks.zig");
const compact = @import("../harness/compact.zig");
const llm = @import("../model/llm.zig");
const Agent = @import("agent.zig").Agent;
const Exit = util.Exit;

/// The request the spec describes, without the messages: {tools, model,
/// settings}, in `t`.
fn newRequest(a: *Agent, t: Allocator) Allocator.Error!json.Value {
    var request = json.object();
    try json.put(t, &request, "tools", try json.parseTrusted(t, try a.tools.toJson(t)));
    try json.putString(t, &request, "model", json.strOr(a.spec.root, "model", ""));
    const settings = json.field(a.spec.root, "model_settings");
    try json.put(t, &request, "settings", if (settings != null and settings.? == .object) try json.copy(t, settings.?) else json.object());
    return request;
}

/// Runs the before_model hooks on `request` and the history. Returns true
/// when a hook changed something.
fn beforeModel(a: *Agent, t: Allocator, request: *json.Value, reason: []const u8) !bool {
    if (!hooks.exists(a, "before_model")) return false;
    var messages = json.array(t);
    for (a.messages.slice()) |m| try messages.array.append(m.value);
    try json.put(t, request, "messages", messages);
    try json.putString(t, request, "reason", reason);
    var changed = json.array(t);
    _ = try hooks.chain(a, t, "before_model", request, &changed);
    const after = request.object.fetchOrderedRemove("messages").?.value;
    _ = request.object.orderedRemove("reason");
    for (changed.array.items) |field| if (std.mem.eql(u8, field.string, "messages")) {
        // A hook's messages become the history.
        var fresh: History = .init(a.ctx.gpa);
        errdefer fresh.deinit();
        for (after.array.items) |value| try fresh.append(try Message.fromValue(a.ctx.gpa, value));
        a.messages.deinit();
        a.messages = fresh;
        try a.recordReset();
    };
    return changed.array.items.len > 0;
}

/// Sends the history with `request`.
fn send(a: *Agent, t: Allocator, request: json.Value, why: *std.ArrayList(u8)) !llm.Result {
    why.clearRetainingCapacity();
    a.estimate_at_call = a.messages.estimateTokens();
    return llm.chat(a, &a.messages, .{
        .model = json.strOr(request, "model", ""),
        .settings = json.field(request, "settings"),
        .tools_json = try json.stringify(t, json.field(request, "tools") orelse json.array(t)),
    }, true, why);
}

/// Runs the after_model hooks on the reply; a changed reply replaces it.
fn afterModel(a: *Agent, t: Allocator, r: *llm.Reply) !void {
    if (!hooks.exists(a, "after_model")) return;
    var object = json.object();
    try json.put(t, &object, "reply", r.message.value);
    var usage = json.object();
    try json.put(t, &usage, "prompt_tokens", .{ .integer = r.tokens_in });
    try json.put(t, &usage, "completion_tokens", .{ .integer = r.tokens_out });
    try json.put(t, &usage, "cost", json.number(r.cost));
    try json.put(t, &object, "usage", usage);
    try json.putString(t, &object, "finish", r.finish);
    var changed = json.array(t);
    _ = try hooks.chain(a, t, "after_model", &object, &changed);
    if (changed.array.items.len == 0) return;
    const fresh = try Message.fromValue(a.ctx.gpa, json.field(object, "reply").?);
    r.message.destroy(a.ctx.gpa);
    r.message = fresh;
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

/// Compacts after a context-overflow error: the before_model hooks first,
/// then the built-in strategy (hybrid for the default mask, which alone
/// rarely frees enough). Returns true when something changed.
fn overflow(a: *Agent, t: Allocator, request: *json.Value) !bool {
    if (try beforeModel(a, t, request, "context_overflow")) return true;
    const s = json.strOr(a.spec.root, "compaction.strategy", "mask");
    return compact.compact(a, if (std.mem.eql(u8, s, "mask")) "hybrid" else s, null);
}

/// What one model turn gave.
pub const Turn = union(enum) {
    /// The assistant message; the caller owns it.
    message: *Message,
    exit: Exit,
};

/// Calls the model once for the next turn, through the before_model and
/// after_model hooks, and accounts for the usage. On a context-overflow
/// error it compacts and retries once.
pub fn turn(a: *Agent) !Turn {
    const gpa = a.ctx.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = arena.allocator();
    var request = try newRequest(a, t);
    _ = try beforeModel(a, t, &request, "turn");
    var why: std.ArrayList(u8) = .empty;
    defer why.deinit(gpa);
    var result = try send(a, t, request, &why);
    if (result == .context and try overflow(a, t, &request)) result = try send(a, t, request, &why);
    switch (result) {
        .ok => |reply| {
            var r = reply;
            errdefer r.message.destroy(gpa);
            try account(a, r);
            try afterModel(a, t, &r);
            return .{ .message = r.message };
        },
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
