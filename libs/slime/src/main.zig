const std = @import("std");
const slime = @import("slime");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { vx: f32, vy: f32 };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = slime.World.init(allocator);
    defer world.deinit();

    const e = try world.spawn(&.{ Position, Velocity }, .{
        Position{ .x = 0, .y = 0 },
        Velocity{ .vx = 1, .vy = 0 },
    });

    if (world.getMut(e, Position)) |p| {
        p.x += p.y;
    }

    var q = world.query(&.{Position});
    while (q.next()) |hit| {
        std.debug.print("{any}\n", .{hit.entity});
    }
}
