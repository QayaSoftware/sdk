//! lrhi-assets' checks on a real GPU: an opacity micromap baked by `assets`
//! from a checkerboard alpha texture and uploaded through lrhi-assets must
//! agree with the texture wherever traversal settles a ray without the
//! shader. A wrong micro-triangle order or barycentric convention puts
//! settled hits on the wrong squares. Runs without a window, with validation
//! on. `zig build lrhi-assets-checks` runs it.
const std = @import("std");
const rhi = @import("lrhi");
const assets = @import("assets");
const bridge = @import("lrhi-assets");
const opacity = assets.opacity;

pub const std_options: std.Options = .{ .log_level = .info };

const side = 64;
const texture_size = 128;
/// Texels a square of the checkerboard spans.
const square = 40;

const Push = extern struct { scene: u64, outcomes: u64, side: u32 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const device = try rhi.Device.init(gpa, init.io, .{ .application_name = "lrhi-assets checks", .validation = true, .debug_names = true });
    defer device.deinit();
    if (!device.caps.ray_tracing or !device.caps.opacity_micromaps) return std.log.info("skipped: no opacity micromaps on {s}", .{device.name()});

    var alpha: [texture_size * texture_size]u8 = undefined;
    for (0..texture_size) |y| for (0..texture_size) |x| {
        alpha[y * texture_size + x] = if ((x / square + y / square) % 2 == 0) 255 else 0;
    };
    const texture: opacity.Texture = .{ .width = texture_size, .height = texture_size, .alpha = &alpha, .address = .{ .clamp_to_edge, .clamp_to_edge } };
    var coverage = try opacity.Coverage.init(gpa, texture_size, texture_size, &alpha, 128, texture.address);
    defer coverage.deinit(gpa);
    const map = (try opacity.bake(gpa, .{
        .indices = &.{ 0, 1, 2 },
        .uvs = &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } },
        .texture = texture,
        .coverage = &coverage,
    })) orelse return error.NothingBaked;
    defer gpa.free(map.whole);
    defer gpa.free(map.data);
    const micromap = (try bridge.createOpacityMicromap(gpa, device, map)) orelse return error.MicromapRefused;
    defer device.destroyOpacityMicromap(micromap);

    const positions = [3][3]f32{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    const indices = [3]u32{ 0, 1, 2 };
    const vertices = try device.createBuffer(.{ .name = "check vertices", .size = @sizeOf(@TypeOf(positions)), .usage = .{ .acceleration_input = true } });
    defer device.destroyBuffer(vertices);
    const index_buffer = try device.createBuffer(.{ .name = "check indices", .size = @sizeOf(@TypeOf(indices)), .usage = .{ .acceleration_input = true } });
    defer device.destroyBuffer(index_buffer);
    const instances = try device.createBuffer(.{ .name = "check instances", .size = @sizeOf(rhi.PackedInstance), .usage = .{ .acceleration_input = true } });
    defer device.destroyBuffer(instances);
    const outcomes = try device.createBuffer(.{ .name = "check outcomes", .size = side * side * @sizeOf(u32), .usage = .{ .storage = true, .copy_src = true } });
    defer device.destroyBuffer(outcomes);
    const pipeline = try device.createComputePipeline(.{ .name = "check outcomes", .shader = @embedFile("checks.comp") });
    defer device.destroyPipeline(pipeline);
    try device.uploadBuffer(vertices, 0, std.mem.asBytes(&positions));
    try device.uploadBuffer(index_buffer, 0, std.mem.asBytes(&indices));

    const desc: rhi.BlasDesc = .{ .geometries = &.{.{
        .vertices = vertices,
        .vertex_count = 3,
        .vertex_stride = @sizeOf([3]f32),
        .indices = index_buffer,
        .index_count = 3,
        .solid = false,
        .opacity = micromap,
    }} };
    const blas = try device.createBlas(desc);
    defer device.destroyAcceleration(blas);
    const tlas = try device.createTlas(.{ .max_instances = 1 });
    defer device.destroyAcceleration(tlas);
    const instance = device.packInstance(.{ .transform = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 }, .custom_index = 0, .blas = blas });
    try device.uploadBuffer(instances, 0, std.mem.asBytes(&instance));
    try device.flushUploadsBlocking();

    var encoder = try device.beginImmediate();
    try encoder.buildOpacityMicromaps(&.{micromap});
    try encoder.buildBlas(blas, desc);
    encoder.buildTlas(tlas, device.bufferAddress(instances), 1);
    encoder.bindPipeline(pipeline);
    encoder.pushConstants(Push{ .scene = device.accelerationAddress(tlas), .outcomes = device.bufferAddress(outcomes), .side = side });
    encoder.dispatch(side * side / 64, 1, 1);
    encoder.sync(.compute_to_all);
    try device.endImmediate(&encoder);
    const read = try device.readBuffer(gpa, outcomes, side * side * @sizeOf(u32));
    defer gpa.free(read);
    const results = std.mem.bytesAsSlice(u32, read);

    var counts: [3]u32 = @splat(0);
    var wrong: u32 = 0;
    for (0..side) |y| for (0..side) |x| {
        const at = [2]f32{ (@as(f32, @floatFromInt(x)) + 0.5) / side, (@as(f32, @floatFromInt(y)) + 0.5) / side };
        if (at[0] + at[1] >= 1) continue;
        const outcome = results[y * side + x];
        counts[outcome] += 1;
        const solid = texture.sample(at) >= 0.5;
        if ((outcome == 2 and !solid) or (outcome == 0 and solid)) wrong += 1;
    };
    if (wrong != 0) {
        std.log.err("{d} rays settled against the texture ({d} passed, {d} to the shader, {d} hit)", .{ wrong, counts[0], counts[1], counts[2] });
        return error.MicromapDisagreesWithTexture;
    }
    if (counts[0] == 0 or counts[2] == 0 or (counts[0] + counts[2]) * 2 < counts[1]) return error.TooFewRaysSettled;
    try device.waitIdle();
    if (device.validationErrorCount() != 0) return error.ValidationFailed;
    std.log.info("micromap of a {d}-texel checkerboard at subdivision {d}: {d} rays passed, {d} hit, {d} left to the shader, none against the texture", .{ square, map.subdivision, counts[0], counts[2], counts[1] });
}
