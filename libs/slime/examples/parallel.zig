const std = @import("std");
const slime = @import("slime");

const P = struct { x: f32 };
const V = struct { y: f32 };
const Spawned = struct { count: u32 };
const Tally = struct { spawned: u32 = 0 };

fn incP(world: *slime.World) !void {
    var q = world.query(&.{P});
    while (q.next()) |chunk| for (chunk.slice(P)) |*p| {
        p.x += 1;
    };
}

fn incV(world: *slime.World) !void {
    var q = world.query(&.{V});
    while (q.next()) |chunk| for (chunk.slice(V)) |*v| {
        v.y += 2;
    };
}

fn spawnMore(world: *slime.World) !void {
    try world.commands().spawn(.{P{ .x = 0 }});
    try world.sendEvent(Spawned{ .count = 1 });
}

fn countSpawned(world: *slime.World) !void {
    for (world.readEvents(Spawned)) |event| world.getResourcePtr(Tally).?.spawned += event.count;
}

pub fn main(init: std.process.Init) !void {
    var world = slime.World.init(init.gpa, init.io);
    defer world.deinit();
    try world.addEvent(Spawned);
    try world.addResource(Tally{});

    for (0..500) |_| _ = try world.spawn(.{ P{ .x = 0 }, V{ .y = 0 } });

    var schedule = slime.Schedule.init(init.gpa);
    defer schedule.deinit();
    try schedule.add(incP, .{ .write = P });
    try schedule.add(incV, .{ .write = V });
    try schedule.add(spawnMore, .{});
    try schedule.add(countSpawned, .{ .write = Tally });

    for (0..3) |_| {
        try schedule.runParallel(&world, init.io);
        world.updateEvents();
    }

    var sum_p: f32 = 0;
    var sum_v: f32 = 0;
    var qp = world.query(&.{P});
    while (qp.next()) |chunk| for (chunk.slice(P)) |p| {
        sum_p += p.x;
    };
    var qv = world.query(&.{V});
    while (qv.next()) |chunk| for (chunk.slice(V)) |v| {
        sum_v += v.y;
    };

    std.debug.print("parallel example - entities: {d} (expect 503), sum(P.x)={d:.0} (expect 1503), sum(V.y)={d:.0} (expect 3000), spawns counted: {d} (expect 2; the third arrives next frame)\n", .{
        world.count(),
        sum_p,
        sum_v,
        world.getResource(Tally).?.spawned,
    });
}
