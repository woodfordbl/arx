//! describe.zig: `arx check --plugin DIR`: reads and checks one plugin
//! without loading it, and prints key=value lines for scripts such as
//! `arx plugin`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const Context = @import("../base/context.zig").Context;
const plugins = @import("plugins.zig");

/// True when `program` is an executable on PATH, or at its path when it
/// has a '/'.
fn onPath(ctx: *const Context, a: Allocator, program: []const u8) Allocator.Error!bool {
    if (std.mem.findScalar(u8, program, '/') != null) return util.isExecutable(ctx.io, program);
    var dirs = std.mem.splitScalar(u8, ctx.getenv("PATH") orelse "", ':');
    while (dirs.next()) |dir| {
        if (dir.len > 0 and util.isExecutable(ctx.io, try std.mem.concat(a, u8, &.{ dir, "/", program }))) return true;
    }
    return false;
}

/// Appends "key=value", with line breaks turned into spaces.
fn field(gpa: Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) Allocator.Error!void {
    try out.print(gpa, "{s}=", .{key});
    for (value) |ch| try out.append(gpa, if (ch == '\n' or ch == '\r') ' ' else ch);
    try out.append(gpa, '\n');
}

/// The entries of `dir`, space-separated. With `inner`, only entries that
/// have `dir/<entry>/<inner>`.
fn entries(ctx: *const Context, a: Allocator, dir: []const u8, inner: ?[]const u8) Allocator.Error![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    for (try util.listNames(ctx.io, a, dir)) |entry| {
        // tools/<name>.json is the schema of a tool, not a tool.
        if (inner == null and std.mem.eql(u8, util.baseName(dir), "tools") and entry.len > 5 and std.mem.endsWith(u8, entry, ".json")) continue;
        if (inner) |file| if (!util.isReadable(ctx.io, try std.mem.concat(a, u8, &.{ dir, "/", entry, "/", file }))) continue;
        if (list.items.len > 0) try list.append(a, ' ');
        try list.appendSlice(a, entry);
    }
    return list.items;
}

/// Reads and checks the plugin in `dir` without loading it, for `arx check
/// --plugin`. Appends "key=value" lines to `out` (name, version,
/// description, arx, requires, missing, tools, hooks, skills, commands).
/// Returns false, with the problems in `err`, when it is not usable.
pub fn describe(ctx: *const Context, dir: []const u8, out: *std.ArrayList(u8), err: *std.ArrayList(u8)) Allocator.Error!bool {
    const gpa = ctx.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = (try plugins.readPlugin(ctx, a, dir, err)) orelse return false;
    const real = (try util.realPath(ctx.io, a, dir)) orelse dir;
    try field(gpa, out, "name", json.strOr(doc.root, "name", util.baseName(real)));
    for ([_][]const u8{ "version", "description", "arx" }) |key| try field(gpa, out, key, json.strOr(doc.root, key, ""));
    var requires: std.ArrayList(u8) = .empty;
    var missing: std.ArrayList(u8) = .empty;
    for (json.items(json.field(doc.root, "requires"))) |item| {
        if (item != .string) continue;
        try requires.print(a, "{s}{s}", .{ if (requires.items.len > 0) " " else "", item.string });
        if (!try onPath(ctx, a, item.string)) try missing.print(a, "{s}{s}", .{ if (missing.items.len > 0) " " else "", item.string });
    }
    try field(gpa, out, "requires", requires.items);
    try field(gpa, out, "missing", missing.items);
    for ([_][]const u8{ "tools", "hooks", "skills", "commands" }) |key| {
        const inner: ?[]const u8 = if (std.mem.eql(u8, key, "skills")) "SKILL.md" else null;
        try field(gpa, out, key, try entries(ctx, a, try util.pathJoin(a, dir, key), inner));
    }
    return true;
}
