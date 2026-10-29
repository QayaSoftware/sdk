const std = @import("std");
const Sdk = @import("../../build/Sdk.zig");

/// cli's part of the SDK's build: its examples.
pub fn build(lib: *Sdk.Library) void {
    _ = lib.addExample("server", "Run examples/server.zig. Try: zig build cli-server -- --help");
    _ = lib.addExample("tool", "Run examples/tool.zig, which has subcommands. Try: zig build cli-tool -- --help");
}
