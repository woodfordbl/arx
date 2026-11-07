//! run.zig: the session lifecycle around the loop: load the spec, open or
//! resume the session, start the event stream and observers, run headless
//! or interactively, and report the result.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const sys = @import("../base/sys.zig");
const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const render = @import("../io/render.zig");
const Session = @import("../io/session.zig").Session;
const spec_mod = @import("../harness/spec.zig");
const tools = @import("../harness/tools.zig");
const tool_exec = @import("../harness/tool_exec.zig");
const hooks = @import("../harness/hooks.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const loop = @import("loop.zig");
const Exit = util.Exit;

/// Opens or resumes the session and points the event stream at it.
fn openSession(a: *Agent) !?Exit {
    const ctx = a.ctx;
    const gpa = ctx.gpa;
    const opened = if (a.resume_ref) |ref| Session.open(ctx, ref, &a.messages) else Session.create(ctx, a.depth);
    a.session = opened catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        render.printErr(ctx.io, "arx: cannot {s} session {s}\n", .{
            if (a.resume_ref != null) "resume" else "create", a.resume_ref orelse "",
        });
        return if (a.resume_ref != null) .usage else .@"error";
    };
    const s = &a.session.?;
    a.events.session = s.id;
    a.events.depth = a.depth;
    a.events.turn = s.turns;
    a.events.view.enabled = !a.quiet;
    const path = try std.mem.concat(gpa, u8, &.{ s.dir, "/events.jsonl" });
    defer gpa.free(path);
    a.events.open(path, a.events_target) catch {
        render.printErr(ctx.io, "arx: cannot open --events {s}\n", .{a.events_target.?});
        return .usage;
    };
    return null;
}

/// Loads the harness and starts the session.
fn start(a: *Agent) !?Exit {
    const ctx = a.ctx;
    const gpa = ctx.gpa;
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(gpa);
    a.spec = (try spec_mod.load(ctx, a.spec_path, a.sets, &err)) orelse {
        render.printErr(ctx.io, "{s}", .{err.items});
        return .usage;
    };
    if (try openSession(a)) |code| return code;
    {
        // Observers get the same ARX_* variables as tools.
        var env = try tool_exec.environ(a, null, a.depth);
        defer env.deinit();
        for (json.items(json.field(a.spec.root, "observers"))) |observer| {
            if (observer == .string) a.events.addObserver(observer.string, &env);
        }
    }
    try tools.build(a);
    var event = try a.events.begin("session.start");
    defer event.deinit();
    try event.str("name", json.strOr(a.spec.root, "name", "agent"));
    try event.str("model", json.strOr(a.spec.root, "model", ""));
    try event.str("spec", a.spec.path);
    try event.boolean("resumed", a.resume_ref != null);
    try event.int("tools", @intCast(a.tools.items.len));
    try a.events.send(&event);
    return null;
}

/// Starts a conversation: system prompt, session_start hook, first message.
fn begin(a: *Agent, prompt: []const u8) !void {
    const gpa = a.ctx.gpa;
    const system = try agent_mod.systemPrompt(a);
    defer gpa.free(system);
    try a.addMessage("system", system);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const outcome = try hooks.run(a, arena.allocator(), "session_start", json.object());
    const first = try agent_mod.firstMessage(a, prompt);
    defer gpa.free(first);
    if (json.str(outcome.output, "context")) |context| {
        const joined = try std.mem.concat(gpa, u8, &.{ first, "\n\n", context });
        defer gpa.free(joined);
        try a.addMessage("user", joined);
    } else {
        try a.addMessage("user", first);
    }
}

/// Headless: one task, run until the agent stops.
fn headless(a: *Agent) !Exit {
    if (a.resume_ref == null) {
        try begin(a, a.prompt orelse "");
    } else if (a.prompt) |p| {
        if (p.len > 0) try a.addMessage("user", p);
    }
    return loop.runTurns(a);
}

/// Reads one line from stdin into `line`, without the newline. Returns
/// false at end of input, or when Ctrl-C interrupts the read.
fn readLine(gpa: Allocator, pending: *std.ArrayList(u8), line: *std.ArrayList(u8)) Allocator.Error!bool {
    line.clearRetainingCapacity();
    while (true) {
        if (std.mem.findScalar(u8, pending.items, '\n')) |nl| {
            try line.appendSlice(gpa, pending.items[0..nl]);
            pending.replaceRangeAssumeCapacity(0, nl + 1, &.{});
            return true;
        }
        var chunk: [4096]u8 = undefined;
        const n = std.c.read(0, &chunk, chunk.len);
        if (n <= 0) {
            if (pending.items.len == 0 or n < 0) return false;
            try line.appendSlice(gpa, pending.items);
            pending.clearRetainingCapacity();
            return true;
        }
        try pending.appendSlice(gpa, chunk[0..@intCast(n)]);
    }
}

/// Interactive: one line per message. Ctrl-C stops the current turn;
/// Ctrl-D, /exit or Ctrl-C at the prompt ends the session.
fn interactive(a: *Agent) !Exit {
    const gpa = a.ctx.gpa;
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    var first_prompt: ?[]u8 = null;
    defer if (first_prompt) |p| gpa.free(p);
    defer a.prompt = null;
    var code: Exit = .done;
    var started = a.resume_ref != null;
    while (true) {
        render.printErr(a.ctx.io, "{s}", .{if (a.events.view.color) "\n\x1b[1m› \x1b[0m" else "\n› "});
        sys.clearInterrupted();
        if (!try readLine(gpa, &pending, &line)) break;
        const text = line.items;
        if (text.len == 0) continue;
        if (std.mem.eql(u8, text, "/exit") or std.mem.eql(u8, text, "/quit")) break;
        if (!started) {
            first_prompt = try gpa.dupe(u8, text);
            a.prompt = first_prompt; // kept for {{prompt}} after a restart
            try begin(a, text);
            started = true;
        } else {
            try a.addMessage("user", text);
        }
        code = try loop.runTurns(a);
        if (code == .interrupted) {
            render.printErr(a.ctx.io, "\n(interrupted)\n", .{});
            code = .done;
        } else if (code == .auth) {
            break;
        }
    }
    return code;
}

/// Prints --json output, or the final answer when it was not already shown.
fn printResult(a: *Agent, code: Exit) Allocator.Error!void {
    const gpa = a.ctx.gpa;
    const answer = a.final_output orelse "";
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(a.ctx.io, &buf);
    const out = &w.interface;
    if (a.json_output) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const t = arena.allocator();
        const s = a.session;
        var r = json.object();
        try json.put(t, &r, "session", json.string(a.sessionId()));
        try json.put(t, &r, "status", json.string(code.status()));
        try json.put(t, &r, "exit", .{ .integer = @backingInt(code) });
        try json.put(t, &r, "final_output", json.string(answer));
        try json.put(t, &r, "turns", .{ .integer = a.turns() });
        var tokens = json.object();
        try json.put(t, &tokens, "input", .{ .integer = if (s) |x| x.tokens_in else 0 });
        try json.put(t, &tokens, "output", .{ .integer = if (s) |x| x.tokens_out else 0 });
        try json.put(t, &r, "tokens", tokens);
        try json.put(t, &r, "cost", json.number(if (s) |x| x.cost else 0));
        json.write(out, r, .compact) catch {};
        out.writeByte('\n') catch {};
    } else if (answer.len > 0 and !(a.events.view.enabled and sys.isatty(1) and sys.isatty(2))) {
        out.print("{s}\n", .{answer}) catch {}; // on a terminal the view already showed it
    }
    out.flush() catch {};
}

/// Ends the session: final event, meta.json, result.
fn finish(a: *Agent, code: Exit) !void {
    const s = &a.session.?;
    var event = try a.events.begin("session.end");
    defer event.deinit();
    try event.str("status", code.status());
    try event.int("turns", s.turns);
    try event.int("tokens", s.tokens_in + s.tokens_out);
    try event.num("cost", s.cost);
    try event.num("secs", util.now(a.ctx.io) - a.start);
    try event.truncated("final_output", a.final_output, 2000);
    try a.events.send(&event);
    try s.writeMeta(a.ctx, code.status());
    a.events.close();
    try printResult(a, code);
}

/// Runs the agent from start to finish: opens or resumes the session, runs
/// the loop (repeatedly in interactive mode), and prints the result.
pub fn main(a: *Agent) !Exit {
    a.start = util.now(a.ctx.io);
    if (a.ctx.getenv("ARX_DEPTH")) |depth| {
        a.depth = std.fmt.parseInt(i64, std.mem.trim(u8, depth, " "), 10) catch 0;
    }
    if (a.caps.depth >= 0 and a.depth > a.caps.depth) {
        render.printErr(a.ctx.io, "arx: subagent depth {d} is over the cap of {d}\n", .{ a.depth, a.caps.depth });
        try printResult(a, .cap);
        return .cap;
    }
    if (try start(a)) |code| return code;
    const code = if (a.interactive) try interactive(a) else try headless(a);
    try finish(a, code);
    return code;
}
