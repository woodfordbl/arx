//! history.zig: the conversation, in OpenAI chat format. Each message owns
//! an arena, so compaction can drop old messages and free them at once
//! while the history lives for days.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const json = @import("../base/json.zig");

/// One message, such as {"role": "user", "content": "..."}.
pub const Message = struct {
    arena: std.heap.ArenaAllocator,
    value: json.Value,

    /// A new message holding an empty object. Free it with `destroy`.
    pub fn create(gpa: Allocator) Allocator.Error!*Message {
        const m = try gpa.create(Message);
        m.* = .{ .arena = .init(gpa), .value = json.object() };
        return m;
    }

    /// A new {"role": role, "content": content} message.
    pub fn text(gpa: Allocator, role_name: []const u8, content: []const u8) Allocator.Error!*Message {
        const m = try create(gpa);
        errdefer m.destroy(gpa);
        const a = m.allocator();
        try json.putString(a, &m.value, "role", role_name);
        try json.putString(a, &m.value, "content", content);
        return m;
    }

    /// A deep copy of `value` as a new message.
    pub fn fromValue(gpa: Allocator, value: json.Value) Allocator.Error!*Message {
        const m = try create(gpa);
        errdefer m.destroy(gpa);
        m.value = try json.copy(m.allocator(), value);
        return m;
    }

    /// The allocator for values stored in this message.
    pub fn allocator(m: *Message) Allocator {
        return m.arena.allocator();
    }

    /// The message's role, or "".
    pub fn role(m: *const Message) []const u8 {
        return json.strOr(m.value, "role", "");
    }

    /// Frees the message and everything in it.
    pub fn destroy(m: *Message, gpa: Allocator) void {
        m.arena.deinit();
        gpa.destroy(m);
    }
};

/// The messages of a conversation, oldest first.
pub const History = struct {
    gpa: Allocator,
    items: std.ArrayList(*Message) = .empty,

    /// An empty history.
    pub fn init(gpa: Allocator) History {
        return .{ .gpa = gpa };
    }

    /// Frees every message.
    pub fn deinit(h: *History) void {
        h.clear();
        h.items.deinit(h.gpa);
    }

    /// Removes and frees every message.
    pub fn clear(h: *History) void {
        for (h.items.items) |m| m.destroy(h.gpa);
        h.items.clearRetainingCapacity();
    }

    /// Adds `m` at the end, taking ownership (also on failure).
    pub fn append(h: *History, m: *Message) Allocator.Error!void {
        h.items.append(h.gpa, m) catch |err| {
            m.destroy(h.gpa);
            return err;
        };
    }

    /// Replaces every message with `messages`, taking ownership of them.
    pub fn replace(h: *History, messages: []const *Message) Allocator.Error!void {
        h.clear();
        try h.items.ensureTotalCapacity(h.gpa, messages.len);
        h.items.appendSliceAssumeCapacity(messages);
    }

    /// The number of messages.
    pub fn len(h: *const History) usize {
        return h.items.items.len;
    }

    /// The messages, oldest first.
    pub fn slice(h: *const History) []const *Message {
        return h.items.items;
    }

    /// Writes the history as a JSON array. With `strip_private`, fields whose
    /// names start with "_" (such as "_out") are left out, as the model must
    /// not see them.
    pub fn write(h: *const History, w: *Writer, strip_private: bool) Writer.Error!void {
        try w.writeByte('[');
        for (h.items.items, 0..) |m, i| {
            if (i > 0) try w.writeByte(',');
            if (!strip_private or m.value != .object) {
                try json.write(w, m.value, .compact);
                continue;
            }
            try w.writeByte('{');
            var first = true;
            for (m.value.object.keys(), m.value.object.values()) |k, v| {
                if (k.len > 0 and k[0] == '_') continue;
                if (!first) try w.writeByte(',');
                first = false;
                try json.writeString(w, k);
                try w.writeByte(':');
                try json.write(w, v, .compact);
            }
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }

    /// A rough token count: the serialized size divided by 4.
    pub fn estimateTokens(h: *const History) i64 {
        var buf: [256]u8 = undefined;
        var counter: Writer.Discarding = .init(&buf);
        h.write(&counter.writer, false) catch {};
        return @intCast(counter.fullCount() / 4);
    }
};

test "history writes and strips private fields" {
    const gpa = std.testing.allocator;
    var h: History = .init(gpa);
    defer h.deinit();
    try h.append(try Message.text(gpa, "user", "hi"));
    const tool = try Message.text(gpa, "tool", "out");
    try json.putString(tool.allocator(), &tool.value, "_out", "/x");
    try h.append(tool);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try h.write(&out.writer, true);
    try std.testing.expectEqualStrings("[{\"role\":\"user\",\"content\":\"hi\"},{\"role\":\"tool\",\"content\":\"out\"}]", out.written());
    try std.testing.expect(h.estimateTokens() > 0);
}
