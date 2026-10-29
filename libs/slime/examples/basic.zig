const std = @import("std");
const slime = @import("slime");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { vx: f32, vy: f32 };
const Gravity = struct { pull: f32 };
const Landed = struct { at: f32 };

fn gravitySystem(world: *slime.World) !void {
    const pull = world.getResource(Gravity).?.pull;
    var q = world.query(&.{Velocity});
    while (q.next()) |chunk| for (chunk.slice(Velocity)) |*v| {
        v.vy -= pull;
    };
}

fn moveSystem(world: *slime.World) !void {
    var q = world.query(&.{ Position, Velocity });
    while (q.next()) |chunk| for (chunk.slice(Position), chunk.slice(Velocity)) |*p, v| {
        p.x += v.vx;
        p.y += v.vy;
    };
}

fn landSystem(world: *slime.World) !void {
    var q = world.query(&.{Position});
    while (q.next()) |chunk| for (chunk.entities(), chunk.slice(Position)) |e, p| {
        if (p.y >= 0) continue;
        try world.commands().despawn(e);
        try world.sendEvent(Landed{ .at = p.x });
    };
}

fn reportSystem(world: *slime.World) !void {
    for (world.readEvents(Landed)) |landed| std.debug.print("  landed at x={d:.2}\n", .{landed.at});
}

pub fn main(init: std.process.Init) !void {
    var world = slime.World.init(init.gpa, init.io);
    defer world.deinit();
    try world.addResource(Gravity{ .pull = 0.5 });
    try world.addEvent(Landed);

    _ = try world.spawn(.{ Position{ .x = 0, .y = 10 }, Velocity{ .vx = 0.1, .vy = 0 } });
    _ = try world.spawn(.{ Position{ .x = 5, .y = 1 }, Velocity{ .vx = -0.05, .vy = 0.2 } });

    var update = slime.Schedule.init(init.gpa);
    defer update.deinit();
    try update.order(.{ .physics, .report });
    try update.add(reportSystem, .{ .in = .report });
    var physics = update.chain(.{ .in = .physics });
    try physics.add(gravitySystem, .{ .read = Gravity, .write = Velocity });
    try physics.add(moveSystem, .{ .read = Velocity, .write = Position });
    try physics.add(landSystem, .{ .read = Position });
    _ = try update.plan();

    for (0..4) |frame| {
        try update.run(&world);
        world.updateEvents();
        std.debug.print("frame {d}: {d} entities in the air\n", .{ frame, world.count() });
    }
}
