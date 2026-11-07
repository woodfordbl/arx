//! spec.zig: loads agent.yaml into JSON (remembering the line of every
//! key), merges the user's defaults under it, and applies --set overrides.
//! Validation lives in validate.zig; plugins in plugins.zig; the
//! fingerprint for hot reload in signature.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const Context = @import("../base/context.zig").Context;
const yaml = @import("yaml.zig");
const plugins = @import("plugins.zig");
const validate = @import("validate.zig");
const signature = @import("signature.zig");

/// One folder that adds tools/, hooks/ and skills to the harness: the spec
/// folder, a plugin, or the user's config folder.
pub const Layer = struct {
    dir: []const u8,
    /// The plugin name, or null for the spec and config folders.
    plugin: ?[]const u8 = null,
    /// Its skills folder, or null.
    skills: ?[]const u8 = null,
    /// A plugin's hook options (from plugin.yaml), or null.
    hooks: ?json.Value = null,
};

/// A parsed YAML file: its values, the lines of its keys, and where it is.
pub const Doc = struct {
    root: json.Value = .null,
    /// "dotted.path" -> line number, or "file:line" for keys that came from
    /// the user's defaults.
    lines: json.Value = .null,
    path: []const u8 = "",
    /// Its folder; tools/, hooks/ and prompt files are relative to it.
    dir: []const u8 = ".",
};

/// A loaded, validated spec. Everything in it lives in its arena.
pub const Spec = struct {
    arena: ?*std.heap.ArenaAllocator = null,
    root: json.Value = .null,
    lines: json.Value = .null,
    /// The spec file.
    path: []const u8 = "",
    dir: []const u8 = ".",
    /// The defaults file merged in (config.yaml), or null.
    config: ?[]const u8 = null,
    /// signature.compute() when it was loaded.
    sig: u64 = 0,
    /// Where tools, hooks and skills come from; the first wins.
    layers: []Layer = &.{},
    /// Plugins that were skipped, and why.
    problems: []const u8 = "",

    /// The spec as a document, for validation and text lookups.
    pub fn doc(s: *const Spec) Doc {
        return .{ .root = s.root, .lines = s.lines, .path = s.path, .dir = s.dir };
    }

    /// Frees everything the spec holds.
    pub fn deinit(s: *Spec, gpa: Allocator) void {
        if (s.arena) |arena| {
            arena.deinit();
            gpa.destroy(arena);
        }
        s.* = .{};
    }
};

/// Parses the YAML file at `path` into `arena`, without validating it.
/// Returns null, with the problem in `err`, when it cannot be read or is
/// not YAML. Problems that leave a usable document are also added to `err`.
pub fn parseFile(ctx: *const Context, arena: Allocator, path: []const u8, err: *std.ArrayList(u8)) Allocator.Error!?Doc {
    const gpa = ctx.gpa;
    const source = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, gpa, .unlimited) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try err.print(gpa, "{s}: {s}\n", .{ path, describeFileError(e) });
            return null;
        },
    };
    defer gpa.free(source);
    switch (try yaml.parse(arena, source, err, gpa)) {
        .syntax => |s| {
            try err.print(gpa, "{s}:{d}:{d}: {s}\n", .{ path, s.line, s.column, s.problem });
            return null;
        },
        .ok => |d| return .{ .root = d.root, .lines = d.lines, .path = try arena.dupe(u8, path), .dir = util.dirName(try arena.dupe(u8, path)) },
    }
}

/// The message for a file error, like strerror() would say.
pub fn describeFileError(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        else => @errorName(e),
    };
}

/// Copies the line numbers of `prefix` and everything under it from `from`
/// into `lines`, as "file:line" strings.
fn copyLines(arena: Allocator, lines: *json.Value, from: Doc, prefix: []const u8) Allocator.Error!void {
    if (lines.* != .object) lines.* = json.object();
    for (json.keys(from.lines), json.values(from.lines)) |key, line| {
        if (!std.mem.startsWith(u8, key, prefix)) continue;
        if (key.len > prefix.len and key[prefix.len] != '.' and key[prefix.len] != '[') continue;
        const where = try arena.print("{s}:{d}", .{ from.path, json.asNumber(line) orelse 0 });
        try json.put(arena, lines, key, .{ .string = where });
    }
}

/// Moves every key of `defaults` that `target` lacks into `target`,
/// recursing into mappings that both have, so `target` wins.
fn mergeDefaults(arena: Allocator, target: *json.Value, defaults: json.Value, prefix: []const u8, lines: *json.Value, from: Doc) Allocator.Error!void {
    for (json.keys(defaults), json.values(defaults)) |key, value| {
        const path = if (prefix.len > 0) try arena.print("{s}.{s}", .{ prefix, key }) else key;
        if (target.object.getPtr(key)) |existing| {
            if (existing.* == .object and value == .object) try mergeDefaults(arena, existing, value, path, lines, from);
        } else {
            try json.put(arena, target, key, value);
            try copyLines(arena, lines, from, path);
        }
    }
}

/// Merges `from` under `spec` key by key, so the spec wins. Both must live
/// in the spec's arena. Keeps line numbers for errors.
pub fn mergeUnder(spec: *Spec, from: Doc) Allocator.Error!void {
    if (spec.root != .object or from.root != .object) return;
    try mergeDefaults(spec.arena.?.allocator(), &spec.root, from.root, "", &spec.lines, from);
}

/// The user's defaults: config.yaml in the config folder.
const Defaults = union(enum) {
    missing,
    invalid,
    found: Doc,
};

/// Reads the user's defaults into `arena`.
fn loadDefaults(ctx: *const Context, arena: Allocator, err: *std.ArrayList(u8)) Allocator.Error!Defaults {
    const dir = try util.configDir(ctx, arena);
    const path = try std.mem.concat(arena, u8, &.{ dir, "/config.yaml" });
    if (!util.isReadable(ctx.io, path)) return .missing;
    var d = (try parseFile(ctx, arena, path, err)) orelse return .invalid;
    d.dir = dir;
    return .{ .found = d };
}

/// Loads and validates the spec at `path`, merged over the user's defaults
/// in config.yaml (the spec wins key by key), then applies `sets` (from
/// --set), then adds the plugins. With `path` null the defaults are the
/// whole spec, and tools/ and hooks/ come from the config folder. Returns
/// null, with one line per problem in `err` ("file:line: path: message"),
/// when the spec cannot be used.
pub fn load(ctx: *const Context, path: ?[]const u8, sets: json.Value, err: *std.ArrayList(u8)) Allocator.Error!?Spec {
    const gpa = ctx.gpa;
    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    arena_ptr.* = .init(gpa);
    var spec: Spec = .{ .arena = arena_ptr };
    errdefer spec.deinit(gpa);
    const arena = arena_ptr.allocator();
    const errors_before = err.items.len;

    const defaults = try loadDefaults(ctx, arena, err);
    if (defaults == .invalid) {
        spec.deinit(gpa);
        return null;
    }
    if (path) |p| {
        const d = (try parseFile(ctx, arena, p, err)) orelse {
            spec.deinit(gpa);
            return null;
        };
        spec.root = d.root;
        spec.lines = d.lines;
        spec.path = d.path;
        spec.dir = d.dir;
        if (defaults == .found) {
            if (spec.root == .object and defaults.found.root == .object) {
                try mergeDefaults(arena, &spec.root, defaults.found.root, "", &spec.lines, defaults.found);
                spec.config = defaults.found.path;
            }
        }
    } else if (defaults == .found) {
        const d = defaults.found; // the defaults are the whole spec
        spec.root = d.root;
        spec.lines = d.lines;
        spec.path = d.path;
        spec.dir = d.dir;
        spec.config = d.path;
    } else {
        try err.appendSlice(gpa, "no agent.yaml here and no saved defaults: run `arx setup`, or `arx init` to start a harness in this folder\n");
        spec.deinit(gpa);
        return null;
    }
    if (spec.lines != .object) spec.lines = json.object();
    if (spec.root == .object) {
        for (json.keys(sets), json.values(sets)) |key, value| {
            try json.set(arena, &spec.root, key, try json.copy(arena, value));
        }
        try plugins.load(ctx, &spec);
    }
    try validate.spec(ctx, &spec, err);
    spec.sig = try signature.compute(ctx, &spec);
    if (err.items.len > errors_before) {
        spec.deinit(gpa);
        return null;
    }
    return spec;
}

/// Parses one --set argument ("limits.max_turns=10") into `sets`. A value
/// that starts with [ or { is read as JSON ("plugins=[]"); others like a
/// YAML scalar. Returns false when it has no "=".
pub fn addSet(arena: Allocator, sets: *json.Value, key_value: []const u8) Allocator.Error!bool {
    const eq = std.mem.findScalar(u8, key_value, '=') orelse return false;
    if (eq == 0) return false;
    const key = key_value[0..eq];
    const value = key_value[eq + 1 ..];
    const parsed: ?json.Value = if (value.len > 0 and (value[0] == '[' or value[0] == '{'))
        json.parse(arena, value) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        }
    else
        null;
    try json.put(arena, sets, key, parsed orelse try json.scalar(arena, value, true));
    return true;
}

/// The text of a text node: a string, {file: path} (relative to the spec's
/// folder) or a list of them joined by blank lines. Null when `node` is
/// missing. A file that cannot be read is reported in `err` when given.
/// The result is allocated in `gpa` (caller owns it).
pub fn text(ctx: *const Context, gpa: Allocator, d: Doc, node: ?json.Value, err: ?*std.ArrayList(u8)) Allocator.Error!?[]u8 {
    const value = node orelse return null;
    switch (value) {
        .null => return null,
        .string => |s| return try gpa.dupe(u8, s),
        .array => |a| {
            var joined: std.ArrayList(u8) = .empty;
            errdefer joined.deinit(gpa);
            for (a.items) |item| {
                const part = (try text(ctx, gpa, d, item, err)) orelse continue;
                defer gpa.free(part);
                if (joined.items.len > 0) try joined.appendSlice(gpa, "\n\n");
                try joined.appendSlice(gpa, part);
            }
            return try joined.toOwnedSlice(gpa);
        },
        else => {},
    }
    const file = json.str(value, "file") orelse return null;
    const path = try util.pathJoin(gpa, d.dir, file);
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, gpa, .unlimited) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (err) |list| try list.print(ctx.gpa, "{s}: cannot read {s}: {s}\n", .{ d.path, path, describeFileError(e) });
            return null;
        },
    };
}

test "addSet parses scalars and JSON" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sets = json.object();
    try std.testing.expect(try addSet(a, &sets, "limits.max_turns=10"));
    try std.testing.expect(try addSet(a, &sets, "plugins=[]"));
    try std.testing.expect(!try addSet(a, &sets, "novalue"));
    try std.testing.expectEqual(@as(i64, 10), json.field(sets, "limits.max_turns").?.integer);
    try std.testing.expect(json.field(sets, "plugins").? == .array);
}
