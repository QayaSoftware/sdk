//! Loading and baking assets on the CPU, with no GPU dependency: glTF and FBX
//! models optimized into meshlets with their levels of detail, texture files
//! and codecs, fonts, and the cache of processed models. Its types are plain
//! data; `lrhi-assets` uploads them to an lrhi device, and limn renders them.

/// Vectors, quaternions and column-major 4x4 matrices. Right-handed, +Y
/// up, cameras look down -Z; `mul(a, b)` applies `b` first.
pub const math = @import("math.zig");
/// glTF 2.0 and FBX models, processed into meshlets and levels of detail.
pub const gltf = @import("gltf.zig");
/// The binary form of a processed model, for the asset cache.
pub const model_cache = @import("model_cache.zig");
/// KTX2 texture files, including Basis Universal and Zstandard.
pub const ktx2 = @import("ktx2.zig");
/// DDS texture files with block-compressed data.
pub const dds = @import("dds.zig");
/// CPU mip chains and block compression; always built optimized.
pub const texture = @import("texture_codec");
/// Opacity micromaps baked from alpha textures, for ray tracing cut-outs.
pub const opacity = @import("opacity.zig");
/// TrueType loading, shaping and distance-field glyph baking; always built
/// optimized.
pub const font = @import("font_baker").font;
/// DejaVu Sans 2.37, the font renderers fall back on; see fonts/NOTICE.md.
pub const default_font = @embedFile("fonts/DejaVuSans.ttf");

test {
    _ = @import("math.zig");
    _ = @import("gltf.zig");
    _ = @import("fbx.zig");
    _ = @import("model_cache.zig");
    _ = @import("ktx2.zig");
    _ = @import("dds.zig");
    _ = @import("opacity.zig");
}
