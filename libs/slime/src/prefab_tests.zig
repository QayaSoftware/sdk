const std = @import("std");
const slime = @import("root.zig");
const Prefab = slime.Prefab;
const PrefabLibrary = slime.PrefabLibrary;
const World = slime.World;
const registry = slime.registry;

const testing = std.testing;

const Location = struct { x: f32 = 0, y: f32 = 0 };
const Health = struct {
    current: i32 = 100,
    max: i32 = 100,
    regen: f32 = 0,
};
const Team = enum { red, blue };
const Faction = struct {
    pub const component_name = "faction";
    team: Team = .red,
    tags: [3]u8 = .{ 0, 0, 0 },
    leader: ?u32 = null,
};
const Enemy = struct {};
const Marker = struct { x: f32 = 0 };
const Transform = struct { matrix: [16]f32 = @splat(0) };
const Handle = struct { target: *u32 };

fn transform(value: f32) Transform {
    return .{ .matrix = @splat(value) };
}

fn testWorld() World {
    return .init(testing.allocator, testing.io);
}

fn readJson(text: []const u8, diagnostics: ?*slime.prefab.Diagnostics) !Prefab {
    var reader: std.Io.Reader = .fixed(text);
    return Prefab.readJson(testing.allocator, &reader, diagnostics);
}

fn readLibrary(library: *PrefabLibrary, text: []const u8, diagnostics: ?*slime.prefab.Diagnostics) !void {
    var reader: std.Io.Reader = .fixed(text);
    try library.readJson(&reader, diagnostics);
}

fn registerAll() void {
    slime.register(&.{ Location, Health, Faction, Enemy, Transform });
}

test "build in code, spawn, and edit" {
    var goblin = try Prefab.from(testing.allocator, .{ Location{ .x = 1, .y = 2 }, Health{ .max = 30, .current = 30 }, Enemy{} });
    defer goblin.deinit();
    try testing.expect(goblin.has(Enemy));
    goblin.getPtr(Health).?.regen = 0.5;
    try goblin.set(Location{ .x = 5, .y = 5 });
    try testing.expectEqual(@as(usize, 3), goblin.components.items.len);

    var world = testWorld();
    defer world.deinit();
    const e = try world.spawnPrefab(&goblin);
    try testing.expectEqual(Location{ .x = 5, .y = 5 }, world.get(e, Location).?);
    try testing.expectEqual(@as(f32, 0.5), world.get(e, Health).?.regen);
    try testing.expect(world.has(e, Enemy));

    try testing.expect(goblin.remove(Enemy));
    try testing.expect(!goblin.remove(Enemy));
    try testing.expect(!world.has(try world.spawnPrefab(&goblin), Enemy));
}

test "prefabs with components larger than 16 bytes spawn side by side" {
    var a = try Prefab.from(testing.allocator, .{transform(1)});
    defer a.deinit();
    var b = try Prefab.from(testing.allocator, .{transform(2)});
    defer b.deinit();
    var world = testWorld();
    defer world.deinit();
    const first = try world.spawnPrefab(&a);
    const second = try world.spawnPrefab(&b);
    try testing.expectEqual(transform(1), world.get(first, Transform).?);
    try testing.expectEqual(transform(2), world.get(second, Transform).?);
}

test "JSON round trip, with defaults filling what is left out" {
    registerAll();
    const text =
        \\{
        \\  "Location": { "x": 3 },
        \\  "Health": { "max": 250 },
        \\  "faction": { "team": "blue", "leader": 7 },
        \\  "Enemy": {}
        \\}
    ;
    var prefab = try readJson(text, null);
    defer prefab.deinit();
    try testing.expectEqual(Location{ .x = 3, .y = 0 }, prefab.get(Location).?);
    try testing.expectEqual(Health{ .current = 100, .max = 250 }, prefab.get(Health).?);
    try testing.expectEqual(Team.blue, prefab.get(Faction).?.team);
    try testing.expectEqual(@as(?u32, 7), prefab.get(Faction).?.leader);
    try testing.expect(prefab.has(Enemy));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try prefab.writeJson(&out.writer, .{ .whitespace = .indent_2 });
    var again = try readJson(out.written(), null);
    defer again.deinit();
    try testing.expectEqual(prefab.components.items.len, again.components.items.len);
    for (prefab.components.items, again.components.items) |a, b| try testing.expectEqualSlices(u8, a.bytes, b.bytes);
}

test "JSON errors say which component" {
    registerAll();
    var diagnostics: slime.prefab.Diagnostics = .{};
    try testing.expectError(error.UnknownComponent, readJson("{\"Location\":{},\"Helth\":{}}", &diagnostics));
    try testing.expectEqualStrings("Helth", diagnostics.where());
    try testing.expectError(error.UnknownField, readJson("{\"Health\":{\"maxx\":1}}", &diagnostics));
    try testing.expectEqualStrings("Health", diagnostics.where());
    try testing.expectError(error.InvalidPrefab, readJson("[1, 2]", &diagnostics));
    try testing.expectError(error.SyntaxError, readJson("{\n  \"Health\": { \"max\": 1 },\n  \"Enemy\": {,\n}", &diagnostics));
    try testing.expectEqual(@as(u64, 3), diagnostics.line);
    try testing.expectEqual(@as(u64, 13), diagnostics.column);
}

test "components holding pointers stay in memory only" {
    var target: u32 = 5;
    var prefab = try Prefab.from(testing.allocator, .{ Location{}, Handle{ .target = &target } });
    defer prefab.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.ComponentNotSerializable, prefab.writeJson(&out.writer, .{}));
    try testing.expectError(error.ComponentNotSerializable, prefab.writeBinary(&out.writer));
    try testing.expect(registry.infoOf(Handle).json == null);

    var world = testWorld();
    defer world.deinit();
    const e = try world.spawnPrefab(&prefab);
    try testing.expectEqual(@as(u32, 5), world.get(e, Handle).?.target.*);
}

test "binary round trip refuses changed layouts" {
    registerAll();
    var prefab = try Prefab.from(testing.allocator, .{ Location{ .x = 1, .y = 2 }, transform(3), Enemy{} });
    defer prefab.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try prefab.writeBinary(&out.writer);

    var reader: std.Io.Reader = .fixed(out.written());
    var back = try Prefab.readBinary(testing.allocator, &reader, null);
    defer back.deinit();
    try testing.expectEqual(transform(3), back.get(Transform).?);
    try testing.expectEqual(out.written().len, reader.seek);

    const bytes = try testing.allocator.dupe(u8, out.written());
    defer testing.allocator.free(bytes);
    const layout_at = std.mem.indexOf(u8, bytes, "Location").? + "Location".len;
    bytes[layout_at] +%= 1;
    var diagnostics: slime.prefab.Diagnostics = .{};
    var changed: std.Io.Reader = .fixed(bytes);
    try testing.expectError(error.ComponentLayoutChanged, Prefab.readBinary(testing.allocator, &changed, &diagnostics));
    try testing.expectEqualStrings("Location", diagnostics.where());

    var bad: std.Io.Reader = .fixed("NOPE\x02\x00");
    try testing.expectError(error.InvalidPrefabMagic, Prefab.readBinary(testing.allocator, &bad, null));
    var short: std.Io.Reader = .fixed(out.written()[0 .. out.written().len - 3]);
    try testing.expectError(error.EndOfStream, Prefab.readBinary(testing.allocator, &short, null));
}

test "capture an entity, then apply a prefab over another" {
    var world = testWorld();
    defer world.deinit();
    const source = try world.spawn(.{ Location{ .x = 4, .y = 4 }, Health{ .current = 1 } });
    var captured = try Prefab.fromEntity(testing.allocator, &world, source);
    defer captured.deinit();
    try testing.expectEqual(@as(i32, 1), captured.get(Health).?.current);

    const target = try world.spawn(.{ Location{ .x = 0, .y = 0 }, Enemy{} });
    try world.applyPrefab(target, &captured);
    try testing.expectEqual(Location{ .x = 4, .y = 4 }, world.get(target, Location).?);
    try testing.expectEqual(@as(i32, 1), world.get(target, Health).?.current);
    try testing.expect(world.has(target, Enemy));
}

test "editing at runtime through component metadata" {
    registerAll();
    const info = try registry.find("Health");
    try testing.expectEqual(@as(usize, 3), info.fields.len);
    try testing.expectEqualStrings("max", info.fields[1].name);
    try testing.expectEqual(@offsetOf(Health, "max"), info.fields[1].offset);
    try testing.expectEqual(std.lang.TypeId.int, info.fields[1].kind);
    try testing.expect(registry.infoOf(Handle).default == null);

    var prefab: Prefab = .init(testing.allocator);
    defer prefab.deinit();
    try prefab.setDefault(info.id());
    try testing.expectEqual(Health{}, prefab.get(Health).?);
    try testing.expectError(error.NoDefault, prefab.setDefault(registry.id(Handle)));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const bytes = prefab.getRaw(info.id()).?;
    var value = try info.toJsonValue(arena.allocator(), bytes);
    try value.object.put(arena.allocator(), "regen", .{ .float = 2.5 });
    try info.parseJson(arena.allocator(), value, bytes);
    try testing.expectEqual(@as(f32, 2.5), prefab.get(Health).?.regen);
    try testing.expectEqual(@as(i32, 100), prefab.get(Health).?.max);
}

test "names: short, declared, or full when shared" {
    const Inner = struct {
        const Marker = struct { x: f32 = 0 };
    };
    registerAll();
    slime.register(&.{ Marker, Inner.Marker });
    try testing.expectEqualStrings("faction", registry.infoOf(Faction).name);
    try testing.expectError(error.AmbiguousComponent, registry.find("Marker"));
    try testing.expectEqual(registry.infoOf(Inner.Marker), try registry.find(@typeName(Inner.Marker)));

    var prefab = try Prefab.from(testing.allocator, .{ Marker{ .x = 1 }, Inner.Marker{ .x = 2 } });
    defer prefab.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try prefab.writeJson(&out.writer, .{});
    var back = try readJson(out.written(), null);
    defer back.deinit();
    try testing.expectEqual(@as(f32, 2), back.get(Inner.Marker).?.x);
}

test "a library loads, edits and saves many prefabs, and survives a bad load" {
    registerAll();
    var library: PrefabLibrary = .init(testing.allocator);
    defer library.deinit();
    try readLibrary(&library,
        \\{
        \\  "goblin": { "Health": { "max": 30 }, "Enemy": {} },
        \\  "chest": { "Location": { "y": 1 } }
        \\}
    , null);
    try testing.expectEqual(@as(usize, 2), library.names().len);
    library.getPtr("goblin").?.getPtr(Health).?.current = 30;

    var diagnostics: slime.prefab.Diagnostics = .{};
    try testing.expectError(error.UnknownComponent, readLibrary(&library, "{\"chest\":{},\"orc\":{\"Hp\":{}}}", &diagnostics));
    try testing.expectEqualStrings("orc: Hp", diagnostics.where());
    try testing.expect(library.getPtr("chest").?.has(Location));
    try testing.expect(library.getPtr("orc") == null);

    try readLibrary(&library, "{\"chest\":{\"Enemy\":{}},\"orc\":{\"Health\":{}}}", null);
    try testing.expect(!library.getPtr("chest").?.has(Location));
    try library.set("rock", try Prefab.from(testing.allocator, .{Location{}}));
    try testing.expect(library.remove("rock"));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try library.writeJson(&out.writer, .{});
    var reloaded: PrefabLibrary = .init(testing.allocator);
    defer reloaded.deinit();
    try readLibrary(&reloaded, out.written(), null);
    try testing.expectEqual(@as(i32, 30), reloaded.getPtr("goblin").?.get(Health).?.current);

    var world = testWorld();
    defer world.deinit();
    const e = try world.spawnPrefab(reloaded.getPtr("orc").?);
    try testing.expectEqual(@as(i32, 100), world.get(e, Health).?.max);
}

test "prefabs sit inside other std.json documents" {
    registerAll();
    const Level = struct {
        name: []const u8,
        spawns: []const struct { at: Location, prefab: Prefab },
    };
    const parsed = try std.json.parseFromSlice(Level, testing.allocator,
        \\{ "name": "cave", "spawns": [ { "at": { "x": 1, "y": 1 }, "prefab": { "Enemy": {}, "Health": { "max": 5 } } } ] }
    , .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i32, 5), parsed.value.spawns[0].prefab.get(Health).?.max);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"Health\":{\"current\":100,\"max\":5") != null);
}
