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

/// `arx check --plugin DIR`: checks a plugin without loading it, and prints
/// key=value lines for scripts such as `arx plugin`.
fn checkPlugin(a: *Agent, dir: []const u8) !Exit {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a.ctx.gpa);
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(a.ctx.gpa);
    const ok = try plugins.describe(a.ctx, dir, &out, &err);
    if (ok) render.printOut(a.ctx.io, "{s}", .{out.items}) else render.printErr(a.ctx.io, "{s}", .{err.items});
    return if (ok) .done else .usage;
}

/// `arx check` and `arx tools`: load the harness without starting a session.
fn checkOrTools(a: *Agent, args: []const []const u8) !Exit {
    const is_check = std.mem.eql(u8, args[1], "check");
    if (is_check and args.len == 4 and std.mem.eql(u8, args[2], "--plugin")) return checkPlugin(a, args[3]);
    if (try options.parse(a, args, 2)) |code| return code;
    if (try loadSpec(a)) |code| return code;
    try tools.build(a);
    var arena: std.heap.ArenaAllocator = .init(a.ctx.gpa);
    defer arena.deinit();
    const t = arena.allocator();
    if (!is_check) {
        render.printOut(a.ctx.io, "{s}\n", .{try json.stringifyPretty(t, try json.parseTrusted(t, try a.tools.toJson(t)))});
        return .done;
    }
    var out: std.ArrayList(u8) = .empty;
    const config = a.spec.config orelse a.spec.path;
    const merged = !std.mem.eql(u8, config, a.spec.path);
    try out.print(t, "ok: {s}{s}{s} (model {s} at {s})\ntools:", .{
        a.spec.path,
        if (merged) " + " else "",
        if (merged) config else "",
        json.strOr(a.spec.root, "model", ""),
        json.strOr(a.spec.root, "endpoint.base_url", ""),
    });
    for (a.tools.items) |tool| try out.print(t, " {s}", .{tool.name});
    // The hooks found in the layers, naming the plugins they come from.
    try out.appendSlice(t, "\nhooks:");
    for (validate.hook_points) |point| {
        var from: std.ArrayList(u8) = .empty;
        var found = false;
        for (a.spec.layers) |layer| {
            if (!util.isExecutable(a.ctx.io, try std.mem.concat(t, u8, &.{ layer.dir, "/hooks/", point }))) continue;
            found = true;
            if (layer.plugin) |plugin| try from.print(t, "{s}{s}", .{ if (from.items.len > 0) "," else "", plugin });
        }
        if (found) try out.print(t, " {s}", .{point});
        if (from.items.len > 0) try out.print(t, "({s})", .{from.items});
    }
    try out.append(t, '\n');
    var any = false;
    for (a.spec.layers) |layer| if (layer.plugin) |plugin| {
        try out.print(t, "{s}{s}", .{ if (any) " " else "plugins: ", plugin });
        any = true;
    };
    if (any) try out.append(t, '\n');
    if (a.notes.items.len > 0) try out.print(t, "problems:\n{s}", .{a.notes.items});
    render.printOut(a.ctx.io, "{s}", .{out.items});
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
    if (args.len < 4) return options.usageError(a, "ctl needs a session and a command", null);
    const note = std.mem.eql(u8, args[3], "note");
    if (!note and !std.mem.eql(u8, args[3], "stop")) return options.usageError(a, "unknown ctl command", args[3]);
    if (note and args.len < 5) return options.usageError(a, "ctl note needs text", null);
    var arena: std.heap.ArenaAllocator = .init(a.ctx.gpa);
    defer arena.deinit();
    const t = arena.allocator();
    const dir = (try session.sessionDir(a.ctx, t, args[2])) orelse return options.usageError(a, "no such session", args[2]);
    const line = if (note)
        try t.print("{{\"cmd\":\"note\",\"text\":{f}}}\n", .{json.fmt(.{ .string = args[4] })})
    else
        "{\"cmd\":\"stop\"}\n";
    util.appendFile(try std.mem.concat(t, u8, &.{ dir, "/inbox" }), line) catch return .@"error";
    return .done;
}

/// Copies a response body to stdout.
fn toStdout(_: *u8, bytes: []const u8) Allocator.Error!void {
    sys.writeAll(1, bytes) catch {};
}

/// `arx request [-X METHOD] [--data JSON|-] [--auth-source] PATH`: one
/// authenticated call to the endpoint; prints the body.
fn requestCommand(a: *Agent, args: []const []const u8) !Exit {
    const ctx = a.ctx;
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    const t = arena.allocator();
    var method: ?[]const u8 = null;
    var data: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var auth_source = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value = if (i + 1 < args.len) args[i + 1] else null;
        if (std.mem.eql(u8, arg, "--auth-source")) {
            auth_source = true;
            continue;
        }
        if (value != null and std.mem.eql(u8, arg, "-X")) {
            method = value;
        } else if (value != null and std.mem.eql(u8, arg, "--data")) {
            data = value;
        } else if (value != null and std.mem.eql(u8, arg, "--spec")) {
            a.spec_path = value;
        } else if (value != null and std.mem.eql(u8, arg, "--set")) {
            if (!try spec_mod.addSet(a.sets_arena.allocator(), &a.sets, value.?)) return options.usageError(a, "bad --set", value);
        } else if (arg.len > 0 and arg[0] != '-' and path == null) {
            path = arg;
            continue;
        } else {
            return options.usageError(a, "unknown request argument", arg);
        }
        i += 1;
    }
    if (try loadSpec(a)) |code| return code;
    const root = a.spec.root;
    if (auth_source) {
        const key = try a.auth.apiKey(ctx, root);
        render.printOut(ctx.io, "{s}\n", .{if (key != null) a.auth.source orelse "" else "no key found"});
        return if (key != null) .done else .auth;
    }
    const url = try auth.endpointUrl(t, root, path orelse return options.usageError(a, "request needs a path such as /models", null));
    const body = if (data) |d| if (std.mem.eql(u8, d, "-")) try options.readStdin(t) else d else null;
    const tmp = std.mem.trimEnd(u8, ctx.getenvNonEmpty("TMPDIR") orelse "/tmp", "/");
    const headers = try auth.writeRequestHeaders(ctx, t, &a.auth, root, tmp, false);
    defer Io.Dir.cwd().deleteFile(ctx.io, headers) catch {};
    const response = try t.print("{s}/.arx-response-{d}", .{ tmp, sys.getpid() });
    defer Io.Dir.cwd().deleteFile(ctx.io, response) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(t, &.{ auth.curlPath(ctx, root), "-sS", "--max-time", "60", "-D", response, "-H", try t.print("@{s}", .{headers}) });
    if (method) |m| try argv.appendSlice(t, &.{ "-X", m });
    if (body != null) try argv.appendSlice(t, &.{ "--data-binary", "@-" });
    try argv.append(t, url);
    var unused: u8 = 0;
    const r = try proc.run(ctx, .{ .argv = argv.items, .stdin = body, .timeout = 90, .stdout = .init(&unused, toStdout) });
    const status = (try auth.readResponseHeaders(ctx, response)).status;
    if (r.code != 0) render.printErr(ctx.io, "arx: curl exited with {d}\n", .{r.code});
    if (r.code != 0 or status < 200 or status >= 300) return if (status == 401 or status == 403) .auth else .@"error";
    return .done;
}
