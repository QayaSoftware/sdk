const std = @import("std");
const Sdk = @import("../../build/Sdk.zig");

/// keybinds' part of the SDK's build: its examples.
pub fn build(lib: *Sdk.Library) void {
    _ = lib.addExample("game", "Run examples/game.zig: a scripted game session through a keymap");
    _ = lib.addExample("editor", "Run examples/editor.zig: an editor's shortcuts, user overrides and rebinding");
    _ = lib.addExample("performance", "Run keybinds benchmarks. Optional: zig build keybinds-performance -Doptimize=fast -- 1000000");
}
