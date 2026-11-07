//! yaml.zig: reads YAML with libyaml (vendored C) into JSON values, and
//! remembers the line of every key so problems can name it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("yaml");

const json = @import("../base/json.zig");

/// Deeper YAML than this is rejected.
const max_depth = 64;

/// The most nodes one document may expand to. An alias repeats its node, so
/// without a limit a few lines could expand to billions of values.
const max_nodes = 200_000;

/// A parsed YAML document.
pub const Document = struct {
    /// The document as JSON (null for an empty document).
    root: json.Value,
    /// "dotted.path" -> line number of each key, for error messages.
    lines: json.Value,
};

/// Where libyaml gave up, when the text is not YAML.
pub const SyntaxError = struct {
    line: usize,
    column: usize,
    problem: []const u8,
};

/// A document, or where the text stopped being YAML.
pub const Result = union(enum) {
    ok: Document,
    syntax: SyntaxError,
};

/// Parses `text` into values in `arena`. Problems that still leave a usable
/// document (a duplicate key, a non-scalar key, too much nesting) are
/// appended to `problems` as "line N: path: message" lines.
pub fn parse(arena: Allocator, text: []const u8, problems: *std.ArrayList(u8), gpa: Allocator) Allocator.Error!Result {
    var parser: c.yaml_parser_t = undefined;
    if (c.yaml_parser_initialize(&parser) == 0) return error.OutOfMemory;
    defer c.yaml_parser_delete(&parser);
    c.yaml_parser_set_input_string(&parser, text.ptr, text.len);
    var doc: c.yaml_document_t = undefined;
    if (c.yaml_parser_load(&parser, &doc) == 0) {
        const problem: []const u8 = if (parser.problem) |p| std.mem.span(p) else "YAML error";
        return .{ .syntax = .{
            .line = parser.problem_mark.line + 1,
            .column = parser.problem_mark.column + 1,
            .problem = try arena.dupe(u8, problem),
        } };
    }
    defer c.yaml_document_delete(&doc);
    var converter: Converter = .{ .arena = arena, .gpa = gpa, .doc = &doc, .problems = problems };
    defer converter.path.deinit(gpa);
    const root_node = c.yaml_document_get_root_node(&doc);
    const root: json.Value = if (root_node == null) json.object() else try converter.node(root_node, 0);
    return .{ .ok = .{ .root = root, .lines = converter.lines } };
}

const Converter = struct {
    arena: Allocator,
    gpa: Allocator,
    doc: *c.yaml_document_t,
    problems: *std.ArrayList(u8),
    lines: json.Value = json.object(),
    /// The dotted path of the node being converted.
    path: std.ArrayList(u8) = .empty,
    nodes: usize = 0,

    /// Appends one problem line.
    fn problem(conv: *Converter, comptime format: []const u8, args: anytype) Allocator.Error!void {
        try conv.problems.print(conv.gpa, format, args);
    }

    /// Converts any node, recording "path.key" -> line in `lines`.
    fn node(conv: *Converter, n: [*c]c.yaml_node_t, depth: usize) Allocator.Error!json.Value {
        conv.nodes += 1;
        if (n == null or depth > max_depth or conv.nodes > max_nodes) {
            if (n != null and conv.nodes == max_nodes + 1) {
                try conv.problem("line {d}: too many values (aliases expand to more than {d})\n", .{ n.*.start_mark.line + 1, max_nodes });
            }
            return .null;
        }
        return switch (n.*.type) {
            c.YAML_SCALAR_NODE => blk: {
                const s = n.*.data.scalar;
                const value: []const u8 = if (s.value == null) "" else s.value[0..s.length];
                break :blk json.scalar(conv.arena, value, s.style == c.YAML_PLAIN_SCALAR_STYLE);
            },
            c.YAML_SEQUENCE_NODE => conv.sequence(n, depth),
            c.YAML_MAPPING_NODE => conv.mapping(n, depth),
            else => .null,
        };
    }

    /// Converts a sequence node into an array.
    fn sequence(conv: *Converter, n: [*c]c.yaml_node_t, depth: usize) Allocator.Error!json.Value {
        var out = json.array(conv.arena);
        const base = conv.path.items.len;
        const seq = n.*.data.sequence.items;
        var it = seq.start;
        var i: usize = 0;
        while (it != seq.top) : ({
            it += 1;
            i += 1;
        }) {
            try conv.path.print(conv.gpa, "[{d}]", .{i});
            const child = c.yaml_document_get_node(conv.doc, it.*);
            try out.array.append(try conv.node(child, depth + 1));
            conv.path.shrinkRetainingCapacity(base);
        }
        return out;
    }

    /// Converts a mapping node into an object; keys must be scalars.
    fn mapping(conv: *Converter, n: [*c]c.yaml_node_t, depth: usize) Allocator.Error!json.Value {
        var out = json.object();
        const base = conv.path.items.len;
        const pairs = n.*.data.mapping.pairs;
        var it = pairs.start;
        while (it != pairs.top) : (it += 1) {
            const key_node = c.yaml_document_get_node(conv.doc, it.*.key);
            if (key_node == null or key_node.*.type != c.YAML_SCALAR_NODE) {
                try conv.problem("line {d}: mapping keys must be plain strings\n", .{n.*.start_mark.line + 1});
                continue;
            }
            const s = key_node.*.data.scalar;
            const key: []const u8 = if (s.value == null) "" else s.value[0..s.length];
            const line = key_node.*.start_mark.line + 1;
            if (base > 0) try conv.path.append(conv.gpa, '.');
            try conv.path.appendSlice(conv.gpa, key);
            defer conv.path.shrinkRetainingCapacity(base);
            if (out.object.contains(key)) {
                try conv.problem("line {d}: {s}: duplicate key\n", .{ line, conv.path.items });
                continue;
            }
            try json.put(conv.arena, &conv.lines, conv.path.items, .{ .integer = @intCast(line) });
            const value = c.yaml_document_get_node(conv.doc, it.*.value);
            try json.put(conv.arena, &out, key, try conv.node(value, depth + 1));
        }
        return out;
    }
};

test "yaml to json with lines" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var problems: std.ArrayList(u8) = .empty;
    defer problems.deinit(gpa);
    const text =
        \\name: test
        \\endpoint: {base_url: "http://x", retry_base: 0.01}
        \\tools:
        \\  bash: {timeout: 5m}
        \\list: [a, 1, true]
        \\name: again
        \\
    ;
    const r = try parse(arena.allocator(), text, &problems, gpa);
    const doc = r.ok;
    try std.testing.expectEqualStrings("http://x", json.str(doc.root, "endpoint.base_url").?);
    try std.testing.expectEqual(@as(f64, 0.01), json.num(doc.root, "endpoint.retry_base", 0));
    try std.testing.expectEqual(@as(i64, 4), json.field(doc.lines, "tools.bash.timeout").?.integer);
    try std.testing.expectEqual(@as(usize, 3), json.items(json.field(doc.root, "list")).len);
    try std.testing.expect(std.mem.find(u8, problems.items, "line 6: name: duplicate key") != null);
}

test "yaml syntax errors carry a position" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var problems: std.ArrayList(u8) = .empty;
    defer problems.deinit(gpa);
    const r = try parse(arena.allocator(), "a: [1, 2\nb: c\n", &problems, gpa);
    try std.testing.expect(r == .syntax);
    try std.testing.expect(r.syntax.line >= 1);
}
