//! hooks.zig: runs hook executables, one per layer for each point, in layer
//! order: the spec folder's first, then each plugin's. A hook that fails is
//! reported and then ignored (fail-open), unless its options mark it
//! `fail: closed`, so a broken hook the agent wrote cannot stop the harness.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const proc = @import("../base/proc.zig");
const Layer = @import("spec.zig").Layer;
const tool_exec = @import("tool_exec.zig");
const Agent = @import("../agent/agent.zig").Agent;

/// Whether any hook ran.
pub const Status = enum {
    /// No layer has a hook for this point.
    none,
    /// Hooks ran (some may have failed open).
    ran,
    /// A hook marked `fail: closed` failed.
    failed,
};

/// What the hooks for one point decided.
pub const Outcome = struct {
    status: Status,
    /// The combined JSON decision, in the caller's arena, or null:
    ///   session_start  {"context": "..."}            every hook's, joined
    ///   before_tool    {"decision": "deny", "reason": "..."}  the first deny
    ///   after_tool     {"note": "..."}                every hook's, joined
    ///   stop           {"decision": "continue" | "restart", "message": "..."}
    ///                                                 the first decision
    output: ?json.Value = null,
};

/// The options for `point` in this layer: a plugin's come from its
/// plugin.yaml, the others from the spec's hooks.<point>.
fn options(a: *const Agent, layer: Layer, point: []const u8) ?json.Value {
    if (layer.plugin != null) return json.field(layer.hooks, point);
    return json.field(json.field(a.spec.root, "hooks"), point);
}

/// Runs one hook with `input` on stdin. Returns its JSON object (in
/// `arena`), or null; `failed` says whether it failed.
fn runOne(a: *Agent, arena: Allocator, layer: Layer, point: []const u8, path: []const u8, input: []const u8, failed: *bool) Allocator.Error!?json.Value {
    const gpa = a.ctx.gpa;
    var env = try tool_exec.environ(a, if (layer.plugin != null) layer.dir else null, a.depth);
    defer env.deinit();
    var out: proc.Collector = .init(gpa);
    defer out.deinit();
    var err: proc.Collector = .init(gpa);
    defer err.deinit();
    const r = try proc.run(a.ctx, .{
        .argv = &.{path},
        .stdin = input,
        .timeout = json.duration(options(a, layer, point), "timeout", 10),
        .environ = &env,
        .stdout = out.sink(),
        .stderr = err.sink(),
    });
    var event = try a.events.begin("hook");
    defer event.deinit();
    try event.str("point", point);
    if (layer.plugin) |plugin| try event.str("plugin", plugin);
    try event.num("secs", r.secs);
    var failure: ?[]const u8 = if (r.spawn_error != null)
        "could not start the hook"
    else if (r.timed_out)
        "timed out"
    else if (r.code != 0)
        try arena.print("exit {d}: {s}", .{ r.code, err.output() })
    else
        null;
    var answer: ?json.Value = null;
    if (failure == null and std.mem.trim(u8, out.output(), " \t\r\n").len > 0) {
        answer = try json.parseObject(arena, out.output());
        if (answer == null) failure = "stdout is not a JSON object";
    }
    if (failure) |f| {
        try event.truncated("error", f, 300);
    } else if (json.str(answer, "decision")) |decision| {
        try event.str("decision", decision);
    }
    try a.events.send(&event);
    failed.* = failure != null;
    return answer;
}

/// Adds one hook's answer to the combined output. Returns true when the
/// answer decides, so the later hooks do not run.
fn combine(arena: Allocator, point: []const u8, answer: json.Value, output: *?json.Value) Allocator.Error!bool {
    const key: ?[]const u8 = if (std.mem.eql(u8, point, "session_start"))
        "context"
    else if (std.mem.eql(u8, point, "after_tool"))
        "note"
    else
        null;
    if (key) |k| {
        const text = json.str(answer, k) orelse return false;
        if (json.str(output.*, k)) |before| {
            try json.put(arena, &output.*.?, k, .{ .string = try arena.print("{s}\n\n{s}", .{ before, text }) });
        } else {
            var fresh = json.object();
            try json.put(arena, &fresh, k, .{ .string = text });
            output.* = fresh;
        }
        return false;
    }
    const decision = json.strOr(answer, "decision", "");
    const decides = if (std.mem.eql(u8, point, "before_tool")) std.mem.eql(u8, decision, "deny") else decision.len > 0;
    if (decides) output.* = answer;
    return decides;
}

/// Runs hooks/<point> in every layer that has one, in layer order, with a
/// JSON object on stdin: `fields` (object members such as `"tool":{...}`,
/// or "") plus point, session and turn. A hook that fails (non-zero exit,
/// timeout, or output that is not a JSON object) is reported and then
/// ignored, unless its options say `fail: closed`; then the run stops with
/// status `failed`. The output lives in `arena`.
pub fn run(a: *Agent, arena: Allocator, point: []const u8, fields: []const u8) Allocator.Error!Outcome {
    const text = try arena.print("{{{s}{s}\"point\":\"{s}\",\"session\":\"{s}\",\"turn\":{d}}}", .{
        fields, if (fields.len > 0) "," else "", point, a.sessionId(), a.turns(),
    });
    var outcome: Outcome = .{ .status = .none };
    for (a.spec.layers) |layer| {
        const path = try std.mem.concat(arena, u8, &.{ layer.dir, "/hooks/", point });
        if (!util.isExecutable(a.ctx.io, path)) continue;
        var failed = false;
        const answer = try runOne(a, arena, layer, point, path, text, &failed);
        if (failed and std.mem.eql(u8, json.strOr(options(a, layer, point), "fail", "open"), "closed")) {
            outcome.status = .failed;
            break;
        }
        outcome.status = .ran;
        if (answer) |ans| if (try combine(arena, point, ans, &outcome.output)) break;
    }
    return outcome;
}
