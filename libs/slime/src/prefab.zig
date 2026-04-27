const std = @import("std");
const registry = @import("registry.zig");
const serialize = @import("serialize.zig");

pub const prefab_magic: u32 = 0x46504c53;
pub const prefab_version: u32 = 1;

pub const PrefabRef = struct {
    id: u32,
    signature: u1024,
    data: []const u8,
};

pub const PrefabOwned = struct {
    id: u32,
    signature: u1024,
    data: []u8,

    pub fn asRef(self: *const PrefabOwned) PrefabRef {
        return .{
            .id = self.id,
            .signature = self.signature,
            .data = self.data,
        };
    }

    pub fn deinit(self: *PrefabOwned, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub const PrefabError = error{
    InvalidPrefabMagic,
    UnsupportedPrefabVersion,
    InvalidPrefabJson,
    MissingPrefabId,
    MissingPrefabComponents,
    InvalidPrefabId,
    UnknownPrefabComponent,
    DuplicatePrefabComponent,
    PrefabSignatureMismatch,
};

fn writeU32(w: anytype, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try w.writeAll(&b);
}

fn writeU1024(w: anytype, v: u1024) !void {
    var b: [128]u8 = undefined;
    std.mem.writeInt(u1024, &b, v, .little);
    try w.writeAll(&b);
}

fn readU32(r: anytype) !u32 {
    var b: [4]u8 = undefined;
    try r.readSliceAll(&b);
    return std.mem.readInt(u32, &b, .little);
}

fn readU1024(r: anytype) !u1024 {
    var b: [128]u8 = undefined;
    try r.readSliceAll(&b);
    return std.mem.readInt(u1024, &b, .little);
}

pub fn writePrefabBinary(writer: anytype, id: u32, signature: u1024, payload: []const u8) !void {
    try writeU32(writer, prefab_magic);
    try writeU32(writer, prefab_version);
    try writeU32(writer, id);
    try writeU1024(writer, signature);
    try writeU32(writer, @intCast(payload.len));
    try writer.writeAll(payload);
}

pub fn readPrefabBinary(allocator: std.mem.Allocator, reader: anytype) !PrefabOwned {
    const magic = try readU32(reader);
    if (magic != prefab_magic) return error.InvalidPrefabMagic;
    const ver = try readU32(reader);
    if (ver != prefab_version) return error.UnsupportedPrefabVersion;
    const id = try readU32(reader);
    const sig = try readU1024(reader);
    const len = try readU32(reader);
    const data = try allocator.alloc(u8, len);
    errdefer allocator.free(data);
    try reader.readSliceAll(data);
    return .{ .id = id, .signature = sig, .data = data };
}

pub fn encodePrefabBinary(allocator: std.mem.Allocator, id: u32, comptime types: []const type, values: anytype) ![]u8 {
    if (types.len != 0) {
        const V = @TypeOf(values);
        const fields = std.meta.fields(V);
        if (fields.len != types.len) @compileError("values tuple length must match types");
    }
    const sig = registry.maskMany(types);

    var wody = std.Io.Writer.Allocating.init(allocator);
    errdefer wody.deinit();

    inline for (types, 0..) |T, ti| {
        const val = values[ti];
        const size = @sizeOf(T);
        try writeU32(&wody.writer, @intCast(size));
        try wody.writer.writeAll(std.mem.asBytes(&val)[0..size]);
    }

    var out_body = std.Io.Writer.Allocating.init(allocator);
    errdefer out_body.deinit();
    try writePrefabBinary(&out_body.writer, id, sig, wody.toArrayList().items);
    var ow_list = out_body.toArrayList();
    return try ow_list.toOwnedSlice(allocator);
}
