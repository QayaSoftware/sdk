const std = @import("std");

/// The SDK's libraries, each a package of its own under libs/. Each is on
/// by default and re-exported under its name; `-D<name>=false` turns one
/// off, and then it is never fetched.
const libraries = [_][]const u8{ "limn", "slime" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Run every library's unit tests");
    const check_step = b.step("check", "Compile every library and its tests without running them");
    for (libraries) |name| {
        if (!(b.option(bool, name, b.fmt("Build {s} (default: true)", .{name})) orelse true)) continue;
        const library = b.lazyDependency(name, .{ .target = target, .optimize = optimize }) orelse continue;
        const module = library.builder.modules.get(name) orelse continue;
        b.modules.put(b.graph.arena, name, module) catch @panic("OOM");
        for ([_]*std.Build.Step{ test_step, check_step }, [_][]const u8{ "test", "check" }) |step, library_step| {
            if (library.builder.top_level_steps.get(library_step)) |top| step.dependOn(&top.step);
        }
    }
}
