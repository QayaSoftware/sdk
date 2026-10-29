const std = @import("std");
const slime = @import("slime");

const Position = struct { x: f32 = 0, y: f32 = 0 };
const Velocity = struct { vx: f32 = 0, vy: f32 = 0 };
const Health = struct { current: i32 = 100, max: i32 = 100 };
const Enemy = struct {};

const library_json =
    \\{
    \\  "goblin": { "Position": { "y": 1 }, "Velocity": { "vx": 0.2 }, "Health": { "max": 30, "current": 30 }, "Enemy": {} },
    \\  "crate": { "Position": {}, "Health": { "max": 5, "current": 5 } }
    \\}
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    slime.register(&.{ Position, Velocity, Health, Enemy });

    var library: slime.PrefabLibrary = .init(gpa);
    defer library.deinit();
    var diagnostics: slime.prefab.Diagnostics = .{};
    var text: std.Io.Reader = .fixed(library_json);
    library.readJson(&text, &diagnostics) catch |err| {
        std.debug.print("prefab {s} (line {d}, column {d}): {t}\n", .{ diagnostics.where(), diagnostics.line, diagnostics.column, err });
        return err;
    };

    library.getPtr("goblin").?.getPtr(Health).?.max = 40;

    var world = slime.World.init(gpa, init.io);
    defer world.deinit();
    const goblin = try world.spawnPrefab(library.getPtr("goblin").?);
    _ = try world.spawnPrefab(library.getPtr("crate").?);

    world.getPtr(goblin, Position).?.x = 12;
    try library.set("moved goblin", try slime.Prefab.fromEntity(gpa, &world, goblin));

    for (library.getPtr("goblin").?.components.items) |component| {
        std.debug.print("goblin has {s} ({d} bytes, {d} fields)\n", .{ component.info.name, component.info.size, component.info.fields.len });
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try library.writeJson(&out.writer, .{ .whitespace = .indent_2 });
    std.debug.print("{s}\n", .{out.written()});

    var binary: std.Io.Writer.Allocating = .init(gpa);
    defer binary.deinit();
    try library.getPtr("crate").?.writeBinary(&binary.writer);
    var reader: std.Io.Reader = .fixed(binary.written());
    var crate = try slime.Prefab.readBinary(gpa, &reader, null);
    defer crate.deinit();
    std.debug.print("binary crate: {d} bytes, health {d}\n", .{ binary.written().len, crate.get(Health).?.max });
}
