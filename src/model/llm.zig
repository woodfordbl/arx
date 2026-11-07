//! llm.zig: one OpenAI-compatible Chat Completions request per call, sent
//! by running curl (so the binary carries no TLS code), classified, and
//! retried on transient errors with backoff. Credentials and request
//! headers come from auth.zig; the streamed reply is parsed by sse.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const sys = @import("../base/sys.zig");
const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const proc = @import("../base/proc.zig");
const History = @import("../io/history.zig").History;
const Message = @import("../io/history.zig").Message;
const auth = @import("auth.zig");
const Stream = @import("sse.zig").Stream;
const Agent = @import("../agent/agent.zig").Agent;

/// A model reply.
pub const Reply = struct {
    /// The assistant message; the caller owns it.
    message: *Message,
    tokens_in: i64,
    tokens_out: i64,
    /// From the provider, else from the spec's prices.
    cost: f64,
};

/// How a model call ended.
pub const Result = union(enum) {
    ok: Reply,
    /// A request error that retrying will not fix.
    fatal,
    /// 401 or 403.
    auth,
    /// The prompt is too long for the model.
    context,
    /// Ctrl-C.
    interrupted,
};

/// What to do after one attempt.
const Outcome = enum { ok, retry, auth, context, fatal, interrupted };

/// The request body: the model, the messages without "_" fields, the tools,
/// streaming options, then model_settings on top (a null setting removes
/// the field). Caller owns the result.
fn requestBody(gpa: Allocator, root: json.Value, messages: *const History, tools_json: ?[]const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    writeBody(&out.writer, root, messages, tools_json) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Writes the request body; see `requestBody`.
fn writeBody(w: *Writer, root: json.Value, messages: *const History, tools_json: ?[]const u8) Writer.Error!void {
    const settings = json.field(root, "model_settings");
    var body: BodyWriter = .{ .w = w, .settings = settings };
    try w.writeByte('{');
    if (try body.key("model")) try json.writeString(w, json.strOr(root, "model", ""));
    if (try body.key("messages")) try messages.write(w, true);
    if (tools_json) |t| if (t.len > 2) if (try body.key("tools")) try w.writeAll(t);
    if (try body.key("stream")) try w.writeAll("true");
    if (try body.key("stream_options")) try w.writeAll("{\"include_usage\":true}");
    for (json.keys(settings), json.values(settings)) |k, v| {
        if (v == .null) continue;
        body.settings = null;
        _ = try body.key(k);
        try json.write(w, v, .compact);
    }
    try w.writeByte('}');
}

/// Writes object keys with commas between them, leaving out keys that
/// model_settings replaces.
const BodyWriter = struct {
    w: *Writer,
    settings: ?json.Value,
    first: bool = true,

    /// Writes `"name":` unless model_settings has the key. Returns whether
    /// the caller should write the value.
    fn key(b: *BodyWriter, name: []const u8) Writer.Error!bool {
        if (json.field(b.settings, name) != null) return false;
        if (!b.first) try b.w.writeByte(',');
        b.first = false;
        try json.writeString(b.w, name);
        try b.w.writeByte(':');
        return true;
    }
};

/// One attempt's results.
const Attempt = struct {
    run: proc.Result,
    curl_err: *const proc.Collector,
    headers: auth.ResponseHeaders,
};

/// One request: runs curl and parses the streamed reply into `stream`.
fn attempt(a: *Agent, body: []const u8, timeout: f64, stream: *Stream, curl_err: *proc.Collector) !Attempt {
    const ctx = a.ctx;
    const gpa = ctx.gpa;
    const root = a.spec.root;
    const dir = a.session.?.dir;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = arena.allocator();
    const url = try auth.endpointUrl(t, root, "/chat/completions");
    const headers = try auth.writeRequestHeaders(ctx, &a.auth, root, dir, true);
    defer gpa.free(headers);
    defer std.Io.Dir.cwd().deleteFile(ctx.io, headers) catch {};
    const response = try std.mem.concat(t, u8, &.{ dir, "/.response-headers" });
    defer std.Io.Dir.cwd().deleteFile(ctx.io, response) catch {};
    std.Io.Dir.cwd().deleteFile(ctx.io, response) catch {};
    const r = proc.run(ctx, .{
        .argv = &.{
            auth.curlPath(ctx, root),          "-sS",           "-N",     "--max-time",
            try t.print("{d:.0}", .{timeout}), "-D",            response, "-H",
            try t.print("@{s}", .{headers}),   "--data-binary", "@-",     url,
        },
        .stdin = body,
        .timeout = timeout + 30,
        .stdout = stream.sink(),
        .stderr = curl_err.sink(),
    });
    try stream.end();
    return .{ .run = r, .curl_err = curl_err, .headers = try auth.readResponseHeaders(ctx, response) };
}

/// curl exit codes worth retrying: DNS, connect, timeouts, dropped
/// connections and TLS handshakes.
fn retryableCurl(code: u8) bool {
    return switch (code) {
        5, 6, 7, 16, 18, 28, 35, 52, 55, 56, 92 => true,
        else => false,
    };
}

/// True when an error message is about the prompt being too long.
fn looksLikeContext(message: []const u8) bool {
    for ([_][]const u8{ "context", "too long", "maximum", "too many" }) |word| {
        if (std.ascii.findIgnoreCase(message, word) != null) return true;
    }
    return false;
}

/// Decides what to do with an attempt; writes the reason to `why`.
fn classify(gpa: Allocator, at: *const Attempt, stream: *Stream, why: *std.ArrayList(u8)) Allocator.Error!Outcome {
    const r = at.run;
    if (r.interrupted) return .interrupted;
    if (r.spawn_error) |err| {
        try why.print(gpa, "cannot run curl: {s}", .{proc.describeSpawnError(err)});
        return .fatal;
    }
    if (r.code != 0) {
        try why.print(gpa, "curl exit {d}: {s}", .{ r.code, std.mem.trimEnd(u8, at.curl_err.output(), "\n") });
        return if (retryableCurl(r.code)) .retry else .fatal;
    }
    const status = at.headers.status;
    if (status == 200 or (status == 0 and stream.chunks > 0)) {
        if (stream.stream_error) |e| {
            try why.print(gpa, "error in the stream: {s}", .{e});
            return .retry;
        }
        if (stream.complete()) return .ok;
        try why.appendSlice(gpa, "the stream ended before the reply finished");
        return .retry;
    }
    const message = try stream.errorText(gpa);
    defer gpa.free(message);
    try why.print(gpa, "HTTP {d}: {s}", .{ status, message });
    return switch (status) {
        401, 403 => .auth,
        429, 408, 409, 425 => .retry,
        400, 413, 422 => if (looksLikeContext(message)) .context else .fatal,
        else => if (status >= 500) .retry else .fatal,
    };
}

/// Cost from the spec's per-million-token prices.
fn priceCost(root: json.Value, in: i64, out: i64) f64 {
    return json.num(root, "prices.input", 0) * @as(f64, @floatFromInt(in)) / 1e6 +
        json.num(root, "prices.output", 0) * @as(f64, @floatFromInt(out)) / 1e6;
}

/// Exponential backoff, or Retry-After when the server sent one.
fn retryWait(root: json.Value, n: usize, retry_after: ?f64) f64 {
    const max_wait = json.duration(root, "endpoint.retry_max", 300);
    var wait = json.duration(root, "endpoint.retry_base", 2);
    if (retry_after) |seconds| {
        wait = seconds;
    } else {
        var i: usize = 1;
        while (i < n and wait < max_wait) : (i += 1) wait *= 2;
    }
    return @min(wait, max_wait);
}

/// Sends `messages` and `tools_json` (a JSON array, or null for none) to the
/// spec's model. Fields whose names start with "_" are stripped from the
/// messages first. With `show` set, text streams to the terminal and the
/// event stream as it arrives. Retries 429, 5xx, timeouts and network
/// errors with backoff (honoring Retry-After), sending a model.retry event
/// each time. On failure, appends the reason to `why`.
pub fn chat(a: *Agent, messages: *const History, tools_json: ?[]const u8, show: bool, why: *std.ArrayList(u8)) !Result {
    const gpa = a.ctx.gpa;
    const root = a.spec.root;
    const max_attempts = json.int(root, "endpoint.retry_attempts", 0);
    var timeout = json.duration(root, "limits.turn_timeout", 600);
    if (a.caps.wall > 0) {
        const left = a.caps.wall - (util.now(a.ctx.io) - a.start);
        if (left < timeout) timeout = @max(left, 1);
    }
    const body = try requestBody(gpa, root, messages, tools_json);
    defer gpa.free(body);
    var n: usize = 1;
    while (true) : (n += 1) {
        var stream: Stream = .init(gpa, if (show) &a.events else null);
        defer stream.deinit();
        var curl_err: proc.Collector = .init(gpa);
        defer curl_err.deinit();
        var reason: std.ArrayList(u8) = .empty;
        defer reason.deinit(gpa);
        const at = try attempt(a, body, timeout, &stream, &curl_err);
        switch (try classify(gpa, &at, &stream, &reason)) {
            .ok => return .{ .ok = .{
                .message = try stream.message(gpa, a.turns()),
                .tokens_in = stream.tokens_in,
                .tokens_out = stream.tokens_out,
                .cost = stream.cost orelse priceCost(root, stream.tokens_in, stream.tokens_out),
            } },
            .retry => {
                if (max_attempts > 0 and n >= max_attempts) {
                    try why.print(gpa, "gave up after {d} attempts: {s}", .{ n, reason.items });
                    return .fatal;
                }
                const wait = retryWait(root, n, at.headers.retry_after);
                var event = try a.events.begin("model.retry");
                defer event.deinit();
                try event.int("attempt", @intCast(n));
                try event.int("status", at.headers.status);
                try event.int("curl_exit", at.run.code);
                try event.num("wait_s", wait);
                try event.truncated("error", reason.items, 300);
                try a.events.send(&event);
                util.sleepSeconds(a.ctx.io, wait);
                if (sys.isInterrupted()) return .interrupted;
            },
            .auth => {
                try why.appendSlice(gpa, reason.items);
                return .auth;
            },
            .context => {
                try why.appendSlice(gpa, reason.items);
                return .context;
            },
            .fatal => {
                try why.appendSlice(gpa, reason.items);
                return .fatal;
            },
            .interrupted => return .interrupted,
        }
    }
}

test "request body with model_settings" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = try json.parse(arena.allocator(), "{\"model\":\"m\",\"model_settings\":{\"temperature\":0.5,\"stream\":null}}");
    var h: History = .init(gpa);
    defer h.deinit();
    try h.append(try Message.text(gpa, "user", "hi"));
    const body = try requestBody(gpa, root, &h, "[]");
    defer gpa.free(body);
    try std.testing.expectEqualStrings(
        "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream_options\":{\"include_usage\":true},\"temperature\":0.5}",
        body,
    );
}

test "retry waits double up to the maximum" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try json.parse(arena.allocator(), "{\"endpoint\":{\"retry_base\":1,\"retry_max\":5}}");
    try std.testing.expectEqual(@as(f64, 1), retryWait(root, 1, null));
    try std.testing.expectEqual(@as(f64, 4), retryWait(root, 3, null));
    try std.testing.expectEqual(@as(f64, 5), retryWait(root, 9, null));
    try std.testing.expectEqual(@as(f64, 2), retryWait(root, 9, 2));
}
