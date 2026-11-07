//! scheduler.zig: a scheduler plugin, which decides when the queued tool
//! calls run. It is one long-lived process for each session: an executable
//! file named `scheduler` at the top of a layer (the first in layer order
//! wins). arx and the process exchange one JSON object per line; when the
//! process exits or prints a bad line, arx says so and uses the built-in
//! scheduler.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const proc = @import("../base/proc.zig");
const keys = @import("../harness/keys.zig");
const tool_exec = @import("../harness/tool_exec.zig");
const Agent = @import("agent.zig").Agent;

/// Drops the plugin's stderr, so it never mixes with its answers.
fn discard(_: *u8, _: []const u8) Allocator.Error!void {}

/// The session's scheduler process.
pub const Scheduler = struct {
    /// The running plugin, or null.
    path: ?[]u8 = null,
    /// A plugin that failed; it is not started again.
    failed: ?[]u8 = null,
    child: ?*proc.Child = null,
    env: ?Environ.Map = null,
    /// What it printed that is not read yet.
    out: std.ArrayList(u8) = .empty,
    /// When it wants a tick (unix seconds), or 0.
    wake_at: f64 = 0,
    /// The allocator for `out`.
    gpa_for_out: Allocator = undefined,
    /// The context of the stderr sink, which drops everything.
    unused: u8 = 0,

    /// Stops the process and forgets it.
    fn stop(s: *Scheduler, gpa: Allocator) void {
        if (s.child) |c| _ = proc.finish(c) catch {};
        if (s.env) |*env| env.deinit();
        if (s.path) |p| gpa.free(p);
        s.path = null;
        s.child = null;
        s.env = null;
        s.out.clearRetainingCapacity();
        s.wake_at = 0;
    }

    /// Stops the plugin and frees everything.
    pub fn deinit(s: *Scheduler, gpa: Allocator) void {
        s.stop(gpa);
        if (s.failed) |f| gpa.free(f);
        s.out.deinit(gpa);
    }

    /// The sink for the plugin's stdout.
    fn collect(s: *Scheduler, bytes: []const u8) Allocator.Error!void {
        try s.out.appendSlice(s.gpa_for_out, bytes);
    }

    /// Reports why the plugin stopped scheduling, and stops it.
    fn fail(s: *Scheduler, a: *Agent, comptime format: []const u8, args: anytype) !void {
        const gpa = a.ctx.gpa;
        var event = try a.events.begin("error");
        defer event.deinit();
        const t = event.arena.allocator();
        try event.truncated("error", try t.print("scheduler {s}: " ++ format ++ "; using the built-in scheduler", .{s.path orelse ""} ++ args), 1000);
        try a.events.send(&event);
        if (s.failed) |f| gpa.free(f);
        s.failed = s.path;
        s.path = null;
        s.stop(gpa);
    }

    /// Starts the plugin when a layer has one, or stops it when none has
    /// or it changed. A plugin that failed is not started again. Returns
    /// true when a plugin schedules.
    pub fn open(s: *Scheduler, a: *Agent) !bool {
        const gpa = a.ctx.gpa;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const found: ?struct { []const u8, ?[]const u8 } = for (a.spec.layers) |layer| {
            // A path with a slash, so the spawn does not look it up in PATH.
            const lead = if (std.mem.findScalar(u8, layer.dir, '/') == null) "./" else "";
            const path = std.fmt.bufPrint(&buf, "{s}{s}/scheduler", .{ lead, layer.dir }) catch continue;
            const info = util.stat(a.ctx.io, path) orelse continue;
            if (info.kind == .file and util.isExecutable(a.ctx.io, path)) break .{ path, if (layer.plugin != null) layer.dir else null };
        } else null;
        const path = if (found) |f| f[0] else null;
        if (s.path) |running| if (path == null or !std.mem.eql(u8, path.?, running)) s.stop(gpa);
        if (path == null or (s.failed != null and std.mem.eql(u8, path.?, s.failed.?))) return s.child != null;
        if (s.child != null) return true;
        s.path = try gpa.dupe(u8, path.?);
        s.env = try tool_exec.environ(a, found.?[1], a.depth);
        s.gpa_for_out = gpa;
        s.child = try proc.start(a.ctx, .{
            .argv = &.{s.path.?},
            .environ = &s.env.?,
            .open_stdin = true,
            .keep_on_interrupt = true,
            .stdout = .init(s, collect),
            .stderr = .init(&s.unused, discard),
        });
        if (s.child.?.result.spawn_error != null) try s.fail(a, "could not start it", .{});
        return s.child != null;
    }

    /// Sends one message as a line.
    fn send(s: *Scheduler, gpa: Allocator, message: json.Value) Allocator.Error!void {
        const c = s.child orelse return;
        const line = try json.stringify(gpa, message);
        defer gpa.free(line);
        try c.write(line);
        try c.write("\n");
    }

    /// Sends {"ready": {id, name, keys}}: a call is in the queue.
    pub fn ready(s: *Scheduler, gpa: Allocator, id: []const u8, name: []const u8, call_keys: ?json.Value) Allocator.Error!void {
        if (s.child == null) return;
        const line = try std.fmt.allocPrint(gpa, "{{\"ready\":{{\"id\":{f},\"name\":{f},\"keys\":{f}}}}}\n", .{ json.fmt(.{ .string = id }), json.fmt(.{ .string = name }), json.fmt(call_keys orelse .null) });
        defer gpa.free(line);
        try s.child.?.write(line);
    }

    /// Sends {"done": {id, secs, is_error, backoff}}: a call ended.
    pub fn done(s: *Scheduler, gpa: Allocator, id: []const u8, secs: f64, is_error: bool, backoff: ?json.Value) Allocator.Error!void {
        if (s.child == null) return;
        const line = try std.fmt.allocPrint(gpa, "{{\"done\":{{\"id\":{f},\"secs\":{f},\"is_error\":{},\"backoff\":{f}}}}}\n", .{ json.fmt(.{ .string = id }), json.fmt(json.number(secs)), is_error, json.fmt(backoff orelse .null) });
        defer gpa.free(line);
        try s.child.?.write(line);
    }

    /// The seconds until the plugin's tick is due, at most `max`.
    pub fn wait(s: *const Scheduler, a: *const Agent, max: f64) f64 {
        if (s.child == null or s.wake_at == 0) return max;
        return std.math.clamp(s.wake_at - unixNow(a), 0, max);
    }

    /// Reads one line from the plugin into `start` and `results`. Returns
    /// false when the line is not a message arx knows.
    fn read(s: *Scheduler, t: Allocator, line: []const u8, start: *json.Value, results: *json.Value) Allocator.Error!bool {
        const m = try json.parseObject(t, line) orelse return false;
        const ids = json.field(m, "start");
        const wake = json.field(m, "wake_at");
        const result = json.field(m, "result");
        if (ids == null and wake == null and result == null) return false;
        if (ids != null and !keys.valid(ids.?)) return false; // a list of strings, as keys are
        if (wake != null and json.asNumber(wake.?) == null) return false;
        const id = json.str(result, "id");
        const text = json.str(result, "text");
        if (result != null and (id == null or text == null)) return false;
        for (json.items(ids)) |v| try start.array.append(v);
        if (wake) |w| s.wake_at = json.asNumber(w).?;
        if (result != null) try json.putString(t, results, id.?, text.?);
        return true;
    }

    /// Reads what the plugin printed: adds the ids of {"start": [...]} to
    /// the list `start` and each {"result": {id, text}} to the object
    /// `results` (id -> text), in `t`, and keeps {"wake_at"}. Sends
    /// {"tick": <unix secs>} when it is due.
    pub fn poll(s: *Scheduler, a: *Agent, t: Allocator, start: *json.Value, results: *json.Value) !void {
        if (s.child == null) return;
        while (std.mem.findScalar(u8, s.out.items, '\n')) |nl| {
            const line = try t.dupe(u8, s.out.items[0..nl]);
            s.out.replaceRangeAssumeCapacity(0, nl + 1, &.{});
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            if (!try s.read(t, line, start, results)) return s.fail(a, "printed a bad line: {s}", .{util.cutPrefix(line, 200)});
        }
        if (s.child.?.done) return s.fail(a, "it exited", .{});
        const now = unixNow(a);
        if (s.wake_at > 0 and now >= s.wake_at) {
            s.wake_at = 0;
            var tick = json.object();
            try json.put(t, &tick, "tick", json.number(now));
            try s.send(a.ctx.gpa, tick);
        }
    }
};

/// The wall clock in unix seconds, as the protocol uses.
fn unixNow(a: *const Agent) f64 {
    return @as(f64, @floatFromInt(util.unixMillis(a.ctx.io))) / 1000;
}
