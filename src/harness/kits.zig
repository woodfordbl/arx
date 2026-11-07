//! kits.zig: kits. A kit is a folder with a kit.yaml, prompts/ and init/,
//! and no executables: it chooses the plugins of a run, their order, their
//! settings and the prompt, and so makes one kind of agent. If something
//! runs, it belongs in a plugin; a kit only chooses.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const Context = @import("../base/context.zig").Context;
const spec_mod = @import("spec.zig");
const Spec = spec_mod.Spec;
const Doc = spec_mod.Doc;
const validate = @import("validate.zig");
const active = @import("active.zig");

/// How deep `extends` may go, which also stops a kit that extends itself.
const max_extends = 8;

/// A kit with its extends resolved.
pub const Kit = struct {
    dir: []const u8 = "",
    /// Its plugin list, in order (raw entries).
    plugins: ?json.Value = null,
    model_settings: ?json.Value = null,
    /// The absolute path of its prompt file.
    prompt: ?[]const u8 = null,
    /// Some entry names an exact version (@ref).
    pinned: bool = false,
};

/// The folder of the installed kit `name`: kits/<name> next to the spec,
/// else in the config folder; null if neither has a kit.yaml.
fn find(ctx: *const Context, a: Allocator, spec_dir: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
    if (name.len == 0 or std.mem.findScalar(u8, name, '/') != null) return null;
    for ([_][]const u8{ spec_dir, try util.configDir(ctx, a) }) |parent| {
        const dir = try std.mem.concat(a, u8, &.{ parent, "/kits/", name });
        if (util.isReadable(ctx.io, try std.mem.concat(a, u8, &.{ dir, "/kit.yaml" }))) return dir;
    }
    return null;
}

/// The first executable file under `dir`, or null.
fn findExecutable(ctx: *const Context, a: Allocator, dir: []const u8, depth: usize) Allocator.Error!?[]const u8 {
    if (depth >= 16) return null;
    for (try util.listNames(ctx.io, a, dir)) |name| {
        const path = try std.mem.concat(a, u8, &.{ dir, "/", name });
        const info = util.stat(ctx.io, path) orelse continue;
        if (info.kind == .directory) {
            if (try findExecutable(ctx, a, path, depth + 1)) |found| return found;
        } else if (info.mode & 0o111 != 0) return path;
    }
    return null;
}

/// Parses and checks `dir`/kit.yaml. Returns null, with the problems in
/// `err`, when it is not a usable kit.
fn read(ctx: *const Context, a: Allocator, dir: []const u8, err: *std.ArrayList(u8)) Allocator.Error!?Doc {
    const gpa = ctx.gpa;
    const before = err.items.len;
    const path = try std.mem.concat(a, u8, &.{ dir, "/kit.yaml" });
    var doc: ?Doc = null;
    if (!util.isReadable(ctx.io, path)) {
        try err.print(gpa, "{s}: not a kit (no kit.yaml)\n", .{dir});
    } else if (try spec_mod.parseFile(ctx, a, path, err)) |d| {
        doc = d;
        try validate.kit(ctx, d, err);
    }
    if (try findExecutable(ctx, a, dir, 0)) |exe| {
        try err.print(gpa, "{s}: is executable, and a kit holds no code (put it in a plugin, or chmod -x it)\n", .{exe});
    }
    return if (err.items.len == before) doc else null;
}

/// The entry of `list` that names the same plugin as `entry`.
fn findEntry(list: json.Value, entry: json.Value) ?usize {
    const name = active.entryName(entry);
    for (json.items(list), 0..) |item, i| if (std.mem.eql(u8, active.entryName(item), name)) return i;
    return null;
}

/// True when an entry of `list` names an exact version (name@ref).
fn pinned(list: json.Value) bool {
    for (json.items(list)) |entry| {
        const ref = if (entry == .string) entry.string else if (entry == .object and entry.object.count() > 0) entry.object.keys()[0] else "";
        if (std.mem.findScalar(u8, ref, '@') != null) return true;
    }
    return false;
}

/// Loads the kit `name` (kits/<name> next to the spec, else in the config
/// folder) and the kits it extends, into `a`. Returns null, with the
/// problem in `err`, when it is missing, not valid, or holds an executable.
pub fn load(ctx: *const Context, a: Allocator, spec_dir: []const u8, name: []const u8, err: *std.ArrayList(u8)) Allocator.Error!?Kit {
    var kit: Kit = .{};
    return if (try loadInto(ctx, a, spec_dir, name, &kit, err, 0)) kit else null;
}

/// Loads kit `name` into `kit`, with the kits it extends below it.
fn loadInto(ctx: *const Context, a: Allocator, spec_dir: []const u8, name: []const u8, kit: *Kit, err: *std.ArrayList(u8), depth: usize) Allocator.Error!bool {
    const gpa = ctx.gpa;
    const dir = (try find(ctx, a, spec_dir, name)) orelse {
        try err.print(gpa, "kit {s} is not installed: run `arx kit add {s}`\n", .{ name, name });
        return false;
    };
    const doc = (try read(ctx, a, dir, err)) orelse return false;
    const own = json.strOr(doc.root, "name", name);
    if (!std.mem.eql(u8, own, name)) {
        try err.print(gpa, "{s}: name \"{s}\" must match the folder name\n", .{ doc.path, own });
        return false;
    }
    if (json.str(doc.root, "extends")) |parent| {
        if (depth >= max_extends) {
            try err.print(gpa, "{s}: extends goes more than {d} kits deep\n", .{ doc.path, max_extends });
            return false;
        }
        if (!try loadInto(ctx, a, spec_dir, parent, kit, err, depth + 1)) return false;
    }
    if (json.field(doc.root, "plugins")) |own_list| {
        kit.plugins = try json.copy(a, own_list);
    } else if (kit.plugins == null) kit.plugins = json.array(a);
    const list = &kit.plugins.?;
    for (json.items(json.field(doc.root, "enable"))) |entry| {
        if (findEntry(list.*, entry) == null) try list.array.append(try json.copy(a, entry));
    }
    for (json.items(json.field(doc.root, "disable"))) |entry| {
        if (entry != .string) continue;
        if (findEntry(list.*, entry)) |at| _ = list.array.orderedRemove(at);
    }
    if (json.field(doc.root, "model_settings")) |settings| {
        if (kit.model_settings == null) kit.model_settings = json.object();
        try spec_mod.mergeOver(a, &kit.model_settings.?, settings);
    }
    if (json.str(doc.root, "prompt")) |prompt| kit.prompt = try util.pathJoin(a, dir, prompt);
    kit.pinned = pinned(list.*);
    kit.dir = dir;
    return true;
}

/// Appends "key=" and the entries of a list, space-separated, as written.
fn appendList(gpa: Allocator, out: *std.ArrayList(u8), key: []const u8, list: ?json.Value) Allocator.Error!void {
    try out.print(gpa, "{s}=", .{key});
    for (json.items(list), 0..) |entry, i| {
        const ref = if (entry == .string) entry.string else if (entry == .object and entry.object.count() > 0) entry.object.keys()[0] else "";
        try out.print(gpa, "{s}{s}", .{ if (i > 0) " " else "", ref });
    }
    try out.append(gpa, '\n');
}

/// Checks the kit in `dir` without using it, for `arx check --kit-dir`,
/// and appends key=value lines to `out` (name, version, description,
/// extends, plugins, enable, disable). Returns false, with the problems in
/// `err`, when it is not usable.
pub fn describe(ctx: *const Context, dir: []const u8, out: *std.ArrayList(u8), err: *std.ArrayList(u8)) Allocator.Error!bool {
    const gpa = ctx.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const doc = (try read(ctx, arena.allocator(), dir, err)) orelse return false;
    for ([_][]const u8{ "name", "version", "description", "extends" }) |key| {
        try out.print(gpa, "{s}=", .{key});
        for (json.strOr(doc.root, key, "")) |ch| try out.append(gpa, if (ch == '\n') ' ' else ch);
        try out.append(gpa, '\n');
    }
    for ([_][]const u8{ "plugins", "enable", "disable" }) |key| try appendList(gpa, out, key, json.field(doc.root, key));
    return true;
}

/// Appends one kit.lock line for the part in `dir`, from its .arx-source.
fn lockLine(ctx: *const Context, a: Allocator, out: *std.ArrayList(u8), lead: []const u8, name: []const u8, dir: []const u8) Allocator.Error!void {
    var part = json.object();
    try json.putString(a, &part, "name", name);
    const link = std.Io.Dir.cwd().statFile(ctx.io, dir, .{ .follow_symlinks = false }) catch null;
    if (link != null and link.?.kind == .sym_link) {
        const real = (try util.realPath(ctx.io, a, dir)) orelse dir;
        try json.putString(a, &part, "source", try a.print("link to {s}", .{real}));
    }
    const text = (try util.readFile(ctx.io, a, try std.mem.concat(a, u8, &.{ dir, "/.arx-source" }))) orelse "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        if ((std.mem.eql(u8, key, "source") or std.mem.eql(u8, key, "commit")) and json.field(part, key) == null) {
            try json.putString(a, &part, key, line[eq + 1 ..]);
        }
    }
    if (json.field(part, "source") == null) try json.putString(a, &part, "source", "(copied by hand)");
    try out.print(a, "{s}{f}\n", .{ lead, json.fmt(part) }); // JSON is valid YAML
}

/// Writes kit.lock next to the spec when the kit pins versions (@ref): the
/// source and commit of the kit and each plugin, from their .arx-source.
pub fn lockWrite(ctx: *const Context, spec: *const Spec) Allocator.Error!void {
    const kit = spec.kit orelse return;
    if (!spec.kit_pinned) return;
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "# kit.lock: the exact parts of kit {s}, written by arx because the kit\n# pins versions. Keep it with the project to repeat a run.\nkit: ", .{kit});
    try lockLine(ctx, a, &out, "", kit, spec.kit_dir);
    try out.appendSlice(a, "plugins:\n");
    for (spec.layers) |layer| if (layer.plugin) |plugin| try lockLine(ctx, a, &out, "  - ", plugin, layer.dir);
    const path = try util.pathJoin(a, spec.dir, "kit.lock");
    const old = try util.readFile(ctx.io, a, path);
    if (old == null or !std.mem.eql(u8, old.?, out.items)) util.writeFileAtomic(ctx.io, a, path, out.items) catch {};
}
