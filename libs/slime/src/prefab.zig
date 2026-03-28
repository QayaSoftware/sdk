//! Prefabs: `id` + component signature + column payload (same wire order as world snapshots).
//! Load from binary buffers or JSON (keys = bundle declaration names).

const std = @import("std");
const registry = @import("registry.zig");
const serialize = @import("serialize.zig");

pub const prefab_magic: u32 = 0x46504c53; // 'S','L','P','F' in LE memory order → "SLPF"
pub const prefab_version: u32 = 1;

pub const PrefabRef = struct {
    id: u32,
    signature: u64,
    data: []const u8,
};

pub const PrefabOwned = struct {
    id: u32,
    signature: u64,
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

fn jsonValueToU32(v: std.json.Value) PrefabError!u32 {
    switch (v) {
        .integer => |i| {
            if (i < 0) return error.InvalidPrefabId;
            const u: u64 = @intCast(i);
            if (u > std.math.maxInt(u32)) return error.InvalidPrefabId;
            return @intCast(u);
        },
        .float => |f| {
            const r = @round(f);
            if (@abs(f - r) > 1e-9) return error.InvalidPrefabId;
            if (r < 0 or r > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return error.InvalidPrefabId;
            return @intFromFloat(r);
        },
        else => return error.InvalidPrefabId,
    }
}

fn jsonValueToU64(v: std.json.Value) PrefabError!u64 {
    switch (v) {
        .integer => |i| {
            if (i < 0) return error.PrefabSignatureMismatch;
            return @intCast(i);
        },
        .float => |f| {
            const r = @round(f);
            if (@abs(f - r) > 1e-9) return error.PrefabSignatureMismatch;
            if (r < 0 or r > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.PrefabSignatureMismatch;
            return @intFromFloat(r);
        },
        else => return error.PrefabSignatureMismatch,
    }
}

/// Full binary prefab: magic, version, id, signature, payload length, payload (column bytes, cid ascending).
pub fn writePrefabBinary(writer: anytype, id: u32, signature: u64, payload: []const u8) !void {
    try writeU32(writer, prefab_magic);
    try writeU32(writer, prefab_version);
    try writeU32(writer, id);
    try writeU64(writer, signature);
    try writeU32(writer, @intCast(payload.len));
    try writer.writeAll(payload);
}

pub fn readPrefabBinary(allocator: std.mem.Allocator, reader: anytype) !PrefabOwned {
    const magic = try readU32(reader);
    if (magic != prefab_magic) return error.InvalidPrefabMagic;
    const ver = try readU32(reader);
    if (ver != prefab_version) return error.UnsupportedPrefabVersion;
    const id = try readU32(reader);
    const sig = try readU64(reader);
    const len = try readU32(reader);
    const data = try allocator.alloc(u8, len);
    errdefer allocator.free(data);
    try reader.readNoEof(data);
    return .{ .id = id, .signature = sig, .data = data };
}

fn appendColumnPayload(
    comptime Bundle: type,
    allocator: std.mem.Allocator,
    cid: u32,
    writer: anytype,
    arena: std.mem.Allocator,
    jv: std.json.Value,
) !void {
    const Info = registry.BundleInfo(Bundle);
    inline for (0..Info.count) |ci| {
        const cid_u: u32 = @intCast(ci);
        if (cid_u == cid) {
            const CT = Info.typeAt(cid_u);
            const val = try std.json.parseFromValueLeaky(CT, arena, jv, .{});
            if (comptime serialize.hasCustomSerialization(CT)) {
                const owned = try serialize.serializeComponentToSlice(CT, val, allocator);
                defer allocator.free(owned);
                try writeU32(writer, @intCast(owned.len));
                try writer.writeAll(owned);
            } else {
                const stride = Info.elementStride(cid_u);
                const row_buf = try allocator.alloc(u8, stride);
                defer allocator.free(row_buf);
                @memset(row_buf, 0);
                @memcpy(row_buf[0..@sizeOf(CT)], std.mem.asBytes(&val)[0..@sizeOf(CT)]);
                try writer.writeAll(row_buf);
            }
            return;
        }
    }
    unreachable;
}

/// JSON: `{ "id": <u32>, "signature"?: <u64>, "components": { "<DeclName>": { ... }, ... } }`
/// Keys must match bundle declaration names (e.g. `P`, not the struct's type name).
pub fn readPrefabJson(comptime Bundle: type, allocator: std.mem.Allocator, json_slice: []const u8) !PrefabOwned {
    const Info = registry.BundleInfo(Bundle);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root_val = try std.json.parseFromSliceLeaky(std.json.Value, a, json_slice, .{});
    const obj = switch (root_val) {
        .object => |o| o,
        else => return error.InvalidPrefabJson,
    };

    const id = try jsonValueToU32(obj.get("id") orelse return error.MissingPrefabId);

    const comp_entry = obj.get("components") orelse return error.MissingPrefabComponents;
    const comp_obj = switch (comp_entry) {
        .object => |o| o,
        else => return error.InvalidPrefabJson,
    };

    var slots: [registry.max_components]?std.json.Value = @splat(null);
    var it = comp_obj.iterator();
    while (it.next()) |entry| {
        const cid = registry.idForDeclName(Bundle, entry.key_ptr.*) orelse return error.UnknownPrefabComponent;
        if (slots[cid] != null) return error.DuplicatePrefabComponent;
        slots[cid] = entry.value_ptr.*;
    }

    var derived_sig: u64 = 0;
    for (slots, 0..) |slot, i| {
        if (slot != null) derived_sig |= @as(u64, 1) << @intCast(i);
    }

    if (obj.get("signature")) |sig_val| {
        const expected = try jsonValueToU64(sig_val);
        if (expected != derived_sig) return error.PrefabSignatureMismatch;
    }

    var body: std.ArrayListUnmanaged(u8) = .{};
    defer body.deinit(allocator);
    const w = body.writer(allocator);

    inline for (0..Info.count) |ci| {
        const cid: u32 = @intCast(ci);
        if (slots[cid]) |jv| {
            try appendColumnPayload(Bundle, allocator, cid, w, a, jv);
        }
    }

    const data = try allocator.dupe(u8, body.items);
    errdefer allocator.free(data);

    return .{ .id = id, .signature = derived_sig, .data = data };
}

/// Build a full binary prefab file from component values (same layout as `readPrefabBinary`).
pub fn encodePrefabBinary(comptime Bundle: type, allocator: std.mem.Allocator, id: u32, comptime types: []const type, values: anytype) ![]u8 {
    const Info = registry.BundleInfo(Bundle);
    if (types.len != 0) {
        const V = @TypeOf(values);
        const fields = std.meta.fields(V);
        if (fields.len != types.len) @compileError("values tuple length must match types");
    }

    const sig = Info.maskMany(types);
    var body: std.ArrayListUnmanaged(u8) = .{};
    defer body.deinit(allocator);
    const w = body.writer(allocator);

    inline for (0..Info.count) |ci| {
        const cid: u32 = @intCast(ci);
        const bit = @as(u64, 1) << @intCast(cid);
        const CT = Info.typeAt(cid);
        if ((sig & bit) != 0) {
            inline for (types, 0..) |T, ti| {
                if (T != CT) continue;
                const val = values[ti];
                if (comptime serialize.hasCustomSerialization(CT)) {
                    const owned = try serialize.serializeComponentToSlice(CT, val, allocator);
                    defer allocator.free(owned);
                    try writeU32(w, @intCast(owned.len));
                    try w.writeAll(owned);
                } else {
                    const stride = Info.elementStride(cid);
                    const row_buf = try allocator.alloc(u8, stride);
                    defer allocator.free(row_buf);
                    @memset(row_buf, 0);
                    @memcpy(row_buf[0..@sizeOf(CT)], std.mem.asBytes(&val)[0..@sizeOf(CT)]);
                    try w.writeAll(row_buf);
                }
                break;
            }
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    const ow = out.writer(allocator);
    try writePrefabBinary(ow, id, sig, body.items);
    return try out.toOwnedSlice(allocator);
}
