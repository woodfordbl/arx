//! hooks.zig: runs hook executables, one per layer for each point, by band
//! (policy, normal, final) and then in layer order: the spec folder's
//! first, then each plugin's in the order of the active list. At the points
//! around the model and tool calls the hooks form a chain over one raw
//! object: each hook gets the object as the hook before it left it, and
//! prints the fields it changes. A hook that fails is reported and then
//! ignored (fail-open), unless its options mark it `fail: closed`, so a
//! broken hook the agent wrote cannot stop the harness.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const proc = @import("../base/proc.zig");
const Event = @import("../io/events.zig").Event;
const spec_mod = @import("spec.zig");
const Spec = spec_mod.Spec;
const Layer = spec_mod.Layer;
const keys = @import("keys.zig");
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

/// What the hooks for a decision point decided.
pub const Outcome = struct {
    status: Status,
    /// The combined JSON, in the caller's arena, or null: session_start
    /// joins every {"context"}; stop takes the first {"decision":
    /// "continue" | "restart", "message"}.
    output: ?json.Value = null,
};

/// The bands, in the order they run.
pub const band_names = [_][]const u8{ "policy", "normal", "final" };

/// The fields a hook may print at each raw-object point.
const raw_points = [_]struct { []const u8, []const []const u8 }{
    .{ "before_model", &.{ "messages", "tools", "model", "settings" } },
    .{ "after_model", &.{"reply"} },
    .{ "before_tool", &.{ "name", "args", "keys", "result" } },
    .{ "after_tool", &.{ "result", "backoff" } },
};

/// The options of `layer`'s hook at `point`: a plugin's come from its
/// plugin.yaml, the others from the spec's hooks.<point>. May be null.
pub fn options(spec: *const Spec, layer: Layer, point: []const u8) ?json.Value {
    if (layer.plugin != null) return json.field(layer.hooks, point);
    return json.field(json.field(spec.root, "hooks"), point);
}

/// The band of `layer`'s hook at `point`: 0 policy, 1 normal (the
/// default), 2 final.
pub fn band(spec: *const Spec, layer: Layer, point: []const u8) usize {
    const name = json.strOr(options(spec, layer, point), "band", "");
    for (band_names, 0..) |b, i| if (std.mem.eql(u8, name, b)) return i;
    return 1;
}

/// The path of this layer's hook for `point`, or null if it has none.
fn hookPath(a: *Agent, t: Allocator, layer: Layer, point: []const u8) Allocator.Error!?[]const u8 {
    const path = try std.mem.concat(t, u8, &.{ layer.dir, "/hooks/", point });
    return if (util.isExecutable(a.ctx.io, path)) path else null;
}

/// True when any layer has an executable hooks/<point>.
pub fn exists(a: *Agent, point: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (a.spec.layers) |layer| {
        const path = std.fmt.bufPrint(&buf, "{s}/hooks/{s}", .{ layer.dir, point }) catch continue;
        if (util.isExecutable(a.ctx.io, path)) return true;
    }
    return false;
}

/// True when this layer's failed hook for `point` should stop the run.
fn failsClosed(a: *Agent, layer: Layer, point: []const u8) bool {
    return std.mem.eql(u8, json.strOr(options(&a.spec, layer, point), "fail", "open"), "closed");
}

/// Runs one hook with `input` on stdin. Returns its JSON object (in `t`)
/// or null, and its hook event, not yet sent; `failed` says whether it
/// failed.
fn runOne(a: *Agent, t: Allocator, layer: Layer, point: []const u8, path: []const u8, input: []const u8, event: *Event, failed: *bool) Allocator.Error!?json.Value {
    const gpa = a.ctx.gpa;
    var env = try tool_exec.environ(a, if (layer.plugin != null) layer.dir else null, a.depth);
    defer env.deinit();
    // A plugin's hook gets its settings from the active list, as JSON.
    if (layer.plugin != null) try env.put("ARX_PLUGIN_SETTINGS", try json.stringify(t, layer.settings orelse json.object()));
    var out: proc.Collector = .init(gpa);
    defer out.deinit();
    var err: proc.Collector = .init(gpa);
    defer err.deinit();
    const r = try proc.run(a.ctx, .{
        .argv = &.{path},
        .stdin = input,
        .timeout = json.duration(options(&a.spec, layer, point), "timeout", 10),
        .environ = &env,
        .stdout = out.sink(),
        .stderr = err.sink(),
    });
    event.* = try a.events.begin("hook");
    try event.str("point", point);
    if (layer.plugin) |plugin| try event.str("plugin", plugin);
    const b = band(&a.spec, layer, point);
    if (b != 1) try event.str("band", band_names[b]);
    try event.num("secs", r.secs);
    var failure: ?[]const u8 = if (r.spawn_error != null)
        "could not start the hook"
    else if (r.timed_out)
        "timed out"
    else if (r.code != 0)
        try t.print("exit {d}: {s}", .{ r.code, err.output() })
    else
        null;
    var answer: ?json.Value = null;
    if (failure == null and std.mem.trim(u8, out.output(), " \t\r\n").len > 0) {
        answer = try json.parseObject(t, out.output());
        if (answer == null) failure = "stdout is not a JSON object";
    }
    if (failure) |f| {
        try event.truncated("error", f, 300);
    } else if (json.str(answer, "decision")) |decision| {
        try event.str("decision", decision);
    }
    failed.* = failure != null;
    return answer;
}

/// Adds one hook's answer to the combined output. Returns true when the
/// answer decides, so the later hooks do not run.
fn combine(t: Allocator, point: []const u8, answer: json.Value, output: *?json.Value) Allocator.Error!bool {
    if (!std.mem.eql(u8, point, "session_start")) {
        if (json.strOr(answer, "decision", "").len == 0) return false;
        output.* = answer; // the first decision wins
        return true;
    }
    const text = json.str(answer, "context") orelse return false;
    const joined = if (json.str(output.*, "context")) |before| try t.print("{s}\n\n{s}", .{ before, text }) else text;
    var fresh = json.object();
    try json.putString(t, &fresh, "context", joined);
    output.* = fresh;
    return false;
}

/// Runs hooks/<point> for session_start or stop in every layer that has
/// one, by band and then in layer order, with a JSON object on stdin:
/// `fields` (object members such as `"reason":"..."`, or "") plus point,
/// session and turn. A failed hook (non-zero exit, timeout, output that is
/// not a JSON object) is reported and ignored, unless it is `fail:
/// closed`: then the run stops with status `failed`. The output lives in
/// `t`.
pub fn run(a: *Agent, t: Allocator, point: []const u8, fields: []const u8) Allocator.Error!Outcome {
    const text = try t.print("{{{s}{s}\"point\":\"{s}\",\"session\":\"{s}\",\"turn\":{d}}}", .{
        fields, if (fields.len > 0) "," else "", point, a.sessionId(), a.turns(),
    });
    var outcome: Outcome = .{ .status = .none };
    const n = a.spec.layers.len;
    for (0..3 * n) |k| {
        const layer = a.spec.layers[k % n];
        if (band(&a.spec, layer, point) != k / n) continue;
        const path = (try hookPath(a, t, layer, point)) orelse continue;
        var failed = false;
        var event: Event = undefined;
        const answer = try runOne(a, t, layer, point, path, text, &event, &failed);
        defer event.deinit();
        try a.events.send(&event);
        if (failed and failsClosed(a, layer, point)) {
            outcome.status = .failed;
            break;
        }
        outcome.status = .ran;
        if (answer) |ans| if (try combine(t, point, ans, &outcome.output)) break;
    }
    return outcome;
}

/// The fields a hook may print at `point`.
fn fieldsOf(point: []const u8) []const []const u8 {
    for (raw_points) |p| if (std.mem.eql(u8, p[0], point)) return p[1];
    return &.{};
}

/// True when `value` has the right type for the field `key`.
fn fieldOk(key: []const u8, value: json.Value) bool {
    const eql = std.mem.eql;
    if (eql(u8, key, "messages")) {
        if (value != .array) return false;
        for (value.array.items) |m| if (json.str(m, "role") == null) return false;
        return true;
    }
    if (eql(u8, key, "tools")) return value == .array;
    if (eql(u8, key, "settings") or eql(u8, key, "backoff")) return value == .object;
    if (eql(u8, key, "keys")) return keys.valid(value);
    if (eql(u8, key, "reply")) return json.str(value, "role") != null;
    if (eql(u8, key, "args")) return value == .object or value == .string;
    return value == .string and (!eql(u8, key, "name") or value.string.len > 0);
}

/// Turns the outputs hooks printed before the raw objects into fields:
/// before_tool's {"decision": "deny", "reason"} becomes the result
/// "denied: <reason>", and after_tool's {"note"} is appended to the
/// result. Returns true for a denial.
fn legacy(t: Allocator, point: []const u8, object: json.Value, answer: *json.Value) Allocator.Error!bool {
    if (std.mem.eql(u8, point, "before_tool") and std.mem.eql(u8, json.strOr(answer.*, "decision", ""), "deny") and json.field(answer.*, "result") == null) {
        try json.putString(t, answer, "result", try t.print("denied: {s}", .{json.strOr(answer.*, "reason", "no reason given")}));
        return true;
    }
    if (std.mem.eql(u8, point, "after_tool")) if (json.str(answer.*, "note")) |note| {
        const base = json.str(answer.*, "result") orelse json.strOr(object, "result", "");
        _ = answer.object.orderedRemove("result");
        try json.putString(t, answer, "result", try t.print("{s}\n[after_tool] {s}", .{ base, note }));
    };
    return false;
}

/// What one hook's answer did to the chain.
const Applied = enum { bad, ok, ends };

/// Applies one hook's answer to `object`: copies the allowed fields that
/// differ, and lists them in the event and in `changed`. A field of the
/// wrong type makes the whole answer bad, and nothing is copied.
fn apply(t: Allocator, point: []const u8, object: *json.Value, answer: *json.Value, event: *Event, changed: ?*json.Value) Allocator.Error!Applied {
    const denied = try legacy(t, point, object.*, answer);
    const allowed = fieldsOf(point);
    for (allowed) |f| if (json.field(answer.*, f)) |v| if (!fieldOk(f, v)) {
        try event.str("error", try t.print("printed a bad \"{s}\"", .{f}));
        return .bad;
    };
    const ea = event.arena.allocator();
    var mine = json.array(ea);
    for (allowed) |f| {
        const value = json.field(answer.*, f) orelse continue;
        if (json.field(object.*, f)) |old| if (json.equal(old, value)) continue;
        try json.put(t, object, f, value);
        try mine.array.append(.{ .string = f });
    }
    if (denied) try json.put(t, object, "is_error", .{ .bool = true });
    if (mine.array.items.len > 0) {
        if (changed) |list| for (mine.array.items) |name| {
            const have = for (list.array.items) |h| {
                if (std.mem.eql(u8, h.string, name.string)) break true;
            } else false;
            if (!have) try list.array.append(name);
        };
        try event.put("changed", mine);
    }
    if (std.mem.eql(u8, point, "before_tool") and json.field(object.*, "result") != null) return .ends;
    return .ok;
}

/// A result that a policy hook set is final: drops a later hook's change
/// to it (a result, a note or a denial), and says so in its event.
fn keepResult(answer: *json.Value, event: *Event) Allocator.Error!void {
    var dropped = false;
    for ([_][]const u8{ "result", "note", "decision" }) |key| {
        if (answer.object.orderedRemove(key)) dropped = true;
    }
    if (dropped) try event.str("ignored", "result: a policy hook set it, so it is final");
}

/// Runs hooks/<point> for a raw-object point as a chain: the `policy` band
/// first, then `normal`, then `final`, each in layer order. Each hook gets
/// `object` plus point, session and turn, and prints the fields it
/// changes; they replace the fields of `object` (which lives in `t`)
/// before the next:
///   before_model  {messages, tools, model, settings, reason}
///                 prints any of messages, tools, model, settings
///   after_model   {reply, usage, finish}; prints reply
///   before_tool   {id, name, args, keys}; prints name, args or keys, or
///                 result to skip the tool, which ends the chain.
///                 {"decision": "deny", "reason"} becomes the result
///                 "denied: <reason>" and adds "is_error": true.
///   after_tool    {call, result, is_error}; prints result or backoff.
///                 {"note"} is appended to the result.
/// A `result` that a policy hook sets is final. Plugin hooks get their
/// settings as ARX_PLUGIN_SETTINGS. A field of the wrong type is a
/// failure. The names of changed fields go to `changed` (a list).
pub fn chain(a: *Agent, t: Allocator, point: []const u8, object: *json.Value, changed: ?*json.Value) Allocator.Error!Status {
    var status: Status = .none;
    var final_result = false;
    const n = a.spec.layers.len;
    for (0..3 * n) |k| {
        const layer = a.spec.layers[k % n];
        const b = band(&a.spec, layer, point);
        if (b != k / n) continue;
        const path = (try hookPath(a, t, layer, point)) orelse continue;
        try json.putString(t, object, "point", point);
        try json.putString(t, object, "session", a.sessionId());
        try json.put(t, object, "turn", .{ .integer = a.turns() });
        const text = try json.stringify(t, object.*);
        for ([_][]const u8{ "point", "session", "turn" }) |key| _ = object.object.orderedRemove(key);
        var failed = false;
        var event: Event = undefined;
        var answer = try runOne(a, t, layer, point, path, text, &event, &failed);
        defer event.deinit();
        var applied: Applied = if (failed) .bad else .ok;
        if (answer) |*ans| {
            if (final_result) try keepResult(ans, &event);
            applied = try apply(t, point, object, ans, &event, changed);
        }
        if (b == 0 and json.field(event.value, "changed") != null) {
            for (json.items(json.field(event.value, "changed"))) |f| if (std.mem.eql(u8, f.string, "result")) {
                final_result = true;
            };
        }
        try a.events.send(&event);
        if (applied == .bad and failsClosed(a, layer, point)) return .failed;
        status = .ran;
        if (applied == .ends) break;
    }
    return status;
}
