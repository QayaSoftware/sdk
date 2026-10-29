const std = @import("std");
const Sdk = @import("../../build/Sdk.zig");

/// slime's part of the SDK's build: its options and its examples.
pub fn build(lib: *Sdk.Library) void {
    const options = lib.b.addOptions();
    options.addOption(bool, "thread_safe", false);
    lib.module.addOptions("options", options);

    _ = lib.addExample("basic", "Run examples/basic.zig");
    _ = lib.addExample("prefabs", "Run examples/prefabs.zig");
    _ = lib.addExample("parallel", "Run examples/parallel.zig");
    const performance = lib.addExample("performance", "Run ECS micro-benchmarks (timer). Optional: zig build slime-performance -Doptimize=ReleaseFast -- 100000");
    performance.root_module.link_libc = true;
}
