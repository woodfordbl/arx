//! schema.zig: generates the JSON Schema for agent.yaml (`arx schema`) from
//! the field table in validate.zig, for editor completion and validation.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../base/json.zig");
const validate = @import("validate.zig");
const Field = validate.Field;
const FieldType = validate.FieldType;

/// The schema of a text node: a string or {file: path}.
fn textSchema(a: Allocator) Allocator.Error!json.Value {
    var file = json.object();
    try json.putString(a, &file, "type", "string");
    var props = json.object();
    try json.put(a, &props, "file", file);
    var required = json.array(a);
    try required.array.append(json.string("file"));
    var object = json.object();
    try json.putString(a, &object, "type", "object");
    try json.put(a, &object, "properties", props);
    try json.put(a, &object, "required", required);
    try json.put(a, &object, "additionalProperties", .{ .bool = false });
    var string = json.object();
    try json.putString(a, &string, "type", "string");
    var any_of = json.array(a);
    try any_of.array.append(string);
    try any_of.array.append(object);
    var out = json.object();
    try json.put(a, &out, "anyOf", any_of);
    return out;
}

/// The schema for one field type.
fn typeSchema(a: Allocator, t: FieldType, sub: []const Field) Allocator.Error!json.Value {
    switch (t) {
        .map => return fieldsSchema(a, sub),
        .text => return textSchema(a),
        else => {},
    }
    var o = json.object();
    switch (t) {
        .string, .number, .integer, .boolean => try json.putString(a, &o, "type", @tagName(t)),
        .duration, .size => {
            var either = json.array(a);
            try either.array.append(json.string("string"));
            try either.array.append(json.string("number"));
            try json.put(a, &o, "type", either);
        },
        .text_list => {
            var list = json.object();
            try json.putString(a, &list, "type", "array");
            try json.put(a, &list, "items", try textSchema(a));
            var any_of = json.array(a);
            try any_of.array.append(try textSchema(a));
            try any_of.array.append(list);
            try json.put(a, &o, "anyOf", any_of);
        },
        .string_list => {
            try json.putString(a, &o, "type", "array");
            var item = json.object();
            try json.putString(a, &item, "type", "string");
            try json.put(a, &o, "items", item);
        },
        .any_map, .dict => {
            try json.putString(a, &o, "type", "object");
            if (t == .dict) try json.put(a, &o, "additionalProperties", try fieldsSchema(a, sub));
        },
        .map, .text => unreachable,
    }
    return o;
}

/// One "properties" entry per field; unknown keys are not allowed.
fn fieldsSchema(a: Allocator, fields: []const Field) Allocator.Error!json.Value {
    var o = json.object();
    try json.putString(a, &o, "type", "object");
    var props = json.object();
    for (fields) |f| {
        var p = try typeSchema(a, f.type, f.sub);
        try json.putString(a, &p, "description", f.doc);
        try json.put(a, &props, f.key, p);
    }
    try json.put(a, &o, "properties", props);
    try json.put(a, &o, "additionalProperties", .{ .bool = false });
    return o;
}

/// The whole schema as indented JSON, ending with a newline. Caller owns
/// the result.
pub fn text(gpa: Allocator) Allocator.Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try fieldsSchema(a, &validate.top_fields);
    try json.putString(a, &s, "$schema", "https://json-schema.org/draft/2020-12/schema");
    try json.putString(a, &s, "title", "arx agent spec");
    var required = json.array(a);
    try required.array.append(json.string("model"));
    try required.array.append(json.string("endpoint"));
    try json.put(a, &s, "required", required);
    var endpoint_required = json.array(a);
    try endpoint_required.array.append(json.string("base_url"));
    try json.put(a, json.getPtr(&s, "properties.endpoint").?, "required", endpoint_required);
    const body = try json.stringifyPretty(a, s);
    return std.mem.concat(gpa, u8, &.{ body, "\n" });
}

test "schema is valid JSON with the top-level keys" {
    const gpa = std.testing.allocator;
    const out = try text(gpa);
    defer gpa.free(out);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = try json.parse(arena.allocator(), out);
    try std.testing.expect(json.get(v, "properties.compaction.properties.trigger") != null);
    try std.testing.expectEqualStrings("integer", json.str(v, "properties.context_window.type").?);
}
