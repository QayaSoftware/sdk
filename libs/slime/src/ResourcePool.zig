//! One value per type, indexed by the type's registry id. Adding, setting
//! and removing are not thread-safe; reading and writing the values are as
//! safe as the systems' declared access makes them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const registry = @import("registry.zig");

const ResourcePool = @This();

entries: std.ArrayList(?Entry),

pub const empty: ResourcePool = .{ .entries = .empty };

/// Who frees a resource added by pointer.
pub const Ownership = enum {
    /// The world destroys it with its allocator, which must have made it.
    owned,
    /// The caller keeps it alive and frees it.
    borrowed,
};

const Entry = struct {
    ptr: *anyopaque,
    /// Null for a borrowed resource.
    destroy: ?*const fn (gpa: Allocator, ptr: *anyopaque) void,
};

pub fn deinit(self: *ResourcePool, gpa: Allocator) void {
    for (self.entries.items) |entry| destroy(gpa, entry);
    self.entries.deinit(gpa);
}

pub fn add(self: *ResourcePool, gpa: Allocator, value: anytype) (Allocator.Error || error{AlreadyExists})!void {
    const T = @TypeOf(value);
    const entry = try self.slot(gpa, registry.id(T));
    if (entry.* != null) return error.AlreadyExists;
    entry.* = try copy(gpa, value);
}

pub fn set(self: *ResourcePool, gpa: Allocator, value: anytype) Allocator.Error!void {
    const T = @TypeOf(value);
    const entry = try self.slot(gpa, registry.id(T));
    const fresh = try copy(gpa, value);
    destroy(gpa, entry.*);
    entry.* = fresh;
}

pub fn addPtr(self: *ResourcePool, gpa: Allocator, comptime T: type, ptr: *T, ownership: Ownership) (Allocator.Error || error{AlreadyExists})!void {
    const entry = try self.slot(gpa, registry.id(T));
    if (entry.* != null) return error.AlreadyExists;
    entry.* = .{ .ptr = ptr, .destroy = switch (ownership) {
        .owned => destroyer(T),
        .borrowed => null,
    } };
}

pub fn remove(self: *ResourcePool, gpa: Allocator, comptime T: type) bool {
    const cid = registry.id(T);
    if (cid >= self.entries.items.len) return false;
    const entry = self.entries.items[cid] orelse return false;
    destroy(gpa, entry);
    self.entries.items[cid] = null;
    return true;
}

pub fn get(self: *const ResourcePool, comptime T: type) ?*T {
    const cid = registry.id(T);
    if (cid >= self.entries.items.len) return null;
    const entry = self.entries.items[cid] orelse return null;
    return @ptrCast(@alignCast(entry.ptr));
}

fn slot(self: *ResourcePool, gpa: Allocator, cid: registry.ComponentId) Allocator.Error!*?Entry {
    if (cid >= self.entries.items.len) try self.entries.appendNTimes(gpa, null, cid + 1 - self.entries.items.len);
    return &self.entries.items[cid];
}

fn copy(gpa: Allocator, value: anytype) Allocator.Error!Entry {
    const T = @TypeOf(value);
    const ptr = try gpa.create(T);
    ptr.* = value;
    return .{ .ptr = ptr, .destroy = destroyer(T) };
}

fn destroy(gpa: Allocator, entry: ?Entry) void {
    const found = entry orelse return;
    if (found.destroy) |f| f(gpa, found.ptr);
}

fn destroyer(comptime T: type) *const fn (Allocator, *anyopaque) void {
    return struct {
        fn destroy(gpa: Allocator, raw: *anyopaque) void {
            const typed: *T = @ptrCast(@alignCast(raw));
            deinitValue(T, typed, gpa);
            gpa.destroy(typed);
        }
    }.destroy;
}

/// Calls `T.deinit`, if it has one taking nothing or an allocator; the
/// allocator given is the world's.
fn deinitValue(comptime T: type, value: *T, gpa: Allocator) void {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return,
    }
    if (!@hasDecl(T, "deinit")) return;
    const Fn = @TypeOf(T.deinit);
    if (@typeInfo(Fn) != .@"fn") return;
    const params = @typeInfo(Fn).@"fn".param_types;
    if (params.len == 1) {
        value.deinit();
    } else if (params.len == 2 and params[1] == Allocator) {
        value.deinit(gpa);
    }
}
