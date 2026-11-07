//! util.zig: helpers every layer uses: exit codes, durations and sizes,
//! UTF-8 cleaning and cutting, paths, files and time.

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

const sys = @import("sys.zig");
const Context = @import("context.zig").Context;

/// Process exit codes. They are also the "status" of a session.
pub const Exit = enum(u8) {
    done = 0,
    @"error" = 1,
    usage = 2,
    cap = 3,
    auth = 4,
    interrupted = 130,

    /// The session status for this exit code.
    pub fn status(code: Exit) []const u8 {
        return switch (code) {
            .done => "done",
            .cap => "cap",
            .auth => "auth",
            .interrupted => "interrupted",
            .@"error", .usage => "error",
        };
    }
};

/// What went wrong, the way strerror() would say it.
pub fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.InvalidExe => "Exec format error",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        error.OutOfMemory => "Cannot allocate memory",
        else => @errorName(err),
    };
}

/// Parses the longest leading decimal number in `s`, the way strtod does
/// for plain decimals. Returns the value and the rest of the text.
pub fn leadingNumber(s: []const u8) ?struct { value: f64, rest: []const u8 } {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    const start = i;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    var digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return null;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        const exp_start = j;
        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
        if (j > exp_start) i = j;
    }
    const value = std.fmt.parseFloat(f64, s[start..i]) catch return null;
    return .{ .value = value, .rest = s[i..] };
}

/// Parses "30", "10s", "250ms", "5m" or "1h" into seconds.
pub fn parseDuration(s: []const u8) ?f64 {
    const n = leadingNumber(s) orelse return null;
    if (n.value < 0) return null;
    const unit = std.mem.trimStart(u8, n.rest, " ");
    if (unit.len == 0 or std.mem.eql(u8, unit, "s")) return n.value;
    if (std.mem.eql(u8, unit, "ms")) return n.value / 1000;
    if (std.mem.eql(u8, unit, "m")) return n.value * 60;
    if (std.mem.eql(u8, unit, "h")) return n.value * 3600;
    return null;
}

/// Parses "2048", "2kb" or "1mb" (any case; powers of 1024) into bytes.
pub fn parseSize(s: []const u8) ?u64 {
    const n = leadingNumber(s) orelse return null;
    if (n.value < 0) return null;
    const unit = std.mem.trimStart(u8, n.rest, " ");
    const scale: f64 = if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "b"))
        1
    else if (std.ascii.eqlIgnoreCase(unit, "kb") or std.ascii.eqlIgnoreCase(unit, "k"))
        1024
    else if (std.ascii.eqlIgnoreCase(unit, "mb") or std.ascii.eqlIgnoreCase(unit, "m"))
        1024 * 1024
    else if (std.ascii.eqlIgnoreCase(unit, "gb") or std.ascii.eqlIgnoreCase(unit, "g"))
        1024 * 1024 * 1024
    else
        return null;
    const bytes = n.value * scale;
    if (!(bytes < 1.8e19)) return null;
    return @intFromFloat(bytes);
}

/// The length of the UTF-8 sequence at the start of `s`, or 0 if it is not
/// a valid one.
fn utf8SequenceLength(s: []const u8) usize {
    const len: usize = switch (s[0]) {
        0xC2...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF4 => 4,
        else => return 0,
    };
    if (len > s.len) return 0;
    for (s[1..len]) |b| if (b & 0xC0 != 0x80) return 0;
    return len;
}

/// Returns a copy of `s` that is valid UTF-8 with no NULs: bad bytes become
/// U+FFFD and NULs become '?'. Tool output is cleaned this way before it goes
/// into JSON. Caller owns the result.
pub fn utf8Clean(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, s.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0) {
            try out.append(gpa, '?');
            i += 1;
        } else if (s[i] < 0x80) {
            try out.append(gpa, s[i]);
            i += 1;
        } else {
            const len = utf8SequenceLength(s[i..]);
            if (len == 0) {
                try out.appendSlice(gpa, "\u{FFFD}");
                i += 1;
            } else {
                try out.appendSlice(gpa, s[i .. i + len]);
                i += len;
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The longest prefix of `s` that is at most `max` bytes and does not split
/// a UTF-8 character.
pub fn cutPrefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
    return s[0..n];
}

/// Returns `s` cut to at most `max` bytes at a character boundary, with "…"
/// appended when it was cut. Caller owns the result.
pub fn truncate(gpa: Allocator, s: []const u8, max: usize) Allocator.Error![]u8 {
    if (s.len <= max) return gpa.dupe(u8, s);
    return std.mem.concat(gpa, u8, &.{ cutPrefix(s, max), "…" });
}

/// `b` resolved against directory `a`: `b` itself when it is absolute or
/// `a` is empty or ".". Caller owns the result.
pub fn pathJoin(gpa: Allocator, a: ?[]const u8, b: []const u8) Allocator.Error![]u8 {
    const dir = a orelse "";
    if ((b.len > 0 and b[0] == '/') or dir.len == 0 or std.mem.eql(u8, dir, ".")) return gpa.dupe(u8, b);
    return std.mem.concat(gpa, u8, &.{ dir, "/", b });
}

/// Everything before the last '/' of `path`: "." when there is none, "/"
/// for a path in the root.
pub fn dirName(path: []const u8) []const u8 {
    const slash = std.mem.findScalarLast(u8, path, '/') orelse return ".";
    if (slash == 0) return "/";
    return path[0..slash];
}

/// Everything after the last '/' of `path`.
pub fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.findScalarLast(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

/// arx's config directory: $ARX_CONFIG_DIR, else $XDG_CONFIG_HOME/arx, else
/// ~/.config/arx. It holds config.yaml (the user's defaults) and, outside
/// macOS, the 0600 credentials file. Caller owns the result.
pub fn configDir(ctx: *const Context, gpa: Allocator) Allocator.Error![]u8 {
    if (ctx.getenvNonEmpty("ARX_CONFIG_DIR")) |dir| return gpa.dupe(u8, dir);
    if (ctx.getenvNonEmpty("XDG_CONFIG_HOME")) |xdg| return std.mem.concat(gpa, u8, &.{ xdg, "/arx" });
    return std.mem.concat(gpa, u8, &.{ ctx.getenv("HOME") orelse ".", "/.config/arx" });
}

/// Reads a whole file, or returns null if it cannot be read. Caller owns
/// the result.
pub fn readFile(io: Io, gpa: Allocator, path: []const u8) Allocator.Error!?[]u8 {
    return Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
}

/// What stat() says about a file, for hot reload.
pub const FileInfo = struct {
    /// Modification time in nanoseconds since the epoch.
    mtime: i64,
    size: i64,
    mode: u32,
    kind: std.Io.File.Kind,
};

/// stat() of `path`, following symlinks, or null when it is missing.
pub fn stat(io: Io, path: []const u8) ?FileInfo {
    const st = Dir.cwd().statFile(io, path, .{}) catch return null;
    return .{
        .mtime = @truncate(st.mtime.nanoseconds),
        .size = @intCast(st.size),
        .mode = @intCast(st.permissions.toMode()),
        .kind = st.kind,
    };
}

/// True when `path` exists and this process may execute it.
pub fn isExecutable(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

/// True when `path` exists and this process may read it.
pub fn isReadable(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{ .read = true }) catch return false;
    return true;
}

/// The canonical absolute path of `path`, or null. Caller owns the result.
pub fn realPath(io: Io, gpa: Allocator, path: []const u8) Allocator.Error!?[]u8 {
    const z = Dir.cwd().realPathFileAlloc(io, path, gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer gpa.free(z);
    return try gpa.dupe(u8, z);
}

/// Replaces `path` atomically (temp file + rename), keeping its file mode so
/// an edited tool stays executable. New files get mode 0644.
pub fn writeFileAtomic(io: Io, gpa: Allocator, path: []const u8, data: []const u8) !void {
    const mode: u32 = if (stat(io, path)) |info| info.mode & 0o7777 else 0o644;
    const tmp = try gpa.print("{s}.tmp{d}", .{ path, sys.getpid() });
    defer gpa.free(tmp);
    const cwd = Dir.cwd();
    const permissions: std.Io.File.Permissions = .fromMode(@intCast(mode));
    {
        var file = try cwd.createFile(io, tmp, .{ .permissions = permissions });
        defer file.close(io);
        errdefer cwd.deleteFile(io, tmp) catch {};
        try file.writePositionalAll(io, data, 0);
        try file.setPermissions(io, permissions); // the umask does not apply
    }
    cwd.rename(tmp, cwd, path, io) catch |err| {
        cwd.deleteFile(io, tmp) catch {};
        return err;
    };
}

/// Appends `data` to `path`, creating it if needed.
pub fn appendFile(path: []const u8, data: []const u8) sys.Error!void {
    const fd = try sys.openAppend(path);
    defer sys.close(fd);
    try sys.writeAll(fd, data);
}

/// The entries of `dir` that do not start with '.', sorted so that lists
/// stay stable between runs. A missing folder has none. Everything is
/// allocated in `arena`.
pub fn listNames(io: Io, arena: Allocator, dir_path: []const u8) Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var dir = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len > 0 and entry.name[0] != '.') try names.append(arena, try arena.dupe(u8, entry.name));
    }
    sortStrings(names.items);
    return names.items;
}

/// Sorts short lists of strings in place. Folder listings hold a few dozen
/// names, so an insertion sort is plenty, and much smaller than the
/// generic block sort.
pub fn sortStrings(items: [][]const u8) void {
    if (items.len < 2) return;
    for (1..items.len) |i| {
        const item = items[i];
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, item, items[j - 1])) : (j -= 1) items[j] = items[j - 1];
        items[j] = item;
    }
}

/// Monotonic time in seconds.
pub fn now(io: Io) f64 {
    const t = Io.Timestamp.now(io, .awake);
    return @as(f64, @floatFromInt(t.nanoseconds)) / 1e9;
}

/// Wall-clock time in milliseconds since the epoch.
pub fn unixMillis(io: Io) i64 {
    const t = Io.Timestamp.now(io, .real);
    return @intCast(@divFloor(t.nanoseconds, std.time.ns_per_ms));
}

/// The current UTC time as "2026-10-30T22:14:03.120Z".
pub fn isoTime(io: Io, out: *[24]u8) []const u8 {
    const ms = unixMillis(io);
    const secs: u64 = @intCast(@divFloor(ms, 1000));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    return std.mem.print(out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
        @as(u64, @intCast(@mod(ms, 1000))),
    }) catch unreachable;
}

/// Sleeps for `seconds` in 100 ms steps, returning early on an interrupt.
pub fn sleepSeconds(io: Io, seconds: f64) void {
    var left = seconds;
    while (left > 0 and !sys.isInterrupted()) {
        const step = @min(left, 0.1);
        io.sleep(.fromNanoseconds(@intFromFloat(step * 1e9)), .awake) catch {};
        left -= step;
    }
}

test "durations and sizes" {
    try std.testing.expectEqual(@as(?f64, 30), parseDuration("30"));
    try std.testing.expectEqual(@as(?f64, 0.25), parseDuration("250ms"));
    try std.testing.expectEqual(@as(?f64, 300), parseDuration("5m"));
    try std.testing.expectEqual(@as(?f64, 3600), parseDuration("1 h"));
    try std.testing.expectEqual(@as(?f64, null), parseDuration("5x"));
    try std.testing.expectEqual(@as(?f64, null), parseDuration("-1"));
    try std.testing.expectEqual(@as(?u64, 2048), parseSize("2kb"));
    try std.testing.expectEqual(@as(?u64, 1048576), parseSize("1MB"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("lots"));
}

test "utf8Clean replaces bad bytes and NULs" {
    const gpa = std.testing.allocator;
    const out = try utf8Clean(gpa, "a\x00b\xffc\u{e9}");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a?b\u{FFFD}c\u{e9}", out);
}

test "truncate keeps whole characters" {
    const gpa = std.testing.allocator;
    const out = try truncate(gpa, "h\u{e9}llo", 2);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("h…", out);
}
