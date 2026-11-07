//! auth.zig: the endpoint's credentials, and the request plumbing every
//! call to it shares. The API key is found the way fx finds it: an
//! environment variable first, then a key saved by `arx setup` in the macOS
//! Keychain (service "arx") or, elsewhere, in configDir()/credentials
//! (0600). The key reaches curl in a 0600 header file, never on a command
//! line, so it never shows up in process listings.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const sys = @import("../base/sys.zig");
const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const proc = @import("../base/proc.zig");
const Context = @import("../base/context.zig").Context;

/// Finds the API key and remembers a stored one, so the Keychain is asked
/// at most once per run.
pub const Auth = struct {
    /// The variable name the cached key belongs to.
    name: ?[]u8 = null,
    /// The stored key for `name`, or null when none was found.
    stored: ?[]u8 = null,
    /// Where the last `apiKey` call found its key, or null.
    source: ?[]const u8 = null,

    /// Forgets the cached key.
    pub fn deinit(a: *Auth, gpa: Allocator) void {
        if (a.name) |n| gpa.free(n);
        if (a.stored) |s| gpa.free(s);
        a.* = .{};
    }

    /// The API key for the spec's endpoint, or null, in fx's order: for
    /// Vercel AI Gateway, VERCEL_OIDC_TOKEN first; then the environment
    /// variable named by endpoint.api_key_env (default OPENAI_API_KEY); then
    /// the key saved by `arx setup` under that name.
    pub fn apiKey(a: *Auth, ctx: *const Context, root: json.Value) Allocator.Error!?[]const u8 {
        const name = json.strOr(root, "endpoint.api_key_env", "OPENAI_API_KEY");
        if (ctx.getenvNonEmpty("VERCEL_OIDC_TOKEN")) |oidc| {
            if (std.mem.find(u8, json.strOr(root, "endpoint.base_url", ""), "ai-gateway.vercel.sh") != null) {
                a.source = "the VERCEL_OIDC_TOKEN environment variable";
                return oidc;
            }
        }
        if (ctx.getenvNonEmpty(name)) |key| {
            a.source = "an environment variable";
            return key;
        }
        if (a.name == null or !std.mem.eql(u8, a.name.?, name)) {
            a.deinit(ctx.gpa);
            a.name = try ctx.gpa.dupe(u8, name);
            a.stored = try keychainKey(ctx, name);
            if (a.stored != null) {
                a.source = "the macOS Keychain";
            } else {
                a.stored = try fileKey(ctx, name);
                a.source = if (a.stored != null) "the arx credentials file" else null;
            }
        }
        if (a.stored == null) a.source = null;
        return a.stored;
    }
};

/// Removes trailing newlines, carriage returns and spaces.
fn trimEnd(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\n\r ");
}

/// Reads `name` from the macOS Keychain (service "arx"), or null.
fn keychainKey(ctx: *const Context, name: []const u8) Allocator.Error!?[]u8 {
    if (builtin.target.os.tag != .macos) return null;
    if (ctx.getenv("ARX_DISABLE_KEYCHAIN") != null) return null;
    var out: proc.Collector = .init(ctx.gpa);
    defer out.deinit();
    var err: proc.Collector = .init(ctx.gpa);
    defer err.deinit();
    const r = proc.run(ctx, .{
        .argv = &.{ "security", "find-generic-password", "-s", "arx", "-a", name, "-w" },
        .timeout = 10,
        .stdout = out.sink(),
        .stderr = err.sink(),
    });
    if (!r.ok() or out.output().len == 0) return null;
    return try ctx.gpa.dupe(u8, trimEnd(out.output()));
}

/// Reads `name` from configDir()/credentials ("NAME=value" lines), or null.
fn fileKey(ctx: *const Context, name: []const u8) Allocator.Error!?[]u8 {
    const gpa = ctx.gpa;
    const dir = try util.configDir(ctx, gpa);
    defer gpa.free(dir);
    const path = try std.mem.concat(gpa, u8, &.{ dir, "/credentials" });
    defer gpa.free(path);
    const text = (try util.readFile(ctx.io, gpa, path)) orelse return null;
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > name.len and std.mem.startsWith(u8, line, name) and line[name.len] == '=') {
            return try gpa.dupe(u8, trimEnd(line[name.len + 1 ..]));
        }
    }
    return null;
}

/// endpoint.base_url without trailing slashes, followed by `path`. Caller
/// owns the result.
pub fn endpointUrl(gpa: Allocator, root: json.Value, path: []const u8) Allocator.Error![]u8 {
    const base = std.mem.trimEnd(u8, json.strOr(root, "endpoint.base_url", ""), "/");
    return std.mem.concat(gpa, u8, &.{ base, path });
}

/// The curl to run: endpoint.curl, else $ARX_CURL, else "curl".
pub fn curlPath(ctx: *const Context, root: json.Value) []const u8 {
    return json.str(root, "endpoint.curl") orelse ctx.getenvNonEmpty("ARX_CURL") orelse "curl";
}

/// Writes the request headers, including the key, to a new 0600 file in
/// `dir` for `curl -H @file`, and returns its path. Delete it after the
/// call. `streaming` adds "Accept: text/event-stream". Caller owns the path.
pub fn writeRequestHeaders(ctx: *const Context, auth: *Auth, root: json.Value, dir: []const u8, streaming: bool) ![]u8 {
    const gpa = ctx.gpa;
    var h: std.Io.Writer.Allocating = .init(gpa);
    defer h.deinit();
    const w = &h.writer;
    w.writeAll("Content-Type: application/json\n") catch return error.OutOfMemory;
    if (streaming) w.writeAll("Accept: text/event-stream\n") catch return error.OutOfMemory;
    if (try auth.apiKey(ctx, root)) |key| {
        if (key.len > 0) w.print("Authorization: Bearer {s}\n", .{key}) catch return error.OutOfMemory;
    }
    const headers = json.get(root, "endpoint.headers");
    for (json.keys(headers), json.values(headers)) |k, v| {
        if (v == .string) w.print("{s}: {s}\n", .{ k, v.string }) catch return error.OutOfMemory;
    }
    const path = try gpa.print("{s}/.arx-request-{d}", .{ dir, sys.getpid() });
    errdefer gpa.free(path);
    const permissions: Io.File.Permissions = .fromMode(0o600);
    var file = try Io.Dir.cwd().createFile(ctx.io, path, .{ .permissions = permissions });
    defer file.close(ctx.io);
    try file.setPermissions(ctx.io, permissions);
    try file.writePositionalAll(ctx.io, h.written(), 0);
    return path;
}

/// The last HTTP status and any Retry-After from a `curl -D` headers file.
pub const ResponseHeaders = struct {
    /// 0 when there was no response.
    status: u32 = 0,
    /// Seconds to wait before retrying, when the server said.
    retry_after: ?f64 = null,
};

/// Reads the headers file written by `curl -D`. With redirects or 100
/// Continue there are several responses; the last one counts.
pub fn readResponseHeaders(ctx: *const Context, path: []const u8) Allocator.Error!ResponseHeaders {
    var result: ResponseHeaders = .{};
    const text = (try util.readFile(ctx.io, ctx.gpa, path)) orelse return result;
    defer ctx.gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = trimEnd(raw);
        if (std.mem.startsWith(u8, line, "HTTP/")) {
            const space = std.mem.findScalar(u8, line, ' ') orelse continue;
            const rest = line[space + 1 ..];
            const end = std.mem.findNone(u8, rest, "0123456789") orelse rest.len;
            result.status = std.fmt.parseInt(u32, rest[0..end], 10) catch 0;
        } else if (line.len >= 12 and std.ascii.eqlIgnoreCase(line[0..12], "retry-after:")) {
            if (util.leadingNumber(line[12..])) |n| result.retry_after = n.value;
        }
    }
    return result;
}
