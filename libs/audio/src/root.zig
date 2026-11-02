//! An audio engine for games: WAV and QOA sounds played as voices with
//! volume, pitch, pan, fades, looping and placement in the world, summed
//! through a tree of buses on a realtime mixer that never waits, locks or
//! allocates, and sent to the system's playback device through miniaudio.
//! Voices and sounds are generational handles, so a stale one is ignored.
const std = @import("std");

const engine = @import("engine.zig");
pub const Engine = engine.Engine;
pub const Options = engine.Options;
pub const Output = engine.Output;
pub const LoadOptions = engine.LoadOptions;
pub const PlayOptions = engine.PlayOptions;
pub const Sound = engine.Sound;
pub const SoundTag = engine.SoundTag;
pub const Voice = engine.Voice;
pub const VoiceTag = engine.VoiceTag;
pub const Bus = engine.Bus;

const mixer = @import("mixer.zig");
pub const Listener = mixer.Listener;
pub const Spatial = mixer.Spatial;
pub const Vec3 = mixer.Vec3;
pub const max_buses = mixer.max_buses;
pub const max_voices = mixer.max_voices;

/// The WAVE reader, for sample data outside the engine.
pub const wav = @import("wav.zig");
/// The QOA decoder, for sample data outside the engine.
pub const qoa = @import("qoa.zig");

test {
    _ = @import("ring.zig");
    _ = @import("sound.zig");
    _ = wav;
    _ = qoa;
}

const testing = std.testing;

fn testEngine(max: u16) !Engine {
    return Engine.init(testing.allocator, .{ .output = .manual, .sample_rate = 8000, .max_voices = max });
}

/// A WAV of `frames` mono samples at 8000 Hz, all `value`.
fn constant(e: *Engine, frames: usize, value: i16) !Sound {
    const samples = try testing.allocator.alloc(i16, frames);
    defer testing.allocator.free(samples);
    @memset(samples, value);
    const bytes = try wav.encode16(testing.allocator, samples, 1, 8000);
    defer testing.allocator.free(bytes);
    return e.load(bytes, .{});
}

fn renderFrames(e: *Engine, comptime frames: usize) [frames * 2]f32 {
    var out: [frames * 2]f32 = undefined;
    e.render(&out);
    e.update();
    return out;
}

test "a voice plays to its end and its handle goes stale" {
    var e = try testEngine(4);
    defer e.deinit();
    const sound = try constant(&e, 100, 16384);
    const voice = try e.play(sound, .{});
    const out = renderFrames(&e, 50);
    const center = 0.5 * @cos(@as(f32, std.math.pi / 4.0));
    try testing.expectApproxEqAbs(center, out[20], 1e-4);
    try testing.expectApproxEqAbs(center, out[21], 1e-4);
    try testing.expect(e.isPlaying(voice));
    const rest = renderFrames(&e, 100);
    try testing.expectEqual(@as(f32, 0), rest[180]);
    try testing.expect(!e.isPlaying(voice));
    try e.setVolume(voice, 0);
}

test "pan, volume and buses scale the mix" {
    var e = try testEngine(4);
    defer e.deinit();
    const sound = try constant(&e, 4000, 16384);
    const music = try e.createBus(.master);
    _ = try e.play(sound, .{ .pan = 1, .volume = 0.5, .bus = music, .looping = true });
    var out = renderFrames(&e, 300);
    try testing.expectApproxEqAbs(@as(f32, 0), out[400], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[401], 1e-4);
    try e.setBusVolume(music, 0);
    _ = renderFrames(&e, 300);
    out = renderFrames(&e, 300);
    try testing.expectEqual(@as(f32, 0), out[401]);
}

test "stopping fades out, then the voice ends" {
    var e = try testEngine(4);
    defer e.deinit();
    const sound = try constant(&e, 8000, 16384);
    const voice = try e.play(sound, .{ .looping = true });
    _ = renderFrames(&e, 64);
    try e.stop(voice, 0.01);
    const out = renderFrames(&e, 200);
    try testing.expect(@abs(out[2]) > @abs(out[60]));
    try testing.expectEqual(@as(f32, 0), out[199 * 2]);
    try testing.expect(!e.isPlaying(voice));
}

test "a paused voice is silent and resumes" {
    var e = try testEngine(4);
    defer e.deinit();
    const sound = try constant(&e, 8000, 16384);
    const voice = try e.play(sound, .{ .looping = true });
    try e.setPaused(voice, true);
    const paused = renderFrames(&e, 256);
    try testing.expectEqual(@as(f32, 0), paused[255 * 2]);
    try testing.expect(e.isPlaying(voice));
    try e.setPaused(voice, false);
    const resumed = renderFrames(&e, 256);
    try testing.expect(resumed[255 * 2] > 0.3);
}

test "spatial voices fall off with distance and pan to their side" {
    var e = try testEngine(4);
    defer e.deinit();
    const sound = try constant(&e, 8000, 16384);
    try e.setListener(.{});
    const voice = try e.play(sound, .{ .looping = true, .spatial = .{ .position = .{ 10, 0, 0 }, .min_distance = 1 } });
    var out = renderFrames(&e, 256);
    try testing.expectApproxEqAbs(@as(f32, 0), out[400], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.05), out[401], 1e-4);
    try e.setPosition(voice, .{ 0, 0, -1 });
    _ = renderFrames(&e, 256);
    out = renderFrames(&e, 256);
    try testing.expectApproxEqAbs(out[400], out[401], 1e-4);
}

test "a full engine steals its oldest voice at or below the new priority" {
    var e = try testEngine(2);
    defer e.deinit();
    const sound = try constant(&e, 8000, 1000);
    const first = try e.play(sound, .{ .priority = 10 });
    const second = try e.play(sound, .{ .priority = 10 });
    const third = try e.play(sound, .{ .priority = 10 });
    try testing.expect(!e.isPlaying(first));
    try testing.expect(e.isPlaying(second) and e.isPlaying(third));
    try testing.expectError(error.NoFreeVoice, e.play(sound, .{ .priority = 5 }));
    _ = renderFrames(&e, 16);
    try testing.expect(e.isPlaying(second) and e.isPlaying(third));
}

test "unloading a playing sound ends its voices and frees it" {
    var e = try testEngine(4);
    defer e.deinit();
    const sound = try constant(&e, 8000, 16384);
    const voice = try e.play(sound, .{ .looping = true });
    try e.unload(sound);
    try testing.expectError(error.InvalidSound, e.play(sound, .{}));
    _ = renderFrames(&e, 16);
    try testing.expect(!e.isPlaying(voice));
    try testing.expectEqual(@as(usize, 0), e.pending.items.len);
}

test "a streamed QOA sound plays like a decoded one, across frames" {
    var e = try testEngine(4);
    defer e.deinit();
    const frames = qoa.frame_len + 300;
    const samples = try testing.allocator.alloc(i16, frames * 2);
    defer testing.allocator.free(samples);
    for (0..frames) |frame| {
        const t: f32 = @floatFromInt(frame);
        samples[frame * 2] = @intFromFloat(@sin(t * 0.07) * 10000);
        samples[frame * 2 + 1] = @intFromFloat(@cos(t * 0.03) * 10000);
    }
    const bytes = try qoa.encodeForTest(testing.allocator, samples, 2, 8000);
    defer testing.allocator.free(bytes);
    const decoded = try e.load(bytes, .{});
    const streamed = try e.load(bytes, .{ .stream = true });
    try testing.expectApproxEqAbs(@as(f64, @floatFromInt(frames)) / 8000, e.duration(streamed).?, 1e-9);

    var outputs: [2][(frames * 4 / 3 + 16) * 2]f32 = undefined;
    for ([2]Sound{ decoded, streamed }, &outputs) |sound, *out| {
        _ = try e.play(sound, .{ .pitch = 0.75 });
        e.render(out);
        e.update();
    }
    try testing.expectEqualSlices(f32, &outputs[0], &outputs[1]);
    try testing.expect(@abs(outputs[0][qoa.frame_len * 2]) > 0);
}
