//! loop.zig: the turn loop. Before each model call it hot-reloads the
//! harness if any of its files changed, reads the inbox, hands harness
//! notes to the agent and compacts the context. Then it calls the model
//! (model_call.zig), runs the tool calls (tool_calls.zig), and asks the
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
const hooks = @import("../harness/hooks.zig");
const kits = @import("../harness/kits.zig");
const compact = @import("../harness/compact.zig");
const model_call = @import("model_call.zig");
const tool_calls = @import("tool_calls.zig");
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
        try kits.lockWrite(ctx, &a.spec);
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
    const header = "[harness]\n";
    try a.notes.insertSlice(a.ctx.gpa, 0, header);
    try a.addMessage("user", a.notes.items);
    var event = try a.events.begin("note");
    defer event.deinit();
    try event.truncated("text", a.notes.items[header.len..], 1000);
    try a.events.send(&event);
    a.notes.clearRetainingCapacity();
}

/// Asks the stop hook whether to go on. Returns true to keep going.
fn stopHook(a: *Agent) !bool {
    var arena: std.heap.ArenaAllocator = .init(a.ctx.gpa);
    defer arena.deinit();
    const t = arena.allocator();
    const fields = try t.print("\"last_message\":{f}", .{json.fmt(.{ .string = try util.truncate(t, a.final_output orelse "", 8192) })});
    const outcome = try hooks.run(a, t, "stop", fields);
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

/// Runs model turns until the agent stops (no tool calls and the stop hook
/// does not continue), a cap is reached, or an error or interrupt happens.
pub fn runTurns(a: *Agent) !Exit {
    try kits.lockWrite(a.ctx, &a.spec); // a kit that pins versions: record the parts
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
        const message = switch (try model_call.turn(a)) {
            .message => |m| m,
            .exit => |code| return code,
        };
        try a.messages.append(message);
        try a.record(message);
        const calls = json.items(json.field(message.value, "tool_calls"));
        if (calls.len > 0) {
            try tool_calls.run(a, calls);
        } else {
            const answer = try a.ctx.gpa.dupe(u8, json.strOr(message.value, "content", ""));
            if (a.final_output) |old| a.ctx.gpa.free(old);
            a.final_output = answer;
            if (!try stopHook(a)) return .done;
        }
        try s.writeMeta(a.ctx, "running");
    }
}
