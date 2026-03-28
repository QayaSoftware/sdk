const std = @import("std");
const prefab = @import("prefab.zig");
const registry = @import("registry.zig");
const serialize = @import("serialize.zig");
const World = @import("world.zig").World;

fn appendU32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try list.appendSlice(allocator, &b);
}

fn appendU64(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try list.appendSlice(allocator, &b);
}

const PodBundle = struct {
    pub const P = struct { x: f32, y: f32 };
    pub const V = struct { vx: f32, vy: f32 };
};

const CustomBundle = struct {
    pub const P = struct { x: f32, y: f32 };
    pub const V = struct {
        vx: f32,
        vy: f32,
        pub fn serialize(self: @This(), writer: anytype) !void {
            try writer.writeAll(std.mem.asBytes(&self.vx));
            try writer.writeAll(std.mem.asBytes(&self.vy));
        }
        pub fn deserialize(reader: anytype) !@This() {
            var vx: f32 = undefined;
            var vy: f32 = undefined;
            try reader.readNoEof(std.mem.asBytes(&vx));
            try reader.readNoEof(std.mem.asBytes(&vy));
            return .{ .vx = vx, .vy = vy };
        }
    };
};

test "prefab binary roundtrip and spawn (pod)" {
    const id: u32 = 42;
    const file_buf = try prefab.encodePrefabBinary(PodBundle, std.testing.allocator, id, &.{ PodBundle.P, PodBundle.V }, .{
        PodBundle.P{ .x = 3, .y = 4 },
        PodBundle.V{ .vx = 1, .vy = -1 },
    });
    defer std.testing.allocator.free(file_buf);

    var fbs = std.io.fixedBufferStream(file_buf);
    var owned = try prefab.readPrefabBinary(std.testing.allocator, fbs.reader());
    defer owned.deinit(std.testing.allocator);

    try std.testing.expectEqual(id, owned.id);
    try std.testing.expectEqual(file_buf.len, fbs.pos);

    var world = World(PodBundle).init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawnPrefab(owned.asRef());
    const p = world.get(e, PodBundle.P).?;
    try std.testing.expectApproxEqAbs(@as(f32, 3), p.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4), p.y, 1e-6);
    const v = world.get(e, PodBundle.V).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1), v.vx, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), v.vy, 1e-6);
}

test "prefab binary with custom serialization roundtrip" {
    try std.testing.expect(serialize.hasCustomSerialization(CustomBundle.V));

    const id: u32 = 9;
    const file_buf = try prefab.encodePrefabBinary(CustomBundle, std.testing.allocator, id, &.{ CustomBundle.P, CustomBundle.V }, .{
        CustomBundle.P{ .x = -1, .y = 2.5 },
        CustomBundle.V{ .vx = 0.25, .vy = 100 },
    });
    defer std.testing.allocator.free(file_buf);

    var fbs = std.io.fixedBufferStream(file_buf);
    var owned = try prefab.readPrefabBinary(std.testing.allocator, fbs.reader());
    defer owned.deinit(std.testing.allocator);

    var world = World(CustomBundle).init(std.testing.allocator);
    defer world.deinit();
    const e = try world.spawnPrefab(owned.asRef());
    const p = world.get(e, CustomBundle.P).?;
    try std.testing.expectApproxEqAbs(@as(f32, -1), p.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), p.y, 1e-6);
    const v = world.get(e, CustomBundle.V).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), v.vx, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 100), v.vy, 1e-6);
}

test "prefab writePrefabBinary readPrefabBinary payload split" {
    const id: u32 = 3;
    const sig = registry.BundleInfo(PodBundle).maskMany(&.{PodBundle.P});

    var body: std.ArrayList(u8) = .{};
    defer body.deinit(std.testing.allocator);
    try serialize.serializeComponent(PodBundle.P, .{ .x = 9, .y = 8 }, body.writer(std.testing.allocator));

    var file: std.ArrayList(u8) = .{};
    defer file.deinit(std.testing.allocator);
    try prefab.writePrefabBinary(file.writer(std.testing.allocator), id, sig, body.items);

    var fbs = std.io.fixedBufferStream(file.items);
    var owned = try prefab.readPrefabBinary(std.testing.allocator, fbs.reader());
    defer owned.deinit(std.testing.allocator);

    try std.testing.expectEqual(id, owned.id);
    try std.testing.expectEqual(sig, owned.signature);
    try std.testing.expectEqual(body.items.len, owned.data.len);

    var world = World(PodBundle).init(std.testing.allocator);
    defer world.deinit();
    const e = try world.spawnPrefab(owned.asRef());
    const p = world.get(e, PodBundle.P).?;
    try std.testing.expectApproxEqAbs(@as(f32, 9), p.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 8), p.y, 1e-6);
}

test "prefab json load pod and optional signature" {
    const mask_both = registry.BundleInfo(PodBundle).maskMany(&.{ PodBundle.P, PodBundle.V });

    const ok_json =
        \\{"id":7,"signature":3,"components":{"P":{"x":10,"y":20},"V":{"vx":0.5,"vy":1.5}}}
    ;
    var owned = try prefab.readPrefabJson(PodBundle, std.testing.allocator, ok_json);
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 7), owned.id);
    try std.testing.expectEqual(mask_both, owned.signature);

    var world = World(PodBundle).init(std.testing.allocator);
    defer world.deinit();
    const e = try world.spawnPrefab(owned.asRef());
    const p = world.get(e, PodBundle.P).?;
    try std.testing.expectApproxEqAbs(@as(f32, 10), p.x, 1e-6);
}

test "prefab json with custom component" {
    const json_text =
        \\{"id":2,"components":{"P":{"x":0,"y":0},"V":{"vx":1,"vy":2}}}
    ;
    var owned = try prefab.readPrefabJson(CustomBundle, std.testing.allocator, json_text);
    defer owned.deinit(std.testing.allocator);

    var world = World(CustomBundle).init(std.testing.allocator);
    defer world.deinit();
    const e = try world.spawnPrefab(owned.asRef());
    const v = world.get(e, CustomBundle.V).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1), v.vx, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2), v.vy, 1e-6);
}

test "prefab json numeric id as float" {
    const json_text = "{\"id\":99.0,\"components\":{\"P\":{\"x\":1,\"y\":2}}}";
    var owned = try prefab.readPrefabJson(PodBundle, std.testing.allocator, json_text);
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 99), owned.id);
}

test "prefab single component" {
    const buf = try prefab.encodePrefabBinary(PodBundle, std.testing.allocator, 0, &.{PodBundle.V}, .{
        PodBundle.V{ .vx = 3, .vy = 4 },
    });
    defer std.testing.allocator.free(buf);

    var fbs = std.io.fixedBufferStream(buf);
    var owned = try prefab.readPrefabBinary(std.testing.allocator, fbs.reader());
    defer owned.deinit(std.testing.allocator);

    var world = World(PodBundle).init(std.testing.allocator);
    defer world.deinit();
    const e = try world.spawnPrefab(owned.asRef());
    try std.testing.expect(world.get(e, PodBundle.P) == null);
    const v = world.get(e, PodBundle.V).?;
    try std.testing.expectApproxEqAbs(@as(f32, 3), v.vx, 1e-6);
}

test "prefab spawn many from same ref" {
    const buf = try prefab.encodePrefabBinary(PodBundle, std.testing.allocator, 1, &.{ PodBundle.P, PodBundle.V }, .{
        PodBundle.P{ .x = 1, .y = 2 },
        PodBundle.V{ .vx = 0, .vy = 0 },
    });
    defer std.testing.allocator.free(buf);

    var fbs = std.io.fixedBufferStream(buf);
    var owned = try prefab.readPrefabBinary(std.testing.allocator, fbs.reader());
    defer owned.deinit(std.testing.allocator);
    const r = owned.asRef();

    var world = World(PodBundle).init(std.testing.allocator);
    defer world.deinit();

    var n: usize = 0;
    while (n < 20) : (n += 1) {
        const e = try world.spawnPrefab(r);
        const p = world.get(e, PodBundle.P).?;
        try std.testing.expectApproxEqAbs(@as(f32, 1), p.x, 1e-6);
    }
    try std.testing.expectEqual(@as(usize, 20), n);
}

test "prefab binary rejects bad magic" {
    var raw: [32]u8 = undefined;
    std.mem.writeInt(u32, raw[0..4], 0xdeadbeef, .little);
    var fbs = std.io.fixedBufferStream(&raw);
    try std.testing.expectError(error.InvalidPrefabMagic, prefab.readPrefabBinary(std.testing.allocator, fbs.reader()));
}

test "prefab binary rejects bad version" {
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(std.testing.allocator);
    try appendU32(&list, std.testing.allocator, prefab.prefab_magic);
    try appendU32(&list, std.testing.allocator, 999);
    var fbs = std.io.fixedBufferStream(list.items);
    try std.testing.expectError(error.UnsupportedPrefabVersion, prefab.readPrefabBinary(std.testing.allocator, fbs.reader()));
}

test "prefab binary truncated payload" {
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(std.testing.allocator);
    try appendU32(&list, std.testing.allocator, prefab.prefab_magic);
    try appendU32(&list, std.testing.allocator, prefab.prefab_version);
    try appendU32(&list, std.testing.allocator, 1);
    try appendU64(&list, std.testing.allocator, 1);
    try appendU32(&list, std.testing.allocator, 1000);
    try list.appendSlice(std.testing.allocator, "short");

    var fbs = std.io.fixedBufferStream(list.items);
    try std.testing.expectError(error.EndOfStream, prefab.readPrefabBinary(std.testing.allocator, fbs.reader()));
}

test "prefab spawn fails on truncated column data" {
    const sig = registry.BundleInfo(PodBundle).maskMany(&.{ PodBundle.P, PodBundle.V });
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(std.testing.allocator);
    try prefab.writePrefabBinary(list.writer(std.testing.allocator), 1, sig, &[_]u8{0} ** 4);

    var fbs = std.io.fixedBufferStream(list.items);
    var owned = try prefab.readPrefabBinary(std.testing.allocator, fbs.reader());
    defer owned.deinit(std.testing.allocator);

    var world = World(PodBundle).init(std.testing.allocator);
    defer world.deinit();
    try std.testing.expectError(error.EndOfStream, world.spawnPrefab(owned.asRef()));
}

test "prefab json errors" {
    try std.testing.expectError(error.InvalidPrefabJson, prefab.readPrefabJson(PodBundle, std.testing.allocator, "[]"));

    try std.testing.expectError(error.MissingPrefabId, prefab.readPrefabJson(PodBundle, std.testing.allocator,
        \\{"components":{"P":{"x":1,"y":2}}}
    ));

    try std.testing.expectError(error.MissingPrefabComponents, prefab.readPrefabJson(PodBundle, std.testing.allocator,
        \\{"id":1}
    ));

    try std.testing.expectError(error.UnknownPrefabComponent, prefab.readPrefabJson(PodBundle, std.testing.allocator,
        \\{"id":1,"components":{"NotAComponent":{"x":1}}}
    ));

    // Duplicate object keys are rejected by `std.json` before we build the prefab payload.
    try std.testing.expectError(error.DuplicateField, prefab.readPrefabJson(PodBundle, std.testing.allocator,
        \\{"id":1,"components":{"P":{"x":1,"y":2},"P":{"x":0,"y":0}}}
    ));

    try std.testing.expectError(error.PrefabSignatureMismatch, prefab.readPrefabJson(PodBundle, std.testing.allocator,
        \\{"id":1,"signature":1,"components":{"P":{"x":1,"y":2},"V":{"vx":0,"vy":0}}}
    ));
}

test "prefab json invalid root" {
    try std.testing.expectError(error.InvalidPrefabJson, prefab.readPrefabJson(PodBundle, std.testing.allocator,
        \\{"id":1,"components":"nope"}
    ));
}

test "prefab json negative id" {
    try std.testing.expectError(error.InvalidPrefabId, prefab.readPrefabJson(PodBundle, std.testing.allocator,
        \\{"id":-5,"components":{"P":{"x":0,"y":0}}}
    ));
}

test "prefab json without optional signature field" {
    const json_text =
        \\{"id":100,"components":{"P":{"x":1,"y":2},"V":{"vx":3,"vy":4}}}
    ;
    var owned = try prefab.readPrefabJson(PodBundle, std.testing.allocator, json_text);
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 100), owned.id);
    const expected = registry.BundleInfo(PodBundle).maskMany(&.{ PodBundle.P, PodBundle.V });
    try std.testing.expectEqual(expected, owned.signature);
}

test "prefab spawns visible to chunked query" {
    const buf = try prefab.encodePrefabBinary(PodBundle, std.testing.allocator, 0, &.{ PodBundle.P, PodBundle.V }, .{
        PodBundle.P{ .x = 0, .y = 0 },
        PodBundle.V{ .vx = 0, .vy = 0 },
    });
    defer std.testing.allocator.free(buf);

    var fbs = std.io.fixedBufferStream(buf);
    var owned = try prefab.readPrefabBinary(std.testing.allocator, fbs.reader());
    defer owned.deinit(std.testing.allocator);

    var world = World(PodBundle).init(std.testing.allocator);
    defer world.deinit();

    var s: usize = 0;
    while (s < 37) : (s += 1) _ = try world.spawnPrefab(owned.asRef());

    var qc = world.queryChunked(&.{ PodBundle.P, PodBundle.V }, 8);
    var total: usize = 0;
    while (qc.next()) |ch| total += ch.len;
    try std.testing.expectEqual(@as(usize, 37), total);
}

test "prefab spawned entities survive snapshot roundtrip" {
    const buf = try prefab.encodePrefabBinary(PodBundle, std.testing.allocator, 1, &.{ PodBundle.P, PodBundle.V }, .{
        PodBundle.P{ .x = 11, .y = 22 },
        PodBundle.V{ .vx = 0.1, .vy = 0.2 },
    });
    defer std.testing.allocator.free(buf);

    var fbs = std.io.fixedBufferStream(buf);
    var owned = try prefab.readPrefabBinary(std.testing.allocator, fbs.reader());
    defer owned.deinit(std.testing.allocator);
    const r = owned.asRef();

    var world = World(PodBundle).init(std.testing.allocator);
    defer world.deinit();

    _ = try world.spawnPrefab(r);
    _ = try world.spawnPrefab(r);

    var snap: std.ArrayList(u8) = .{};
    defer snap.deinit(std.testing.allocator);
    try world.writeSnapshot(snap.writer(std.testing.allocator));

    world.reset();
    var snap_reader = std.io.fixedBufferStream(snap.items);
    try world.readSnapshot(snap_reader.reader());

    var q = world.query(&.{ PodBundle.P, PodBundle.V });
    var n: usize = 0;
    while (q.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "registry idForDeclName ordering matches prefab json" {
    const C = struct {
        pub const First = struct { a: i32 };
        pub const Second = struct { b: f32 };
    };
    try std.testing.expectEqual(@as(registry.ComponentId, 0), registry.idForDeclName(C, "First").?);
    try std.testing.expectEqual(@as(registry.ComponentId, 1), registry.idForDeclName(C, "Second").?);

    const sig = registry.BundleInfo(C).maskMany(&.{ C.First, C.Second });
    const json_text =
        \\{"id":0,"signature":3,"components":{"First":{"a":-5},"Second":{"b":2.5}}}
    ;
    var owned = try prefab.readPrefabJson(C, std.testing.allocator, json_text);
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectEqual(sig, owned.signature);

    var world = World(C).init(std.testing.allocator);
    defer world.deinit();
    const e = try world.spawnPrefab(owned.asRef());
    try std.testing.expectEqual(@as(i32, -5), world.get(e, C.First).?.a);
}
