//! tool_calls.zig: the tool runtime for the calls of one reply. Hooks
//! decide if a call may run; the runtime decides when. before_tool gets the
//! raw call {id, name, args, keys} and may change it, or give the result
//! itself so the tool does not run. The allowed calls wait in a queue and
//! start by their keys, or when a scheduler plugin says so. after_tool gets
//! {call, result, is_error} as each call ends and may change the result; it
//! runs for every call that ran, also after an error, a timeout or Ctrl-C.
//! When a hook changed the call, the result says what ran, since the model
//! only knows the call it made. Results go into the history in call order.

const std = @import("std");
const Allocator = std.mem.Allocator;

const sys = @import("../base/sys.zig");
const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const proc = @import("../base/proc.zig");
const Event = @import("../io/events.zig").Event;
const Message = @import("../io/history.zig").Message;
const hooks = @import("../harness/hooks.zig");
const keys = @import("../harness/keys.zig");
const tool_exec = @import("../harness/tool_exec.zig");
const Agent = @import("agent.zig").Agent;

/// A one-line summary of a tool call for the terminal view: the command,
/// path or task when there is one, else the raw arguments.
fn preview(t: Allocator, args: []const u8) Allocator.Error![]u8 {
    const parsed = try json.parseObject(t, args);
    const s = json.str(parsed, "command") orelse json.str(parsed, "path") orelse json.str(parsed, "task") orelse args;
    const text = try util.truncate(t, s, 120);
    std.mem.replaceScalar(u8, text, '\n', ' ');
    return text;
}

/// The arguments of `call` as the tool gets them on stdin.
fn argsText(t: Allocator, call: json.Value) Allocator.Error![]const u8 {
    const args = json.field(call, "args") orelse return "{}";
    return if (args == .string) args.string else json.stringify(t, args);
}

/// Where a call is in the runtime.
const State = enum { queued, running, done };

/// One call of the reply, from its before_tool hooks to its result.
const Call = struct {
    id: []const u8 = "",
    /// The arguments as the model wrote them.
    args: []const u8 = "{}",
    /// {id, name, args, keys} as the model made it.
    model_call: json.Value = .null,
    /// The same after the before_tool hooks.
    call: json.Value = .null,
    state: State = .done,
    run: ?*tool_exec.Run = null,
    text: []const u8 = "",
    is_error: bool = true,
    out_path: ?[]const u8 = null,
    /// The tool.end event, until it is sent.
    end: ?Event = null,
};

/// The calls of one reply and what they share.
const Runtime = struct {
    a: *Agent,
    /// Holds every string and value of the calls.
    t: Allocator,
    calls: []Call,

    /// The raw call a before_tool hook gets: {id, name, args, keys}, with
    /// the arguments parsed when they are JSON and the keys from the
    /// tool's schema.
    fn newCall(rt: *Runtime, id: []const u8, name: []const u8, args: []const u8) Allocator.Error!json.Value {
        const t = rt.t;
        var call = json.object();
        try json.putString(t, &call, "id", id);
        try json.putString(t, &call, "name", name);
        const parsed = json.parse(t, args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        try json.put(t, &call, "args", parsed orelse json.Value{ .string = args });
        try json.put(t, &call, "keys", try keys.forCall(t, rt.a.tools.find(name), if (parsed) |p| (if (p == .object) p else .null) else .null));
        return call;
    }

    /// The keys the call runs with: the ones a hook printed, else the
    /// tool's keys for the call as it is now (a hook may have changed the
    /// name or the arguments).
    fn finalKeys(rt: *Runtime, c: *Call) Allocator.Error!void {
        const have = json.field(c.call, "keys");
        if (have != null and keys.valid(have.?) and !json.equal(have.?, json.field(c.model_call, "keys") orelse .null)) return;
        const args = json.field(c.call, "args") orelse .null;
        try json.put(rt.t, &c.call, "keys", try keys.forCall(rt.t, rt.a.tools.find(json.strOr(c.call, "name", "")), if (args == .object) args else .null));
    }

    /// Sends the call's tool.end event with its error flag and the first
    /// line of its result.
    fn sendEnd(rt: *Runtime, c: *Call) Allocator.Error!void {
        var end = c.end orelse return;
        defer end.deinit();
        c.end = null;
        try end.boolean("error", c.is_error);
        try end.truncated("preview", c.text[0 .. std.mem.findScalar(u8, c.text, '\n') orelse c.text.len], 100);
        try rt.a.events.send(&end);
    }

    /// Ends a call without a run, with the result `text`.
    fn endWithout(rt: *Runtime, c: *Call, text: []const u8, is_error: bool) Allocator.Error!void {
        c.text = text;
        c.is_error = is_error;
        c.state = .done;
        try rt.sendEnd(c);
    }

    /// Runs the after_tool hooks on the call's result. Returns the backoff
    /// the hooks printed ({"key", "secs"}), which only a scheduler plugin
    /// uses.
    fn afterTool(rt: *Runtime, c: *Call) Allocator.Error!?json.Value {
        const t = rt.t;
        if (!hooks.exists(rt.a, "after_tool")) return null;
        var object = json.object();
        var call = json.object();
        for ([_][]const u8{ "id", "name", "args" }) |key| try json.put(t, &call, key, json.field(c.call, key) orelse .{ .string = "" });
        try json.put(t, &object, "call", call);
        try json.putString(t, &object, "result", c.text);
        try json.put(t, &object, "is_error", .{ .bool = c.is_error });
        // After a Ctrl-C the hook must still run, so it is not killed at once.
        const interrupted = sys.isInterrupted();
        sys.clearInterrupted();
        defer if (interrupted) sys.setInterrupted();
        _ = try hooks.chain(rt.a, t, "after_tool", &object, null);
        c.text = json.strOr(object, "result", c.text);
        const backoff = json.field(object, "backoff") orelse return null;
        if (json.str(backoff, "key") == null or json.asNumber(json.field(backoff, "secs") orelse .null) == null) return null;
        return backoff;
    }

    /// Finishes a call whose tool ended (or could not start): sends
    /// tool.end before the after_tool hooks, so the view shows the end at
    /// once, then runs them, adds what ran when a hook changed the call,
    /// and tells a scheduler plugin.
    fn complete(rt: *Runtime, c: *Call, secs: f64) Allocator.Error!void {
        const t = rt.t;
        try rt.sendEnd(c);
        const backoff = try rt.afterTool(c);
        const name = json.strOr(c.call, "name", "");
        const renamed = !std.mem.eql(u8, name, json.strOr(c.model_call, "name", ""));
        if (renamed or !json.equal(json.field(c.call, "args") orelse .null, json.field(c.model_call, "args") orelse .null)) {
            const what = try preview(t, try argsText(t, c.call));
            const line = if (renamed) try t.print("[ran as: {s} {s}]", .{ name, what }) else try t.print("[ran as: {s}]", .{what});
            const sep = if (c.text.len > 0 and c.text[c.text.len - 1] != '\n') "\n" else "";
            c.text = try t.print("{s}{s}{s}", .{ c.text, sep, line });
        }
        c.state = .done;
        try rt.a.sched.done(rt.a.ctx.gpa, c.id, secs, c.is_error, backoff);
    }

    /// Starts a queued call's tool.
    fn launch(rt: *Runtime, c: *Call) !void {
        // Unchanged arguments go to the tool exactly as the model wrote them.
        const same = json.equal(json.field(c.call, "args") orelse .null, json.field(c.model_call, "args") orelse .null);
        const input = if (same) c.args else try argsText(rt.t, c.call);
        c.state = .running;
        switch (try tool_exec.start(rt.a, rt.t, json.strOr(c.call, "name", ""), input)) {
            .running => |started| c.run = started,
            .done => |outcome| {
                c.text = outcome.text;
                c.is_error = outcome.is_error;
                try rt.complete(c, 0);
            },
        }
    }

    /// Runs the before_tool hooks of one call and sends tool.start. Leaves
    /// the call queued, or done when a hook gave the result.
    fn prepare(rt: *Runtime, c: *Call, raw: json.Value) !void {
        const a = rt.a;
        const name = json.strOr(raw, "function.name", "");
        c.id = json.strOr(raw, "id", "");
        c.args = json.strOr(raw, "function.arguments", "{}");
        c.end = try a.events.begin("tool.end");
        try c.end.?.str("id", c.id);
        try c.end.?.str("name", name);
        if (sys.isInterrupted()) return rt.endWithout(c, "[interrupted before this tool ran]", true);
        var start = try a.events.begin("tool.start");
        defer start.deinit();
        try start.str("id", c.id);
        try start.str("name", name);
        try start.str("preview", try preview(rt.t, c.args));
        try a.events.send(&start);
        c.model_call = try rt.newCall(c.id, name, c.args);
        c.call = try json.copy(rt.t, c.model_call);
        if (try hooks.chain(a, rt.t, "before_tool", &c.call, null) == .failed) {
            return rt.endWithout(c, "denied: the before_tool hook failed (fail: closed)", true);
        }
        if (json.str(c.call, "result")) |result| return rt.endWithout(c, result, json.boolean(c.call, "is_error", false));
        try rt.finalKeys(c);
        c.state = .queued;
    }

    /// The built-in scheduler: starts each queued call, in call order,
    /// whose keys conflict with no running call and no call queued before
    /// it. So calls that conflict run in the order the model gave them.
    fn startByKeys(rt: *Runtime) !void {
        for (rt.calls, 0..) |*c, i| {
            if (c.state != .queued) continue;
            const mine = json.field(c.call, "keys") orelse .null;
            const blocked = for (rt.calls, 0..) |other, j| {
                const before = other.state == .running or (other.state == .queued and j < i);
                if (j != i and before and keys.conflict(mine, json.field(other.call, "keys") orelse .null)) break true;
            } else false;
            if (!blocked) try rt.launch(c);
        }
    }

    /// Applies what a scheduler plugin said: the calls to start and the
    /// results that end calls without a run. Unknown ids are ignored.
    fn startByPlugin(rt: *Runtime) !void {
        var start = json.array(rt.t);
        var results = json.object();
        try rt.a.sched.poll(rt.a, rt.t, &start, &results);
        for (rt.calls) |*c| {
            if (c.state != .queued) continue;
            for (start.array.items) |id| if (c.state == .queued and std.mem.eql(u8, id.string, c.id)) try rt.launch(c);
            if (json.str(results, c.id)) |text| if (c.state == .queued) try rt.endWithout(c, text, true);
        }
    }

    /// Runs the queued calls until every call is done.
    fn runQueue(rt: *Runtime) !void {
        const a = rt.a;
        const gpa = a.ctx.gpa;
        var kids: std.ArrayList(*proc.Child) = .empty;
        defer kids.deinit(gpa);
        while (true) {
            // After Ctrl-C nothing new starts; running calls are stopped by
            // proc.poll and still get their after_tool hooks.
            if (sys.isInterrupted()) for (rt.calls) |*c| if (c.state == .queued) try rt.endWithout(c, "[interrupted before this tool ran]", true);
            if (a.sched.child != null) try rt.startByPlugin();
            if (a.sched.child == null) try rt.startByKeys();
            kids.clearRetainingCapacity();
            var queued = false;
            for (rt.calls) |c| {
                if (c.state == .running) try kids.append(gpa, c.run.?.child);
                if (c.state == .queued) queued = true;
            }
            if (kids.items.len == 0 and !queued) break;
            const wait = a.sched.wait(a, 0.1);
            if (a.sched.child) |child| try kids.append(gpa, child);
            try proc.poll(gpa, kids.items, wait);
            for (rt.calls) |*c| {
                if (c.state != .running or !c.run.?.child.done) continue;
                const outcome = try c.run.?.finish(rt.t, &c.end.?);
                c.run = null;
                c.text = outcome.text;
                c.is_error = outcome.is_error;
                c.out_path = outcome.output_path;
                try rt.complete(c, json.num(c.end.?.value, "secs", 0));
            }
        }
    }
};

/// Runs the tool calls in `calls` through the before_tool hooks, then
/// queues the allowed calls and runs them by their keys (calls that share
/// a key run one at a time, "*" runs alone, [] runs with anything), or as a
/// scheduler plugin says. after_tool runs as each call ends. Adds the
/// results to the history and the transcript in the order of the calls.
/// Calls after a Ctrl-C still get a result, so the history stays valid.
pub fn run(a: *Agent, calls: []const json.Value) !void {
    const gpa = a.ctx.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = arena.allocator();
    var rt: Runtime = .{ .a = a, .t = t, .calls = try t.alloc(Call, calls.len) };
    @memset(rt.calls, .{});
    defer for (rt.calls) |*c| if (c.end) |*e| {
        if (c.run) |r| _ = r.finish(t, e) catch {}; // only after an error
        e.deinit();
    };
    const plugin = try a.sched.open(a);
    for (rt.calls, calls) |*c, raw| {
        try rt.prepare(c, raw);
        if (plugin and c.state == .queued) try a.sched.ready(gpa, c.id, json.strOr(c.call, "name", ""), json.field(c.call, "keys"));
    }
    try rt.runQueue();
    for (rt.calls) |c| {
        const m = try Message.text(gpa, "tool", c.text);
        {
            errdefer m.destroy(gpa);
            try json.putString(m.allocator(), &m.value, "tool_call_id", c.id);
            if (c.out_path) |p| try json.putString(m.allocator(), &m.value, "_out", p);
        }
        try a.messages.append(m);
        try a.record(m);
    }
}
