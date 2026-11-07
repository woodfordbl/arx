//! tools.zig: builds the tool set: the built-ins (bash and edit), every
//! executable in a layer's tools/ folder, and subagent tools from the spec.
//! Executable tools describe themselves with `--schema`; the answers are
//! cached by modification time and size, so a reload only re-runs tools
//! that changed.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const proc = @import("../base/proc.zig");
const Context = @import("../base/context.zig").Context;
const Layer = @import("spec.zig").Layer;
const validate = @import("validate.zig");
const Agent = @import("../agent/agent.zig").Agent;

const bash_params =
    \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command, run with sh -c in the working directory"}},"required":["command"]}
;
const edit_params =
    \\{"type":"object","properties":{"path":{"type":"string"},"old":{"type":"string","description":"Exact text to replace; it must occur exactly once. Empty creates a new file."},"new":{"type":"string","description":"Replacement text"}},"required":["path","old","new"]}
;
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
    /// sh -c <command>
    bash,
    /// Exact string replacement, in process.
    edit,
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

/// One cached `--schema` answer.
const SchemaEntry = struct {
    path: []u8,
    mtime: i64,
    size: i64,
    arena: std.heap.ArenaAllocator,
    description: []const u8 = "",
    /// Why the tool is skipped, or null.
    problem: ?[]const u8 = null,
    params: json.Value = .null,
};

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
        const info = util.stat(ctx.io, path);
        const mtime: i64 = if (info) |i| i.mtime else -1;
        const size: i64 = if (info) |i| i.size else -1;
        const entry = for (c.entries.items) |e| {
            if (std.mem.eql(u8, e.path, path)) break e;
        } else blk: {
            if (c.entries.items.len >= max_schemas) return null;
            const e = try gpa.create(SchemaEntry);
            errdefer gpa.destroy(e);
            e.* = .{ .path = try gpa.dupe(u8, path), .mtime = 0, .size = -2, .arena = .init(gpa) };
            c.entries.append(gpa, e) catch |err| {
                gpa.free(e.path);
                return err;
            };
            break :blk e;
        };
        if (entry.mtime == mtime and entry.size == size) return entry;
        _ = entry.arena.reset(.free_all);
        entry.* = .{ .path = entry.path, .mtime = mtime, .size = size, .arena = entry.arena };
        try load(ctx, entry);
        return entry;
    }
};

/// Runs `<tool> --schema` and fills in the entry.
fn load(ctx: *const Context, e: *SchemaEntry) Allocator.Error!void {
    const a = e.arena.allocator();
    var out: proc.Collector = .init(a);
    const r = try proc.run(ctx, .{ .argv = &.{ e.path, "--schema" }, .timeout = schema_timeout, .stdout = out.sink() });
    if (r.spawn_error) |err| {
        e.problem = try a.print("cannot run it ({s})", .{util.describeError(err)});
    } else if (r.timed_out) {
        e.problem = "--schema took longer than 2s";
    } else if (r.code != 0) {
        e.problem = try a.print("--schema exited with {d}", .{r.code});
    } else if (try json.parseObject(a, out.output())) |schema| {
        e.description = json.strOr(schema, "description", "");
        const params = json.field(schema, "parameters");
        e.params = if ((params != null and params.? == .object)) params.? else try json.parseTrusted(a, empty_params);
    } else {
        e.problem = "--schema must print a JSON object {\"description\": ..., \"parameters\": {...}}";
    }
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

    /// Adds the built-in tools unless the spec disables them.
    fn builtins(b: *Builder) Allocator.Error!void {
        const root = b.a.spec.root;
        const head = json.size(root, "tool_output.head", 2048);
        const tail = json.size(root, "tool_output.tail", 6144);
        const timeout = json.duration(root, "tools.bash.timeout", 120);
        if (json.boolean(root, "tools.bash.enabled", true)) {
            try b.add(.{
                .name = "bash",
                .description = try b.arena.print("Run a shell command (sh -c) in the working directory. You see the first {d} and last {d} bytes of output; the full output is saved to a file whose path is shown. Timeout {d:.0}s.", .{ head, tail, timeout }),
                .params = try json.parseTrusted(b.arena, bash_params),
                .kind = .bash,
                .timeout = timeout,
            });
        }
        if (json.boolean(root, "tools.edit.enabled", true)) {
            try b.add(.{
                .name = "edit",
                .description = "Replace an exact, unique string in a file, or create a new file when `old` is empty.",
                .params = try json.parseTrusted(b.arena, edit_params),
                .kind = .edit,
                .timeout = 0,
            });
        }
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
        if (isBuiltin(name) or std.mem.findNone(u8, name, validate.name_chars) != null) {
            return b.note("- {s}tools/{s} skipped: use letters, digits, _ and -, and not bash or edit\n", .{ where, name });
        }
        const options = json.field(json.field(b.a.spec.root, "tools"), name);
        if (!json.boolean(options, "enabled", true)) return;
        const entry = (try b.a.schemas.get(ctx, path)) orelse {
            return b.note("- {s}tools/{s} skipped: too many tools\n", .{ where, name });
        };
        if (entry.problem) |problem| return b.note("- {s}tools/{s} skipped: {s}\n", .{ where, name, problem });
        try b.add(.{
            .name = try b.arena.dupe(u8, name),
            .description = try b.arena.dupe(u8, entry.description),
            .path = path,
            .params = try json.copy(b.arena, entry.params),
            .kind = .exec,
            .timeout = json.duration(options, "timeout", 120),
            .plugin_dir = if (layer.plugin != null) layer.dir else null,
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
                if (!b.has(name)) {
                    try b.executable(layer, where, name);
                } else if (!isBuiltin(name)) {
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
            const found = isBuiltin(name) or for (names) |n| {
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
                });
            } else if (!found and json.boolean(entry, "enabled", true)) {
                try b.note("- tools.{s} is configured but tools/{s} is missing\n", .{ name, name });
            }
        }
    }
};

/// True for the names of built-in tools.
fn isBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "edit");
}

/// Rebuilds a.tools from the spec and the tools/ folder of every layer.
/// Problems, and skipped plugins, become harness notes, once per change.
pub fn build(a: *Agent) Allocator.Error!void {
    const gpa = a.ctx.gpa;
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    var set: ToolSet = .{ .arena = arena };
    errdefer set.deinit(gpa);
    var b: Builder = .{ .a = a, .arena = arena.allocator() };
    try b.notes.appendSlice(b.arena, a.spec.problems);
    try b.builtins();
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
