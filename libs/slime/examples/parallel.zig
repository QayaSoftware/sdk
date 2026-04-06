const std = @import("std");
const slime = @import("slime");

const P = struct { x: f32 };
const V = struct { y: f32 };

fn incP(world: *slime.World) !void {
    var q = world.query(&.{P});
    while (q.next()) |hit| {
        if (world.getMut(hit.entity, P)) |p| p.x += 1;
    }
}

fn incV(world: *slime.World) !void {
    var q = world.query(&.{V});
    while (q.next()) |hit| {
        if (world.getMut(hit.entity, V)) |v| v.y += 2;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = slime.World.init(allocator);
    defer world.deinit();

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        _ = try world.spawn(&.{ P, V }, .{
            P{ .x = 0 },
            V{ .y = 0 },
        });
    }

    var sched = slime.Schedule.init(allocator);
    defer sched.deinit();
    try sched.addWithMasks(&.{P}, &.{P}, incP);
    try sched.addWithMasks(&.{V}, &.{V}, incV);

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator, .n_jobs = 4 });
    defer pool.deinit();

    try sched.runParallel(&world, &pool);

    var sum_p: f32 = 0;
    var sum_v: f32 = 0;
    var qp = world.query(&.{P});
    while (qp.next()) |hit| sum_p += world.get(hit.entity, P).?.x;
    var qv = world.query(&.{V});
    while (qv.next()) |hit| sum_v += world.get(hit.entity, V).?.y;

    std.debug.print("parallel example - entities: {}, sum(P.x)={d:.0} (expect {}), sum(V.y)={d:.0} (expect {})\n", .{
        i,
        sum_p,
        @as(f32, @floatFromInt(i)),
        sum_v,
        @as(f32, @floatFromInt(i * 2)),
    });
}
