const std = @import("std");

pub const Entity = @import("entity.zig").Entity;
pub const EntitySlot = @import("entity.zig").EntitySlot;

pub const registry = @import("registry.zig");
pub const World = @import("world.zig").World;
pub const WorldError = @import("world.zig").Error;

pub const Archetype = @import("archetype.zig").Archetype;
pub const ArchetypeId = @import("archetype.zig").ArchetypeId;

pub const Column = @import("column.zig").Column;

pub const serialize = @import("serialize.zig");
pub const assertBundleSerializable = serialize.assertBundleSerializable;
pub const assertSerializable = serialize.assertSerializable;
pub const schedule = @import("schedule.zig");
pub const Schedule = schedule.Schedule;
pub const Masks = schedule.Masks;
pub const masksConflict = schedule.masksConflict;
pub const events = @import("events.zig");
pub const prefab = @import("prefab.zig");

test "ecs spawn migrate query" {
    const C = struct {
        pub const Position = struct { x: f32, y: f32 };
        pub const Velocity = struct { vx: f32, vy: f32 };
    };

    var world = World(C).init(std.testing.allocator);
    defer world.deinit();

    const e0 = try world.spawn(&.{C.Velocity}, .{C.Velocity{ .vx = 3, .vy = 4 }});

    try world.addComponent(e0, C.Position, .{ .x = 10, .y = 20 });

    const p = world.get(e0, C.Position).?;
    try std.testing.expectApproxEqAbs(@as(f32, 10), p.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 20), p.y, 1e-6);

    if (world.getMut(e0, C.Velocity)) |v| {
        v.vx = 0.5;
    }

    var q = world.query(&.{ C.Position, C.Velocity });
    var seen: usize = 0;
    while (q.next()) |hit| {
        try std.testing.expect(world.isAlive(hit.entity));
        seen += 1;
        _ = hit.archetype;
        _ = hit.row;
    }
    try std.testing.expectEqual(@as(usize, 1), seen);

    world.despawn(e0);
    try std.testing.expect(!world.isAlive(e0));
}

test "serialize roundtrip" {
    const T = struct { a: i32, b: f64 };
    var buf: [@sizeOf(T)]u8 = undefined;
    const v: T = .{ .a = -7, .b = 2.5 };
    _ = serialize.writeBytes(T, v, &buf);
    const out = serialize.readBytes(T, &buf);
    try std.testing.expectEqual(v.a, out.a);
    try std.testing.expectEqual(v.b, out.b);
}

test "comptime serialize hooks detection" {
    const With = struct {
        pub const A = struct {
            x: i32,
            pub fn serialize(self: A, writer: anytype) !void {
                try writer.writeAll(std.mem.asBytes(&self.x));
            }
            pub fn deserialize(reader: anytype) !A {
                var x: i32 = undefined;
                try reader.readNoEof(std.mem.asBytes(&x));
                return .{ .x = x };
            }
        };
    };
    try std.testing.expect(serialize.hasCustomSerialization(With.A));
    const Plain = struct { y: f32 };
    try std.testing.expect(!serialize.hasCustomSerialization(Plain));
}

test "world snapshot roundtrip" {
    const C = struct {
        pub const P = struct { x: f32, y: f32 };
        pub const V = struct { vx: f32, vy: f32 };
    };

    var world = World(C).init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn(&.{ C.P, C.V }, .{
        C.P{ .x = 1, .y = 2 },
        C.V{ .vx = 3, .vy = 4 },
    });
    _ = e;

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try world.writeSnapshot(buf.writer(std.testing.allocator));

    world.reset();
    var fbs = std.io.fixedBufferStream(buf.items);
    try world.readSnapshot(fbs.reader());

    try std.testing.expectEqual(@as(usize, 1), world.archetypes.items.len);
    var q = world.query(&.{C.P});
    const hit = q.next().?;
    const p = world.get(hit.entity, C.P).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1), p.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2), p.y, 1e-6);
}

test "mask conflict rules" {
    const a = Masks{ .read_mask = 0b001, .write_mask = 0b010 };
    const b = Masks{ .read_mask = 0b100, .write_mask = 0b010 };
    try std.testing.expect(masksConflict(a, b)); // write/write

    const c = Masks{ .read_mask = 0b001, .write_mask = 0 };
    const d = Masks{ .read_mask = 0, .write_mask = 0b001 };
    try std.testing.expect(masksConflict(c, d)); // read/write

    const e = Masks{ .read_mask = 0b1, .write_mask = 0 };
    const f = Masks{ .read_mask = 0b10, .write_mask = 0 };
    try std.testing.expect(!masksConflict(e, f));
}

test "chunked query and column slice" {
    const C = struct {
        pub const P = struct { x: f32, y: f32 };
        pub const V = struct { vx: f32, vy: f32 };
    };

    var world = World(C).init(std.testing.allocator);
    defer world.deinit();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        _ = try world.spawn(&.{ C.P, C.V }, .{
            C.P{ .x = @floatFromInt(i), .y = 0 },
            C.V{ .vx = 0, .vy = 0 },
        });
    }

    var total: usize = 0;
    var qc = world.queryChunked(&.{ C.P, C.V }, 16);
    while (qc.next()) |ch| {
        total += ch.len;
        const pos = world.columnSlice(C.P, ch.archetype_id, ch.start_row, ch.len) orelse {
            return error.ColumnSlice;
        };
        try std.testing.expectEqual(ch.len, pos.len);
        try std.testing.expectEqual(ch.len, ch.entities.len);
    }
    try std.testing.expectEqual(@as(usize, 50), total);
}

test "parallel schedule runs" {
    const C = struct {
        pub const P = struct { x: f32 };
        pub const V = struct { y: f32 };
    };

    var world = World(C).init(std.testing.allocator);
    defer world.deinit();
    _ = try world.spawn(&.{ C.P, C.V }, .{ C.P{ .x = 1 }, C.V{ .y = 2 } });

    var sched = Schedule(C).init(std.testing.allocator);
    defer sched.deinit();

    try sched.addWithMasks(&.{C.P}, &.{C.P}, struct {
        fn s(w: *World(C)) !void {
            _ = w;
        }
    }.s);
    try sched.addWithMasks(&.{C.V}, &.{C.V}, struct {
        fn s(w: *World(C)) !void {
            _ = w;
        }
    }.s);

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = std.testing.allocator });
    defer pool.deinit();

    try sched.runParallel(&world, &pool);
}

test "perf spawn and query" {
    const C = struct {
        pub const P = struct { x: f32, y: f32 };
        pub const V = struct { vx: f32, vy: f32 };
    };

    var world = World(C).init(std.testing.allocator);
    defer world.deinit();

    const n: usize = 10_000;
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = try world.spawn(&.{ C.P, C.V }, .{
            C.P{ .x = @floatFromInt(i), .y = 0 },
            C.V{ .vx = 0, .vy = 0 },
        });
    }
    const spawn_ns = timer.lap();

    timer.reset();
    var q = world.query(&.{ C.P, C.V });
    var count: usize = 0;
    while (q.next()) |_| count += 1;
    const query_ns = timer.lap();

    try std.testing.expectEqual(n, count);
    try std.testing.expect(spawn_ns < 5_000_000_000);
    try std.testing.expect(query_ns < 1_000_000_000);
}

test "registry decl name lookup" {
    const C = struct {
        pub const Alpha = struct { n: i32 };
        pub const Beta = struct { m: f32 };
    };
    try std.testing.expectEqual(@as(registry.ComponentId, 0), registry.idForDeclName(C, "Alpha").?);
    try std.testing.expectEqual(@as(registry.ComponentId, 1), registry.idForDeclName(C, "Beta").?);
    try std.testing.expect(registry.idForDeclName(C, "Nope") == null);
    try std.testing.expectEqualStrings("Alpha", registry.declNameForId(C, 0));
    try std.testing.expectEqualStrings("Beta", registry.declNameForId(C, 1));
}

test "perf chunked iteration" {
    const C = struct {
        pub const P = struct { x: f32, y: f32 };
        pub const V = struct { vx: f32, vy: f32 };
    };

    var world = World(C).init(std.testing.allocator);
    defer world.deinit();

    const n: usize = 50_000;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = try world.spawn(&.{ C.P, C.V }, .{
            C.P{ .x = @floatFromInt(i), .y = 0 },
            C.V{ .vx = 0, .vy = 0 },
        });
    }

    var timer = try std.time.Timer.start();

    var q = world.query(&.{ C.P, C.V });
    var c1: usize = 0;
    while (q.next()) |_| c1 += 1;
    const per_entity_ns = timer.lap();

    timer.reset();
    var qc = world.queryChunked(&.{ C.P, C.V }, 256);
    var c2: usize = 0;
    while (qc.next()) |ch| {
        c2 += ch.len;
        const slice = world.columnSlice(C.P, ch.archetype_id, ch.start_row, ch.len).?;
        for (slice) |*p| p.x += 1;
    }
    const chunked_ns = timer.lap();

    try std.testing.expectEqual(n, c1);
    try std.testing.expectEqual(n, c2);
    try std.testing.expect(per_entity_ns < 2_000_000_000);
    try std.testing.expect(chunked_ns < 2_000_000_000);
}

test "column storage grows exponentially not by one" {
    const Col = @import("column.zig").Column;
    var col = Col.init(std.testing.allocator, @sizeOf(u32), @alignOf(u32));
    defer col.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = try col.pushUninitialized(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1000), col.len);
    // 8 -> ... -> 1024 is first power-of-two capacity that fits 1000 rows
    try std.testing.expectEqual(@as(usize, 1024), col.capacity);
}

test {
    _ = @import("prefab_tests.zig");
}
