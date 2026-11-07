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

/// What a tool call produced.
pub const Outcome = struct {
    /// The text for the model. The caller owns it.
    text: []u8,
    is_error: bool,
    /// The file with the full output, or null. The caller owns it.
    output_path: ?[]u8 = null,
};

/// The ARX_* variables for tools, hooks, compactors and observers, added to
/// our own environment: ARX_SESSION, ARX_SESSION_DIR, ARX_TURN, ARX_CWD,
/// ARX_SPEC, ARX_SPEC_DIR, ARX_DEPTH, ARX_BIN, and ARX_PLUGIN_DIR when
/// `plugin_dir` is set. Caller owns the map.
pub fn environ(a: *Agent, plugin_dir: ?[]const u8, depth: i64) Allocator.Error!Environ.Map {
    const gpa = a.ctx.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = arena.allocator();
    const cwd = std.process.currentPathAlloc(a.ctx.io, t) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => ".",
    };
    var extra: std.ArrayList([2][]const u8) = .empty;
    try extra.appendSlice(t, &.{
        .{ "ARX_SESSION", a.sessionId() },
        .{ "ARX_SESSION_DIR", if (a.session) |s| s.dir else "" },
        .{ "ARX_TURN", try t.print("{d}", .{a.turns()}) },
        .{ "ARX_CWD", cwd },
        .{ "ARX_SPEC", a.spec.path },
        .{ "ARX_SPEC_DIR", a.spec.dir },
        .{ "ARX_DEPTH", try t.print("{d}", .{depth}) },
        .{ "ARX_BIN", a.ctx.self_path },
    });
    if (plugin_dir) |dir| try extra.append(t, .{ "ARX_PLUGIN_DIR", dir });
    return proc.environWith(gpa, a.ctx.environ, extra.items);
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
    out_of_memory: bool = false,

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
    fn write(c: *Capture, bytes: []const u8) void {
        if (c.fd >= 0) sys.writeAll(c.fd, bytes) catch {};
        c.total += bytes.len;
        c.keep(bytes) catch {
            c.out_of_memory = true;
        };
    }

    /// Adds `bytes` to the head (until full) and to the tail.
    fn keep(c: *Capture, bytes: []const u8) Allocator.Error!void {
        if (c.head.items.len < c.head_max) {
            const room = c.head_max - c.head.items.len;
            try c.head.appendSlice(c.gpa, bytes[0..@min(bytes.len, room)]);
        }
        try c.tail.appendSlice(c.gpa, bytes);
        if (c.tail.items.len > 2 * c.tail_max + 65536) { // trim now and then, not always
            const n = c.tail.items.len;
            c.tail.replaceRangeAssumeCapacity(0, n - c.tail_max, &.{});
        }
    }

    /// What the model sees: all of a short output, or head + marker + tail.
    fn text(c: *const Capture, path: []const u8) Allocator.Error![]u8 {
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(c.gpa);
        try b.appendSlice(c.gpa, c.head.items);
        const tail = c.tail.items;
        if (c.total > c.head_max + c.tail_max) {
            try b.print(c.gpa, "\n[... {d} bytes omitted; full output: {s} ...]\n", .{ c.total - c.head_max - c.tail_max, path });
            try b.appendSlice(c.gpa, tail[tail.len - @min(c.tail_max, tail.len) ..]);
        } else if (c.total > c.head_max) {
            const rest = c.total - c.head_max;
            try b.appendSlice(c.gpa, tail[tail.len - @min(rest, tail.len) ..]);
        }
        return util.utf8Clean(c.gpa, b.items);
    }
};

/// Creates `path` with `content`, refusing to overwrite.
fn createFile(a: *Agent, path: []const u8, content: []const u8) Allocator.Error!Outcome {
    const gpa = a.ctx.gpa;
    util.makeDirs(a.ctx.io, util.dirName(path)) catch {};
    util.writeFileAtomic(a.ctx.io, gpa, path, content) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .text = try gpa.print("cannot create {s}: {s}", .{ path, spec_mod.describeFileError(err) }), .is_error = true };
    };
    return .{ .text = try gpa.print("created {s} ({d} bytes)", .{ path, content.len }), .is_error = false };
}

/// The edit tool: replace one exact, unique occurrence, or create a file.
fn edit(a: *Agent, args: json.Value) Allocator.Error!Outcome {
    const gpa = a.ctx.gpa;
    const io = a.ctx.io;
    const path = json.str(args, "path");
    const old = json.str(args, "old");
    const new = json.str(args, "new");
    if (path == null or old == null or new == null) {
        return .{ .text = try gpa.dupe(u8, "edit needs string arguments path, old and new"), .is_error = true };
    }
    const text = std.Io.Dir.cwd().readFileAlloc(io, path.?, gpa, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (old.?.len == 0) return createFile(a, path.?, new.?);
            return .{ .text = try gpa.print("cannot read {s}: {s}", .{ path.?, spec_mod.describeFileError(err) }), .is_error = true };
        },
    };
    defer gpa.free(text);
    if (old.?.len == 0) {
        return .{ .text = try gpa.print("{s} exists; pass the exact text to replace in `old`", .{path.?}), .is_error = true };
    }
    const count = std.mem.count(u8, text, old.?);
    if (count == 0) {
        return .{ .text = try gpa.print("`old` was not found in {s} (it must match exactly, including whitespace)", .{path.?}), .is_error = true };
    }
    if (count > 1) {
        return .{ .text = try gpa.print("`old` occurs {d} times in {s}; include more context so it is unique", .{ count, path.? }), .is_error = true };
    }
    const hit = std.mem.find(u8, text, old.?).?;
    const updated = try std.mem.concat(gpa, u8, &.{ text[0..hit], new.?, text[hit + old.?.len ..] });
    defer gpa.free(updated);
    util.writeFileAtomic(io, gpa, path.?, updated) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .text = try gpa.print("cannot write {s}: {s}", .{ path.?, spec_mod.describeFileError(err) }), .is_error = true };
    };
    return .{ .text = try gpa.print("edited {s}", .{path.?}), .is_error = false };
}

/// Forwards each complete event line from a subagent's event pipe.
const Forwarder = struct {
    gpa: Allocator,
    events: *Events,
    pending: std.ArrayList(u8) = .empty,
    out_of_memory: bool = false,

    /// The sink for the subagent's event pipe.
    fn sink(f: *Forwarder) proc.Sink {
        return .init(f, write);
    }

    /// Forwards complete lines; remembers running out of memory.
    fn write(f: *Forwarder, bytes: []const u8) void {
        f.forward(bytes) catch {
            f.out_of_memory = true;
        };
    }

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
/// with our caps and one more level of depth. Its stdout (the --json
/// result) goes to `out`, its stderr to `cap`.
fn runSubagent(a: *Agent, tool: *const tools.Tool, task: []const u8, cap: *Capture, out: *proc.Collector) Allocator.Error!proc.Result {
    const gpa = a.ctx.gpa;
    var forwarder: Forwarder = .{ .gpa = gpa, .events = &a.events };
    defer forwarder.pending.deinit(gpa);
    const side = proc.SidePipe.open(forwarder.sink()) catch |err| return .{ .spawn_error = err, .code = 127 };
    errdefer for (side.fds) |fd| sys.close(fd); // proc.run closes them once it starts
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(t, &.{
        a.ctx.self_path, "-p",      "-",        "--spec",                                 tool.path.?,
        "--json",        "--quiet", "--events", try t.print("fd:{d}", .{side.childFd()}),
    });
    for (a.cap_args.items) |cap_arg| try argv.appendSlice(t, &.{ "--cap", cap_arg });
    var env = try environ(a, tool.plugin_dir, a.depth + 1);
    defer env.deinit();
    const r = proc.run(a.ctx, .{
        .argv = argv.items,
        .stdin = task,
        .timeout = tool.timeout,
        .environ = &env,
        .stdout = out.sink(),
        .stderr = cap.sink(),
        .side = side,
    });
    if (forwarder.out_of_memory) return error.OutOfMemory;
    return r;
}

/// Turns a subagent's --json output and exit code into the tool result.
fn subagentResult(gpa: Allocator, out: []const u8, cap: *const Capture, path: []const u8, code: u8) Allocator.Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const result = try json.parseObject(arena.allocator(), out);
    const answer = json.strOr(result, "final_output", "");
    switch (code) {
        @backingInt(util.Exit.done) => return gpa.dupe(u8, answer),
        @backingInt(util.Exit.cap) => return gpa.print("[the subagent stopped at a cap]\n{s}", .{answer}),
        else => {
            const err = try cap.text(path);
            defer gpa.free(err);
            return gpa.print("[the subagent failed with exit {d}]\n{s}{s}", .{ code, answer, err });
        },
    }
}

/// Output plus a status line for timeouts, interrupts and non-zero exits.
fn processResult(gpa: Allocator, cap: *const Capture, path: []const u8, r: proc.Result, timeout: f64) Allocator.Error![]u8 {
    const body = try cap.text(path);
    defer gpa.free(body);
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try b.appendSlice(gpa, if (body.len > 0 or r.code != 0) body else "(no output)");
    if (r.timed_out) {
        try b.print(gpa, "\n[timed out after {d:.0}s; the process group was killed]", .{timeout});
    } else if (r.interrupted) {
        try b.appendSlice(gpa, "\n[interrupted]");
    } else if (r.code != 0) {
        try b.print(gpa, "\n[exit code {d}]", .{r.code});
    }
    return b.toOwnedSlice(gpa);
}

/// Runs a process-backed tool (bash, executable or subagent).
fn runProcess(a: *Agent, tool: *const tools.Tool, args: json.Value, raw: []const u8, path: []const u8, end: *Event) Allocator.Error!Outcome {
    const gpa = a.ctx.gpa;
    const io = a.ctx.io;
    var cap: Capture = .{
        .gpa = gpa,
        .head_max = json.size(a.spec.root, "tool_output.head", 2048),
        .tail_max = json.size(a.spec.root, "tool_output.tail", 6144),
    };
    defer cap.deinit();
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch null;
    defer if (file) |f| f.close(io);
    if (file) |f| cap.fd = f.handle;
    var out: proc.Collector = .init(gpa);
    defer out.deinit();
    var r: proc.Result = undefined;
    var text: ?[]u8 = null;
    if (tool.kind == .agent) {
        r = try runSubagent(a, tool, json.strOr(args, "task", ""), &cap, &out);
        if (r.spawn_error == null) text = try subagentResult(gpa, out.output(), &cap, path, r.code);
    } else {
        var env = try environ(a, tool.plugin_dir, a.depth);
        defer env.deinit();
        const argv: []const []const u8 = if (tool.kind == .bash)
            &.{ "sh", "-c", json.strOr(args, "command", "") }
        else
            &.{tool.path.?};
        r = proc.run(a.ctx, .{
            .argv = argv,
            .stdin = if (tool.kind == .exec) raw else null,
            .timeout = tool.timeout,
            .environ = &env,
            .stdout = cap.sink(),
        });
        if (r.spawn_error == null) text = try processResult(gpa, &cap, path, r, tool.timeout);
    }
    if (cap.out_of_memory) {
        if (text) |t| gpa.free(t);
        return error.OutOfMemory;
    }
    if (r.spawn_error) |err| text = try gpa.print("could not start the tool: {s}", .{proc.describeSpawnError(err)});
    try end.int("exit", r.code);
    try end.num("secs", r.secs);
    try end.int("bytes", @intCast(cap.total));
    try end.str("path", path);
    return .{ .text = text.?, .is_error = r.spawn_error != null or r.code != 0 or r.timed_out };
}

/// Runs tool `name` with JSON `args` and adds exit, secs, bytes and path to
/// `end` (the tool.end event).
pub fn call(a: *Agent, name: []const u8, args: []const u8, end: *Event) Allocator.Error!Outcome {
    const gpa = a.ctx.gpa;
    const tool = a.tools.find(name) orelse {
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(gpa);
        for (a.tools.items, 0..) |t, i| {
            if (i > 0) try names.appendSlice(gpa, ", ");
            try names.appendSlice(gpa, t.name);
        }
        return .{
            .text = try gpa.print("unknown tool \"{s}\" (available: {s})", .{ name, if (names.items.len > 0) names.items else "none" }),
            .is_error = true,
        };
    };
    const raw = if (args.len > 0) args else "{}";
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const parsed = try json.parseObject(arena.allocator(), raw) orelse {
        return .{ .text = try gpa.print("the arguments are not a valid JSON object: {s}", .{util.cutPrefix(raw, 200)}), .is_error = true };
    };
    if (tool.kind == .edit) return edit(a, parsed);
    if (tool.kind == .bash and json.str(parsed, "command") == null) {
        return .{ .text = try gpa.dupe(u8, "bash needs a string argument `command`"), .is_error = true };
    }
    if (tool.kind == .agent and json.str(parsed, "task") == null) {
        return .{ .text = try gpa.dupe(u8, "this subagent needs a string argument `task`"), .is_error = true };
    }
    const path = try a.session.?.nextOutputPath(gpa);
    errdefer gpa.free(path);
    var outcome = try runProcess(a, tool, parsed, raw, path, end);
    outcome.output_path = path;
    return outcome;
}
