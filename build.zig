const std = @import("std");

/// The SDK's build, for an application's own: `applyAndroidLibc`.
pub const Sdk = @import("build/Sdk.zig");
/// limn's build, for an application's own: `addShaders` and `Shader`.
pub const limn = @import("libs/limn/build.zig");
/// lrhi's build, for an application's own: `addShaders` for shaders that do not
/// use limn's.
pub const lrhi = @import("libs/lrhi/build.zig");

pub fn build(b: *std.Build) void {
    const sdk = Sdk.create(b);
    sdk.add("handles", @import("libs/handles/build.zig"));
    sdk.add("assets", @import("libs/assets/build.zig"));
    sdk.add("lrhi", @import("libs/lrhi/build.zig"));
    sdk.add("lrhi-dlss", @import("libs/lrhi-dlss/build.zig"));
    sdk.add("lrhi-fsr", @import("libs/lrhi-fsr/build.zig"));
    sdk.add("lrhi-nrd", @import("libs/lrhi-nrd/build.zig"));
    sdk.add("lrhi-assets", @import("libs/lrhi-assets/build.zig"));
    sdk.add("limn", limn);
    sdk.add("slime", @import("libs/slime/build.zig"));
    sdk.add("commands", @import("libs/commands/build.zig"));
    sdk.add("cli", @import("libs/cli/build.zig"));
    sdk.add("logging", @import("libs/logging/build.zig"));
    sdk.add("keybinds", @import("libs/keybinds/build.zig"));
    sdk.add("audio", @import("libs/audio/build.zig"));
    sdk.finish();
}
