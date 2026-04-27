const std = @import("std");

pub const ComponentId = u16;

pub fn typeId(comptime T: type) u64 {
    return std.hash.Fnv1a_64.hash(@typeName(T));
}

pub fn id(comptime T: type) ComponentId {
    return @intCast(typeId(T) & 1023);
}

pub fn mask(comptime T: type) u1024 {
    return @as(u1024, 1) << @as(u10, @intCast(id(T)));
}

pub fn maskMany(comptime types: []const type) u1024 {
    var m: u1024 = 0;
    inline for (types) |T| {
        m |= mask(T);
    }
    return m;
}

pub fn elementSize(comptime T: type) usize {
    return @sizeOf(T);
}

pub fn elementAlign(comptime T: type) u8 {
    return std.meta.alignment(T);
}

pub fn elementStride(comptime T: type) usize {
    return std.mem.alignForward(usize, @sizeOf(T), std.meta.alignment(T));
}
