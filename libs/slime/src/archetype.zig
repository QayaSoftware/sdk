const std = @import("std");
const Column = @import("column.zig").Column;
const Entity = @import("entity.zig").Entity;

pub const ArchetypeId = u32;

pub const Archetype = struct {
    signature: u64,
    id: ArchetypeId,
    entities: std.ArrayListUnmanaged(Entity),
    columns: std.AutoArrayHashMapUnmanaged(u32, Column),

    pub fn deinit(self: *Archetype, allocator: std.mem.Allocator) void {
        var it = self.columns.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(allocator);
        }
        self.columns.deinit(allocator);
        self.entities.deinit(allocator);
    }

    pub fn appendRow(
        self: *Archetype,
        allocator: std.mem.Allocator,
        e: Entity,
        comptime Info: type,
        sig: u64,
        comptime types: []const type,
        values: anytype,
    ) !usize {
        std.debug.assert(self.signature == sig);
        const row = self.entities.items.len;

        var cid: u32 = 0;
        while (cid < 64) : (cid += 1) {
            if ((sig >> @intCast(cid)) & 1 == 0) continue;
            const gop = try self.columns.getOrPut(allocator, cid);
            if (!gop.found_existing) {
                gop.value_ptr.* = Column.init(allocator, Info.elementSize(cid), Info.elementAlign(cid));
            }
            _ = try gop.value_ptr.pushUninitialized(allocator);
        }

        try self.entities.append(allocator, e);
        std.debug.assert(self.entities.items.len == row + 1);

        inline for (0..types.len) |vi| {
            const CT = types[vi];
            const idv = comptime Info.id(CT);
            const col = self.columns.getPtr(idv).?;
            const dst = col.rowPtr(row)[0..@sizeOf(CT)];
            var tmp = values[vi];
            @memcpy(dst, std.mem.asBytes(&tmp)[0..@sizeOf(CT)]);
        }

        return row;
    }

    /// Adds a row with uninitialized component storage for every bit in `sig`. Caller fills via `copyRowFrom` / writes.
    pub fn pushBlankRow(
        self: *Archetype,
        allocator: std.mem.Allocator,
        e: Entity,
        comptime Info: type,
        sig: u64,
    ) !usize {
        std.debug.assert(self.signature == sig);
        const row = self.entities.items.len;

        var cid: u32 = 0;
        while (cid < 64) : (cid += 1) {
            if ((sig >> @intCast(cid)) & 1 == 0) continue;
            const gop = try self.columns.getOrPut(allocator, cid);
            if (!gop.found_existing) {
                gop.value_ptr.* = Column.init(allocator, Info.elementSize(cid), Info.elementAlign(cid));
            }
            _ = try gop.value_ptr.pushUninitialized(allocator);
        }

        try self.entities.append(allocator, e);
        std.debug.assert(self.entities.items.len == row + 1);
        return row;
    }

    pub fn getColumn(self: *Archetype, cid: u32) ?*Column {
        return self.columns.getPtr(cid);
    }

    pub fn copySharedComponents(
        dst: *Archetype,
        dst_row: usize,
        src: *const Archetype,
        src_row: usize,
        comptime Info: type,
        comptime shared: []const type,
    ) void {
        inline for (shared) |CT| {
            const cid = comptime Info.id(CT);
            const dst_col = dst.getColumn(cid).?;
            const src_col = src.getColumn(cid).?;
            dst_col.copyRowFrom(dst_row, src_col, src_row);
        }
    }

    /// Removes `row` with swap-remove. Returns the entity that moved into `row`, if any.
    pub fn swapRemoveRow(self: *Archetype, _: std.mem.Allocator, row: usize) !?Entity {
        std.debug.assert(row < self.entities.items.len);
        if (self.entities.items.len == 1) {
            _ = self.entities.pop();
            var it = self.columns.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.swapRemove(row);
            }
            return null;
        }

        if (row == self.entities.items.len - 1) {
            _ = self.entities.pop();
            var it = self.columns.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.swapRemove(row);
            }
            return null;
        }

        const moved = self.entities.items[self.entities.items.len - 1];
        _ = self.entities.swapRemove(row);

        var it = self.columns.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.swapRemove(row);
        }

        return moved;
    }
};

pub fn create(
    allocator: std.mem.Allocator,
    id: ArchetypeId,
    signature: u64,
) !Archetype {
    var arch: Archetype = .{
        .signature = signature,
        .id = id,
        .entities = .empty,
        .columns = .empty,
    };
    errdefer arch.deinit(allocator);
    try arch.entities.ensureTotalCapacity(allocator, 4);
    return arch;
}
