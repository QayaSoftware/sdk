const std = @import("std");
const slime = @import("root.zig");
const World = slime.World;
const Entity = slime.Entity;
const registry = slime.registry;

const testing = std.testing;

const Position = struct { x: f32, y: f32 };
const Velocity = struct { vx: f32, vy: f32 };
const Tag = struct {};
const Big = struct { m: [16]f32 };
const Wide = struct { v: @Vector(8, f32) align(32) };
const Hit = struct { damage: u32 };

fn testWorld() World {
    return .init(testing.allocator, testing.io);
}

fn bigValue(start: f32) Big {
    var big: Big = undefined;
    for (&big.m, 0..) |*f, i| f.* = start + @as(f32, @floatFromInt(i));
    return big;
}

test "spawn, migrate and query" {
    var world = testWorld();
    defer world.deinit();

    const e = try world.spawn(.{Velocity{ .vx = 3, .vy = 4 }});
    try world.add(e, Position{ .x = 10, .y = 20 });
    try testing.expectEqual(Position{ .x = 10, .y = 20 }, world.get(e, Position).?);
    world.getPtr(e, Velocity).?.vx = 0.5;

    var q = world.query(&.{ Position, Velocity });
    var seen: usize = 0;
    while (q.next()) |chunk| {
        for (chunk.entities(), chunk.slice(Position), chunk.slice(Velocity)) |entity, p, v| {
            try testing.expect(entity.eql(e));
            try testing.expectEqual(@as(f32, 10), p.x);
            try testing.expectEqual(@as(f32, 0.5), v.vx);
            seen += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), seen);

    try testing.expect(world.despawn(e));
    try testing.expect(!world.isAlive(e));
    try testing.expectEqual(@as(usize, 0), world.count());
}

test "the same rules everywhere: add fails when present, set overwrites, remove reports, dead entities fail" {
    var world = testWorld();
    defer world.deinit();
    const e = try world.spawn(.{Position{ .x = 1, .y = 1 }});

    try world.add(e, Velocity{ .vx = 1, .vy = 2 });
    try testing.expectError(error.AlreadyExists, world.add(e, Velocity{ .vx = 0, .vy = 0 }));
    try world.set(e, Velocity{ .vx = 3, .vy = 4 });
    try testing.expectEqual(Velocity{ .vx = 3, .vy = 4 }, world.get(e, Velocity).?);
    try testing.expect(try world.remove(e, Velocity));
    try testing.expect(!try world.remove(e, Velocity));

    try testing.expect(world.despawn(e));
    try testing.expect(!world.despawn(e));
    try testing.expect(!try world.remove(e, Position));
    try testing.expectError(error.DeadEntity, world.add(e, Tag{}));
    try testing.expectError(error.DeadEntity, world.set(e, Tag{}));
    try testing.expect(world.get(e, Position) == null);
    try testing.expect(world.getPtr(e, Position) == null);
    try testing.expect(world.componentIds(e) == null);

    try world.addResource(Hit{ .damage = 1 });
    try testing.expectError(error.AlreadyExists, world.addResource(Hit{ .damage = 2 }));
    try world.setResource(Hit{ .damage = 3 });
    try testing.expectEqual(@as(u32, 3), world.getResource(Hit).?.damage);
    try testing.expect(world.removeResource(Hit));
    try testing.expect(!world.removeResource(Hit));
    try testing.expect(world.getResource(Hit) == null);

    try world.addEvent(Hit);
    try testing.expectError(error.AlreadyExists, world.addEvent(Hit));
    try testing.expectError(error.UnknownEvent, world.sendEvent(Position{ .x = 0, .y = 0 }));
    try testing.expectEqual(@as(usize, 0), world.readEvents(Position).len);
}

test "component ids are unique however many types there are" {
    const Numbered = struct {
        fn Type(comptime n: usize) type {
            return struct {
                pub const number = n;
                value: u32,
            };
        }
    };
    var seen: std.AutoHashMapUnmanaged(registry.ComponentId, void) = .empty;
    defer seen.deinit(testing.allocator);
    inline for (0..100) |n| try testing.expect(!(try seen.getOrPut(testing.allocator, registry.id(Numbered.Type(n)))).found_existing);

    var world = testWorld();
    defer world.deinit();
    const e = try world.spawn(.{Numbered.Type(8){ .value = 1234 }});
    try testing.expect(world.get(e, Numbered.Type(82)) == null);

    var count: usize = 0;
    var all = registry.iterator();
    while (all.next()) |_| count += 1;
    try testing.expect(count >= 100);
}

test "components larger than 16 bytes survive every migration" {
    var world = testWorld();
    defer world.deinit();
    const big = bigValue(1);
    const e = try world.spawn(.{ big, Tag{} });
    const other = try world.spawn(.{ bigValue(100), Tag{} });

    _ = try world.remove(e, Tag);
    try testing.expectEqual(big, world.get(e, Big).?);
    try world.add(e, Position{ .x = 1, .y = 2 });
    try testing.expectEqual(big, world.get(e, Big).?);
    _ = try world.remove(other, Tag);
    try world.add(other, Position{ .x = 3, .y = 4 });
    try testing.expectEqual(big, world.get(e, Big).?);
    try testing.expectEqual(bigValue(100), world.get(other, Big).?);
}

test "columns keep their alignment through migrations, even from an allocator that honours align 1" {
    var odd: OddAllocator = .{ .child = testing.allocator };
    var world: World = .init(odd.allocator(), testing.io);
    defer world.deinit();
    const e = try world.spawn(.{Position{ .x = 1, .y = 2 }});
    try world.add(e, Velocity{ .vx = 0, .vy = 0 });
    try world.add(e, Wide{ .v = @splat(3) });
    try testing.expect(std.mem.isAligned(@intFromPtr(world.getPtr(e, Velocity).?), @alignOf(Velocity)));
    try testing.expect(std.mem.isAligned(@intFromPtr(world.getPtr(e, Wide).?), 32));
    try testing.expectEqual(@as(f32, 3), world.get(e, Wide).?.v[7]);

    var q = world.query(&.{ Position, Velocity });
    const chunk = q.next().?;
    try testing.expectEqual(@as(usize, 1), chunk.slice(Position).len);
}

test "tag components cost no storage and move like any other" {
    var world = testWorld();
    defer world.deinit();
    const e = try world.spawn(.{ Position{ .x = 1, .y = 1 }, Tag{} });
    try testing.expect(world.has(e, Tag));
    try testing.expect(try world.remove(e, Tag));
    try testing.expect(!world.has(e, Tag));
    try world.add(e, Tag{});
    try testing.expectEqual(@as(usize, 1), world.queryWithout(&.{Tag}, &.{Velocity}).count());
    try testing.expect(world.despawn(e));
}

test "despawn moves the last row into the hole" {
    var world = testWorld();
    defer world.deinit();
    var entities: [5]Entity = undefined;
    for (&entities, 0..) |*e, i| e.* = try world.spawn(.{Position{ .x = @floatFromInt(i), .y = 0 }});
    try testing.expect(world.despawn(entities[1]));
    for (entities, 0..) |e, i| {
        if (i == 1) continue;
        try testing.expectEqual(@as(f32, @floatFromInt(i)), world.get(e, Position).?.x);
    }
    try testing.expectEqual(@as(usize, 4), world.count());
}

test "a reused slot does not revive old handles" {
    var world = testWorld();
    defer world.deinit();
    const old = try world.spawn(.{Position{ .x = 1, .y = 1 }});
    _ = world.despawn(old);
    const new = try world.spawn(.{Position{ .x = 2, .y = 2 }});
    try testing.expectEqual(old.index, new.index);
    try testing.expect(!world.isAlive(old));
    try testing.expect(world.get(old, Position) == null);
    try testing.expectEqual(@as(f32, 2), world.get(new, Position).?.x);
}

test "reset keeps old handles dead" {
    var world = testWorld();
    defer world.deinit();
    const old = try world.spawn(.{Position{ .x = 1, .y = 1 }});
    const gone = try world.spawn(.{Position{ .x = 5, .y = 5 }});
    _ = world.despawn(gone);
    world.reset();
    const new = try world.spawn(.{Position{ .x = 99, .y = 99 }});
    _ = try world.spawn(.{Position{ .x = 98, .y = 98 }});
    try testing.expect(!world.isAlive(old));
    try testing.expect(!world.isAlive(gone));
    try testing.expect(world.isAlive(new));
    try testing.expectEqual(@as(usize, 2), world.count());
}

test "moving back and forth reuses the archetypes it found" {
    var world = testWorld();
    defer world.deinit();
    const e = try world.spawn(.{Position{ .x = 1, .y = 1 }});
    for (0..10) |_| {
        try world.add(e, Velocity{ .vx = 0, .vy = 0 });
        _ = try world.remove(e, Velocity);
    }
    try testing.expectEqual(@as(usize, 2), world.archetypes.items.len);
}

test "queries skip archetypes that have an excluded component" {
    var world = testWorld();
    defer world.deinit();
    _ = try world.spawn(.{Position{ .x = 1, .y = 1 }});
    _ = try world.spawn(.{ Position{ .x = 2, .y = 2 }, Velocity{ .vx = 0, .vy = 0 } });
    _ = try world.spawn(.{ Position{ .x = 3, .y = 3 }, Tag{} });
    try testing.expectEqual(@as(usize, 3), world.query(&.{Position}).count());
    try testing.expectEqual(@as(usize, 2), world.queryWithout(&.{Position}, &.{Tag}).count());

    var q = world.query(&.{Position});
    var with_velocity: usize = 0;
    while (q.next()) |chunk| if (chunk.optional(Velocity)) |velocities| {
        with_velocity += velocities.len;
    };
    try testing.expectEqual(@as(usize, 1), with_velocity);
}

test "runtime access by id" {
    var world = testWorld();
    defer world.deinit();
    const e = try world.spawn(.{ Position{ .x = 1, .y = 2 }, Velocity{ .vx = 3, .vy = 4 } });
    const ids = world.componentIds(e).?;
    try testing.expectEqual(@as(usize, 2), ids.len);
    for (ids) |cid| try testing.expectEqual(registry.info(cid).size, world.getRaw(e, cid).?.len);
    try world.setRaw(e, registry.id(Position), std.mem.asBytes(&Position{ .x = 7, .y = 8 }));
    try testing.expectEqual(@as(f32, 7), world.get(e, Position).?.x);
    try testing.expect(try world.removeRaw(e, registry.id(Velocity)));
    try testing.expect(!try world.removeRaw(e, registry.id(Velocity)));
    try testing.expect(!world.has(e, Velocity));
}

test "commands apply in order and skip the dead" {
    var world = testWorld();
    defer world.deinit();
    const a = try world.spawn(.{Position{ .x = 1, .y = 1 }});
    const b = try world.spawn(.{Position{ .x = 2, .y = 2 }});
    var prefab = try slime.Prefab.from(testing.allocator, .{ Tag{}, Velocity{ .vx = 6, .vy = 6 } });
    defer prefab.deinit();
    const commands = world.commands();
    try commands.spawn(.{ Position{ .x = 3, .y = 3 }, bigValue(5) });
    try commands.spawnPrefab(&prefab);
    try commands.set(a, Velocity{ .vx = 1, .vy = 1 });
    try commands.despawn(b);
    try commands.set(b, Velocity{ .vx = 9, .vy = 9 });
    try commands.remove(b, Position);
    try commands.remove(a, Position);
    try testing.expectEqual(@as(usize, 2), world.count());
    try world.applyCommands();
    try testing.expectEqual(@as(usize, 3), world.count());
    try testing.expect(!world.isAlive(b));
    try testing.expect(world.has(a, Velocity) and !world.has(a, Position));
    var big = world.query(&.{Big});
    try testing.expectEqual(bigValue(5), big.next().?.slice(Big)[0]);
    var tagged = world.query(&.{Tag});
    try testing.expectEqual(@as(f32, 6), tagged.next().?.slice(Velocity)[0].vx);
    try testing.expectEqual(@as(usize, 0), world.queue.bytes.items.len);
}

test "allocation failures leave the world usable and leak nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var world: World = .init(gpa, testing.io);
            defer world.deinit();
            const a = try world.spawn(.{Position{ .x = 1, .y = 1 }});
            const b = try world.spawn(.{Position{ .x = 2, .y = 2 }});
            try world.add(a, Velocity{ .vx = 0, .vy = 0 });
            _ = try world.remove(a, Velocity);
            _ = world.despawn(b);
            _ = try world.spawn(.{ Position{ .x = 3, .y = 3 }, Velocity{ .vx = 0, .vy = 0 } });
            try world.commands().despawn(a);
            try world.applyCommands();
            try world.addResource(Position{ .x = 0, .y = 0 });
            try world.setResource(Position{ .x = 1, .y = 0 });
            try world.addEvent(Velocity);
            try world.sendEvent(Velocity{ .vx = 1, .vy = 1 });
        }
    }.run, .{});
}

test "a failed spawn leaves no entity behind" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var world: World = .init(failing.allocator(), testing.io);
    defer world.deinit();
    _ = try world.spawn(.{Position{ .x = 1, .y = 1 }});
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, world.spawn(.{Velocity{ .vx = 1, .vy = 1 }}));
    failing.fail_index = std.math.maxInt(usize);
    const e = try world.spawn(.{Velocity{ .vx = 1, .vy = 1 }});
    try testing.expectEqual(@as(usize, 2), world.count());
    try testing.expectEqual(@as(u32, 1), e.index);
}

test "resources own what they copy, deinit it, and borrow what they are lent" {
    var world = testWorld();
    defer world.deinit();

    var log: std.ArrayList(u8) = .empty;
    try log.appendSlice(testing.allocator, "owned by the world");
    try world.addResource(log);
    try testing.expectEqualStrings("owned by the world", world.getResourcePtr(std.ArrayList(u8)).?.items);
    var replacement: std.ArrayList(u8) = .empty;
    try replacement.appendSlice(testing.allocator, "replaced");
    try world.setResource(replacement);
    try testing.expectEqualStrings("replaced", world.getResource(std.ArrayList(u8)).?.items);

    var borrowed: Position = .{ .x = 1, .y = 1 };
    try world.addResourcePtr(Position, &borrowed, .borrowed);
    world.getResourcePtr(Position).?.x = 5;
    try testing.expectEqual(@as(f32, 5), borrowed.x);
    try testing.expect(world.removeResource(Position));
    try testing.expectEqual(@as(f32, 5), borrowed.x);

    const owned = try testing.allocator.create(Velocity);
    owned.* = .{ .vx = 2, .vy = 2 };
    try world.addResourcePtr(Velocity, owned, .owned);
    try testing.expectEqual(@as(f32, 2), world.getResource(Velocity).?.vx);
}

test "events arrive the frame after they are sent, once" {
    var world = testWorld();
    defer world.deinit();
    try world.addEvent(Hit);
    try world.sendEvent(Hit{ .damage = 7 });
    try world.sendEvent(Hit{ .damage = 8 });
    try testing.expectEqual(@as(usize, 0), world.readEvents(Hit).len);

    world.updateEvents();
    const frame = world.readEvents(Hit);
    try world.sendEvent(Hit{ .damage = 9 });
    try testing.expectEqual(@as(usize, 2), frame.len);
    try testing.expectEqual(@as(u32, 7), frame[0].damage);
    try testing.expectEqual(@as(u32, 8), world.readEvents(Hit)[1].damage);

    world.updateEvents();
    try testing.expectEqual(@as(usize, 1), world.readEvents(Hit).len);
    try testing.expectEqual(@as(u32, 9), world.readEvents(Hit)[0].damage);
    world.updateEvents();
    try testing.expectEqual(@as(usize, 0), world.readEvents(Hit).len);
    try testing.expect(world.hasEvent(Hit) and !world.hasEvent(Tag));
}

test "entities format" {
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{f}", .{Entity{ .index = 3, .generation = 7 }});
    try testing.expectEqualStrings("Entity(3,7)", text);
}

/// Returns odd addresses for align-1 requests, which the `Allocator`
/// contract permits.
const OddAllocator = struct {
    child: std.mem.Allocator,

    fn allocator(self: *OddAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *OddAllocator = @ptrCast(@alignCast(ctx));
        if (alignment.toByteUnits() != 1) return self.child.rawAlloc(len, alignment, ret);
        const ptr = self.child.rawAlloc(len + 1, .@"16", ret) orelse return null;
        return ptr + 1;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *OddAllocator = @ptrCast(@alignCast(ctx));
        return alignment.toByteUnits() != 1 and self.child.rawResize(memory, alignment, len, ret);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *OddAllocator = @ptrCast(@alignCast(ctx));
        if (alignment.toByteUnits() == 1) return null;
        return self.child.rawRemap(memory, alignment, len, ret);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *OddAllocator = @ptrCast(@alignCast(ctx));
        if (alignment.toByteUnits() != 1) return self.child.rawFree(memory, alignment, ret);
        self.child.rawFree((memory.ptr - 1)[0 .. memory.len + 1], .@"16", ret);
    }
};
