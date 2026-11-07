//! json_write.zig: writes JSON values as text, compact or indented. Numbers
//! read naturally: integers without ".0", decimals without exponents, and
//! NaN or infinities as null.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Value = std.json.Value;

/// Writes `s` as a JSON string.
pub fn writeString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    var start: usize = 0;
    for (s, 0..) |ch, i| {
        const escape: ?[]const u8 = switch (ch) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0C => "\\f",
            else => null,
        };
        if (escape == null and ch >= 0x20) continue;
        try w.writeAll(s[start..i]);
        if (escape) |e| try w.writeAll(e) else try w.print("\\u{x:0>4}", .{ch});
        start = i + 1;
    }
    try w.writeAll(s[start..]);
    try w.writeByte('"');
}

/// Writes a float: whole numbers without a fraction, others in plain
/// decimal notation; NaN and infinities as null.
fn writeFloat(w: *Writer, f: f64) Writer.Error!void {
    if (!std.math.isFinite(f)) return w.writeAll("null");
    if (f == @trunc(f) and @abs(f) < 9e15) return w.print("{d}", .{@as(i64, @intFromFloat(f))});
    try w.print("{d}", .{f});
}

/// How `write` lays out its output.
pub const Style = enum { compact, pretty };

/// Writes `v` as JSON: on one line, or indented by two spaces per level.
pub fn write(w: *Writer, v: Value, style: Style) Writer.Error!void {
    try writeIndented(w, v, style, 0);
}

/// Starts a new line at `depth` when pretty-printing.
fn newline(w: *Writer, style: Style, depth: usize) Writer.Error!void {
    if (style == .compact) return;
    try w.writeByte('\n');
    try w.splatByteAll(' ', depth * 2);
}

/// Writes `v`, nested `depth` levels deep.
fn writeIndented(w: *Writer, v: Value, style: Style, depth: usize) Writer.Error!void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try writeFloat(w, f),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try writeString(w, s),
        .array => |a| {
            if (a.items.len == 0) return w.writeAll("[]");
            try w.writeByte('[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try newline(w, style, depth + 1);
                try writeIndented(w, item, style, depth + 1);
            }
            try newline(w, style, depth);
            try w.writeByte(']');
        },
        .object => |o| {
            if (o.count() == 0) return w.writeAll("{}");
            try w.writeByte('{');
            for (o.keys(), o.values(), 0..) |k, item, i| {
                if (i > 0) try w.writeByte(',');
                try newline(w, style, depth + 1);
                try writeString(w, k);
                try w.writeAll(if (style == .pretty) ": " else ":");
                try writeIndented(w, item, style, depth + 1);
            }
            try newline(w, style, depth);
            try w.writeByte('}');
        },
    }
}

/// `v` as compact JSON text. Caller owns the result.
pub fn stringify(gpa: Allocator, v: Value) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    write(&out.writer, v, .compact) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `v` as indented JSON text. Caller owns the result.
pub fn stringifyPretty(gpa: Allocator, v: Value) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    write(&out.writer, v, .pretty) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

test "compact and pretty output" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v: Value = .{ .object = .empty };
    try v.object.put(a, "n", .{ .float = 0.0123 });
    try v.object.put(a, "i", .{ .float = 3 });
    try v.object.put(a, "list", .{ .array = .init(a) });
    try std.testing.expectEqualStrings("{\"n\":0.0123,\"i\":3,\"list\":[]}", try stringify(a, v));
    try std.testing.expectEqualStrings("{\n  \"n\": 0.0123,\n  \"i\": 3,\n  \"list\": []\n}", try stringifyPretty(a, v));
}
