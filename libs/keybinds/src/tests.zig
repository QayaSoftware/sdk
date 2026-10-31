const std = @import("std");
const keybinds = @import("root.zig");
const Input = keybinds.Input;
const ms = keybinds.ms;

const testing = std.testing;

const Action = enum { jump, sprint, crouch, save, save_as, comment, copy, quick_save, interact, inspect, dash, move_x, look_x, zoom, back, fire, click };
const Context = enum { gameplay, menu, editor, text };
const Map = keybinds.Keymap(Action, Context);
const Tracker = Map.Tracker;

fn key(which: keybinds.Key) Input {
    return .key(which);
}

/// Presses and releases `inputs` at `time`, holding the earlier ones while
/// the last is pressed.
fn chord(tracker: *Tracker, inputs: []const Input, time: u64) !void {
    for (inputs) |which| try tracker.press(which, time);
    var at = inputs.len;
    while (at > 0) {
        at -= 1;
        try tracker.release(inputs[at], time);
    }
}

fn expectEvents(tracker: *const Tracker, expected: []const struct { Action, keybinds.Gesture.Tag, u64 }) !void {
    const events = tracker.eventsSinceFrame();
    errdefer for (events) |event| std.debug.print("  {t} {t} at {d}\n", .{ event.action, event.gesture, event.time });
    try testing.expectEqual(expected.len, events.len);
    for (expected, events) |want, got| {
        try testing.expectEqual(want[0], got.action);
        try testing.expectEqual(want[1], got.gesture);
        try testing.expectEqual(want[2], got.time);
    }
}

test "a press fires its action and holds it down until released" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.jump, "space", .{});
    _ = try map.bind(.jump, "pad:a", .{});
    var tracker = Tracker.init(testing.allocator, &map, 7);
    defer tracker.deinit();

    try tracker.press(key(.space), ms(10));
    try tracker.press(key(.space), ms(20));
    try testing.expect(tracker.pressed(.jump) and tracker.down(.jump));
    try testing.expectEqual(@as(u32, 1), tracker.presses(.jump));
    try tracker.press(.button(.south), ms(30));
    try tracker.release(key(.space), ms(40));
    try testing.expect(tracker.down(.jump) and !tracker.released(.jump));
    try tracker.release(.button(.south), ms(50));
    try testing.expect(!tracker.down(.jump) and tracker.released(.jump));
    try expectEvents(&tracker, &.{ .{ .jump, .press, ms(10) }, .{ .jump, .press, ms(30) } });
    try testing.expectEqual(@as(u32, 7), tracker.eventsSinceFrame()[0].caller);

    tracker.endFrame();
    try testing.expect(!tracker.pressed(.jump) and !tracker.released(.jump));
    try chord(&tracker, &.{key(.space)}, ms(60));
    try chord(&tracker, &.{key(.space)}, ms(61));
    try testing.expectEqual(@as(u32, 2), tracker.presses(.jump));
}

test "the most specific chord a press completes wins, and modifiers held do not stop the rest" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.save, "ctrl+s", .{});
    _ = try map.bind(.save_as, "ctrl+shift+s", .{});
    _ = try map.bind(.jump, "s", .{});
    _ = try map.bind(.crouch, "space", .{});
    var tracker = Tracker.init(testing.allocator, &map, 0);
    defer tracker.deinit();

    try chord(&tracker, &.{ key(.left_ctrl), key(.s) }, 1);
    try chord(&tracker, &.{ key(.right_ctrl), key(.left_shift), key(.s) }, 2);
    try chord(&tracker, &.{key(.s)}, 3);
    try chord(&tracker, &.{ key(.left_shift), key(.space) }, 4);
    try expectEvents(&tracker, &.{ .{ .save, .press, 1 }, .{ .save_as, .press, 2 }, .{ .jump, .press, 3 }, .{ .crouch, .press, 4 } });
}

test "exact modifiers keep a chord from firing with more held" {
    var map = Map.init(testing.allocator, .{ .exact_modifiers = true });
    defer map.deinit();
    _ = try map.bind(.save, "ctrl+s", .{});
    _ = try map.bind(.jump, "space", .{ .exact = false });
    var tracker = Tracker.init(testing.allocator, &map, 0);
    defer tracker.deinit();
    try chord(&tracker, &.{ key(.ctrl), key(.alt), key(.s) }, 1);
    try chord(&tracker, &.{ key(.ctrl), key(.alt), key(.space) }, 2);
    try chord(&tracker, &.{ key(.ctrl), key(.s) }, 3);
    try expectEvents(&tracker, &.{ .{ .jump, .press, 2 }, .{ .save, .press, 3 } });
}

test "priority comes before specificity, and a binding can pass the press on" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.fire, "mouse:left", .{ .consume = false });
    _ = try map.bind(.click, "mouse:left", .{ .priority = 1, .when = &.{.menu} });
    _ = try map.bind(.inspect, "ctrl+mouse:left", .{});
    var tracker = Tracker.init(testing.allocator, &map, 0);
    defer tracker.deinit();
    try chord(&tracker, &.{.mouse(.left)}, 1);
    try chord(&tracker, &.{ key(.ctrl), .mouse(.left) }, 2);
    tracker.setContext(.menu, true);
    try chord(&tracker, &.{ key(.ctrl), .mouse(.left) }, 3);
    try expectEvents(&tracker, &.{ .{ .fire, .press, 1 }, .{ .inspect, .press, 2 }, .{ .click, .press, 3 } });
}

test "a chord of buttons completes in any order, and a modifier alone is its key" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.dash, "pad:lb+pad:rb", .{});
    _ = try map.bind(.sprint, "shift", .{});
    _ = try map.bind(.crouch, "left_ctrl", .{});
    var tracker = Tracker.init(testing.allocator, &map, 0);
    defer tracker.deinit();
    try tracker.press(.button(.right_shoulder), 1);
    try tracker.press(.button(.left_shoulder), 2);
    try tracker.press(key(.right_shift), 3);
    try testing.expect(tracker.down(.dash) and tracker.down(.sprint));
    try tracker.press(key(.left_shift), 4);
    try tracker.release(key(.right_shift), 5);
    try testing.expect(tracker.down(.sprint));
    try tracker.release(key(.left_shift), 6);
    try testing.expect(!tracker.down(.sprint));
    try tracker.release(.button(.left_shoulder), 7);
    try testing.expect(!tracker.down(.dash));
    try chord(&tracker, &.{key(.right_ctrl)}, 8);
    try chord(&tracker, &.{key(.left_ctrl)}, 9);
    try expectEvents(&tracker, &.{ .{ .dash, .press, 2 }, .{ .sprint, .press, 3 }, .{ .crouch, .press, 9 } });
}

test "holds and repeats fire at their exact deadlines, even fed late" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.quick_save, "f5", .{ .gesture = .{ .hold = ms(500) } });
    _ = try map.bind(.zoom, "equal", .{ .gesture = .{ .repeat = .{ .delay = ms(300), .interval = ms(50) } } });
    var tracker = Tracker.init(testing.allocator, &map, 0);
    defer tracker.deinit();

    try tracker.press(key(.f5), ms(1000));
    try tracker.release(key(.f5), ms(1400));
    try tracker.press(key(.f5), ms(2000));
    try testing.expect(!tracker.down(.quick_save));
    try tracker.release(key(.f5), ms(2600));
    try testing.expect(!tracker.down(.quick_save) and tracker.released(.quick_save));

    try tracker.press(key(.equal), ms(3000));
    try tracker.update(ms(3420));
    try tracker.release(key(.equal), ms(3430));
    try tracker.update(ms(5000));
    try expectEvents(&tracker, &.{
        .{ .quick_save, .hold, ms(2500) },
        .{ .zoom, .repeat, ms(3000) },
        .{ .zoom, .repeat, ms(3300) },
        .{ .zoom, .repeat, ms(3350) },
        .{ .zoom, .repeat, ms(3400) },
    });
    try testing.expectEqual(@as(u32, 3), tracker.eventsSinceFrame()[4].repeat);
}

test "taps, releases and double taps fire by timing" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.interact, "e", .{ .gesture = .{ .tap = ms(200) } });
    _ = try map.bind(.inspect, "e", .{ .gesture = .{ .hold = ms(200) }, .consume = false });
    _ = try map.bind(.back, "escape", .{ .gesture = .release });
    _ = try map.bind(.dash, "w", .{ .gesture = .{ .double_tap = ms(250) } });
    var tracker = Tracker.init(testing.allocator, &map, 0);
    defer tracker.deinit();

    try tracker.press(key(.e), ms(0));
    try tracker.release(key(.e), ms(150));
    try tracker.press(key(.e), ms(1000));
    try tracker.release(key(.e), ms(1300));
    try tracker.press(key(.escape), ms(2000));
    try tracker.release(key(.escape), ms(2100));
    try chord(&tracker, &.{key(.w)}, ms(3000));
    try chord(&tracker, &.{key(.w)}, ms(3400));
    try tracker.press(key(.w), ms(3500));
    try testing.expect(tracker.down(.dash));
    try tracker.release(key(.w), ms(3600));
    try expectEvents(&tracker, &.{
        .{ .interact, .tap, ms(150) },
        .{ .inspect, .hold, ms(1200) },
        .{ .back, .release, ms(2100) },
        .{ .dash, .double_tap, ms(3500) },
    });
}

test "sequences wait for their next chord, which they then consume" {
    var map = Map.init(testing.allocator, .{ .sequence_timeout = ms(1000) });
    defer map.deinit();
    _ = try map.bind(.comment, "ctrl+k ctrl+c", .{});
    _ = try map.bind(.copy, "ctrl+c", .{});
    _ = try map.bind(.jump, "k", .{});
    var tracker = Tracker.init(testing.allocator, &map, 0);
    defer tracker.deinit();

    try tracker.press(key(.left_ctrl), ms(0));
    try chord(&tracker, &.{key(.k)}, ms(10));
    try chord(&tracker, &.{key(.c)}, ms(20));
    try chord(&tracker, &.{key(.c)}, ms(30));
    try tracker.release(key(.left_ctrl), ms(40));
    try expectEvents(&tracker, &.{ .{ .comment, .press, ms(20) }, .{ .copy, .press, ms(30) } });
    tracker.endFrame();

    try chord(&tracker, &.{ key(.left_ctrl), key(.k) }, ms(100));
    try chord(&tracker, &.{ key(.left_ctrl), key(.c) }, ms(1200));
    try chord(&tracker, &.{ key(.left_ctrl), key(.k) }, ms(2000));
    try tracker.press(key(.right_shift), ms(2010));
    try tracker.release(key(.right_shift), ms(2020));
    try chord(&tracker, &.{ key(.left_ctrl), key(.c) }, ms(2030));
    try chord(&tracker, &.{ key(.left_ctrl), key(.k) }, ms(3000));
    try chord(&tracker, &.{key(.k)}, ms(3010));
    try expectEvents(&tracker, &.{ .{ .copy, .press, ms(1200) }, .{ .comment, .press, ms(2030) }, .{ .jump, .press, ms(3010) } });
}

test "contexts decide what fires, and leaving one lets go without firing" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.sprint, "shift", .{ .when = &.{.gameplay} });
    _ = try map.bind(.back, "escape", .{ .when = &.{.menu}, .gesture = .release });
    _ = try map.bind(.jump, "space", .{ .unless = &.{ .menu, .text } });
    var tracker = Tracker.init(testing.allocator, &map, 0);
    defer tracker.deinit();

    try chord(&tracker, &.{key(.left_shift)}, 1);
    tracker.setContext(.gameplay, true);
    try tracker.press(key(.left_shift), 2);
    try tracker.press(key(.escape), 3);
    try testing.expect(tracker.down(.sprint));
    tracker.setContexts(.initMany(&.{.menu}));
    try testing.expect(!tracker.down(.sprint) and tracker.released(.sprint));
    try tracker.release(key(.escape), 4);
    try chord(&tracker, &.{key(.space)}, 5);
    try chord(&tracker, &.{key(.escape)}, 6);
    tracker.setContexts(.empty);
    try chord(&tracker, &.{key(.space)}, 7);
    try expectEvents(&tracker, &.{ .{ .sprint, .press, 2 }, .{ .back, .release, 6 }, .{ .jump, .press, 7 } });
}

test "axes, halves of axes and motion give values" {
    var map = Map.init(testing.allocator, .{ .deadzone = 0.2, .axis_press = 0.5, .axis_release = 0.3 });
    defer map.deinit();
    _ = try map.bind(.move_x, "d", .{});
    _ = try map.bind(.move_x, "a", .{ .scale = -1 });
    _ = try map.bind(.move_x, "pad:left_x", .{});
    _ = try map.bind(.dash, "pad:rt+", .{});
    _ = try map.bind(.back, "pad:left_x-", .{});
    _ = try map.bind(.look_x, "mouse:right+motion:x", .{ .scale = 0.5 });
    _ = try map.bind(.zoom, "motion:wheel_y", .{});
    try testing.expectError(error.InvalidGesture, map.bind(.jump, "pad:left_x", .{ .gesture = .release }));
    var tracker = Tracker.init(testing.allocator, &map, 0);
    defer tracker.deinit();

    try tracker.press(key(.d), 1);
    try testing.expectEqual(@as(f32, 1), tracker.value(.move_x));
    try tracker.press(key(.a), 2);
    try testing.expectEqual(@as(f32, 0), tracker.value(.move_x));
    try tracker.release(key(.a), 3);
    try tracker.release(key(.d), 3);
    try tracker.axis(.left_x, 0.1, 4);
    try testing.expectEqual(@as(f32, 0), tracker.value(.move_x));
    try tracker.axis(.left_x, 0.6, 5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), tracker.value(.move_x), 1e-6);
    try tracker.press(key(.d), 6);
    try testing.expectEqual(@as(f32, 1), tracker.value(.move_x));
    try tracker.release(key(.d), 6);

    try tracker.axis(.right_trigger, 0.55, 7);
    try tracker.axis(.right_trigger, 0.4, 8);
    try testing.expect(tracker.down(.dash));
    try tracker.axis(.right_trigger, 0.25, 9);
    try testing.expect(!tracker.down(.dash));
    try tracker.axis(.left_x, -0.9, 10);
    try testing.expect(tracker.pressed(.back));
    try testing.expectApproxEqAbs(@as(f32, -0.875), tracker.value(.move_x), 1e-6);

    try tracker.motion(.x, 10);
    try testing.expectEqual(@as(f32, 0), tracker.value(.look_x));
    try tracker.press(.mouse(.right), 11);
    try tracker.motion(.x, 6);
    try testing.expectEqual(@as(f32, 8), tracker.value(.look_x));
    try tracker.wheel(0, -2, 12);
    try testing.expectEqual(@as(f32, -2), tracker.value(.zoom));
    tracker.endFrame();
    try testing.expectEqual(@as(f32, 0), tracker.value(.look_x));
    try testing.expectEqual(@as(f32, 0), tracker.value(.zoom));
}

test "the wheel steps as a button" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.zoom, "ctrl+wheel:up", .{});
    var tracker = Tracker.init(testing.allocator, &map, 0);
    defer tracker.deinit();
    try tracker.press(key(.ctrl), 1);
    try tracker.wheel(0, 1, 2);
    try tracker.wheel(0, 3, 3);
    try tracker.wheel(0, -1, 4);
    try testing.expectEqual(@as(u32, 2), tracker.presses(.zoom));
    try testing.expect(!tracker.down(.zoom));
}

const Game = struct {
    jumps: u32 = 0,
    seen: u32 = 0,

    fn jump(game: *Game, event: Map.Event) bool {
        game.jumps += 1;
        return event.caller == 1;
    }

    fn watch(game: *Game, _: Map.Event) void {
        game.seen += 1;
    }
};

test "handlers run for each event, by priority, until one handles it" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.jump, "space", .{});
    var game: Game = .{};
    var handlers = Map.Handlers.init(testing.allocator);
    defer handlers.deinit();
    _ = try handlers.on(.jump, .of(&game, Game.watch), .{});
    const first = try handlers.on(.jump, .of(&game, Game.jump), .{ .priority = 1 });

    var one = Tracker.init(testing.allocator, &map, 1);
    defer one.deinit();
    var two = Tracker.init(testing.allocator, &map, 2);
    defer two.deinit();
    try chord(&one, &.{key(.space)}, 1);
    try chord(&two, &.{key(.space)}, 1);
    try chord(&two, &.{key(.space)}, 2);
    handlers.dispatch(&one);
    handlers.dispatch(&two);
    handlers.dispatch(&two);
    try testing.expectEqual(@as(u32, 3), game.jumps);
    try testing.expectEqual(@as(u32, 2), game.seen);
    handlers.off(first);
    try chord(&one, &.{key(.space)}, 3);
    handlers.dispatch(&one);
    try testing.expectEqual(@as(u32, 3), game.jumps);
    try testing.expectEqual(@as(u32, 3), game.seen);
}

test "capturing takes the next chord, or a modifier pressed alone" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.jump, "space", .{});
    var tracker = Tracker.init(testing.allocator, &map, 0);
    defer tracker.deinit();

    tracker.startCapture();
    try tracker.press(key(.left_ctrl), 1);
    try tracker.press(key(.left_shift), 2);
    try testing.expectEqual(@as(?keybinds.Chord, null), tracker.takeCapture());
    try tracker.press(key(.space), 3);
    const captured = tracker.takeCapture().?;
    try tracker.releaseAll(4);
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+Shift+Space", try std.fmt.bufPrint(&buffer, "{f}", .{captured}));
    try testing.expectEqual(@as(usize, 0), tracker.eventsSinceFrame().len);

    tracker.startCapture();
    try chord(&tracker, &.{key(.right_alt)}, 5);
    var writer: std.Io.Writer = .fixed(&buffer);
    try tracker.takeCapture().?.writeText(&writer);
    try testing.expectEqualStrings("alt", writer.buffered());
    try chord(&tracker, &.{key(.space)}, 6);
    try testing.expect(tracker.pressed(.jump));
}

test "releasing everything lets every action go" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.sprint, "shift+w", .{});
    _ = try map.bind(.crouch, "ctrl", .{});
    var tracker = Tracker.init(testing.allocator, &map, 0);
    defer tracker.deinit();
    try tracker.press(key(.left_shift), 1);
    try tracker.press(key(.w), 2);
    try tracker.press(key(.right_ctrl), 3);
    try testing.expect(tracker.down(.sprint) and tracker.down(.crouch));
    try tracker.release(key(.left_shift), 4);
    try testing.expect(!tracker.down(.sprint));
    try tracker.releaseAll(5);
    try testing.expect(!tracker.down(.crouch) and !tracker.isHeld(key(.ctrl)) and !tracker.isHeld(key(.w)));
}

test "triggers read names in any case, with aliases" {
    var buffer: [64]u8 = undefined;
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "Ctrl+Shift+S", "ctrl+shift+s", "Ctrl+Shift+S" },
        .{ "cmd+esc", "super+escape", "Super+Esc" },
        .{ "ctrl+k ctrl+c", "ctrl+k ctrl+c", "Ctrl+K Ctrl+C" },
        .{ "pad:LB+pad:rb", "pad:left_shoulder+pad:right_shoulder", "Left Bumper+Right Bumper" },
        .{ "pad:rt+", "pad:right_trigger+", "Right Trigger+" },
        .{ "pad:lx-+pad:a", "pad:left_x-+pad:south", "Left Stick X-+Pad South" },
        .{ "mouse:right+motion:x", "mouse:right+motion:x", "Right Click+Mouse X" },
        .{ "alt+`", "alt+grave", "Alt+`" },
        .{ "shift", "shift", "Shift" },
        .{ "ctrl+shift", "ctrl+shift", "Ctrl+Shift" },
        .{ "custom:12", "custom:12", "Input 12" },
    };
    for (cases) |case| {
        const trigger = try keybinds.Trigger.parse(case[0]);
        var writer: std.Io.Writer = .fixed(&buffer);
        try trigger.writeText(&writer);
        try testing.expectEqualStrings(case[1], writer.buffered());
        try testing.expectEqualStrings(case[2], try std.fmt.bufPrint(&buffer, "{f}", .{trigger}));
    }
    try testing.expectError(error.UnknownInput, keybinds.Trigger.parse("ctrl+nope"));
    try testing.expectError(error.EmptyTrigger, keybinds.Trigger.parse("  "));
    try testing.expectError(error.RepeatedInput, keybinds.Trigger.parse("a+a"));
    try testing.expectError(error.MisplacedAnalog, keybinds.Trigger.parse("pad:left_x+pad:right_x"));
    try testing.expectError(error.MisplacedAnalog, keybinds.Trigger.parse("ctrl+k motion:x"));
    try testing.expectError(error.TooManyChords, keybinds.Trigger.parse("a b c d e"));
}

test "bindings load from text and write back as they were" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.jump, "space", .{});
    _ = try map.bind(.copy, "ctrl+c", .{});
    const text =
        \\# player's choices
        \\jump = pad:south
        \\jump = w, double 250ms
        \\save = ctrl+s, when editor, exact
        \\comment = ctrl+k ctrl+c
        \\quick-save = f5, hold 1s, priority 2
        \\zoom = ctrl+wheel:up, repeat 300ms 50ms, pass
        \\move_x = a, scale -1, unless menu text
        \\look_x = mouse:right+motion:x, scale 0.25
        \\
    ;
    try map.load(text, .replace_actions, null);
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try map.write(&writer);
    try testing.expectEqualStrings(
        \\jump = pad:south
        \\jump = w, double 250ms
        \\save = ctrl+s, when editor, exact
        \\comment = ctrl+k ctrl+c
        \\copy = ctrl+c
        \\quick_save = f5, hold 1s, priority 2
        \\move_x = a, scale -1, unless menu text
        \\look_x = mouse:right+motion:x, scale 0.25
        \\zoom = ctrl+wheel:up, repeat 300ms 50ms, pass
        \\
    , writer.buffered());

    var again = Map.init(testing.allocator, .{});
    defer again.deinit();
    try again.load(writer.buffered(), .replace_all, null);
    writer = .fixed(buffer[512..]);
    try again.write(&writer);
    try testing.expectEqualStrings(buffer[0..writer.buffered().len], writer.buffered());

    var diagnostics: Map.Diagnostics = .{};
    const cases = [_]struct { []const u8, Map.LoadError, usize, usize }{
        .{ "jump space", error.ExpectedEquals, 1, 1 },
        .{ "\nfly = space", error.UnknownAction, 2, 1 },
        .{ "jump = ctrl+nope", error.UnknownInput, 1, 8 },
        .{ "jump = space, hold", error.InvalidOption, 1, 15 },
        .{ "jump = space, when menu nowhere", error.UnknownContext, 1, 25 },
        .{ "jump = pad:left_x, tap 100ms", error.InvalidGesture, 1, 8 },
        .{ "jump = space, fast", error.InvalidOption, 1, 15 },
    };
    for (cases) |case| {
        try testing.expectError(case[1], map.load(case[0], .add, &diagnostics));
        try testing.expectEqual(case[2], diagnostics.line);
        try testing.expectEqual(case[3], diagnostics.column);
    }
    try testing.expectEqual(@as(usize, 2), map.bindingsOf(.jump).len);
}

test "conflicts are bindings of different actions one press fires together" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    const copy = try map.bind(.copy, "ctrl+c", .{});
    _ = try map.bind(.save, "ctrl+c", .{ .when = &.{.editor} });
    _ = try map.bind(.back, "ctrl+c", .{ .unless = &.{.editor} });
    const comment = try map.bind(.comment, "ctrl+c ctrl+k", .{});
    _ = try map.bind(.copy, "ctrl+insert", .{});
    _ = try map.bind(.fire, "ctrl+c", .{ .consume = false });
    const found = try map.conflicts(testing.allocator);
    defer testing.allocator.free(found);
    try testing.expectEqual(@as(usize, 5), found.len);
    try testing.expectEqual(copy, found[2].first);
    try testing.expectEqual(comment, found[2].second);
    try testing.expect(found[2].prefix);
}

test "describe writes an action's triggers as players see them" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.save, "ctrl+s", .{});
    const pad = try map.bind(.save, "pad:start+pad:a", .{});
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try map.describe(&writer, .save);
    try testing.expectEqualStrings("Ctrl+S / Pad Start+Pad South", writer.buffered());
    try map.unbind(pad);
    writer = .fixed(&buffer);
    try map.describe(&writer, .save);
    try testing.expectEqualStrings("Ctrl+S", writer.buffered());
}

test "a tracker starts over when its keymap changes" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.sprint, "shift", .{});
    var tracker = Tracker.init(testing.allocator, &map, 0);
    defer tracker.deinit();
    try tracker.press(key(.left_shift), 1);
    try testing.expect(tracker.down(.sprint));
    try map.unbindAction(.sprint);
    _ = try map.bind(.crouch, "c", .{});
    try tracker.update(2);
    try testing.expect(!tracker.down(.sprint) and tracker.released(.sprint));
    try chord(&tracker, &.{key(.c)}, 3);
    try testing.expect(tracker.pressed(.crouch));
    try testing.expectEqual(@as(usize, 1), map.bindingsOf(.crouch).len);
}

test "trackers share a keymap across threads" {
    var map = Map.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.jump, "space", .{});
    _ = try map.bind(.zoom, "equal", .{ .gesture = .{ .repeat = .{ .delay = 100, .interval = 10 } } });
    const Player = struct {
        fn run(keymap: *const Map, presses: *std.atomic.Value(u32)) void {
            var tracker = Tracker.init(testing.allocator, keymap, 0);
            defer tracker.deinit();
            var time: u64 = 0;
            for (0..1000) |_| {
                chord(&tracker, &.{key(.space)}, time) catch unreachable;
                tracker.press(key(.equal), time) catch unreachable;
                tracker.release(key(.equal), time + 125) catch unreachable;
                time += 1000;
                _ = presses.fetchAdd(tracker.presses(.jump) + tracker.presses(.zoom), .monotonic);
                tracker.endFrame();
            }
        }
    };
    var presses: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    for (0..8) |_| group.concurrent(testing.io, Player.run, .{ &map, &presses }) catch Player.run(&map, &presses);
    try group.await(testing.io);
    try testing.expectEqual(@as(u32, 8 * 1000 * 5), presses.load(.monotonic));
}

test "a keymap needs no contexts" {
    const Simple = keybinds.Keymap(enum { quit }, void);
    var map = Simple.init(testing.allocator, .{});
    defer map.deinit();
    _ = try map.bind(.quit, "ctrl+q", .{});
    var tracker = Simple.Tracker.init(testing.allocator, &map, 0);
    defer tracker.deinit();
    try tracker.press(key(.ctrl), 0);
    try tracker.press(key(.q), 1);
    try testing.expect(tracker.pressed(.quit));
}
