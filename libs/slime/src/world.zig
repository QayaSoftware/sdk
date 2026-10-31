const std = @import("std");
const Allocator = std.mem.Allocator;
const Entity = @import("entity.zig").Entity;
const Archetype = @import("Archetype.zig");
const registry = @import("registry.zig");
const ComponentId = registry.ComponentId;
const Mask = registry.Mask;
const ResourcePool = @import("ResourcePool.zig");
const EventChannel = @import("EventChannel.zig").EventChannel;
const Prefab = @import("prefab.zig").Prefab;

pub const Error = error{
    DeadEntity,
    AlreadyExists,
    UnknownEvent,
};

/// The entities, their components, the resources and the events. Its
/// methods share one set of rules:
///
/// - `add…` fails with `error.AlreadyExists` when the thing is already
///   there; `set…` adds it or overwrites it.
/// - Changing a dead entity fails with `error.DeadEntity`; `despawn` and
///   `remove…` instead return whether they removed anything.
/// - `get…` returns a copy and `get…Ptr` a pointer, both null when missing.
/// - Anything that allocates can fail with `error.OutOfMemory`, leaving the
///   world as it was.
///
/// Spawning, despawning, and adding, setting or removing components,
/// resources and events change the world's structure: do it from one thread
/// at a time, and queue it with `commands` while `Schedule.runParallel` runs
/// systems. Components are plain data: they move by copying and are never
/// deinitialized.
pub const World = struct {
    gpa: Allocator,
    io: std.Io,
    archetypes: std.ArrayList(Archetype) = .empty,
    /// Each archetype's mask again, packed so a query sweeps them in order.
    masks: std.ArrayList(Mask) = .empty,
    by_mask: std.HashMapUnmanaged(Mask, u32, Mask.Context, std.hash_map.default_max_load_percentage) = .empty,
    /// One per entity slot; a free slot links to the next free one.
    records: std.ArrayList(Record) = .empty,
    free: u32 = Archetype.none,
    resources: ResourcePool = .empty,
    event_updates: std.ArrayList(*const fn (*World) void) = .empty,
    queue: Queue = .{},
    /// Set while `Schedule.runParallel` runs a batch.
    parallel: bool = false,

    pub const Ownership = ResourcePool.Ownership;

    const Record = struct {
        generation: u32,
        /// `Archetype.none` while the slot is free.
        archetype: u32,
        /// The next free slot while the slot is free.
        row: u32,
    };

    const Queue = struct {
        mutex: std.Io.Mutex = .init,
        bytes: std.ArrayList(u8) = .empty,
    };

    pub fn init(gpa: Allocator, io: std.Io) World {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *World) void {
        for (self.archetypes.items) |*archetype| archetype.deinit(self.gpa);
        self.archetypes.deinit(self.gpa);
        self.masks.deinit(self.gpa);
        self.by_mask.deinit(self.gpa);
        self.records.deinit(self.gpa);
        self.resources.deinit(self.gpa);
        self.event_updates.deinit(self.gpa);
        self.queue.bytes.deinit(self.gpa);
    }

    /// Despawns every entity and drops the queued commands, keeping the
    /// tables' memory for the next entities. Handles from before stay dead;
    /// resources and events stay.
    pub fn reset(self: *World) void {
        self.assertSerial();
        for (self.archetypes.items) |*archetype| archetype.len = 0;
        self.free = Archetype.none;
        var index = self.records.items.len;
        while (index > 0) {
            index -= 1;
            const slot = &self.records.items[index];
            const generation = if (slot.archetype == Archetype.none) slot.generation else slot.generation +% 1;
            slot.* = .{ .generation = generation, .archetype = Archetype.none, .row = self.free };
            self.free = @intCast(index);
        }
        self.queue.bytes.clearRetainingCapacity();
    }

    pub fn isAlive(self: *const World, e: Entity) bool {
        return self.record(e) != null;
    }

    /// How many entities are alive.
    pub fn count(self: *const World) usize {
        var total: usize = 0;
        for (self.archetypes.items) |archetype| total += archetype.len;
        return total;
    }

    /// Makes an entity from `bundle`, a tuple of component values such as
    /// `.{ Position{ .x = 1 }, Enemy{} }`.
    pub fn spawn(self: *World, bundle: anytype) Allocator.Error!Entity {
        const types = comptime registry.bundleTypes(@TypeOf(bundle));
        const index = try self.archetypeFor(registry.maskOf(types));
        const e = try self.allocate(index);
        const archetype = &self.archetypes.items[index];
        const row = archetype.len - 1;
        inline for (types, 0..) |T, i| {
            if (@sizeOf(T) != 0) archetype.ptr(T, archetype.columnIndex(registry.id(T)), row).* = bundle[i];
        }
        return e;
    }

    pub fn spawnPrefab(self: *World, prefab: *const Prefab) Allocator.Error!Entity {
        const index = try self.archetypeFor(prefab.mask);
        const e = try self.allocate(index);
        const archetype = &self.archetypes.items[index];
        const row = archetype.len - 1;
        for (prefab.components.items, archetype.columns) |component, column| @memcpy(column.bytes(row), component.bytes);
        return e;
    }

    /// Returns whether `e` was alive.
    pub fn despawn(self: *World, e: Entity) bool {
        self.assertSerial();
        const found = self.record(e) orelse return false;
        const archetype = &self.archetypes.items[found.archetype];
        if (archetype.swapRemove(found.row)) |moved| self.records.items[moved.index].row = found.row;
        self.records.items[e.index] = .{ .generation = e.generation +% 1, .archetype = Archetype.none, .row = self.free };
        self.free = e.index;
        return true;
    }

    pub fn has(self: *const World, e: Entity, comptime T: type) bool {
        return self.getRaw(e, registry.id(T)) != null;
    }

    pub fn get(self: *const World, e: Entity, comptime T: type) ?T {
        const value = self.getPtr(e, T) orelse return null;
        return value.*;
    }

    /// Valid until the world's structure next changes.
    pub fn getPtr(self: *const World, e: Entity, comptime T: type) ?*T {
        const found = self.record(e) orelse return null;
        const cid = registry.id(T);
        const archetype = &self.archetypes.items[found.archetype];
        if (!archetype.has(cid)) return null;
        return archetype.ptr(T, archetype.columnIndex(cid), found.row);
    }

    /// Adds `value`'s component to `e`.
    pub fn add(self: *World, e: Entity, value: anytype) (Allocator.Error || error{ DeadEntity, AlreadyExists })!void {
        const T = @TypeOf(value);
        if (self.has(e, T)) return error.AlreadyExists;
        self.write(T, try self.insertSlot(e, registry.id(T)), value);
    }

    /// Adds `value`'s component to `e`, or overwrites the one it has.
    pub fn set(self: *World, e: Entity, value: anytype) (Allocator.Error || error{DeadEntity})!void {
        const T = @TypeOf(value);
        if (self.getPtr(e, T)) |existing| {
            existing.* = value;
            return;
        }
        self.write(T, try self.insertSlot(e, registry.id(T)), value);
    }

    /// Returns whether `e` had a `T`.
    pub fn remove(self: *World, e: Entity, comptime T: type) Allocator.Error!bool {
        return self.removeRaw(e, registry.id(T));
    }

    /// Sets each of `prefab`'s components on `e`, moving it at most once.
    pub fn applyPrefab(self: *World, e: Entity, prefab: *const Prefab) (Allocator.Error || error{DeadEntity})!void {
        self.assertSerial();
        const found = self.record(e) orelse return error.DeadEntity;
        const mask = self.archetypes.items[found.archetype].mask.unite(prefab.mask);
        if (!mask.eql(self.archetypes.items[found.archetype].mask)) {
            const target = try self.archetypeFor(mask);
            try self.archetypes.items[target].reserve(self.gpa, 1);
            _ = self.move(e.index, found.archetype, target);
        }
        const moved = self.records.items[e.index];
        const archetype = &self.archetypes.items[moved.archetype];
        for (prefab.components.items) |component| @memcpy(archetype.columns[archetype.columnIndex(component.id)].bytes(moved.row), component.bytes);
    }

    /// The ids of `e`'s components, ascending.
    pub fn componentIds(self: *const World, e: Entity) ?[]const ComponentId {
        const found = self.record(e) orelse return null;
        return self.archetypes.items[found.archetype].ids;
    }

    /// The bytes of `e`'s `cid` component, which `registry.info(cid)`
    /// describes. Valid until the world's structure next changes.
    pub fn getRaw(self: *const World, e: Entity, cid: ComponentId) ?[]u8 {
        const found = self.record(e) orelse return null;
        const archetype = &self.archetypes.items[found.archetype];
        if (!archetype.has(cid)) return null;
        return archetype.columns[archetype.columnIndex(cid)].bytes(found.row);
    }

    /// Adds the `cid` component to `e` from `bytes`, or overwrites it.
    pub fn setRaw(self: *World, e: Entity, cid: ComponentId, bytes: []const u8) (Allocator.Error || error{DeadEntity})!void {
        std.debug.assert(bytes.len == registry.info(cid).size);
        if (self.getRaw(e, cid)) |existing| {
            @memcpy(existing, bytes);
            return;
        }
        const spot = try self.insertSlot(e, cid);
        const archetype = &self.archetypes.items[spot.archetype];
        @memcpy(archetype.columns[archetype.columnIndex(cid)].bytes(spot.row), bytes);
    }

    /// Returns whether `e` had the `cid` component.
    pub fn removeRaw(self: *World, e: Entity, cid: ComponentId) Allocator.Error!bool {
        self.assertSerial();
        const found = self.record(e) orelse return false;
        if (!self.archetypes.items[found.archetype].has(cid)) return false;
        const target = try self.removeEdge(found.archetype, cid);
        try self.archetypes.items[target].reserve(self.gpa, 1);
        _ = self.move(e.index, found.archetype, target);
        return true;
    }

    /// The entities with every type in `with`, a table at a time.
    pub fn query(self: *World, comptime with: []const type) Query {
        return self.queryWithout(with, &.{});
    }

    /// The entities with every type in `with` and none in `without`.
    pub fn queryWithout(self: *World, comptime with: []const type, comptime without: []const type) Query {
        return .{ .world = self, .with = registry.maskOf(with), .without = registry.maskOf(without) };
    }

    /// Walks the matching tables. Changing the world's structure while
    /// walking invalidates the chunks; queue the changes with `commands`.
    pub const Query = struct {
        world: *World,
        with: Mask,
        without: Mask,
        next_archetype: u32 = 0,

        pub fn next(self: *Query) ?Chunk {
            const masks = self.world.masks.items;
            while (self.next_archetype < masks.len) {
                const index = self.next_archetype;
                self.next_archetype += 1;
                const mask = masks[index];
                if (!mask.contains(self.with) or mask.intersects(self.without)) continue;
                const archetype = &self.world.archetypes.items[index];
                if (archetype.len == 0) continue;
                return .{ .archetype = archetype };
            }
            return null;
        }

        /// How many entities match, without moving the query.
        pub fn count(self: Query) usize {
            var copy = self;
            var total: usize = 0;
            while (copy.next()) |chunk| total += chunk.len();
            return total;
        }
    };

    /// Every entity of one table, its components as slices in row order.
    pub const Chunk = struct {
        archetype: *Archetype,

        pub fn len(self: Chunk) usize {
            return self.archetype.len;
        }

        pub fn entities(self: Chunk) []const Entity {
            return self.archetype.entities[0..self.archetype.len];
        }

        pub fn has(self: Chunk, comptime T: type) bool {
            return self.archetype.has(registry.id(T));
        }

        /// `T`'s column, which the query must guarantee.
        pub fn slice(self: Chunk, comptime T: type) []T {
            const cid = registry.id(T);
            std.debug.assert(self.archetype.has(cid));
            return self.archetype.slice(T, self.archetype.columnIndex(cid));
        }

        /// `T`'s column, if the table has one.
        pub fn optional(self: Chunk, comptime T: type) ?[]T {
            const cid = registry.id(T);
            if (!self.archetype.has(cid)) return null;
            return self.archetype.slice(T, self.archetype.columnIndex(cid));
        }
    };

    /// Structural changes to make later, from any thread: the schedule
    /// applies them after each system, or after each parallel batch, and
    /// `applyCommands` applies them on demand.
    pub fn commands(self: *World) Commands {
        return .{ .world = self };
    }

    pub const Commands = struct {
        world: *World,

        pub fn spawn(self: Commands, bundle: anytype) Allocator.Error!void {
            const types = comptime registry.bundleTypes(@TypeOf(bundle));
            var copies: @Tuple(types) = undefined;
            var size: usize = 1 + @sizeOf(u16);
            inline for (types, 0..) |T, i| {
                copies[i] = bundle[i];
                size += @sizeOf(ComponentId) + @sizeOf(T);
            }
            const bytes = try self.begin(size);
            defer self.end();
            append(bytes, Op.spawn);
            append(bytes, @as(u16, types.len));
            inline for (types, 0..) |T, i| {
                append(bytes, registry.id(T));
                bytes.appendSliceAssumeCapacity(std.mem.asBytes(&copies[i]));
            }
        }

        pub fn spawnPrefab(self: Commands, prefab: *const Prefab) Allocator.Error!void {
            var size: usize = 1 + @sizeOf(u16);
            for (prefab.components.items) |component| size += @sizeOf(ComponentId) + component.bytes.len;
            const bytes = try self.begin(size);
            defer self.end();
            append(bytes, Op.spawn);
            append(bytes, @as(u16, @intCast(prefab.components.items.len)));
            for (prefab.components.items) |component| {
                append(bytes, component.id);
                bytes.appendSliceAssumeCapacity(component.bytes);
            }
        }

        /// Despawns `e`, if it is still alive by then.
        pub fn despawn(self: Commands, e: Entity) Allocator.Error!void {
            const bytes = try self.begin(1 + @sizeOf(Entity));
            defer self.end();
            append(bytes, Op.despawn);
            append(bytes, e);
        }

        /// Sets `value`'s component on `e`, if it is still alive by then.
        pub fn set(self: Commands, e: Entity, value: anytype) Allocator.Error!void {
            const bytes = try self.begin(1 + @sizeOf(Entity) + @sizeOf(ComponentId) + @sizeOf(@TypeOf(value)));
            defer self.end();
            append(bytes, Op.set);
            append(bytes, e);
            append(bytes, registry.id(@TypeOf(value)));
            append(bytes, value);
        }

        /// Removes `e`'s `T`, if it has one by then.
        pub fn remove(self: Commands, e: Entity, comptime T: type) Allocator.Error!void {
            const bytes = try self.begin(1 + @sizeOf(Entity) + @sizeOf(ComponentId));
            defer self.end();
            append(bytes, Op.remove);
            append(bytes, e);
            append(bytes, registry.id(T));
        }

        /// Locks the queue with room for `size` more bytes.
        fn begin(self: Commands, size: usize) Allocator.Error!*std.ArrayList(u8) {
            const queue = &self.world.queue;
            queue.mutex.lockUncancelable(self.world.io);
            errdefer queue.mutex.unlock(self.world.io);
            try queue.bytes.ensureUnusedCapacity(self.world.gpa, size);
            return &queue.bytes;
        }

        fn end(self: Commands) void {
            self.world.queue.mutex.unlock(self.world.io);
        }

        fn append(bytes: *std.ArrayList(u8), value: anytype) void {
            bytes.appendSliceAssumeCapacity(std.mem.asBytes(&value));
        }
    };

    const Op = enum(u8) { spawn, despawn, set, remove };

    const Cursor = struct {
        bytes: []const u8,
        at: usize,

        fn take(self: *Cursor, len: usize) []const u8 {
            defer self.at += len;
            return self.bytes[self.at..][0..len];
        }

        fn read(self: *Cursor, comptime T: type) T {
            return std.mem.bytesToValue(T, self.take(@sizeOf(T)));
        }
    };

    /// Makes the queued changes, in order. When it fails, the change that
    /// failed and those after it stay queued.
    pub fn applyCommands(self: *World) Allocator.Error!void {
        self.assertSerial();
        const bytes = &self.queue.bytes;
        var start: usize = 0;
        errdefer {
            const rest = bytes.items.len - start;
            std.mem.copyForwards(u8, bytes.items[0..rest], bytes.items[start..]);
            bytes.shrinkRetainingCapacity(rest);
        }
        while (start < bytes.items.len) {
            var cursor: Cursor = .{ .bytes = bytes.items, .at = start };
            switch (cursor.read(Op)) {
                .despawn => _ = self.despawn(cursor.read(Entity)),
                .set => {
                    const e = cursor.read(Entity);
                    const cid = cursor.read(ComponentId);
                    self.setRaw(e, cid, cursor.take(registry.info(cid).size)) catch |err| switch (err) {
                        error.DeadEntity => {},
                        error.OutOfMemory => |oom| return oom,
                    };
                },
                .remove => {
                    const e = cursor.read(Entity);
                    _ = try self.removeRaw(e, cursor.read(ComponentId));
                },
                .spawn => try self.applySpawn(&cursor),
            }
            start = cursor.at;
        }
        bytes.clearRetainingCapacity();
    }

    fn applySpawn(self: *World, cursor: *Cursor) Allocator.Error!void {
        const len = cursor.read(u16);
        const first = cursor.at;
        var mask: Mask = .empty;
        for (0..len) |_| {
            const cid = cursor.read(ComponentId);
            mask = mask.with(cid);
            _ = cursor.take(registry.info(cid).size);
        }
        const index = try self.archetypeFor(mask);
        _ = try self.allocate(index);
        const archetype = &self.archetypes.items[index];
        const row = archetype.len - 1;
        cursor.at = first;
        for (0..len) |_| {
            const column = archetype.columns[archetype.columnIndex(cursor.read(ComponentId))];
            @memcpy(column.bytes(row), cursor.take(column.size));
        }
    }

    /// Copies `value` in as its type's resource.
    pub fn addResource(self: *World, value: anytype) (Allocator.Error || error{AlreadyExists})!void {
        self.assertSerial();
        try self.resources.add(self.gpa, value);
    }

    /// Copies `value` in as its type's resource, destroying any it replaces.
    pub fn setResource(self: *World, value: anytype) Allocator.Error!void {
        self.assertSerial();
        try self.resources.set(self.gpa, value);
    }

    /// Adds `ptr` as `T`'s resource, owned by the world or borrowed.
    pub fn addResourcePtr(self: *World, comptime T: type, ptr: *T, ownership: Ownership) (Allocator.Error || error{AlreadyExists})!void {
        self.assertSerial();
        try self.resources.addPtr(self.gpa, T, ptr, ownership);
    }

    /// Returns whether there was a `T` resource.
    pub fn removeResource(self: *World, comptime T: type) bool {
        self.assertSerial();
        return self.resources.remove(self.gpa, T);
    }

    pub fn hasResource(self: *const World, comptime T: type) bool {
        return self.resources.get(T) != null;
    }

    pub fn getResource(self: *const World, comptime T: type) ?T {
        const value = self.resources.get(T) orelse return null;
        return value.*;
    }

    pub fn getResourcePtr(self: *const World, comptime T: type) ?*T {
        return self.resources.get(T);
    }

    /// Lets events of type `E` be sent.
    pub fn addEvent(self: *World, comptime E: type) (Allocator.Error || error{AlreadyExists})!void {
        self.assertSerial();
        if (self.hasEvent(E)) return error.AlreadyExists;
        try self.event_updates.ensureUnusedCapacity(self.gpa, 1);
        try self.resources.set(self.gpa, EventChannel(E).init(self.gpa, self.io));
        self.event_updates.appendAssumeCapacity(struct {
            fn update(world: *World) void {
                world.resources.get(EventChannel(E)).?.update();
            }
        }.update);
    }

    pub fn hasEvent(self: *const World, comptime E: type) bool {
        return self.resources.get(EventChannel(E)) != null;
    }

    /// Sends `event`, which systems read the frame after this one. Safe
    /// from any thread.
    pub fn sendEvent(self: *World, event: anytype) (Allocator.Error || error{UnknownEvent})!void {
        const channel = self.resources.get(EventChannel(@TypeOf(event))) orelse return error.UnknownEvent;
        try channel.send(event);
    }

    /// The `E` events sent last frame, in the order they were sent; empty
    /// when `E` was never added. Unchanged until `updateEvents`.
    pub fn readEvents(self: *const World, comptime E: type) []const E {
        const channel = self.resources.get(EventChannel(E)) orelse return &.{};
        return channel.read();
    }

    /// Ends the frame for every event type: this frame's events become the
    /// ones `readEvents` returns, and last frame's are dropped.
    pub fn updateEvents(self: *World) void {
        self.assertSerial();
        for (self.event_updates.items) |update| update(self);
    }

    const Spot = struct { archetype: u32, row: u32 };

    fn record(self: *const World, e: Entity) ?Record {
        if (e.index >= self.records.items.len) return null;
        const found = self.records.items[e.index];
        if (found.generation != e.generation or found.archetype == Archetype.none) return null;
        return found;
    }

    fn assertSerial(self: *const World) void {
        if (std.debug.runtime_safety and self.parallel) @panic("slime: structural change while systems run in parallel; queue it with World.commands");
    }

    fn write(self: *World, comptime T: type, spot: Spot, value: T) void {
        if (@sizeOf(T) == 0) return;
        const archetype = &self.archetypes.items[spot.archetype];
        archetype.ptr(T, archetype.columnIndex(registry.id(T)), spot.row).* = value;
    }

    /// Adds a row for a new entity to the archetype at `index`.
    fn allocate(self: *World, index: u32) Allocator.Error!Entity {
        self.assertSerial();
        const archetype = &self.archetypes.items[index];
        try archetype.reserve(self.gpa, 1);
        try self.records.ensureUnusedCapacity(self.gpa, 1);
        var e: Entity = .{ .index = @intCast(self.records.items.len), .generation = 0 };
        if (self.free != Archetype.none) {
            e = .{ .index = self.free, .generation = self.records.items[self.free].generation };
            self.free = self.records.items[e.index].row;
        } else {
            self.records.appendAssumeCapacity(undefined);
        }
        self.records.items[e.index] = .{ .generation = e.generation, .archetype = index, .row = archetype.push(e) };
        return e;
    }

    /// Moves `e`, which lacks `cid`, to the archetype that also has it,
    /// leaving the new component unset.
    fn insertSlot(self: *World, e: Entity, cid: ComponentId) (Allocator.Error || error{DeadEntity})!Spot {
        self.assertSerial();
        const found = self.record(e) orelse return error.DeadEntity;
        std.debug.assert(!self.archetypes.items[found.archetype].has(cid));
        const target = try self.addEdge(found.archetype, cid);
        try self.archetypes.items[target].reserve(self.gpa, 1);
        return .{ .archetype = target, .row = self.move(e.index, found.archetype, target) };
    }

    /// Moves entity `index` from `from` to `to`, which has room, keeping the
    /// components both have.
    fn move(self: *World, index: u32, from: u32, to: u32) u32 {
        const src = &self.archetypes.items[from];
        const dst = &self.archetypes.items[to];
        const old = &self.records.items[index];
        const old_row = old.row;
        const row = dst.push(src.entities[old_row]);
        dst.copyShared(row, src, old_row);
        if (src.swapRemove(old_row)) |moved| self.records.items[moved.index].row = old_row;
        old.archetype = to;
        old.row = row;
        return row;
    }

    fn addEdge(self: *World, from: u32, cid: ComponentId) Allocator.Error!u32 {
        if (self.archetypes.items[from].findEdge(cid)) |found| if (found.add != Archetype.none) return found.add;
        const to = try self.archetypeFor(self.archetypes.items[from].mask.with(cid));
        (try self.archetypes.items[from].edge(self.gpa, cid)).add = to;
        (try self.archetypes.items[to].edge(self.gpa, cid)).remove = from;
        return to;
    }

    fn removeEdge(self: *World, from: u32, cid: ComponentId) Allocator.Error!u32 {
        if (self.archetypes.items[from].findEdge(cid)) |found| if (found.remove != Archetype.none) return found.remove;
        const to = try self.archetypeFor(self.archetypes.items[from].mask.without(cid));
        (try self.archetypes.items[from].edge(self.gpa, cid)).remove = to;
        (try self.archetypes.items[to].edge(self.gpa, cid)).add = from;
        return to;
    }

    fn archetypeFor(self: *World, mask: Mask) Allocator.Error!u32 {
        if (self.by_mask.get(mask)) |index| return index;
        try self.archetypes.ensureUnusedCapacity(self.gpa, 1);
        try self.masks.ensureUnusedCapacity(self.gpa, 1);
        try self.by_mask.ensureUnusedCapacity(self.gpa, 1);
        const index: u32 = @intCast(self.archetypes.items.len);
        self.archetypes.appendAssumeCapacity(try Archetype.init(self.gpa, mask));
        self.masks.appendAssumeCapacity(mask);
        self.by_mask.putAssumeCapacityNoClobber(mask, index);
        return index;
    }
};
