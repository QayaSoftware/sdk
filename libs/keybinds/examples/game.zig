const std = @import("std");
const keybinds = @import("keybinds");

const Action = enum { move_x, move_y, look_x, jump, dash, interact, pause, back, quick_save };
const Context = enum { gameplay, menu };
const Map = keybinds.Keymap(Action, Context);

const defaults =
    \\move_x = d
    \\move_x = a, scale -1
    \\move_x = pad:left_x
    \\move_y = w
    \\move_y = s, scale -1
    \\move_y = pad:left_y, scale -1
    \\look_x = mouse:right+motion:x, scale 0.01
    \\jump = space, when gameplay
    \\jump = pad:south, when gameplay
    \\dash = w, double 250ms, when gameplay
    \\dash = pad:east, when gameplay
    \\interact = e, hold 400ms, when gameplay
    \\interact = pad:west, hold 400ms, when gameplay
    \\pause = escape, when gameplay
    \\pause = pad:start, when gameplay
    \\back = escape, when menu
    \\back = pad:east, when menu
    \\quick_save = f5
;

/// Two players, one at the keyboard and one with a gamepad, through one
/// keymap: each has a tracker, which is who an event is from.
const Game = struct {
    trackers: [2]*Map.Tracker,
    names: [2][]const u8 = .{ "keyboard", "gamepad" },
    positions: [2][2]f32 = @splat(.{ 0, 0 }),

    fn say(game: *Game, event: Map.Event, what: []const u8) void {
        std.debug.print("  [{d:>4} ms] {s:<8} {s}\n", .{ event.time / std.time.ns_per_ms, game.names[event.caller], what });
    }

    fn jump(game: *Game, event: Map.Event) void {
        game.say(event, "jumps");
    }

    fn dash(game: *Game, event: Map.Event) void {
        game.say(event, "dashes");
    }

    fn interact(game: *Game, event: Map.Event) void {
        game.say(event, "opens the chest, having held to interact");
    }

    fn pause(game: *Game, event: Map.Event) void {
        game.say(event, "pauses: the menu takes their input");
        game.trackers[event.caller].setContexts(.initMany(&.{.menu}));
    }

    fn back(game: *Game, event: Map.Event) void {
        game.say(event, "goes back to the game");
        game.trackers[event.caller].setContexts(.initMany(&.{.gameplay}));
    }

    fn quickSave(game: *Game, event: Map.Event) bool {
        game.say(event, "quick saves");
        return true;
    }
};

/// What a window would report, as it happened.
const Happening = struct {
    at: u64,
    player: u1,
    what: union(enum) {
        press: keybinds.Input,
        release: keybinds.Input,
        axis: struct { keybinds.Axis, f32 },
        motion: struct { keybinds.Motion, f32 },
    },
};

fn at(milliseconds: u64, player: u1, what: @FieldType(Happening, "what")) Happening {
    return .{ .at = keybinds.ms(milliseconds), .player = player, .what = what };
}

const script = [_]Happening{
    at(0, 0, .{ .press = .key(.d) }),
    at(40, 0, .{ .press = .key(.space) }),
    at(90, 0, .{ .release = .key(.space) }),
    at(200, 0, .{ .release = .key(.d) }),
    at(250, 0, .{ .press = .key(.w) }),
    at(300, 0, .{ .release = .key(.w) }),
    at(380, 0, .{ .press = .key(.w) }),
    at(520, 0, .{ .release = .key(.w) }),
    at(600, 0, .{ .press = .key(.e) }),
    at(610, 1, .{ .axis = .{ .left_x, 0.8 } }),
    at(700, 0, .{ .press = .mouse(.right) }),
    at(710, 0, .{ .motion = .{ .x, 120 } }),
    at(800, 1, .{ .axis = .{ .left_x, 0 } }),
    at(820, 0, .{ .release = .mouse(.right) }),
    at(1100, 0, .{ .release = .key(.e) }),
    at(1200, 1, .{ .press = .button(.start) }),
    at(1250, 1, .{ .release = .button(.start) }),
    at(1300, 1, .{ .press = .button(.south) }),
    at(1350, 1, .{ .release = .button(.south) }),
    at(1400, 1, .{ .press = .button(.east) }),
    at(1450, 1, .{ .release = .button(.east) }),
    at(1500, 1, .{ .press = .button(.south) }),
    at(1550, 1, .{ .release = .button(.south) }),
    at(1700, 0, .{ .press = .key(.f5) }),
    at(1710, 0, .{ .release = .key(.f5) }),
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var map = Map.init(gpa, .{});
    defer map.deinit();
    try map.load(defaults, .replace_all, null);

    var keyboard = Map.Tracker.init(gpa, &map, 0);
    defer keyboard.deinit();
    var gamepad = Map.Tracker.init(gpa, &map, 1);
    defer gamepad.deinit();
    var game: Game = .{ .trackers = .{ &keyboard, &gamepad } };
    for (game.trackers) |tracker| tracker.setContext(.gameplay, true);

    var handlers = Map.Handlers.init(gpa);
    defer handlers.deinit();
    _ = try handlers.on(.jump, .of(&game, Game.jump), .{});
    _ = try handlers.on(.dash, .of(&game, Game.dash), .{});
    _ = try handlers.on(.interact, .of(&game, Game.interact), .{});
    _ = try handlers.on(.pause, .of(&game, Game.pause), .{});
    _ = try handlers.on(.back, .of(&game, Game.back), .{});
    _ = try handlers.on(.quick_save, .of(&game, Game.quickSave), .{});

    std.debug.print("a scripted session at 60 frames a second, two players on one keymap:\n", .{});
    const frame = std.time.ns_per_s / 60;
    var next: usize = 0;
    var now: u64 = 0;
    while (next < script.len or now < keybinds.ms(1800)) : (now += frame) {
        while (next < script.len and script[next].at <= now) : (next += 1) {
            const happening = script[next];
            const tracker = game.trackers[happening.player];
            switch (happening.what) {
                .press => |which| try tracker.press(which, happening.at),
                .release => |which| try tracker.release(which, happening.at),
                .axis => |axis| try tracker.axis(axis[0], axis[1], happening.at),
                .motion => |motion| try tracker.motion(motion[0], motion[1]),
            }
        }
        for (game.trackers, &game.positions) |tracker, *position| {
            try tracker.update(now);
            const seconds = @as(f32, frame) / std.time.ns_per_s;
            position[0] += tracker.value(.move_x) * seconds;
            position[1] += tracker.value(.move_y) * seconds;
            if (tracker.value(.look_x) != 0) std.debug.print("  [{d:>4} ms] {s:<8} turns by {d:.2}\n", .{ now / std.time.ns_per_ms, game.names[tracker.caller], tracker.value(.look_x) });
            handlers.dispatch(tracker);
            tracker.endFrame();
        }
    }
    for (game.names, game.positions) |name, position| std.debug.print("{s} ended at {d:.2}, {d:.2}\n", .{ name, position[0], position[1] });

    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try map.describe(&writer, .interact);
    std.debug.print("the prompt for interacting reads: Hold {s}\n", .{writer.buffered()});
}
