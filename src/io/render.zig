//! render.zig: draws events as short lines on stderr (colored on a
//! terminal, plain otherwise, so it also reads well in docker logs and CI),
//! and implements `arx watch`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const sys = @import("../base/sys.zig");
const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const Context = @import("../base/context.zig").Context;
const session = @import("session.zig");

const dim = "\x1b[2m";
const red = "\x1b[31m";
const green = "\x1b[32m";
const yellow = "\x1b[33m";
const blue = "\x1b[34m";
const magenta = "\x1b[35m";
const cyan = "\x1b[36m";
const bold = "\x1b[1m";
const reset = "\x1b[0m";

/// The terminal view: whether it is on, its colors, and whether the cursor
/// is in the middle of a line.
pub const View = struct {
    io: Io,
    version: []const u8,
    enabled: bool = false,
    color: bool = false,
    mid_line: bool = false,

    /// Draws streamed model text, indenting each new line by subagent depth.
    pub fn text(v: *View, depth: i64, s: []const u8) void {
        var buf: [4096]u8 = undefined;
        var w = Io.File.stderr().writerStreaming(v.io, &buf);
        var rest = s;
        while (rest.len > 0) {
            if (!v.mid_line) indent(&w.interface, depth);
            const n = if (std.mem.findScalar(u8, rest, '\n')) |nl| nl + 1 else rest.len;
            w.interface.writeAll(rest[0..n]) catch {};
            v.mid_line = rest[n - 1] != '\n';
            rest = rest[n..];
        }
        w.interface.flush() catch {};
    }

    /// Draws one full line in `color`, starting on a fresh line.
    fn line(v: *View, depth: i64, color: ?[]const u8, comptime format: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        var w = Io.File.stderr().writerStreaming(v.io, &buf);
        const out = &w.interface;
        if (v.mid_line) out.writeByte('\n') catch {};
        indent(out, depth);
        const colored = color != null and v.color;
        if (colored) out.writeAll(color.?) catch {};
        out.print(format, args) catch {};
        if (colored) out.writeAll(reset) catch {};
        out.writeByte('\n') catch {};
        out.flush() catch {};
        v.mid_line = false;
    }

    /// Draws one event. `from_log` is true when the event was read back
    /// from a log or a subagent (so model text is drawn from model.delta
    /// events), and false for our own live events (whose text was drawn as
    /// it streamed).
    pub fn event(v: *View, e: json.Value, from_log: bool) void {
        const kind = json.strOr(e, "type", "");
        const depth = json.int(e, "depth", 0);
        if (std.mem.eql(u8, kind, "model.delta")) {
            if (from_log) v.text(depth, json.strOr(e, "text", ""));
        } else if (!v.work(e, kind, depth)) {
            v.harness(e, kind, depth);
        }
    }

    /// Draws the model and tool events. Returns false for other events.
    fn work(v: *View, e: json.Value, kind: []const u8, depth: i64) bool {
        if (eql(kind, "model.message")) {
            const in = json.num(e, "tokens_in", 0);
            const out = json.num(e, "tokens_out", 0);
            if (in != 0 or out != 0) {
                v.line(depth, dim, "  · {f} in · {f} out · ${d:.5}", .{ human(in), human(out), json.num(e, "cost", 0) });
            }
        } else if (eql(kind, "model.retry")) {
            v.line(depth, yellow, "  ↻ retry {d} in {d:.1}s: {s}", .{
                json.int(e, "attempt", 0), json.num(e, "wait_s", 0), json.strOr(e, "error", ""),
            });
        } else if (eql(kind, "tool.start")) {
            v.line(depth, cyan, "  ⏵ {s} {s}", .{ json.strOr(e, "name", ""), json.strOr(e, "preview", "") });
        } else if (eql(kind, "tool.end")) {
            v.line(depth, if (json.boolean(e, "error", false)) red else dim, "    ↳ exit {d} · {d:.1}s · {f} B  {s}", .{
                json.int(e, "exit", 0),
                json.num(e, "secs", 0),
                human(json.num(e, "bytes", 0)),
                json.strOr(e, "preview", ""),
            });
        } else {
            return false;
        }
        return true;
    }

    /// Draws the harness and session events.
    fn harness(v: *View, e: json.Value, kind: []const u8, depth: i64) void {
        if (eql(kind, "session.start")) {
            v.line(depth, dim, "● arx {s} · {s} · {s} · session {s}", .{
                v.version,
                json.strOr(e, "name", "agent"),
                json.strOr(e, "model", "?"),
                json.strOr(e, "session", ""),
            });
        } else if (eql(kind, "hook")) {
            const err = json.str(e, "error");
            const decision = json.str(e, "decision");
            if (err != null or decision != null) {
                v.line(depth, if (err != null) red else magenta, "  ⚑ hook {s}: {s}", .{
                    json.strOr(e, "point", ""), err orelse decision.?,
                });
            }
        } else if (eql(kind, "harness.reload")) {
            if (json.boolean(e, "ok", false)) {
                v.line(depth, green, "  ↻ harness reloaded ({d:.1} ms)", .{json.num(e, "ms", 0)});
            } else {
                v.line(depth, red, "  ✗ harness edit rejected; still using the previous version:\n{s}", .{json.strOr(e, "errors", "")});
            }
        } else if (eql(kind, "compact")) {
            v.line(depth, blue, "  ⇣ compacted ({s}): {f} → {f} tokens", .{
                json.strOr(e, "strategy", ""),
                human(json.num(e, "tokens_before", 0)),
                human(json.num(e, "tokens_after", 0)),
            });
        } else if (eql(kind, "note")) {
            v.line(depth, yellow, "  ✎ {s}", .{json.strOr(e, "text", "")});
        } else if (eql(kind, "error")) {
            v.line(depth, red, "  ✗ {s}", .{json.strOr(e, "error", "")});
        } else if (eql(kind, "session.end")) {
            v.line(depth, bold, "● {s} · {d} turns · {f} tokens · ${d:.5} · {d:.1}s", .{
                json.strOr(e, "status", ""),
                json.int(e, "turns", 0),
                human(json.num(e, "tokens", 0)),
                json.num(e, "cost", 0),
                json.num(e, "secs", 0),
            });
        }
    }
};

/// True when the strings are equal.
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Indents subagent output with one bar per level.
fn indent(w: *Io.Writer, depth: i64) void {
    var i: i64 = 0;
    while (i < depth) : (i += 1) w.writeAll("│ ") catch {};
}

/// A count such as 1234, drawn as "1.2k".
const Human = struct {
    n: f64,

    /// Writes the count with a k or M suffix.
    pub fn format(h: Human, w: *Io.Writer) Io.Writer.Error!void {
        if (h.n >= 1e6) return w.print("{d:.1}M", .{h.n / 1e6});
        if (h.n >= 1e3) return w.print("{d:.1}k", .{h.n / 1e3});
        try w.print("{d:.0}", .{h.n});
    }
};

/// Formats `n` like 1.2k when printed with {f}.
fn human(n: f64) Human {
    return .{ .n = n };
}

/// `arx watch`: follows a session's events.jsonl (`ref` is an id, "last"
/// or a folder) until the session ends. `raw` prints the lines instead of
/// the view; `from_start` replays the session first.
pub fn watch(ctx: *const Context, ref: []const u8, raw: bool, from_start: bool) Allocator.Error!util.Exit {
    const gpa = ctx.gpa;
    const io = ctx.io;
    const dir = (try session.sessionDir(ctx, gpa, ref)) orelse {
        printErr(io, "arx: no session {s}\n", .{ref});
        return .usage;
    };
    defer gpa.free(dir);
    const path = try std.mem.concat(gpa, u8, &.{ dir, "/events.jsonl" });
    defer gpa.free(path);
    const id = util.baseName(dir);
    var file = Io.Dir.cwd().openFile(io, path, .{}) catch {
        printErr(io, "arx: cannot open {s}\n", .{path});
        return .@"error";
    };
    defer file.close(io);
    var offset: u64 = if (from_start) 0 else file.length(io) catch 0;
    var view: View = .{
        .io = io,
        .version = ctx.version,
        .enabled = true,
        .color = sys.isatty(2) and ctx.getenv("NO_COLOR") == null,
    };
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var ended = false;
    var chunk: [65536]u8 = undefined;
    while (!sys.isInterrupted()) {
        const n = file.readPositional(io, &.{&chunk}, offset) catch 0;
        if (n == 0) {
            if (ended) break;
            util.sleepSeconds(io, 0.1);
            continue;
        }
        offset += n;
        try pending.appendSlice(gpa, chunk[0..n]);
        while (std.mem.findScalar(u8, pending.items, '\n')) |nl| {
            ended = try watchLine(ctx, &view, pending.items[0 .. nl + 1], id, raw, ended);
            pending.replaceRangeAssumeCapacity(0, nl + 1, &.{});
        }
    }
    return .done;
}

/// Handles one complete line. Returns true once the top-level session has
/// ended (a later session.start, from a resume, clears it).
fn watchLine(ctx: *const Context, view: *View, line: []const u8, id: []const u8, raw: bool, ended: bool) Allocator.Error!bool {
    if (raw) {
        var buf: [256]u8 = undefined;
        var w = Io.File.stdout().writerStreaming(ctx.io, &buf);
        w.interface.writeAll(line) catch {};
        w.interface.flush() catch {};
    }
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    const e = try json.parseObject(arena.allocator(), line) orelse return ended;
    if (!raw) view.event(e, true);
    if (json.int(e, "depth", 0) == 0 and std.mem.eql(u8, json.strOr(e, "session", ""), id)) {
        const kind = json.strOr(e, "type", "");
        if (eql(kind, "session.end")) return true;
        if (eql(kind, "session.start")) return false;
    }
    return ended;
}

/// Prints a formatted message on stderr.
pub fn printErr(io: Io, comptime format: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print(format, args) catch {};
    w.interface.flush() catch {};
}

/// Prints a formatted message on stdout.
pub fn printOut(io: Io, comptime format: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(io, &buf);
    w.interface.print(format, args) catch {};
    w.interface.flush() catch {};
}
