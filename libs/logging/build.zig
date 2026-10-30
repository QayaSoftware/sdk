const std = @import("std");
const Sdk = @import("../../build/Sdk.zig");

/// logging's part of the SDK's build: its examples.
pub fn build(lib: *Sdk.Library) void {
    _ = lib.addExample("basic", "Run examples/basic.zig");
    _ = lib.addExample("engine", "Run examples/engine.zig: frames, threads, a console, spam control and a log directory");
    _ = lib.addExample("performance", "Run logging benchmarks. Optional: zig build logging-performance -Doptimize=ReleaseFast -- 1000000");
}
