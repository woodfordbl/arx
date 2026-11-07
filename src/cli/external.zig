//! external.zig: `arx foo` runs `arx-foo`, the way git runs git-foo.
//! Commands like setup and update are small scripts, so the binary stays
//! small and anyone can add a command: in ~/.config/arx/commands/, in a
//! plugin's commands/, or on PATH. The first match wins, and arx's own
//! commands come first, so a plugin can add a command but not replace one.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const proc = @import("../base/proc.zig");
const Context = @import("../base/context.zig").Context;
const render = @import("../io/render.zig");
const Agent = @import("../agent/agent.zig").Agent;
const options = @import("options.zig");
const commands = @import("commands.zig");
const Exit = util.Exit;

/// The most external commands `arx help` lists.
const max_listed = 64;

/// The folders to search, in order: arx's own commands, the user's, each
/// user plugin's, then PATH. The strings live in `arena`.
fn searchDirs(ctx: *const Context, arena: Allocator) Allocator.Error![]const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    const config = try util.configDir(ctx, arena);
    const plugins = try std.mem.concat(arena, u8, &.{ config, "/plugins" });
    const bin = util.dirName(ctx.self_path);
    try dirs.append(arena, try std.mem.concat(arena, u8, &.{ bin, "/../libexec/arx" })); // installed
    try dirs.append(arena, try std.mem.concat(arena, u8, &.{ bin, "/commands" })); // source checkout
    try dirs.append(arena, try std.mem.concat(arena, u8, &.{ config, "/commands" }));
    const names = try util.listNames(ctx.io, arena, plugins);
    for (names) |name| try dirs.append(arena, try std.mem.concat(arena, u8, &.{ plugins, "/", name, "/commands" }));
    var path = std.mem.splitScalar(u8, ctx.getenv("PATH") orelse "", ':');
    while (path.next()) |dir| if (dir.len > 0) try dirs.append(arena, dir);
    return dirs.items;
}

/// True when `path` is an executable regular file.
fn isCommand(ctx: *const Context, path: []const u8) bool {
    const info = util.stat(ctx.io, path) orelse return false;
    return info.kind == .file and util.isExecutable(ctx.io, path);
}

/// The path of the external command `arx-<name>`, or null. The result lives
/// in `arena`.
pub fn find(ctx: *const Context, arena: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
    for (try searchDirs(ctx, arena)) |dir| {
        const path = try std.mem.concat(arena, u8, &.{ dir, "/arx-", name });
        if (isCommand(ctx, path)) return path;
    }
    return null;
}

/// Runs `arx-<name>` with args[2..], with ARX_BIN and ARX_LIBEXEC set (and
/// ARX_PLUGIN_DIR for a user plugin's command). Does not return on success;
/// returns null when there is no such command.
pub fn run(ctx: *const Context, name: []const u8, args: []const []const u8) Allocator.Error!?Exit {
    if (std.mem.findScalar(u8, name, '/') != null) return null;
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = (try find(ctx, a, name)) orelse return null;
    const dir = util.dirName(path);
    var extra: std.ArrayList([2][]const u8) = .empty;
    try extra.appendSlice(a, &.{ .{ "ARX_BIN", ctx.self_path }, .{ "ARX_LIBEXEC", dir } });
    // A command in ~/.config/arx/plugins/<name>/commands belongs to that plugin.
    const plugin = util.dirName(dir);
    const plugins = try std.mem.concat(a, u8, &.{ try util.configDir(ctx, a), "/plugins" });
    if (std.mem.eql(u8, util.dirName(plugin), plugins)) try extra.append(a, .{ "ARX_PLUGIN_DIR", plugin });
    var env = try proc.environWith(ctx.gpa, ctx.environ, extra.items);
    defer env.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, path);
    if (args.len > 2) try argv.appendSlice(a, args[2..]);
    const err = std.process.replace(ctx.io, .{ .argv = argv.items, .environ_map = &env });
    render.printErr(ctx.io, "arx: cannot run {s}: {s}\n", .{ path, util.describeError(err) });
    return .@"error";
}

/// A command's summary from its "# arx-<name>: summary" line.
fn summary(ctx: *const Context, arena: Allocator, path: []const u8, name: []const u8) Allocator.Error![]const u8 {
    const text = (try util.readFile(ctx.io, arena, path)) orelse return "";
    const marker = try std.mem.concat(arena, u8, &.{ "# arx-", name, ": " });
    const at = std.mem.find(u8, text, marker) orelse return "";
    if (at >= 512) return "";
    const rest = text[at + marker.len ..];
    return rest[0 .. std.mem.findScalar(u8, rest, '\n') orelse rest.len];
}

/// Prints every command with its summary.
fn printCommands(ctx: *const Context, out: *std.Io.Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    for (try searchDirs(ctx, a)) |dir| {
        const entries = try util.listNames(ctx.io, a, dir);
        for (entries) |entry| {
            if (names.items.len >= max_listed) break;
            if (!std.mem.startsWith(u8, entry, "arx-") or entry.len == 4) continue;
            const name = entry[4..];
            const builtin = for (commands.all) |c| {
                if (std.mem.eql(u8, c.name, name)) break true;
            } else false;
            const seen = for (names.items) |n| {
                if (std.mem.eql(u8, n, name)) break true;
            } else false;
            if (builtin or seen) continue;
            if (isCommand(ctx, try std.mem.concat(a, u8, &.{ dir, "/", entry }))) try names.append(a, name);
        }
    }
    util.sortStrings(names.items);
    try out.writeAll("commands:\n");
    for (names.items) |name| {
        const path = (try find(ctx, a, name)) orelse continue;
        try out.print("  {s:<10} {s}\n", .{ name, try summary(ctx, a, path, name) });
    }
    for (commands.all) |c| try out.print("  {s:<10} {s}\n", .{ c.name, c.summary });
}

/// `arx help [COMMAND]`: everything, or one command (an external command
/// prints its own help with --help).
pub fn helpCommand(a: *Agent, args: []const []const u8) anyerror!Exit {
    const ctx = a.ctx;
    if (args.len > 2) {
        const help_args = [_][]const u8{ args[0], args[2], "--help" };
        if (try commands.run(a, args[2], &help_args)) |code| return code;
        if (try run(ctx, args[2], &help_args)) |code| return code;
        return options.usageError(a, "no such command", args[2]);
    }
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(ctx.io, &buf);
    const out = &w.interface;
    try out.print(
        \\arx {s}: a minimal, self-improving agent harness
        \\
        \\usage: arx [options]          run the agent (interactive, or headless if stdin is piped)
        \\       arx -p TASK [options]  run one task until the agent stops
        \\       arx COMMAND [args]     run a command
        \\
        \\
    , .{ctx.version});
    try printCommands(ctx, out);
    try out.writeAll("\n" ++ options.help);
    try out.writeAll("\nRun `arx help COMMAND` for one command. Docs: docs/plugins.md\n");
    try out.flush();
    return .done;
}
