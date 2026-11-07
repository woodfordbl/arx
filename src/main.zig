//! main.zig: the entry point. Installs signal handlers, then runs a
//! built-in command, an external `arx-*` command, or the agent.
//!
//! Layers (each only uses the ones below it):
//!   cli/      options, built-in and external commands
//!   agent/    the loop, session lifecycle, prompts
//!   harness/  what the agent can change: spec, plugins, tools, hooks
//!   model/    model calls through curl
//!   io/       sessions, events, terminal view
//!   base/     files, JSON, processes

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const sys = @import("base/sys.zig");
const util = @import("base/util.zig");
const Context = @import("base/context.zig").Context;
const render = @import("io/render.zig");
const Agent = @import("agent/agent.zig").Agent;
const run = @import("agent/run.zig");
const options = @import("cli/options.zig");
const commands = @import("cli/commands.zig");
const external = @import("cli/external.zig");
const Exit = util.Exit;

/// Release builds print a panic's message without a stack trace, which
/// keeps the stack-trace machinery (about 60 KB) out of the binary. Debug
/// builds keep the full handler.
pub const panic = if (builtin.optimize == .debug) std.debug.FullPanic(std.debug.defaultPanic) else std.debug.simple_panic;

/// Runs arx and returns its exit code.
pub fn main(init: std.process.Init) u8 {
    sys.installSignals();
    const args = argsSlice(init) catch return outOfMemory(init.io);
    const self_path = selfPath(init, args) catch return outOfMemory(init.io);
    const ctx: Context = .{
        .gpa = init.gpa,
        .io = init.io,
        .environ = init.environ_map,
        .self_path = self_path,
        .version = build_options.version,
    };
    var agent: Agent = .init(&ctx);
    defer agent.deinit();
    const code = dispatch(&agent, args) catch |err| {
        render.printErr(init.io, "arx: {s}\n", .{if (err == error.OutOfMemory) "out of memory" else @errorName(err)});
        return @backingInt(Exit.@"error");
    };
    return @backingInt(code);
}

/// Reports running out of memory before the agent exists.
fn outOfMemory(io: std.Io) u8 {
    render.printErr(io, "arx: out of memory\n", .{});
    return @backingInt(Exit.@"error");
}

/// The command-line arguments as plain slices.
fn argsSlice(init: std.process.Init) ![]const []const u8 {
    const arena = init.arena.allocator();
    const raw = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, raw.len);
    for (args, raw) |*dst, src| dst.* = src;
    return args;
}

/// The absolute path of the running binary, so subagents run the same one.
fn selfPath(init: std.process.Init, args: []const []const u8) ![]const u8 {
    const arena = init.arena.allocator();
    if (std.process.executablePathAlloc(init.io, arena)) |path| {
        if (try util.realPath(init.io, arena, path)) |real| return real;
        return path;
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    const argv0 = if (args.len > 0) args[0] else "arx";
    return (try util.realPath(init.io, arena, argv0)) orelse argv0;
}

/// Picks what to run from the first argument.
fn dispatch(a: *Agent, args: []const []const u8) !Exit {
    const first: []const u8 = if (args.len > 1) args[1] else "";
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V")) {
        return (try commands.run(a, "version", args)).?;
    }
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        return external.helpCommand(a, args[0..1]);
    }
    if (first.len > 0 and first[0] != '-') {
        if (try commands.run(a, first, args)) |code| return code;
        if (try external.run(a.ctx, first, args)) |code| return code;
        return options.usageError(a, "unknown command", first);
    }
    return runAgent(a, args);
}

/// Runs the agent: headless with -p or piped stdin, else interactive.
fn runAgent(a: *Agent, args: []const []const u8) !Exit {
    const gpa = a.ctx.gpa;
    if (try options.parse(a, args, 1)) |code| return code;
    options.resolveSpec(a);
    var stdin_prompt: ?[]u8 = null;
    defer if (stdin_prompt) |p| gpa.free(p);
    const piped = !sys.isatty(0);
    if ((a.prompt != null and std.mem.eql(u8, a.prompt.?, "-")) or (a.prompt == null and piped)) {
        stdin_prompt = try options.readStdin(gpa);
        a.prompt = stdin_prompt;
    }
    a.interactive = a.prompt == null and !piped;
    if (!a.interactive and a.resume_ref == null and (a.prompt == null or a.prompt.?.len == 0)) {
        return options.usageError(a, "no task: use -p TASK, or pipe one on stdin", null);
    }
    return run.main(a);
}

test {
    // The files with unit tests; `zig build test` only sees what is imported.
    _ = @import("base/util.zig");
    _ = @import("base/json.zig");
    _ = @import("base/proc.zig");
    _ = @import("harness/yaml.zig");
    _ = @import("harness/plugins.zig");
    _ = @import("model/llm.zig");
    _ = @import("agent/agent.zig");
}
