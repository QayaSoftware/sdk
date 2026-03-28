const std = @import("std");
const slime = @import("slime");

pub fn main() !void {
    const C = struct {
        pub const Position = struct { x: f32, y: f32 };
        pub const Velocity = struct { vx: f32, vy: f32 };
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = slime.World(C).init(allocator);
    defer world.deinit();

    const e = try world.spawn(&.{ C.Position, C.Velocity }, .{
        C.Position{ .x = 0, .y = 0 },
        C.Velocity{ .vx = 1, .vy = 0 },
    });

    if (world.getMut(e, C.Position)) |p| {
        p.x += p.y;
    }

    var q = world.query(&.{C.Position});
    while (q.next()) |hit| {
        std.debug.print("{any}\n", .{hit.entity});
    }
}
