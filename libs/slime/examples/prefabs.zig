const std = @import("std");
const slime = @import("slime");

const Position = struct { x: f32, y: f32 };

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const binary_blob = try slime.prefab.encodePrefabBinary(allocator, 1, &.{ Position, Velocity }, .{
        Position{ .x = 0, .y = 0 },
        Velocity{ .vx = 0.2, .vy = 0.05 },
    });
    defer allocator.free(binary_blob);

    var world = slime.World.init(allocator);
    defer world.deinit();

    var fbs_bin = std.io.fixedBufferStream(binary_blob);
    var prefab_bin = try slime.prefab.readPrefabBinary(allocator, fbs_bin.reader());
    defer prefab_bin.deinit(allocator);

    _ = try world.spawnPrefab(prefab_bin.asRef());
    _ = try world.spawnPrefab(prefab_bin.asRef());

    var sched = slime.Schedule.init(allocator);
    defer sched.deinit();
    try sched.addWithMasks(
        &.{ Position, Velocity },
        &.{Position},
        struct {
            fn run(w: *slime.World) !void {
                var q = w.query(&.{ Position, Velocity });
                while (q.next()) |hit| {
                    if (w.getMut(hit.entity, Position)) |p| {
                        if (w.get(hit.entity, Velocity)) |v| {
                            p.x += v.vx;
                            p.y += v.vy;
                        }
                    }
                }
            }
        }.run,
    );
    try sched.run(&world);

    var q = world.query(&.{Position});
    std.debug.print("prefab example - entities: ", .{});
    var first = true;
    while (q.next()) |hit| {
        if (!first) std.debug.print(", ", .{});
        first = false;
        const p = world.get(hit.entity, Position).?;
        std.debug.print("({d:.1},{d:.1})", .{ p.x, p.y });
    }
    std.debug.print("\n", .{});
}
