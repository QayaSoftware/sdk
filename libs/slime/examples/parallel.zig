//! Parallel schedule: `Thread.Pool` + mask batching (systems that do not conflict run together).

const std = @import("std");
const slime = @import("slime");

const Components = struct {
    pub const P = struct { x: f32 };
    pub const V = struct { y: f32 };
};

const World = slime.World(Components);
const Schedule = slime.schedule.Schedule(Components);

fn incP(world: *World) !void {
    var q = world.query(&.{Components.P});
    while (q.next()) |hit| {
        if (world.getMut(hit.entity, Components.P)) |p| p.x += 1;
    }
}

fn incV(world: *World) !void {
    var q = world.query(&.{Components.V});
    while (q.next()) |hit| {
        if (world.getMut(hit.entity, Components.V)) |v| v.y += 2;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        _ = try world.spawn(&.{ Components.P, Components.V }, .{
            Components.P{ .x = 0 },
            Components.V{ .y = 0 },
        });
    }

    var sched = Schedule.init(allocator);
    defer sched.deinit();
    try sched.addWithMasks(&.{Components.P}, &.{Components.P}, incP);
    try sched.addWithMasks(&.{Components.V}, &.{Components.V}, incV);

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator, .n_jobs = 4 });
    defer pool.deinit();

    try sched.runParallel(&world, &pool);

    var sum_p: f32 = 0;
    var sum_v: f32 = 0;
    var qp = world.query(&.{Components.P});
    while (qp.next()) |hit| sum_p += world.get(hit.entity, Components.P).?.x;
    var qv = world.query(&.{Components.V});
    while (qv.next()) |hit| sum_v += world.get(hit.entity, Components.V).?.y;

    std.debug.print("parallel example - entities: {}, sum(P.x)={d:.0} (expect {}), sum(V.y)={d:.0} (expect {})\n", .{
        i,
        sum_p,
        @as(f32, @floatFromInt(i)),
        sum_v,
        @as(f32, @floatFromInt(i * 2)),
    });
}
