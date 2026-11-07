//! agent.zig: one running agent: its command-line options, the loaded
//! harness (spec and tools), its session and message history; plus caps,
//! harness notes, and the system prompt with its {{templates}} (including
//! the harness description that tells the agent how to extend itself).

const std = @import("std");
const Allocator = std.mem.Allocator;

const sys = @import("../base/sys.zig");
const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const Context = @import("../base/context.zig").Context;
const History = @import("../io/history.zig").History;
const Message = @import("../io/history.zig").Message;
const Session = @import("../io/session.zig").Session;
const Events = @import("../io/events.zig").Events;
const Auth = @import("../model/auth.zig").Auth;
const spec_mod = @import("../harness/spec.zig");
const Spec = spec_mod.Spec;
const tools = @import("../harness/tools.zig");
const Scheduler = @import("scheduler.zig").Scheduler;

/// Used when the spec has no instructions.
const default_instructions =
    "You are an autonomous agent working in {{cwd}}. Use the tools to act, " ++
    "check the results, and keep going until the task is done. A reply " ++
    "without a tool call ends the task, so never say you will do something " ++
    "later: do it now. When everything is done, reply with a short summary " ++
    "and no tool calls.\n\n{{harness}}";

/// Hard ceilings from --cap. The spec cannot raise them; a negative value
/// means no cap.
pub const Caps = struct {
    /// Model calls in this session.
    turns: i64 = -1,
    /// Input + output tokens in this session.
    tokens: f64 = -1,
    /// Cost in this session.
    usd: f64 = -1,
    /// Seconds since this process started.
    wall: f64 = -1,
    /// Deepest subagent level allowed.
    depth: i64 = 4,

    /// Parses one --cap argument ("turns=50", "usd=2", "wall=8h",
    /// "depth=2"). Returns false when the key or value is not valid.
    pub fn parse(c: *Caps, key_value: []const u8) bool {
        const eq = std.mem.findScalar(u8, key_value, '=') orelse return false;
        const key = key_value[0..eq];
        const value = key_value[eq + 1 ..];
        if (std.mem.eql(u8, key, "wall")) {
            c.wall = util.parseDuration(value) orelse return false;
            return true;
        }
        const n = util.leadingNumber(value) orelse return false;
        if (n.rest.len != 0 or n.value < 0 or !std.math.isFinite(n.value)) return false;
        if (std.mem.eql(u8, key, "turns")) {
            c.turns = @intFromFloat(@min(n.value, 9e18));
        } else if (std.mem.eql(u8, key, "tokens")) {
            c.tokens = n.value;
        } else if (std.mem.eql(u8, key, "usd")) {
            c.usd = n.value;
        } else if (std.mem.eql(u8, key, "depth")) {
            c.depth = @intFromFloat(@min(n.value, 9e18));
        } else {
            return false;
        }
        return true;
    }
};

/// A running agent. It must not move once `init` returns: its event stream
/// and option values point into it.
pub const Agent = struct {
    ctx: *const Context,

    // Options from the command line.
    spec_path: ?[]const u8 = null,
    /// The task (-p or stdin), or null.
    prompt: ?[]const u8 = null,
    /// The session to resume, or null.
    resume_ref: ?[]const u8 = null,
    /// The --events target, or null.
    events_target: ?[]const u8 = null,
    /// --set overrides, applied on every (re)load. They live in `sets_arena`.
    sets: json.Value = json.object(),
    sets_arena: std.heap.ArenaAllocator,
    caps: Caps = .{},
    /// The raw --cap arguments, passed on to subagents.
    cap_args: std.ArrayList([]const u8) = .empty,
    /// Print the result as JSON on stdout.
    json_output: bool = false,
    /// No terminal view.
    quiet: bool = false,
    /// Read messages from the terminal.
    interactive: bool = false,

    // State.
    spec: Spec = .{},
    tools: tools.ToolSet = .{},
    schemas: tools.SchemaCache = .{},
    session: ?Session = null,
    /// The conversation, in OpenAI chat format.
    messages: History,
    /// Harness notes for the agent's next turn.
    notes: std.ArrayList(u8) = .empty,
    /// The last tool-problem notes, so they are not repeated.
    notes_sig: u64 = 0,
    /// 0 at the top, 1 for a subagent, ...
    depth: i64 = 0,
    /// util.now() when the process started.
    start: f64 = 0,
    /// History.estimateTokens() at the last model call.
    estimate_at_call: i64 = 0,
    /// The prompt_tokens the provider reported for it.
    tokens_at_call: i64 = 0,
    /// The last answer without tool calls.
    final_output: ?[]u8 = null,
    /// `arx ctl stop` arrived.
    stop_requested: bool = false,
    events: Events,
    auth: Auth,
    /// The scheduler plugin of the session, when a layer has one.
    sched: Scheduler = .{},

    /// An agent with no spec, session or history yet.
    pub fn init(ctx: *const Context) Agent {
        return .{
            .ctx = ctx,
            .sets_arena = .init(ctx.gpa),
            .messages = .init(ctx.gpa),
            .events = .init(ctx),
            .auth = .init(ctx.gpa),
        };
    }

    /// Frees everything the agent holds.
    pub fn deinit(a: *Agent) void {
        const gpa = a.ctx.gpa;
        a.sched.deinit(gpa);
        a.tools.deinit(gpa);
        a.schemas.deinit(gpa);
        a.spec.deinit(gpa);
        if (a.session) |*s| s.close();
        a.messages.deinit();
        a.notes.deinit(gpa);
        if (a.final_output) |f| gpa.free(f);
        a.auth.deinit();
        a.cap_args.deinit(gpa);
        a.sets_arena.deinit();
    }

    /// The session id, or "" before a session is open.
    pub fn sessionId(a: *const Agent) []const u8 {
        return if (a.session) |s| s.id else "";
    }

    /// Model calls so far in this session.
    pub fn turns(a: *const Agent) i64 {
        return if (a.session) |s| s.turns else 0;
    }

    /// Queues a "[harness]" note that the agent sees before its next model
    /// call.
    pub fn note(a: *Agent, comptime format: []const u8, args: anytype) Allocator.Error!void {
        try a.notes.print(a.ctx.gpa, format, args);
        if (a.notes.items.len > 0 and a.notes.items[a.notes.items.len - 1] != '\n') try a.notes.append(a.ctx.gpa, '\n');
    }

    /// Appends a {"role", "content"} message to the history and transcript.
    pub fn addMessage(a: *Agent, role: []const u8, content: []const u8) Allocator.Error!void {
        const m = try Message.text(a.ctx.gpa, role, content);
        try a.messages.append(m);
        try a.record(m);
    }

    /// Writes a message that is already in the history to the transcript.
    pub fn record(a: *Agent, m: *const Message) Allocator.Error!void {
        if (a.session) |*s| try s.append(a.ctx.gpa, m.value);
    }

    /// Records that the history was replaced (compaction, a new system
    /// prompt).
    pub fn recordReset(a: *Agent) Allocator.Error!void {
        if (a.session) |*s| try s.reset(a.ctx.gpa, &a.messages);
    }
};

/// Reads `name` and `description` from SKILL.md front matter.
fn frontMatter(text: []const u8, name: *[]const u8, desc: *[]const u8) void {
    if (!std.mem.startsWith(u8, text, "---\n")) return;
    var lines = std.mem.splitScalar(u8, text[4..], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "---")) break;
        if (std.mem.startsWith(u8, line, "name:")) name.* = std.mem.trimStart(u8, line[5..], " ");
        if (std.mem.startsWith(u8, line, "description:")) desc.* = std.mem.trimStart(u8, line[12..], " ");
    }
}

/// Lists skills as "- name: description (path)", one per line, from every
/// layer; the first folder with a name wins.
fn skillsIndex(a: *Agent, t: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
    const before = out.items.len;
    var seen: std.ArrayList([]const u8) = .empty;
    for (a.spec.layers) |layer| {
        const dir = layer.skills orelse continue;
        names: for (try util.listNames(a.ctx.io, t, dir)) |folder| {
            for (seen.items) |s| if (std.mem.eql(u8, s, folder)) continue :names;
            const path = try std.mem.concat(t, u8, &.{ dir, "/", folder, "/SKILL.md" });
            const text = (try util.readFile(a.ctx.io, t, path)) orelse continue;
            var name: []const u8 = folder;
            var desc: []const u8 = "";
            frontMatter(text, &name, &desc);
            try out.print(t, "- {s}: {s} ({s})\n", .{ name, desc, path });
            try seen.append(t, folder);
        }
    }
    if (out.items.len == before) try out.appendSlice(t, "(no skills yet)");
}

/// Tells the agent where its harness lives and how to change it.
fn harnessText(a: *Agent, t: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
    const skills = json.str(a.spec.root, "skills");
    try out.print(t, "Your harness is yours to change; edits take effect on your next turn:\n" ++
        "- Spec: {s} (YAML: model settings, tools, hooks, compaction, limits). Check edits with `{s} check --spec {s}`.\n" ++
        "- Tools: {s}/tools/<name>, any executable (chmod +x). `<name> --schema` prints {{\"description\": ..., \"parameters\": <JSON Schema>}}; " ++
        "a call gets its arguments as JSON on stdin; stdout and stderr are the result; a non-zero exit marks an error.\n" ++
        "- Hooks: {s}/hooks/<point> for session_start, before_model, after_model, before_tool, after_tool and stop: JSON on stdin; print the fields to change, or a decision, as JSON on stdout.\n" ++
        "- Skills: {s}{s}<name>/SKILL.md with name and description front matter.\n" ++
        "- Session files (full tool outputs, transcript): {s}", .{
        a.spec.path,
        a.ctx.self_path,
        a.spec.path,
        a.spec.dir,
        a.spec.dir,
        skills orelse "(set `skills:` in the spec) ",
        if (skills != null) "/" else "",
        if (a.session) |s| s.dir else "(none)",
    });
    var plugins: std.ArrayList(u8) = .empty;
    for (a.spec.layers) |layer| if (layer.plugin) |plugin| {
        try plugins.print(t, "{s}{s} ({s})", .{ if (plugins.items.len > 0) ", " else "", plugin, layer.dir });
    };
    if (plugins.items.len == 0) return;
    try out.print(t, "\n- Plugins add tools, hooks and skills below yours: {s}. A tool of yours with the same name wins; hooks all run by band (policy, normal, final) and then in this order, yours first.", .{plugins.items});
    if (a.spec.kit) |kit| try out.print(t, " The kit {s} ({s}) chose them.", .{ kit, a.spec.kit_dir });
}

/// {{file:PATH}}, {{file:PATH:tail=N}} or {{file:PATH:max=SIZE}}.
fn fileVar(a: *Agent, t: Allocator, spec: []const u8, out: *std.ArrayList(u8)) Allocator.Error!void {
    const colon = std.mem.findScalar(u8, spec, ':') orelse spec.len;
    const path = spec[0..colon];
    const option = if (colon < spec.len) spec[colon + 1 ..] else "";
    const text = (try util.readFile(a.ctx.io, t, path)) orelse return out.print(t, "(missing: {s})", .{path});
    var start: usize = 0;
    if (std.mem.startsWith(u8, option, "tail=")) {
        var lines: i64 = if (util.leadingNumber(option[5..])) |n| @intFromFloat(@max(@min(n.value, 1e9), -1e9)) else 0;
        start = text.len - @intFromBool(text.len > 0 and text[text.len - 1] == '\n');
        while (start > 0 and lines > 0) {
            start -= 1;
            if (text[start] == '\n') lines -= 1;
        }
        if (lines == 0) start = @min(start + 1, text.len);
    }
    const clean = try util.utf8Clean(t, text[start..]);
    const max = if (std.mem.startsWith(u8, option, "max=")) util.parseSize(option[4..]) orelse 0 else 0;
    try out.appendSlice(t, if (max > 0) try util.truncate(t, clean, @intCast(max)) else clean);
}

/// Appends the value of one {{name}}.
fn appendVar(a: *Agent, t: Allocator, name: []const u8, out: *std.ArrayList(u8)) Allocator.Error!void {
    if (std.mem.eql(u8, name, "prompt")) {
        try out.appendSlice(t, a.prompt orelse "");
    } else if (std.mem.eql(u8, name, "harness")) {
        try harnessText(a, t, out);
    } else if (std.mem.eql(u8, name, "skills")) {
        try skillsIndex(a, t, out);
    } else if (std.mem.eql(u8, name, "date")) {
        const now = sys.localTime(@divFloor(util.unixMillis(a.ctx.io), 1000));
        try out.print(t, "{d:0>4}-{d:0>2}-{d:0>2}", .{ now.year, now.month, now.day });
    } else if (std.mem.eql(u8, name, "cwd")) {
        try out.appendSlice(t, std.process.currentPathAlloc(a.ctx.io, t) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => ".",
        });
    } else if (std.mem.eql(u8, name, "session")) {
        try out.appendSlice(t, a.sessionId());
    } else if (std.mem.eql(u8, name, "turn")) {
        try out.print(t, "{d}", .{a.turns()});
    } else if (std.mem.startsWith(u8, name, "file:")) {
        try fileVar(a, t, name[5..], out);
    } else {
        try out.print(t, "{{{{{s}}}}}", .{name});
    }
}

/// Expands {{vars}} in `template`: prompt, harness, skills, date, cwd,
/// session, turn, and file:PATH[:tail=N|:max=SIZE]. Caller owns the result.
pub fn renderTemplate(a: *Agent, template: []const u8) Allocator.Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(a.ctx.gpa);
    defer arena.deinit();
    const t = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (std.mem.findPos(u8, template, pos, "{{")) |open| {
        const close = std.mem.findPos(u8, template, open + 2, "}}") orelse break;
        try out.appendSlice(t, template[pos..open]);
        try appendVar(a, t, std.mem.trim(u8, template[open + 2 .. close], " "), &out);
        pos = close + 2;
    }
    try out.appendSlice(t, template[pos..]);
    return a.ctx.gpa.dupe(u8, out.items);
}

/// The system prompt: the spec's instructions (or a default), rendered.
/// Caller owns the result.
pub fn systemPrompt(a: *Agent) Allocator.Error![]u8 {
    const gpa = a.ctx.gpa;
    const text = try spec_mod.text(a.ctx, gpa, a.spec.doc(), json.get(a.spec.root, "instructions"), null);
    defer if (text) |t| gpa.free(t);
    return renderTemplate(a, text orelse default_instructions);
}

/// The first user message for `prompt`: the spec's first_message template
/// with {{prompt}} filled in, or `prompt` itself. Caller owns the result.
pub fn firstMessage(a: *Agent, prompt: []const u8) Allocator.Error![]u8 {
    const gpa = a.ctx.gpa;
    const template = (try spec_mod.text(a.ctx, gpa, a.spec.doc(), json.get(a.spec.root, "first_message"), null)) orelse
        return gpa.dupe(u8, prompt);
    defer gpa.free(template);
    const saved = a.prompt;
    defer a.prompt = saved;
    a.prompt = prompt;
    return renderTemplate(a, template);
}

test "caps" {
    var c: Caps = .{};
    try std.testing.expect(c.parse("turns=50"));
    try std.testing.expect(c.parse("wall=8h"));
    try std.testing.expect(c.parse("usd=2.5"));
    try std.testing.expect(!c.parse("usd=-1"));
    try std.testing.expect(!c.parse("nope=1"));
    try std.testing.expect(!c.parse("turns=5x"));
    try std.testing.expectEqual(@as(i64, 50), c.turns);
    try std.testing.expectEqual(@as(f64, 28800), c.wall);
}
