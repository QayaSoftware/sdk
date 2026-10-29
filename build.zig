const std = @import("std");

/// The SDK's build, for an application's own: `applyAndroidLibc`.
pub const Sdk = @import("build/Sdk.zig");
/// limn's build, for an application's own: `addShaders` and `Shader`.
pub const limn = @import("libs/limn/build.zig");

pub fn build(b: *std.Build) void {
    const sdk = Sdk.create(b);
    sdk.add("limn", limn);
    sdk.add("slime", @import("libs/slime/build.zig"));
    sdk.finish();
}
