//! sys.zig: the few POSIX calls that std.Io does not cover, kept in one
//! place: append-mode files, raw pipes, non-blocking writes, reaping a child
//! without blocking, signalling a process group, local time, and the
//! interrupt flag that the SIGINT and SIGTERM handlers set.

const std = @import("std");
const posix = std.posix;
const c = std.c;

pub const fd_t = posix.fd_t;
pub const pid_t = posix.pid_t;

/// Set by the SIGINT/SIGTERM handler. Long waits check it and return early.
var interrupted: std.atomic.Value(bool) = .init(false);

/// True once Ctrl-C or SIGTERM arrived.
pub fn isInterrupted() bool {
    return interrupted.load(.monotonic);
}

/// Marks an interrupt again, after a step that had to run without it.
pub fn setInterrupted() void {
    interrupted.store(true, .monotonic);
}

/// Forgets an earlier interrupt, so the next prompt can be interrupted again.
pub fn clearInterrupted() void {
    interrupted.store(false, .monotonic);
}

/// The first Ctrl-C stops the current step; a second one exits at once.
fn onSignal(sig: posix.SIG) callconv(.c) void {
    if (sig == .INT and interrupted.load(.monotonic)) c._exit(130);
    interrupted.store(true, .monotonic);
}

/// Does nothing: a write to a closed pipe then fails with EPIPE, where the
/// default action would kill arx.
fn onPipe(_: posix.SIG) callconv(.c) void {}

/// Installs the SIGINT and SIGTERM handlers, and catches SIGPIPE. No
/// SA_RESTART, so a blocking read returns and the caller can notice the
/// signal. Caught signals go back to their default action in a child after
/// exec, so tools still get the usual SIGPIPE (an ignored one would not).
pub fn installSignals() void {
    var action: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &action, null);
    posix.sigaction(.TERM, &action, null);
    action.handler = .{ .handler = onPipe };
    posix.sigaction(.PIPE, &action, null);
}

/// The calls below fail with this one error; no caller needs more detail.
pub const Error = error{SystemCall};

/// Opens `path` for appending, creating it with mode 0644. The descriptor
/// is close-on-exec, so tools never inherit it.
pub fn openAppend(path: []const u8) Error!fd_t {
    var buf: [posix.PATH_MAX]u8 = undefined;
    if (path.len >= buf.len) return error.SystemCall;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const flags: posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const rc = c.open(buf[0..path.len :0], flags, @as(c_uint, 0o644));
    if (rc < 0) return error.SystemCall;
    return rc;
}

/// Writes all of `bytes` to `fd`, retrying short writes and EINTR.
pub fn writeAll(fd: fd_t, bytes: []const u8) Error!void {
    var rest = bytes;
    while (rest.len > 0) {
        const rc = c.write(fd, rest.ptr, rest.len);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return error.SystemCall;
        }
        rest = rest[@intCast(rc)..];
    }
}

/// One write to a non-blocking descriptor. Returns the bytes written; 0
/// means the pipe is full right now.
pub fn writeSome(fd: fd_t, bytes: []const u8) Error!usize {
    const rc = c.write(fd, bytes.ptr, bytes.len);
    if (rc >= 0) return @intCast(rc);
    return switch (posix.errno(rc)) {
        .AGAIN, .INTR => 0,
        else => error.SystemCall,
    };
}

/// Closes `fd`, ignoring errors (there is nothing useful to do with them).
pub fn close(fd: fd_t) void {
    _ = c.close(fd);
}

/// A pipe with both ends close-on-exec, so only the child it is meant for
/// inherits an end. Index 0 reads, 1 writes.
pub fn pipe() Error![2]fd_t {
    var fds: [2]fd_t = undefined;
    const rc = c.pipe(&fds);
    if (rc != 0) return error.SystemCall;
    _ = setCloexec(fds[0]);
    _ = setCloexec(fds[1]);
    return fds;
}

/// Marks `fd` close-on-exec. Returns false when `fd` is not open.
pub fn setCloexec(fd: fd_t) bool {
    return c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC)) >= 0;
}

/// Makes writes to `fd` return at once instead of waiting for room.
pub fn setNonblocking(fd: fd_t) void {
    const flags = c.fcntl(fd, posix.F.GETFL);
    if (flags < 0) return;
    const nonblock: c_int = @intCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    _ = c.fcntl(fd, posix.F.SETFL, flags | nonblock);
}

/// A duplicate of `fd`, close-on-exec, or null.
pub fn dup(fd: fd_t) ?fd_t {
    const rc = c.dup(fd);
    if (rc < 0) return null;
    _ = setCloexec(rc);
    return rc;
}

/// True when `fd` is a terminal.
pub fn isatty(fd: fd_t) bool {
    return c.isatty(fd) != 0;
}

/// This process's id.
pub fn getpid() pid_t {
    return c.getpid();
}

/// How a child ended: its exit code, or 128 + the signal number.
pub fn exitCode(status: c_int) u8 {
    const s: u32 = @bitCast(status);
    if (posix.W.IFEXITED(s)) return posix.W.EXITSTATUS(s);
    if (posix.W.IFSIGNALED(s)) return @truncate(128 + @backingInt(posix.W.TERMSIG(s)));
    return 1;
}

/// Reaps `pid` if it has exited. Returns its wait status, or null while it
/// is still running.
pub fn tryWait(pid: pid_t) ?c_int {
    var status: c_int = 0;
    const rc = c.waitpid(pid, &status, posix.W.NOHANG);
    if (rc == pid) return status;
    if (rc < 0 and posix.errno(rc) == .CHILD) return 0; // already reaped
    return null;
}

/// Waits for `pid` to exit and returns its wait status.
pub fn wait(pid: pid_t) c_int {
    var status: c_int = 0;
    while (true) {
        const rc = c.waitpid(pid, &status, 0);
        if (rc == pid) return status;
        if (rc < 0 and posix.errno(rc) != .INTR) return 0;
    }
}

/// Sends `sig` to every process in the group led by `pid`.
pub fn killGroup(pid: pid_t, sig: posix.SIG) void {
    posix.kill(-pid, sig) catch {};
}

/// Calendar fields of a moment, in local time.
pub const LocalTime = struct {
    year: u32,
    month: u8, // 1-12
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

/// The C library's struct tm. Darwin, glibc and musl share this layout.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timer: *const c.time_t, result: *Tm) ?*Tm;

/// Converts Unix time to local time, using the system's time zone rules.
pub fn localTime(unix_seconds: i64) LocalTime {
    const t: c.time_t = @intCast(unix_seconds);
    var tm: Tm = undefined;
    if (localtime_r(&t, &tm) == null) return .{ .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 };
    return .{
        .year = @intCast(tm.year + 1900),
        .month = @intCast(tm.mon + 1),
        .day = @intCast(tm.mday),
        .hour = @intCast(tm.hour),
        .minute = @intCast(tm.min),
        .second = @intCast(@min(tm.sec, 59)),
    };
}
