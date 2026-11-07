//! proc.zig: the process runner behind every tool, hook, curl call and
//! subagent. The child starts in its own process group with pipes made
//! here; one poll() loop feeds its stdin, drains its stdout, stderr and an
//! optional side pipe (subagent events), and enforces the timeout on the
//! whole group: SIGTERM, then SIGKILL after a grace period.

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

/// Receives chunks of a child's output.
pub const Sink = struct {
    context: *anyopaque,
    writeFn: *const fn (context: *anyopaque, bytes: []const u8) void,

    /// A sink that calls `f(ptr, bytes)`.
    pub fn init(ptr: anytype, comptime f: fn (@TypeOf(ptr), []const u8) void) Sink {
        const Ptr = @TypeOf(ptr);
        const wrapper = struct {
            /// Calls `f` with the context cast back to its type.
            fn call(context: *anyopaque, bytes: []const u8) void {
                f(@as(Ptr, @ptrCast(@alignCast(context))), bytes);
            }
        };
        return .{ .context = ptr, .writeFn = wrapper.call };
    }

    /// Passes a chunk to the sink.
    fn write(s: Sink, bytes: []const u8) void {
        s.writeFn(s.context, bytes);
    }
};

/// Collects output in memory, keeping at most `limit` bytes.
pub const Collector = struct {
    gpa: Allocator,
    list: std.ArrayList(u8) = .empty,
    limit: usize = 1 << 20,
    /// Set when memory ran out; the output is then incomplete.
    failed: bool = false,

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
    fn append(c: *Collector, bytes: []const u8) void {
        if (c.list.items.len >= c.limit) return;
        c.list.appendSlice(c.gpa, bytes) catch {
            c.failed = true;
        };
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

    /// Opens the pipe. `run` closes it.
    pub fn open(sink: Sink) sys.Error!SidePipe {
        return .{ .fds = try sys.pipe(), .sink = sink };
    }

    /// The descriptor number the child writes to.
    pub fn childFd(p: SidePipe) sys.fd_t {
        return p.fds[1];
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

/// Describes why a program could not be started, like strerror() would.
pub fn describeSpawnError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.InvalidExe => "Exec format error",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "Too many open files or processes",
        error.OutOfMemory => "Cannot allocate memory",
        else => @errorName(err),
    };
}

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
fn pump(fd: *sys.fd_t, sink: ?Sink) void {
    var chunk: [65536]u8 = undefined;
    const n = posix.read(fd.*, &chunk) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return closeFd(fd),
    };
    if (n == 0) return closeFd(fd);
    if (sink) |s| s.write(chunk[0..n]);
}

/// Runs `opts` and waits for the child. The child gets its own process
/// group, so a timeout or Ctrl-C stops it and everything it started.
pub fn run(ctx: *const Context, opts: Options) Result {
    const io = ctx.io;
    var result: Result = .{};
    var p: Pipes = .{};
    defer p.closeAll();
    if (opts.side) |side| p.side = side.fds;

    p.out = sys.pipe() catch |err| return failed(&result, err);
    if (opts.stdin != null) p.in = sys.pipe() catch |err| return failed(&result, err);
    if (opts.stderr != null) p.err = sys.pipe() catch |err| return failed(&result, err);

    const start = util.now(io);
    const inherit = [_]File{asFile(p.side[1])};
    const child = std.process.spawn(io, .{
        .argv = opts.argv,
        .environ_map = opts.environ,
        .stdin = if (opts.stdin != null) .{ .file = asFile(p.in[0]) } else .ignore,
        .stdout = .{ .file = asFile(p.out[1]) },
        .stderr = .{ .file = asFile(if (opts.stderr != null) p.err[1] else p.out[1]) },
        .inherit_files = if (opts.side != null) &inherit else &.{},
        .pgid = 0,
    }) catch |err| return failed(&result, err);
    const pid = child.id.?;
    closeFd(&p.in[0]);
    closeFd(&p.out[1]);
    closeFd(&p.err[1]);
    closeFd(&p.side[1]);
    if (p.in[1] >= 0) sys.setNonblocking(p.in[1]);

    const input = opts.stdin orelse "";
    var written: usize = 0;
    var status: c_int = 0;
    var reaped = false;
    var killed = false;
    var kill_at: f64 = 0;
    var drain_until: f64 = 0;
    const deadline: f64 = if (opts.timeout > 0) start + opts.timeout else 0;
    while (true) {
        var fds: [4]posix.pollfd = undefined;
        var n: usize = 0;
        const i_in = addPoll(&fds, &n, p.in[1], posix.POLL.OUT);
        const i_out = addPoll(&fds, &n, p.out[0], posix.POLL.IN);
        const i_err = addPoll(&fds, &n, p.err[0], posix.POLL.IN);
        const i_side = addPoll(&fds, &n, p.side[0], posix.POLL.IN);
        if (reaped and (n == 0 or util.now(io) >= drain_until)) break;
        const wait_ms: i32 = if (reaped) @intFromFloat((drain_until - util.now(io)) * 1000 + 1) else 100;
        if (n > 0) {
            const ready = posix.poll(fds[0..n], wait_ms) catch 0;
            if (ready > 0) {
                if (i_in) |i| if (fds[i].revents != 0) {
                    const w = sys.writeSome(p.in[1], input[written..]) catch std.math.maxInt(usize);
                    if (w == std.math.maxInt(usize)) {
                        closeFd(&p.in[1]);
                    } else {
                        written += w;
                        if (written >= input.len) closeFd(&p.in[1]);
                    }
                };
                if (i_out) |i| if (fds[i].revents != 0) pump(&p.out[0], opts.stdout);
                if (i_err) |i| if (fds[i].revents != 0) pump(&p.err[0], opts.stderr);
                if (i_side) |i| if (fds[i].revents != 0) pump(&p.side[0], if (opts.side) |s| s.sink else null);
            }
        } else {
            io.sleep(.fromMilliseconds(1), .awake) catch {}; // all pipes closed: wait for the exit
        }
        if (!reaped) {
            if (sys.tryWait(pid)) |s| {
                status = s;
                reaped = true;
                drain_until = util.now(io) + drain_seconds;
                closeFd(&p.in[1]);
            }
        }
        const t = util.now(io);
        if (!reaped and !killed and (sys.isInterrupted() or (deadline > 0 and t > deadline))) {
            if (sys.isInterrupted()) result.interrupted = true else result.timed_out = true;
            sys.killGroup(pid, .TERM);
            killed = true;
            kill_at = t + kill_grace_seconds;
        } else if (!reaped and killed and t > kill_at) {
            sys.killGroup(pid, .KILL);
            kill_at = std.math.inf(f64);
        }
    }
    p.closeAll();
    if (!reaped) status = sys.wait(pid);
    if (killed) sys.killGroup(pid, .KILL); // anything left in the group
    result.secs = util.now(io) - start;
    result.code = sys.exitCode(status);
    return result;
}

/// The result for a child that could not be started.
fn failed(result: *Result, err: anyerror) Result {
    result.spawn_error = err;
    result.code = 127;
    return result.*;
}

/// Adds `fd` to the poll set if it is open. Returns its index.
fn addPoll(fds: *[4]posix.pollfd, n: *usize, fd: sys.fd_t, events: i16) ?usize {
    if (fd < 0) return null;
    fds[n.*] = .{ .fd = fd, .events = events, .revents = 0 };
    n.* += 1;
    return n.* - 1;
}

test "run feeds stdin and collects stdout and stderr apart" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var env: Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    const ctx: Context = .{ .gpa = std.testing.allocator, .io = threaded.io(), .environ = &env, .self_path = "", .version = "test" };
    var out: Collector = .init(std.testing.allocator);
    defer out.deinit();
    var err: Collector = .init(std.testing.allocator);
    defer err.deinit();
    const r = run(&ctx, .{
        .argv = &.{ "sh", "-c", "cat; echo oops >&2; exit 3" },
        .stdin = "hello",
        .environ = &env,
        .stdout = out.sink(),
        .stderr = err.sink(),
    });
    try std.testing.expectEqual(@as(u8, 3), r.code);
    try std.testing.expectEqualStrings("hello", out.output());
    try std.testing.expectEqualStrings("oops\n", err.output());
}

test "run kills the group at the timeout" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var env: Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    const ctx: Context = .{ .gpa = std.testing.allocator, .io = threaded.io(), .environ = &env, .self_path = "", .version = "test" };
    const r = run(&ctx, .{ .argv = &.{ "sh", "-c", "sleep 5 & sleep 5" }, .timeout = 0.2, .environ = &env });
    try std.testing.expect(r.timed_out);
    try std.testing.expect(r.secs < 4);
}
