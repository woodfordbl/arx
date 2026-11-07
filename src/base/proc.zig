//! proc.zig: the process runner behind every tool, hook, curl call and
//! subagent. Each child starts in its own process group with pipes made
//! here; one poll() loop serves many children at once: it feeds stdin,
//! drains stdout, stderr and an optional side pipe (subagent events), and
//! enforces each timeout and Ctrl-C on the child's whole group: SIGTERM,
//! then SIGKILL after a grace period. `run` is the same loop for one child.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const File = std.Io.File;

const sys = @import("sys.zig");
const util = @import("util.zig");
const Context = @import("context.zig").Context;

/// Seconds between SIGTERM and SIGKILL when a child is stopped.
const kill_grace_seconds = 3.0;

/// How long to keep reading after the child exits, for output that its
/// background children still hold open.
const drain_seconds = 0.2;

/// Receives chunks of a child's output. A sink that runs out of memory
/// stops the child, and `run` returns the error.
pub const Sink = struct {
    context: *anyopaque,
    writeFn: *const fn (context: *anyopaque, bytes: []const u8) Allocator.Error!void,

    /// A sink that calls `f(ptr, bytes)`.
    pub fn init(ptr: anytype, comptime f: fn (@TypeOf(ptr), []const u8) Allocator.Error!void) Sink {
        const wrapper = struct {
            /// Calls `f` with the context cast back to its type.
            fn call(context: *anyopaque, bytes: []const u8) Allocator.Error!void {
                return f(@ptrCast(@alignCast(context)), bytes);
            }
        };
        return .{ .context = ptr, .writeFn = wrapper.call };
    }
};

/// Collects output in memory, keeping the first megabyte.
pub const Collector = struct {
    gpa: Allocator,
    list: std.ArrayList(u8) = .empty,

    /// An empty collector.
    pub fn init(gpa: Allocator) Collector {
        return .{ .gpa = gpa };
    }

    /// Frees the collected output.
    pub fn deinit(c: *Collector) void {
        c.list.deinit(c.gpa);
    }

    /// The sink that appends to this collector.
    pub fn sink(c: *Collector) Sink {
        return .init(c, append);
    }

    /// Keeps `bytes` while under the limit.
    fn append(c: *Collector, bytes: []const u8) Allocator.Error!void {
        if (c.list.items.len < 1 << 20) try c.list.appendSlice(c.gpa, bytes);
    }

    /// The output so far.
    pub fn output(c: *const Collector) []const u8 {
        return c.list.items;
    }
};

/// An extra pipe from the child to us, such as a subagent's event stream.
/// The child gets the write end at the same descriptor number, which the
/// caller passes on in its arguments (`--events fd:N`).
pub const SidePipe = struct {
    fds: [2]sys.fd_t,
    sink: Sink,

    /// Opens the pipe. `run` closes it; fds[1] is the child's end.
    pub fn open(sink: Sink) sys.Error!SidePipe {
        return .{ .fds = try sys.pipe(), .sink = sink };
    }
};

/// What to run and where its input and output go.
pub const Options = struct {
    /// argv[0] is looked up in PATH unless it has a '/'.
    argv: []const []const u8,
    /// stdin data; null means /dev/null.
    stdin: ?[]const u8 = null,
    /// Seconds; 0 means no limit.
    timeout: f64 = 0,
    /// The child's whole environment; null means ours.
    environ: ?*const Environ.Map = null,
    /// Where stdout goes, and stderr too unless `stderr` is set.
    stdout: ?Sink = null,
    /// Where stderr goes, kept apart from stdout.
    stderr: ?Sink = null,
    side: ?SidePipe = null,
    /// stdin stays open for `Child.write` (`stdin` is then ignored).
    open_stdin: bool = false,
    /// Ctrl-C does not stop it (a long-lived helper).
    keep_on_interrupt: bool = false,
};

/// How the child finished.
pub const Result = struct {
    /// Exit code, or 128 + signal number.
    code: u8 = 0,
    /// Killed because it ran past the timeout.
    timed_out: bool = false,
    /// Killed because of Ctrl-C or SIGTERM.
    interrupted: bool = false,
    /// Set when the child could not be started.
    spawn_error: ?anyerror = null,
    secs: f64 = 0,

    /// True when the child started, ran to the end and exited with 0.
    pub fn ok(r: Result) bool {
        return r.spawn_error == null and !r.timed_out and r.code == 0;
    }
};

/// A copy of `base` with `extra` ("KEY", "value") pairs added or replaced.
/// Caller owns the map.
pub fn environWith(gpa: Allocator, base: *const Environ.Map, extra: []const [2][]const u8) Allocator.Error!Environ.Map {
    var map = try base.clone(gpa);
    errdefer map.deinit();
    for (extra) |kv| try map.put(kv[0], kv[1]);
    return map;
}

/// The pipe ends we hold; -1 when closed.
const Pipes = struct {
    in: [2]sys.fd_t = .{ -1, -1 },
    out: [2]sys.fd_t = .{ -1, -1 },
    err: [2]sys.fd_t = .{ -1, -1 },
    side: [2]sys.fd_t = .{ -1, -1 },

    /// Closes every pipe end that is still open.
    fn closeAll(p: *Pipes) void {
        for ([_]*sys.fd_t{ &p.in[0], &p.in[1], &p.out[0], &p.out[1], &p.err[0], &p.err[1], &p.side[0], &p.side[1] }) |fd| closeFd(fd);
    }
};

/// Closes `fd.*` if it is open and marks it closed.
fn closeFd(fd: *sys.fd_t) void {
    if (fd.* >= 0) sys.close(fd.*);
    fd.* = -1;
}

/// Wraps a blocking descriptor for std.process.spawn.
fn asFile(fd: sys.fd_t) File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Reads one chunk from `fd.*` into `sink`; closes it at end of file.
fn pump(fd: *sys.fd_t, sink: ?Sink) Allocator.Error!void {
    var chunk: [65536]u8 = undefined;
    const n = posix.read(fd.*, &chunk) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return closeFd(fd),
    };
    if (n == 0) return closeFd(fd);
    if (sink) |s| try s.writeFn(s.context, chunk[0..n]);
}

/// A started child and the state of its loop. `start` makes one, `poll`
/// runs it, and `finish` frees it.
pub const Child = struct {
    gpa: Allocator,
    io: std.Io,
    opts: Options,
    p: Pipes = .{},
    pid: sys.pid_t = 0,
    /// stdin queued by `write` (Options.open_stdin).
    more: std.ArrayList(u8) = .empty,
    written: usize = 0,
    status: c_int = 0,
    reaped: bool = false,
    killed: bool = false,
    done: bool = false,
    start: f64 = 0,
    deadline: f64 = 0,
    kill_at: f64 = 0,
    drain_until: f64 = 0,
    result: Result = .{},
    sink_error: ?Allocator.Error = null,

    /// Queues `bytes` for the stdin of a child started with `open_stdin`;
    /// `poll` writes them.
    pub fn write(c: *Child, bytes: []const u8) Allocator.Error!void {
        if (c.p.in[1] >= 0) try c.more.appendSlice(c.gpa, bytes);
    }

    /// The stdin bytes still to write.
    fn pending(c: *const Child) []const u8 {
        const data = if (c.opts.open_stdin) c.more.items else c.opts.stdin orelse "";
        return data[@min(c.written, data.len)..];
    }

    /// Writes what the child can take now; closes a fixed stdin once it is
    /// all written.
    fn feed(c: *Child) void {
        const data = c.pending();
        if (data.len > 0) c.written += sys.writeSome(c.p.in[1], data) catch return closeFd(&c.p.in[1]); // gone: stop feeding
        if (c.opts.open_stdin) {
            if (c.written == c.more.items.len) {
                c.more.clearRetainingCapacity();
                c.written = 0;
            }
        } else if (c.pending().len == 0) closeFd(&c.p.in[1]);
    }

    /// Serves the pipe that poll() marked; a sink that runs out of memory
    /// stops the child.
    fn serve(c: *Child, fd: sys.fd_t) void {
        (blk: {
            if (fd == c.p.in[1]) c.feed();
            if (fd == c.p.out[0]) pump(&c.p.out[0], c.opts.stdout) catch |e| break :blk e;
            if (fd == c.p.err[0]) pump(&c.p.err[0], c.opts.stderr) catch |e| break :blk e;
            if (fd == c.p.side[0]) pump(&c.p.side[0], c.opts.side.?.sink) catch |e| break :blk e;
        }) catch |e| {
            c.sink_error = e;
            c.p.closeAll(); // stop reading; check() kills it
        };
    }

    /// Reaps the child, and stops it at its deadline, on Ctrl-C, or when a
    /// sink failed.
    fn check(c: *Child) void {
        if (!c.reaped) if (sys.tryWait(c.pid)) |s| {
            c.status = s;
            c.reaped = true;
            c.drain_until = util.now(c.io) + drain_seconds;
            closeFd(&c.p.in[1]);
        };
        const t = util.now(c.io);
        const stop = sys.isInterrupted() and !c.opts.keep_on_interrupt;
        if (!c.reaped and !c.killed and (c.sink_error != null or stop or (c.deadline > 0 and t > c.deadline))) {
            if (stop) c.result.interrupted = true else c.result.timed_out = c.sink_error == null;
            c.terminate(t);
        } else if (!c.reaped and c.killed and t > c.kill_at) {
            sys.killGroup(c.pid, .KILL);
            c.kill_at = std.math.inf(f64);
        }
        const open = c.p.out[0] >= 0 or c.p.err[0] >= 0 or c.p.side[0] >= 0;
        if (c.reaped and (!open or t >= c.drain_until)) c.done = true;
    }

    /// Sends SIGTERM to the group; SIGKILL follows after the grace period.
    fn terminate(c: *Child, t: f64) void {
        sys.killGroup(c.pid, .TERM);
        c.killed = true;
        c.kill_at = t + kill_grace_seconds;
    }
};

/// Starts `opts` and returns at once; `poll` then runs it. `opts.stdin`
/// and the sinks must stay valid until `finish`. A child that could not
/// start comes back done, with `result.spawn_error` set.
pub fn start(ctx: *const Context, opts: Options) Allocator.Error!*Child {
    const c = try ctx.gpa.create(Child);
    c.* = .{ .gpa = ctx.gpa, .io = ctx.io, .opts = opts, .start = util.now(ctx.io) };
    if (opts.side) |side| c.p.side = side.fds;
    spawn(ctx, c) catch |err| {
        c.p.closeAll();
        c.result.spawn_error = err;
        c.result.code = 127;
        c.done = true;
        return c;
    };
    c.deadline = if (opts.timeout > 0) c.start + opts.timeout else 0;
    return c;
}

/// Makes the pipes and starts the child in its own process group.
fn spawn(ctx: *const Context, c: *Child) !void {
    const opts = c.opts;
    const want_in = opts.stdin != null or opts.open_stdin;
    c.p.out = try sys.pipe();
    if (want_in) c.p.in = try sys.pipe();
    if (opts.stderr != null) c.p.err = try sys.pipe();
    const inherit = [_]File{asFile(c.p.side[1])};
    const child = try std.process.spawn(ctx.io, .{
        .argv = opts.argv,
        .environ_map = opts.environ,
        .stdin = if (want_in) .{ .file = asFile(c.p.in[0]) } else .ignore,
        .stdout = .{ .file = asFile(c.p.out[1]) },
        .stderr = .{ .file = asFile(if (opts.stderr != null) c.p.err[1] else c.p.out[1]) },
        .inherit_files = if (opts.side != null) &inherit else &.{},
        .pgid = 0,
    });
    c.pid = child.id.?;
    closeFd(&c.p.in[0]);
    closeFd(&c.p.out[1]);
    closeFd(&c.p.err[1]);
    closeFd(&c.p.side[1]);
    if (c.p.in[1] >= 0) sys.setNonblocking(c.p.in[1]);
}

/// Runs one round of the loop for many children at once: waits up to
/// `max_wait` seconds (at most 0.1) for any of them, feeds stdin, drains
/// output, reaps them, and stops each at its timeout or on Ctrl-C. Call it
/// again until every child is `done`.
pub fn poll(gpa: Allocator, kids: []const *Child, max_wait: f64) Allocator.Error!void {
    const fds = try gpa.alloc(posix.pollfd, 4 * kids.len + 1);
    defer gpa.free(fds);
    const owner = try gpa.alloc(usize, 4 * kids.len + 1);
    defer gpa.free(owner);
    var n: usize = 0;
    var wait = @min(max_wait, 0.1); // see exits and Ctrl-C
    for (kids, 0..) |c, k| {
        if (c.done) continue;
        const ends = [_]sys.fd_t{ c.p.in[1], c.p.out[0], c.p.err[0], c.p.side[0] };
        for (ends, 0..) |fd, i| {
            if (fd < 0 or (i == 0 and c.opts.open_stdin and c.pending().len == 0)) continue;
            fds[n] = .{ .fd = fd, .events = if (i == 0) posix.POLL.OUT else posix.POLL.IN, .revents = 0 };
            owner[n] = k;
            n += 1;
        }
        if (c.reaped) wait = @min(wait, c.drain_until - util.now(c.io));
    }
    const wait_ms: i32 = if (n > 0) @intFromFloat(@max(wait, 0) * 1000 + 1) else 1;
    const ready = posix.poll(fds[0..n], wait_ms) catch 0;
    if (ready > 0) for (fds[0..n], owner[0..n]) |e, k| if (e.revents != 0) kids[k].serve(e.fd);
    for (kids) |c| if (!c.done) c.check();
}

/// Stops the child if it still runs (SIGTERM, then SIGKILL after the grace
/// period), waits for it, and frees it. Fails only when a sink ran out of
/// memory.
pub fn finish(c: *Child) Allocator.Error!Result {
    const gpa = c.gpa;
    defer gpa.destroy(c);
    defer c.more.deinit(gpa);
    if (!c.done and !c.killed) {
        closeFd(&c.p.in[1]);
        c.terminate(util.now(c.io));
    }
    while (!c.done) try poll(gpa, &.{c}, 0.1);
    c.p.closeAll();
    if (c.result.spawn_error != null) return c.result;
    if (c.killed) sys.killGroup(c.pid, .KILL); // anything left in the group
    if (c.sink_error) |e| return e;
    c.result.secs = util.now(c.io) - c.start;
    c.result.code = sys.exitCode(c.status);
    return c.result;
}

/// Runs `opts` and waits for the child. The child gets its own process
/// group, so a timeout or Ctrl-C stops it and everything it started. Fails
/// only when a sink runs out of memory (the child is then stopped too).
pub fn run(ctx: *const Context, opts: Options) Allocator.Error!Result {
    const c = try start(ctx, opts);
    while (!c.done) poll(ctx.gpa, &.{c}, 0.1) catch |err| {
        _ = finish(c) catch {};
        return err;
    };
    return finish(c);
}

test "run kills the group at the timeout" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var env: Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    const ctx: Context = .{ .gpa = std.testing.allocator, .io = threaded.io(), .environ = &env, .self_path = "", .version = "test" };
    const r = try run(&ctx, .{ .argv = &.{ "sh", "-c", "sleep 5 & sleep 5" }, .timeout = 0.2, .environ = &env });
    try std.testing.expect(r.timed_out);
    try std.testing.expect(r.secs < 4);
}
