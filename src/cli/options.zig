//! options.zig: option parsing, spec lookup and usage errors, shared by the
//! agent and the built-in commands.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const render = @import("../io/render.zig");
const spec_mod = @import("../harness/spec.zig");
const Agent = @import("../agent/agent.zig").Agent;
const Exit = util.Exit;

/// The options section of `arx help`.
pub const help =
    \\options:
    \\  -p TASK|-             run one task (- reads it from stdin)
    \\  --spec PATH           agent spec (default ./agent.yaml, else your
    \\                        defaults from `arx setup`)
    \\  --kit NAME            use an installed kit (its plugins, in order,
    \\                        and its prompt); the agent cannot change it
    \\  --set KEY=VALUE       override a spec value, e.g. model=...
    \\  --cap KEY=VALUE       hard limit: turns, tokens, usd, wall, depth
    \\  --resume ID|last      continue a session
    \\  --json                print the result as JSON
    \\  --events PATH|-|fd:N  also write the event stream there
    \\  --quiet               no terminal view
    \\
    \\exit codes: 0 done, 1 error, 2 usage, 3 cap reached, 4 auth, 130 interrupted
    \\
;

/// Prints "arx: <what>: <arg>" and a pointer to `arx help` on stderr.
pub fn usageError(a: *const Agent, what: []const u8, arg: ?[]const u8) Exit {
    render.printErr(a.ctx.io, "arx: {s}{s}{s}\nRun `arx help` for usage.\n", .{ what, if (arg != null) ": " else "", arg orelse "" });
    return .usage;
}

/// Parses the options shared by the agent, check and tools, from
/// args[first..]. Returns an exit code on a usage error.
pub fn parse(a: *Agent, args: []const []const u8, first: usize) Allocator.Error!?Exit {
    var i = first;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            a.json_output = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            a.quiet = true;
            continue;
        }
        if (i + 1 >= args.len) return usageError(a, "missing value or unknown option", arg);
        const value = args[i + 1];
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--prompt")) {
            a.prompt = value;
        } else if (std.mem.eql(u8, arg, "--spec")) {
            a.spec_path = value;
        } else if (std.mem.eql(u8, arg, "--resume")) {
            a.resume_ref = value;
        } else if (std.mem.eql(u8, arg, "--events")) {
            a.events_target = value;
        } else if (std.mem.eql(u8, arg, "--kit")) {
            // The same as --set kit=NAME, so it stays in force after a reload.
            _ = a.sets.object.orderedRemove("kit");
            try json.putString(a.sets_arena.allocator(), &a.sets, "kit", value);
        } else if (std.mem.eql(u8, arg, "--set")) {
            if (!try spec_mod.addSet(a.sets_arena.allocator(), &a.sets, value)) return usageError(a, "bad --set", value);
        } else if (std.mem.eql(u8, arg, "--cap")) {
            if (!a.caps.parse(value)) return usageError(a, "bad --cap", value);
            try a.cap_args.append(a.ctx.gpa, value);
        } else {
            return usageError(a, "unknown option", arg);
        }
        i += 1;
    }
    return null;
}

/// Uses ./agent.yaml when --spec was not given and it exists; otherwise the
/// spec stays null and the user's saved defaults are used.
pub fn resolveSpec(a: *Agent) void {
    if (a.spec_path == null and util.isReadable(a.ctx.io, "agent.yaml")) a.spec_path = "agent.yaml";
}

/// Reads all of stdin. Caller owns the result.
pub fn readStdin(gpa: Allocator) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &chunk, chunk.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        try out.appendSlice(gpa, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(gpa);
}
