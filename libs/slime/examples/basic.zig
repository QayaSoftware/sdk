const std = @import("std");
const slime = @import("slime");

const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    vx: f32,
    vy: f32,

    pub fn serialize(self: Velocity, writer: anytype) !void {
        try writer.writeAll(std.mem.asBytes(&self.vx));
        try writer.writeAll(std.mem.asBytes(&self.vy));
    }

    pub fn deserialize(reader: anytype) !Velocity {
        var vx: f32 = undefined;
        var vy: f32 = undefined;
        try reader.readNoEof(std.mem.asBytes(&vx));
        try reader.readNoEof(std.mem.asBytes(&vy));
        return .{ .vx = vx, .vy = vy };
    }
};

fn gravitySystem(world: *slime.World) !void {
    var q = world.query(&.{ Position, Velocity });
    while (q.next()) |hit| {
        if (world.getMut(hit.entity, Velocity)) |v| {
            v.vy -= 0.01;
        }
    }
}

fn moveSystem(world: *slime.World) !void {
    var q = world.query(&.{ Position, Velocity });
    while (q.next()) |hit| {
        if (world.getMut(hit.entity, Position)) |p| {
            if (world.get(hit.entity, Velocity)) |v| {
                p.x += v.vx;
                p.y += v.vy;
            }
        }
    }
}

pub fn main(init: std.process.Init ) !void {
    const allocator = init.gpa;
    var world = slime.World.init(allocator);
    defer world.deinit();

    _ = try world.spawn(&.{ Position, Velocity }, .{
        Position{ .x = 0, .y = 10 },
        Velocity{ .vx = 0.1, .vy = 0 },
    });
    _ = try world.spawn(&.{ Position, Velocity }, .{
        Position{ .x = 5, .y = 3 },
        Velocity{ .vx = -0.05, .vy = 0.2 },
    });

    var sched = slime.Schedule.init(allocator);
    defer sched.deinit();
    try sched.addWithMasks(&.{Velocity}, &.{Velocity}, gravitySystem);
    try sched.addWithMasks(&.{ Position, Velocity }, &.{Position}, moveSystem);

    try sched.run(&world);

    world.reset();

    var q = world.query(&.{Position});
    var n: usize = 0;
    while (q.next()) |_| n += 1;
    std.debug.print("entity count after snapshot reload: {}\n", .{n});
}
