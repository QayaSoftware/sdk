//! lrhi-assets: the bridge between `assets`, which loads and bakes on the
//! CPU and knows nothing of a GPU, and an lrhi device. It picks the device's
//! formats for baked data and uploads it. A renderer with its own loader
//! needs neither module: lrhi's own upload calls take plain bytes.
const std = @import("std");
const rhi = @import("lrhi");
const assets = @import("assets");
const gltf = assets.gltf;
const ktx2 = assets.ktx2;

/// What Basis Universal textures are transcoded to on a device with `caps`:
/// the block formats it reads, else plain texels.
pub fn basisTarget(caps: rhi.Capabilities) ktx2.BasisTarget {
    return if (caps.bc_textures) .bc else if (caps.astc_textures) .astc else .rgba;
}

/// The texture format a model image baked to `block` is uploaded in. BC7
/// images of one or two channels are baked to BC4 or BC5.
pub fn blockFormat(block: gltf.Image.Block, one_channel: bool, two_channel: bool, srgb: bool) rhi.Format {
    return switch (block) {
        .bc1 => if (srgb) .bc1_srgb else .bc1_unorm,
        .bc3 => if (srgb) .bc3_srgb else .bc3_unorm,
        .bc6h => .bc6h_ufloat,
        .rgba8 => if (srgb) .rgba8_srgb else .rgba8_unorm,
        .astc4x4 => if (srgb) .astc_4x4_srgb else .astc_4x4_unorm,
        .bc7 => if (one_channel) .bc4_unorm else if (two_channel) .bc5_unorm else if (srgb) .bc7_srgb else .bc7_unorm,
    };
}

/// The texture format of a KTX2 file's texels, or null where `device`
/// cannot sample it.
pub fn textureFormat(device: *const rhi.Device, source: ktx2.Texture) ?rhi.Format {
    const readable = switch (source.format) {
        .rgba8, .rgba16f => true,
        .astc4x4 => device.caps.astc_textures,
        else => device.caps.bc_textures,
    };
    if (!readable) return null;
    return switch (source.format) {
        .bc7 => if (source.srgb) .bc7_srgb else .bc7_unorm,
        .bc1 => if (source.srgb) .bc1_srgb else .bc1_unorm,
        .bc3 => if (source.srgb) .bc3_srgb else .bc3_unorm,
        .bc4 => .bc4_unorm,
        .bc5 => .bc5_unorm,
        .bc6h => .bc6h_ufloat,
        .rgba8 => if (source.srgb) .rgba8_srgb else .rgba8_unorm,
        .rgba16f => .rgba16_float,
        .astc4x4 => if (source.srgb) .astc_4x4_srgb else .astc_4x4_unorm,
    };
}

/// A sampled texture holding a 2D KTX2 file's every level, uploaded with
/// the next flush. Fails with `error.UnsupportedTextureFormat` for cube
/// maps, arrays and formats the device cannot sample.
pub fn uploadTexture(device: *rhi.Device, source: ktx2.Texture, name: [:0]const u8) !rhi.Texture {
    if (source.faces != 1 or source.layers != 1) return error.UnsupportedTextureFormat;
    const format = textureFormat(device, source) orelse return error.UnsupportedTextureFormat;
    const texture = try device.createTexture(.{
        .name = name,
        .width = source.width,
        .height = source.height,
        .format = format,
        .usage = .{ .sampled = true, .copy_dst = true },
        .mip_levels = source.levels,
    });
    errdefer device.destroyTexture(texture);
    try device.uploadTextureLevels(texture, 0, 0, source.data);
    return texture;
}

/// An opacity micromap of `map` on `device`, to build with
/// `CommandEncoder.buildOpacityMicromaps` and give the mesh's full-detail
/// geometry as `BlasGeometry.opacity`. Null where the device has no
/// micromaps or a shallower subdivision than the map's.
pub fn createOpacityMicromap(gpa: std.mem.Allocator, device: *rhi.Device, map: assets.opacity.Map) !?rhi.OpacityMicromap {
    if (!device.caps.opacity_micromaps or map.subdivision > device.caps.max_opacity_subdivision) return null;
    const whole = try gpa.alloc(?rhi.Opacity, map.whole.len);
    defer gpa.free(whole);
    for (whole, map.whole) |*state, value| state.* = if (value == assets.opacity.Map.micro) null else @fromBackingInt(@intCast(value));
    return try device.createOpacityMicromap(.{
        .triangle_count = @intCast(map.whole.len),
        .subdivision = map.subdivision,
        .data = map.data,
        .whole = whole,
    });
}
