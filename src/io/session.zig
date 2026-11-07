//! session.zig: the files a session leaves under .arx/sessions/<id>/:
//!   transcript.jsonl  every message, with reset markers
//!   events.jsonl      the event stream (events.zig)
//!   meta.json         counters, for --resume
//!   tool-NNNN.out     full tool outputs
//!   inbox             commands from `arx ctl` (note, stop)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

const sys = @import("../base/sys.zig");
const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const Context = @import("../base/context.zig").Context;
const history = @import("history.zig");
const History = history.History;
const Message = history.Message;

/// Where sessions live, relative to the working directory.
const root = ".arx/sessions";

/// An open session.
pub const Session = struct {
    /// Holds `id` and `dir`.
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    /// Absolute, because tools may cd elsewhere.
    dir: []const u8,
    transcript: sys.fd_t = -1,
    inbox_offset: u64 = 0,
    /// The number of the last tool-NNNN.out.
    tool_seq: u32 = 0,
    turns: i64 = 0,
    tokens_in: i64 = 0,
    tokens_out: i64 = 0,
    cost: f64 = 0,

    /// Creates a new session folder. A top-level session (depth 0) also
    /// becomes `last`.
    pub fn create(ctx: *const Context, depth: i64) !Session {
        const io = ctx.io;
        var s: Session = .{ .arena = .init(ctx.gpa), .id = "", .dir = "" };
        errdefer s.arena.deinit();
        const a = s.arena.allocator();
        const t = sys.localTime(@divFloor(util.unixMillis(io), 1000));
        // Microseconds overflow 32 bits; keep the low bits on purpose.
        const micros: u64 = @intFromFloat(util.now(io) * 1e6);
        const r: u32 = @as(u32, @bitCast(sys.getpid())) *% 2654435761 ^ @as(u32, @truncate(micros));
        s.id = try a.print("{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{x:0>4}", .{ t.year, t.month, t.day, t.hour, t.minute, t.second, r & 0xffff });
        const rel = try std.mem.concat(a, u8, &.{ root, "/", s.id });
        try Dir.cwd().createDirPath(io, rel);
        s.dir = (try util.realPath(io, a, rel)) orelse return error.FileNotFound;
        s.transcript = try sys.openAppend(try std.mem.concat(a, u8, &.{ s.dir, "/transcript.jsonl" }));
        if (depth == 0) linkLast(ctx, s.id);
        return s;
    }

    /// Reopens a session (`ref` is an id, "last" or a folder) and rebuilds
    /// its history into `messages`, which must be empty.
    pub fn open(ctx: *const Context, ref: []const u8, messages: *History) !Session {
        var s: Session = .{ .arena = .init(ctx.gpa), .id = "", .dir = "" };
        errdefer s.arena.deinit();
        const a = s.arena.allocator();
        s.dir = (try sessionDir(ctx, a, ref)) orelse return error.FileNotFound;
        s.id = util.baseName(s.dir);
        var scratch: std.heap.ArenaAllocator = .init(ctx.gpa);
        defer scratch.deinit();
        const t = scratch.allocator();
        // Replay the transcript; a {"_reset":true} line starts the history over.
        const transcript = try std.mem.concat(a, u8, &.{ s.dir, "/transcript.jsonl" });
        var lines = std.mem.splitScalar(u8, (try util.readFile(ctx.io, t, transcript)) orelse "", '\n');
        while (lines.next()) |line| {
            const value = try json.parseObject(t, line) orelse continue;
            if (json.boolean(value, "_reset", false)) messages.clear() else try messages.append(try Message.fromValue(ctx.gpa, value));
        }
        const meta = try json.parseObject(t, (try util.readFile(ctx.io, t, try std.mem.concat(t, u8, &.{ s.dir, "/meta.json" }))) orelse "");
        s.turns = json.int(meta, "turns", 0);
        s.tool_seq = @intCast(std.math.clamp(json.int(meta, "tool_seq", 0), 0, std.math.maxInt(u32)));
        s.tokens_in = json.int(meta, "tokens_in", 0);
        s.tokens_out = json.int(meta, "tokens_out", 0);
        s.cost = json.num(meta, "cost", 0);
        // Commands sent while the session was stopped are stale: skip them.
        s.inbox_offset = if (util.stat(ctx.io, try std.mem.concat(t, u8, &.{ s.dir, "/inbox" }))) |info| @intCast(info.size) else 0;
        s.transcript = try sys.openAppend(transcript);
        return s;
    }

    /// Closes the transcript and frees the strings.
    pub fn close(s: *Session) void {
        if (s.transcript >= 0) sys.close(s.transcript);
        s.arena.deinit();
        s.* = undefined;
    }

    /// Appends one message to the transcript, as one line, so a crash loses
    /// at most the current turn.
    pub fn append(s: *Session, gpa: Allocator, message: json.Value) Allocator.Error!void {
        if (s.transcript < 0) return;
        const line = try json.stringify(gpa, message);
        defer gpa.free(line);
        sys.writeAll(s.transcript, line) catch {};
        sys.writeAll(s.transcript, "\n") catch {};
    }

    /// Records that the history was replaced (compaction, a new system
    /// prompt): a reset marker, then every message.
    pub fn reset(s: *Session, gpa: Allocator, messages: *const History) Allocator.Error!void {
        if (s.transcript < 0) return;
        sys.writeAll(s.transcript, "{\"_reset\":true}\n") catch {};
        for (messages.slice()) |m| try s.append(gpa, m.value);
    }

    /// Writes meta.json with the counters and `status`.
    pub fn writeMeta(s: *const Session, ctx: *const Context, status: []const u8) Allocator.Error!void {
        var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var m = json.object();
        try json.putString(a, &m, "id", s.id);
        try json.putString(a, &m, "status", status);
        try json.put(a, &m, "turns", .{ .integer = s.turns });
        try json.put(a, &m, "tool_seq", .{ .integer = s.tool_seq });
        try json.put(a, &m, "tokens_in", .{ .integer = s.tokens_in });
        try json.put(a, &m, "tokens_out", .{ .integer = s.tokens_out });
        try json.put(a, &m, "cost", json.number(s.cost));
        const text = try json.stringifyPretty(a, m);
        const path = try std.mem.concat(a, u8, &.{ s.dir, "/meta.json" });
        util.writeFileAtomic(ctx.io, a, path, text) catch {};
    }

    /// The inbox commands added since the last call. A partial last line
    /// waits for the next call. The values live in `arena`.
    pub fn readInbox(s: *Session, ctx: *const Context, arena: Allocator) Allocator.Error![]json.Value {
        const path = try std.mem.concat(arena, u8, &.{ s.dir, "/inbox" });
        const text = (try util.readFile(ctx.io, arena, path)) orelse return &.{};
        var commands: std.ArrayList(json.Value) = .empty;
        var off: usize = @intCast(@min(s.inbox_offset, text.len));
        while (std.mem.findScalarPos(u8, text, off, '\n')) |nl| {
            if (try json.parseObject(arena, text[off..nl])) |c| try commands.append(arena, c);
            off = nl + 1;
        }
        s.inbox_offset = off;
        return commands.items;
    }

    /// The path for the next tool output file. Caller owns the result.
    pub fn nextOutputPath(s: *Session, gpa: Allocator) Allocator.Error![]u8 {
        s.tool_seq += 1;
        return gpa.print("{s}/tool-{d:0>4}.out", .{ s.dir, s.tool_seq });
    }
};

/// Points .arx/sessions/last at `id`, atomically.
fn linkLast(ctx: *const Context, id: []const u8) void {
    var buf: [64]u8 = undefined;
    const tmp = std.mem.print(&buf, root ++ "/.last{d}", .{sys.getpid()}) catch return;
    const cwd = Dir.cwd();
    cwd.deleteFile(ctx.io, tmp) catch {};
    cwd.symLink(ctx.io, id, tmp, .{}) catch return;
    cwd.rename(tmp, cwd, root ++ "/last", ctx.io) catch {};
}

/// The absolute folder for an id, "last" or a path, or null when there is
/// no such session. Allocated in `a`.
pub fn sessionDir(ctx: *const Context, a: Allocator, ref: []const u8) Allocator.Error!?[]u8 {
    const dir = if (std.mem.findScalar(u8, ref, '/') != null) ref else try std.mem.concat(a, u8, &.{ root, "/", ref });
    const info = util.stat(ctx.io, dir) orelse return null;
    return if (info.kind == .directory) util.realPath(ctx.io, a, dir) else null;
}
