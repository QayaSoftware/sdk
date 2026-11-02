//! Opacity micromaps (`VK_EXT_opacity_micromap`). Internal to the device.
const std = @import("std");
const vk = @import("vulkan");
const types = @import("../../types.zig");
const device_module = @import("../device.zig");

const Device = device_module.Device;
const MicromapResource = device_module.MicromapResource;
const retire = @import("objects.zig").retire;
const scratch_alignment = device_module.scratch_alignment;

fn format(states: types.OpacityStates) u16 {
    return @intCast(@backingInt(if (states == .two) vk.OpacityMicromapFormatEXT.@"2_state_ext" else vk.OpacityMicromapFormatEXT.@"4_state_ext"));
}

fn specialIndex(state: types.Opacity) i32 {
    return @backingInt(switch (state) {
        .transparent => vk.OpacityMicromapSpecialIndexEXT.fully_transparent_khr,
        .@"opaque" => vk.OpacityMicromapSpecialIndexEXT.fully_opaque_khr,
        .unknown_transparent => vk.OpacityMicromapSpecialIndexEXT.fully_unknown_transparent_khr,
        .unknown_opaque => vk.OpacityMicromapSpecialIndexEXT.fully_unknown_opaque_khr,
    });
}

fn mappedBuffer(self: *Device, name: [:0]const u8, usage: types.BufferUsage, size: usize) !types.Buffer {
    return self.createBuffer(.{ .name = name, .size = @max(size, 4), .usage = usage, .memory = .cpu_to_gpu });
}

/// Build input of a micromap: a host-visible buffer whose part from
/// `offset` starts at a multiple of 256 bytes on the GPU, as builds need.
const Input = struct { buffer: types.Buffer, offset: u64 };

fn inputBuffer(self: *Device, name: [:0]const u8, size: usize) !Input {
    const buffer = try mappedBuffer(self, name, .{ .micromap_input = true }, size + input_alignment);
    const address = self.bufferAddress(buffer);
    return .{ .buffer = buffer, .offset = std.mem.alignForward(u64, address, input_alignment) - address };
}

const input_alignment = 256;

/// Copies `desc` into buffers of its own and sizes the micromap; build it
/// with `CommandEncoder.buildOpacityMicromaps` before a structure uses it.
/// `error.InvalidMicromapDesc` for data that does not match the triangle
/// count and subdivision, `error.OpacityMicromapsUnavailable` without
/// `Capabilities.opacity_micromaps`.
pub fn createOpacityMicromap(self: *Device, desc: types.OpacityMicromapDesc) !types.OpacityMicromap {
    self.lockResources();
    defer self.unlockResources();
    if (!self.caps.opacity_micromaps) return error.OpacityMicromapsUnavailable;
    if (desc.triangle_count == 0 or desc.subdivision > self.caps.max_opacity_subdivision) return error.InvalidMicromapDesc;
    if (desc.whole.len != 0 and desc.whole.len != desc.triangle_count) return error.InvalidMicromapDesc;
    const triangle_bytes = desc.triangleBytes();
    if (desc.data.len == 0) {
        if (desc.whole.len == 0) return error.InvalidMicromapDesc;
        for (desc.whole) |state| if (state == null) return error.InvalidMicromapDesc;
    } else if (desc.data.len != triangle_bytes * desc.triangle_count) return error.InvalidMicromapDesc;

    const indices = try mappedBuffer(self, "micromap indices", .{ .acceleration_input = true }, desc.triangle_count * @sizeOf(i32));
    errdefer self.destroyBuffer(indices);
    const index_values: [*]i32 = @ptrCast(@alignCast(self.mapped(indices).ptr));
    var used: u32 = 0;
    for (0..desc.triangle_count) |triangle| {
        const whole: ?types.Opacity = if (desc.whole.len != 0) desc.whole[triangle] else null;
        index_values[triangle] = if (whole) |state| specialIndex(state) else blk: {
            used += 1;
            break :blk @intCast(triangle);
        };
    }
    const usage = vk.MicromapUsageEXT{ .count = used, .subdivision_level = desc.subdivision, .format = format(desc.states) };

    const data_size = triangle_bytes * desc.triangle_count;
    const data = try inputBuffer(self, "micromap data", data_size);
    errdefer self.destroyBuffer(data.buffer);
    const data_bytes = self.mapped(data.buffer)[@intCast(data.offset)..][0..data_size];
    if (desc.data.len == 0) @memset(data_bytes, 0) else @memcpy(data_bytes, desc.data);
    const triangles = try inputBuffer(self, "micromap triangles", desc.triangle_count * @sizeOf(vk.MicromapTriangleEXT));
    errdefer self.destroyBuffer(triangles.buffer);
    const entries: [*]vk.MicromapTriangleEXT = @ptrCast(@alignCast(self.mapped(triangles.buffer)[@intCast(triangles.offset)..].ptr));
    for (0..desc.triangle_count) |triangle| entries[triangle] = .{
        .data_offset = @intCast(triangle * triangle_bytes),
        .subdivision_level = @intCast(desc.subdivision),
        .format = format(desc.states),
    };

    var sizes: vk.MicromapBuildSizesInfoEXT = .{ .micromap_size = 0, .build_scratch_size = 0, .discardable = .false };
    self.vkd.getMicromapBuildSizesEXT(.device_khr, &.{
        .type = .opacity_micromap_ext,
        .flags = .{ .prefer_fast_trace_ext = true },
        .mode = .build_ext,
        .usage_counts_count = 1,
        .p_usage_counts = @ptrCast(&vk.MicromapUsageEXT{ .count = desc.triangle_count, .subdivision_level = desc.subdivision, .format = format(desc.states) }),
        .data = .{ .device_address = 0 },
        .scratch_data = .{ .device_address = 0 },
        .triangle_array = .{ .device_address = 0 },
        .triangle_array_stride = @sizeOf(vk.MicromapTriangleEXT),
    }, &sizes);
    const buffer = try self.createBuffer(.{ .name = "opacity micromap", .size = @max(sizes.micromap_size, 4), .usage = .{ .micromap_storage = true } });
    errdefer self.destroyBuffer(buffer);
    const handle = try self.vkd.createMicromapEXT(&.{
        .buffer = self.bufferResource(buffer).handle,
        .offset = 0,
        .size = sizes.micromap_size,
        .type = .opacity_micromap_ext,
    }, null);
    errdefer self.vkd.destroyMicromapEXT(handle, null);
    return self.micromaps.insert(.{
        .handle = handle,
        .buffer = buffer,
        .data = data.buffer,
        .data_offset = data.offset,
        .triangles = triangles.buffer,
        .triangles_offset = triangles.offset,
        .indices = indices,
        .usage = usage,
        .triangle_count = desc.triangle_count,
        .scratch_size = sizes.build_scratch_size,
    });
}

/// Deferred like `destroyBuffer`. Structures built with it must be
/// destroyed first.
pub fn destroyOpacityMicromap(self: *Device, micromap: types.OpacityMicromap) void {
    self.lockResources();
    defer self.unlockResources();
    const resource = self.micromaps.remove(micromap) orelse return;
    retire(self, .{ .micromap = resource.handle });
    for ([_]types.Buffer{ resource.buffer, resource.data, resource.triangles, resource.indices }) |buffer| {
        if (buffer.isValid()) self.destroyBuffer(buffer);
    }
}

/// Panics on a stale handle. The pointer is valid until a micromap is
/// created or destroyed.
pub fn micromapResource(self: *Device, micromap: types.OpacityMicromap) *MicromapResource {
    return self.micromaps.get(micromap) orelse @panic("stale or invalid opacity micromap handle");
}

/// Called by `CommandEncoder.buildOpacityMicromaps`, which adds the
/// barriers; use that. Frees each one's input once its build is recorded.
pub fn buildMicromapsCommand(self: *Device, command: vk.CommandBuffer, micromaps: []const types.OpacityMicromap) !void {
    for (micromaps) |micromap| {
        const resource = self.micromapResource(micromap);
        if (resource.built) continue;
        const scratch = try self.createBuffer(.{ .name = "micromap scratch", .size = resource.scratch_size + scratch_alignment, .usage = .{ .storage = true } });
        defer self.destroyBuffer(scratch);
        const counts = vk.MicromapUsageEXT{ .count = resource.triangle_count, .subdivision_level = resource.usage.subdivision_level, .format = resource.usage.format };
        self.vkd.cmdBuildMicromapsEXT(command, &.{.{
            .type = .opacity_micromap_ext,
            .flags = .{ .prefer_fast_trace_ext = true },
            .mode = .build_ext,
            .dst_micromap = resource.handle,
            .usage_counts_count = 1,
            .p_usage_counts = @ptrCast(&counts),
            .data = .{ .device_address = self.bufferAddress(resource.data) + resource.data_offset },
            .scratch_data = .{ .device_address = std.mem.alignForward(u64, self.bufferAddress(scratch), scratch_alignment) },
            .triangle_array = .{ .device_address = self.bufferAddress(resource.triangles) + resource.triangles_offset },
            .triangle_array_stride = @sizeOf(vk.MicromapTriangleEXT),
        }});
        self.destroyBuffer(resource.data);
        self.destroyBuffer(resource.triangles);
        resource.data = .invalid;
        resource.triangles = .invalid;
        resource.built = true;
    }
}

/// What a structure build chains onto a geometry that uses `micromap`.
pub fn geometryMicromap(self: *Device, micromap: types.OpacityMicromap, triangle_count: u32) !vk.AccelerationStructureTrianglesOpacityMicromapEXT {
    const resource = self.micromapResource(micromap);
    if (resource.triangle_count != triangle_count) return error.InvalidBlasDesc;
    return .{
        .index_type = .uint32,
        .index_buffer = .{ .device_address = self.bufferAddress(resource.indices) },
        .index_stride = @sizeOf(i32),
        .base_triangle = 0,
        .usage_counts_count = if (resource.usage.count == 0) 0 else 1,
        .p_usage_counts = if (resource.usage.count == 0) null else @ptrCast(&resource.usage),
        .micromap = resource.handle,
    };
}
