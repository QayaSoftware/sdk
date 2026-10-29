const std = @import("std");
const Sdk = @import("../../build/Sdk.zig");

/// commands' part of the SDK's build: its examples.
pub fn build(lib: *Sdk.Library) void {
    _ = lib.addExample("basic", "Run examples/basic.zig");
    _ = lib.addExample("parallel", "Run examples/parallel.zig");
    _ = lib.addExample("performance", "Run parser benchmarks. Optional: zig build commands-performance -Doptimize=ReleaseFast -- 1000000");
}
