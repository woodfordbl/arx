//! plugins.zig: the layers a harness is made of. The spec folder comes
//! first; plugins (folders with a plugin.yaml) and the user's config folder
//! add tools/, hooks/ and skills below it, so the agent's own files always
//! win. With an active list (active.zig), only its plugins load, in its
//! order. A plugin that is broken or needs a newer arx is skipped and
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
const own_keys = [_][]const u8{ "name", "version", "description", "arx", "requires", "hooks", "observers", "replaces" };

/// Builds spec.layers and spec.rows. With an active list (spec.active): the
/// spec folder, then each listed plugin in order, from <spec
/// dir>/plugins/<name>/ or else the config folder's. Without one: the spec
/// folder, its plugins/, then the config folder (when different) and its
/// plugins/, less those `disable` names. A plugin's tools, compactors and
/// observers merge under the spec; its hook options, settings and
/// `replaces` stay with its layer. A broken, missing or too-new plugin is
/// skipped and explained in spec.problems, so it cannot stop the harness.
pub fn load(ctx: *const Context, spec: *Spec) Allocator.Error!void {
    const a = spec.arena.?.allocator();
    var l: Loader = .{ .ctx = ctx, .spec = spec, .arena = a, .rows = json.array(a) };
    const skills = json.str(spec.root, "skills");
    try l.layers.append(a, .{
        .dir = spec.dir,
        .skills = if (skills) |s| try util.pathJoin(a, spec.dir, s) else null,
    });
    const config = try util.configDir(ctx, a);
    const other = !try sameDir(ctx, a, spec.dir, config);
    const all = spec.active == null;
    if (!all) try l.loadActive(if (other) config else null);
    try l.loadAll(try util.pathJoin(a, spec.dir, "plugins"), all);
    if (other) {
        // A kit or a list makes the harness exact: the spec folder and the
        // plugins it names, without loose files in the config folder.
        if (all) try l.layers.append(a, .{ .dir = config, .skills = try util.pathJoin(a, config, "skills") });
        try l.loadAll(try util.pathJoin(a, config, "plugins"), all);
    }
    spec.layers = l.layers.items;
    spec.problems = l.problems.items;
    spec.rows = l.rows;
}

/// True when `a` and `b` are the same folder.
fn sameDir(ctx: *const Context, arena: Allocator, a: []const u8, b: []const u8) Allocator.Error!bool {
    const ra = try util.realPath(ctx.io, arena, a) orelse a;
    const rb = try util.realPath(ctx.io, arena, b) orelse b;
    return std.mem.eql(u8, ra, rb);
}

const Loader = struct {
    ctx: *const Context,
    spec: *Spec,
    arena: Allocator,
    layers: std.ArrayList(Layer) = .empty,
    problems: std.ArrayList(u8) = .empty,
    /// [{name, state, why, dir}] for `arx check --list`.
    rows: json.Value,

    /// Adds a row for `arx check --list`.
    fn addRow(l: *Loader, name: []const u8, state: []const u8, why: []const u8, dir: []const u8) Allocator.Error!void {
        var row = json.object();
        for ([_][2][]const u8{ .{ "name", name }, .{ "state", state }, .{ "why", why }, .{ "dir", dir } }) |kv| try json.putString(l.arena, &row, kv[0], kv[1]);
        try l.rows.array.append(row);
    }

    /// True when the rows already have `name`: a project plugin hides a
    /// user plugin with the same name.
    fn have(l: *const Loader, name: []const u8) bool {
        for (json.items(l.rows)) |row| if (std.mem.eql(u8, json.strOr(row, "name", ""), name)) return true;
        return false;
    }

    /// Why an installed plugin that is not in the active list is off.
    fn offWhy(l: *const Loader, name: []const u8) Allocator.Error![]const u8 {
        if (json.str(l.spec.off, name)) |why| return why;
        if (l.spec.kit) |kit| return l.arena.print("not in kit {s}", .{kit});
        return "not in the plugins list";
    }

    /// Loads every plugin folder in `parent`, in name order, when there is
    /// no active list (`all`), or else adds a row for each one that is off.
    /// Folders without a plugin.yaml are not plugins and are passed over.
    fn loadAll(l: *Loader, parent: []const u8, all: bool) Allocator.Error!void {
        for (try util.listNames(l.ctx.io, l.arena, parent)) |name| {
            const dir = try std.mem.concat(l.arena, u8, &.{ parent, "/", name });
            if (util.stat(l.ctx.io, try std.mem.concat(l.arena, u8, &.{ dir, "/plugin.yaml" })) == null or l.have(name)) continue;
            if (all and json.str(l.spec.off, name) == null) {
                try l.loadOne(dir, name, "installed");
            } else {
                try l.addRow(name, "off", try l.offWhy(name), dir);
            }
        }
    }

    /// Loads the plugins of the active list, in its order: each from the
    /// spec's plugins/ folder, else from the config folder's.
    fn loadActive(l: *Loader, config: ?[]const u8) Allocator.Error!void {
        const a = l.arena;
        for (json.items(l.spec.active)) |row| {
            const name = json.strOr(row, "name", "");
            const why = json.strOr(row, "why", "");
            const dir = for ([_]?[]const u8{ l.spec.dir, config }) |parent| {
                const p = parent orelse continue;
                const d = try std.mem.concat(a, u8, &.{ p, "/plugins/", name });
                if (util.stat(l.ctx.io, try std.mem.concat(a, u8, &.{ d, "/plugin.yaml" })) != null) break d;
            } else null;
            if (dir) |d| {
                try l.loadOne(d, name, why);
            } else {
                try l.problems.print(a, "- plugin {s} ({s}) is not installed: run `arx plugin add {s}`\n", .{ name, why, name });
                try l.addRow(name, "missing", why, "");
            }
        }
    }

    /// Loads the plugin in `dir`, named after its folder; `why` says why it
    /// is on. A problem skips it.
    fn loadOne(l: *Loader, dir: []const u8, name: []const u8, why: []const u8) Allocator.Error!void {
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
            try l.addRow(name, "broken", "skipped: see arx check", where);
        } else {
            try l.adopt(doc.?, where, name);
            try l.addRow(name, "on", why, where);
        }
    }

    /// Merges a checked plugin.yaml under the spec and adds its layer.
    fn adopt(l: *Loader, plugin: Doc, dir: []const u8, name: []const u8) Allocator.Error!void {
        const a = l.arena;
        var root = plugin.root;
        const settings = json.field(l.spec.settings, name);
        // Settings may set the plugin's own tool and hook options.
        for ([_][]const u8{ "tools", "hooks" }) |key| {
            const over = json.field(settings, key) orelse continue;
            if (over != .object) continue;
            const base = json.getPtr(&root, key);
            if (base == null or base.?.* != .object) try json.put(a, &root, key, json.object());
            try spec_mod.mergeOver(a, json.getPtr(&root, key).?, over);
        }
        try l.layers.append(a, .{
            .dir = dir,
            .plugin = name,
            .skills = try util.pathJoin(a, dir, "skills"),
            .hooks = json.field(root, "hooks"),
            .settings = settings,
            .replaces = json.field(root, "replaces"),
        });
        for (json.values(json.field(root, "tools"))) |*tool| {
            if (json.getPtr(tool, "agent")) |agent| try absolute(a, agent, dir);
        }
        if (json.getPtr(&root, "compactors")) |compactors| {
            for (json.values(compactors.*)) |*path| try absolute(a, path, dir);
        }
        const mine = json.items(json.field(root, "observers"));
        if (mine.len > 0 and json.field(l.spec.root, "observers") == null) try json.put(a, &l.spec.root, "observers", json.array(a));
        const all = json.getPtr(&l.spec.root, "observers");
        if (all != null and all.?.* == .array) for (mine) |command| {
            if (command == .string) try all.?.array.append(.{ .string = try withPluginDir(a, dir, command.string) });
        };
        for (own_keys) |key| _ = root.object.orderedRemove(key);
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
    const need = if (std.mem.startsWith(u8, constraint, ">=")) versionNumber(std.mem.trimStart(u8, constraint[2..], " ")) else null;
    const need_number = need orelse return try a.print("arx: \"{s}\" must look like \">=0.2.0\"", .{constraint});
    if (std.mem.findScalar(u8, version, '-') != null) return null;
    const have = versionNumber(version) orelse return null;
    if (have < need_number) return try a.print("needs arx {s}, and this is arx {s}", .{ constraint, version });
    return null;
}

/// Parses and checks `dir`/plugin.yaml into `arena`. Returns null, with the
/// problems in `err`, when it is not a usable plugin.
pub fn readPlugin(ctx: *const Context, arena: Allocator, dir: []const u8, err: *std.ArrayList(u8)) Allocator.Error!?Doc {
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
