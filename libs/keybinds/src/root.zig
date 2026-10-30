//! Keybindings for games, editors and tools: actions of your own, bound to
//! triggers of physical inputs, as chords (`ctrl+s`, `lb+rb`), sequences
//! (`ctrl+k ctrl+c`), axes (`pad:left_x`) and motion (`motion:x`), each with
//! a gesture (press, release, hold, repeat, tap or double tap), contexts and
//! a priority. A `Keymap` holds the bindings; a `Keymap.Tracker` follows one
//! caller's inputs through it, with exact timing, into actions to poll and
//! events to dispatch to `Keymap.Handlers`.
const input = @import("input.zig");
pub const Input = input.Input;
pub const Key = input.Key;
pub const Mouse = input.Mouse;
pub const Wheel = input.Wheel;
pub const Button = input.Button;
pub const Axis = input.Axis;
pub const Motion = input.Motion;
pub const Mods = input.Mods;
pub const Modifier = input.Modifier;

const trigger = @import("trigger.zig");
pub const Chord = trigger.Chord;
pub const Trigger = trigger.Trigger;
pub const Gesture = trigger.Gesture;
pub const ms = trigger.ms;
pub const parseDuration = trigger.parseDuration;
pub const writeDuration = trigger.writeDuration;

const keymap = @import("keymap.zig");
pub const Keymap = keymap.Keymap;
pub const BindingId = keymap.BindingId;

test {
    _ = @import("tests.zig");
}
