//! active.zig: the active list, the ordered list of plugins that one run
//! uses. Three sources build it, each changing the list from the one
//! before: config.yaml (a default kit or list), agent.yaml, and the
//! launcher (--kit and --set). The position in the list is the priority.
//! In each source, `kit:` replaces the list with the kit's, `plugins:`
//! replaces it with its own, `enable:` adds to it and `disable:` takes out.
//! Plugin settings merge in the order config.yaml, kit, agent.yaml, --set.
//! When no source sets a kit or a list, every installed plugin is on.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../base/json.zig");
const Context = @import("../base/context.zig").Context;
const spec_mod = @import("spec.zig");
const Spec = spec_mod.Spec;
const kits = @import("kits.zig");

/// The plugin name an entry refers to: "acme/tools/lint@v1" -> "lint", and
/// {guard: {...}} -> "guard".
pub fn entryName(entry: json.Value) []const u8 {
    var ref: []const u8 = switch (entry) {
        .string => |s| s,
        .object => |o| if (o.count() > 0) o.keys()[0] else "",
        else => "",
    };
    if (std.mem.findScalarLast(u8, ref, '/')) |slash| ref = ref[slash + 1 ..];
    return ref[0 .. std.mem.findScalar(u8, ref, '@') orelse ref.len];
}

/// The settings of an entry ({name: {settings}}), or null.
fn entrySettings(entry: json.Value) ?json.Value {
    if (entry != .object or entry.object.count() == 0) return null;
    const v = entry.object.values()[0];
    return if (v == .object) v else null;
}

/// The keys that build the active list, as one source gave them.
const Source = struct {
    label: []const u8,
    kit: ?[]const u8 = null,
    plugins: ?json.Value = null,
    enable: ?json.Value = null,
    disable: ?json.Value = null,

    /// The list keys of `root` (may be null).
    fn read(label: []const u8, root: json.Value) Source {
        const list = struct {
            /// `root.key` when it is a list.
            fn get(r: json.Value, key: []const u8) ?json.Value {
                const v = json.field(r, key) orelse return null;
                return if (v == .array) v else null;
            }
        }.get;
        return .{ .label = label, .kit = json.str(root, "kit"), .plugins = list(root, "plugins"), .enable = list(root, "enable"), .disable = list(root, "disable") };
    }
};

/// Builds the active list as it changes, in the spec's arena.
const Builder = struct {
    a: Allocator,
    /// null: every installed plugin.
    list: ?json.Value = null,
    off: json.Value,

    /// The index of `name` in the list, or null.
    fn indexOf(b: *const Builder, name: []const u8) ?usize {
        for (json.items(b.list), 0..) |row, i| if (std.mem.eql(u8, json.strOr(row, "name", ""), name)) return i;
        return null;
    }

    /// Appends the entries the list lacks, with `why`.
    fn append(b: *Builder, entries: ?json.Value, why: []const u8) Allocator.Error!void {
        if (b.list == null) return;
        for (json.items(entries)) |entry| {
            const name = entryName(entry);
            if (name.len == 0 or b.indexOf(name) != null) continue;
            var row = json.object();
            try json.putString(b.a, &row, "name", name);
            try json.putString(b.a, &row, "why", why);
            try b.list.?.array.append(row);
        }
    }

    /// Applies one source's enable: and disable:.
    fn enableDisable(b: *Builder, s: Source) Allocator.Error!void {
        try b.append(s.enable, try b.a.print("enable in {s}", .{s.label}));
        for (json.items(s.enable)) |entry| _ = b.off.object.orderedRemove(entryName(entry));
        const why = try b.a.print("disable in {s}", .{s.label});
        for (json.items(s.disable)) |entry| {
            const name = entryName(entry);
            if (b.indexOf(name)) |at| _ = b.list.?.array.orderedRemove(at);
            _ = b.off.object.orderedRemove(name);
            try json.putString(b.a, &b.off, name, why);
        }
    }
};

/// Merges the settings of each entry of `list` into `settings`.
fn addSettings(a: Allocator, settings: *json.Value, list: ?json.Value) Allocator.Error!void {
    for (json.items(list)) |entry| {
        const mine = entrySettings(entry) orelse continue;
        const name = entryName(entry);
        if (json.field(settings.*, name) == null) try json.put(a, settings, name, json.object());
        try spec_mod.mergeOver(a, settings.object.getPtr(name).?, mine);
    }
}

/// Builds spec.active, off, settings and kit* from the kit, plugins, enable
/// and disable keys of `config`, `agent` (.null when the defaults are the
/// spec) and `sets`, in that order. Returns the kit's model_settings and
/// instructions as a spec mapping to merge, or null. error.Invalid means
/// the kit is missing or broken, and `err` says why.
pub fn build(ctx: *const Context, spec: *Spec, config: json.Value, agent: json.Value, sets: json.Value, err: *std.ArrayList(u8)) (Allocator.Error || error{Invalid})!?json.Value {
    const a = spec.arena.?.allocator();
    var sources: [3]Source = undefined;
    var n: usize = 0;
    sources[n] = .read("config.yaml", config);
    n += 1;
    if (agent != .null) {
        sources[n] = .read("agent.yaml", agent);
        n += 1;
    }
    sources[n] = .read("--set", sets);
    n += 1;

    var kit_at: ?usize = null;
    for (sources[0..n], 0..) |s, i| if (s.kit != null) {
        kit_at = i;
    };
    var kit: kits.Kit = .{};
    var kit_name: []const u8 = "";
    var kit_root: ?json.Value = null;
    if (kit_at) |at| {
        const named = sources[at].kit.?;
        kit_name = named[0 .. std.mem.findScalar(u8, named, '@') orelse named.len]; // --kit coding@v1 uses kit coding
        kit = (try kits.load(ctx, a, spec.dir, kit_name, err)) orelse return error.Invalid;
        spec.kit = kit_name;
        spec.kit_dir = kit.dir;
        spec.kit_from = if (std.mem.eql(u8, sources[at].label, "--set")) "--kit" else sources[at].label;
        spec.kit_pinned = kit.pinned;
        var root = json.object();
        if (kit.model_settings) |settings| try json.put(a, &root, "model_settings", settings);
        if (kit.prompt) |prompt| {
            var file = json.object();
            try json.putString(a, &file, "file", prompt);
            var list = json.array(a);
            try list.array.append(file);
            try json.put(a, &root, "instructions", list);
        }
        kit_root = root;
    }

    var b: Builder = .{ .a = a, .off = json.object() };
    for (sources[0..n], 0..) |s, i| {
        if (s.kit != null or s.plugins != null) {
            // A kit or a list replaces what the sources before it built.
            b.list = json.array(a);
            b.off = json.object();
        }
        if (kit_at == i) try b.append(kit.plugins, try a.print("kit {s}", .{kit_name}));
        if (s.plugins != null) try b.append(s.plugins, try a.print("plugins in {s}", .{s.label}));
        try b.enableDisable(s);
    }
    // Settings: config.yaml, then the kit, then agent.yaml and --set.
    var settings = json.object();
    for (sources[0..n], 0..) |s, i| {
        try addSettings(a, &settings, s.plugins);
        try addSettings(a, &settings, s.enable);
        if (i == 0) try addSettings(a, &settings, kit.plugins);
    }
    spec.active = b.list;
    spec.off = b.off;
    spec.settings = settings;
    return kit_root;
}

test "entry names" {
    try std.testing.expectEqualStrings("lint", entryName(.{ .string = "acme/tools/lint@v1" }));
    try std.testing.expectEqualStrings("guard", entryName(.{ .string = "guard" }));
}
