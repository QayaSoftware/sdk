const std = @import("std");

pub const ComponentId = u32;
pub const max_components = 64;

pub fn BundleInfo(comptime Bundle: type) type {
    return struct {
        pub const count: usize = countDeclarations(Bundle);

        pub fn id(comptime T: type) ComponentId {
            return findId(Bundle, T);
        }

        pub fn typeAt(comptime cid: ComponentId) type {
            return typeAtImpl(Bundle, cid);
        }

        pub fn mask(comptime T: type) u64 {
            return @as(u64, 1) << @intCast(id(T));
        }

        pub fn maskMany(comptime types: []const type) u64 {
            var m: u64 = 0;
            inline for (types) |T| {
                m |= mask(T);
            }
            return m;
        }

        pub fn elementSize(cid: ComponentId) usize {
            return sizes[cid];
        }

        pub fn elementAlign(cid: ComponentId) u8 {
            return aligns[cid];
        }

        pub fn elementStride(cid: ComponentId) usize {
            return strides[cid];
        }

        const sizes: [count]usize = blk: {
            var s: [count]usize = undefined;
            for (0..count) |i| {
                s[i] = @sizeOf(typeAtImpl(Bundle, @intCast(i)));
            }
            break :blk s;
        };

        const aligns: [count]u8 = blk: {
            var a: [count]u8 = undefined;
            for (0..count) |i| {
                a[i] = std.meta.alignment(typeAtImpl(Bundle, @intCast(i)));
            }
            break :blk a;
        };

        const strides: [count]usize = blk: {
            var st: [count]usize = undefined;
            for (0..count) |i| {
                const T = typeAtImpl(Bundle, @intCast(i));
                const sz = @sizeOf(T);
                const al = std.meta.alignment(T);
                st[i] = std.mem.alignForward(usize, sz, al);
            }
            break :blk st;
        };
    };
}

fn countDeclarations(comptime Bundle: type) usize {
    const decls: []const std.builtin.Type.Declaration = comptime std.meta.declarations(Bundle);
    var n: usize = 0;
    inline for (0..decls.len) |k| {
        const d = decls[k];
        const decl = @field(Bundle, d.name);
        if (@TypeOf(decl) == type) n += 1;
    }
    return n;
}

fn findId(comptime Bundle: type, comptime T: type) ComponentId {
    const decls: []const std.builtin.Type.Declaration = comptime std.meta.declarations(Bundle);
    var i: ComponentId = 0;
    inline for (0..decls.len) |k| {
        const d = decls[k];
        const decl = @field(Bundle, d.name);
        if (@TypeOf(decl) != type) continue;
        if (decl == T) return i;
        i += 1;
    }
    @compileError("type is not a registered component in this bundle");
}

fn typeAtImpl(comptime Bundle: type, comptime cid: ComponentId) type {
    const decls: []const std.builtin.Type.Declaration = comptime std.meta.declarations(Bundle);
    var i: ComponentId = 0;
    inline for (0..decls.len) |k| {
        const d = decls[k];
        const decl = @field(Bundle, d.name);
        if (@TypeOf(decl) != type) continue;
        if (i == cid) return decl;
        i += 1;
    }
    @compileError("invalid component id for bundle");
}

pub fn assertMaxComponents(comptime Bundle: type) void {
    if (countDeclarations(Bundle) > max_components) {
        @compileError("bundle has more than 64 component types; extend Signature type");
    }
}

/// Bundle declaration name → component id, or `null` if no such component type.
pub fn idForDeclName(comptime Bundle: type, name: []const u8) ?ComponentId {
    const decls: []const std.builtin.Type.Declaration = comptime std.meta.declarations(Bundle);
    var i: ComponentId = 0;
    inline for (0..decls.len) |k| {
        const d = decls[k];
        const decl = @field(Bundle, d.name);
        if (@TypeOf(decl) != type) continue;
        if (std.mem.eql(u8, d.name, name)) return i;
        i += 1;
    }
    return null;
}

/// Stable id → bundle declaration name (for JSON keys, tooling). `cid` must be known at comptime.
pub fn declNameForId(comptime Bundle: type, comptime cid: ComponentId) []const u8 {
    const decls: []const std.builtin.Type.Declaration = comptime std.meta.declarations(Bundle);
    comptime var i: ComponentId = 0;
    inline for (0..decls.len) |k| {
        const d = decls[k];
        const decl = @field(Bundle, d.name);
        if (@TypeOf(decl) != type) continue;
        if (i == cid) return d.name;
        comptime i += 1;
    }
    @compileError("invalid component id for bundle");
}
