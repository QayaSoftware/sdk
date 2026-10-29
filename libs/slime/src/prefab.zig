//! Prefabs: sets of component values to spawn entities from. Build and edit
//! them in code with `set` and `get`, at runtime by component id through
//! each component's `ComponentInfo`, or as JSON; ship them as JSON or in the
//! binary form. They follow `World`'s rules: `set` adds or overwrites,
//! `remove` returns whether it removed anything, `get` copies and `getPtr`
//! points.
//!
//! JSON names each component and spells out its fields; fields left out
//! take their defaults:
//!
//!     { "Position": { "x": 0, "y": 2 }, "Health": { "max": 100 }, "Enemy": {} }
//!
//! A component is named by its type's name without the namespace, or its
//! `component_name` declaration, or its full `@typeName` when two types
//! share a name. A type must be registered, by use or by `slime.register`,
//! before a prefab naming it is read.
const std = @import("std");
const Allocator = std.mem.Allocator;
const registry = @import("registry.zig");
const ComponentId = registry.ComponentId;
const ComponentInfo = registry.ComponentInfo;
const Mask = registry.Mask;
const World = @import("world.zig").World;
const Entity = @import("entity.zig").Entity;

/// What reading prefabs from a JSON tree can fail with.
pub const FromJsonError = std.json.ParseFromValueError || registry.FindError || error{ InvalidPrefab, ComponentNotSerializable };
/// What reading prefabs from JSON text can fail with.
pub const ReadJsonError = FromJsonError || std.json.ParseError(std.json.Reader);
/// What reading a binary prefab can fail with.
pub const ReadBinaryError = Allocator.Error || std.Io.Reader.Error || registry.FindError || error{ InvalidPrefabMagic, UnsupportedPrefabVersion, ComponentLayoutChanged };
/// What writing prefabs can fail with.
pub const WriteError = std.Io.Writer.Error || error{ComponentNotSerializable};

/// Where reading prefabs stopped.
pub const Diagnostics = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,
    /// Where the JSON text stopped making sense, when it did; 0 otherwise.
    line: u64 = 0,
    column: u64 = 0,

    /// The component, after its prefab's name when reading a library.
    pub fn where(self: *const Diagnostics) []const u8 {
        return self.buffer[0..self.len];
    }

    fn note(diagnostics: ?*Diagnostics, prefab: []const u8, component: []const u8) void {
        const self = diagnostics orelse return;
        var writer: std.Io.Writer = .fixed(&self.buffer);
        if (prefab.len > 0) writer.print("{s}: ", .{prefab}) catch {};
        writer.writeAll(component) catch {};
        self.len = writer.end;
    }
};

pub const Prefab = struct {
    gpa: Allocator,
    /// Ordered by id, which is the order spawning copies them in.
    components: std.ArrayList(Component) = .empty,
    mask: Mask = .empty,

    pub const Component = struct {
        id: ComponentId,
        info: *const ComponentInfo,
        bytes: []u8,

        pub fn as(self: Component, comptime T: type) *T {
            std.debug.assert(self.id == registry.id(T));
            return @ptrCast(@alignCast(self.bytes.ptr));
        }
    };

    pub const magic = "SLPF".*;
    pub const version: u16 = 2;

    pub fn init(gpa: Allocator) Prefab {
        return .{ .gpa = gpa };
    }

    /// A prefab of `bundle`, a tuple of component values such as
    /// `.{ Position{ .x = 1 }, Enemy{} }`.
    pub fn from(gpa: Allocator, bundle: anytype) Allocator.Error!Prefab {
        _ = comptime registry.bundleTypes(@TypeOf(bundle));
        var prefab: Prefab = .init(gpa);
        errdefer prefab.deinit();
        inline for (bundle) |value| try prefab.set(value);
        return prefab;
    }

    /// A prefab of `e`'s components as they are now.
    pub fn fromEntity(gpa: Allocator, world: *const World, e: Entity) (Allocator.Error || error{DeadEntity})!Prefab {
        const ids = world.componentIds(e) orelse return error.DeadEntity;
        var prefab: Prefab = .init(gpa);
        errdefer prefab.deinit();
        for (ids) |cid| try prefab.setRaw(cid, world.getRaw(e, cid).?);
        return prefab;
    }

    pub fn clone(self: *const Prefab, gpa: Allocator) Allocator.Error!Prefab {
        var copy: Prefab = .init(gpa);
        errdefer copy.deinit();
        for (self.components.items) |component| try copy.setRaw(component.id, component.bytes);
        return copy;
    }

    pub fn deinit(self: *Prefab) void {
        for (self.components.items) |component| freeBytes(self.gpa, component);
        self.components.deinit(self.gpa);
        self.* = undefined;
    }

    /// Adds `value`'s component, or overwrites it.
    pub fn set(self: *Prefab, value: anytype) Allocator.Error!void {
        @memcpy(try self.slot(registry.infoOf(@TypeOf(value))), std.mem.asBytes(&value));
    }

    pub fn has(self: *const Prefab, comptime T: type) bool {
        return self.mask.has(registry.id(T));
    }

    pub fn get(self: *const Prefab, comptime T: type) ?T {
        const value = self.getPtr(T) orelse return null;
        return value.*;
    }

    pub fn getPtr(self: *const Prefab, comptime T: type) ?*T {
        const bytes = self.getRaw(registry.id(T)) orelse return null;
        return @ptrCast(@alignCast(bytes.ptr));
    }

    /// Returns whether the prefab had a `T`.
    pub fn remove(self: *Prefab, comptime T: type) bool {
        return self.removeRaw(registry.id(T));
    }

    /// Adds the `cid` component from `bytes`, or overwrites it.
    pub fn setRaw(self: *Prefab, cid: ComponentId, bytes: []const u8) Allocator.Error!void {
        @memcpy(try self.slot(registry.info(cid)), bytes);
    }

    /// Adds the `cid` component at its type's default, or resets it to it.
    pub fn setDefault(self: *Prefab, cid: ComponentId) (Allocator.Error || error{NoDefault})!void {
        const value = registry.info(cid).defaultBytes() orelse return error.NoDefault;
        try self.setRaw(cid, value);
    }

    pub fn getRaw(self: *const Prefab, cid: ComponentId) ?[]u8 {
        const at = self.position(cid);
        if (at == self.components.items.len or self.components.items[at].id != cid) return null;
        return self.components.items[at].bytes;
    }

    /// Returns whether the prefab had the `cid` component.
    pub fn removeRaw(self: *Prefab, cid: ComponentId) bool {
        const at = self.position(cid);
        if (at == self.components.items.len or self.components.items[at].id != cid) return false;
        freeBytes(self.gpa, self.components.orderedRemove(at));
        self.mask = self.mask.without(cid);
        return true;
    }

    /// The bytes of `info`'s component, added unset if missing.
    fn slot(self: *Prefab, info: *const ComponentInfo) Allocator.Error![]u8 {
        const cid = info.id();
        const at = self.position(cid);
        if (at < self.components.items.len and self.components.items[at].id == cid) return self.components.items[at].bytes;
        const component: Component = .{ .id = cid, .info = info, .bytes = try allocBytes(self.gpa, info) };
        errdefer freeBytes(self.gpa, component);
        try self.components.insert(self.gpa, at, component);
        self.mask = self.mask.with(cid);
        return component.bytes;
    }

    fn position(self: *const Prefab, cid: ComponentId) usize {
        return std.sort.lowerBound(Component, self.components.items, cid, struct {
            fn order(target: ComponentId, component: Component) std.math.Order {
                return std.math.order(target, component.id);
            }
        }.order);
    }

    /// Reads a prefab from JSON text.
    pub fn readJson(gpa: Allocator, reader: *std.Io.Reader, diagnostics: ?*Diagnostics) ReadJsonError!Prefab {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const source = try parseJsonText(arena.allocator(), reader, diagnostics);
        return fromJson(gpa, arena.allocator(), source, diagnostics);
    }

    /// Reads a prefab from a parsed JSON object; `scratch` holds what
    /// reading the components allocates.
    pub fn fromJson(gpa: Allocator, scratch: Allocator, source: std.json.Value, diagnostics: ?*Diagnostics) FromJsonError!Prefab {
        return fromJsonNamed(gpa, scratch, source, diagnostics, "");
    }

    fn fromJsonNamed(gpa: Allocator, scratch: Allocator, source: std.json.Value, diagnostics: ?*Diagnostics, name: []const u8) FromJsonError!Prefab {
        if (source != .object) {
            Diagnostics.note(diagnostics, name, "");
            return error.InvalidPrefab;
        }
        var prefab: Prefab = .init(gpa);
        errdefer prefab.deinit();
        var entries = source.object.iterator();
        while (entries.next()) |entry| {
            errdefer Diagnostics.note(diagnostics, name, entry.key_ptr.*);
            const info = try registry.find(entry.key_ptr.*);
            try info.parseJson(scratch, entry.value_ptr.*, try prefab.slot(info));
        }
        return prefab;
    }

    pub fn writeJson(self: *const Prefab, writer: *std.Io.Writer, options: std.json.Stringify.Options) WriteError!void {
        try self.checkJson();
        var jw: std.json.Stringify = .{ .writer = writer, .options = options };
        try self.jsonStringify(&jw);
    }

    fn checkJson(self: *const Prefab) error{ComponentNotSerializable}!void {
        for (self.components.items) |component| if (component.info.json == null) return error.ComponentNotSerializable;
    }

    /// Lets the prefab sit inside any value `std.json` writes; fails on a
    /// component that cannot be saved, which `writeJson` names.
    pub fn jsonStringify(self: Prefab, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.beginObject();
        for (self.components.items) |component| {
            try jw.objectField(savedName(component.info));
            const json = component.info.json orelse return error.WriteFailed;
            try json.write(component.bytes.ptr, jw);
        }
        try jw.endObject();
    }

    /// Lets the prefab sit inside any value `std.json` reads.
    pub fn jsonParse(gpa: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Prefab {
        const value = try std.json.innerParse(std.json.Value, gpa, source, options);
        return jsonParseFromValue(gpa, value, options);
    }

    pub fn jsonParseFromValue(gpa: Allocator, source: std.json.Value, _: std.json.ParseOptions) std.json.ParseFromValueError!Prefab {
        return fromJson(gpa, gpa, source, null) catch |err| switch (err) {
            error.UnknownComponent, error.AmbiguousComponent => error.UnknownField,
            error.ComponentNotSerializable, error.InvalidPrefab => error.UnexpectedToken,
            else => |other| other,
        };
    }

    /// Writes the components' bytes as they are in memory, behind a header
    /// naming each and its layout; it loads on machines of the same
    /// endianness, and only while the layouts stay the same.
    pub fn writeBinary(self: *const Prefab, writer: *std.Io.Writer) WriteError!void {
        for (self.components.items) |component| if (!component.info.plain) return error.ComponentNotSerializable;
        try writer.writeAll(&magic);
        try writer.writeInt(u16, version, .little);
        try writer.writeInt(u16, @intCast(self.components.items.len), .little);
        for (self.components.items) |component| {
            const name = savedName(component.info);
            try writer.writeInt(u16, @intCast(name.len), .little);
            try writer.writeAll(name);
            try writer.writeInt(u64, component.info.layout, .little);
            try writer.writeInt(u32, @intCast(component.info.size), .little);
            try writer.writeAll(component.bytes);
        }
    }

    pub fn readBinary(gpa: Allocator, reader: *std.Io.Reader, diagnostics: ?*Diagnostics) ReadBinaryError!Prefab {
        if (!std.mem.eql(u8, try reader.takeArray(magic.len), &magic)) return error.InvalidPrefabMagic;
        if (try reader.takeInt(u16, .little) != version) return error.UnsupportedPrefabVersion;
        const count = try reader.takeInt(u16, .little);
        var prefab: Prefab = .init(gpa);
        errdefer prefab.deinit();
        for (0..count) |_| {
            const name = try reader.take(try reader.takeInt(u16, .little));
            const info = registry.find(name) catch |err| {
                Diagnostics.note(diagnostics, "", name);
                return err;
            };
            errdefer Diagnostics.note(diagnostics, "", info.name);
            if (try reader.takeInt(u64, .little) != info.layout) return error.ComponentLayoutChanged;
            if (try reader.takeInt(u32, .little) != info.size) return error.ComponentLayoutChanged;
            try reader.readSliceAll(try prefab.slot(info));
        }
        return prefab;
    }
};

/// Prefabs by name, kept as one JSON object of them:
///
///     { "goblin": { "Position": { "x": 0, "y": 0 } }, "orc": { ... } }
pub const PrefabLibrary = struct {
    gpa: Allocator,
    prefabs: std.StringArrayHashMapUnmanaged(Prefab) = .empty,

    pub fn init(gpa: Allocator) PrefabLibrary {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *PrefabLibrary) void {
        var entries = self.prefabs.iterator();
        while (entries.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.prefabs.deinit(self.gpa);
    }

    /// The names, in the order they were first set.
    pub fn names(self: *const PrefabLibrary) []const []const u8 {
        return self.prefabs.keys();
    }

    pub fn getPtr(self: *const PrefabLibrary, name: []const u8) ?*Prefab {
        return self.prefabs.getPtr(name);
    }

    /// Takes ownership of `prefab`, even when it fails, replacing any
    /// prefab called `name`.
    pub fn set(self: *PrefabLibrary, name: []const u8, prefab: Prefab) Allocator.Error!void {
        var owned = prefab;
        if (self.prefabs.getPtr(name)) |existing| {
            existing.deinit();
            existing.* = owned;
            return;
        }
        errdefer owned.deinit();
        const key = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(key);
        try self.prefabs.put(self.gpa, key, owned);
    }

    /// Returns whether there was a prefab called `name`.
    pub fn remove(self: *PrefabLibrary, name: []const u8) bool {
        const entry = self.prefabs.fetchOrderedRemove(name) orelse return false;
        self.gpa.free(entry.key);
        var prefab = entry.value;
        prefab.deinit();
        return true;
    }

    /// Sets the prefabs in the JSON text, replacing those of the same names;
    /// when it fails, the library is as it was.
    pub fn readJson(self: *PrefabLibrary, reader: *std.Io.Reader, diagnostics: ?*Diagnostics) ReadJsonError!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const source = try parseJsonText(arena.allocator(), reader, diagnostics);
        if (source != .object) return error.InvalidPrefab;
        const entries = &source.object;
        const loaded = try arena.allocator().alloc(Prefab, entries.count());
        var made: usize = 0;
        errdefer for (loaded[0..made]) |*prefab| prefab.deinit();
        for (entries.keys(), entries.values()) |name, value| {
            loaded[made] = try Prefab.fromJsonNamed(self.gpa, arena.allocator(), value, diagnostics, name);
            made += 1;
        }
        const keys = try arena.allocator().alloc(?[]u8, loaded.len);
        @memset(keys, null);
        errdefer for (keys) |key| if (key) |owned| self.gpa.free(owned);
        for (entries.keys(), keys) |name, *key| {
            if (!self.prefabs.contains(name)) key.* = try self.gpa.dupe(u8, name);
        }
        try self.prefabs.ensureUnusedCapacity(self.gpa, loaded.len);
        for (entries.keys(), loaded, keys) |name, prefab, key| {
            if (self.prefabs.getPtr(name)) |existing| {
                existing.deinit();
                existing.* = prefab;
            } else {
                self.prefabs.putAssumeCapacityNoClobber(key.?, prefab);
            }
        }
    }

    pub fn writeJson(self: *const PrefabLibrary, writer: *std.Io.Writer, options: std.json.Stringify.Options) WriteError!void {
        for (self.prefabs.values()) |*prefab| try prefab.checkJson();
        var jw: std.json.Stringify = .{ .writer = writer, .options = options };
        try jw.beginObject();
        for (self.prefabs.keys(), self.prefabs.values()) |name, prefab| {
            try jw.objectField(name);
            try prefab.jsonStringify(&jw);
        }
        try jw.endObject();
    }
};

fn parseJsonText(arena: Allocator, reader: *std.Io.Reader, diagnostics: ?*Diagnostics) std.json.ParseError(std.json.Reader)!std.json.Value {
    var json: std.json.Reader = .init(arena, reader);
    var place: std.json.Diagnostics = .{};
    json.enableDiagnostics(&place);
    return std.json.parseFromTokenSourceLeaky(std.json.Value, arena, &json, .{}) catch |err| {
        if (diagnostics) |d| {
            d.line = place.getLine();
            d.column = place.getColumn();
        }
        return err;
    };
}

/// The name a component is saved under: its short name, unless another
/// registered type shares it.
fn savedName(info: *const ComponentInfo) []const u8 {
    const found = registry.find(info.name) catch return info.type_name;
    return if (found == info) info.name else info.type_name;
}

fn allocBytes(gpa: Allocator, info: *const ComponentInfo) Allocator.Error![]u8 {
    if (info.size == 0) return @as([*]u8, @ptrFromInt(info.alignment.toByteUnits()))[0..0];
    const ptr = gpa.rawAlloc(info.size, info.alignment, @returnAddress()) orelse return error.OutOfMemory;
    return ptr[0..info.size];
}

fn freeBytes(gpa: Allocator, component: Prefab.Component) void {
    if (component.bytes.len != 0) gpa.rawFree(component.bytes, component.info.alignment, @returnAddress());
}
