const std = @import("std");
const slime = @import("root.zig");
const World = slime.World;
const Schedule = slime.Schedule;
const System = slime.System;

const testing = std.testing;

const Position = struct { x: f32 };
const Velocity = struct { vx: f32 };
const Big = struct { m: [16]f32 };
const Hit = struct { damage: u32 };
const Hits = struct { total: u32 = 0 };

/// The letters of the systems that ran, in order.
const Trace = struct {
    buffer: [64]u8 = undefined,
    len: usize = 0,

    fn text(self: *const Trace) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// A system that writes `letter` to the trace; each letter is its own system.
fn mark(comptime letter: u8) System {
    return struct {
        fn run(world: *World) !void {
            const trace = world.getResourcePtr(Trace).?;
            trace.buffer[trace.len] = letter;
            trace.len += 1;
        }
    }.run;
}

/// A system that does nothing; each number is its own system.
fn idle(comptime number: u8) System {
    return struct {
        const which = number;
        fn run(_: *World) !void {}
    }.run;
}

fn traced(schedule: *Schedule) ![]const u8 {
    var world: World = .init(testing.allocator, testing.io);
    defer world.deinit();
    try world.addResource(Trace{});
    try schedule.run(&world);
    const trace = world.getResource(Trace).?;
    return testing.allocator.dupe(u8, trace.text());
}

fn expectTrace(schedule: *Schedule, expected: []const u8) !void {
    const text = try traced(schedule);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "systems order themselves with after and before, wherever they were added" {
    var schedule = Schedule.init(testing.allocator);
    defer schedule.deinit();
    try schedule.add(mark('c'), .{ .after = mark('b'), .write = Trace });
    try schedule.add(mark('a'), .{ .before = mark('b'), .write = Trace });
    try schedule.add(mark('b'), .{ .write = Trace });
    try expectTrace(&schedule, "abc");
}

test "sets order whole groups, named by enum values, enum literals or types" {
    const Phase = enum { early, late };
    const Render = struct {};
    var schedule = Schedule.init(testing.allocator);
    defer schedule.deinit();
    try schedule.order(.{ Phase.early, .late, Render });
    try schedule.add(mark('r'), .{ .in = Render, .write = Trace });
    try schedule.add(mark('l'), .{ .in = Phase.late, .write = Trace });
    try schedule.add(mark('e'), .{ .in = .early, .write = Trace });
    try schedule.add(mark('f'), .{ .in = Phase.early, .write = Trace });
    try expectTrace(&schedule, "eflr");
}

test "a chain runs its systems in the order added, ordered as a whole" {
    var schedule = Schedule.init(testing.allocator);
    defer schedule.deinit();
    var physics = schedule.chain(.{ .in = .physics, .after = mark('s') });
    try physics.add(mark('x'), .{ .write = Trace });
    try physics.add(mark('y'), .{ .write = .{Trace} });
    try physics.add(mark('z'), .{ .write = &.{Trace} });
    try schedule.add(mark('t'), .{ .after = .physics, .write = Trace });
    try schedule.add(mark('s'), .{ .write = Trace });
    try expectTrace(&schedule, "sxyzt");
}

test "sets nest, and a nested set keeps its parent's order" {
    var schedule = Schedule.init(testing.allocator);
    defer schedule.deinit();
    try schedule.order(.{ .update, .render });
    try schedule.configureSet(.physics, .{ .in = .update });
    try schedule.configureSet(.ai, .{ .in = .update, .before = .physics });
    try schedule.add(mark('d'), .{ .in = .render, .write = Trace });
    try schedule.add(mark('p'), .{ .in = .physics, .write = Trace });
    try schedule.add(mark('a'), .{ .in = .ai, .write = Trace });
    try expectTrace(&schedule, "apd");
}

test "order splits batches even between systems that do not conflict" {
    var schedule = Schedule.init(testing.allocator);
    defer schedule.deinit();
    try schedule.add(idle(0), .{});
    try schedule.add(idle(1), .{ .after = idle(0) });
    try schedule.add(idle(2), .{});
    try schedule.add(idle(3), .{ .write = Position });
    try schedule.add(idle(4), .{ .read = Position });
    const plan = try schedule.plan();
    try testing.expectEqual(@as(usize, 2), plan.batches.len);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 3 }, plan.batches[0]);
    try testing.expectEqualSlices(u32, &.{ 1, 4 }, plan.batches[1]);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, plan.order);
}

test "order against a system or set nobody added does nothing" {
    var schedule = Schedule.init(testing.allocator);
    defer schedule.deinit();
    try schedule.add(mark('a'), .{ .after = .{ mark('q'), .missing }, .before = idle(9), .write = Trace });
    try expectTrace(&schedule, "a");
}

test "cycles are reported where the schedule is planned" {
    var schedule = Schedule.init(testing.allocator);
    defer schedule.deinit();
    try schedule.add(mark('a'), .{ .after = mark('b') });
    try schedule.add(mark('b'), .{ .after = mark('a') });
    try testing.expectError(error.ScheduleCycle, schedule.plan());
    var world: World = .init(testing.allocator, testing.io);
    defer world.deinit();
    try testing.expectError(error.ScheduleCycle, schedule.run(&world));

    schedule.reset();
    try schedule.configureSet(.outer, .{ .in = .inner });
    try schedule.configureSet(.inner, .{ .in = .outer });
    try testing.expectError(error.ScheduleCycle, schedule.plan());
}

test "systems are known by their full names, even when the optimizer merges identical ones" {
    var schedule = Schedule.init(testing.allocator);
    defer schedule.deinit();
    try schedule.add(Systems.movePositions, .{});
    try schedule.add(idle(0), .{});
    try schedule.add(idle(1), .{ .after = idle(0) });
    try testing.expectEqualStrings("schedule_tests.Systems.movePositions", schedule.systems.items[0].name);
    try testing.expect(!std.mem.eql(u8, schedule.systems.items[1].name, schedule.systems.items[2].name));
    try testing.expectEqual(@as(usize, 2), (try schedule.plan()).batches.len);
}

test "adding after planning plans again" {
    var schedule = Schedule.init(testing.allocator);
    defer schedule.deinit();
    try schedule.add(mark('b'), .{ .write = Trace });
    try expectTrace(&schedule, "b");
    try schedule.add(mark('a'), .{ .before = mark('b'), .write = Trace });
    try expectTrace(&schedule, "ab");
    try testing.expectEqual(@as(usize, 2), schedule.count());
}

const Systems = struct {
    fn movePositions(world: *World) !void {
        var q = world.query(&.{ Position, Velocity });
        while (q.next()) |chunk| for (chunk.slice(Position), chunk.slice(Velocity)) |*p, v| {
            p.x += v.vx;
        };
    }

    fn bumpBig(world: *World) !void {
        var q = world.query(&.{Big});
        while (q.next()) |chunk| for (chunk.slice(Big)) |*big| {
            big.m[0] += 1;
        };
    }

    fn despawnMoved(world: *World) !void {
        var q = world.query(&.{Position});
        while (q.next()) |chunk| for (chunk.entities(), chunk.slice(Position)) |e, p| {
            if (p.x >= 2) try world.commands().despawn(e);
        };
    }

    fn sendHits(world: *World) !void {
        for (0..100) |i| try world.sendEvent(Hit{ .damage = @intCast(i) });
    }

    fn readHits(world: *World) !void {
        var total: u32 = 0;
        for (world.readEvents(Hit)) |hit| total += hit.damage;
        world.getResourcePtr(Hits).?.total += total;
    }

    fn fail(_: *World) !void {
        return error.SystemFailed;
    }
};

test "runParallel runs batches, applies their commands and reports errors" {
    var world: World = .init(testing.allocator, testing.io);
    defer world.deinit();
    try world.addEvent(Hit);
    try world.addResource(Hits{});
    for (0..50) |_| _ = try world.spawn(.{ Position{ .x = 0 }, Velocity{ .vx = 1 } });
    for (0..50) |_| _ = try world.spawn(.{Big{ .m = @splat(0) }});

    var schedule = Schedule.init(testing.allocator);
    defer schedule.deinit();
    try schedule.add(Systems.movePositions, .{ .read = Velocity, .write = Position });
    try schedule.add(Systems.bumpBig, .{ .write = Big });
    try schedule.add(Systems.sendHits, .{});
    try schedule.add(Systems.readHits, .{ .write = Hits });
    try schedule.add(Systems.despawnMoved, .{ .read = Position });
    const plan = try schedule.plan();
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, plan.batches[0]);
    try testing.expectEqualSlices(u32, &.{4}, plan.batches[1]);

    try schedule.runParallel(&world, testing.io);
    try testing.expectEqual(@as(usize, 100), world.count());
    try testing.expectEqual(@as(u32, 0), world.getResource(Hits).?.total);
    world.updateEvents();
    try schedule.runParallel(&world, testing.io);
    try testing.expectEqual(@as(usize, 50), world.count());
    try testing.expectEqual(@as(u32, 4950), world.getResource(Hits).?.total);
    var q = world.query(&.{Big});
    try testing.expectEqual(@as(f32, 2), q.next().?.slice(Big)[0].m[0]);

    try schedule.add(Systems.fail, .{ .write = Hit });
    try schedule.add(Systems.fail, .{ .write = Velocity });
    try testing.expectError(error.SystemFailed, schedule.runParallel(&world, testing.io));
    try testing.expect(!world.parallel);
}
