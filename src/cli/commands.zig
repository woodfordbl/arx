//! commands.zig: the built-in commands. One table drives both dispatch and
//! `arx help`; everything else is an external `arx-*` command.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const sys = @import("../base/sys.zig");
const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const proc = @import("../base/proc.zig");
const render = @import("../io/render.zig");
const session = @import("../io/session.zig");
const spec_mod = @import("../harness/spec.zig");
const plugins = @import("../harness/plugins.zig");
const schema = @import("../harness/schema.zig");
const tools = @import("../harness/tools.zig");
const validate = @import("../harness/validate.zig");
const auth = @import("../model/auth.zig");
const Agent = @import("../agent/agent.zig").Agent;
const options = @import("options.zig");
const external = @import("external.zig");
const Exit = util.Exit;

/// One built-in command, for dispatch and `arx help`.
pub const Command = struct {
    name: []const u8,
    args: []const u8,
    summary: []const u8,
    run: *const fn (a: *Agent, args: []const []const u8) anyerror!Exit,
};

/// The built-in commands.
pub const all = [_]Command{
    .{ .name = "check", .args = "[--spec P] | --plugin DIR", .summary = "validate the spec, tools and hooks, or one plugin", .run = checkOrTools },
    .{ .name = "tools", .args = "[--spec P]", .summary = "print the tools as the model sees them", .run = checkOrTools },
    .{ .name = "schema", .args = "", .summary = "print the JSON Schema of agent.yaml", .run = schemaCommand },
    .{ .name = "watch", .args = "[ID|last] [--json] [--from start|now]", .summary = "follow a session's events", .run = watchCommand },
    .{ .name = "ctl", .args = "ID|last stop|note TEXT", .summary = "steer a running session", .run = ctlCommand },
    .{ .name = "request", .args = "[-X METHOD] [--data JSON|-] [--auth-source] PATH", .summary = "call your endpoint with your key, e.g. /models", .run = requestCommand },
    .{ .name = "version", .args = "", .summary = "print the version", .run = versionCommand },
    .{ .name = "help", .args = "[COMMAND]", .summary = "everything, or one command", .run = external.helpCommand },
};

/// Runs built-in command `name` (args[1]). Returns null when `name` is not
/// a built-in.
pub fn run(a: *Agent, name: []const u8, args: []const []const u8) anyerror!?Exit {
    for (all) |c| {
        if (!std.mem.eql(u8, c.name, name)) continue;
        if (args.len > 2 and (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "-h"))) {
            render.printOut(a.ctx.io, "usage: arx {s} {s}\n  {s}\n", .{ c.name, c.args, c.summary });
            return .done;
        }
        return try c.run(a, args);
    }
    return null;
}

/// A buffered stdout writer.
const Stdout = struct {
    buf: [4096]u8 = undefined,
    file: Io.File.Writer = undefined,

    /// Starts the writer; `s` must stay put while it is used.
    fn init(s: *Stdout, io: Io) *Io.Writer {
        s.file = Io.File.stdout().writerStreaming(io, &s.buf);
        return &s.file.interface;
    }
};

/// Loads the spec for a command and prints its problems.
fn loadSpec(a: *Agent) Allocator.Error!?Exit {
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(a.ctx.gpa);
    options.resolveSpec(a);
    a.spec = (try spec_mod.load(a.ctx, a.spec_path, a.sets, &err)) orelse {
        render.printErr(a.ctx.io, "{s}", .{err.items});
        return .usage;
    };
    return null;
}

/// Prints the hooks found in the layers, naming the plugins they come from.
fn printHooks(a: *Agent, out: *Io.Writer) !void {
    try out.writeAll("\nhooks:");
    for (validate.hook_points) |point| {
        var found = false;
        var from: std.ArrayList(u8) = .empty;
        defer from.deinit(a.ctx.gpa);
        for (a.spec.layers) |layer| {
            const path = try std.mem.concat(a.ctx.gpa, u8, &.{ layer.dir, "/hooks/", point });
            defer a.ctx.gpa.free(path);
            if (!util.isExecutable(a.ctx.io, path)) continue;
            found = true;
            if (layer.plugin) |plugin| {
                if (from.items.len > 0) try from.append(a.ctx.gpa, ',');
                try from.appendSlice(a.ctx.gpa, plugin);
            }
        }
        if (found) try out.print(" {s}", .{point});
        if (from.items.len > 0) try out.print("({s})", .{from.items});
    }
    try out.writeByte('\n');
}

/// `arx check --plugin DIR`: checks a plugin without loading it, and prints
/// key=value lines for scripts such as `arx plugin`.
fn checkPlugin(a: *Agent, dir: []const u8) !Exit {
    const gpa = a.ctx.gpa;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(gpa);
    if (!try plugins.describe(a.ctx, dir, &out, &err)) {
        render.printErr(a.ctx.io, "{s}", .{err.items});
        return .usage;
    }
    render.printOut(a.ctx.io, "{s}", .{out.items});
    return .done;
}

/// `arx check` and `arx tools`: load the harness without starting a session.
fn checkOrTools(a: *Agent, args: []const []const u8) !Exit {
    const is_check = std.mem.eql(u8, args[1], "check");
    if (is_check and args.len == 4 and std.mem.eql(u8, args[2], "--plugin")) return checkPlugin(a, args[3]);
    if (try options.parse(a, args, 2)) |code| return code;
    if (try loadSpec(a)) |code| return code;
    try tools.build(a);
    var stdout: Stdout = .{};
    const out = stdout.init(a.ctx.io);
    if (!is_check) {
        var arena: std.heap.ArenaAllocator = .init(a.ctx.gpa);
        defer arena.deinit();
        try json.write(out, try a.tools.toValue(arena.allocator()), .pretty);
        try out.writeByte('\n');
        try out.flush();
        return .done;
    }
    const config = a.spec.config;
    const merged = config != null and !std.mem.eql(u8, config.?, a.spec.path);
    try out.print("ok: {s}{s}{s} (model {s} at {s})\ntools:", .{
        a.spec.path,
        if (merged) " + " else "",
        if (merged) config.? else "",
        json.strOr(a.spec.root, "model", ""),
        json.strOr(a.spec.root, "endpoint.base_url", ""),
    });
    for (a.tools.items) |tool| try out.print(" {s}", .{tool.name});
    try printHooks(a, out);
    var any = false;
    for (a.spec.layers) |layer| {
        const plugin = layer.plugin orelse continue;
        try out.print("{s}{s}", .{ if (any) " " else "plugins: ", plugin });
        any = true;
    }
    if (any) try out.writeByte('\n');
    if (a.notes.items.len > 0) try out.print("problems:\n{s}", .{a.notes.items});
    try out.flush();
    return .done;
}

/// `arx schema`.
fn schemaCommand(a: *Agent, args: []const []const u8) !Exit {
    _ = args;
    const text = try schema.text(a.ctx.gpa);
    defer a.ctx.gpa.free(text);
    render.printOut(a.ctx.io, "{s}", .{text});
    return .done;
}

/// `arx version`.
fn versionCommand(a: *Agent, args: []const []const u8) !Exit {
    _ = args;
    render.printOut(a.ctx.io, "arx {s}\n", .{a.ctx.version});
    return .done;
}

/// `arx watch [ID|last] [--json] [--from start|now]`.
fn watchCommand(a: *Agent, args: []const []const u8) !Exit {
    var ref: []const u8 = "last";
    var raw = false;
    var from_start = true;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) {
            raw = true;
        } else if (std.mem.eql(u8, args[i], "--from") and i + 1 < args.len) {
            i += 1;
            from_start = !std.mem.eql(u8, args[i], "now");
        } else {
            ref = args[i];
        }
    }
    return render.watch(a.ctx, ref, raw, from_start);
}

/// `arx ctl ID|last stop|note TEXT`: appends a command to the inbox.
fn ctlCommand(a: *Agent, args: []const []const u8) !Exit {
    const gpa = a.ctx.gpa;
    if (args.len < 4) return options.usageError(a, "ctl needs a session and a command", null);
    const note = std.mem.eql(u8, args[3], "note");
    if (!note and !std.mem.eql(u8, args[3], "stop")) return options.usageError(a, "unknown ctl command", args[3]);
    if (note and args.len < 5) return options.usageError(a, "ctl note needs text", null);
    const dir = (try session.sessionDir(a.ctx, gpa, args[2])) orelse return options.usageError(a, "no such session", args[2]);
    defer gpa.free(dir);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = arena.allocator();
    var command = json.object();
    try json.put(t, &command, "cmd", json.string(args[3]));
    if (note) try json.put(t, &command, "text", json.string(args[4]));
    const line = try std.mem.concat(t, u8, &.{ try json.stringify(t, command), "\n" });
    const path = try std.mem.concat(t, u8, &.{ dir, "/inbox" });
    util.appendFile(path, line) catch return .@"error";
    return .done;
}

/// Copies a response body to stdout.
const StdoutSink = struct {
    /// Writes a chunk of the body to stdout.
    fn write(_: *StdoutSink, bytes: []const u8) void {
        sys.writeAll(1, bytes) catch {};
    }
};

/// One authenticated call to the endpoint; prints the body.
fn request(a: *Agent, method: ?[]const u8, body: ?[]const u8, path: []const u8) !Exit {
    const ctx = a.ctx;
    const gpa = ctx.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = arena.allocator();
    const root = a.spec.root;
    const tmp = ctx.getenvNonEmpty("TMPDIR") orelse "/tmp";
    const headers = try auth.writeRequestHeaders(ctx, &a.auth, root, std.mem.trimEnd(u8, tmp, "/"), false);
    defer gpa.free(headers);
    defer Io.Dir.cwd().deleteFile(ctx.io, headers) catch {};
    const response = try t.print("{s}/.arx-response-{d}", .{ std.mem.trimEnd(u8, tmp, "/"), sys.getpid() });
    defer Io.Dir.cwd().deleteFile(ctx.io, response) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(t, &.{ auth.curlPath(ctx, root), "-sS", "--max-time", "60", "-D", response, "-H", try t.print("@{s}", .{headers}) });
    if (method) |m| try argv.appendSlice(t, &.{ "-X", m });
    if (body != null) try argv.appendSlice(t, &.{ "--data-binary", "@-" });
    try argv.append(t, try auth.endpointUrl(t, root, path));
    var sink: StdoutSink = .{};
    const r = proc.run(ctx, .{ .argv = argv.items, .stdin = body, .timeout = 90, .stdout = .init(&sink, StdoutSink.write) });
    const status = (try auth.readResponseHeaders(ctx, response)).status;
    if (r.code != 0) render.printErr(ctx.io, "arx: curl exited with {d}\n", .{r.code});
    if (r.code != 0 or status < 200 or status >= 300) return if (status == 401 or status == 403) .auth else .@"error";
    return .done;
}

/// `arx request [-X METHOD] [--data JSON|-] [--auth-source] PATH`.
fn requestCommand(a: *Agent, args: []const []const u8) !Exit {
    const gpa = a.ctx.gpa;
    var method: ?[]const u8 = null;
    var data: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var auth_source = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const has_value = i + 1 < args.len;
        if (std.mem.eql(u8, args[i], "--auth-source")) {
            auth_source = true;
        } else if (has_value and std.mem.eql(u8, args[i], "-X")) {
            i += 1;
            method = args[i];
        } else if (has_value and std.mem.eql(u8, args[i], "--data")) {
            i += 1;
            data = args[i];
        } else if (has_value and std.mem.eql(u8, args[i], "--spec")) {
            i += 1;
            a.spec_path = args[i];
        } else if (has_value and std.mem.eql(u8, args[i], "--set")) {
            i += 1;
            if (!try spec_mod.addSet(a.sets_arena.allocator(), &a.sets, args[i])) return options.usageError(a, "bad --set", args[i]);
        } else if (args[i].len > 0 and args[i][0] != '-' and path == null) {
            path = args[i];
        } else {
            return options.usageError(a, "unknown request argument", args[i]);
        }
    }
    if (try loadSpec(a)) |code| return code;
    if (auth_source) {
        const key = try a.auth.apiKey(a.ctx, a.spec.root);
        render.printOut(a.ctx.io, "{s}\n", .{if (key != null) a.auth.source orelse "" else "no key found"});
        return if (key != null) .done else .auth;
    }
    const p = path orelse return options.usageError(a, "request needs a path such as /models", null);
    const body: ?[]u8 = if (data) |d|
        if (std.mem.eql(u8, d, "-")) try options.readStdin(gpa) else try gpa.dupe(u8, d)
    else
        null;
    defer if (body) |b| gpa.free(b);
    return request(a, method, body, p);
}
