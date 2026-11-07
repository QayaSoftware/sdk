//! Push constants of the passes in shade.slang. The build writes each
//! struct as `shade.<Name>.slang`, which the shader includes.

pub const Push = extern struct {
    frame: u64,
    visibility_texture: u32,
    ao_texture: u32,
    debug_view: u32,
    gi_texture: u32,
    material_shader: u32,
    shadow_history: u32,
    bounce_texture: u32,
    bounce_strength: f32,
    shadow_depth: u32 = 0xffff_ffff,
    /// The sun's traced shadow at half resolution (lit fraction, view depth),
    /// and the index of the light it is for; `invalid_id` for none.
    sun_mask: u32 = 0xffff_ffff,
    sun_light: u32 = 0xffff_ffff,

    pub const references = .{ .frame = "FrameConstants" };
};

/// `sunShadowMain`: one pixel of four, in turn, of the view at half size.
pub const SunShadowPush = extern struct {
    frame: u64,
    depth_texture: u32,
    /// Storage index of the mask written, and the light traced toward.
    mask: u32,
    sun_light: u32,
    /// Which pixel of each 2x2 block is traced this frame, 0 to 3.
    phase: u32,

    pub const references = .{ .frame = "FrameConstants" };
};
