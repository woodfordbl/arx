//! tool_exec.zig: runs one tool call. Output goes to a file in the session,
//! and the model sees only its head and tail. Subagents are this same
//! binary run one level deeper, with their events forwarded into ours.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const sys = @import("../base/sys.zig");
const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const proc = @import("../base/proc.zig");
const Event = @import("../io/events.zig").Event;
const Events = @import("../io/events.zig").Events;
const spec_mod = @import("spec.zig");
const tools = @import("tools.zig");
const Agent = @import("../agent/agent.zig").Agent;

/// What a tool call produced. The strings live in the caller's arena.
pub const Outcome = struct {
    /// The text for the model.
    text: []const u8,
    is_error: bool = true,
    /// The file with the full output, or null.
    output_path: ?[]const u8 = null,
};

/// The ARX_* variables for tools, hooks, compactors and observers, added to
/// our own environment: ARX_SESSION, ARX_SESSION_DIR, ARX_TURN, ARX_CWD,
/// ARX_SPEC, ARX_SPEC_DIR, ARX_DEPTH, ARX_BIN, and ARX_PLUGIN_DIR when
/// `plugin_dir` is set. Caller owns the map.
pub fn environ(a: *Agent, plugin_dir: ?[]const u8, depth: i64) Allocator.Error!Environ.Map {
    var arena: std.heap.ArenaAllocator = .init(a.ctx.gpa);
    defer arena.deinit();
    const t = arena.allocator();
    const cwd = std.process.currentPathAlloc(a.ctx.io, t) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => ".",
    };
    const extra = [_][2][]const u8{
        .{ "ARX_SESSION", a.sessionId() },
        .{ "ARX_SESSION_DIR", if (a.session) |s| s.dir else "" },
        .{ "ARX_TURN", try t.print("{d}", .{a.turns()}) },
        .{ "ARX_CWD", cwd },
        .{ "ARX_SPEC", a.spec.path },
        .{ "ARX_SPEC_DIR", a.spec.dir },
        .{ "ARX_DEPTH", try t.print("{d}", .{depth}) },
        .{ "ARX_BIN", a.ctx.self_path },
        .{ "ARX_PLUGIN_DIR", plugin_dir orelse "" },
    };
    return proc.environWith(a.ctx.gpa, a.ctx.environ, extra[0 .. extra.len - @intFromBool(plugin_dir == null)]);
}

/// Captured output: the head and tail in memory, everything in a file.
const Capture = struct {
    gpa: Allocator,
    head: std.ArrayList(u8) = .empty,
    tail: std.ArrayList(u8) = .empty,
    total: usize = 0,
    head_max: usize,
    tail_max: usize,
    /// The full-output file, or -1.
    fd: sys.fd_t = -1,

    /// Frees the head and tail.
    fn deinit(c: *Capture) void {
        c.head.deinit(c.gpa);
        c.tail.deinit(c.gpa);
    }

    /// The sink that captures a child's output.
    fn sink(c: *Capture) proc.Sink {
        return .init(c, write);
    }

    /// Saves output to the file and keeps the head and the tail.
    fn write(c: *Capture, bytes: []const u8) Allocator.Error!void {
        if (c.fd >= 0) sys.writeAll(c.fd, bytes) catch {};
        c.total += bytes.len;
        try c.head.appendSlice(c.gpa, bytes[0..@min(bytes.len, c.head_max -| c.head.items.len)]);
        try c.tail.appendSlice(c.gpa, bytes);
        if (c.tail.items.len > 2 * c.tail_max + 65536) { // trim now and then, not always
            c.tail.replaceRangeAssumeCapacity(0, c.tail.items.len - c.tail_max, &.{});
        }
    }

    /// What the model sees: all of a short output, or head + marker + tail.
    fn text(c: *const Capture, t: Allocator, path: []const u8) Allocator.Error![]u8 {
        var b: std.ArrayList(u8) = .empty;
        try b.appendSlice(t, c.head.items);
        const rest = @min(c.total -| c.head_max, c.tail_max, c.tail.items.len);
        if (c.total > c.head_max + c.tail_max) {
            try b.print(t, "\n[... {d} bytes omitted; full output: {s} ...]\n", .{ c.total - c.head_max - c.tail_max, path });
        }
        try b.appendSlice(t, c.tail.items[c.tail.items.len - rest ..]);
        return util.utf8Clean(t, b.items);
    }
};

/// The edit tool: replace one exact, unique occurrence, or create a file
/// when `old` is empty.
fn edit(a: *Agent, t: Allocator, args: json.Value) Allocator.Error!Outcome {
    const io = a.ctx.io;
    const path = json.str(args, "path");
    const old = json.str(args, "old");
    const new = json.str(args, "new");
    if (path == null or old == null or new == null) return .{ .text = "edit needs string arguments path, old and new" };
    const p = path.?;
    const updated = if (std.Io.Dir.cwd().readFileAlloc(io, p, t, .unlimited)) |text| blk: {
        if (old.?.len == 0) return .{ .text = try t.print("{s} exists; pass the exact text to replace in `old`", .{p}) };
        const count = std.mem.count(u8, text, old.?);
        if (count == 0) return .{ .text = try t.print("`old` was not found in {s} (it must match exactly, including whitespace)", .{p}) };
        if (count > 1) return .{ .text = try t.print("`old` occurs {d} times in {s}; include more context so it is unique", .{ count, p }) };
        const hit = std.mem.find(u8, text, old.?).?;
        break :blk try std.mem.concat(t, u8, &.{ text[0..hit], new.?, text[hit + old.?.len ..] });
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            if (old.?.len > 0) return .{ .text = try t.print("cannot read {s}: {s}", .{ p, util.describeError(err) }) };
            std.Io.Dir.cwd().createDirPath(io, util.dirName(p)) catch {};
            break :blk new.?;
        },
    };
    const created = old.?.len == 0;
    util.writeFileAtomic(io, t, p, updated) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .text = try t.print("cannot {s} {s}: {s}", .{ if (created) "create" else "write", p, util.describeError(err) }) };
    };
    const text = if (created) try t.print("created {s} ({d} bytes)", .{ p, updated.len }) else try t.print("edited {s}", .{p});
    return .{ .text = text, .is_error = false };
}

/// Forwards each complete event line from a subagent's event pipe.
const Forwarder = struct {
    gpa: Allocator,
    events: *Events,
    pending: std.ArrayList(u8) = .empty,

    /// Splits the pipe's bytes into event lines and forwards them.
    fn forward(f: *Forwarder, bytes: []const u8) Allocator.Error!void {
        try f.pending.appendSlice(f.gpa, bytes);
        var start: usize = 0;
        while (std.mem.findScalarPos(u8, f.pending.items, start, '\n')) |nl| {
            try f.events.forward(f.pending.items[start .. nl + 1]);
            start = nl + 1;
        }
        f.pending.replaceRangeAssumeCapacity(0, start, &.{});
    }
};

/// Runs a subagent: `arx -p - --spec <path> --json --quiet --events fd:N`,
/// with our caps and one more level of depth, and turns its --json output
/// into the tool result.
fn runSubagent(a: *Agent, t: Allocator, tool: *const tools.Tool, task: []const u8, cap: *Capture, path: []const u8) Allocator.Error!struct { proc.Result, []const u8 } {
    var forwarder: Forwarder = .{ .gpa = a.ctx.gpa, .events = &a.events };
    defer forwarder.pending.deinit(a.ctx.gpa);
    const side = proc.SidePipe.open(.init(&forwarder, Forwarder.forward)) catch |err| return .{ .{ .spawn_error = err, .code = 127 }, "" };
    errdefer for (side.fds) |fd| sys.close(fd); // proc.run closes them once it starts
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(t, &.{ a.ctx.self_path, "-p", "-", "--spec", tool.path.?, "--json", "--quiet", "--events", try t.print("fd:{d}", .{side.fds[1]}) });
    for (a.cap_args.items) |cap_arg| try argv.appendSlice(t, &.{ "--cap", cap_arg });
    var env = try environ(a, tool.plugin_dir, a.depth + 1);
    defer env.deinit();
    var out: proc.Collector = .init(t);
    const r = try proc.run(a.ctx, .{ .argv = argv.items, .stdin = task, .timeout = tool.timeout, .environ = &env, .stdout = out.sink(), .stderr = cap.sink(), .side = side });
    const answer = json.strOr(try json.parseObject(t, out.output()), "final_output", "");
    const text = switch (r.code) {
        @backingInt(util.Exit.done) => answer,
        @backingInt(util.Exit.cap) => try t.print("[the subagent stopped at a cap]\n{s}", .{answer}),
        else => try t.print("[the subagent failed with exit {d}]\n{s}{s}", .{ r.code, answer, try cap.text(t, path) }),
    };
    return .{ r, text };
}

/// Runs a process-backed tool (bash, executable or subagent).
fn runProcess(a: *Agent, t: Allocator, tool: *const tools.Tool, args: json.Value, raw: []const u8, path: []const u8, end: *Event) Allocator.Error!Outcome {
    const io = a.ctx.io;
    var cap: Capture = .{
        .gpa = a.ctx.gpa,
        .head_max = json.size(a.spec.root, "tool_output.head", 2048),
        .tail_max = json.size(a.spec.root, "tool_output.tail", 6144),
    };
    defer cap.deinit();
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch null;
    defer if (file) |f| f.close(io);
    if (file) |f| cap.fd = f.handle;
    var r: proc.Result = undefined;
    var text: []const u8 = undefined;
    if (tool.kind == .agent) {
        r, text = try runSubagent(a, t, tool, json.strOr(args, "task", ""), &cap, path);
    } else {
        var env = try environ(a, tool.plugin_dir, a.depth);
        defer env.deinit();
        const argv: []const []const u8 = if (tool.kind == .bash) &.{ "sh", "-c", json.strOr(args, "command", "") } else &.{tool.path.?};
        r = try proc.run(a.ctx, .{ .argv = argv, .stdin = if (tool.kind == .exec) raw else null, .timeout = tool.timeout, .environ = &env, .stdout = cap.sink() });
        const body = try cap.text(t, path);
        text = try t.print("{s}{s}", .{ if (body.len > 0 or r.code != 0) body else "(no output)", if (r.timed_out)
            try t.print("\n[timed out after {d:.0}s; the process group was killed]", .{tool.timeout})
        else if (r.interrupted)
            "\n[interrupted]"
        else if (r.code != 0)
            try t.print("\n[exit code {d}]", .{r.code})
        else
            "" });
    }
    if (r.spawn_error) |err| text = try t.print("could not start the tool: {s}", .{util.describeError(err)});
    try end.int("exit", r.code);
    try end.num("secs", r.secs);
    try end.int("bytes", @intCast(cap.total));
    try end.str("path", path);
    return .{ .text = text, .is_error = r.spawn_error != null or r.code != 0 or r.timed_out, .output_path = path };
}

/// Runs tool `name` with JSON `args` and adds exit, secs, bytes and path to
/// `end` (the tool.end event). The outcome lives in `t`.
pub fn call(a: *Agent, t: Allocator, name: []const u8, args: []const u8, end: *Event) Allocator.Error!Outcome {
    const tool = a.tools.find(name) orelse {
        var names: std.ArrayList(u8) = .empty;
        for (a.tools.items, 0..) |tool, i| try names.print(t, "{s}{s}", .{ if (i > 0) ", " else "", tool.name });
        return .{ .text = try t.print("unknown tool \"{s}\" (available: {s})", .{ name, if (names.items.len > 0) names.items else "none" }) };
    };
    const raw = if (args.len > 0) args else "{}";
    const parsed = try json.parseObject(t, raw) orelse
        return .{ .text = try t.print("the arguments are not a valid JSON object: {s}", .{util.cutPrefix(raw, 200)}) };
    switch (tool.kind) {
        .edit => return edit(a, t, parsed),
        .bash => if (json.str(parsed, "command") == null) return .{ .text = "bash needs a string argument `command`" },
        .agent => if (json.str(parsed, "task") == null) return .{ .text = "this subagent needs a string argument `task`" },
        .exec => {},
    }
    return runProcess(a, t, tool, parsed, raw, try a.session.?.nextOutputPath(t), end);
}
