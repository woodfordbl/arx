//! signature.zig: the fingerprint for hot reload. It covers the spec, the
//! prompt files it names, and tools/, hooks/ and skills in every layer,
//! plus each plugin.yaml and kit.yaml, using stat() only, so arx can check it before
//! every model call.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("../base/util.zig");
const json = @import("../base/json.zig");
const Context = @import("../base/context.zig").Context;
const Spec = @import("spec.zig").Spec;

const Hasher = struct {
    ctx: *const Context,
    h: std.hash.Fnv1a_64 = .init(),

    /// Mixes a number into the hash.
    fn int(f: *Hasher, n: i64) void {
        f.h.update(std.mem.asBytes(&n));
    }

    /// Mixes a file's path, modification time and size into the hash.
    fn file(f: *Hasher, path: []const u8) void {
        f.h.update(path);
        const info = util.stat(f.ctx.io, path);
        f.int(if (info) |i| i.mtime else -1);
        f.int(if (info) |i| i.size else -1);
    }

    /// Hashes every entry of `dir` (or `dir/<entry>/<inner>` when `inner`
    /// is set), including file modes so a chmod +x counts as a change.
    fn dir(f: *Hasher, path: []const u8, inner: ?[]const u8) Allocator.Error!void {
        const gpa = f.ctx.gpa;
        var d = std.Io.Dir.cwd().openDir(f.ctx.io, path, .{ .iterate = true }) catch return;
        defer d.close(f.ctx.io);
        var it = d.iterate();
        while (it.next(f.ctx.io) catch null) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            const full = if (inner) |file_name|
                try std.mem.concat(gpa, u8, &.{ path, "/", entry.name, "/", file_name })
            else
                try std.mem.concat(gpa, u8, &.{ path, "/", entry.name });
            defer gpa.free(full);
            f.file(full);
            if (inner == null) {
                if (util.stat(f.ctx.io, full)) |info| f.int(info.mode);
            }
        }
    }

    /// Hashes the files that a text node points at.
    fn textFiles(f: *Hasher, spec: *const Spec, node: ?json.Value) Allocator.Error!void {
        const value = node orelse return;
        if (value == .array) {
            for (value.array.items) |item| try f.textFiles(spec, item);
            return;
        }
        const name = json.str(value, "file") orelse return;
        const path = try util.pathJoin(f.ctx.gpa, spec.dir, name);
        defer f.ctx.gpa.free(path);
        f.file(path);
    }
};

/// A fingerprint of every file that makes up the harness.
pub fn compute(ctx: *const Context, spec: *const Spec) Allocator.Error!u64 {
    const gpa = ctx.gpa;
    var f: Hasher = .{ .ctx = ctx };
    f.file(spec.path);
    if (spec.config) |config| f.file(config);
    try f.textFiles(spec, json.get(spec.root, "instructions"));
    try f.textFiles(spec, json.get(spec.root, "first_message"));
    try f.textFiles(spec, json.get(spec.root, "compaction.prompt"));
    for (spec.layers) |layer| {
        for ([_][]const u8{ "tools", "hooks" }) |sub| {
            const path = try util.pathJoin(gpa, layer.dir, sub);
            defer gpa.free(path);
            try f.dir(path, null);
        }
        if (layer.skills) |skills| try f.dir(skills, "SKILL.md");
    }
    // A plugin or kit that is added, removed, or changes its plugin.yaml or
    // kit.yaml.
    const config = try util.configDir(ctx, gpa);
    defer gpa.free(config);
    for ([_][]const u8{ spec.dir, config }) |parent| {
        for ([_][2][]const u8{ .{ "plugins", "plugin.yaml" }, .{ "kits", "kit.yaml" } }) |kind| {
            const path = try util.pathJoin(gpa, parent, kind[0]);
            defer gpa.free(path);
            try f.dir(path, kind[1]);
        }
    }
    return f.h.final();
}
