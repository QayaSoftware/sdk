//! lrhi's checks on a real GPU, with no renderer: large uploads reusing
//! staging buffers, copying mip ranges between textures, opacity micromaps
//! settling alpha-tested ray hits, and packed top-level instances. Runs
//! without a window, with validation on, and fails on the first check that
//! does not hold or on any validation error. `zig build lrhi-checks` runs it.
const std = @import("std");
const rhi = @import("lrhi");

pub const std_options: std.Options = .{ .log_level = .info };

const mib = 1024 * 1024;

const Checks = struct {
    gpa: std.mem.Allocator,
    device: *rhi.Device,

    /// An upload too big for the staging ring gets a buffer of its own,
    /// which the next upload of about its size takes over instead of
    /// allocating another.
    fn stagingReuse(self: *Checks) !void {
        const size = 20 * mib;
        const data = try self.gpa.alloc(u8, size);
        defer self.gpa.free(data);
        for (data, 0..) |*byte, index| byte.* = @truncate(index *% 31 +% index / 4096);

        const before = self.device.memoryStats().used_bytes;
        const first = try self.device.createBuffer(.{ .name = "first upload", .size = size, .usage = .{ .storage = true, .copy_src = true } });
        defer self.device.destroyBuffer(first);
        try self.device.uploadBuffer(first, 0, data);
        try self.device.flushUploadsBlocking();
        const after_first = self.device.memoryStats().used_bytes;

        const second = try self.device.createBuffer(.{ .name = "second upload", .size = size, .usage = .{ .storage = true, .copy_src = true } });
        defer self.device.destroyBuffer(second);
        try self.device.uploadBuffer(second, 0, data);
        try self.device.flushUploadsBlocking();
        const after_second = self.device.memoryStats().used_bytes;

        const first_growth = after_first - before;
        const second_growth = after_second - after_first;
        if (first_growth < 2 * size) return error.LargeUploadNotStagedApart;
        if (second_growth >= 2 * size) return error.StagingNotReused;
        for ([_]rhi.Buffer{ first, second }) |buffer| {
            const read = try self.device.readBuffer(self.gpa, buffer, size);
            defer self.gpa.free(read);
            if (!std.mem.eql(u8, read, data)) return error.UploadContentsWrong;
        }
        std.log.info("staging reuse: first 20 MiB upload took {d} MiB, the second {d} MiB", .{ first_growth / mib, second_growth / mib });
    }

    /// Mips 1 and 2 of a 64x64 texture copied to mips 0 and 1 of a 32x32
    /// one, then its mip 1 to a 16x16 one, so that both read back as mip 0.
    fn mipCopy(self: *Checks) !void {
        const usage: rhi.TextureUsage = .{ .sampled = true, .copy_src = true, .copy_dst = true };
        const source = try self.device.createTexture(.{ .name = "mip source", .width = 64, .height = 64, .format = .rgba8_unorm, .usage = usage, .mip_levels = 3 });
        defer self.device.destroyTexture(source);
        const middle = try self.device.createTexture(.{ .name = "mip middle", .width = 32, .height = 32, .format = .rgba8_unorm, .usage = usage, .mip_levels = 2 });
        defer self.device.destroyTexture(middle);
        const last = try self.device.createTexture(.{ .name = "mip last", .width = 16, .height = 16, .format = .rgba8_unorm, .usage = usage });
        defer self.device.destroyTexture(last);

        const level_sizes = [3]usize{ 64 * 64 * 4, 32 * 32 * 4, 16 * 16 * 4 };
        var levels: [level_sizes[0] + level_sizes[1] + level_sizes[2]]u8 = undefined;
        for (&levels, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% index / 251);
        try self.device.uploadTextureLevels(source, 0, 0, &levels);
        try self.device.flushUploadsBlocking();

        var encoder = try self.device.beginImmediate();
        encoder.copyTextureMips(source, 1, middle, 0, 2);
        encoder.copyTextureMips(middle, 1, last, 0, 1);
        try self.device.endImmediate(&encoder);

        const mip1 = levels[level_sizes[0]..][0..level_sizes[1]];
        const mip2 = levels[level_sizes[0] + level_sizes[1] ..][0..level_sizes[2]];
        const read_middle = try self.device.readTexture(self.gpa, middle);
        defer self.gpa.free(read_middle);
        if (!std.mem.eql(u8, read_middle, mip1)) return error.MipOneNotCopied;
        const read_last = try self.device.readTexture(self.gpa, last);
        defer self.gpa.free(read_last);
        if (!std.mem.eql(u8, read_last, mip2)) return error.MipTwoNotCopied;
        std.log.info("mip copy: mips 1-2 of 64x64 into 32x32, and on into 16x16, match", .{});
    }

    /// Two alpha-tested triangles, traced with and without micromaps.
    fn micromaps(self: *Checks) !void {
        const caps = self.device.caps;
        if (!caps.ray_tracing) return std.log.info("micromaps: skipped, no ray tracing", .{});
        if (!caps.opacity_micromaps) return std.log.info("micromaps: skipped, no VK_EXT_opacity_micromap", .{});
        var scene = try Triangles.init(self.gpa, self.device);
        defer scene.deinit();

        const solid = try scene.trace(true, null, .{});
        if (solid.committed[0] != solid.rays[0] or solid.committed[1] != solid.rays[1]) return error.SolidTrianglesMissed;
        if (solid.candidates[0] + solid.candidates[1] != 0) return error.SolidTrianglesReachedShader;

        const tested = try scene.trace(false, null, .{});
        if (tested.candidates[0] != tested.rays[0] or tested.candidates[1] != tested.rays[1]) return error.AlphaTestedSkippedShader;
        if (tested.committed[0] + tested.committed[1] != 0) return error.UncommittedCandidateHit;

        const whole = try self.device.createOpacityMicromap(.{ .triangle_count = 2, .subdivision = 0, .data = &.{}, .whole = &.{ .transparent, .@"opaque" } });
        defer self.device.destroyOpacityMicromap(whole);
        const settled_whole = try scene.trace(false, whole, .{});
        if (settled_whole.candidates[0] + settled_whole.candidates[1] != 0) return error.WholeStatesReachedShader;
        if (settled_whole.committed[0] != 0) return error.TransparentTriangleHit;
        if (settled_whole.committed[1] != settled_whole.rays[1]) return error.OpaqueTriangleMissed;

        const subdivision = @min(caps.max_opacity_subdivision, 4);
        const desc_bytes = (rhi.OpacityMicromapDesc{ .triangle_count = 2, .subdivision = subdivision, .data = &.{} }).triangleBytes();
        const data = try self.gpa.alloc(u8, desc_bytes * 2);
        defer self.gpa.free(data);
        @memset(data[0..desc_bytes], 0b01010101);
        @memset(data[desc_bytes..], 0b11111111);
        const mixed = try self.device.createOpacityMicromap(.{ .triangle_count = 2, .subdivision = subdivision, .data = data });
        defer self.device.destroyOpacityMicromap(mixed);
        const settled_mixed = try scene.trace(false, mixed, .{});
        if (settled_mixed.candidates[0] != 0) return error.OpaqueMicroTrianglesReachedShader;
        if (settled_mixed.committed[0] != settled_mixed.rays[0]) return error.OpaqueMicroTrianglesMissed;
        if (settled_mixed.candidates[1] != settled_mixed.rays[1]) return error.UnknownMicroTrianglesSkippedShader;
        if (settled_mixed.committed[1] != 0) return error.UncommittedCandidateHit;

        std.log.info("micromaps: {d} rays a triangle; alpha tested without one, all reach the shader; whole states and subdivision {d} settle in hardware, unknown ones still reach it", .{ tested.rays[0], subdivision });
    }

    /// Instances packed by `Device.packInstance`: a forced-opaque one is hit
    /// without the shader, and one whose mask the rays do not share is
    /// passed.
    fn instances(self: *Checks) !void {
        if (!self.device.caps.ray_tracing) return std.log.info("instances: skipped, no ray tracing", .{});
        var scene = try Triangles.init(self.gpa, self.device);
        defer scene.deinit();
        const forced = try scene.trace(false, null, .{ .flags = .{ .force_opaque = true } });
        if (forced.candidates[0] + forced.candidates[1] != 0) return error.ForcedOpaqueReachedShader;
        if (forced.committed[0] != forced.rays[0] or forced.committed[1] != forced.rays[1]) return error.ForcedOpaqueMissed;
        const masked = try scene.trace(true, null, .{ .mask = 0 });
        if (masked.candidates[0] + masked.candidates[1] + masked.committed[0] + masked.committed[1] != 0) return error.MaskedInstanceHit;
        std.log.info("instances: force opaque settles in hardware, mask 0 is never hit", .{});
    }
};

/// What checks.slang counted for each triangle.
const Counts = struct {
    rays: [2]u32,
    candidates: [2]u32,
    committed: [2]u32,
};

/// The two triangles the shader casts rays at, in one bottom-level
/// structure of one geometry, built again for each `trace`.
const Triangles = struct {
    gpa: std.mem.Allocator,
    device: *rhi.Device,
    vertices: rhi.Buffer,
    indices: rhi.Buffer,
    instances: rhi.Buffer,
    counts: rhi.Buffer,
    pipeline: rhi.Pipeline,

    /// How `trace` places the triangles in the top-level structure.
    const Instance = struct { mask: u8 = 0xff, flags: rhi.InstanceFlags = .{} };

    const rays_per_triangle = 32 * 32;
    const Push = extern struct { scene: u64, counts: u64, rays_per_triangle: u32 };

    fn init(gpa: std.mem.Allocator, device: *rhi.Device) !Triangles {
        const positions = [6][3]f32{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 2, 0, 0 }, .{ 3, 0, 0 }, .{ 2, 1, 0 } };
        const indices = [6]u32{ 0, 1, 2, 3, 4, 5 };
        const vertices = try device.createBuffer(.{ .name = "check vertices", .size = @sizeOf(@TypeOf(positions)), .usage = .{ .acceleration_input = true } });
        errdefer device.destroyBuffer(vertices);
        const index_buffer = try device.createBuffer(.{ .name = "check indices", .size = @sizeOf(@TypeOf(indices)), .usage = .{ .acceleration_input = true } });
        errdefer device.destroyBuffer(index_buffer);
        const instances = try device.createBuffer(.{ .name = "check instances", .size = @sizeOf(rhi.PackedInstance), .usage = .{ .acceleration_input = true } });
        errdefer device.destroyBuffer(instances);
        const counts = try device.createBuffer(.{ .name = "check counts", .size = 6 * @sizeOf(u32), .usage = .{ .storage = true, .copy_src = true } });
        errdefer device.destroyBuffer(counts);
        try device.uploadBuffer(vertices, 0, std.mem.asBytes(&positions));
        try device.uploadBuffer(index_buffer, 0, std.mem.asBytes(&indices));
        try device.flushUploadsBlocking();
        const pipeline = try device.createComputePipeline(.{ .name = "check candidates", .shader = @embedFile("checks.comp") });
        return .{ .gpa = gpa, .device = device, .vertices = vertices, .indices = index_buffer, .instances = instances, .counts = counts, .pipeline = pipeline };
    }

    fn deinit(self: *Triangles) void {
        self.device.destroyPipeline(self.pipeline);
        for ([_]rhi.Buffer{ self.vertices, self.indices, self.instances, self.counts }) |buffer| self.device.destroyBuffer(buffer);
    }

    fn trace(self: *Triangles, solid: bool, opacity: ?rhi.OpacityMicromap, placement: Instance) !Counts {
        const device = self.device;
        const desc: rhi.BlasDesc = .{ .geometries = &.{.{
            .vertices = self.vertices,
            .vertex_count = 6,
            .vertex_stride = @sizeOf([3]f32),
            .indices = self.indices,
            .index_count = 6,
            .solid = solid,
            .opacity = opacity,
        }} };
        const blas = try device.createBlas(desc);
        defer device.destroyAcceleration(blas);
        const tlas = try device.createTlas(.{ .max_instances = 1 });
        defer device.destroyAcceleration(tlas);
        const packed_instance = device.packInstance(.{
            .transform = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 },
            .custom_index = 0,
            .mask = placement.mask,
            .flags = placement.flags,
            .blas = blas,
        });
        try device.uploadBuffer(self.instances, 0, std.mem.asBytes(&packed_instance));
        try device.flushUploadsBlocking();

        var encoder = try device.beginImmediate();
        if (opacity) |micromap| try encoder.buildOpacityMicromaps(&.{micromap});
        try encoder.buildBlas(blas, desc);
        encoder.buildTlas(tlas, device.bufferAddress(self.instances), 1);
        encoder.fillBuffer(self.counts, 0, 6 * @sizeOf(u32), 0);
        encoder.sync(.transfer_to_all);
        encoder.bindPipeline(self.pipeline);
        encoder.pushConstants(Push{ .scene = device.accelerationAddress(tlas), .counts = device.bufferAddress(self.counts), .rays_per_triangle = rays_per_triangle });
        encoder.dispatch(2 * rays_per_triangle / 64, 1, 1);
        encoder.sync(.compute_to_all);
        try device.endImmediate(&encoder);

        const read = try device.readBuffer(self.gpa, self.counts, 6 * @sizeOf(u32));
        defer self.gpa.free(read);
        const values = std.mem.bytesAsSlice(u32, read);
        return .{ .rays = values[0..2].*, .candidates = values[2..4].*, .committed = values[4..6].* };
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const device = try rhi.Device.init(gpa, init.io, .{ .application_name = "lrhi checks", .validation = true, .debug_names = true });
    defer device.deinit();
    std.log.info("device: {s}", .{device.name()});

    var checks = Checks{ .gpa = gpa, .device = device };
    try checks.stagingReuse();
    try checks.mipCopy();
    try checks.micromaps();
    try checks.instances();

    try device.waitIdle();
    if (device.validationErrorCount() != 0) return error.ValidationFailed;
    std.log.info("all lrhi checks passed", .{});
}
