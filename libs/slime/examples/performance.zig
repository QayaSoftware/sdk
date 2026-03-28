//! ECS micro-benchmarks (timer-based, not a sampling profiler).
//! Run: `zig build performance` or `zig build performance -Doptimize=ReleaseFast -- 100000`
//! Optional arg: entity count (default 20_000).

const std = @import("std");
const slime = @import("slime");

const Components = struct {
    pub const P = struct { x: f32, y: f32 };
    pub const V = struct { vx: f32, vy: f32 };
};

const World = slime.World(Components);

fn printRow(name: []const u8, n: usize, ns: u64) void {
    const per = if (n > 0) ns / n else @as(u64, 0);
    const ms_whole = ns / 1_000_000;
    const ms_frac: u64 = (ns % 1_000_000) / 1000;
    std.debug.print("{s:<28} {d:>9} {d:>6}.{d:0>3} ms {d:>14} ns/op\n", .{
        name, n, ms_whole, ms_frac, per,
    });
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var arg_it = try std.process.argsWithAllocator(allocator);
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
        \\slime performance (std.time.Timer)
        \\entity count: {d}  (pass a number as argv to change, e.g. zig build performance -- 50000)
        \\use ReleaseFast for meaningful numbers: zig build performance -Doptimize=ReleaseFast
        \\
        \\benchmark                         n      total_ms    ns/entity
        \\----------------------------------------------------------------
        \\
    , .{n});

    // --- spawn P+V ---
    {
        var world = World.init(allocator);
        defer world.deinit();

        var timer = try std.time.Timer.start();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            _ = try world.spawn(&.{ Components.P, Components.V }, .{
                Components.P{ .x = @floatFromInt(i), .y = 0 },
                Components.V{ .vx = 0, .vy = 0 },
            });
        }
        printRow("spawn P+V", n, timer.lap());

        timer.reset();
        var q = world.query(&.{ Components.P, Components.V });
        var c: usize = 0;
        while (q.next()) |_| c += 1;
        printRow("query iterate P+V", n, timer.lap());
        std.debug.assert(c == n);

        timer.reset();
        var qc = world.queryChunked(&.{ Components.P, Components.V }, 256);
        var c2: usize = 0;
        while (qc.next()) |ch| {
            c2 += ch.len;
            const slice = world.columnSlice(Components.P, ch.archetype_id, ch.start_row, ch.len).?;
            for (slice) |*p| p.x += 1;
        }
        printRow("chunked + columnSlice P", n, timer.lap());
        std.debug.assert(c2 == n);

        timer.reset();
        var q3 = world.query(&.{Components.P});
        while (q3.next()) |hit| {
            if (world.getMut(hit.entity, Components.P)) |p| p.y += 1;
        }
        printRow("getMut via query P", n, timer.lap());
    }

    // --- prefab spawn ---
    {
        const blob = try slime.prefab.encodePrefabBinary(Components, allocator, 1, &.{ Components.P, Components.V }, .{
            Components.P{ .x = 0, .y = 0 },
            Components.V{ .vx = 1, .vy = 1 },
        });
        defer allocator.free(blob);

        var world = World.init(allocator);
        defer world.deinit();

        var fbs = std.io.fixedBufferStream(blob);
        var owned = try slime.prefab.readPrefabBinary(allocator, fbs.reader());
        defer owned.deinit(allocator);
        const prefab_ref = owned.asRef();

        var timer = try std.time.Timer.start();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            _ = try world.spawnPrefab(prefab_ref);
        }
        printRow("spawnPrefab (same prefab)", n, timer.lap());
    }

    // --- addComponent: P -> P+V migrate ---
    {
        var world = World.init(allocator);
        defer world.deinit();

        var ents: std.ArrayList(slime.Entity) = .{};
        defer ents.deinit(allocator);
        try ents.ensureTotalCapacity(allocator, n);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = try world.spawn(&.{Components.P}, .{
                Components.P{ .x = @floatFromInt(i), .y = 0 },
            });
            try ents.append(allocator, e);
        }

        var timer = try std.time.Timer.start();
        for (ents.items) |e| {
            try world.addComponent(e, Components.V, Components.V{ .vx = 0, .vy = 0 });
        }
        printRow("addComponent V (migrate)", n, timer.lap());
    }

    // --- removeComponent: P+V -> P ---
    {
        var world = World.init(allocator);
        defer world.deinit();

        var ents: std.ArrayList(slime.Entity) = .{};
        defer ents.deinit(allocator);
        try ents.ensureTotalCapacity(allocator, n);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = try world.spawn(&.{ Components.P, Components.V }, .{
                Components.P{ .x = 0, .y = 0 },
                Components.V{ .vx = 0, .vy = 0 },
            });
            try ents.append(allocator, e);
        }

        var timer = try std.time.Timer.start();
        for (ents.items) |e| {
            try world.removeComponent(e, Components.V);
        }
        printRow("removeComponent V (migrate)", n, timer.lap());
    }

    // --- despawn ---
    {
        var world = World.init(allocator);
        defer world.deinit();

        var ents: std.ArrayList(slime.Entity) = .{};
        defer ents.deinit(allocator);
        try ents.ensureTotalCapacity(allocator, n);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = try world.spawn(&.{ Components.P, Components.V }, .{
                Components.P{ .x = 0, .y = 0 },
                Components.V{ .vx = 0, .vy = 0 },
            });
            try ents.append(allocator, e);
        }

        var timer = try std.time.Timer.start();
        for (ents.items) |e| {
            world.despawn(e);
        }
        printRow("despawn", n, timer.lap());
    }

    std.debug.print(
        \\
        \\done.
        \\
    , .{});
}
