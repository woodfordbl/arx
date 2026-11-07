//! keys.zig: the keys of a tool call. A key works as a lock: calls that
//! share a key run one at a time, "*" runs alone, and [] runs with
//! anything. A tool declares key templates in its schema, filled in from
//! the arguments of each call.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../base/json.zig");
const Tool = @import("tools.zig").Tool;

/// True when `keys` is a list of strings.
pub fn valid(keys: json.Value) bool {
    if (keys != .array) return false;
    for (keys.array.items) |k| if (k != .string) return false;
    return true;
}

/// The host of a URL (or of a bare host name): no scheme, user, port or
/// path. The caller lowers its case.
fn host(url: []const u8) []const u8 {
    var p = if (std.mem.find(u8, url, "://")) |at| url[at + 3 ..] else url;
    p = p[0 .. std.mem.findAny(u8, p, "/?#") orelse p.len];
    if (std.mem.findScalar(u8, p, '@')) |at| p = p[at + 1 ..];
    if (p.len > 0 and p[0] == '[') { // an IPv6 address keeps its brackets
        if (std.mem.findScalar(u8, p, ']')) |close| return p[0 .. close + 1];
        return p;
    }
    return p[0 .. std.mem.findScalar(u8, p, ':') orelse p.len];
}

/// Fills in one key template: {name} becomes the value of the top-level
/// argument `name` ("" when missing), and in a "host:" key just its host.
fn expand(a: Allocator, template: []const u8, args: json.Value) Allocator.Error![]const u8 {
    const is_host = std.mem.startsWith(u8, template, "host:");
    var out: std.ArrayList(u8) = .empty;
    var rest = template;
    while (std.mem.findScalar(u8, rest, '{')) |open| {
        const close = std.mem.findScalarPos(u8, rest, open, '}') orelse break;
        try out.appendSlice(a, rest[0..open]);
        const v = json.field(args, rest[open + 1 .. close]);
        const text = if (v == null) "" else if (v.? == .string) v.?.string else try json.stringify(a, v.?);
        if (is_host) {
            for (host(text)) |ch| try out.append(a, std.ascii.toLower(ch));
        } else try out.appendSlice(a, text);
        rest = rest[close + 1 ..];
    }
    try out.appendSlice(a, rest);
    return out.items;
}

/// The keys of a call to `tool` (null for an unknown tool, which gets [])
/// with the arguments `args`, as a new list in `a`. A tool that declares
/// no keys gets ["*"]; a subagent gets [].
pub fn forCall(a: Allocator, tool: ?*const Tool, args: json.Value) Allocator.Error!json.Value {
    var keys = json.array(a);
    const t = tool orelse return keys;
    const templates = t.keys orelse {
        try keys.array.append(.{ .string = "*" });
        return keys;
    };
    for (templates.array.items) |template| try keys.array.append(.{ .string = try expand(a, template.string, args) });
    return keys;
}

/// True when the list has the key "*".
fn hasStar(keys: json.Value) bool {
    for (json.items(keys)) |k| if (std.mem.eql(u8, k.string, "*")) return true;
    return false;
}

/// True when two calls with these keys may not run at the same time: one
/// of them has "*", or they share a key.
pub fn conflict(a: json.Value, b: json.Value) bool {
    if (hasStar(a) or hasStar(b)) return true;
    for (json.items(a)) |x| for (json.items(b)) |y| if (std.mem.eql(u8, x.string, y.string)) return true;
    return false;
}

test "keys fill in and conflict" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("example.com", host("https://user@example.com:8080/x"));
    try std.testing.expectEqualStrings("[::1]", host("http://[::1]:80/"));
    const args = try json.parseTrusted(a, "{\"url\":\"https://Example.COM/a\",\"path\":\"src/x\"}");
    try std.testing.expectEqualStrings("host:example.com", try expand(a, "host:{url}", args));
    try std.testing.expectEqualStrings("file:src/x", try expand(a, "file:{path}", args));
    const star = try json.parseTrusted(a, "[\"*\"]");
    const none = try json.parseTrusted(a, "[]");
    const one = try json.parseTrusted(a, "[\"x\"]");
    try std.testing.expect(conflict(star, none));
    try std.testing.expect(!conflict(none, one));
    try std.testing.expect(conflict(one, one));
}
