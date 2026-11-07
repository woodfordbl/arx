//! tool_exec.zig: starts and ends one tool call; the runtime runs many at
//! once. Output goes to a file in the session, and the model sees only its
//! head and tail. Subagents are this same binary run one level deeper, with
//! their events forwarded into ours.

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

/// Forwards each complete event line from a subagent's event pipe.
const Forwarder = struct {
    gpa: Allocator,
    events: *Events,
    pending: std.ArrayList(u8) = .empty,

    /// Splits the pipe's bytes into event lines and forwards them.
    fn forward(f: *Forwarder, bytes: []const u8) Allocator.Error!void {
        try f.pending.appendSlice(f.gpa, bytes);
        var at: usize = 0;
        while (std.mem.findScalarPos(u8, f.pending.items, at, '\n')) |nl| {
            try f.events.forward(f.pending.items[at .. nl + 1]);
            at = nl + 1;
        }
        f.pending.replaceRangeAssumeCapacity(0, at, &.{});
    }
};

/// A tool call that runs: its process and what it collects. Heap-allocated,
/// so the sinks stay put while the process runs.
pub const Run = struct {
    a: *Agent,
    arena: std.heap.ArenaAllocator,
    kind: tools.Kind,
    timeout: f64,
    cap: Capture,
    /// A subagent's --json answer.
    out: proc.Collector,
    forwarder: Forwarder,
    env: Environ.Map,
    path: []const u8,
    file: ?std.Io.File = null,
    child: *proc.Child,

    /// Ends the call (stopping its process if it still runs) and frees the
    /// run. Adds exit, secs, bytes and path to `end`. The outcome lives in
    /// `t`.
    pub fn finish(run: *Run, t: Allocator, end: *Event) Allocator.Error!Outcome {
        const a = run.a;
        const gpa = a.ctx.gpa;
        defer {
            run.cap.deinit();
            run.forwarder.pending.deinit(gpa);
            run.env.deinit();
            if (run.file) |f| f.close(a.ctx.io);
            run.arena.deinit();
            gpa.destroy(run);
        }
        const r = try proc.finish(run.child);
        const path = try t.dupe(u8, run.path);
        var text: []const u8 = undefined;
        if (r.spawn_error) |err| {
            text = try t.print("could not start the tool: {s}", .{util.describeError(err)});
        } else if (run.kind == .agent) {
            const answer = json.strOr(try json.parseObject(t, run.out.output()), "final_output", "");
            text = switch (r.code) {
                @backingInt(util.Exit.done) => answer,
                @backingInt(util.Exit.cap) => try t.print("[the subagent stopped at a cap]\n{s}", .{answer}),
                else => try t.print("[the subagent failed with exit {d}]\n{s}{s}", .{ r.code, answer, try run.cap.text(t, path) }),
            };
        } else {
            const body = try run.cap.text(t, path);
            text = try t.print("{s}{s}", .{ if (body.len > 0 or r.code != 0) body else "(no output)", if (r.timed_out)
                try t.print("\n[timed out after {d:.0}s; the process group was killed]", .{run.timeout})
            else if (r.interrupted)
                "\n[interrupted]"
            else if (r.code != 0)
                try t.print("\n[exit code {d}]", .{r.code})
            else
                "" });
        }
        try end.int("exit", r.code);
        try end.num("secs", r.secs);
        try end.int("bytes", @intCast(run.cap.total));
        try end.str("path", path);
        return .{ .text = text, .is_error = r.spawn_error != null or r.code != 0 or r.timed_out, .output_path = path };
    }
};

/// A call either ends at once or runs.
pub const Started = union(enum) {
    /// An unknown tool or bad arguments: the result, in the caller's arena.
    done: Outcome,
    /// Poll `run.child`, then call `run.finish`.
    running: *Run,
};

/// Starts the process of a call: the tool's file (or `arx tool NAME` for a
/// file that only hands over to it), or a subagent: `arx -p - --spec
/// <path> --json --quiet --events fd:N`, with our caps and one more level
/// of depth.
fn startProcess(a: *Agent, tool: *const tools.Tool, args: json.Value, input: []const u8) Allocator.Error!*Run {
    const gpa = a.ctx.gpa;
    const run = try gpa.create(Run);
    run.* = .{
        .a = a,
        .arena = .init(gpa),
        .kind = tool.kind,
        .timeout = tool.timeout,
        .cap = .{ .gpa = gpa, .head_max = json.size(a.spec.root, "tool_output.head", 2048), .tail_max = json.size(a.spec.root, "tool_output.tail", 6144) },
        .out = undefined,
        .forwarder = .{ .gpa = gpa, .events = &a.events },
        .env = undefined,
        .path = "",
        .child = undefined,
    };
    const t = run.arena.allocator();
    run.out = .init(t);
    run.path = try a.session.?.nextOutputPath(t);
    run.file = std.Io.Dir.cwd().createFile(a.ctx.io, run.path, .{}) catch null;
    if (run.file) |f| run.cap.fd = f.handle;
    const agent = tool.kind == .agent;
    run.env = try environ(a, tool.plugin_dir, a.depth + @intFromBool(agent));
    var opts: proc.Options = .{ .argv = &.{}, .timeout = tool.timeout, .environ = &run.env, .stdout = run.cap.sink() };
    if (agent) {
        var argv: std.ArrayList([]const u8) = .empty;
        opts.side = proc.SidePipe.open(.init(&run.forwarder, Forwarder.forward)) catch null;
        const fd: i64 = if (opts.side) |side| side.fds[1] else -1;
        try argv.appendSlice(t, &.{ a.ctx.self_path, "-p", "-", "--spec", tool.path.?, "--json", "--quiet", "--events", try t.print("fd:{d}", .{fd}) });
        for (a.cap_args.items) |cap_arg| try argv.appendSlice(t, &.{ "--cap", cap_arg });
        opts.argv = argv.items;
        opts.stdin = try t.dupe(u8, json.strOr(args, "task", ""));
        opts.stdout = run.out.sink();
        opts.stderr = run.cap.sink();
    } else {
        opts.argv = if (tool.core) |core| try t.dupe([]const u8, &.{ a.ctx.self_path, "tool", core }) else try t.dupe([]const u8, &.{tool.path.?});
        opts.stdin = try t.dupe(u8, input);
    }
    run.child = try proc.start(a.ctx, opts);
    return run;
}

/// Starts tool `name` with JSON `args` and returns at once, or ends the
/// call at once for an unknown tool or bad arguments (the outcome then
/// lives in `t`).
pub fn start(a: *Agent, t: Allocator, name: []const u8, args: []const u8) Allocator.Error!Started {
    const tool = a.tools.find(name) orelse {
        var names: std.ArrayList(u8) = .empty;
        for (a.tools.items, 0..) |tool, i| try names.print(t, "{s}{s}", .{ if (i > 0) ", " else "", tool.name });
        return .{ .done = .{ .text = try t.print("unknown tool \"{s}\" (available: {s})", .{ name, if (names.items.len > 0) names.items else "none" }) } };
    };
    const raw = if (args.len > 0) args else "{}";
    const parsed = try json.parseObject(t, raw) orelse
        return .{ .done = .{ .text = try t.print("the arguments are not a valid JSON object: {s}", .{util.cutPrefix(raw, 200)}) } };
    if (tool.kind == .agent and json.str(parsed, "task") == null) return .{ .done = .{ .text = "this subagent needs a string argument `task`" } };
    return .{ .running = try startProcess(a, tool, parsed, raw) };
}
