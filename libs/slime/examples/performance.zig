const std = @import("std");
const slime = @import("slime");

const P = struct { x: f32, y: f32 };
const V = struct { vx: f32, vy: f32 };

fn printRow(name: []const u8, n: usize, ns: i96) void {
    const per = @divTrunc(ns, n);
    const ms_whole = @divTrunc(ns, 1_000_000);
    const ms_frac: u64 = @intCast(@divFloor(@mod(ns, 1_000_000), 1000));
    std.debug.print("{s:<28} {d:>9} {d:>6}.{d:0>3} ms {d:>14} ns/op\n", .{ name, n, ms_whole, ms_frac, per });
}

fn elapsed(io: std.Io, since: std.Io.Timestamp) i96 {
    return std.Io.Clock.now(.awake, io).nanoseconds - since.nanoseconds;
}

fn spawnMany(world: *slime.World, ents: *std.ArrayList(slime.Entity), allocator: std.mem.Allocator, n: usize, bundle: anytype) !void {
    try ents.ensureTotalCapacity(allocator, n);
    for (0..n) |_| ents.appendAssumeCapacity(try world.spawn(bundle));
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var arg_it = try init.minimal.args.iterateAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.next();
    const n = if (arg_it.next()) |s| try std.fmt.parseUnsigned(usize, s, 10) else 20_000;
    if (n == 0) {
        std.debug.print("entity count must be > 0\n", .{});
        return;
    }

    std.debug.print(
        \\entity count: {d}  (pass a number as argv to change, e.g. zig build slime-performance -- 50000)
        \\use -Doptimize=fast for meaningful numbers: zig build slime-performance -Doptimize=fast
        \\
        \\benchmark                         n      total_ms    ns/entity
        \\----------------------------------------------------------------
        \\
    , .{n});

    {
        var world = slime.World.init(allocator, io);
        defer world.deinit();

        var now = std.Io.Clock.now(.awake, io);
        for (0..n) |i| _ = try world.spawn(.{ P{ .x = @floatFromInt(i), .y = 0 }, V{ .vx = 1, .vy = 0 } });
        printRow("spawn P+V", n, elapsed(io, now));

        now = std.Io.Clock.now(.awake, io);
        var sum: f32 = 0;
        var q = world.query(&.{ P, V });
        while (q.next()) |chunk| for (chunk.slice(P), chunk.slice(V)) |p, v| {
            sum += p.x * v.vx;
        };
        std.mem.doNotOptimizeAway(sum);
        printRow("query read P+V", n, elapsed(io, now));

        now = std.Io.Clock.now(.awake, io);
        var q2 = world.query(&.{ P, V });
        while (q2.next()) |chunk| for (chunk.slice(P), chunk.slice(V)) |*p, v| {
            p.x += v.vx;
        };
        printRow("query write P from V", n, elapsed(io, now));

        now = std.Io.Clock.now(.awake, io);
        var q3 = world.query(&.{P});
        while (q3.next()) |chunk| for (chunk.entities()) |e| {
            if (world.getPtr(e, P)) |p| p.y += 1;
        };
        printRow("getPtr per entity P", n, elapsed(io, now));
    }

    {
        var world = slime.World.init(allocator, io);
        defer world.deinit();
        var prefab = try slime.Prefab.from(allocator, .{ P{ .x = 0, .y = 0 }, V{ .vx = 1, .vy = 1 } });
        defer prefab.deinit();

        const now = std.Io.Clock.now(.awake, io);
        for (0..n) |_| _ = try world.spawnPrefab(&prefab);
        printRow("spawnPrefab (same prefab)", n, elapsed(io, now));
    }

    {
        var world = slime.World.init(allocator, io);
        defer world.deinit();
        var ents: std.ArrayList(slime.Entity) = .empty;
        try spawnMany(&world, &ents, allocator, n, .{P{ .x = 0, .y = 0 }});

        const now = std.Io.Clock.now(.awake, io);
        for (ents.items) |e| try world.add(e, V{ .vx = 0, .vy = 0 });
        printRow("add V (migrate)", n, elapsed(io, now));
    }

    {
        var world = slime.World.init(allocator, io);
        defer world.deinit();
        var ents: std.ArrayList(slime.Entity) = .empty;
        try spawnMany(&world, &ents, allocator, n, .{ P{ .x = 0, .y = 0 }, V{ .vx = 0, .vy = 0 } });

        const now = std.Io.Clock.now(.awake, io);
        for (ents.items) |e| _ = try world.remove(e, V);
        printRow("remove V (migrate)", n, elapsed(io, now));
    }

    {
        var world = slime.World.init(allocator, io);
        defer world.deinit();
        var ents: std.ArrayList(slime.Entity) = .empty;
        try spawnMany(&world, &ents, allocator, n, .{ P{ .x = 0, .y = 0 }, V{ .vx = 0, .vy = 0 } });

        const now = std.Io.Clock.now(.awake, io);
        for (ents.items) |e| _ = world.despawn(e);
        printRow("despawn", n, elapsed(io, now));
    }

    {
        var world = slime.World.init(allocator, io);
        defer world.deinit();
        var ents: std.ArrayList(slime.Entity) = .empty;
        try spawnMany(&world, &ents, allocator, n, .{ P{ .x = 0, .y = 0 }, V{ .vx = 0, .vy = 0 } });

        const now = std.Io.Clock.now(.awake, io);
        const commands = world.commands();
        for (ents.items) |e| try commands.despawn(e);
        try world.applyCommands();
        printRow("queued despawn + apply", n, elapsed(io, now));
    }

    std.debug.print("\ndone.\n", .{});
}
