const std = @import("std");
const keybinds = @import("keybinds");

const Action = enum { save, save_as, undo, redo, copy, paste, find, palette, comment, uncomment, zoom_in, zoom_out };
const Context = enum { text, viewport };
const Map = keybinds.Keymap(Action, Context);

const defaults =
    \\save = ctrl+s
    \\save_as = ctrl+shift+s
    \\undo = ctrl+z
    \\redo = ctrl+shift+z
    \\redo = ctrl+y
    \\copy = ctrl+c
    \\paste = ctrl+v
    \\find = ctrl+f
    \\palette = ctrl+shift+p
    \\comment = ctrl+k ctrl+c, when text
    \\uncomment = ctrl+k ctrl+u, when text
    \\zoom_in = ctrl+equal, repeat 400ms 60ms
    \\zoom_in = ctrl+wheel:up, when viewport
    \\zoom_out = ctrl+minus, repeat 400ms 60ms
    \\zoom_out = ctrl+wheel:down, when viewport
;

/// What a player saved in their settings: only `redo` and `find` change,
/// and `find` now clashes with `copy`.
const overrides =
    \\# my keys
    \\redo = ctrl+shift+z
    \\find = ctrl+c, when text
;

fn printMenu(map: *const Map) !void {
    var buffer: [128]u8 = undefined;
    inline for (@typeInfo(Action).@"enum".field_names) |field_name| {
        var writer: std.Io.Writer = .fixed(&buffer);
        try map.describe(&writer, @field(Action, field_name));
        std.debug.print("  {s:<10} {s}\n", .{ field_name, writer.buffered() });
    }
}

fn type_(tracker: *Map.Tracker, keys: []const keybinds.Key, time: *u64) !void {
    for (keys) |key| try tracker.press(.key(key), time.*);
    var at = keys.len;
    while (at > 0) {
        at -= 1;
        try tracker.release(.key(keys[at]), time.*);
    }
    time.* += keybinds.ms(100);
}

fn printEvents(tracker: *const Map.Tracker, what: []const u8) void {
    std.debug.print("  {s:<34} ->", .{what});
    for (tracker.eventsSinceFrame()) |event| std.debug.print(" {t}{s}", .{ event.action, if (event.repeat > 0) "+" else "" });
    std.debug.print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var map = Map.init(gpa, .{ .exact_modifiers = true });
    defer map.deinit();
    try map.load(defaults, .replace_all, null);
    try map.load(overrides, .replace_actions, null);

    std.debug.print("the menu, with the player's overrides:\n", .{});
    try printMenu(&map);

    const conflicts = try map.conflicts(gpa);
    defer gpa.free(conflicts);
    for (conflicts) |conflict| {
        const first = map.binding(conflict.first);
        const second = map.binding(conflict.second);
        std.debug.print("warning: {f} is both {t} and {t}{s}\n", .{ first.trigger, first.action, second.action, if (conflict.prefix) ", which it begins" else "" });
    }

    var tracker = Map.Tracker.init(gpa, &map, 0);
    defer tracker.deinit();
    tracker.setContext(.text, true);
    var time: u64 = 0;
    std.debug.print("\ntyping:\n", .{});
    const cases = [_]struct { []const u8, []const []const keybinds.Key }{
        .{ "ctrl+s", &.{&.{ .left_ctrl, .s }} },
        .{ "ctrl+shift+s", &.{&.{ .left_ctrl, .left_shift, .s }} },
        .{ "ctrl+alt+s (nothing: exact)", &.{&.{ .left_ctrl, .left_alt, .s }} },
        .{ "ctrl+k ctrl+c", &.{ &.{ .left_ctrl, .k }, &.{ .left_ctrl, .c } } },
        .{ "ctrl+k ctrl+u", &.{ &.{ .left_ctrl, .k }, &.{ .left_ctrl, .u } } },
        .{ "ctrl+c (find and copy clash)", &.{&.{ .left_ctrl, .c }} },
        .{ "ctrl+y (redo moved away)", &.{&.{ .left_ctrl, .y }} },
    };
    for (cases) |case| {
        for (case[1]) |keys| try type_(&tracker, keys, &time);
        printEvents(&tracker, case[0]);
        tracker.endFrame();
    }

    try tracker.press(.key(.right_ctrl), time);
    try tracker.press(.key(.equal), time);
    try tracker.update(time + keybinds.ms(700));
    try tracker.release(.key(.equal), time + keybinds.ms(700));
    try tracker.release(.key(.right_ctrl), time + keybinds.ms(700));
    printEvents(&tracker, "ctrl+= held for 700 ms");
    tracker.endFrame();
    time += keybinds.ms(1000);

    std.debug.print("\nrebinding find: press the new keys...\n", .{});
    tracker.startCapture();
    try type_(&tracker, &.{ .left_ctrl, .left_alt, .f }, &time);
    const chord = tracker.takeCapture().?;
    std.debug.print("  captured {f}\n", .{chord});
    try map.unbindAction(.find);
    _ = try map.bindTrigger(.find, .single(chord), .{});
    try type_(&tracker, &.{ .left_ctrl, .left_alt, .f }, &time);
    printEvents(&tracker, "ctrl+alt+f");
    tracker.endFrame();

    std.debug.print("\nthe settings file now reads:\n", .{});
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try map.write(&text.writer);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text.written(), "\n"), '\n');
    while (lines.next()) |line| std.debug.print("  {s}\n", .{line});
}
