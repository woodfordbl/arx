//! validate.zig: validation against the field tables in fields.zig, with
//! line numbers and "did you mean" hints, so an agent editing its own spec
//! can fix it from the message alone. agent.yaml, plugin.yaml and kit.yaml
//! all go through the same checks.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const Context = @import("../base/context.zig").Context;
const spec_mod = @import("spec.zig");
const Spec = spec_mod.Spec;
const Doc = spec_mod.Doc;
const fields_mod = @import("fields.zig");
const Field = fields_mod.Field;
const FieldType = fields_mod.FieldType;
const hook_points = fields_mod.hook_points;

const strategies = [_][]const u8{ "mask", "summarize", "hybrid", "restart" };
const template_vars = [_][]const u8{ "prompt", "harness", "skills", "date", "cwd", "session", "turn" };
const bands = [_][]const u8{ "policy", "normal", "final" };

/// True when `name` is in `list`.
pub fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

/// True for a non-empty name of at most `max` letters, digits, _ and -.
pub fn validName(name: []const u8, max: usize) bool {
    return name.len > 0 and name.len <= max and std.mem.findNone(u8, name, fields_mod.name_chars) == null;
}

/// Edit distance between two short strings, for "did you mean" hints.
fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 32 or b.len > 32) return 99;
    var d: [33][33]usize = undefined;
    for (0..a.len + 1) |i| d[i][0] = i;
    for (0..b.len + 1) |j| d[0][j] = j;
    for (1..a.len + 1) |i| {
        for (1..b.len + 1) |j| {
            const substitute = d[i - 1][j - 1] + @intFromBool(a[i - 1] != b[j - 1]);
            d[i][j] = @min(substitute, d[i - 1][j] + 1, d[i][j - 1] + 1);
        }
    }
    return d[a.len][b.len];
}

/// Collects problems as "file:line: path: message" lines.
const Checker = struct {
    ctx: *const Context,
    doc: Doc,
    err: *std.ArrayList(u8),
    /// For paths and other short-lived strings.
    t: Allocator,

    /// Appends "file:line: path: message" for the key at `path`.
    fn problem(c: Checker, path: []const u8, comptime format: []const u8, args: anytype) Allocator.Error!void {
        const gpa = c.ctx.gpa;
        if (json.field(c.doc.lines, path)) |line| switch (line) {
            .integer => |n| try c.err.print(gpa, "{s}:{d}: {s}: ", .{ c.doc.path, n, path }),
            .string => |where| try c.err.print(gpa, "{s}: {s}: ", .{ where, path }), // from the user's defaults
            else => try c.err.print(gpa, "{s}: {s}: ", .{ c.doc.path, path }),
        } else try c.err.print(gpa, "{s}: {s}: ", .{ c.doc.path, path });
        try c.err.print(gpa, format ++ "\n", args);
    }

    /// Reports an unknown key, suggesting the closest known one.
    fn unknownKey(c: Checker, path: []const u8, key: []const u8, fields: []const Field) Allocator.Error!void {
        var best: ?[]const u8 = null;
        var best_distance: usize = 3;
        for (fields) |f| {
            const d = editDistance(key, f.key);
            if (d < best_distance) {
                best_distance = d;
                best = f.key;
            }
        }
        if (best) |b| return c.problem(path, "unknown key (did you mean \"{s}\"?)", .{b});
        var known: std.ArrayList(u8) = .empty;
        for (fields, 0..) |f, i| try known.print(c.t, "{s}{s}", .{ if (i > 0) ", " else "", f.key });
        try c.problem(path, "unknown key (known: {s})", .{known.items});
    }

    /// Checks every key of `node` against `fields`, recursing into mappings.
    fn node(c: Checker, value: json.Value, fields: []const Field, path: []const u8) Allocator.Error!void {
        for (json.keys(value), json.values(value)) |key, child| {
            const child_path = if (path.len > 0) try c.t.print("{s}.{s}", .{ path, key }) else key;
            const f = for (fields) |f| {
                if (std.mem.eql(u8, f.key, key)) break f;
            } else {
                try c.unknownKey(child_path, key, fields);
                continue;
            };
            if (!typeOk(f.type, child)) {
                try c.problem(child_path, "must be {s}", .{typeName(f.type)});
            } else if (f.type == .map) {
                try c.node(child, f.sub, child_path);
            } else if (f.type == .dict) {
                try c.dict(child, f.sub, child_path);
            }
        }
    }

    /// Checks the entries of a dict: each value is a mapping of `fields`.
    fn dict(c: Checker, value: json.Value, fields: []const Field, path: []const u8) Allocator.Error!void {
        for (json.keys(value), json.values(value)) |key, entry| {
            const entry_path = try c.t.print("{s}.{s}", .{ path, key });
            switch (entry) {
                .object => try c.node(entry, fields, entry_path),
                .null => {},
                else => try c.problem(entry_path, "must be a mapping of options (or empty)", .{}),
            }
        }
    }

    /// Reports {{names}} in `text` that are not template variables.
    fn template(c: Checker, where: []const u8, text: []const u8) Allocator.Error!void {
        var pos: usize = 0;
        while (std.mem.findPos(u8, text, pos, "{{")) |open| {
            const close = std.mem.findPos(u8, text, open + 2, "}}") orelse break;
            const name = std.mem.trim(u8, text[open + 2 .. close], " ");
            if (!inList(&template_vars, name) and !std.mem.startsWith(u8, name, "file:")) {
                try c.problem(where, "unknown template variable {{{{{s}}}}} (known: prompt, harness, skills, date, cwd, session, turn, file:PATH)", .{name});
            }
            pos = close + 2;
        }
    }

    /// Checks the names of hook points and tools.
    fn names(c: Checker) Allocator.Error!void {
        const hooks = json.field(c.doc.root, "hooks");
        for (json.keys(hooks), json.values(hooks)) |point, options| {
            if (!inList(&bands, json.strOr(options, "band", "normal"))) try c.problem(try c.t.print("hooks.{s}.band", .{point}), "must be policy, normal or final", .{});
            if (!inList(&hook_points, point)) try c.problem(try c.t.print("hooks.{s}", .{point}), "unknown hook point (known: session_start, before_model, after_model, before_tool, after_tool, stop)", .{});
        }
        for (json.keys(json.field(c.doc.root, "tools"))) |tool| {
            if (!validName(tool, 64)) try c.problem(try c.t.print("tools.{s}", .{tool}), "tool names use letters, digits, _ and - (64 max)", .{});
        }
    }

    /// A plugin or kit names itself with letters, digits, _ and -.
    fn ownName(c: Checker) Allocator.Error!void {
        if (!validName(json.strOr(c.doc.root, "name", "x"), std.math.maxInt(usize))) try c.problem("name", "use letters, digits, _ and -", .{});
    }

    /// Each compactors entry names an executable, relative to the file.
    fn compactors(c: Checker) Allocator.Error!void {
        const entries = json.field(c.doc.root, "compactors");
        for (json.keys(entries), json.values(entries)) |name, value| {
            const where = try c.t.print("compactors.{s}", .{name});
            if (value != .string) {
                try c.problem(where, "must be the path of an executable", .{});
                continue;
            }
            const path = try util.pathJoin(c.t, c.doc.dir, value.string);
            if (!util.isExecutable(c.ctx.io, path)) try c.problem(where, "{s} is not executable", .{path});
        }
    }

    /// Rules the table cannot express: required keys, ranges and templates.
    fn rules(c: Checker) Allocator.Error!void {
        const root = c.doc.root;
        if (json.str(root, "model") == null) try c.problem("model", "required", .{});
        if (json.str(root, "endpoint.base_url") == null) try c.problem("endpoint.base_url", "required", .{});
        try c.compactors();
        if (json.str(root, "compaction.strategy")) |strategy| {
            const named = json.field(json.field(root, "compactors"), strategy) != null;
            const path = try util.pathJoin(c.t, c.doc.dir, strategy);
            if (!named and !inList(&strategies, strategy) and !util.isExecutable(c.ctx.io, path)) {
                try c.problem("compaction.strategy", "not a built-in strategy, and {s} is not executable", .{path});
            }
        }
        const trigger = json.num(root, "compaction.trigger", 0.7);
        if (!(trigger > 0 and trigger <= 1)) try c.problem("compaction.trigger", "must be between 0 and 1", .{});
        for ([_][]const u8{ "instructions", "first_message", "compaction.prompt" }) |key| {
            if (try spec_mod.text(c.ctx, c.t, c.doc, json.get(root, key), c.err)) |text| try c.template(key, text);
        }
    }
};

/// True for a string or {file: path}.
fn isText(v: json.Value) bool {
    return switch (v) {
        .string => true,
        .object => |o| o.count() == 1 and json.str(v, "file") != null,
        else => false,
    };
}

/// True for one entry of a plugin list: a name, or {name: {settings}}.
fn isPluginEntry(v: json.Value) bool {
    return switch (v) {
        .string => |name| name.len > 0,
        .object => |o| o.count() == 1 and (o.values()[0] == .object or o.values()[0] == .null),
        else => false,
    };
}

/// True when `v` is a list whose items all pass `f`.
fn allItems(v: json.Value, comptime f: fn (json.Value) bool) bool {
    if (v != .array) return false;
    for (v.array.items) |item| if (!f(item)) return false;
    return true;
}

/// True for a string.
fn isString(v: json.Value) bool {
    return v == .string;
}

/// True when `v` has the shape that `t` needs.
fn typeOk(t: FieldType, v: json.Value) bool {
    return switch (t) {
        .string => v == .string,
        .number => json.asNumber(v) != null,
        .integer => if (json.asNumber(v)) |n| n == @trunc(n) else false,
        .boolean => v == .bool,
        .duration => json.asNumber(v) != null or (v == .string and util.parseDuration(v.string) != null),
        .size => json.asNumber(v) != null or (v == .string and util.parseSize(v.string) != null),
        .text => isText(v),
        .text_list => isText(v) or allItems(v, isText),
        .string_list => allItems(v, isString),
        .plugin_list => allItems(v, isPluginEntry),
        .any_map, .map, .dict => v == .object,
    };
}

/// Describes a type for error messages.
fn typeName(t: FieldType) []const u8 {
    return switch (t) {
        .string => "a string",
        .number => "a number",
        .integer => "a whole number",
        .boolean => "true or false",
        .duration => "a duration (30, 10s, 5m, 1h)",
        .size => "a size (2048, 2kb, 1mb)",
        .text => "text or {file: path}",
        .text_list => "text, {file: path} or a list of them",
        .string_list => "a list of strings",
        .plugin_list => "a list of plugin names or {name: {settings}}",
        .any_map, .map, .dict => "a mapping",
    };
}

/// Validates a whole spec, appending problems to `err`.
pub fn spec(ctx: *const Context, s: *const Spec, err: *std.ArrayList(u8)) Allocator.Error!void {
    if (s.root != .object) return err.print(ctx.gpa, "{s}: the spec must be a YAML mapping\n", .{s.path});
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    const c: Checker = .{ .ctx = ctx, .doc = s.doc(), .err = err, .t = arena.allocator() };
    try c.node(s.root, &fields_mod.top_fields, "");
    try c.names();
    try c.rules();
}

/// Validates a parsed plugin.yaml, appending problems to `err`.
pub fn plugin(ctx: *const Context, d: Doc, err: *std.ArrayList(u8)) Allocator.Error!void {
    if (d.root != .object) return err.print(ctx.gpa, "{s}: plugin.yaml must be a YAML mapping\n", .{d.path});
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    const c: Checker = .{ .ctx = ctx, .doc = d, .err = err, .t = arena.allocator() };
    try c.node(d.root, &fields_mod.plugin_fields, "");
    try c.names();
    try c.compactors();
    try c.ownName();
}

/// Validates a parsed kit.yaml, appending problems to `err`.
pub fn kit(ctx: *const Context, d: Doc, err: *std.ArrayList(u8)) Allocator.Error!void {
    if (d.root != .object) return err.print(ctx.gpa, "{s}: kit.yaml must be a YAML mapping\n", .{d.path});
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    const c: Checker = .{ .ctx = ctx, .doc = d, .err = err, .t = arena.allocator() };
    try c.node(d.root, &fields_mod.kit_fields, "");
    try c.ownName();
    if (json.str(d.root, "extends") == null and json.field(d.root, "plugins") == null) try c.problem("plugins", "required (or extends)", .{});
}
