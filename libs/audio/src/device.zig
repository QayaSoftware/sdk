const std = @import("std");

const Native = opaque {};
const RenderFn = *const fn (user: ?*anyopaque, out: [*]f32, frames: u32) callconv(.c) void;

extern fn qaya_audio_open(sample_rate: u32, period_frames: u32, render: RenderFn, user: ?*anyopaque, actual_rate: *u32) ?*Native;
extern fn qaya_audio_start(device: *Native) c_int;
extern fn qaya_audio_close(device: *Native) void;
extern fn qaya_audio_backend(device: *Native) [*:0]const u8;

/// The system's default playback device through miniaudio: interleaved
/// stereo `f32`, pulled by `render` on the backend's own realtime thread.
pub const Device = struct {
    native: *Native,
    sample_rate: u32,

    /// Opens the default device; a `sample_rate` or `period_frames` of 0
    /// takes the device's own. Fails with `error.NoAudioDevice`.
    pub fn open(sample_rate: u32, period_frames: u32, render: RenderFn, user: ?*anyopaque) !Device {
        var actual_rate: u32 = 0;
        const native = qaya_audio_open(sample_rate, period_frames, render, user, &actual_rate) orelse return error.NoAudioDevice;
        return .{ .native = native, .sample_rate = actual_rate };
    }

    /// `render` starts being called once this returns.
    pub fn start(self: Device) !void {
        if (qaya_audio_start(self.native) == 0) {
            qaya_audio_close(self.native);
            return error.NoAudioDevice;
        }
    }

    /// Stops the device; `render` is not called again once this returns.
    pub fn close(self: Device) void {
        qaya_audio_close(self.native);
    }

    /// The backend miniaudio chose, such as "PulseAudio" or "WASAPI".
    pub fn backend(self: Device) []const u8 {
        return std.mem.span(qaya_audio_backend(self.native));
    }
};
