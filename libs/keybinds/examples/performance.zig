const std = @import("std");
const keybinds = @import("keybinds");

const Action = enum(u16) { move_x, move_y, look_x, jump, fire, save, comment, quick_save, zoom, other };
const Context = enum { gameplay, menu, editor };
const Map = keybinds.Keymap(Action, Context);

fn elapsed(io: std.Io, since: std.Io.Timestamp) i96 {
    return std.Io.Clock.now(.awake, io).nanoseconds - since.nanoseconds;
}

fn printRow(name: []const u8, n: usize, ns: i96) void {
    const per: f64 = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
    std.debug.print("{s:<44} {d:>9} {d:>9.1} ns/op\n", .{ name, n, per });
}

/// Every key, mouse button and pad button bound in each context, with
/// modifiers, beside the bindings a game has: about a thousand.
fn register(map: *Map) !void {
    inline for (@typeInfo(keybinds.Key).@"enum".fields) |field| {
        const which: keybinds.Input = .key(@field(keybinds.Key, field.name));
        _ = try map.bindTrigger(.other, .single(.of(.{ .ctrl = true }, &.{which})), .{ .when = &.{.editor} });
        _ = try map.bindTrigger(.other, .single(.of(.{ .ctrl = true, .shift = true }, &.{which})), .{ .when = &.{.editor} });
        _ = try map.bindTrigger(.other, .single(.of(.{ .alt = true }, &.{which})), .{ .when = &.{.menu} });
        _ = try map.bindTrigger(.other, .single(.of(.{ .super = true }, &.{which})), .{});
    }
    _ = try map.bind(.move_x, "d", .{});
    _ = try map.bind(.move_x, "a", .{ .scale = -1 });
    _ = try map.bind(.move_x, "pad:left_x", .{});
    _ = try map.bind(.move_y, "w", .{});
    _ = try map.bind(.move_y, "s", .{ .scale = -1 });
    _ = try map.bind(.look_x, "mouse:right+motion:x", .{ .scale = 0.1 });
    _ = try map.bind(.jump, "space", .{ .when = &.{.gameplay} });
    _ = try map.bind(.fire, "mouse:left", .{ .when = &.{.gameplay} });
    _ = try map.bind(.save, "ctrl+s", .{});
    _ = try map.bind(.comment, "ctrl+k ctrl+c", .{});
    _ = try map.bind(.quick_save, "f5", .{ .gesture = .{ .hold = keybinds.ms(500) } });
    _ = try map.bind(.zoom, "equal", .{ .gesture = .{ .repeat = .{ .delay = keybinds.ms(300), .interval = keybinds.ms(30) } } });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    defer args.deinit();
    _ = args.next();
    const n = if (args.next()) |text| try std.fmt.parseUnsigned(usize, text, 10) else 1_000_000;

    var map = Map.init(gpa, .{});
    defer map.deinit();
    var start = std.Io.Clock.now(.awake, io);
    try register(&map);
    std.debug.print("bindings: {d}, registered in {d:.2} ms\nruns per benchmark: {d}  (ReleaseFast for meaningful numbers)\n\n", .{ map.bindings.items.len, @as(f64, @floatFromInt(elapsed(io, start))) / 1e6, n });

    var tracker = Map.Tracker.init(gpa, &map, 0);
    defer tracker.deinit();
    tracker.setContext(.gameplay, true);
    var time: u64 = 0;

    start = std.Io.Clock.now(.awake, io);
    for (0..n) |_| {
        time += 1000;
        try tracker.press(.key(.space), time);
        try tracker.release(.key(.space), time);
        tracker.endFrame();
    }
    printRow("press + release, one binding fires", n, elapsed(io, start));

    try tracker.press(.key(.left_ctrl), time);
    start = std.Io.Clock.now(.awake, io);
    for (0..n) |_| {
        time += 1000;
        try tracker.press(.key(.s), time);
        try tracker.release(.key(.s), time);
        tracker.endFrame();
    }
    printRow("ctrl+s among 6 bindings of s", n, elapsed(io, start));
    try tracker.release(.key(.left_ctrl), time);

    start = std.Io.Clock.now(.awake, io);
    for (0..n) |_| {
        time += 1000;
        try tracker.press(.key(.x), time);
        try tracker.release(.key(.x), time);
    }
    printRow("press + release that fires nothing", n, elapsed(io, start));

    start = std.Io.Clock.now(.awake, io);
    for (0..n / 4) |_| {
        time += 1000;
        try tracker.press(.key(.left_ctrl), time);
        try tracker.press(.key(.k), time);
        try tracker.release(.key(.k), time);
        try tracker.press(.key(.c), time);
        try tracker.release(.key(.c), time);
        try tracker.release(.key(.left_ctrl), time);
        tracker.endFrame();
    }
    printRow("ctrl+k ctrl+c, all six events", n / 4, elapsed(io, start));

    try tracker.press(.key(.d), time);
    try tracker.press(.mouse(.right), time);
    start = std.Io.Clock.now(.awake, io);
    var sum: f32 = 0;
    for (0..n) |i| {
        try tracker.axis(.left_x, @as(f32, @floatFromInt(i % 100)) / 100, time);
        try tracker.motion(.x, 1);
        sum += tracker.value(.move_x) + tracker.value(.look_x) + tracker.value(.move_y);
        tracker.endFrame();
    }
    std.mem.doNotOptimizeAway(sum);
    printRow("axis + motion fed, three values read", n, elapsed(io, start));
    try tracker.releaseAll(time);

    try tracker.press(.key(.equal), time);
    start = std.Io.Clock.now(.awake, io);
    for (0..n) |_| {
        time += keybinds.ms(30);
        try tracker.update(time);
        tracker.endFrame();
    }
    printRow("update firing a repeat each frame", n, elapsed(io, start));
    try tracker.releaseAll(time);

    start = std.Io.Clock.now(.awake, io);
    for (0..n) |_| {
        time += 1000;
        try tracker.update(time);
        std.mem.doNotOptimizeAway(tracker.down(.jump) or tracker.pressed(.fire));
        tracker.endFrame();
    }
    printRow("an idle frame: update, poll, end", n, elapsed(io, start));

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try map.write(&text.writer);
    var loaded = Map.init(gpa, .{});
    defer loaded.deinit();
    const loads = @max(n / 10_000, 1);
    start = std.Io.Clock.now(.awake, io);
    for (0..loads) |_| try loaded.load(text.written(), .replace_all, null);
    printRow("load the whole keymap from text", loads, elapsed(io, start));
}
