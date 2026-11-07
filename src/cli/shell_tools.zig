//! shell_tools.zig: the bash and edit tools behind `arx tool NAME`. The
//! code stays in the binary so the tools are fast and need no other
//! programs, but the shell plugin connects them, so another plugin can
//! replace them (for example to run them in a sandbox).

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const render = @import("../io/render.zig");
const Agent = @import("../agent/agent.zig").Agent;
const options = @import("options.zig");
const Exit = util.Exit;

/// The schema of `arx tool bash`, the same as
/// plugins/shell/tools/bash.json. The {{...}} fields are filled in when the
/// tool loads (see tools.zig).
const bash_schema =
    \\{"description":"Run a shell command (sh -c) in the working directory. You see the first {{tool_output.head}} and last {{tool_output.tail}} bytes of output; the full output is saved to a file whose path is shown. Timeout {{timeout}}s.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"Shell command, run with sh -c in the working directory"}},"required":["command"]}}
;

/// The schema of `arx tool edit`, the same as plugins/shell/tools/edit.json.
const edit_schema =
    \\{"description":"Replace an exact, unique string in a file, or create a new file when `old` is empty.","parameters":{"type":"object","properties":{"path":{"type":"string"},"old":{"type":"string","description":"Exact text to replace; it must occur exactly once. Empty creates a new file."},"new":{"type":"string","description":"Replacement text"}},"required":["path","old","new"]},"keys":["file:{path}"]}
;

/// What the edit tool produced.
const Outcome = struct {
    text: []const u8,
    is_error: bool = true,
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

/// The bash tool: becomes `sh -c <command>`, so it costs no extra process.
/// The command gets what a process tool got before: no stdin. (arx catches
/// SIGPIPE, and exec puts a caught signal back to its default.) Returns
/// only on a failure.
fn bash(a: *Agent, args: json.Value) Exit {
    const script = json.str(args, "command") orelse {
        render.printOut(a.ctx.io, "bash needs a string argument `command`", .{});
        return .@"error";
    };
    const fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    if (fd > 0) {
        _ = std.c.dup2(fd, 0);
        _ = std.c.close(fd);
    }
    const err = std.process.replace(a.ctx.io, .{ .argv = &.{ "sh", "-c", script }, .environ_map = a.ctx.environ });
    render.printOut(a.ctx.io, "cannot run sh: {s}", .{util.describeError(err)});
    return .@"error";
}

/// `arx tool bash|edit [--schema]`: runs a tool of the shell plugin, with
/// the arguments as JSON on stdin, or prints its schema. The result goes
/// to stdout; the exit code is 0, or 1 for an error.
pub fn command(a: *Agent, args: []const []const u8) !Exit {
    const name = if (args.len > 2) args[2] else "";
    const schema = if (std.mem.eql(u8, name, "bash")) bash_schema else if (std.mem.eql(u8, name, "edit")) edit_schema else {
        return options.usageError(a, "tool needs bash or edit", if (args.len > 2) args[2] else null);
    };
    if (args.len > 3 and std.mem.eql(u8, args[3], "--schema")) {
        render.printOut(a.ctx.io, "{s}\n", .{schema});
        return .done;
    }
    if (args.len > 3) return options.usageError(a, "unknown tool argument", args[3]);
    var arena: std.heap.ArenaAllocator = .init(a.ctx.gpa);
    defer arena.deinit();
    const t = arena.allocator();
    const raw = try options.readStdin(t);
    const parsed = try json.parseObject(t, raw) orelse {
        render.printOut(a.ctx.io, "the arguments are not a valid JSON object: {s}", .{util.cutPrefix(raw, 200)});
        return .@"error";
    };
    if (schema.ptr == bash_schema.ptr) return bash(a, parsed);
    const outcome = try edit(a, t, parsed);
    render.printOut(a.ctx.io, "{s}", .{outcome.text});
    return if (outcome.is_error) .@"error" else .done;
}
