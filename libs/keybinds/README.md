# Keybinds

Keybindings for games, editors and tools, written in Zig. Your actions are bound to triggers of physical inputs, and each binding says how it is played and when it applies:
- **Triggers:** chords like `ctrl+s` or `lb+rb`, sequences like `ctrl+k ctrl+c`, analog axes like `pad:left_x`, and motion like `motion:x`.
- **Gestures:** press, release, hold, repeat, tap or double tap.
- **When it applies:** contexts it needs or excludes, and a priority.

Timing is exact: a hold fires at its deadline even when the release arrives later in the same frame. Nothing allocates per event once warmed up, and there is no windowing library to depend on.

Latest docs are published to https://qayasoftware.github.io/sdk/keybinds/

```zig
const keybinds = @import("keybinds");

const Action = enum { move_x, jump, interact, pause, back, save };
const Context = enum { gameplay, menu };
const Map = keybinds.Keymap(Action, Context);

var map = Map.init(gpa, .{});
defer map.deinit();
_ = try map.bind(.move_x, "d", .{});
_ = try map.bind(.move_x, "a", .{ .scale = -1 });
_ = try map.bind(.move_x, "pad:left_x", .{});
_ = try map.bind(.jump, "space", .{ .when = &.{.gameplay} });
_ = try map.bind(.interact, "e", .{ .gesture = .{ .hold = keybinds.ms(400) } });
_ = try map.bind(.save, "ctrl+s", .{});

var player = Map.Tracker.init(gpa, &map, 0);
defer player.deinit();
player.setContext(.gameplay, true);

// from your window's events, with their times in nanoseconds:
try player.press(.key(.space), time);
try player.release(.key(.space), time);
try player.axis(.left_x, 0.8, time);

// once a frame:
try player.update(now);
if (player.pressed(.jump)) jump();
velocity.x = player.value(.move_x);
handlers.dispatch(&player);
player.endFrame();
```

## Keymaps and trackers

A `Keymap(Action, Context)` holds the bindings. `Action` is your enum of actions; `Context` is your enum of contexts, or `void` for none. A keymap is only definitions. Build it once, then share it read-only with as many trackers and threads as you like.

A `Keymap.Tracker` follows one caller's inputs through a keymap: a player, a gamepad, an editor panel. Each tracker has its own held inputs, contexts, timers and events, and its `caller` number is on every event it fires. Two players on one keymap are two trackers.

Feed a tracker every input in the order it happened, with its time:
- `press` and `release` for digital inputs;
- `axis` for analog ones;
- `motion` for amounts like mouse movement;
- `wheel` for scrolling.

Then call `update(now)` to fire any holds and repeats that are due. Read the tracker and finish the frame with `endFrame`. Call `releaseAll` when the window loses focus.

| Read | |
|---|---|
| `down(action)` | held down by a binding |
| `pressed(action)`, `presses(action)` | fired this frame, and how often: taps faster than frames all count |
| `released(action)` | stopped being down this frame |
| `heldFor(action)` | how long it has been down |
| `value(action)` | held digital bindings and axes, kept within -1 and 1, plus this frame's motion |
| `eventsSinceFrame()` | every firing this frame, in order, with its exact time |

## Triggers

Inputs are named as in this table, in any case. A trigger joins them into chords with `+`, and a sequence is chords separated by spaces.

| Input | Written |
|---|---|
| keys | `a`, `5`, `f5`, `space`, `escape` (`esc`), `page_up` (`pgup`), `` ` ``, `kp_add`, `left_shift`… |
| modifier keys, either side | `shift`, `ctrl`, `alt`, `super` (`cmd`, `win`, `meta`) |
| mouse buttons | `mouse:left`, `mouse:right`, `mouse:middle`, `mouse:back`… |
| wheel steps | `wheel:up`, `wheel:down`, `wheel:left`, `wheel:right` |
| gamepad buttons | `pad:south` (`pad:a`, `pad:cross`), `pad:lb`, `pad:start`, `pad:up`… |
| gamepad axes | `pad:left_x`, `pad:rt`; one way, as a button, with hysteresis: `pad:left_x-`, `pad:rt+` |
| motion | `motion:x`, `motion:y`, `motion:wheel_y` |
| your own | `custom:7` |

- **Chords:** `ctrl+shift+s` and `lb+rb` complete when their last input is pressed with the rest held, in any order.
- **Modifier keys:** a modifier last in a chord is its key, so `shift` alone is a binding to either shift key.
- **Analog inputs in chords:** a chord can hold one axis or motion input, which then gives its value only while the rest is held. For example, `mouse:right+motion:x` looks around only while the right button is held.
- **Sequences:** `ctrl+k ctrl+c` waits up to `sequence_timeout` for its next chord, and that chord is then consumed: `ctrl+c` doesn't also copy.
- **Display names:** `Trigger.format` writes triggers as players see them (`Ctrl+Shift+S`, `Left Bumper`, `Right Trigger+`). `keymap.describe(writer, action)` writes every trigger of an action, for prompts like "Hold E / Pad West".

## Gestures

| Gesture | Fires | Down |
|---|---|---|
| `.press` | when the chord completes | until released |
| `.release` | when released | never |
| `.{ .hold = ms(500) }` | once held 500 ms | from then until released |
| `.{ .repeat = .{ .delay = ms(400), .interval = ms(50) } }` | on press, then every 50 ms after 400 ms | until released |
| `.{ .tap = ms(200) }` | on release within 200 ms | never |
| `.{ .double_tap = ms(250) }` | on the second press within 250 ms | until released |

A hold and a tap on the same key work together: "tap E to use, hold E to inspect". A double tap and a press do too: "W moves, double-tap W dashes".

## Which bindings fire

When one press completes several bindings, they fire in order:
1. Higher `priority` first.
2. Then the more specific: more modifiers and inputs, so `ctrl+s` before `s`.

Each group fires together, and a binding that `consume`s (the default) stops the groups after it.

Holding modifiers doesn't stop bindings that don't ask for them, so sprinting with shift held still lets space jump. For editors, set `exact_modifiers`, on the keymap or per binding, so that `ctrl+alt+s` is not `ctrl+s`.

Contexts are flags you set on a tracker:
- a binding fires only `when` all of its required contexts are active, and not in its `unless` contexts;
- leaving a context lets go of what it was holding, without firing.

`keymap.conflicts()` lists bindings of different actions that one press fires together, and triggers that begin with another's, for a settings menu to warn about.

## Handlers

`Keymap.Handlers` maps actions to functions. `dispatch(&tracker)` runs a tracker's events through it in order.
- **Order:** handlers of an action run by priority.
- **Stopping:** a handler that returns `true` stops the rest.
- **Shared table:** one table serves every tracker, and handlers know which tracker fired from `event.caller`.

```zig
var handlers = Map.Handlers.init(gpa);
_ = try handlers.on(.jump, .of(&game, Game.jump), .{});
_ = try handlers.on(.pause, .of(&menu, Menu.open), .{ .priority = 1 });
```

## Rebinding and saving

- **Capturing a binding:** `tracker.startCapture()` turns presses into a capture instead of firing anything, and `takeCapture()` returns the chord that was pressed. A modifier pressed and released alone is captured as its key.
- **Saving and loading:** `keymap.write(writer)` saves every binding, one per line, and `keymap.load(text, mode, diagnostics)` reads them back.
- **Partial loads:** `.replace_actions` replaces only the actions the text mentions, which suits defaults overridden by a player's choices.
- **Errors:** a bad line changes nothing, and the diagnostics give its line and column.

```
# comments start with #
jump = space
jump = pad:south
save = ctrl+s, when editor, exact
comment = ctrl+k ctrl+c
quick_save = f5, hold 500ms
zoom_in = ctrl+wheel:up, repeat 300ms 50ms, priority 1
move_x = a, scale -1
look_x = mouse:right+motion:x, scale 0.2, unless menu
```

## Connecting a window

Keybinds has no windowing code. Translate your window's events into `Input`s, for example from GLFW:

```zig
fn onKey(window: *glfw.Window, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    const which: keybinds.Input = .key(switch (key) {
        glfw.GLFW_KEY_SPACE => .space,
        glfw.GLFW_KEY_A...glfw.GLFW_KEY_Z => @enumFromInt(@intFromEnum(keybinds.Key.a) + @as(u16, @intCast(key - glfw.GLFW_KEY_A))),
        glfw.GLFW_KEY_LEFT_SHIFT => .left_shift,
        // ...
        else => return,
    });
    const time: u64 = @intFromFloat(glfw.glfwGetTime() * std.time.ns_per_s);
    switch (action) {
        glfw.GLFW_PRESS => tracker.press(which, time) catch {},
        glfw.GLFW_RELEASE => tracker.release(which, time) catch {},
        else => {},
    }
}
```

Feed the side modifier keys (`left_shift`, `right_ctrl`). The tracker works out the either-side keys and modifiers from them.

## Performance

`zig build keybinds-performance -Doptimize=fast`, on an Intel i7 12700F, with 532 bindings:

```
press + release, one binding fires             1000000     107.9 ns/op
ctrl+s among 6 bindings of s                   1000000      68.1 ns/op
press + release that fires nothing             1000000      41.0 ns/op
ctrl+k ctrl+c, all six events                   250000     287.9 ns/op
axis + motion fed, three values read           1000000      28.1 ns/op
update firing a repeat each frame              1000000       7.9 ns/op
an idle frame: update, poll, end               1000000       3.4 ns/op
load the whole keymap from text                    100  204856.2 ns/op
```

## Examples

```sh
zig build keybinds-game          # two players on one keymap: contexts, gestures, axes, handlers
zig build keybinds-editor        # exact shortcuts, sequences, user overrides, conflicts, rebinding, saving
zig build keybinds-performance -Doptimize=fast
```
