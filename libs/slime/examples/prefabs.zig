//! Load prefabs from binary and JSON, spawn entities, run a tiny schedule.

const std = @import("std");
const slime = @import("slime");

const Components = struct {
    pub const Position = struct { x: f32, y: f32 };

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const binary_blob = try slime.prefab.encodePrefabBinary(Components, allocator, 1, &.{ Components.Position, Components.Velocity }, .{
        Components.Position{ .x = 0, .y = 0 },
        Components.Velocity{ .vx = 0.2, .vy = 0.05 },
    });
    defer allocator.free(binary_blob);

    const json_text =
        \\{"id":2,"components":{"Position":{"x":100,"y":50},"Velocity":{"vx":-0.1,"vy":0}}}
    ;

    var world = World.init(allocator);
    defer world.deinit();

    var fbs_bin = std.io.fixedBufferStream(binary_blob);
    var prefab_bin = try slime.prefab.readPrefabBinary(allocator, fbs_bin.reader());
    defer prefab_bin.deinit(allocator);

    var prefab_json = try slime.prefab.readPrefabJson(Components, allocator, json_text);
    defer prefab_json.deinit(allocator);

    _ = try world.spawnPrefab(prefab_bin.asRef());
    _ = try world.spawnPrefab(prefab_bin.asRef());
    _ = try world.spawnPrefab(prefab_json.asRef());

    var sched = Schedule.init(allocator);
    defer sched.deinit();
    try sched.addWithMasks(
        &.{ Components.Position, Components.Velocity },
        &.{Components.Position},
        struct {
            fn run(w: *World) !void {
                var q = w.query(&.{ Components.Position, Components.Velocity });
                while (q.next()) |hit| {
                    if (w.getMut(hit.entity, Components.Position)) |p| {
                        if (w.get(hit.entity, Components.Velocity)) |v| {
                            p.x += v.vx;
                            p.y += v.vy;
                        }
                    }
                }
            }
        }.run,
    );
    try sched.run(&world);

    var q = world.query(&.{Components.Position});
    std.debug.print("prefab example - entities: ", .{});
    var first = true;
    while (q.next()) |hit| {
        if (!first) std.debug.print(", ", .{});
        first = false;
        const p = world.get(hit.entity, Components.Position).?;
        std.debug.print("({d:.1},{d:.1})", .{ p.x, p.y });
    }
    std.debug.print("\n", .{});
}
