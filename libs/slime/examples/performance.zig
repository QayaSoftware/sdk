const std = @import("std");
const slime = @import("slime");

const P = struct { x: f32, y: f32 };
const V = struct { vx: f32, vy: f32 };

fn printRow(name: []const u8, n: usize, ns: i96) void {
    const per = if (n > 0) @divTrunc(ns, n) else @as(u64, 0);
    const ms_whole = @divTrunc(ns, 1_000_000);
    const ms_frac: u64 = @intCast((@divFloor(@mod(ns, 1_000_000), 1000)));
    std.debug.print("{s:<28} {d:>9} {d:>6}.{d:0>3} ms {d:>14} ns/op\n", .{
        name, n, ms_whole, ms_frac, per,
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var arg_it = try init.minimal.args.iterateAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.next();

    const default_n: usize = 20_000;
    const n = if (arg_it.next()) |s|
        try std.fmt.parseUnsigned(usize, s, 10)
    else
        default_n;

    if (n == 0) {
        std.debug.print("entity count must be > 0\n", .{});
        return;
    }

    std.debug.print(
        \\entity count: {d}  (pass a number as argv to change, e.g. zig build performance -- 50000)
        \\use ReleaseFast for meaningful numbers: zig build performance -Doptimize=ReleaseFast
        \\
        \\benchmark                         n      total_ms    ns/entity
        \\----------------------------------------------------------------
        \\
    , .{n});

    {
        var world = slime.World.init(allocator);
        defer world.deinit();
        var i: usize = 0;

        var now = std.Io.Clock.now(.awake, init.io);
        while (i < n) : (i += 1) {
            _ = try world.spawn(&.{ P, V }, .{
                P{ .x = @floatFromInt(i), .y = 0 },
                V{ .vx = 0, .vy = 0 },
            });
        }
        printRow("spawn P+V", n, std.Io.Clock.now(.awake, init.io).nanoseconds - now.nanoseconds);
        now = std.Io.Clock.now(.awake, init.io);

        var q = world.query(&.{ P, V });
        var c: usize = 0;
        while (q.next()) |_| c += 1;
        printRow("query iterate P+V", n, std.Io.Clock.now(.awake, init.io).nanoseconds - now.nanoseconds);
        std.debug.assert(c == n);

        now = std.Io.Clock.now(.awake, init.io);

        var qc = world.queryChunked(&.{ P, V }, 256);
        var c2: usize = 0;
        while (qc.next()) |ch| {
            c2 += ch.len;
            const slice = world.columnSlice(P, ch.archetype_id, ch.start_row, ch.len).?;
            for (slice) |*p| p.x += 1;
        }
        printRow("chunked + columnSlice P", n, std.Io.Clock.now(.awake, init.io).nanoseconds - now.nanoseconds);
        std.debug.assert(c2 == n);
        now = std.Io.Clock.now(.awake, init.io);

        var q3 = world.query(&.{P});
        while (q3.next()) |hit| {
            if (world.getMut(hit.entity, P)) |p| p.y += 1;
        }
        printRow("getMut via query P", n, std.Io.Clock.now(.awake, init.io).nanoseconds - now.nanoseconds);
    }

    {
        const blob = try slime.prefab.encodePrefabBinary(allocator, 1, &.{ P, V }, .{
            P{ .x = 0, .y = 0 },
            V{ .vx = 1, .vy = 1 },
        });
        defer allocator.free(blob);
        var world = slime.World.init(allocator);
        defer world.deinit();

        var fbsw = std.Io.Reader.fixed(blob);
        var owned = try slime.prefab.readPrefabBinary(allocator, &fbsw);
        defer owned.deinit(allocator);
        const prefab_ref = owned.asRef();

        const now = std.Io.Clock.now(.awake, init.io);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            _ = try world.spawnPrefab(prefab_ref);
        }
        printRow("spawnPrefab (same prefab)", n, std.Io.Clock.now(.awake, init.io).nanoseconds - now.nanoseconds);
    }

    {
        var world = slime.World.init(allocator);
        defer world.deinit();

        var ents: std.ArrayList(slime.Entity) = .empty;
        defer ents.deinit(allocator);
        try ents.ensureTotalCapacity(allocator, n);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = try world.spawn(&.{P}, .{
                P{ .x = @floatFromInt(i), .y = 0 },
            });
            try ents.append(allocator, e);
        }

        const now = std.Io.Clock.now(.awake, init.io);

        for (ents.items) |e| {
            try world.addComponent(e, V, V{ .vx = 0, .vy = 0 });
        }
        printRow("addComponent V (migrate)", n, std.Io.Clock.now(.awake, init.io).nanoseconds - now.nanoseconds);
    }

    {
        var world = slime.World.init(allocator);
        defer world.deinit();

        var ents: std.ArrayList(slime.Entity) = .empty;
        defer ents.deinit(allocator);
        try ents.ensureTotalCapacity(allocator, n);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = try world.spawn(&.{ P, V }, .{
                P{ .x = 0, .y = 0 },
                V{ .vx = 0, .vy = 0 },
            });
            try ents.append(allocator, e);
        }

        const now = std.Io.Clock.now(.awake, init.io);
        for (ents.items) |e| {
            try world.removeComponent(e, V);
        }
        printRow("removeComponent V (migrate)", n, std.Io.Clock.now(.awake, init.io).nanoseconds - now.nanoseconds);
    }

    {
        var world = slime.World.init(allocator);
        defer world.deinit();

        var ents: std.ArrayList(slime.Entity) = .empty;
        defer ents.deinit(allocator);
        try ents.ensureTotalCapacity(allocator, n);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = try world.spawn(&.{ P, V }, .{
                P{ .x = 0, .y = 0 },
                V{ .vx = 0, .vy = 0 },
            });
            try ents.append(allocator, e);
        }

        const now = std.Io.Clock.now(.awake, init.io);
        for (ents.items) |e| {
            world.despawn(e);
        }
        printRow("despawn", n, std.Io.Clock.now(.awake, init.io).nanoseconds - now.nanoseconds);
    }

    std.debug.print(
        \\
        \\done.
        \\
    , .{});
}
