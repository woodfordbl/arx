//! sse.zig: turns "data: {...}" chunks of a streamed Chat Completions reply
//! into text and tool calls. Providers differ: some resend the whole tool
//! name in every chunk, some omit tool call ids or indexes, some send a
//! final non-delta "message". All of those are handled here so the loop
//! sees one clean message. A reply that was not streamed is accepted too.

const std = @import("std");
const Allocator = std.mem.Allocator;

const json = @import("../base/json.zig");
const util = @import("../base/util.zig");
const proc = @import("../base/proc.zig");
const Events = @import("../io/events.zig").Events;
const Message = @import("../io/history.zig").Message;

/// The most tool calls one reply can carry.
pub const max_tool_calls = 64;

/// Non-SSE body text kept for error messages.
const max_raw_bytes = 65536;

/// One tool call, assembled from streamed pieces.
const ToolCallParts = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    args: std.ArrayList(u8) = .empty,
};

/// The state of one streamed reply.
pub const Stream = struct {
    /// Holds everything below; a stream lives for one attempt.
    arena: std.heap.ArenaAllocator,
    /// Where to stream the text as it arrives, or null.
    events: ?*Events = null,
    /// A line that has not ended yet.
    line: std.ArrayList(u8) = .empty,
    /// Assistant text so far.
    text: std.ArrayList(u8) = .empty,
    calls: [max_tool_calls]ToolCallParts = @splat(.{}),
    call_count: usize = 0,
    /// Body lines that are not SSE (an error, or a whole JSON reply).
    raw: std.ArrayList(u8) = .empty,
    /// SSE data chunks parsed.
    chunks: usize = 0,
    /// Saw "data: [DONE]".
    done: bool = false,
    finish_reason: ?[]const u8 = null,
    /// An error object sent inside the stream.
    stream_error: ?[]const u8 = null,
    tokens_in: i64 = 0,
    tokens_out: i64 = 0,
    /// usage.cost, when the provider sends one.
    cost: ?f64 = null,
    /// Holds each parsed chunk, reset after it is read.
    scratch: std.heap.ArenaAllocator,

    /// A stream that shows its text on `events` when set.
    pub fn init(gpa: Allocator, events: ?*Events) Stream {
        return .{ .arena = .init(gpa), .events = events, .scratch = .init(gpa) };
    }

    /// Frees everything the stream holds.
    pub fn deinit(s: *Stream) void {
        s.arena.deinit();
        s.scratch.deinit();
    }

    /// The sink that feeds curl's stdout into this stream.
    pub fn sink(s: *Stream) proc.Sink {
        return .init(s, feed);
    }

    /// Splits the incoming bytes into lines.
    fn feed(s: *Stream, bytes: []const u8) Allocator.Error!void {
        try s.line.appendSlice(s.arena.allocator(), bytes);
        var start: usize = 0;
        while (std.mem.findScalarPos(u8, s.line.items, start, '\n')) |nl| {
            try s.readLine(std.mem.trimEnd(u8, s.line.items[start..nl], "\r"));
            start = nl + 1;
        }
        s.line.replaceRangeAssumeCapacity(0, start, &.{});
    }

    /// Call once the body has ended: handles a last line without a newline,
    /// and a reply that was not streamed.
    pub fn end(s: *Stream) Allocator.Error!void {
        try s.readLine(std.mem.trimEnd(u8, s.line.items, "\r"));
        s.line.clearRetainingCapacity();
        if (s.chunks > 0 or s.raw.items.len == 0) return;
        defer _ = s.scratch.reset(.retain_capacity);
        const body = try json.parseObject(s.scratch.allocator(), s.raw.items) orelse return;
        if (json.field(body, "choices") != null) {
            try s.readChunk(body);
            s.done = true;
        }
    }

    /// True when the reply finished normally (a finish_reason or [DONE]).
    pub fn complete(s: *const Stream) bool {
        return s.done or s.finish_reason != null;
    }

    /// Handles one complete line of the body.
    fn readLine(s: *Stream, line: []const u8) Allocator.Error!void {
        if (line.len == 0 or line[0] == ':') return; // event boundary or comment
        if (std.mem.startsWith(u8, line, "data:")) {
            var data = line[5..];
            if (data.len > 0 and data[0] == ' ') data = data[1..];
            if (std.mem.eql(u8, data, "[DONE]")) {
                s.done = true;
                return;
            }
            defer _ = s.scratch.reset(.retain_capacity);
            const chunk = try json.parseObject(s.scratch.allocator(), data) orelse return;
            s.chunks += 1;
            try s.readChunk(chunk);
        } else if (!std.mem.startsWith(u8, line, "event:") and !std.mem.startsWith(u8, line, "id:") and
            !std.mem.startsWith(u8, line, "retry:") and s.raw.items.len < max_raw_bytes)
        {
            try s.raw.appendSlice(s.arena.allocator(), line);
            try s.raw.append(s.arena.allocator(), '\n');
        }
    }

    /// Handles one parsed chunk (or a whole non-streamed reply).
    fn readChunk(s: *Stream, chunk: json.Value) Allocator.Error!void {
        if (json.field(chunk, "error")) |err| {
            s.stream_error = try s.arena.allocator().dupe(u8, json.strOr(err, "message", "error in the stream"));
        }
        s.readUsage(json.field(chunk, "usage"));
        const choices = json.items(json.field(chunk, "choices"));
        if (choices.len == 0) return;
        const choice = choices[0];
        try s.readDelta(json.field(choice, "delta") orelse json.field(choice, "message"));
        if (json.str(choice, "finish_reason")) |reason| {
            s.finish_reason = try s.arena.allocator().dupe(u8, reason);
        }
    }

    /// Reads usage numbers, wherever in the stream they arrive. Providers
    /// report cost differently: OpenRouter sends usage.cost; Vercel AI
    /// Gateway sends usage.cost = 0 when the request used your own provider
    /// key, with the real price in usage.market_cost. The first non-zero one
    /// wins; with none, the spec's prices are used.
    fn readUsage(s: *Stream, usage: ?json.Value) void {
        if (!(usage != null and usage.? == .object)) return;
        s.tokens_in = json.int(usage, "prompt_tokens", s.tokens_in);
        s.tokens_out = json.int(usage, "completion_tokens", s.tokens_out);
        for ([_][]const u8{ "cost", "market_cost", "cost_details.upstream_inference_cost" }) |key| {
            const cost = json.num(usage, key, 0);
            if (cost > 0) {
                s.cost = cost;
                break;
            }
        }
    }

    /// Reads a delta (or a whole message) from a choice.
    fn readDelta(s: *Stream, delta: ?json.Value) Allocator.Error!void {
        if (json.str(delta, "content")) |content| {
            if (content.len > 0) {
                try s.text.appendSlice(s.arena.allocator(), content);
                if (s.events) |e| try e.delta(content);
            }
        }
        for (json.items(json.field(delta, "tool_calls")), 0..) |call, position| {
            try s.readToolCall(call, position);
        }
    }

    /// Adds one streamed piece of a tool call.
    fn readToolCall(s: *Stream, call: json.Value, position: usize) Allocator.Error!void {
        const index = json.int(call, "index", @intCast(position));
        if (index < 0 or index >= max_tool_calls) return;
        const i: usize = @intCast(index);
        s.call_count = @max(s.call_count, i + 1);
        const parts = &s.calls[i];
        if (json.str(call, "id")) |id| {
            if (id.len > 0 and parts.id.items.len == 0) try parts.id.appendSlice(s.arena.allocator(), id);
        }
        // A name equal to what we have is a resend; anything else is a fragment.
        if (json.str(call, "function.name")) |name| {
            if (name.len > 0 and !std.mem.eql(u8, parts.name.items, name)) try parts.name.appendSlice(s.arena.allocator(), name);
        }
        if (json.str(call, "function.arguments")) |args| try parts.args.appendSlice(s.arena.allocator(), args);
    }

    /// The assistant message in Chat Completions format. Content is null when
    /// the reply only calls tools; a tool call without an id gets
    /// "call_<turn>_<index>". Caller owns the message.
    pub fn message(s: *const Stream, gpa: Allocator, turn: i64) Allocator.Error!*Message {
        const m = try Message.create(gpa);
        errdefer m.destroy(gpa);
        const a = m.allocator();
        try json.putString(a, &m.value, "role", "assistant");
        var calls = json.array(a);
        for (s.calls[0..s.call_count], 0..) |*parts, i| {
            if (parts.name.items.len == 0) continue;
            var call = json.object();
            const id = if (parts.id.items.len > 0)
                try a.dupe(u8, parts.id.items)
            else
                try a.print("call_{d}_{d}", .{ turn, i });
            try json.put(a, &call, "id", .{ .string = id });
            try json.putString(a, &call, "type", "function");
            var function = json.object();
            try json.putString(a, &function, "name", parts.name.items);
            try json.putString(a, &function, "arguments", if (parts.args.items.len > 0) parts.args.items else "{}");
            try json.put(a, &call, "function", function);
            try calls.array.append(call);
        }
        const has_calls = calls.array.items.len > 0;
        if (has_calls and s.text.items.len == 0) {
            try json.put(a, &m.value, "content", .null);
        } else {
            try json.putString(a, &m.value, "content", s.text.items);
        }
        if (has_calls) try json.put(a, &m.value, "tool_calls", calls);
        return m;
    }

    /// A short error message from a non-SSE body: error.message, message or
    /// error, else the body itself. Caller owns the result.
    pub fn errorText(s: *Stream, t: Allocator) Allocator.Error![]const u8 {
        if (s.stream_error) |e| return e;
        if (s.raw.items.len == 0) return "(empty response)";
        const body = json.parse(t, s.raw.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => json.Value.null,
        };
        const text = json.str(body, "error.message") orelse json.str(body, "message") orelse
            json.str(body, "error") orelse s.raw.items;
        return util.truncate(t, text, 500);
    }
};
