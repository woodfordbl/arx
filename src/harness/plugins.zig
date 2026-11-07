//! plugins.zig: the layers a harness is made of. The spec folder comes
//! first; plugins (folders with a plugin.yaml) and the user's config folder
//! add tools/, hooks/ and skills below it, so the agent's own files always
//! win. A plugin that is broken or needs a newer arx is skipped and
//! explained, so it cannot stop the harness.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const Context = @import("../base/context.zig").Context;
const spec_mod = @import("spec.zig");
const Spec = spec_mod.Spec;
const Doc = spec_mod.Doc;
const Layer = spec_mod.Layer;
const validate = @import("validate.zig");

/// plugin.yaml keys that describe the plugin, or that `adopt` handles
/// itself, so they are not merged into the spec.
const own_keys = [_][]const u8{ "name", "version", "description", "arx", "requires", "hooks", "observers" };

/// Builds spec.layers, in this order: the spec folder; the plugins in
/// <spec dir>/plugins/<name>/; then, when it is a different folder, the
/// user's config folder and its plugins/<name>/. A plugin's tools,
/// compactors and observers merge under the spec (the spec wins), and its
/// hook options stay with its layer. The spec's `plugins:` list, when set,
/// names the only plugins to use, and leaves out the config folder's own
/// tools/, hooks/ and skills/.
pub fn load(ctx: *const Context, spec: *Spec) Allocator.Error!void {
    const a = spec.arena.?.allocator();
    var loader: Loader = .{ .ctx = ctx, .spec = spec, .arena = a };
    const skills = json.str(spec.root, "skills");
    try loader.layers.append(a, .{
        .dir = spec.dir,
        .skills = if (skills) |s| try util.pathJoin(a, spec.dir, s) else null,
    });
    try loader.loadAll(try util.pathJoin(a, spec.dir, "plugins"));
    const config = try util.configDir(ctx, a);
    if (!try sameDir(ctx, spec.dir, config)) {
        // A `plugins:` list makes the harness exact: the spec folder and the
        // plugins it names, without loose files in the config folder.
        if (json.field(spec.root, "plugins") == null or json.field(spec.root, "plugins").? != .array) {
            try loader.layers.append(a, .{ .dir = config, .skills = try util.pathJoin(a, config, "skills") });
        }
        try loader.loadAll(try util.pathJoin(a, config, "plugins"));
    }
    spec.layers = loader.layers.items;
    spec.problems = loader.problems.items;
}

/// True when `a` and `b` are the same folder.
fn sameDir(ctx: *const Context, a: []const u8, b: []const u8) Allocator.Error!bool {
    const ra = try util.realPath(ctx.io, ctx.gpa, a);
    defer if (ra) |p| ctx.gpa.free(p);
    const rb = try util.realPath(ctx.io, ctx.gpa, b);
    defer if (rb) |p| ctx.gpa.free(p);
    if (ra != null and rb != null) return std.mem.eql(u8, ra.?, rb.?);
    return std.mem.eql(u8, a, b);
}

const Loader = struct {
    ctx: *const Context,
    spec: *Spec,
    arena: Allocator,
    layers: std.ArrayList(Layer) = .empty,
    problems: std.ArrayList(u8) = .empty,

    /// True when a plugin named `name` is already a layer: a project plugin
    /// hides a user plugin with the same name.
    fn have(l: *const Loader, name: []const u8) bool {
        for (l.layers.items) |layer| {
            if (layer.plugin) |p| if (std.mem.eql(u8, p, name)) return true;
        }
        return false;
    }

    /// True when the spec's `plugins:` list names `name`, or there is no
    /// list.
    fn allowed(l: *const Loader, name: []const u8) bool {
        const list = json.field(l.spec.root, "plugins") orelse return true;
        if (list != .array) return true;
        for (list.array.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, name)) return true;
        }
        return false;
    }

    /// Loads every plugin folder in `parent`, in name order. Folders without
    /// a plugin.yaml are not plugins and are passed over.
    fn loadAll(l: *Loader, parent: []const u8) Allocator.Error!void {
        const gpa = l.ctx.gpa;
        const names = try util.listNames(l.ctx.io, gpa, parent);
        defer util.freeNames(gpa, names);
        for (names) |name| {
            const dir = try std.mem.concat(l.arena, u8, &.{ parent, "/", name });
            const yaml_path = try std.mem.concat(gpa, u8, &.{ dir, "/plugin.yaml" });
            defer gpa.free(yaml_path);
            if (util.exists(l.ctx.io, yaml_path) and l.allowed(name) and !l.have(name)) {
                try l.loadOne(dir, try l.arena.dupe(u8, name));
            }
        }
    }

    /// Loads the plugin in `dir`, named after its folder. A problem skips it.
    fn loadOne(l: *Loader, dir: []const u8, name: []const u8) Allocator.Error!void {
        const gpa = l.ctx.gpa;
        var err: std.ArrayList(u8) = .empty;
        defer err.deinit(gpa);
        // Absolute, so ARX_PLUGIN_DIR is too.
        const where = if (try util.realPath(l.ctx.io, l.arena, dir)) |real| real else dir;
        const doc = try readPlugin(l.ctx, l.arena, where, &err);
        if (doc) |d| {
            const own = json.strOr(d.root, "name", name);
            if (!std.mem.eql(u8, own, name)) {
                try err.print(gpa, "{s}: name \"{s}\" must match the folder name\n", .{ d.path, own });
            }
        }
        if (err.items.len > 0) {
            try l.problems.print(l.arena, "- plugin {s} was skipped:\n{s}", .{ name, err.items });
        } else {
            try l.adopt(doc.?, where, name);
        }
    }

    /// Merges a checked plugin.yaml under the spec and adds its layer.
    fn adopt(l: *Loader, plugin: Doc, dir: []const u8, name: []const u8) Allocator.Error!void {
        const a = l.arena;
        var root = plugin.root;
        try l.layers.append(a, .{
            .dir = dir,
            .plugin = name,
            .skills = try util.pathJoin(a, dir, "skills"),
            .hooks = json.field(root, "hooks"),
        });
        for (json.values(json.field(root, "tools"))) |*tool| {
            if (json.getPtr(tool, "agent")) |agent| try absolute(a, agent, dir);
        }
        if (json.getPtr(&root, "compactors")) |compactors| {
            for (json.values(compactors.*)) |*path| try absolute(a, path, dir);
        }
        const mine = json.items(json.field(root, "observers"));
        if (mine.len > 0 and json.field(l.spec.root, "observers") == null) {
            try json.put(a, &l.spec.root, "observers", json.array(a));
        }
        if (json.getPtr(&l.spec.root, "observers")) |all| {
            if (all.* == .array) {
                for (mine) |command| {
                    if (command != .string) continue;
                    try all.array.append(.{ .string = try withPluginDir(a, dir, command.string) });
                }
            }
        }
        for (own_keys) |key| json.remove(&root, key);
        var merged = plugin;
        merged.root = root;
        try spec_mod.mergeUnder(l.spec, merged);
    }
};

/// Makes a path value absolute, relative to `dir`.
fn absolute(a: Allocator, node: *json.Value, dir: []const u8) Allocator.Error!void {
    if (node.* != .string) return;
    node.* = .{ .string = try util.pathJoin(a, dir, node.string) };
}

/// Wraps an observer command so that it runs with ARX_PLUGIN_DIR set.
fn withPluginDir(a: Allocator, dir: []const u8, command: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "export ARX_PLUGIN_DIR='");
    for (dir) |ch| {
        if (ch == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, ch);
    }
    try out.print(a, "'; {s}", .{command});
    return out.items;
}

/// "1.2.3" as one comparable number (missing parts count as 0), or null
/// when `s` does not start with a digit, as in a build of an untagged
/// commit.
fn versionNumber(s: []const u8) ?i64 {
    if (s.len == 0 or !std.ascii.isDigit(s[0])) return null;
    var v: i64 = 0;
    var i: usize = 0;
    for (0..3) |_| {
        var n: i64 = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) n = n *| 10 +| (s[i] - '0');
        v = v *| 100000 +| n;
        if (i < s.len and s[i] == '.') i += 1;
    }
    return v;
}

/// Why this arx cannot use a plugin whose `arx:` is `constraint` (">=0.2"),
/// or null when it can. A build that is not a release ("0.1.0-4-gabc1234",
/// or no number at all) accepts any plugin.
fn versionProblem(a: Allocator, constraint: []const u8, version: []const u8) Allocator.Error!?[]u8 {
    const ok = std.mem.startsWith(u8, constraint, ">=");
    const need = if (ok) std.mem.trimStart(u8, constraint[2..], " ") else "";
    const need_number = versionNumber(need) orelse
        return try a.print("arx: \"{s}\" must look like \">=0.2.0\"", .{constraint});
    if (!ok) return try a.print("arx: \"{s}\" must look like \">=0.2.0\"", .{constraint});
    if (std.mem.findScalar(u8, version, '-') != null) return null;
    const have = versionNumber(version) orelse return null;
    if (have < need_number) return try a.print("needs arx {s}, and this is arx {s}", .{ constraint, version });
    return null;
}

/// Parses and checks `dir`/plugin.yaml into `arena`. Returns null, with the
/// problems in `err`, when it is not a usable plugin.
fn readPlugin(ctx: *const Context, arena: Allocator, dir: []const u8, err: *std.ArrayList(u8)) Allocator.Error!?Doc {
    const before = err.items.len;
    const path = try std.mem.concat(arena, u8, &.{ dir, "/plugin.yaml" });
    if (!util.isReadable(ctx.io, path)) {
        try err.print(ctx.gpa, "{s}: not a plugin (no plugin.yaml)\n", .{dir});
        return null;
    }
    const doc = (try spec_mod.parseFile(ctx, arena, path, err)) orelse return null;
    try validate.plugin(ctx, doc, err);
    if (json.str(doc.root, "arx")) |constraint| {
        if (try versionProblem(arena, constraint, ctx.version)) |why| try err.print(ctx.gpa, "{s}: {s}\n", .{ path, why });
    }
    return if (err.items.len == before) doc else null;
}

/// True when `program` is an executable on PATH, or at its path when it
/// has a '/'.
fn onPath(ctx: *const Context, program: []const u8) Allocator.Error!bool {
    if (std.mem.findScalar(u8, program, '/') != null) return util.isExecutable(ctx.io, program);
    var dirs = std.mem.splitScalar(u8, ctx.getenv("PATH") orelse "", ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const full = try std.mem.concat(ctx.gpa, u8, &.{ dir, "/", program });
        defer ctx.gpa.free(full);
        if (util.isExecutable(ctx.io, full)) return true;
    }
    return false;
}

/// Appends "key=value", with line breaks turned into spaces.
fn field(gpa: Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) Allocator.Error!void {
    try out.print(gpa, "{s}=", .{key});
    for (value) |ch| try out.append(gpa, if (ch == '\n' or ch == '\r') ' ' else ch);
    try out.append(gpa, '\n');
}

/// Appends "key=" and the entries of `dir`, space-separated. With `inner`,
/// only entries that have `dir/<entry>/<inner>`.
fn listField(ctx: *const Context, out: *std.ArrayList(u8), key: []const u8, dir: []const u8, inner: ?[]const u8) Allocator.Error!void {
    const gpa = ctx.gpa;
    const entries = try util.listNames(ctx.io, gpa, dir);
    defer util.freeNames(gpa, entries);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    for (entries) |entry| {
        if (inner) |file| {
            const path = try std.mem.concat(gpa, u8, &.{ dir, "/", entry, "/", file });
            defer gpa.free(path);
            if (!util.isReadable(ctx.io, path)) continue;
        }
        if (list.items.len > 0) try list.append(gpa, ' ');
        try list.appendSlice(gpa, entry);
    }
    try field(gpa, out, key, list.items);
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
    const doc = (try readPlugin(ctx, a, dir, err)) orelse return false;
    const real = (try util.realPath(ctx.io, a, dir)) orelse dir;
    try field(gpa, out, "name", json.strOr(doc.root, "name", util.baseName(real)));
    try field(gpa, out, "version", json.strOr(doc.root, "version", ""));
    try field(gpa, out, "description", json.strOr(doc.root, "description", ""));
    try field(gpa, out, "arx", json.strOr(doc.root, "arx", ""));
    var requires: std.ArrayList(u8) = .empty;
    var missing: std.ArrayList(u8) = .empty;
    for (json.items(json.field(doc.root, "requires"))) |item| {
        if (item != .string) continue;
        if (requires.items.len > 0) try requires.append(a, ' ');
        try requires.appendSlice(a, item.string);
        if (!try onPath(ctx, item.string)) {
            if (missing.items.len > 0) try missing.append(a, ' ');
            try missing.appendSlice(a, item.string);
        }
    }
    try field(gpa, out, "requires", requires.items);
    try field(gpa, out, "missing", missing.items);
    try listField(ctx, out, "tools", try util.pathJoin(a, dir, "tools"), null);
    try listField(ctx, out, "hooks", try util.pathJoin(a, dir, "hooks"), null);
    try listField(ctx, out, "skills", try util.pathJoin(a, dir, "skills"), "SKILL.md");
    try listField(ctx, out, "commands", try util.pathJoin(a, dir, "commands"), null);
    return true;
}

test "plugin version constraints" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(try versionProblem(a, ">=0.2", "0.3.0") == null);
    try std.testing.expect(try versionProblem(a, ">=999.0", "0.3.0") != null);
    try std.testing.expect(try versionProblem(a, ">=999.0", "0.3.0-4-gabc") == null);
    try std.testing.expect(try versionProblem(a, ">=999.0", "dev") == null);
    try std.testing.expect(try versionProblem(a, "latest", "0.3.0") != null);
}
