//! Every type used as a component, resource or event gets a dense id the
//! first time it is used, shared by every `World` in the process, along with
//! the runtime description prefabs and editors work from. Registration is
//! lock-free and safe from any thread.
const std = @import("std");
const options = @import("options");

/// How many distinct types the process can use: `-Dslime-max-components`.
pub const max_components: usize = options.max_components;

/// A type's dense id, below `max_components`.
pub const ComponentId = u16;

/// A set of component ids, one bit each, in 64-bit words: wider integers
/// cost several times as much to shift, count and hash.
pub const Mask = struct {
    words: [word_count]u64 = @splat(0),

    pub const word_count = (max_components + 63) / 64;
    pub const empty: Mask = .{};

    pub fn of(cid: ComponentId) Mask {
        var mask: Mask = .empty;
        mask.words[cid >> 6] = @as(u64, 1) << @truncate(cid);
        return mask;
    }

    pub fn has(self: Mask, cid: ComponentId) bool {
        return self.words[cid >> 6] >> @truncate(cid) & 1 != 0;
    }

    pub fn with(self: Mask, cid: ComponentId) Mask {
        var mask = self;
        mask.words[cid >> 6] |= @as(u64, 1) << @truncate(cid);
        return mask;
    }

    pub fn without(self: Mask, cid: ComponentId) Mask {
        var mask = self;
        mask.words[cid >> 6] &= ~(@as(u64, 1) << @truncate(cid));
        return mask;
    }

    pub fn unite(self: Mask, other: Mask) Mask {
        var mask = self;
        for (&mask.words, other.words) |*word, theirs| word.* |= theirs;
        return mask;
    }

    /// Whether every id in `other` is in `self`.
    pub fn contains(self: Mask, other: Mask) bool {
        var missing: u64 = 0;
        for (self.words, other.words) |mine, theirs| missing |= theirs & ~mine;
        return missing == 0;
    }

    pub fn intersects(self: Mask, other: Mask) bool {
        var shared: u64 = 0;
        for (self.words, other.words) |mine, theirs| shared |= mine & theirs;
        return shared != 0;
    }

    pub fn eql(self: Mask, other: Mask) bool {
        return std.mem.eql(u64, &self.words, &other.words);
    }

    pub fn isEmpty(self: Mask) bool {
        return self.eql(.empty);
    }

    pub fn count(self: Mask) usize {
        var total: usize = 0;
        for (self.words) |word| total += @popCount(word);
        return total;
    }

    /// The ids, ascending.
    pub fn iterator(self: Mask) Iterator {
        return .{ .mask = self };
    }

    pub const Iterator = struct {
        mask: Mask,
        word: usize = 0,

        pub fn next(self: *Iterator) ?ComponentId {
            while (self.word < word_count) {
                const bits = self.mask.words[self.word];
                if (bits != 0) {
                    self.mask.words[self.word] = bits & (bits - 1);
                    return @intCast(self.word * 64 + @ctz(bits));
                }
                self.word += 1;
            }
            return null;
        }
    };

    /// For hash maps keyed by masks.
    pub const Context = struct {
        pub fn hash(_: Context, mask: Mask) u64 {
            var h: u64 = 0;
            for (mask.words) |word| h = std.math.rotl(u64, h ^ word, 29) *% 0x9e3779b97f4a7c15;
            return h ^ h >> 32;
        }

        pub fn eql(_: Context, a: Mask, b: Mask) bool {
            return a.eql(b);
        }
    };
};

comptime {
    if (max_components == 0 or max_components > std.math.maxInt(ComponentId)) @compileError("slime: -Dslime-max-components must be between 1 and 65535");
}

const unassigned = std.math.maxInt(ComponentId);

var handed_out: std.atomic.Value(u32) = .init(0);
var infos: [max_components]std.atomic.Value(?*const ComponentInfo) = @splat(.init(null));

/// What slime knows about a type at runtime.
pub const ComponentInfo = struct {
    /// What prefabs and editors call it: the type's `component_name` if it
    /// declares one, otherwise its name without the namespace.
    name: []const u8,
    /// `@typeName` of the type.
    type_name: []const u8,
    size: usize,
    alignment: std.mem.Alignment,
    /// A hash of the layout, which changes when a field, its type or its
    /// place changes; binary prefabs refuse data saved with another.
    layout: u64,
    /// The fields of a struct, in declaration order; empty otherwise.
    fields: []const Field,
    /// The value an editor starts a new component at: the type's
    /// `pub const default`, or `.{}` when every field has a default.
    default: ?*const anyopaque,
    /// Null when the type holds pointers, vectors (which `std.json` cannot
    /// read back) or anything else that cannot be saved, unless it declares
    /// `jsonStringify` and `jsonParseFromValue`.
    json: ?Json,
    /// Whether the bytes alone are the whole value, so binary prefabs can
    /// save them.
    plain: bool,
    slot: *std.atomic.Value(ComponentId),

    pub const Field = struct {
        name: []const u8,
        type_name: []const u8,
        /// Byte offset; in a packed struct, the byte holding the first bit.
        offset: usize,
        size: usize,
        kind: std.lang.TypeId,
    };

    pub const Json = struct {
        write: *const fn (value: *const anyopaque, jw: *std.json.Stringify) std.json.Stringify.Error!void,
        parse: *const fn (arena: std.mem.Allocator, source: std.json.Value, out: *anyopaque) std.json.ParseFromValueError!void,
    };

    /// The id, registering the type if nothing has used it yet.
    pub fn id(self: *const ComponentInfo) ComponentId {
        const known = self.slot.load(.acquire);
        if (known != unassigned) return known;
        return assign(self);
    }

    /// The default value's bytes.
    pub fn defaultBytes(self: *const ComponentInfo) ?[]const u8 {
        const value = self.default orelse return null;
        return @as([*]const u8, @ptrCast(value))[0..self.size];
    }

    /// Writes the component at `bytes` as JSON.
    pub fn writeJson(self: *const ComponentInfo, bytes: []const u8, jw: *std.json.Stringify) (std.json.Stringify.Error || error{ComponentNotSerializable})!void {
        std.debug.assert(bytes.len == self.size);
        const json = self.json orelse return error.ComponentNotSerializable;
        try json.write(bytes.ptr, jw);
    }

    /// Parses `source` into the component at `bytes`. `arena` holds what
    /// the parse allocates.
    pub fn parseJson(self: *const ComponentInfo, arena: std.mem.Allocator, source: std.json.Value, bytes: []u8) (std.json.ParseFromValueError || error{ComponentNotSerializable})!void {
        std.debug.assert(bytes.len == self.size);
        const json = self.json orelse return error.ComponentNotSerializable;
        try json.parse(arena, source, bytes.ptr);
    }

    /// The component at `bytes` as a JSON tree, for an editor to change and
    /// hand back to `parseJson`.
    pub fn toJsonValue(self: *const ComponentInfo, arena: std.mem.Allocator, bytes: []const u8) (std.mem.Allocator.Error || std.json.ParseError(std.json.Scanner) || error{ComponentNotSerializable})!std.json.Value {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        self.writeJson(bytes, &jw) catch |err| return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => |e| e,
        };
        return std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    }

    fn of(comptime T: type, slot: *std.atomic.Value(ComponentId)) ComponentInfo {
        @setEvalBranchQuota(100_000);
        return .{
            .name = nameOf(T),
            .type_name = @typeName(T),
            .size = @sizeOf(T),
            .alignment = .fromByteUnits(@alignOf(T)),
            .layout = comptime layoutHash(T),
            .fields = comptime fieldsOf(T),
            .default = defaultOf(T),
            .json = if (comptime jsonable(T)) JsonOf(T).value else null,
            .plain = comptime isPlain(T),
            .slot = slot,
        };
    }
};

fn Slot(comptime T: type) type {
    return struct {
        var assigned: std.atomic.Value(ComponentId) = .init(unassigned);
        const description: ComponentInfo = .of(T, &assigned);
    };
}

/// `T`'s id, registering it on first use.
pub inline fn id(comptime T: type) ComponentId {
    const known = Slot(T).assigned.load(.acquire);
    if (known != unassigned) return known;
    return assign(&Slot(T).description);
}

/// `T`'s description, registering it on first use.
pub fn infoOf(comptime T: type) *const ComponentInfo {
    _ = id(T);
    return &Slot(T).description;
}

/// Registers `types` so prefabs and editors can find them by name before
/// anything else has used them.
pub fn register(comptime types: []const type) void {
    inline for (types) |T| _ = id(T);
}

/// The description of an id `id`, `infoOf` or `ComponentInfo.id` gave.
pub fn info(cid: ComponentId) *const ComponentInfo {
    return infos[cid].load(.acquire).?;
}

/// Every registered type, in id order.
pub fn iterator() InfoIterator {
    return .{};
}

pub const InfoIterator = struct {
    next_id: usize = 0,

    pub fn next(self: *InfoIterator) ?*const ComponentInfo {
        const end = @min(handed_out.load(.acquire), max_components);
        while (self.next_id < end) {
            const found = infos[self.next_id].load(.acquire);
            self.next_id += 1;
            if (found) |registered| return registered;
        }
        return null;
    }
};

pub const FindError = error{ UnknownComponent, AmbiguousComponent };

/// The registered type called `name`, by its full `@typeName` or its
/// shorter `name`.
pub fn find(name: []const u8) FindError!*const ComponentInfo {
    var found: ?*const ComponentInfo = null;
    var all = iterator();
    while (all.next()) |candidate| {
        if (std.mem.eql(u8, candidate.type_name, name)) return candidate;
        if (!std.mem.eql(u8, candidate.name, name)) continue;
        if (found != null) return error.AmbiguousComponent;
        found = candidate;
    }
    return found orelse error.UnknownComponent;
}

/// The ids of `types` as a mask.
pub inline fn maskOf(comptime types: []const type) Mask {
    var mask: Mask = .empty;
    inline for (types) |T| mask = mask.with(id(T));
    return mask;
}

/// The component types of `Bundle`, a tuple of component values such as
/// `.{ Position{ .x = 1 }, Enemy{} }`, each type at most once.
pub fn bundleTypes(comptime Bundle: type) []const type {
    const shape = switch (@typeInfo(Bundle)) {
        .@"struct" => |shape| shape,
        else => @compileError("slime: a bundle is a tuple of component values, like .{ Position{ .x = 1 } }"),
    };
    if (shape.field_types.len > 0 and !shape.is_tuple) @compileError("slime: a bundle is a tuple of component values, like .{ Position{ .x = 1 } }");
    var types: [shape.field_types.len]type = undefined;
    for (shape.field_types, &types) |Field, *T| {
        if (!isConcrete(Field)) @compileError("slime: a bundle value of type " ++ @typeName(Field) ++ " has no component type; write it as a typed literal like Position{ .x = 1 }");
        T.* = Field;
    }
    for (types, 0..) |A, i| for (types[i + 1 ..]) |B| if (A == B) @compileError("slime: " ++ @typeName(A) ++ " is in the bundle twice");
    const final = types;
    return &final;
}

fn isConcrete(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .comptime_int, .comptime_float, .enum_literal, .null, .undefined, .type, .noreturn, .@"fn", .@"opaque" => false,
        .@"struct" => |shape| for (shape.field_attrs) |attrs| {
            if (attrs.@"comptime") break false;
        } else true,
        else => true,
    };
}

fn assign(new: *const ComponentInfo) ComponentId {
    @branchHint(.cold);
    const fresh = handed_out.fetchAdd(1, .monotonic);
    if (fresh >= max_components) std.debug.panic("slime: more than {d} component types; raise -Dslime-max-components", .{max_components});
    infos[fresh].store(new, .release);
    if (new.slot.cmpxchgStrong(unassigned, @intCast(fresh), .acq_rel, .acquire)) |winner| {
        infos[fresh].store(null, .release);
        return winner;
    }
    return @intCast(fresh);
}

fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => true,
        else => false,
    };
}

fn nameOf(comptime T: type) []const u8 {
    if (isContainer(T) and @hasDecl(T, "component_name")) return T.component_name;
    const full = @typeName(T);
    const end = std.mem.indexOfAny(u8, full, "([") orelse full.len;
    const start = if (std.mem.lastIndexOfScalar(u8, full[0..end], '.')) |dot| dot + 1 else 0;
    return full[start..];
}

fn fieldsOf(comptime T: type) []const ComponentInfo.Field {
    const shape = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => return &.{},
    };
    var out: [shape.field_names.len]ComponentInfo.Field = undefined;
    var len: usize = 0;
    for (shape.field_names, shape.field_types, shape.field_attrs) |field_name, Field, attrs| {
        if (attrs.@"comptime") continue;
        out[len] = .{
            .name = field_name,
            .type_name = @typeName(Field),
            .offset = @bitOffsetOf(T, field_name) / 8,
            .size = @sizeOf(Field),
            .kind = std.meta.activeTag(@typeInfo(Field)),
        };
        len += 1;
    }
    const final = out[0..len].*;
    return &final;
}

fn Default(comptime T: type) type {
    return struct {
        const value: T = if (isContainer(T) and @hasDecl(T, "default") and @TypeOf(T.default) == T) T.default else .{};
    };
}

fn defaultOf(comptime T: type) ?*const anyopaque {
    if (isContainer(T) and @hasDecl(T, "default") and @TypeOf(T.default) == T) return &Default(T).value;
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            inline for (s.field_attrs) |attrs| {
                if (!attrs.@"comptime" and attrs.default_value_ptr == null) return null;
            }
            return &Default(T).value;
        },
        else => return null,
    }
}

fn hasJsonHooks(comptime T: type) bool {
    return isContainer(T) and std.meta.hasFn(T, "jsonStringify") and std.meta.hasFn(T, "jsonParseFromValue");
}

fn isPlain(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .void, .@"enum" => true,
        .array => |a| isPlain(a.child),
        .vector => |v| isPlain(v.child),
        .optional => |o| isPlain(o.child),
        .@"struct" => |s| for (s.field_types, s.field_attrs) |Field, attrs| {
            if (!attrs.@"comptime" and !isPlain(Field)) break false;
        } else true,
        .@"union" => |u| for (u.field_types) |Field| {
            if (!isPlain(Field)) break false;
        } else true,
        else => false,
    };
}

fn jsonable(comptime T: type) bool {
    if (hasJsonHooks(T)) return true;
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .void, .@"enum" => true,
        .array => |a| jsonable(a.child),
        .optional => |o| jsonable(o.child),
        .@"struct" => |s| for (s.field_types, s.field_attrs) |Field, attrs| {
            if (!attrs.@"comptime" and !jsonable(Field)) break false;
        } else true,
        .@"union" => |u| if (u.tag_type == null) false else for (u.field_types) |Field| {
            if (!jsonable(Field)) break false;
        } else true,
        else => false,
    };
}

fn JsonOf(comptime T: type) type {
    return struct {
        const value: ComponentInfo.Json = .{ .write = write, .parse = parse };

        fn write(raw: *const anyopaque, jw: *std.json.Stringify) std.json.Stringify.Error!void {
            const typed: *const T = @ptrCast(@alignCast(raw));
            try writeValue(jw, typed.*);
        }

        fn parse(arena: std.mem.Allocator, source: std.json.Value, out: *anyopaque) std.json.ParseFromValueError!void {
            const typed: *T = @ptrCast(@alignCast(out));
            typed.* = try std.json.parseFromValueLeaky(T, arena, source, .{});
        }
    };
}

/// Writes like `std.json` does, except that floats narrower than `f64` are
/// written as the shortest text that reads back the same, so `0.2` in a
/// hand-written file stays `0.2`.
fn writeValue(jw: *std.json.Stringify, value: anytype) std.json.Stringify.Error!void {
    const T = @TypeOf(value);
    if (comptime hasJsonHooks(T)) return jw.write(value);
    switch (@typeInfo(T)) {
        .float => |float| {
            if (float.bits >= 64 or !std.math.isFinite(value)) return jw.write(value);
            return jw.print("{d}", .{value});
        },
        .optional => return if (value) |payload| writeValue(jw, payload) else jw.write(null),
        .array => |array| {
            if (array.child == u8) return jw.write(value);
            try jw.beginArray();
            for (value) |item| try writeValue(jw, item);
            try jw.endArray();
        },
        .@"struct" => |shape| {
            if (shape.is_tuple) return jw.write(value);
            try jw.beginObject();
            inline for (shape.field_names, shape.field_types, shape.field_attrs) |field_name, Field, attrs| {
                if (attrs.@"comptime") continue;
                const item = @field(value, field_name);
                const skip = @typeInfo(Field) == .optional and item == null and !jw.options.emit_null_optional_fields;
                if (!skip) {
                    try jw.objectField(field_name);
                    try writeValue(jw, item);
                }
            }
            try jw.endObject();
        },
        else => return jw.write(value),
    }
}

fn layoutHash(comptime T: type) u64 {
    var hasher: std.hash.Fnv1a_64 = .init();
    hashLayout(T, &hasher);
    return hasher.final();
}

fn hashLayout(comptime T: type, hasher: *std.hash.Fnv1a_64) void {
    hasher.update(@tagName(@typeInfo(T)));
    hasher.update(std.mem.asBytes(&@as(u64, @sizeOf(T))));
    switch (@typeInfo(T)) {
        .int => |i| hasher.update(&[_]u8{ @backingInt(i.signedness), @truncate(i.bits), @truncate(i.bits >> 8) }),
        .array => |a| {
            hasher.update(std.mem.asBytes(&@as(u64, a.len)));
            hashLayout(a.child, hasher);
        },
        .vector => |v| {
            hasher.update(std.mem.asBytes(&@as(u64, v.len)));
            hashLayout(v.child, hasher);
        },
        .optional => |o| hashLayout(o.child, hasher),
        .@"enum" => |e| for (e.field_names, e.field_values) |field_name, field_value| {
            hasher.update(field_name);
            hasher.update(std.mem.asBytes(&@as(i128, field_value)));
        },
        .@"struct" => |s| for (s.field_names, s.field_types, s.field_attrs) |field_name, Field, attrs| {
            if (attrs.@"comptime") continue;
            hasher.update(field_name);
            hasher.update(std.mem.asBytes(&@as(u64, @bitOffsetOf(T, field_name))));
            hashLayout(Field, hasher);
        },
        .@"union" => |u| for (u.field_names, u.field_types) |field_name, Field| {
            hasher.update(field_name);
            hashLayout(Field, hasher);
        },
        .bool, .float, .void => {},
        else => hasher.update(@typeName(T)),
    }
}
