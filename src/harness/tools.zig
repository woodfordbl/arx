//! tools.zig: builds the tool set: every executable in a layer's tools/
//! folder, and subagent tools from the spec. An executable is described by
//! a <name>.json file next to it, or else by `--schema` (description,
//! parameters and keys); the answers are cached by modification time and
//! size, so a reload only reads tools that changed.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const proc = @import("../base/proc.zig");
const Context = @import("../base/context.zig").Context;
const Layer = @import("spec.zig").Layer;
const fields = @import("fields.zig");
const keys_mod = @import("keys.zig");
const Agent = @import("../agent/agent.zig").Agent;

const agent_params =
    \\{"type":"object","properties":{"task":{"type":"string","description":"The complete task. The subagent starts with no other context."}},"required":["task"]}
;
const empty_params =
    \\{"type":"object","properties":{}}
;

/// How long `<tool> --schema` may take.
const schema_timeout = 2.0;

/// The most executable tools whose schemas are cached.
const max_schemas = 128;

/// How a tool runs.
pub const Kind = enum {
    /// tools/<name>, arguments as JSON on stdin.
    exec,
    /// A subagent: arx -p - --spec <path>.
    agent,
};

/// One tool as the model sees it, plus how to run it.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// The executable (exec) or spec (agent).
    path: ?[]const u8 = null,
    /// JSON Schema of the arguments.
    params: json.Value,
    kind: Kind,
    timeout: f64,
    /// The plugin folder it came from, or null.
    plugin_dir: ?[]const u8 = null,
    /// NAME when the file only runs `arx tool NAME`, or null.
    core: ?[]const u8 = null,
    /// Key templates from the schema; null means ["*"].
    keys: ?json.Value = null,
};

/// The tools of the current harness version. Everything lives in its arena.
pub const ToolSet = struct {
    arena: ?*std.heap.ArenaAllocator = null,
    items: []Tool = &.{},

    /// Frees every tool.
    pub fn deinit(t: *ToolSet, gpa: Allocator) void {
        if (t.arena) |arena| {
            arena.deinit();
            gpa.destroy(arena);
        }
        t.* = .{};
    }

    /// The tool called `name`, or null.
    pub fn find(t: *const ToolSet, name: []const u8) ?*const Tool {
        for (t.items) |*tool| if (std.mem.eql(u8, tool.name, name)) return tool;
        return null;
    }

    /// The tools in OpenAI "tools" format, as compact JSON. Caller owns the
    /// result.
    pub fn toJson(t: *const ToolSet, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.append(gpa, '[');
        for (t.items, 0..) |tool, i| try out.print(gpa, "{s}{{\"type\":\"function\",\"function\":{{\"name\":{f},\"description\":{f},\"parameters\":{f}}}}}", .{
            if (i > 0) "," else "", json.fmt(.{ .string = tool.name }), json.fmt(.{ .string = tool.description }), json.fmt(tool.params),
        });
        try out.append(gpa, ']');
        return out.toOwnedSlice(gpa);
    }
};

/// One cached schema, from <path>.json or `--schema`.
const SchemaEntry = struct {
    path: []u8,
    /// stat() of the tool and of its .json file, to see changes.
    stamp: [4]i64,
    arena: std.heap.ArenaAllocator,
    description: []const u8 = "",
    /// Why the tool is skipped, or null.
    problem: ?[]const u8 = null,
    params: json.Value = .null,
    /// The `arx tool NAME` the file hands over to, or null.
    core: ?[]const u8 = null,
    /// The declared keys, or null.
    keys: ?json.Value = null,
};

/// The modification time and size of `path`; -1s when it is missing.
fn stamp(ctx: *const Context, path: []const u8) [2]i64 {
    const info = util.stat(ctx.io, path) orelse return .{ -1, -1 };
    return .{ info.mtime, info.size };
}

/// `--schema` answers, by path. Entries are heap-allocated so their arenas
/// stay put.
pub const SchemaCache = struct {
    entries: std.ArrayList(*SchemaEntry) = .empty,

    /// Frees every cached answer.
    pub fn deinit(c: *SchemaCache, gpa: Allocator) void {
        for (c.entries.items) |e| {
            e.arena.deinit();
            gpa.free(e.path);
            gpa.destroy(e);
        }
        c.entries.deinit(gpa);
    }

    /// The schema for `path`, refreshed when the file changed, or null when
    /// the cache is full.
    fn get(c: *SchemaCache, ctx: *const Context, path: []const u8) Allocator.Error!?*SchemaEntry {
        const gpa = ctx.gpa;
        var json_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const json_path = std.fmt.bufPrint(&json_path_buf, "{s}.json", .{path}) catch return null;
        const now = stamp(ctx, path) ++ stamp(ctx, json_path);
        const entry = for (c.entries.items) |e| {
            if (std.mem.eql(u8, e.path, path)) break e;
        } else blk: {
            if (c.entries.items.len >= max_schemas) return null;
            const e = try gpa.create(SchemaEntry);
            errdefer gpa.destroy(e);
            e.* = .{ .path = try gpa.dupe(u8, path), .stamp = @splat(-2), .arena = .init(gpa) };
            c.entries.append(gpa, e) catch |err| {
                gpa.free(e.path);
                return err;
            };
            break :blk e;
        };
        if (std.mem.eql(i64, &entry.stamp, &now)) return entry;
        _ = entry.arena.reset(.free_all);
        entry.* = .{ .path = entry.path, .stamp = now, .arena = entry.arena };
        try load(ctx, entry, json_path, now[1], now[3] >= 0);
        return entry;
    }
};

/// The NAME when the file at `path` only runs `exec "$ARX_BIN" tool NAME`
/// (with an optional "$@", a #! line and comments), else null. arx then
/// starts `arx tool NAME` itself: the result is the same, without a shell,
/// which takes about 3 ms on macOS.
fn coreTool(ctx: *const Context, a: Allocator, path: []const u8, size: i64) Allocator.Error!?[]const u8 {
    const prefix = "exec \"$ARX_BIN\" tool ";
    if (size <= 0 or size > 512) return null;
    const text = (try util.readFile(ctx.io, a, path)) orelse return null;
    var found: ?[]const u8 = null;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        if (found != null or !std.mem.startsWith(u8, line, prefix)) return null; // anything else: run the file as it is
        const name = line[prefix.len..];
        const n = std.mem.findNone(u8, name, fields.name_chars) orelse name.len;
        var rest = std.mem.trimStart(u8, name[n..], " \t");
        if (std.mem.startsWith(u8, rest, "\"$@\"")) rest = std.mem.trimStart(u8, rest[4..], " \t");
        if (n == 0 or rest.len > 0) return null;
        found = name[0..n];
    }
    return found;
}

/// Fills in the entry from a parsed schema; `what` names its source in the
/// error.
fn readSchema(e: *SchemaEntry, schema: ?json.Value, what: []const u8) Allocator.Error!void {
    const a = e.arena.allocator();
    const j = schema orelse {
        e.problem = try a.print("{s} must be a JSON object {{\"description\": ..., \"parameters\": {{...}}}}", .{what});
        return;
    };
    if (json.field(j, "keys")) |keys| {
        if (!keys_mod.valid(keys)) {
            e.problem = try a.print("{s}: \"keys\" must be a list of strings", .{what});
            return;
        }
        e.keys = keys;
    }
    e.description = json.strOr(j, "description", "");
    const params = json.field(j, "parameters");
    e.params = if (params != null and params.? == .object) params.? else try json.parseTrusted(a, empty_params);
}

/// Reads <path>.json when there is one, else runs `--schema`, and fills in
/// the entry.
fn load(ctx: *const Context, e: *SchemaEntry, json_path: []const u8, size: i64, has_json: bool) Allocator.Error!void {
    const a = e.arena.allocator();
    e.core = try coreTool(ctx, a, e.path, size);
    if (has_json) {
        const text = (try util.readFile(ctx.io, a, json_path)) orelse "";
        return readSchema(e, try json.parseObject(a, text), util.baseName(json_path));
    }
    var out: proc.Collector = .init(a);
    const argv: []const []const u8 = if (e.core) |core| &.{ ctx.self_path, "tool", core, "--schema" } else &.{ e.path, "--schema" };
    const r = try proc.run(ctx, .{ .argv = argv, .timeout = schema_timeout, .stdout = out.sink() });
    if (r.spawn_error) |err| {
        e.problem = try a.print("cannot run it ({s})", .{util.describeError(err)});
    } else if (r.timed_out) {
        e.problem = "--schema took longer than 2s";
    } else if (r.code != 0) {
        e.problem = try a.print("--schema exited with {d}", .{r.code});
    } else {
        try readSchema(e, try json.parseObject(a, out.output()), "--schema output");
    }
}

/// Fills in {{timeout}}, {{tool_output.head}} and {{tool_output.tail}}, so a
/// description can give the limits that the spec sets for the tool.
fn describe(a: Allocator, text: []const u8, timeout: f64, root: json.Value) Allocator.Error![]const u8 {
    if (std.mem.find(u8, text, "{{") == null) return a.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    var rest = text;
    while (std.mem.find(u8, rest, "{{")) |open| {
        try out.appendSlice(a, rest[0..open]);
        rest = rest[open..];
        if (std.mem.startsWith(u8, rest, "{{timeout}}")) {
            try out.print(a, "{d:.0}", .{timeout});
            rest = rest["{{timeout}}".len..];
        } else if (std.mem.startsWith(u8, rest, "{{tool_output.head}}")) {
            try out.print(a, "{d}", .{json.size(root, "tool_output.head", 2048)});
            rest = rest["{{tool_output.head}}".len..];
        } else if (std.mem.startsWith(u8, rest, "{{tool_output.tail}}")) {
            try out.print(a, "{d}", .{json.size(root, "tool_output.tail", 6144)});
            rest = rest["{{tool_output.tail}}".len..];
        } else {
            try out.appendSlice(a, "{{");
            rest = rest[2..];
        }
    }
    try out.appendSlice(a, rest);
    return out.items;
}

/// Builds a tool set for `a`, collecting problems in `notes`.
const Builder = struct {
    a: *Agent,
    arena: Allocator,
    tools: std.ArrayList(Tool) = .empty,
    notes: std.ArrayList(u8) = .empty,

    /// Adds a line to the tool problems.
    fn note(b: *Builder, comptime format: []const u8, args: anytype) Allocator.Error!void {
        try b.notes.print(b.arena, format, args);
    }

    /// True when a tool called `name` is already in the set.
    fn has(b: *const Builder, name: []const u8) bool {
        for (b.tools.items) |t| if (std.mem.eql(u8, t.name, name)) return true;
        return false;
    }

    /// Appends a tool.
    fn add(b: *Builder, tool: Tool) Allocator.Error!void {
        try b.tools.append(b.arena, tool);
    }

    /// Adds one executable from a layer's tools/, or explains in the notes
    /// why it is skipped. `where` names the layer ("" for the spec folder).
    fn executable(b: *Builder, layer: Layer, where: []const u8, name: []const u8) Allocator.Error!void {
        const ctx = b.a.ctx;
        const path = try std.mem.concat(b.arena, u8, &.{ layer.dir, "/tools/", name });
        const info = util.stat(ctx.io, path) orelse return; // a broken link is not a tool
        if (info.kind != .file) return; // nor is a folder
        if (!util.isExecutable(ctx.io, path)) {
            return b.note("- {s}tools/{s} is not executable (chmod +x it)\n", .{ where, name });
        }
        if (std.mem.findNone(u8, name, fields.name_chars) != null) {
            return b.note("- {s}tools/{s} skipped: use letters, digits, _ and -\n", .{ where, name });
        }
        const options = json.field(json.field(b.a.spec.root, "tools"), name);
        if (!json.boolean(options, "enabled", true)) return;
        const entry = (try b.a.schemas.get(ctx, path)) orelse {
            return b.note("- {s}tools/{s} skipped: too many tools\n", .{ where, name });
        };
        if (entry.problem) |problem| return b.note("- {s}tools/{s} skipped: {s}\n", .{ where, name, problem });
        const timeout = json.duration(options, "timeout", 120);
        try b.add(.{
            .name = try b.arena.dupe(u8, name),
            .description = try describe(b.arena, entry.description, timeout, b.a.spec.root),
            .path = path,
            .params = try json.copy(b.arena, entry.params),
            .kind = .exec,
            .timeout = timeout,
            .plugin_dir = if (layer.plugin != null) layer.dir else null,
            .core = if (entry.core) |core| try b.arena.dupe(u8, core) else null,
            .keys = if (entry.keys) |keys| try json.copy(b.arena, keys) else null,
        });
    }

    /// Adds the executables of every layer; the first working tool with a
    /// name wins. Returns every file name found, for `configured`.
    fn layers(b: *Builder) Allocator.Error![]const []const u8 {
        const ctx = b.a.ctx;
        var found: std.ArrayList([]const u8) = .empty;
        for (b.a.spec.layers, 0..) |layer, i| {
            const where = if (i == 0)
                ""
            else if (layer.plugin) |p|
                try b.arena.print("plugin {s}: ", .{p})
            else
                try b.arena.print("{s}/", .{layer.dir});
            const dir = try util.pathJoin(b.arena, layer.dir, "tools");
            const names = try util.listNames(ctx.io, b.arena, dir);
            for (names) |name| {
                if (name.len > 5 and std.mem.endsWith(u8, name, ".json")) continue; // a schema, which sits next to its tool
                if (!b.has(name)) {
                    try b.executable(layer, where, name);
                } else {
                    try b.note("- {s}tools/{s} is hidden by a tool above it\n", .{ where, name });
                }
                try found.append(b.arena, name);
            }
        }
        return found.items;
    }

    /// Adds subagent tools and flags spec entries that match nothing.
    fn configured(b: *Builder, names: []const []const u8) Allocator.Error!void {
        const ctx = b.a.ctx;
        const entries = json.field(b.a.spec.root, "tools");
        for (json.keys(entries), json.values(entries)) |name, entry| {
            const found = for (names) |n| {
                if (std.mem.eql(u8, n, name)) break true;
            } else false;
            if (json.str(entry, "agent")) |spec_file| {
                const path = try util.pathJoin(b.arena, b.a.spec.dir, spec_file);
                if (!util.isReadable(ctx.io, path)) {
                    try b.note("- tools.{s}: subagent spec {s} not found\n", .{ name, path });
                    continue;
                }
                const default_description = try b.arena.print("Delegate a task to the {s} subagent (spec {s}). It starts with no context, so give it the complete task. Returns its final answer.", .{ name, spec_file });
                try b.add(.{
                    .name = name,
                    .description = json.strOr(entry, "description", default_description),
                    .path = path,
                    .params = try json.parseTrusted(b.arena, agent_params),
                    .kind = .agent,
                    .timeout = json.duration(entry, "timeout", 1800),
                    .keys = json.array(b.arena),
                });
            } else if (!found and json.boolean(entry, "enabled", true)) {
                try b.note("- tools.{s} is configured but tools/{s} is missing\n", .{ name, name });
            }
        }
    }
};

/// Rebuilds a.tools from the spec and the tools/ folder of every layer. An
/// executable in tools/ is a tool named after its file; {{timeout}} and
/// {{tool_output.*}} in its description become the spec's values. The first
/// layer with a working tool of a name wins. A file that only runs `exec
/// "$ARX_BIN" tool NAME "$@"` starts as `arx tool NAME` with no shell. A
/// spec entry with `agent: path` is a subagent. Problems, and skipped
/// plugins, become harness notes, once per change.
pub fn build(a: *Agent) Allocator.Error!void {
    const gpa = a.ctx.gpa;
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    var set: ToolSet = .{ .arena = arena };
    errdefer set.deinit(gpa);
    var b: Builder = .{ .a = a, .arena = arena.allocator() };
    try b.notes.appendSlice(b.arena, a.spec.problems);
    const names = try b.layers();
    try b.configured(names);
    set.items = b.tools.items;
    a.tools.deinit(gpa);
    a.tools = set;
    // Tell the agent about problems once, not again on every reload.
    const sig = std.hash.Fnv1a_64.hash(b.notes.items);
    if (b.notes.items.len > 0 and sig != a.notes_sig) try a.note("Tool problems:\n{s}", .{b.notes.items});
    a.notes_sig = if (b.notes.items.len > 0) sig else 0;
}
