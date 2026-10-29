const std = @import("std");

/// limn's build, for an application's own: `addShaders` and `applyAndroidLibc`.
pub const limn = @import("libs/limn/build.zig");
const slime = @import("libs/slime/build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Run unit tests");
    const check_step = b.step("check", "Compile everything and its tests without running them");
    if (b.option(bool, "limn", "Build limn (default: true)") orelse true) limn.build(b, target, optimize, test_step, check_step);
    if (b.option(bool, "slime", "Build slime (default: true)") orelse true) slime.build(b, target, optimize, test_step);
}
