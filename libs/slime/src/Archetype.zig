//! The table of every entity with exactly one set of components: a column
//! per component, ordered by id, all in one block that doubles as it fills.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Entity = @import("entity.zig").Entity;
const registry = @import("registry.zig");
const ComponentId = registry.ComponentId;
const ComponentInfo = registry.ComponentInfo;
const Mask = registry.Mask;

const Archetype = @This();

/// No archetype, no row, no edge.
pub const none = std.math.maxInt(u32);

mask: Mask,
/// The component ids, ascending; column `i` holds `ids[i]`.
ids: []const ComponentId,
columns: []Column,
/// Indexed by id up to the largest the archetype has: one more than the
/// column holding it, or 0.
column_of: []u16,
entities: [*]Entity,
len: u32 = 0,
capacity: u32 = 0,
block: []u8 = &.{},
block_alignment: std.mem.Alignment,
/// The archetypes one component away, found as entities move.
edges: std.ArrayList(Edge) = .empty,

pub const Column = struct {
    data: [*]u8,
    size: usize,
    info: *const ComponentInfo,

    pub fn bytes(column: Column, row: usize) []u8 {
        return column.data[row * column.size ..][0..column.size];
    }
};

pub const Edge = struct {
    id: ComponentId,
    add: u32 = none,
    remove: u32 = none,
};

pub fn init(gpa: Allocator, mask: Mask) Allocator.Error!Archetype {
    const count = mask.count();
    const ids = try gpa.alloc(ComponentId, count);
    errdefer gpa.free(ids);
    const columns = try gpa.alloc(Column, count);
    errdefer gpa.free(columns);
    var ascending = mask.iterator();
    for (ids) |*cid| cid.* = ascending.next().?;
    const column_of = try gpa.alloc(u16, if (count == 0) 0 else @as(usize, ids[count - 1]) + 1);
    @memset(column_of, 0);
    var alignment: std.mem.Alignment = .fromByteUnits(@alignOf(Entity));
    for (ids, columns, 0..) |cid, *column, index| {
        column_of[cid] = @intCast(index + 1);
        const info = registry.info(cid);
        column.* = .{ .data = @ptrFromInt(info.alignment.toByteUnits()), .size = info.size, .info = info };
        alignment = alignment.max(info.alignment);
    }
    return .{
        .mask = mask,
        .ids = ids,
        .columns = columns,
        .column_of = column_of,
        .entities = @ptrFromInt(@alignOf(Entity)),
        .block_alignment = alignment,
    };
}

pub fn deinit(self: *Archetype, gpa: Allocator) void {
    if (self.capacity > 0) gpa.rawFree(self.block, self.block_alignment, @returnAddress());
    gpa.free(self.ids);
    gpa.free(self.columns);
    gpa.free(self.column_of);
    self.edges.deinit(gpa);
}

pub fn has(self: *const Archetype, cid: ComponentId) bool {
    return cid < self.column_of.len and self.column_of[cid] != 0;
}

/// The column holding `cid`, which the archetype must have.
pub fn columnIndex(self: *const Archetype, cid: ComponentId) usize {
    return self.column_of[cid] - 1;
}

pub fn ptr(self: *const Archetype, comptime T: type, column: usize, row: usize) *T {
    return @ptrCast(@alignCast(self.columns[column].data + row * @sizeOf(T)));
}

pub fn slice(self: *const Archetype, comptime T: type, column: usize) []T {
    const many: [*]T = @ptrCast(@alignCast(self.columns[column].data));
    return many[0..self.len];
}

/// Makes room for `additional` more rows. Leaves the table as it was when
/// it fails.
pub fn reserve(self: *Archetype, gpa: Allocator, additional: usize) Allocator.Error!void {
    const needed = @as(usize, self.len) + additional;
    if (needed <= self.capacity) return;
    var capacity: usize = @max(self.capacity, 8);
    while (capacity < needed) capacity *= 2;
    if (capacity > none) return error.OutOfMemory;
    const size = self.blockSize(capacity);
    const block = (gpa.rawAlloc(size, self.block_alignment, @returnAddress()) orelse return error.OutOfMemory)[0..size];
    const entities: [*]Entity = @ptrCast(@alignCast(block.ptr));
    @memcpy(entities[0..self.len], self.entities[0..self.len]);
    var offset = capacity * @sizeOf(Entity);
    for (self.columns) |*column| {
        offset = column.info.alignment.forward(offset);
        const used = self.len * column.size;
        @memcpy(block.ptr[offset..][0..used], column.data[0..used]);
        column.data = block.ptr + offset;
        offset += capacity * column.size;
    }
    if (self.capacity > 0) gpa.rawFree(self.block, self.block_alignment, @returnAddress());
    self.block = block;
    self.entities = entities;
    self.capacity = @intCast(capacity);
}

fn blockSize(self: *const Archetype, capacity: usize) usize {
    var offset = capacity * @sizeOf(Entity);
    for (self.columns) |column| offset = column.info.alignment.forward(offset) + capacity * column.size;
    return offset;
}

/// Adds a row for `e`, its components unset, in room `reserve` made.
pub fn push(self: *Archetype, e: Entity) u32 {
    std.debug.assert(self.len < self.capacity);
    const row = self.len;
    self.entities[row] = e;
    self.len += 1;
    return row;
}

/// Removes `row` by moving the last row into it, and returns the entity
/// that moved, if one did.
pub fn swapRemove(self: *Archetype, row: u32) ?Entity {
    const last = self.len - 1;
    self.len = last;
    if (row == last) return null;
    for (self.columns) |column| @memcpy(column.bytes(row), column.bytes(last));
    self.entities[row] = self.entities[last];
    return self.entities[row];
}

/// Copies the components `src` and `self` share from `src_row` to `row`.
pub fn copyShared(self: *Archetype, row: u32, src: *const Archetype, src_row: u32) void {
    var s: usize = 0;
    var d: usize = 0;
    while (s < src.ids.len and d < self.ids.len) {
        if (src.ids[s] == self.ids[d]) {
            @memcpy(self.columns[d].bytes(row), src.columns[s].bytes(src_row));
            s += 1;
            d += 1;
        } else if (src.ids[s] < self.ids[d]) {
            s += 1;
        } else {
            d += 1;
        }
    }
}

/// The edge for `cid`, made if there is none yet.
pub fn edge(self: *Archetype, gpa: Allocator, cid: ComponentId) Allocator.Error!*Edge {
    if (self.findEdge(cid)) |found| return found;
    try self.edges.append(gpa, .{ .id = cid });
    return &self.edges.items[self.edges.items.len - 1];
}

pub fn findEdge(self: *const Archetype, cid: ComponentId) ?*Edge {
    for (self.edges.items) |*found| if (found.id == cid) return found;
    return null;
}
