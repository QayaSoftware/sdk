const std = @import("std");
const logging = @import("root.zig");
const format = @import("format.zig");

const testing = std.testing;

fn recent(comptime L: type, buffer: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try L.writeRecent(&writer, 100);
    return writer.buffered();
}

/// Keeps the records it hears, and can log from inside.
const Capture = struct {
    listener: logging.Listener = .{ .call = hear },
    messages: [64][128]u8 = undefined,
    lengths: [64]usize = undefined,
    count: usize = 0,
    nested: ?*const fn () void = null,

    fn hear(listener: *logging.Listener, record: *const logging.Record) void {
        const self: *Capture = @fieldParentPtr("listener", listener);
        const length = @min(record.message.len, 128);
        @memcpy(self.messages[self.count][0..length], record.message[0..length]);
        self.lengths[self.count] = record.message.len;
        self.count += 1;
        if (self.nested) |nested| nested();
    }

    fn message(self: *const Capture, i: usize) []const u8 {
        return self.messages[i][0..@min(self.lengths[i], 128)];
    }
};

test "decorations write each part asked for, in order" {
    const L = logging.Logger(.{
        .terminal = null,
        .memory = 4001,
        .memory_decorations = .{ .time = .none, .level = .short, .thread = true, .frame = true },
        .collapse_repeats = false,
    });
    logging.nameThread("main");
    defer logging.nameThread(null);
    logging.setFrame(42);
    defer logging.setFrame(0);
    L.log(.info, .render, "drew {d} meshes", .{12});
    L.log(.warn, .default, "low memory", .{});
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings("INF [main] f42 render: drew 12 meshes\nWRN [main] f42 low memory\n", try recent(L, &buffer));
}

test "level labels and presets" {
    const record: logging.Record = .{ .level = .warn, .scope = "audio", .message = "clipping", .time = 0, .elapsed = 1_234_567_890, .frame = 7, .thread = .{ .number = 3 } };
    const cases = [_]struct { logging.Decorations, []const u8 }{
        .{ .{ .time = .none, .level = .word }, "warning audio: clipping\n" },
        .{ .{ .time = .none, .level = .letter, .scope = false }, "W clipping\n" },
        .{ .compact, "W audio: clipping\n" },
        .{ .plain, "clipping\n" },
        .{ .pretty, "+   1.234s WRN audio: clipping\n" },
        .{ .{ .time = .none, .level = .none, .thread = true }, "[#3] audio: clipping\n" },
    };
    for (cases) |case| {
        var buffer: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try format.writeLine(&record, .{ .text = case[0] }, .{ .writer = &writer });
        try testing.expectEqualStrings(case[1], writer.buffered());
    }
}

test "times are written in UTC" {
    const time: i96 = 1709210096789 * std.time.ns_per_ms;
    const cases = [_]struct { logging.Time, []const u8 }{
        .{ .date_time, "2024-02-29 12:34:56.789" },
        .{ .clock, "12:34:56.789" },
        .{ .unix, "1709210096.789" },
        .{ .elapsed, "+  61.002s" },
    };
    for (cases) |case| {
        var buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try format.writeTime(&writer, case[0], time, 61_002_000_000);
        try testing.expectEqualStrings(case[1], writer.buffered());
    }
    const new_year = format.Civil.of(946684800 * std.time.ns_per_s);
    try testing.expectEqual(@as(u32, 2000), new_year.year);
    try testing.expectEqual(@as(u8, 1), new_year.month);
    try testing.expectEqual(@as(u8, 1), new_year.day);
}

test "json writes every field and escapes strings" {
    const record: logging.Record = .{
        .level = .err,
        .scope = "net",
        .message = "bad \"packet\"\n\tfrom \\host\x01",
        .time = 1709210096789 * std.time.ns_per_ms,
        .elapsed = 5,
        .frame = 9,
        .thread = .{ .number = 2, .name = "io" },
        .repeats = 3,
    };
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try format.writeLine(&record, .json, .{ .writer = &writer });
    try testing.expectEqualStrings(
        \\{"time":"2024-02-29T12:34:56.789Z","elapsed":5,"level":"error","scope":"net","thread":2,"thread_name":"io","frame":9,"message":"bad \"packet\"\n\tfrom \\host\u0001","repeats":3}
        \\
    , writer.buffered());
}

fn customFormat(record: *const logging.Record, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("<{s}|{s}>", .{ record.scope, record.message });
}

test "a custom format writes the record its own way" {
    const record: logging.Record = .{ .level = .info, .scope = "ui", .message = "hi", .time = 0, .elapsed = 0, .frame = 0, .thread = .{ .number = 1 } };
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try format.writeLine(&record, .{ .custom = customFormat }, .{ .writer = &writer });
    try testing.expectEqualStrings("<ui|hi>\n", writer.buffered());
}

test "repeats collapse into a count" {
    const L = logging.Logger(.{ .terminal = null, .memory = 4002, .memory_decorations = .plain });
    for (0..5) |_| L.log(.warn, .physics, "body {d} fell out of the world", .{7});
    L.log(.info, .physics, "something else", .{});
    for (0..3) |_| L.log(.info, .physics, "again", .{});
    L.flush();
    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        \\body 7 fell out of the world
        \\body 7 fell out of the world (repeated 4 more times)
        \\something else
        \\again
        \\again (repeated 2 more times)
        \\
    , try recent(L, &buffer));
}

test "levels change at runtime by scope, by default and by name" {
    const L = logging.Logger(.{ .terminal = null, .memory = 4003, .memory_decorations = .compact, .level = .info, .collapse_repeats = false });
    defer {
        logging.setDefaultLevel(null);
        logging.setLevel(.physics, null);
        logging.setLevelByName("audio_names", null) catch {};
    }
    L.log(.debug, .physics, "hidden", .{});
    logging.setLevel(.physics, .debug);
    try testing.expectEqual(@as(?logging.Level, .debug), logging.levelOf(.physics));
    L.log(.debug, .physics, "shown", .{});
    logging.setDefaultLevel(.warn);
    L.log(.info, .render, "hidden by the default", .{});
    L.log(.info, .physics, "still shown", .{});
    try logging.setLevelByName("audio_names", .debug);
    try testing.expectEqual(@as(?logging.Level, .debug), logging.levelOfName("audio_names"));
    L.log(.debug, .audio_names, "named before it logged", .{});
    try logging.setLevelByName("audio_names", .err);
    L.log(.warn, .audio_names, "hidden by name", .{});
    try testing.expectError(error.NameTooLong, logging.setLevelByName("x" ** 65, .err));

    var names: [64][]const u8 = undefined;
    const known = logging.scopeNames(&names);
    var found = false;
    for (known) |name| found = found or std.mem.eql(u8, name, "audio_names");
    try testing.expect(found);

    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings("D physics: shown\nI physics: still shown\nD audio_names: named before it logged\n", try recent(L, &buffer));
}

test "once logs the first time, throttled once an interval" {
    const L = logging.Logger(.{ .terminal = null, .memory = 4004, .memory_decorations = .plain, .collapse_repeats = false });
    for (0..3) |i| L.once(.warn, .loader, "missing texture {d}", .{i});
    for (0..4) |i| L.throttled(60, .warn, .loader, "slow frame {d}", .{i});
    try testing.io.sleep(.fromMilliseconds(80), .awake);
    L.throttled(60, .warn, .loader, "slow frame {d}", .{9});
    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings("missing texture 0\nslow frame 0\nslow frame 9 (3 left out)\n", try recent(L, &buffer));
}

test "a message too long for the buffers is formatted again, then cut off" {
    const L = logging.Logger(.{ .terminal = null, .message_buffer = 32, .overflow_buffer = 96, .collapse_repeats = false });
    var capture: Capture = .{};
    logging.listen(&capture.listener);
    defer logging.unlisten(&capture.listener);
    L.log(.info, .text, "{s}", .{"a" ** 60});
    L.log(.info, .text, "{s}", .{"b" ** 200});
    try testing.expectEqual(@as(usize, 2), capture.count);
    try testing.expectEqualStrings("a" ** 60, capture.message(0));
    try testing.expectEqual(@as(usize, 96), capture.lengths[1]);
    try testing.expectEqualStrings("b" ** 81 ++ "... [truncated]", capture.message(1));
}

const Nested = logging.Logger(.{ .terminal = null, .memory = 4005, .memory_decorations = .plain, .collapse_repeats = false });

fn logFromListener() void {
    Nested.log(.debug, .console, "logged from a listener", .{});
}

test "a listener hears each record, and what it logs reaches only the sinks" {
    var capture: Capture = .{ .nested = logFromListener };
    logging.listen(&capture.listener);
    logging.listen(&capture.listener);
    Nested.log(.info, .game, "first", .{});
    Nested.log(.info, .game, "second", .{});
    logging.unlisten(&capture.listener);
    Nested.log(.info, .game, "unheard", .{});
    try testing.expectEqual(@as(usize, 2), capture.count);
    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings("first\nlogged from a listener\nsecond\nlogged from a listener\nunheard\n", try recent(Nested, &buffer));
}

const Threaded = logging.Logger(.{ .terminal = null, .memory = 64 * 1024, .memory_decorations = .{ .time = .none, .level = .none, .thread = true }, .collapse_repeats = false });

fn logMany(task: usize) void {
    for (0..200) |i| Threaded.log(.info, .worker, "task {d} record {d}", .{ task, i });
}

const Counter = struct {
    listener: logging.Listener = .{ .call = hear },
    count: usize = 0,

    fn hear(listener: *logging.Listener, _: *const logging.Record) void {
        const self: *Counter = @fieldParentPtr("listener", listener);
        self.count += 1;
    }
};

test "many threads log at once without tearing lines" {
    var counter: Counter = .{};
    logging.listen(&counter.listener);
    defer logging.unlisten(&counter.listener);
    var group: std.Io.Group = .init;
    for (0..8) |task| group.concurrent(testing.io, logMany, .{task}) catch logMany(task);
    try group.await(testing.io);
    try testing.expectEqual(@as(usize, 1600), counter.count);

    const buffer = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    try Threaded.writeRecent(&writer, 2000);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, writer.buffered(), "\n"), '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        try testing.expect(std.mem.startsWith(u8, line, "[#"));
        try testing.expect(std.mem.indexOf(u8, line, "] worker: task ") != null);
    }
    try testing.expect(count > 1000);
}

fn tmpPath(buffer: []u8, tmp: *const testing.TmpDir, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, name }) catch unreachable;
}

test "a file sink holds records until it has a target, then rotates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const L = logging.Logger(.{ .terminal = null, .file = .{ .format = .{ .text = .plain }, .max_bytes = 120, .keep = 3, .append = false }, .collapse_repeats = false });
    L.log(.info, .boot, "early {d}", .{1});
    L.log(.info, .boot, "early {d}", .{2});
    var path_buffer: [256]u8 = undefined;
    try L.setFile(.{ .path = tmpPath(&path_buffer, &tmp, "logs/game.log") });
    for (0..40) |i| L.log(.info, .boot, "line {d:0>2}", .{i});
    L.flush();

    var read: [512]u8 = undefined;
    const current = try tmp.dir.readFile(testing.io, "logs/game.log", &read);
    try testing.expect(std.mem.endsWith(u8, current, "line 39\n"));
    _ = try tmp.dir.statFile(testing.io, "logs/game.log.1", .{});
    _ = try tmp.dir.statFile(testing.io, "logs/game.log.2", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "logs/game.log.3", .{}));
}

test "a directory sink starts a file each run and keeps the newest" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "runs");
    const old = [_][]const u8{ "2020-01-01_00-00-01.log", "2020-01-01_00-00-02.log", "2020-01-01_00-00-02_2.log", "2020-01-01_00-00-03.log", "notes.txt" };
    for (old) |name| {
        var path: [64]u8 = undefined;
        try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&path, "runs/{s}", .{name}), .data = "old\n" });
    }
    const L = logging.Logger(.{ .terminal = null, .file = .{ .format = .{ .text = .plain }, .keep = 3 }, .collapse_repeats = false });
    var path_buffer: [256]u8 = undefined;
    try L.setFile(.{ .directory = tmpPath(&path_buffer, &tmp, "runs") });
    L.log(.info, .boot, "this run", .{});
    L.flush();

    var runs = try tmp.dir.openDir(testing.io, "runs", .{ .iterate = true });
    defer runs.close(testing.io);
    var kept: usize = 0;
    var newest_found = false;
    var iterator = runs.iterate();
    while (try iterator.next(testing.io)) |entry| {
        if (std.mem.eql(u8, entry.name, "notes.txt")) continue;
        kept += 1;
        try testing.expect(!std.mem.eql(u8, entry.name, "2020-01-01_00-00-01.log"));
        try testing.expect(!std.mem.eql(u8, entry.name, "2020-01-01_00-00-02.log"));
        if (!std.mem.startsWith(u8, entry.name, "2020")) {
            var read: [64]u8 = undefined;
            try testing.expectEqualStrings("this run\n", try runs.readFile(testing.io, entry.name, &read));
            newest_found = true;
        }
    }
    try testing.expectEqual(@as(usize, 3), kept);
    try testing.expect(newest_found);
}

test "a timer measures, and stats count" {
    const timer = logging.Timer.start();
    try testing.io.sleep(.fromMilliseconds(2), .awake);
    try testing.expect(timer.elapsed() >= 2 * std.time.ns_per_ms);
    try testing.expectEqual(@as(f64, 1.5), logging.milliseconds(1_500_000));
    const L = logging.Logger(.{ .terminal = null, .memory = 4006 });
    const before = logging.stats().records;
    L.log(.info, .stats, "counted", .{});
    try testing.expectEqual(before + 1, logging.stats().records);
}

test "a terminal gets colors, and none when it shows none" {
    const record: logging.Record = .{ .level = .err, .scope = "gpu", .message = "lost", .time = 0, .elapsed = 0, .frame = 0, .thread = .{ .number = 1 } };
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const decorations: logging.Decorations = .{ .time = .none };
    try format.writeLine(&record, .{ .text = decorations }, .{ .writer = &writer, .terminal = .{ .writer = &writer, .mode = .escape_codes } });
    try testing.expectEqualStrings("\x1b[31m\x1b[1mERR\x1b[0m \x1b[2m\x1b[1mgpu:\x1b[0m lost\n", writer.buffered());
    writer = .fixed(&buffer);
    try format.writeLine(&record, .{ .text = decorations }, .{ .writer = &writer, .terminal = .{ .writer = &writer, .mode = .no_color } });
    try testing.expectEqualStrings("ERR gpu: lost\n", writer.buffered());
}
