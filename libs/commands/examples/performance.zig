const std = @import("std");
const commands = @import("commands");

const Source = struct { op: bool = true };
const Dispatcher = commands.Dispatcher(Source);
const Context = Dispatcher.Context;

fn noop(ctx: *const Context) !void {
    std.mem.doNotOptimizeAway(ctx.nodes.len);
}

fn useAll(ctx: *const Context) !void {
    std.mem.doNotOptimizeAway(ctx.argument(f64, "x") + ctx.argument(f64, "y") + ctx.argument(f64, "z"));
}

fn isOp(source: Source) bool {
    return source.op;
}

fn identity(ctx: *const Context) !Source {
    return ctx.source;
}

/// 512 filler commands beside tp, give, execute and a command whose last
/// argument only parses after three others fail.
fn register(dispatcher: *Dispatcher, arena: std.mem.Allocator) !void {
    for (0..512) |i| {
        const node = try dispatcher.literal(.root, try std.fmt.allocPrint(arena, "cmd{d:0>3}", .{i}), .{ .requires = isOp });
        _ = try dispatcher.argument(node, "n", i32, .{ .executes = noop });
    }
    const tp = try dispatcher.literal(.root, "tp", .{});
    const x = try dispatcher.argument(tp, "x", f64, .{});
    const y = try dispatcher.argument(x, "y", f64, .{});
    _ = try dispatcher.argument(y, "z", f64, .{ .executes = useAll });

    const give = try dispatcher.literal(.root, "give", .{});
    const target = try dispatcher.argument(give, "target", commands.word, .{});
    const item = try dispatcher.argument(target, "item", commands.word, .{});
    _ = try dispatcher.argument(item, "count", commands.integer(u8, .{ .min = 1, .max = 64 }), .{ .executes = noop });

    const execute = try dispatcher.literal(.root, "execute", .{});
    _ = try dispatcher.literal(execute, "run", .{ .redirect = .to(.root) });
    const as = try dispatcher.literal(execute, "as", .{});
    _ = try dispatcher.argument(as, "who", commands.word, .{ .redirect = .map(execute, identity) });

    const pick = try dispatcher.literal(.root, "pick", .{});
    _ = try dispatcher.argument(pick, "a", u8, .{ .executes = noop });
    _ = try dispatcher.argument(pick, "b", bool, .{ .executes = noop });
    _ = try dispatcher.argument(pick, "c", commands.choice(enum { north, south }), .{ .executes = noop });
    _ = try dispatcher.argument(pick, "d", commands.word, .{ .executes = noop });
}

fn elapsed(io: std.Io, since: std.Io.Timestamp) i96 {
    return std.Io.Clock.now(.awake, io).nanoseconds - since.nanoseconds;
}

fn printRow(name: []const u8, n: usize, ns: i96) void {
    const per: f64 = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
    std.debug.print("{s:<40} {d:>9} {d:>10.1} ns/op {d:>12.0} ops/s\n", .{ name, n, per, 1e9 / per });
}

/// Inputs that differ in their numbers, so each round is not the same text:
/// `format` takes the first `arity` of a counter, a count in 1...64 and a
/// float.
fn inputs(arena: std.mem.Allocator, comptime format: []const u8, comptime arity: usize) ![64][]const u8 {
    var all: [64][]const u8 = undefined;
    for (&all, 0..) |*input, i| {
        const values = .{ i, i * 7 % 64 + 1, @as(f64, @floatFromInt(i)) * 0.5 };
        input.* = switch (arity) {
            1 => try std.fmt.allocPrint(arena, format, .{values[0]}),
            2 => try std.fmt.allocPrint(arena, format, .{ values[0], values[1] }),
            else => try std.fmt.allocPrint(arena, format, values),
        };
    }
    return all;
}

fn benchParse(io: std.Io, dispatcher: *const Dispatcher, name: []const u8, n: usize, texts: []const []const u8) void {
    var buffer: [commands.default_buffer_size]u8 = undefined;
    const start = std.Io.Clock.now(.awake, io);
    for (0..n) |i| {
        const parsed = dispatcher.parse(texts[i % texts.len], .{}, &buffer, null) catch unreachable;
        std.mem.doNotOptimizeAway(parsed.nodes.len);
    }
    printRow(name, n, elapsed(io, start));
}

fn benchExecute(io: std.Io, dispatcher: *const Dispatcher, name: []const u8, n: usize, texts: []const []const u8) void {
    const start = std.Io.Clock.now(.awake, io);
    for (0..n) |i| std.mem.doNotOptimizeAway(dispatcher.execute(texts[i % texts.len], .{}, null) catch unreachable);
    printRow(name, n, elapsed(io, start));
}

fn worker(dispatcher: *const Dispatcher, texts: []const []const u8, n: usize) void {
    for (0..n) |i| std.mem.doNotOptimizeAway(dispatcher.execute(texts[i % texts.len], .{}, null) catch unreachable);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(arena);
    defer args.deinit();
    _ = args.next();
    const n = if (args.next()) |text| try std.fmt.parseUnsigned(usize, text, 10) else 1_000_000;

    var dispatcher = Dispatcher.init(init.gpa);
    defer dispatcher.deinit();
    try register(&dispatcher, arena);

    std.debug.print(
        \\runs per benchmark: {d}  (pass a number to change it, e.g. zig build commands-performance -- 5000000)
        \\use -Doptimize=fast for meaningful numbers: zig build commands-performance -Doptimize=fast
        \\
        \\
    , .{n});

    const tp = try inputs(arena, "tp {d} {d} {d}", 3);
    const give = try inputs(arena, "give player{d} diamond {d}", 2);
    const filler = try inputs(arena, "cmd{d:0>3} {d}", 2);
    const chained = try inputs(arena, "execute as p{d} run execute as q{d} run tp 1 2 {d}", 3);
    const picks = try inputs(arena, "pick word{d}", 1);
    const quoted = try inputs(arena, "give \"player {d}\" diamond {d}", 2);

    benchParse(io, &dispatcher, "parse tp <x> <y> <z>", n, &tp);
    benchParse(io, &dispatcher, "parse give <target> <item> <count>", n, &give);
    benchParse(io, &dispatcher, "parse one of 512 literals", n, &filler);
    benchParse(io, &dispatcher, "parse two redirects", n, &chained);
    benchParse(io, &dispatcher, "parse after three arguments fail", n, &picks);
    benchExecute(io, &dispatcher, "execute tp <x> <y> <z>", n, &tp);
    benchExecute(io, &dispatcher, "execute two redirects", n, &chained);

    {
        var buffer: [commands.default_buffer_size]u8 = undefined;
        var diagnostics: commands.Diagnostics = .{};
        const start = std.Io.Clock.now(.awake, io);
        for (0..n) |i| {
            _ = dispatcher.parse(quoted[i % quoted.len], .{}, &buffer, &diagnostics) catch {};
            std.mem.doNotOptimizeAway(diagnostics.cursor);
        }
        printRow("reject a bad argument", n, elapsed(io, start));
    }
    {
        const runs = @max(n / 100, 1);
        const start = std.Io.Clock.now(.awake, io);
        for (0..runs) |_| {
            var suggestions = try dispatcher.suggest(init.gpa, "cmd1", .{});
            std.mem.doNotOptimizeAway(suggestions.items.len);
            suggestions.deinit();
        }
        printRow("suggest among 512 literals (100 found)", runs, elapsed(io, start));
    }

    std.debug.print("\n", .{});
    for ([_]usize{ 1, 2, 4, 8, 16 }) |tasks| {
        const per_task = n / tasks;
        var group: std.Io.Group = .init;
        const start = std.Io.Clock.now(.awake, io);
        for (0..tasks) |_| group.concurrent(io, worker, .{ &dispatcher, &tp, per_task }) catch worker(&dispatcher, &tp, per_task);
        try group.await(io);
        var name_buffer: [64]u8 = undefined;
        printRow(try std.fmt.bufPrint(&name_buffer, "execute tp, {d} tasks at once", .{tasks}), per_task * tasks, elapsed(io, start));
    }
}
