//! Basic Slime example: components (optional custom serialization), world, systems, snapshot roundtrip.

const std = @import("std");
const slime = @import("slime");

const Components = struct {
    /// POD: snapshot uses memcpy when no custom hooks are defined.
    pub const Position = struct {
        x: f32,
        y: f32,
    };

    /// Custom wire format: length-prefixed f32s (illustrative).
    pub const Velocity = struct {
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
};

const World = slime.World(Components);
const Schedule = slime.schedule.Schedule(Components);

fn gravitySystem(world: *World) !void {
    var q = world.query(&.{ Components.Position, Components.Velocity });
    while (q.next()) |hit| {
        if (world.getMut(hit.entity, Components.Velocity)) |v| {
            v.vy -= 0.01;
        }
    }
}

fn moveSystem(world: *World) !void {
    var q = world.query(&.{ Components.Position, Components.Velocity });
    while (q.next()) |hit| {
        if (world.getMut(hit.entity, Components.Position)) |p| {
            if (world.get(hit.entity, Components.Velocity)) |v| {
                p.x += v.vx;
                p.y += v.vy;
            }
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = World.init(allocator);
    defer world.deinit();

    _ = try world.spawn(&.{ Components.Position, Components.Velocity }, .{
        Components.Position{ .x = 0, .y = 10 },
        Components.Velocity{ .vx = 0.1, .vy = 0 },
    });
    _ = try world.spawn(&.{ Components.Position, Components.Velocity }, .{
        Components.Position{ .x = 5, .y = 3 },
        Components.Velocity{ .vx = -0.05, .vy = 0.2 },
    });

    var sched = Schedule.init(allocator);
    defer sched.deinit();
    try sched.addWithMasks(&.{Components.Velocity}, &.{Components.Velocity}, gravitySystem);
    try sched.addWithMasks(&.{ Components.Position, Components.Velocity }, &.{Components.Position}, moveSystem);

    try sched.run(&world);

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    try world.writeSnapshot(buf.writer(allocator));
    world.reset();
    var fbs = std.io.fixedBufferStream(buf.items);
    try world.readSnapshot(fbs.reader());

    var q = world.query(&.{Components.Position});
    var n: usize = 0;
    while (q.next()) |_| n += 1;
    std.debug.print("entity count after snapshot reload: {}\n", .{n});
}
