//! context.zig: what every layer needs from the process: the allocator, the
//! Io implementation, the environment, and where the arx binary lives.

const std = @import("std");

/// Process-wide services, created once in main and passed down by pointer.
pub const Context = struct {
    /// The general-purpose allocator. Long-lived values are freed explicitly;
    /// short-lived work uses arenas on top of it.
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The environment. Children get a copy with their own additions.
    environ: *std.process.Environ.Map,
    /// The absolute path of the running arx binary, for subagents and
    /// external commands.
    self_path: []const u8,
    /// The version `arx version` prints.
    version: []const u8,

    /// The value of environment variable `key`, or null.
    pub fn getenv(ctx: *const Context, key: []const u8) ?[]const u8 {
        return ctx.environ.get(key);
    }

    /// The value of `key` when it is set and not empty, else null.
    pub fn getenvNonEmpty(ctx: *const Context, key: []const u8) ?[]const u8 {
        const value = ctx.environ.get(key) orelse return null;
        return if (value.len == 0) null else value;
    }
};
