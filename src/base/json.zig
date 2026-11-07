//! json.zig: JSON values (std.json.Value) and the lookups arx uses on
//! them: dotted paths, typed reads with defaults, YAML-style scalars, a
//! parser that bounds nesting, and a writer whose numbers read naturally
//! (integers without ".0", decimals without exponents).
//!
//! Values live in arenas: whoever owns a tree owns the arena it was built
//! in, so trees are never freed piece by piece.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("util.zig");

pub const Value = std.json.Value;
pub const ObjectMap = std.json.ObjectMap;
pub const Array = std.json.Array;

const json_write = @import("json_write.zig");
pub const Style = json_write.Style;
pub const write = json_write.write;
pub const writeString = json_write.writeString;
pub const stringify = json_write.stringify;
pub const stringifyPretty = json_write.stringifyPretty;

/// The deepest nesting `parse` accepts. Deeper input is rejected before it
/// is built, so the recursive helpers here cannot run out of stack.
pub const max_depth = 256;

/// The value under one key of an object, or null.
pub fn field(v: ?Value, key: []const u8) ?Value {
    const value = v orelse return null;
    return switch (value) {
        .object => |o| o.get(key),
        else => null,
    };
}

/// The value at a dotted path such as "tools.bash.timeout", or null.
pub fn get(v: ?Value, dotted: []const u8) ?Value {
    var current = v orelse return null;
    var it = std.mem.splitScalar(u8, dotted, '.');
    while (it.next()) |key| current = field(current, key) orelse return null;
    return current;
}

/// A pointer to the value at a dotted path, for changing it in place.
pub fn getPtr(v: *Value, dotted: []const u8) ?*Value {
    var current = v;
    var it = std.mem.splitScalar(u8, dotted, '.');
    while (it.next()) |key| {
        switch (current.*) {
            .object => |*o| current = o.getPtr(key) orelse return null,
            else => return null,
        }
    }
    return current;
}

/// The string at `dotted`, or null if it is missing or not a string.
pub fn str(v: ?Value, dotted: []const u8) ?[]const u8 {
    return switch (get(v, dotted) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// The string at `dotted`, or `default`.
pub fn strOr(v: ?Value, dotted: []const u8, default: []const u8) []const u8 {
    return str(v, dotted) orelse default;
}

/// A number as f64, or null if `v` is not a number.
pub fn asNumber(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// The number at `dotted`, or `default`.
pub fn num(v: ?Value, dotted: []const u8, default: f64) f64 {
    return asNumber(get(v, dotted) orelse return default) orelse default;
}

/// The number at `dotted` as an integer (truncated), or `default`.
pub fn int(v: ?Value, dotted: []const u8, default: i64) i64 {
    const f = asNumber(get(v, dotted) orelse return default) orelse return default;
    if (!(f > -9.2e18 and f < 9.2e18)) return default;
    return @intFromFloat(f);
}

/// The boolean at `dotted`, or `default`.
pub fn boolean(v: ?Value, dotted: []const u8, default: bool) bool {
    return switch (get(v, dotted) orelse return default) {
        .bool => |b| b,
        else => default,
    };
}

/// The duration at `dotted` in seconds ("10s", "5m" or a number), or
/// `default`.
pub fn duration(v: ?Value, dotted: []const u8, default: f64) f64 {
    const value = get(v, dotted) orelse return default;
    if (asNumber(value)) |n| return n;
    return switch (value) {
        .string => |s| util.parseDuration(s) orelse default,
        else => default,
    };
}

/// The size at `dotted` in bytes ("2kb" or a number), or `default`.
pub fn size(v: ?Value, dotted: []const u8, default: u64) u64 {
    const value = get(v, dotted) orelse return default;
    if (asNumber(value)) |n| return if (n >= 0 and n < 1.8e19) @intFromFloat(n) else default;
    return switch (value) {
        .string => |s| util.parseSize(s) orelse default,
        else => default,
    };
}

/// True when `v` is an object.
pub fn isObject(v: ?Value) bool {
    return v != null and v.? == .object;
}

/// The items of an array, or none.
pub fn items(v: ?Value) []Value {
    const value = v orelse return &.{};
    return switch (value) {
        .array => |a| a.items,
        else => &.{},
    };
}

/// The keys of an object, or none.
pub fn keys(v: ?Value) []const []const u8 {
    const value = v orelse return &.{};
    return switch (value) {
        .object => |o| o.keys(),
        else => &.{},
    };
}

/// The values of an object, in key order, or none.
pub fn values(v: ?Value) []Value {
    const value = v orelse return &.{};
    return switch (value) {
        .object => |o| o.values(),
        else => &.{},
    };
}

/// A new, empty object.
pub fn object() Value {
    return .{ .object = .empty };
}

/// A new, empty array whose items are allocated in `arena`.
pub fn array(arena: Allocator) Value {
    return .{ .array = Array.init(arena) };
}

/// A string value that refers to `s` (no copy).
pub fn string(s: []const u8) Value {
    return .{ .string = s };
}

/// A number value: an integer when `f` is a whole number, else a float.
pub fn number(f: f64) Value {
    if (f == @trunc(f) and @abs(f) < 9e15) return .{ .integer = @intFromFloat(f) };
    return .{ .float = f };
}

/// Sets `key` of object `obj` to `value`, copying the key into `arena`. An
/// existing key keeps its place.
pub fn put(arena: Allocator, obj: *Value, key: []const u8, value: Value) Allocator.Error!void {
    const gop = try obj.object.getOrPut(arena, key);
    if (!gop.found_existing) gop.key_ptr.* = try arena.dupe(u8, key);
    gop.value_ptr.* = value;
}

/// Sets `key` to a copy of string `s`.
pub fn putString(arena: Allocator, obj: *Value, key: []const u8, s: []const u8) Allocator.Error!void {
    try put(arena, obj, key, .{ .string = try arena.dupe(u8, s) });
}

/// Removes `key` from object `obj`, keeping the order of the rest.
pub fn remove(obj: *Value, key: []const u8) void {
    if (obj.* == .object) _ = obj.object.orderedRemove(key);
}

/// Sets the value at `dotted`, creating objects on the way (and replacing
/// anything on the way that is not an object).
pub fn set(arena: Allocator, root: *Value, dotted: []const u8, value: Value) Allocator.Error!void {
    var current = root;
    var it = std.mem.splitScalar(u8, dotted, '.');
    var key = it.next() orelse return;
    while (it.next()) |next| {
        if (current.* != .object) current.* = object();
        const gop = try current.object.getOrPut(arena, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try arena.dupe(u8, key);
            gop.value_ptr.* = object();
        } else if (gop.value_ptr.* != .object) {
            gop.value_ptr.* = object();
        }
        current = gop.value_ptr;
        key = next;
    }
    if (current.* != .object) current.* = object();
    try put(arena, current, key, value);
}

/// Parses a YAML scalar. Plain (unquoted) "true", "false", "null", "~", ""
/// and decimal numbers become those JSON types; anything else, and every
/// quoted scalar, stays a string. "0x10", "inf" and "1e" stay strings.
pub fn scalar(arena: Allocator, text: []const u8, plain: bool) Allocator.Error!Value {
    if (plain) {
        if (std.mem.eql(u8, text, "true")) return .{ .bool = true };
        if (std.mem.eql(u8, text, "false")) return .{ .bool = false };
        if (text.len == 0 or std.mem.eql(u8, text, "null") or std.mem.eql(u8, text, "~")) return .null;
        if (std.mem.findNone(u8, text, "0123456789+-.eE") == null) {
            if (util.leadingNumber(text)) |n| {
                if (n.rest.len == 0) return number(n.value);
            }
        }
    }
    return .{ .string = try arena.dupe(u8, text) };
}

/// The deepest nesting of arrays and objects in `text`, counted without
/// parsing it.
fn nestingDepth(text: []const u8) usize {
    var depth: usize = 0;
    var deepest: usize = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (in_string) {
            if (ch == '\\') {
                i += 1;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        switch (ch) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                deepest = @max(deepest, depth);
            },
            ']', '}' => depth -|= 1,
            else => {},
        }
    }
    return deepest;
}

/// Why `parse` failed.
pub const ParseError = error{ OutOfMemory, SyntaxError, TooDeep };

/// Parses `text` into a value in `arena`. Strings are copied, so `text` can
/// be freed afterwards. A duplicate key keeps its first value.
pub fn parse(arena: Allocator, text: []const u8) ParseError!Value {
    if (nestingDepth(text) > max_depth) return error.TooDeep;
    return std.json.parseFromSliceLeaky(Value, arena, text, .{
        .duplicate_field_behavior = .use_first,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SyntaxError,
    };
}

/// Parses JSON text that is known to be valid, such as a constant.
pub fn parseTrusted(arena: Allocator, text: []const u8) Allocator.Error!Value {
    return parse(arena, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SyntaxError, error.TooDeep => unreachable,
    };
}

/// Parses `text` and returns the value when it is an object, else null.
pub fn parseObject(arena: Allocator, text: []const u8) Allocator.Error!?Value {
    const v = parse(arena, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return if (v == .object) v else null;
}

/// A deep copy of `v` in `arena`.
pub fn copy(arena: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .number_string => |s| .{ .number_string = try arena.dupe(u8, s) },
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .array => |a| blk: {
            var out = Array.init(arena);
            try out.ensureTotalCapacity(a.items.len);
            for (a.items) |item| out.appendAssumeCapacity(try copy(arena, item));
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            var out: Value = object();
            try out.object.ensureTotalCapacity(arena, o.count());
            for (o.keys(), o.values()) |k, item| {
                out.object.putAssumeCapacity(try arena.dupe(u8, k), try copy(arena, item));
            }
            break :blk out;
        },
    };
}

/// True when `a` and `b` hold the same JSON (object keys in any order).
pub fn equal(a: Value, b: Value) bool {
    if (asNumber(a)) |x| return if (asNumber(b)) |y| x == y else false;
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| b == .array and x.items.len == b.array.items.len and for (x.items, b.array.items) |p, q| {
            if (!equal(p, q)) break false;
        } else true,
        .object => |x| b == .object and x.count() == b.object.count() and for (x.keys(), x.values()) |k, p| {
            const q = b.object.get(k) orelse break false;
            if (!equal(p, q)) break false;
        } else true,
        .integer, .float, .number_string => unreachable,
    };
}

test "dotted lookups" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parse(a, "{\"tools\":{\"bash\":{\"timeout\":\"5m\",\"on\":true}},\"n\":2.5}");
    try std.testing.expectEqual(@as(f64, 300), duration(v, "tools.bash.timeout", 0));
    try std.testing.expect(boolean(v, "tools.bash.on", false));
    try std.testing.expectEqual(@as(f64, 2.5), num(v, "n", 0));
    try std.testing.expectEqual(@as(?[]const u8, null), str(v, "tools.x"));
}

test "set creates objects and write is compact" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = object();
    try set(a, &v, "limits.max_turns", number(10));
    try set(a, &v, "cost", number(0.0123));
    try putString(a, &v, "s", "a\"b\n\x01");
    const text = try stringify(a, v);
    try std.testing.expectEqualStrings("{\"limits\":{\"max_turns\":10},\"cost\":0.0123,\"s\":\"a\\\"b\\n\\u0001\"}", text);
}

test "scalars" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try scalar(a, "true", true)) == .bool);
    try std.testing.expect((try scalar(a, "12", true)) == .integer);
    try std.testing.expect((try scalar(a, "0.5", true)) == .float);
    try std.testing.expect((try scalar(a, "0x10", true)) == .string);
    try std.testing.expect((try scalar(a, "12", false)) == .string);
    try std.testing.expect((try scalar(a, "", true)) == .null);
}

test "parse rejects deep nesting and keeps the first duplicate" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deep: [max_depth + 1]u8 = @splat('[');
    try std.testing.expectError(error.TooDeep, parse(a, &deep));
    const v = try parse(a, "{\"a\":1,\"a\":2}");
    try std.testing.expectEqual(@as(f64, 1), num(v, "a", 0));
    try std.testing.expect(equal(v, try copy(a, v)));
}
