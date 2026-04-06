const std = @import("std");
const Entity = @import("entity.zig").Entity;
const EntitySlot = @import("entity.zig").EntitySlot;
const archetype_mod = @import("archetype.zig");
const Archetype = archetype_mod.Archetype;
const ArchetypeId = archetype_mod.ArchetypeId;
const Column = @import("column.zig").Column;
const registry = @import("registry.zig");
const serialize = @import("serialize.zig");
const prefab_mod = @import("prefab.zig");

pub const World = struct {
    allocator: std.mem.Allocator,
    archetypes: std.ArrayListUnmanaged(Archetype),
    archetype_by_sig: std.AutoHashMapUnmanaged(u64, ArchetypeId),
    entities: std.ArrayListUnmanaged(EntitySlot),
    free_slots: std.ArrayListUnmanaged(u32),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .archetypes = .empty,
            .archetype_by_sig = .empty,
            .entities = .empty,
            .free_slots = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.archetypes.items) |*a| {
            a.deinit(self.allocator);
        }
        self.archetypes.deinit(self.allocator);
        self.archetype_by_sig.deinit(self.allocator);
        self.entities.deinit(self.allocator);
        self.free_slots.deinit(self.allocator);
    }

    pub fn isAlive(self: *const Self, e: Entity) bool {
        if (e.index >= self.entities.items.len) return false;
        const s = self.entities.items[e.index];
        return s.alive and s.generation == e.generation;
    }

    pub fn spawn(self: *Self, comptime types: []const type, values: anytype) !Entity {
        if (types.len != 0) {
            const V = @TypeOf(values);
            const fields = std.meta.fields(V);
            if (fields.len != types.len) @compileError("values tuple length must match types");
        }

        const sig = registry.maskMany(types);
        const e = try self.allocEntity();
        const arch_id = try self.ensureArchetype(sig);
        const arch = &self.archetypes.items[arch_id];
        const row = try arch.appendRow(self.allocator, e, sig, types, values);
        self.entities.items[e.index] = .{
            .generation = e.generation,
            .alive = true,
            .archetype = arch_id,
            .row = @intCast(row),
        };
        return e;
    }

    pub fn despawn(self: *Self, e: Entity) void {
        if (!self.isAlive(e)) return;
        const slot = &self.entities.items[e.index];
        const arch = &self.archetypes.items[slot.archetype];
        const moved = arch.swapRemoveRow(self.allocator, slot.row) catch return;
        if (moved) |m| {
            if (m.index != e.index) {
                self.entities.items[m.index].row = slot.row;
            }
        }
        slot.alive = false;
        slot.generation +|= 1;
        self.free_slots.append(self.allocator, e.index) catch {};
    }

    pub fn addComponent(self: *Self, e: Entity, comptime T: type, value: T) !void {
        if (!self.isAlive(e)) return error.DeadEntity;
        const slot = &self.entities.items[e.index];
        const old_arch_id = slot.archetype;
        const old_row: u32 = slot.row;
        const old_sig = self.archetypes.items[old_arch_id].signature;
        const bit = registry.mask(T);
        if (old_sig & bit != 0) return error.AlreadyHasComponent;
        const new_sig = old_sig | bit;

        const dst_id = try self.ensureArchetype(new_sig);
        const old_arch = &self.archetypes.items[old_arch_id];
        const dst = &self.archetypes.items[dst_id];
        const new_row = try dst.pushBlankRow(self.allocator, e, new_sig);

        var remaining = old_sig & new_sig;
        while (remaining != 0) {
            const cid = @ctz(remaining);
            remaining &= remaining - 1;
            const src_col = old_arch.getColumn(cid).?;
            try ensureColumnForExistingRow(self.allocator, dst, cid, src_col.element_size, src_col.element_align);
            const dst_col = dst.getColumn(cid).?;
            const copy_size = @min(dst_col.stride, src_col.stride);
            const dst_offset = new_row * dst_col.stride;
            const src_offset = old_row * src_col.stride;
            @memcpy(dst_col.data[dst_offset .. dst_offset + copy_size], src_col.data[src_offset .. src_offset + copy_size]);
        }

        const idv = registry.id(T);
        try ensureColumnForExistingRow(self.allocator, dst, idv, @sizeOf(T), registry.elementAlign(T));
        const col = dst.getColumn(idv).?;
        const dst_bytes = col.rowPtr(new_row)[0..@sizeOf(T)];
        @memcpy(dst_bytes, std.mem.asBytes(&value));

        const moved = try old_arch.swapRemoveRow(self.allocator, old_row);
        if (moved) |m| {
            if (m.index != e.index) {
                self.entities.items[m.index].row = old_row;
            }
        }

        slot.archetype = dst_id;
        slot.row = @intCast(new_row);
    }

    fn ensureColumnForExistingRow(allocator: std.mem.Allocator, arch: *Archetype, cid: u32, element_size: usize, element_align: u8) !void {
        const stride = std.mem.alignForward(usize, element_size, element_align);
        if (arch.columns.getPtr(cid)) |col| {
            if (col.element_size >= element_size) return;
            const old_len = col.len;
            col.deinit(allocator);
            col.* = Column.init(allocator, element_size, element_align);
            try col.ensureTotalCapacity(allocator, old_len);
            col.len = old_len;
            try arch.column_sizes.put(allocator, cid, stride);
            return;
        }
        try arch.columns.put(allocator, cid, Column.init(allocator, element_size, element_align));
        try arch.column_sizes.put(allocator, cid, stride);
    }

    pub fn removeComponent(self: *Self, e: Entity, comptime T: type) !void {
        if (!self.isAlive(e)) return error.DeadEntity;
        const slot = &self.entities.items[e.index];
        const old_arch_id = slot.archetype;
        const old_row: u32 = slot.row;
        const old_sig = self.archetypes.items[old_arch_id].signature;
        const bit = registry.mask(T);
        if (old_sig & bit == 0) return error.MissingComponent;
        const new_sig = old_sig & ~bit;

        const dst_id = try self.ensureArchetype(new_sig);
        const old_arch = &self.archetypes.items[old_arch_id];
        const dst = &self.archetypes.items[dst_id];
        const new_row = try dst.pushBlankRow(self.allocator, e, new_sig);

        var remaining = old_sig & new_sig;
        while (remaining != 0) {
            const cid = @ctz(remaining);
            remaining &= remaining - 1;
            const dst_col = dst.getColumn(@intCast(cid)).?;
            const src_col = old_arch.getColumn(@intCast(cid)).?;
            dst_col.copyRowFrom(new_row, src_col, old_row);
        }

        const moved = try old_arch.swapRemoveRow(self.allocator, old_row);
        if (moved) |m| {
            if (m.index != e.index) {
                self.entities.items[m.index].row = old_row;
            }
        }

        slot.archetype = dst_id;
        slot.row = @intCast(new_row);
    }

    pub fn get(self: *Self, e: Entity, comptime T: type) ?T {
        if (!self.isAlive(e)) return null;
        const slot = self.entities.items[e.index];
        const arch = &self.archetypes.items[slot.archetype];
        const bit = registry.mask(T);
        if (arch.signature & bit == 0) return null;
        const idv = registry.id(T);
        const col = arch.getColumn(idv) orelse return null;
        const bytes = col.rowPtr(@intCast(slot.row))[0..@sizeOf(T)];
        return std.mem.bytesToValue(T, bytes);
    }

    pub fn getMut(self: *Self, e: Entity, comptime T: type) ?*T {
        if (!self.isAlive(e)) return null;
        const slot = &self.entities.items[e.index];
        const arch = &self.archetypes.items[slot.archetype];
        const bit = registry.mask(T);
        if (arch.signature & bit == 0) return null;
        const idv = registry.id(T);
        const col = arch.getColumn(idv) orelse return null;
        const ptr = col.rowPtr(@intCast(slot.row));
        return @ptrCast(@alignCast(ptr));
    }

    fn allocEntity(self: *Self) !Entity {
        if (self.free_slots.items.len > 0) {
            const idx = self.free_slots.pop().?;
            const s = &self.entities.items[idx];
            s.generation +%= 1;
            s.alive = true;
            return .{ .index = idx, .generation = s.generation };
        }
        const idx = @as(u32, @intCast(self.entities.items.len));
        try self.entities.append(self.allocator, .{
            .generation = 0,
            .alive = true,
            .archetype = 0,
            .row = 0,
        });
        return .{ .index = idx, .generation = 0 };
    }

    fn ensureArchetype(self: *Self, sig: u64) !ArchetypeId {
        const gop = try self.archetype_by_sig.getOrPut(self.allocator, sig);
        if (gop.found_existing) return gop.value_ptr.*;

        const id = @as(ArchetypeId, @intCast(self.archetypes.items.len));
        var arch = try archetype_mod.create(self.allocator, id, sig);
        errdefer arch.deinit(self.allocator);
        try self.archetypes.append(self.allocator, arch);
        gop.value_ptr.* = id;
        return id;
    }

    pub fn query(self: *Self, comptime with: []const type) QueryIter {
        return .{
            .world = self,
            .arch_index = 0,
            .row = 0,
            .required_mask = registry.maskMany(with),
        };
    }

    pub const QueryIter = struct {
        world: *Self,
        arch_index: usize,
        row: usize,
        required_mask: u64,

        pub fn next(self: *QueryIter) ?struct {
            entity: Entity,
            archetype: ArchetypeId,
            row: u32,
        } {
            const req = self.required_mask;
            while (self.arch_index < self.world.archetypes.items.len) {
                const arch = &self.world.archetypes.items[self.arch_index];
                if ((arch.signature & req) != req) {
                    self.arch_index += 1;
                    self.row = 0;
                    continue;
                }
                if (self.row < arch.entities.items.len) {
                    const e = arch.entities.items[self.row];
                    const r: u32 = @intCast(self.row);
                    const aid = arch.id;
                    self.row += 1;
                    return .{
                        .entity = e,
                        .archetype = aid,
                        .row = r,
                    };
                }
                self.arch_index += 1;
                self.row = 0;
            }
            return null;
        }
    };

    pub fn queryChunked(self: *Self, comptime with: []const type, chunk_size: usize) QueryChunkIter {
        std.debug.assert(chunk_size > 0);
        return .{
            .world = self,
            .arch_index = 0,
            .row = 0,
            .required_mask = registry.maskMany(with),
            .chunk_size = chunk_size,
        };
    }

    pub const QueryChunkIter = struct {
        world: *Self,
        arch_index: usize,
        row: usize,
        required_mask: u64,
        chunk_size: usize,

        pub fn next(self: *QueryChunkIter) ?struct {
            archetype_id: ArchetypeId,
            signature: u64,
            start_row: usize,
            len: usize,
            entities: []const Entity,
        } {
            const req = self.required_mask;
            while (self.arch_index < self.world.archetypes.items.len) {
                const arch = &self.world.archetypes.items[self.arch_index];
                if ((arch.signature & req) != req) {
                    self.arch_index += 1;
                    self.row = 0;
                    continue;
                }
                const total = arch.entities.items.len;
                if (self.row < total) {
                    const remain = total - self.row;
                    const take = @min(remain, self.chunk_size);
                    const start = self.row;
                    const slice = arch.entities.items[start .. start + take];
                    self.row += take;
                    if (self.row >= total) {
                        self.arch_index += 1;
                        self.row = 0;
                    }
                    return .{
                        .archetype_id = arch.id,
                        .signature = arch.signature,
                        .start_row = start,
                        .len = take,
                        .entities = slice,
                    };
                }
                self.arch_index += 1;
                self.row = 0;
            }
            return null;
        }
    };

    pub fn columnSlice(self: *Self, comptime T: type, archetype_id: ArchetypeId, start_row: usize, len: usize) ?[]T {
        if (len == 0) return &[_]T{};
        const arch = &self.archetypes.items[archetype_id];
        const bit = registry.mask(T);
        if ((arch.signature & bit) == 0) return null;
        const idv = registry.id(T);
        const col = arch.getColumn(idv) orelse return null;
        if (col.stride != @sizeOf(T)) return null;
        if (start_row + len > col.len) return null;
        const byte_len = len * col.stride;
        const bytes = col.data[start_row * col.stride ..][0..byte_len];
        const aligned: []align(@alignOf(T)) u8 = @alignCast(bytes);
        return std.mem.bytesAsSlice(T, aligned);
    }

    pub fn reset(self: *Self) void {
        for (self.archetypes.items) |*a| {
            a.deinit(self.allocator);
        }
        self.archetypes.clearRetainingCapacity();
        self.archetype_by_sig.clearRetainingCapacity();
        self.entities.clearRetainingCapacity();
        self.free_slots.clearRetainingCapacity();
    }

    pub fn spawnPrefab(self: *Self, prefab: prefab_mod.PrefabRef) !Entity {
        const sig = prefab.signature;
        const e = try self.allocEntity();
        const arch_id = try self.ensureArchetype(sig);
        const arch = &self.archetypes.items[arch_id];
        const row_u = try arch.pushBlankRow(self.allocator, e, sig);
        const row: u32 = @intCast(row_u);
        self.entities.items[e.index] = .{
            .generation = e.generation,
            .alive = true,
            .archetype = arch_id,
            .row = row,
        };
        var fbs = std.io.fixedBufferStream(prefab.data);
        const r = fbs.reader();
        try fillPrefabRow(arch, row, sig, r);
        return e;
    }

    fn fillPrefabRow(arch: *Archetype, row: u32, sig: u64, reader: anytype) !void {
        var remaining = sig;
        while (remaining != 0) {
            const cid = @ctz(remaining);
            remaining &= remaining - 1;
            const col = arch.getColumn(@intCast(cid)).?;
            const stride = col.stride;
            var size_bytes: [4]u8 = undefined;
            try reader.readNoEof(&size_bytes);
            const size = std.mem.readInt(u32, &size_bytes, .little);
            const offset = @as(usize, @intCast(row)) * stride;
            try reader.readNoEof(col.data[offset..][0..size]);
        }
    }

    pub fn writeSnapshot(self: *Self, writer: anytype) !void {
        const snapshot_magic: u32 = 0x4D4C4953;
        const snapshot_version: u32 = 1;
        try writeU32(writer, snapshot_magic);
        try writeU32(writer, snapshot_version);
        try writeU32(writer, @intCast(self.entities.items.len));

        var nonempty: usize = 0;
        for (self.archetypes.items) |a| {
            if (a.entities.items.len > 0) nonempty += 1;
        }
        try writeU32(writer, @intCast(nonempty));

        for (self.archetypes.items) |*arch| {
            const rows = arch.entities.items.len;
            if (rows == 0) continue;

            try writeU64(writer, arch.signature);
            try writeU32(writer, @intCast(rows));

            for (arch.entities.items) |e| {
                try writeEntity(writer, e);
            }

            var cid: u32 = 0;
            while (cid < 64) : (cid += 1) {
                const b = @as(u64, 1) << @intCast(cid);
                if ((arch.signature & b) == 0) continue;
                const col = arch.getColumn(cid).?;
                try writeU32(writer, @intCast(col.element_size));
                const total = col.element_size * rows;
                try writer.writeAll(col.data[0..total]);
            }
        }
    }

    pub fn readSnapshot(self: *Self, reader: anytype) !void {
        const snapshot_magic: u32 = 0x4D4C4953;
        const snapshot_version: u32 = 1;

        const magic = try readU32(reader);
        if (magic != snapshot_magic) return error.InvalidSnapshot;
        const ver = try readU32(reader);
        if (ver != snapshot_version) return error.UnsupportedSnapshotVersion;

        const slot_capacity = try readU32(reader);
        const arch_count = try readU32(reader);

        self.reset();

        while (self.entities.items.len < slot_capacity) {
            try self.entities.append(self.allocator, .{
                .generation = 0,
                .alive = false,
                .archetype = 0,
                .row = 0,
            });
        }

        var aidx: u32 = 0;
        while (aidx < arch_count) : (aidx += 1) {
            const sig = try readU64(reader);
            const rows: u32 = try readU32(reader);

            const aid = try self.ensureArchetype(sig);
            const arch = &self.archetypes.items[aid];

            var r: u32 = 0;
            while (r < rows) : (r += 1) {
                const e = try readEntity(reader);
                while (self.entities.items.len <= e.index) {
                    try self.entities.append(self.allocator, .{
                        .generation = 0,
                        .alive = false,
                        .archetype = 0,
                        .row = 0,
                    });
                }
                const row = try arch.pushBlankRow(self.allocator, e, sig);
                self.entities.items[e.index] = .{
                    .generation = e.generation,
                    .alive = true,
                    .archetype = aid,
                    .row = @intCast(row),
                };
            }

            var cid: u32 = 0;
            while (cid < 64) : (cid += 1) {
                const b = @as(u64, 1) << @intCast(cid);
                if ((sig & b) == 0) continue;
                var size_bytes: [4]u8 = undefined;
                try reader.readNoEof(&size_bytes);
                const elem_size = std.mem.readInt(u32, &size_bytes, .little);
                try ensureColumnForExistingRow(self.allocator, arch, cid, elem_size, 1);
                const col = arch.getColumn(cid).?;
                const total = elem_size * rows;
                try reader.readNoEof(col.data[0..total]);
            }
        }
    }
};

fn writeU32(w: anytype, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try w.writeAll(&b);
}

fn writeU64(w: anytype, v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try w.writeAll(&b);
}

fn readU32(r: anytype) !u32 {
    var b: [4]u8 = undefined;
    try r.readNoEof(&b);
    return std.mem.readInt(u32, &b, .little);
}

fn readU64(r: anytype) !u64 {
    var b: [8]u8 = undefined;
    try r.readNoEof(&b);
    return std.mem.readInt(u64, &b, .little);
}

fn writeEntity(writer: anytype, e: Entity) !void {
    const u = @as(u64, @bitCast(e));
    try writeU64(writer, u);
}

fn readEntity(reader: anytype) !Entity {
    const u = try readU64(reader);
    return @bitCast(u);
}

pub const Error = error{
    DeadEntity,
    AlreadyHasComponent,
    MissingComponent,
    InvalidSnapshot,
    UnsupportedSnapshotVersion,
};
