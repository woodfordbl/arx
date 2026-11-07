//! validate.zig: the agent.yaml field table, and validation against it. One
//! table drives validation (with line numbers and "did you mean" hints, so
//! an agent editing its own spec can fix it from the message alone) and the
//! JSON Schema in schema.zig. Adding a key to the table adds it to both.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const Context = @import("../base/context.zig").Context;
const spec_mod = @import("spec.zig");
const Spec = spec_mod.Spec;
const Doc = spec_mod.Doc;

/// The type of one spec key.
pub const FieldType = enum {
    string,
    number,
    integer,
    boolean,
    /// Seconds, or "10s", "5m", "1h".
    duration,
    /// Bytes, or "2kb", "1mb".
    size,
    /// A string or {file: path}.
    text,
    /// Text or a list of them.
    text_list,
    string_list,
    /// A mapping with any keys.
    any_map,
    /// A mapping with the keys in `sub`.
    map,
    /// A mapping whose values each have the keys in `sub`.
    dict,
};

/// One key of the spec: its name, type, sub-fields (for map and dict) and
/// a short description for the JSON Schema.
pub const Field = struct {
    key: []const u8,
    type: FieldType,
    sub: []const Field = &.{},
    doc: []const u8,
};

/// The hook points.
pub const hook_points = [_][]const u8{ "session_start", "before_tool", "after_tool", "stop" };

/// The characters allowed in tool names (OpenAI function names).
pub const name_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-";

const strategies = [_][]const u8{ "mask", "summarize", "hybrid", "restart" };
const template_vars = [_][]const u8{ "prompt", "harness", "skills", "date", "cwd", "session", "turn" };

const endpoint_fields = [_]Field{
    .{ .key = "base_url", .type = .string, .doc = "OpenAI-compatible base URL" },
    .{ .key = "api_key_env", .type = .string, .doc = "Env var with the API key (OPENAI_API_KEY)" },
    .{ .key = "headers", .type = .any_map, .doc = "Extra HTTP headers" },
    .{ .key = "curl", .type = .string, .doc = "curl executable (default: $ARX_CURL or curl)" },
    .{ .key = "retry_base", .type = .duration, .doc = "First retry delay (default 2s)" },
    .{ .key = "retry_max", .type = .duration, .doc = "Longest retry delay (default 5m)" },
    .{ .key = "retry_attempts", .type = .integer, .doc = "Give up after this many (0 = never)" },
};

const tool_fields = [_]Field{
    .{ .key = "timeout", .type = .duration, .doc = "Seconds or 10s/5m/1h" },
    .{ .key = "agent", .type = .string, .doc = "Spec path: makes this tool a subagent" },
    .{ .key = "description", .type = .string, .doc = "Description shown to the model" },
    .{ .key = "enabled", .type = .boolean, .doc = "false hides the tool" },
};

const tool_output_fields = [_]Field{
    .{ .key = "head", .type = .size, .doc = "Bytes kept from the start of output (2kb)" },
    .{ .key = "tail", .type = .size, .doc = "Bytes kept from the end of output (6kb)" },
};

const hook_fields = [_]Field{
    .{ .key = "timeout", .type = .duration, .doc = "Default 10s" },
    .{ .key = "fail", .type = .string, .doc = "open (ignore failures) or closed" },
};

const compaction_fields = [_]Field{
    .{ .key = "strategy", .type = .string, .doc = "mask, summarize, hybrid, restart, a compactors name or a path" },
    .{ .key = "trigger", .type = .number, .doc = "Fraction of context_window (default 0.7)" },
    .{ .key = "keep", .type = .integer, .doc = "Recent outputs or turns kept intact (5)" },
    .{ .key = "exclude_tools", .type = .string_list, .doc = "Tools whose outputs stay" },
    .{ .key = "clear_inputs", .type = .boolean, .doc = "Also clear old tool-call arguments" },
    .{ .key = "prompt", .type = .text, .doc = "Instructions for summarize" },
};

const limits_fields = [_]Field{
    .{ .key = "max_turns", .type = .integer, .doc = "Model calls per session (200)" },
    .{ .key = "turn_timeout", .type = .duration, .doc = "Longest single model call (10m)" },
};

const prices_fields = [_]Field{
    .{ .key = "input", .type = .number, .doc = "USD per 1M input tokens" },
    .{ .key = "output", .type = .number, .doc = "USD per 1M output tokens" },
};

/// The top-level keys of agent.yaml.
pub const top_fields = [_]Field{
    .{ .key = "name", .type = .string, .doc = "Agent name" },
    .{ .key = "model", .type = .string, .doc = "Model id your endpoint accepts" },
    .{ .key = "endpoint", .type = .map, .sub = &endpoint_fields, .doc = "Where requests go" },
    .{ .key = "model_settings", .type = .any_map, .doc = "Extra request fields; null removes" },
    .{ .key = "context_window", .type = .integer, .doc = "Context size in tokens (128000)" },
    .{ .key = "instructions", .type = .text_list, .doc = "System prompt; {{vars}} allowed" },
    .{ .key = "first_message", .type = .text, .doc = "First user message; {{prompt}} is the task" },
    .{ .key = "tools", .type = .dict, .sub = &tool_fields, .doc = "Options per tool, or subagent tools" },
    .{ .key = "tool_output", .type = .map, .sub = &tool_output_fields, .doc = "How much tool output the model sees" },
    .{ .key = "hooks", .type = .dict, .sub = &hook_fields, .doc = "Options per hook point (hooks/<point>)" },
    .{ .key = "compaction", .type = .map, .sub = &compaction_fields, .doc = "How the context stays in the window" },
    .{ .key = "skills", .type = .string, .doc = "Directory of <name>/SKILL.md files" },
    .{ .key = "limits", .type = .map, .sub = &limits_fields, .doc = "Per-session limits" },
    .{ .key = "observers", .type = .string_list, .doc = "Commands fed the event stream on stdin" },
    .{ .key = "prices", .type = .map, .sub = &prices_fields, .doc = "Token prices for cost tracking" },
    .{ .key = "plugins", .type = .string_list, .doc = "The only plugins to use (default: all installed); [] for none" },
    .{ .key = "compactors", .type = .any_map, .doc = "Named compaction programs: name -> path" },
};

/// The keys of plugin.yaml.
const plugin_fields = [_]Field{
    .{ .key = "name", .type = .string, .doc = "Must match the plugin's folder name" },
    .{ .key = "version", .type = .string, .doc = "The plugin's version" },
    .{ .key = "description", .type = .string, .doc = "One line about what it adds" },
    .{ .key = "arx", .type = .string, .doc = "The arx versions it works with, e.g. \">=0.2\"" },
    .{ .key = "requires", .type = .string_list, .doc = "Programs that must be on PATH" },
    .{ .key = "tools", .type = .dict, .sub = &tool_fields, .doc = "Options for its tools, or subagent tools" },
    .{ .key = "hooks", .type = .dict, .sub = &hook_fields, .doc = "Options for its hooks" },
    .{ .key = "observers", .type = .string_list, .doc = "Commands fed the event stream" },
    .{ .key = "compactors", .type = .any_map, .doc = "Named compaction programs: name -> path" },
};

/// True when `name` is in `list`.
pub fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

/// True for a non-empty name of at most `max` letters, digits, _ and -.
pub fn validName(name: []const u8, max: usize) bool {
    return name.len > 0 and name.len <= max and std.mem.findNone(u8, name, name_chars) == null;
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
        defer known.deinit(c.ctx.gpa);
        for (fields, 0..) |f, i| {
            if (i > 0) try known.appendSlice(c.ctx.gpa, ", ");
            try known.appendSlice(c.ctx.gpa, f.key);
        }
        try c.problem(path, "unknown key (known: {s})", .{known.items});
    }

    /// Checks every key of `node` against `fields`, recursing into mappings.
    fn node(c: Checker, value: json.Value, fields: []const Field, path: []const u8) Allocator.Error!void {
        const gpa = c.ctx.gpa;
        for (json.keys(value), json.values(value)) |key, child| {
            const child_path = if (path.len > 0) try gpa.print("{s}.{s}", .{ path, key }) else try gpa.dupe(u8, key);
            defer gpa.free(child_path);
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
        const gpa = c.ctx.gpa;
        for (json.keys(value), json.values(value)) |key, entry| {
            const entry_path = try gpa.print("{s}.{s}", .{ path, key });
            defer gpa.free(entry_path);
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
        const gpa = c.ctx.gpa;
        for (json.keys(json.field(c.doc.root, "hooks"))) |point| {
            if (inList(&hook_points, point)) continue;
            const path = try gpa.print("hooks.{s}", .{point});
            defer gpa.free(path);
            try c.problem(path, "unknown hook point (known: session_start, before_tool, after_tool, stop)", .{});
        }
        for (json.keys(json.field(c.doc.root, "tools"))) |tool| {
            if (validName(tool, 64)) continue;
            const path = try gpa.print("tools.{s}", .{tool});
            defer gpa.free(path);
            try c.problem(path, "tool names use letters, digits, _ and - (64 max)", .{});
        }
    }

    /// Each compactors entry names an executable, relative to the file.
    fn compactors(c: Checker) Allocator.Error!void {
        const gpa = c.ctx.gpa;
        const entries = json.field(c.doc.root, "compactors");
        for (json.keys(entries), json.values(entries)) |name, value| {
            const where = try gpa.print("compactors.{s}", .{name});
            defer gpa.free(where);
            if (value != .string) {
                try c.problem(where, "must be the path of an executable", .{});
                continue;
            }
            const path = try util.pathJoin(gpa, c.doc.dir, value.string);
            defer gpa.free(path);
            if (!util.isExecutable(c.ctx.io, path)) try c.problem(where, "{s} is not executable", .{path});
        }
    }

    /// Rules the table cannot express: required keys, ranges and templates.
    fn rules(c: Checker) Allocator.Error!void {
        const gpa = c.ctx.gpa;
        const root = c.doc.root;
        if (json.str(root, "model") == null) try c.problem("model", "required", .{});
        if (json.str(root, "endpoint.base_url") == null) try c.problem("endpoint.base_url", "required", .{});
        try c.compactors();
        if (json.str(root, "compaction.strategy")) |strategy| {
            const named = json.field(json.field(root, "compactors"), strategy) != null;
            if (!named and !inList(&strategies, strategy)) {
                const path = try util.pathJoin(gpa, c.doc.dir, strategy);
                defer gpa.free(path);
                if (!util.isExecutable(c.ctx.io, path)) {
                    try c.problem("compaction.strategy", "not a built-in strategy, and {s} is not executable", .{path});
                }
            }
        }
        const trigger = json.num(root, "compaction.trigger", 0.7);
        if (!(trigger > 0 and trigger <= 1)) try c.problem("compaction.trigger", "must be between 0 and 1", .{});
        for ([_][]const u8{ "instructions", "first_message", "compaction.prompt" }) |key| {
            const text = (try spec_mod.text(c.ctx, gpa, c.doc, json.get(root, key), c.err)) orelse continue;
            defer gpa.free(text);
            try c.template(key, text);
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
        .text_list => isText(v) or (v == .array and for (v.array.items) |item| {
            if (!isText(item)) break false;
        } else true),
        .string_list => v == .array and for (v.array.items) |item| {
            if (item != .string) break false;
        } else true,
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
        .any_map, .map, .dict => "a mapping",
    };
}

/// Validates a whole spec, appending problems to `err`.
pub fn spec(ctx: *const Context, s: *const Spec, err: *std.ArrayList(u8)) Allocator.Error!void {
    const c: Checker = .{ .ctx = ctx, .doc = s.doc(), .err = err };
    if (s.root != .object) {
        try err.print(ctx.gpa, "{s}: the spec must be a YAML mapping\n", .{s.path});
        return;
    }
    try c.node(s.root, &top_fields, "");
    try c.names();
    try c.rules();
}

/// Validates a parsed plugin.yaml, appending problems to `err`.
pub fn plugin(ctx: *const Context, d: Doc, err: *std.ArrayList(u8)) Allocator.Error!void {
    const c: Checker = .{ .ctx = ctx, .doc = d, .err = err };
    if (d.root != .object) {
        try err.print(ctx.gpa, "{s}: plugin.yaml must be a YAML mapping\n", .{d.path});
        return;
    }
    try c.node(d.root, &plugin_fields, "");
    try c.names();
    try c.compactors();
    const name = json.strOr(d.root, "name", "x");
    if (name.len == 0 or std.mem.findNone(u8, name, name_chars) != null) {
        try c.problem("name", "use letters, digits, _ and -", .{});
    }
}

test "edit distance" {
    try std.testing.expectEqual(@as(usize, 2), editDistance("modle", "model"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("tols", "tools"));
}
