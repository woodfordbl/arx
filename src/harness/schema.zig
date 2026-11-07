//! schema.zig: generates the JSON Schema for agent.yaml (`arx schema`) from
//! the field table in validate.zig, for editor completion and validation.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../base/json.zig");
const validate = @import("validate.zig");
const Field = validate.Field;

/// The schema of a text node: a string or {file: path}.
const text_schema =
    \\{"anyOf":[{"type":"string"},{"type":"object","properties":{"file":{"type":"string"}},"required":["file"],"additionalProperties":false}]}
;

/// The schema for one field, as JSON text for the fixed shapes.
fn fieldSchema(a: Allocator, f: Field) Allocator.Error!json.Value {
    const fixed: []const u8 = switch (f.type) {
        .map => return fieldsSchema(a, f.sub),
        .dict => {
            var o = try json.parseTrusted(a, "{\"type\":\"object\"}");
            try json.put(a, &o, "additionalProperties", try fieldsSchema(a, f.sub));
            return o;
        },
        .string => "{\"type\":\"string\"}",
        .number => "{\"type\":\"number\"}",
        .integer => "{\"type\":\"integer\"}",
        .boolean => "{\"type\":\"boolean\"}",
        .duration, .size => "{\"type\":[\"string\",\"number\"]}",
        .text => text_schema,
        .text_list => "{\"anyOf\":[" ++ text_schema ++ ",{\"type\":\"array\",\"items\":" ++ text_schema ++ "}]}",
        .string_list => "{\"type\":\"array\",\"items\":{\"type\":\"string\"}}",
        .any_map => "{\"type\":\"object\"}",
    };
    return json.parseTrusted(a, fixed);
}

/// One "properties" entry per field; unknown keys are not allowed.
fn fieldsSchema(a: Allocator, fields: []const Field) Allocator.Error!json.Value {
    var props = json.object();
    for (fields) |f| {
        var p = try fieldSchema(a, f);
        try json.putString(a, &p, "description", f.doc);
        try json.put(a, &props, f.key, p);
    }
    var o = try json.parseTrusted(a, "{\"type\":\"object\"}");
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
    try json.put(a, &s, "required", try json.parseTrusted(a, "[\"model\",\"endpoint\"]"));
    try json.put(a, json.getPtr(&s, "properties.endpoint").?, "required", try json.parseTrusted(a, "[\"base_url\"]"));
    return std.mem.concat(gpa, u8, &.{ try json.stringifyPretty(a, s), "\n" });
}
