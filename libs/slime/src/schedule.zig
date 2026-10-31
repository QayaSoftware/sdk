//! Systems and the order they run in. A schedule is one thing that runs at
//! one time, such as startup or every frame; inside it, systems order
//! themselves against each other and against sets, so no one place has to
//! know every phase:
//!
//!     try update.order(.{ .input, .physics, .render });
//!     try update.add(integrate, .{ .in = .physics, .after = applyGravity, .read = .{Velocity}, .write = .{Position} });
//!
//!     var physics = update.chain(.{ .in = .physics });
//!     try physics.add(applyGravity, .{ .write = .{Velocity} });
//!     try physics.add(collide, .{ .write = .{Position} });
//!
//! A system is named by its function, which must be known at compile time.
//! A set is named by an enum value or literal, so `Phase.render` and
//! `.render` are the same set, or by a type, for a set no other code can
//! name by accident. A system's options are `.in` (sets), `.after` and
//! `.before` (systems and sets), and `.read` and `.write` (component and
//! resource types); each takes one value or a tuple of them.
//!
//! Systems that nothing orders run in the order they were added if they
//! conflict, one writing what the other reads or writes, and together
//! under `runParallel` if they do not. Events need no declaring, since
//! reading them never races with sending them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const World = @import("world.zig").World;
const registry = @import("registry.zig");
const Mask = registry.Mask;

const log = std.log.scoped(.slime);

pub const System = *const fn (*World) anyerror!void;

/// A system or a set, by its name.
pub const Label = union(enum) {
    system: []const u8,
    set: []const u8,

    /// The label `value` stands for: a system function, an enum value or
    /// literal, or a type.
    pub fn of(comptime value: anytype) Label {
        const T = @TypeOf(value);
        if (T == type) return .{ .set = @typeName(value) };
        switch (@typeInfo(T)) {
            .enum_literal, .@"enum" => return .{ .set = @tagName(value) },
            .@"fn" => return .{ .system = systemName(value) },
            .pointer => |pointer| if (@typeInfo(pointer.child) == .@"fn") return .{ .system = systemName(value) },
            else => {},
        }
        @compileError("slime: " ++ @typeName(T) ++ " is neither a system nor a set; use a system function, an enum value or literal, or a type");
    }

    fn matches(self: Label, schedule: *const Schedule, member: []const bool, sets: []const []const u8, index: usize) bool {
        return switch (self) {
            .system => |name| std.mem.eql(u8, schedule.systems.items[index].name, name),
            .set => |name| member[index * sets.len + indexOf(sets, name).?],
        };
    }
};

pub const PlanError = Allocator.Error || error{ScheduleCycle};

pub const Schedule = struct {
    gpa: Allocator,
    /// Holds the sets' names that chains put together.
    arena: std.heap.ArenaAllocator,
    systems: std.ArrayList(Entry) = .empty,
    /// Pairs of labels where the first runs before the second.
    constraints: std.ArrayList(Constraint) = .empty,
    /// Pairs of sets where the first is in the second.
    parents: std.ArrayList(Parent) = .empty,
    /// Worked out from the above by `plan`.
    planned: ?Plan = null,

    const Entry = struct {
        run: System,
        /// The function's full name, which stays apart from any other
        /// function's even where the optimizer merges identical ones.
        name: []const u8,
        read: Mask,
        write: Mask,
        in: []const []const u8,

        fn conflicts(self: Entry, other: Entry) bool {
            return self.write.intersects(other.write.unite(other.read)) or self.read.intersects(other.write);
        }
    };

    const Constraint = struct { first: Label, then: Label };
    const Parent = struct { set: []const u8, parent: []const u8 };

    const Options = struct {
        read: Mask = .empty,
        write: Mask = .empty,
        in: []const []const u8 = &.{},
        after: []const Label = &.{},
        before: []const Label = &.{},
    };

    pub const Plan = struct {
        /// Every system, in an order that keeps every constraint.
        order: []const u32,
        /// The same systems in batches that may run together.
        batches: []const []const u32,
    };

    pub fn init(gpa: Allocator) Schedule {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Schedule) void {
        self.forgetPlan();
        self.systems.deinit(self.gpa);
        self.constraints.deinit(self.gpa);
        self.parents.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Removes every system, set and constraint.
    pub fn reset(self: *Schedule) void {
        self.forgetPlan();
        self.systems.clearRetainingCapacity();
        self.constraints.clearRetainingCapacity();
        self.parents.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    /// How many systems there are.
    pub fn count(self: *const Schedule) usize {
        return self.systems.items.len;
    }

    /// Adds `system` with `options`: `.in`, `.after`, `.before`, `.read` and
    /// `.write`, each optional.
    pub fn add(self: *Schedule, comptime system: System, comptime options: anytype) Allocator.Error!void {
        comptime checkOptions(@TypeOf(options), &.{ "in", "after", "before", "read", "write" });
        try self.addSystem(system, comptime systemName(system), systemOptions(options), .{});
    }

    /// Systems added through the chain each run after the one added before
    /// it, and all take `options`: `.in`, `.after` and `.before`.
    pub fn chain(self: *Schedule, comptime options: anytype) Chain {
        comptime checkOptions(@TypeOf(options), &.{ "in", "after", "before" });
        return .{
            .schedule = self,
            .in = comptime setsOf(options, "in"),
            .after = comptime labelsOf(options, "after"),
            .before = comptime labelsOf(options, "before"),
        };
    }

    pub const Chain = struct {
        schedule: *Schedule,
        in: []const []const u8,
        after: []const Label,
        before: []const Label,
        previous: ?[]const u8 = null,

        pub fn add(self: *Chain, comptime system: System, comptime options: anytype) Allocator.Error!void {
            comptime checkOptions(@TypeOf(options), &.{ "in", "after", "before", "read", "write" });
            const name = comptime systemName(system);
            var own = systemOptions(options);
            own.in = try std.mem.concat(self.schedule.arena.allocator(), []const u8, &.{ self.in, own.in });
            var previous: [1]Label = undefined;
            const extra: []const Label = if (self.previous) |earlier| blk: {
                previous[0] = .{ .system = earlier };
                break :blk &previous;
            } else &.{};
            const after = try std.mem.concat(self.schedule.arena.allocator(), Label, &.{ self.after, extra });
            try self.schedule.addSystem(system, name, own, .{ .after = after, .before = self.before });
            self.previous = name;
        }
    };

    /// Puts `set` in other sets and orders it, with `options` `.in`,
    /// `.after` and `.before`.
    pub fn configureSet(self: *Schedule, comptime set: anytype, comptime options: anytype) Allocator.Error!void {
        comptime checkOptions(@TypeOf(options), &.{ "in", "after", "before" });
        const name = comptime setName(set);
        const in = comptime setsOf(options, "in");
        const after = comptime labelsOf(options, "after");
        const before = comptime labelsOf(options, "before");
        try self.parents.ensureUnusedCapacity(self.gpa, in.len);
        try self.constraints.ensureUnusedCapacity(self.gpa, after.len + before.len);
        self.forgetPlan();
        for (in) |parent| self.parents.appendAssumeCapacity(.{ .set = name, .parent = parent });
        for (after) |label| self.constraints.appendAssumeCapacity(.{ .first = label, .then = .{ .set = name } });
        for (before) |label| self.constraints.appendAssumeCapacity(.{ .first = .{ .set = name }, .then = label });
    }

    /// Runs each of the systems and sets in the tuple `labels` after the one
    /// before it.
    pub fn order(self: *Schedule, comptime labels: anytype) Allocator.Error!void {
        const list = comptime labelsFrom(labels);
        if (list.len < 2) return;
        try self.constraints.ensureUnusedCapacity(self.gpa, list.len - 1);
        self.forgetPlan();
        for (list[0 .. list.len - 1], list[1..]) |first, then| self.constraints.appendAssumeCapacity(.{ .first = first, .then = then });
    }

    /// Order shared by a chain's systems.
    const Extra = struct {
        after: []const Label = &.{},
        before: []const Label = &.{},
    };

    fn addSystem(self: *Schedule, system: System, name: []const u8, options: Options, extra: Extra) Allocator.Error!void {
        try self.systems.ensureUnusedCapacity(self.gpa, 1);
        try self.constraints.ensureUnusedCapacity(self.gpa, options.after.len + options.before.len + extra.after.len + extra.before.len);
        self.forgetPlan();
        self.systems.appendAssumeCapacity(.{ .run = system, .name = name, .read = options.read, .write = options.write, .in = options.in });
        const label: Label = .{ .system = name };
        for ([_][]const Label{ options.after, extra.after }) |labels| for (labels) |first| self.constraints.appendAssumeCapacity(.{ .first = first, .then = label });
        for ([_][]const Label{ options.before, extra.before }) |labels| for (labels) |then| self.constraints.appendAssumeCapacity(.{ .first = label, .then = then });
    }

    /// Works out the order and the parallel batches now, so a cycle shows up
    /// where the schedule is built rather than where it first runs. Running
    /// does it when nothing has since.
    pub fn plan(self: *Schedule) PlanError!*const Plan {
        if (self.planned) |*done| return done;
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const systems = self.systems.items;
        const n = systems.len;

        var set_names: std.ArrayList([]const u8) = .empty;
        for (systems) |system| for (system.in) |set| try addName(arena, &set_names, set);
        for (self.parents.items) |pair| {
            try addName(arena, &set_names, pair.set);
            try addName(arena, &set_names, pair.parent);
        }
        for (self.constraints.items) |pair| for ([_]Label{ pair.first, pair.then }) |label| switch (label) {
            .set => |set| try addName(arena, &set_names, set),
            .system => {},
        };
        const sets = set_names.items;

        const within = try arena.alloc(bool, sets.len * sets.len);
        @memset(within, false);
        for (self.parents.items) |pair| within[indexOf(sets, pair.set).? * sets.len + indexOf(sets, pair.parent).?] = true;
        for (0..sets.len) |k| for (0..sets.len) |i| {
            if (!within[i * sets.len + k]) continue;
            for (0..sets.len) |j| if (within[k * sets.len + j]) {
                within[i * sets.len + j] = true;
            };
        };
        for (sets, 0..) |set, i| if (within[i * sets.len + i]) {
            log.warn("set {s} is inside itself", .{set});
            return error.ScheduleCycle;
        };

        const member = try arena.alloc(bool, n * sets.len);
        @memset(member, false);
        for (systems, 0..) |system, i| for (system.in) |set| {
            const s = indexOf(sets, set).?;
            member[i * sets.len + s] = true;
            for (0..sets.len) |parent| if (within[s * sets.len + parent]) {
                member[i * sets.len + parent] = true;
            };
        };

        const before = try arena.alloc(bool, n * n);
        @memset(before, false);
        const firsts = try arena.alloc(bool, n);
        const thens = try arena.alloc(bool, n);
        for (self.constraints.items) |pair| {
            for (firsts, thens, 0..) |*first, *then, i| {
                first.* = pair.first.matches(self, member, sets, i);
                then.* = pair.then.matches(self, member, sets, i);
            }
            for (firsts, 0..) |first, i| {
                if (!first) continue;
                for (thens, 0..) |then, j| if (then and j != i) {
                    before[i * n + j] = true;
                };
            }
        }

        const waiting = try arena.alloc(u32, n);
        @memset(waiting, 0);
        for (0..n) |i| for (0..n) |j| if (before[i * n + j]) {
            waiting[j] += 1;
        };
        const sequence = try self.gpa.alloc(u32, n);
        errdefer self.gpa.free(sequence);
        const placed = try arena.alloc(bool, n);
        @memset(placed, false);
        for (sequence) |*slot| {
            const next = for (0..n) |i| {
                if (!placed[i] and waiting[i] == 0) break i;
            } else {
                for (0..n) |i| if (!placed[i]) log.warn("{s} is ordered in a cycle", .{systems[i].name});
                return error.ScheduleCycle;
            };
            slot.* = @intCast(next);
            placed[next] = true;
            for (0..n) |j| if (before[next * n + j]) {
                waiting[j] -= 1;
            };
        }

        const level = try arena.alloc(u32, n);
        var levels: u32 = 0;
        for (sequence, 0..) |i, k| {
            var at: u32 = 0;
            for (sequence[0..k]) |earlier| {
                if (before[earlier * n + i] or systems[earlier].conflicts(systems[i])) at = @max(at, level[earlier] + 1);
            }
            level[i] = at;
            levels = @max(levels, at + 1);
        }
        const batches = try self.gpa.alloc([]const u32, levels);
        var made: usize = 0;
        errdefer {
            for (batches[0..made]) |batch| self.gpa.free(batch);
            self.gpa.free(batches);
        }
        for (batches, 0..) |*batch, at| {
            var size: usize = 0;
            for (sequence) |i| size += @intFromBool(level[i] == at);
            const members = try self.gpa.alloc(u32, size);
            var next: usize = 0;
            for (sequence) |i| if (level[i] == at) {
                members[next] = i;
                next += 1;
            };
            batch.* = members;
            made += 1;
        }
        self.planned = .{ .order = sequence, .batches = batches };
        return &self.planned.?;
    }

    /// Runs the systems one after another, applying the world's commands
    /// after each.
    pub fn run(self: *Schedule, world: *World) anyerror!void {
        const planned = try self.plan();
        for (planned.order) |index| {
            try self.systems.items[index].run(world);
            try world.applyCommands();
        }
    }

    /// Runs each batch's systems concurrently, then applies the world's
    /// commands. Returns the first error a system returned, once its batch
    /// finishes.
    pub fn runParallel(self: *Schedule, world: *World, io: std.Io) anyerror!void {
        const planned = try self.plan();
        for (planned.batches) |batch| {
            if (batch.len == 1) {
                try self.systems.items[batch[0]].run(world);
            } else {
                var failure: std.atomic.Value(u16) = .init(0);
                world.parallel = true;
                defer world.parallel = false;
                var group: std.Io.Group = .init;
                for (batch) |index| {
                    const system = self.systems.items[index].run;
                    group.concurrent(io, runOne, .{ world, system, &failure }) catch runOne(world, system, &failure);
                }
                try group.await(io);
                world.parallel = false;
                const failed = failure.load(.acquire);
                if (failed != 0) return @errorFromInt(failed);
            }
            try world.applyCommands();
        }
    }

    fn runOne(world: *World, system: System, failure: *std.atomic.Value(u16)) void {
        system(world) catch |err| {
            _ = failure.cmpxchgStrong(0, @intFromError(err), .release, .monotonic);
        };
    }

    fn forgetPlan(self: *Schedule) void {
        const planned = self.planned orelse return;
        for (planned.batches) |batch| self.gpa.free(batch);
        self.gpa.free(planned.batches);
        self.gpa.free(planned.order);
        self.planned = null;
    }
};

fn addName(arena: Allocator, names: *std.ArrayList([]const u8), name: []const u8) Allocator.Error!void {
    if (indexOf(names.items, name) == null) try names.append(arena, name);
}

fn indexOf(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, i| if (std.mem.eql(u8, candidate, name)) return i;
    return null;
}

fn checkOptions(comptime Options: type, comptime allowed: []const []const u8) void {
    for (@typeInfo(Options).@"struct".field_names) |field_name| {
        for (allowed) |name| {
            if (std.mem.eql(u8, field_name, name)) break;
        } else @compileError("slime: unknown option ." ++ field_name);
    }
}

fn systemOptions(comptime options: anytype) Schedule.Options {
    return .{
        .read = registry.maskOf(comptime typesOf(options, "read")),
        .write = registry.maskOf(comptime typesOf(options, "write")),
        .in = comptime setsOf(options, "in"),
        .after = comptime labelsOf(options, "after"),
        .before = comptime labelsOf(options, "before"),
    };
}

fn setName(comptime value: anytype) []const u8 {
    return switch (Label.of(value)) {
        .set => |name| name,
        .system => @compileError("slime: a system cannot be used as a set"),
    };
}

fn labelsOf(comptime options: anytype, comptime field: []const u8) []const Label {
    if (!@hasField(@TypeOf(options), field)) return &.{};
    return labelsFrom(@field(options, field));
}

/// One label or a tuple of them.
fn labelsFrom(comptime value: anytype) []const Label {
    const info = @typeInfo(@TypeOf(value));
    if (info != .@"struct" or !(info.@"struct".is_tuple or info.@"struct".field_names.len == 0)) return &.{Label.of(value)};
    var labels: [info.@"struct".field_names.len]Label = undefined;
    for (&labels, 0..) |*label, i| label.* = Label.of(value[i]);
    const final = labels;
    return &final;
}

fn setsOf(comptime options: anytype, comptime field: []const u8) []const []const u8 {
    const labels = labelsOf(options, field);
    var names: [labels.len][]const u8 = undefined;
    for (labels, &names) |label, *name| name.* = switch (label) {
        .set => |set| set,
        .system => @compileError("slime: ." ++ field ++ " takes sets, not systems"),
    };
    const final = names;
    return &final;
}

fn typesOf(comptime options: anytype, comptime field: []const u8) []const type {
    if (!@hasField(@TypeOf(options), field)) return &.{};
    const value = @field(options, field);
    const T = @TypeOf(value);
    if (T == type) return &.{value};
    switch (@typeInfo(T)) {
        .pointer => return value,
        .@"struct" => |shape| if (shape.is_tuple or shape.field_types.len == 0) {
            var types: [shape.field_types.len]type = undefined;
            for (&types, 0..) |*slot, i| slot.* = value[i];
            const final = types;
            return &final;
        },
        else => {},
    }
    @compileError("slime: ." ++ field ++ " takes a type or a tuple of types");
}

fn Identity(comptime system: System) type {
    return struct {
        const of = system;
    };
}

/// `system`'s full name, such as `game.physics.integrate`: unique to the
/// function, and readable when the compiler spells it out.
fn systemName(comptime system: System) []const u8 {
    const full = @typeName(Identity(system));
    const start = (std.mem.lastIndexOfScalar(u8, full, '&') orelse return full) + 1;
    const end = std.mem.indexOfScalarPos(u8, full, start, ')') orelse return full;
    return full[start..end];
}
