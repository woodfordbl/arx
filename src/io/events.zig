//! events.zig: the event stream, arx's plugin API. One JSON line per event,
//! {"v":1,"t":...,"session":...,"depth":0,"turn":7,"type":...}, written to
//! the session's events.jsonl, the --events target and observers. arx is
//! the only writer. Observer pipes are non-blocking: a slow observer loses
//! events, never the run.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const sys = @import("../base/sys.zig");
const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const Context = @import("../base/context.zig").Context;
const View = @import("render.zig").View;

/// The most observers a session can start.
pub const max_observers = 8;

/// Model text is batched into one model.delta event per this many seconds.
const delta_seconds = 0.05;

/// One event being built. Free it with `deinit` after sending it.
pub const Event = struct {
    arena: std.heap.ArenaAllocator,
    value: json.Value,

    /// Frees the event.
    pub fn deinit(e: *Event) void {
        e.arena.deinit();
    }

    /// Sets a field. `value` must live in this event's arena or longer.
    pub fn put(e: *Event, key: []const u8, value: json.Value) Allocator.Error!void {
        try json.put(e.arena.allocator(), &e.value, key, value);
    }

    /// Sets a string field to a copy of `s`.
    pub fn str(e: *Event, key: []const u8, s: []const u8) Allocator.Error!void {
        try json.putString(e.arena.allocator(), &e.value, key, s);
    }

    /// Sets a string field to `s` cut to `max` bytes ("" when null).
    pub fn truncated(e: *Event, key: []const u8, s: ?[]const u8, max: usize) Allocator.Error!void {
        try e.put(key, .{ .string = try util.truncate(e.arena.allocator(), s orelse "", max) });
    }

    /// Sets an integer field.
    pub fn int(e: *Event, key: []const u8, n: i64) Allocator.Error!void {
        try e.put(key, .{ .integer = n });
    }

    /// Sets a number field.
    pub fn num(e: *Event, key: []const u8, n: f64) Allocator.Error!void {
        try e.put(key, json.number(n));
    }

    /// Sets a boolean field.
    pub fn boolean(e: *Event, key: []const u8, b: bool) Allocator.Error!void {
        try e.put(key, .{ .bool = b });
    }
};

/// An observer: `sh -c command` reading the stream on its stdin.
const Observer = struct {
    /// The write end of its stdin pipe, or -1 once it went away.
    fd: sys.fd_t,
    pid: sys.pid_t,
};

/// Where events go and how they are shown.
pub const Events = struct {
    ctx: *const Context,
    /// The session's events.jsonl, or -1.
    fd: sys.fd_t = -1,
    /// The --events target (a path, stdout or fd:N), or -1.
    extra_fd: sys.fd_t = -1,
    view: View,
    session: []const u8 = "",
    /// 0 for the top-level agent, 1 for its subagents, ...
    depth: i64 = 0,
    turn: i64 = 0,
    /// Model text not yet sent as a model.delta event.
    delta_text: std.ArrayList(u8) = .empty,
    delta_time: f64 = 0,
    observers: [max_observers]Observer = undefined,
    observer_count: usize = 0,
    /// Events a slow observer missed.
    dropped: i64 = 0,

    /// An event stream with no sinks yet.
    pub fn init(ctx: *const Context) Events {
        return .{ .ctx = ctx, .view = .{ .io = ctx.io, .version = ctx.version } };
    }

    /// Opens the session file and the optional --events target ("-" for
    /// stdout, "fd:N", or a path). Fails only when `extra` cannot be opened.
    pub fn open(e: *Events, session_file: ?[]const u8, extra: ?[]const u8) error{BadTarget}!void {
        if (session_file) |path| e.fd = openTarget(path) orelse -1;
        e.view.color = e.view.enabled and sys.isatty(2) and e.ctx.getenv("NO_COLOR") == null;
        if (extra) |where| e.extra_fd = openTarget(where) orelse return error.BadTarget;
    }

    /// A new event with the fields every event has.
    pub fn begin(e: *Events, kind: []const u8) Allocator.Error!Event {
        var ev: Event = .{ .arena = .init(e.ctx.gpa), .value = json.object() };
        errdefer ev.deinit();
        var time: [24]u8 = undefined;
        try ev.int("v", 1);
        try ev.str("t", util.isoTime(e.ctx.io, &time));
        try ev.str("session", e.session);
        try ev.int("depth", e.depth);
        try ev.int("turn", e.turn);
        try ev.str("type", kind);
        return ev;
    }

    /// Writes `ev` to every sink and shows it. Pending model text goes
    /// first so the stream stays in order.
    pub fn send(e: *Events, ev: *const Event) Allocator.Error!void {
        try e.flush();
        try e.writeEvent(ev.value);
        if (e.view.enabled) e.view.event(ev.value, false);
    }

    /// Builds and sends an event of `kind` with no other fields.
    pub fn sendPlain(e: *Events, kind: []const u8) Allocator.Error!void {
        var ev = try e.begin(kind);
        defer ev.deinit();
        try e.send(&ev);
    }

    /// Streams model text: shows it at once, and batches it into model.delta
    /// events about every 50 ms.
    pub fn delta(e: *Events, text: []const u8) Allocator.Error!void {
        if (e.view.enabled) e.view.text(e.depth, text);
        try e.delta_text.appendSlice(e.ctx.gpa, text);
        const t = util.now(e.ctx.io);
        if (t - e.delta_time > delta_seconds or e.delta_text.items.len > 1024) {
            try e.flush();
            e.delta_time = t;
        }
    }

    /// Sends any batched model text now.
    pub fn flush(e: *Events) Allocator.Error!void {
        if (e.delta_text.items.len == 0) return;
        var ev = try e.begin("model.delta");
        defer ev.deinit();
        try ev.str("text", e.delta_text.items);
        e.delta_text.clearRetainingCapacity();
        try e.writeEvent(ev.value);
    }

    /// Passes a subagent's event line (already a complete event with its
    /// own depth) through to our sinks and shows it.
    pub fn forward(e: *Events, line: []const u8) Allocator.Error!void {
        try e.flush();
        e.writeLine(line);
        if (line.len == 0 or line[line.len - 1] != '\n') e.writeLine("\n");
        if (!e.view.enabled) return;
        var arena: std.heap.ArenaAllocator = .init(e.ctx.gpa);
        defer arena.deinit();
        if (try json.parseObject(arena.allocator(), line)) |v| e.view.event(v, true);
    }

    /// Starts `sh -c command` with the event stream on its stdin and
    /// `environ` as its environment.
    pub fn addObserver(e: *Events, command: []const u8, environ: *const Environ.Map) void {
        if (e.observer_count >= max_observers) return;
        const fds = sys.pipe() catch return;
        defer sys.close(fds[0]);
        const child = std.process.spawn(e.ctx.io, .{
            .argv = &.{ "sh", "-c", command },
            .environ_map = environ,
            .stdin = .{ .file = .{ .handle = fds[0], .flags = .{ .nonblocking = false } } },
        }) catch {
            sys.close(fds[1]);
            return;
        };
        sys.setNonblocking(fds[1]);
        e.observers[e.observer_count] = .{ .fd = fds[1], .pid = child.id.? };
        e.observer_count += 1;
    }

    /// Flushes, closes the sinks, and gives each observer up to a second to
    /// finish.
    pub fn close(e: *Events) void {
        e.flush() catch {};
        const observers = e.observers[0..e.observer_count];
        for (observers) |*o| if (o.fd >= 0) sys.close(o.fd);
        for (observers) |o| {
            for (0..100) |_| {
                if (sys.tryWait(o.pid) != null) break;
                util.sleepSeconds(e.ctx.io, 0.01);
            }
        }
        if (e.fd >= 0) sys.close(e.fd);
        if (e.extra_fd >= 0) sys.close(e.extra_fd);
        e.fd = -1;
        e.extra_fd = -1;
        e.observer_count = 0;
        e.delta_text.deinit(e.ctx.gpa);
        e.delta_text = .empty;
    }

    /// Serializes an event as one line and writes it.
    fn writeEvent(e: *Events, value: json.Value) Allocator.Error!void {
        var out: std.Io.Writer.Allocating = .init(e.ctx.gpa);
        defer out.deinit();
        json.write(&out.writer, value, .compact) catch return error.OutOfMemory;
        out.writer.writeByte('\n') catch return error.OutOfMemory;
        e.writeLine(out.written());
    }

    /// Writes one line to every sink.
    fn writeLine(e: *Events, line: []const u8) void {
        if (e.fd >= 0) sys.writeAll(e.fd, line) catch {};
        if (e.extra_fd >= 0) sys.writeAll(e.extra_fd, line) catch {};
        for (e.observers[0..e.observer_count]) |*o| {
            if (o.fd < 0) continue;
            const written = sys.writeSome(o.fd, line) catch {
                sys.close(o.fd);
                o.fd = -1;
                continue;
            };
            if (written != line.len) e.dropped += 1;
        }
    }
};

/// Opens an event target: "-" (stdout), "fd:N", or a file to append to.
/// The descriptor is close-on-exec, so tools do not inherit it.
fn openTarget(where: []const u8) ?sys.fd_t {
    if (std.mem.eql(u8, where, "-")) return sys.dup(1);
    if (std.mem.startsWith(u8, where, "fd:")) {
        const fd = std.fmt.parseInt(sys.fd_t, where[3..], 10) catch return null;
        if (fd < 0 or !sys.isOpen(fd)) return null;
        sys.setCloexec(fd);
        return fd;
    }
    return sys.openAppend(where) catch null;
}
