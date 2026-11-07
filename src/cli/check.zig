//! check.zig: `arx check` and `arx tools`. They load the harness the way a
//! run does, without a session, and report it: the kit, tools, hooks and
//! plugins in order, the problems, and warnings about plugins that change
//! the same field or hide a tool without saying so.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const render = @import("../io/render.zig");
const spec_mod = @import("../harness/spec.zig");
const Spec = spec_mod.Spec;
const Layer = spec_mod.Layer;
const fields = @import("../harness/fields.zig");
const hooks = @import("../harness/hooks.zig");
const describe = @import("../harness/describe.zig");
const kits = @import("../harness/kits.zig");
const tools = @import("../harness/tools.zig");
const Agent = @import("../agent/agent.zig").Agent;
const options = @import("options.zig");
const Exit = util.Exit;

/// The output, built in an arena.
const Report = struct {
    a: *Agent,
    t: Allocator,
    out: std.ArrayList(u8) = .empty,

    /// Appends formatted text.
    fn print(r: *Report, comptime format: []const u8, args: anytype) Allocator.Error!void {
        try r.out.print(r.t, format, args);
    }

    /// True when `layer` has an executable <sub>/<name>.
    fn has(r: *Report, layer: Layer, sub: []const u8, name: []const u8) Allocator.Error!bool {
        return util.isExecutable(r.a.ctx.io, try std.mem.concat(r.t, u8, &.{ layer.dir, "/", sub, "/", name }));
    }

    /// How warnings name a layer.
    fn label(r: *Report, layer: *const Layer) Allocator.Error![]const u8 {
        if (layer.plugin) |plugin| return r.t.print("plugin {s}", .{plugin});
        return if (layer == &r.a.spec.layers[0]) "the spec folder" else "the config folder";
    }

    /// The hooks of every layer, with the plugins that add them.
    fn hookLine(r: *Report) Allocator.Error!void {
        try r.print("\nhooks:", .{});
        for (fields.hook_points) |point| {
            var from: std.ArrayList(u8) = .empty;
            var found = false;
            for (r.a.spec.layers) |layer| {
                if (!try r.has(layer, "hooks", point)) continue;
                found = true;
                if (layer.plugin) |plugin| try from.print(r.t, "{s}{s}", .{ if (from.items.len > 0) "," else "", plugin });
            }
            if (found) try r.print(" {s}", .{point});
            if (from.items.len > 0) try r.print("({s})", .{from.items});
        }
        try r.print("\n", .{});
    }

    /// Warns when two layers' hooks at one point change the same field,
    /// and shows the order they run in (band, then list order).
    fn overlaps(r: *Report, out: *std.ArrayList(u8)) Allocator.Error!void {
        const spec = &r.a.spec;
        const n = spec.layers.len;
        for (fields.hook_points) |point| {
            var who = json.object(); // field -> ["plugin a (band)", ...]
            for (0..3 * n) |k| {
                const layer = &spec.layers[k % n];
                const b = hooks.band(spec, layer.*, point);
                if (b != k / n or !try r.has(layer.*, "hooks", point)) continue;
                for (json.items(json.field(hooks.options(spec, layer.*, point), "changes"))) |field| {
                    if (field != .string) continue;
                    if (json.field(who, field.string) == null) try json.put(r.t, &who, field.string, json.array(r.t));
                    const entry: json.Value = .{ .string = try r.t.print("{s} ({s})", .{ try r.label(layer), hooks.band_names[b] }) };
                    try who.object.getPtr(field.string).?.array.append(entry);
                }
            }
            for (json.keys(who), json.values(who)) |field, names| {
                if (names.array.items.len < 2) continue;
                try out.print(r.t, "- {s}: {d} hooks change {s}; they run in this order:", .{ point, names.array.items.len, field });
                for (names.array.items, 0..) |name, i| try out.print(r.t, "{s} {s}", .{ if (i > 0) "," else "", name.string });
                try out.append(r.t, '\n');
            }
        }
    }

    /// Warns when a plugin's tool hides a tool of a layer below it, unless
    /// the plugin declares it in `replaces:`.
    fn hidden(r: *Report, out: *std.ArrayList(u8)) Allocator.Error!void {
        const layers = r.a.spec.layers;
        for (layers, 0..) |layer, i| {
            const plugin = layer.plugin orelse continue;
            for (try util.listNames(r.a.ctx.io, r.t, try util.pathJoin(r.t, layer.dir, "tools"))) |name| {
                if (!try r.has(layer, "tools", name)) continue;
                const replaced = for (json.items(layer.replaces)) |v| {
                    if (v == .string and std.mem.eql(u8, v.string, name)) break true;
                } else false;
                for (layers[i + 1 ..]) |*other| {
                    if (replaced or !try r.has(other.*, "tools", name)) continue;
                    try out.print(r.t, "- plugin {s} hides the tool {s} of {s}; if that is on purpose, add `replaces: [{s}]` to its plugin.yaml\n", .{ plugin, name, try r.label(other), name });
                }
            }
        }
    }

    /// The active list for `arx plugin list`: a "kit" line, then one
    /// tab-separated row per plugin: position (or -), name, state, why,
    /// folder.
    fn list(r: *Report) Allocator.Error!void {
        const spec = &r.a.spec;
        if (spec.kit) |kit| try r.print("kit\t{s}\t{s}\n", .{ kit, spec.kit_from });
        var position: usize = 0;
        for (json.items(spec.rows)) |row| {
            const state = json.strOr(row, "state", "");
            const on = std.mem.eql(u8, state, "on");
            if (on) position += 1;
            const at = if (on) try r.t.print("{d}", .{position}) else "-";
            try r.print("{s}\t{s}\t{s}\t{s}\t{s}\n", .{ at, json.strOr(row, "name", ""), state, json.strOr(row, "why", ""), json.strOr(row, "dir", "") });
        }
    }

    /// The whole check report.
    fn check(r: *Report) Allocator.Error!void {
        const spec = &r.a.spec;
        const config = spec.config orelse spec.path;
        const merged = !std.mem.eql(u8, config, spec.path);
        try r.print("ok: {s}{s}{s} (model {s} at {s})\n", .{ spec.path, if (merged) " + " else "", if (merged) config else "", json.strOr(spec.root, "model", ""), json.strOr(spec.root, "endpoint.base_url", "") });
        if (spec.kit) |kit| try r.print("kit: {s} (from {s})\n", .{ kit, spec.kit_from });
        try r.print("tools:", .{});
        for (r.a.tools.items) |tool| try r.print(" {s}", .{tool.name});
        try r.hookLine();
        var any = false;
        for (spec.layers) |layer| if (layer.plugin) |plugin| {
            try r.print("{s}{s}", .{ if (any) " " else "plugins: ", plugin });
            any = true;
        };
        if (any) try r.print("\n", .{});
        if (r.a.notes.items.len > 0) try r.print("problems:\n{s}", .{r.a.notes.items});
        var warnings: std.ArrayList(u8) = .empty;
        try r.overlaps(&warnings);
        try r.hidden(&warnings);
        if (warnings.items.len > 0) try r.print("warnings:\n{s}", .{warnings.items});
    }
};

/// Loads the spec for a command and prints its problems.
pub fn loadSpec(a: *Agent) Allocator.Error!?Exit {
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(a.ctx.gpa);
    options.resolveSpec(a);
    a.spec = (try spec_mod.load(a.ctx, a.spec_path, a.sets, &err)) orelse {
        render.printErr(a.ctx.io, "{s}", .{err.items});
        return .usage;
    };
    return null;
}

/// `arx check --plugin DIR` and `--kit-dir DIR`: checks one folder without
/// loading it, and prints key=value lines for scripts.
fn checkFolder(a: *Agent, flag: []const u8, dir: []const u8) !Exit {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a.ctx.gpa);
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(a.ctx.gpa);
    const ok = if (std.mem.eql(u8, flag, "--plugin")) try describe.describe(a.ctx, dir, &out, &err) else try kits.describe(a.ctx, dir, &out, &err);
    if (ok) render.printOut(a.ctx.io, "{s}", .{out.items}) else render.printErr(a.ctx.io, "{s}", .{err.items});
    return if (ok) .done else .usage;
}

/// `arx check` and `arx tools`: load the harness without starting a
/// session, and print it (check: the spec, kit, tools, hooks, plugins,
/// problems and warnings; --list: the active list; tools: the tools as the
/// model sees them).
pub fn checkOrTools(a: *Agent, all_args: []const []const u8) !Exit {
    var args = all_args;
    const is_check = std.mem.eql(u8, args[1], "check");
    if (is_check and args.len == 4 and (std.mem.eql(u8, args[2], "--plugin") or std.mem.eql(u8, args[2], "--kit-dir"))) return checkFolder(a, args[2], args[3]);
    const list = is_check and args.len > 2 and std.mem.eql(u8, args[args.len - 1], "--list");
    if (list) args = args[0 .. args.len - 1];
    if (try options.parse(a, args, 2)) |code| return code;
    if (try loadSpec(a)) |code| return code;
    try tools.build(a);
    var arena: std.heap.ArenaAllocator = .init(a.ctx.gpa);
    defer arena.deinit();
    const t = arena.allocator();
    if (!is_check) {
        render.printOut(a.ctx.io, "{s}\n", .{try json.stringifyPretty(t, try json.parseTrusted(t, try a.tools.toJson(t)))});
        return .done;
    }
    var r: Report = .{ .a = a, .t = t };
    if (list) try r.list() else try r.check();
    render.printOut(a.ctx.io, "{s}", .{r.out.items});
    return .done;
}
