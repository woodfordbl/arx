//! build.zig: builds arx with the Zig version pinned in build.zig.zon.
//!   zig build                      zig-out/bin/arx, optimized for size
//!   zig build -Doptimize=debug     a debug build with safety checks and leak checks
//!   zig build test                 the Zig unit tests
//!   zig build -Dversion=1.2.3      set the version `arx version` prints
//!
//! libyaml is the only C in the binary. It is vendored unmodified in
//! vendor/libyaml and compiled here; translate-c turns yaml.h into the
//! `yaml` module that src/harness/yaml.zig imports.

const std = @import("std");
const builtin = @import("builtin");

/// The one Zig release arx builds with. CI, the Makefile and build.zig.zon
/// all name the same version; change them together.
const pinned_zig = "0.17.0";

comptime {
    const have = builtin.zig_version;
    const want = std.SemanticVersion.parse(pinned_zig) catch unreachable;
    if (have.order(want) != .eq or have.pre != null) {
        @compileError("arx builds with Zig " ++ pinned_zig ++ " exactly; this is Zig " ++ builtin.zig_version_string);
    }
}

/// Declares the arx executable and the test step.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.lang.Optimize,
        "optimize",
        "debug, safe, fast or small (default: small)",
    ) orelse .small;
    const version = b.option([]const u8, "version", "The version `arx version` prints") orelse
        gitVersion(b);

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const yaml = yamlModule(b, target, optimize);

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // arx runs one thing at a time; children are processes, not threads.
        .single_threaded = true,
        // Nothing unwinds the stack in a release build (see `panic` in
        // src/main.zig), so leave out the tables.
        .unwind_tables = if (optimize == .debug) null else .none,
        .strip = b.option(bool, "strip", "Strip debug symbols (default: on unless debug)") orelse (optimize != .debug),
        .imports = &.{
            .{ .name = "yaml", .module = yaml },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
    addLibYaml(b, root);

    const exe = b.addExecutable(.{ .name = "arx", .root_module = root });
    b.installArtifact(exe);

    const unit_tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run the Zig unit tests").dependOn(&b.addRunArtifact(unit_tests).step);
}

/// The version from `git describe`, without a leading "v", or "dev" outside
/// a git checkout.
fn gitVersion(b: *std.Build) []const u8 {
    // The configure cache cannot see a new tag or commit, so rerun configure.
    b.graph.poisonCache();
    const out = switch (b.runFallible(
        &.{ "git", "describe", "--tags", "--always", "--dirty" },
        .{ .stderr_behavior = .ignore },
    )) {
        .success => |stdout| stdout,
        .spawn_failed, .bad_exit_code, .crashed => return "dev",
    };
    const trimmed = std.mem.trim(u8, out, " \n\r\t");
    if (trimmed.len == 0) return "dev";
    return b.allocator.dupe(u8, if (trimmed[0] == 'v') trimmed[1..] else trimmed) catch "dev";
}

/// The libyaml defines, shared by the C build and translate-c.
const yaml_macros = [_][2][]const u8{
    .{ "YAML_VERSION_MAJOR", "0" },
    .{ "YAML_VERSION_MINOR", "2" },
    .{ "YAML_VERSION_PATCH", "5" },
    .{ "YAML_VERSION_STRING", "\"0.2.5\"" },
    .{ "YAML_DECLARE_STATIC", "1" },
};

/// The `yaml` module: yaml.h through translate-c.
fn yamlModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/libyaml/include/yaml.h"),
        .target = target,
        .optimize = optimize,
    });
    for (yaml_macros) |m| translate.defineCMacro(m[0], m[1]);
    return translate.createModule();
}

/// Compiles vendor/libyaml into `module`.
fn addLibYaml(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor/libyaml/include"));
    for (yaml_macros) |m| module.addCMacro(m[0], m[1]);
    module.addCSourceFiles(.{
        .root = b.path("vendor/libyaml/src"),
        .files = &.{
            "api.c",    "dumper.c", "emitter.c", "loader.c",
            "parser.c", "reader.c", "scanner.c", "writer.c",
        },
        // gnu99, not c99: libyaml calls strdup, which strict C99 headers hide.
        .flags = &.{ "-std=gnu99", "-w" },
    });
}
