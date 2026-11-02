const std = @import("std");
const Ring = @import("ring.zig").Ring;
const sound = @import("sound.zig");

/// Buses a mixer holds, the master included.
pub const max_buses = 32;
/// Voices a mixer can hold at most; each keeps a decoded QOA frame of
/// about 20 KiB for streamed sounds.
pub const max_voices = 256;
/// Frames mixed at a time; gains glide from one block's value to the next.
const block_frames = 256;
/// Frames a stop or pause fades over at least, so it never clicks.
const declick_frames = 64;
const command_capacity = 4096;

/// A point or direction in the listener's world: right-handed, y up.
pub const Vec3 = [3]f32;

/// Where sound is heard from.
pub const Listener = struct {
    position: Vec3 = .{ 0, 0, 0 },
    forward: Vec3 = .{ 0, 0, -1 },
    up: Vec3 = .{ 0, 1, 0 },
};

/// A voice placed in the world: quieter with distance between
/// `min_distance` and `max_distance`, by `min / (min + rolloff * (d - min))`,
/// and panned toward its side of the listener.
pub const Spatial = struct {
    position: Vec3 = .{ 0, 0, 0 },
    min_distance: f32 = 1,
    max_distance: f32 = 100,
    rolloff: f32 = 1,
};

/// How a voice starts.
pub const Start = struct {
    volume: f32,
    pitch: f32,
    pan: f32,
    bus: u8,
    looping: bool,
    paused: bool,
    fade_in_frames: u32,
    start_frame: f64,
    spatial: ?Spatial,
};

/// What the game thread asks of the mixer.
pub const Command = union(enum) {
    /// Starts `data` in `slot`, replacing what plays there without an event.
    play: struct { slot: u16, serial: u40, data: *const sound.Data, start: Start },
    stop: struct { slot: u16, fade_frames: u32 },
    pause: struct { slot: u16, paused: bool },
    volume: struct { slot: u16, value: f32 },
    pitch: struct { slot: u16, value: f32 },
    pan: struct { slot: u16, value: f32 },
    position: struct { slot: u16, value: Vec3 },
    bus_volume: struct { bus: u8, value: f32 },
    /// Adds bus `bus`, above every bus before it, feeding `parent`.
    bus_add: struct { bus: u8, parent: u8 },
    listener: Listener,
    /// Ends every voice playing `data` at once, so it can be freed.
    release_sound: *const sound.Data,
};

/// A voice that ended by itself or by `stop`, as `serial` in `slot`.
pub const Finished = struct { slot: u16, serial: u40 };

const FadeEnd = enum { none, release, pause };

const Voice = struct {
    data: ?*const sound.Data = null,
    serial: u40 = 0,
    start: Start = undefined,
    position: f64 = 0,
    gains: [2]f32 = .{ 0, 0 },
    fade: f32 = 1,
    fade_target: f32 = 1,
    fade_step: f32 = 0,
    fade_end: FadeEnd = .none,
    paused: bool = false,

    /// Glides `fade` to `target` over `frames`, then does `end`.
    fn fadeTo(self: *Voice, target: f32, frames: u32, end: FadeEnd) void {
        self.fade_target = target;
        self.fade_step = @max(@abs(target - self.fade) / @as(f32, @floatFromInt(frames)), 1e-6);
        self.fade_end = end;
    }

    /// One frame's step of the fade; true once it reaches its target.
    fn advanceFade(self: *Voice) bool {
        self.fade = if (self.fade < self.fade_target) @min(self.fade + self.fade_step, self.fade_target) else @max(self.fade - self.fade_step, self.fade_target);
        return self.fade == self.fade_target;
    }
};

const Bus = struct {
    parent: u8 = 0,
    volume: f32 = 1,
    gain: f32 = 1,
};

/// The realtime half of the engine: commands in, interleaved stereo out,
/// finished voices back. `render` runs on one thread, the audio thread, and
/// never waits, locks or allocates; everything else runs on one other
/// thread, the game's.
pub const Mixer = struct {
    sample_rate: u32,
    voices: []Voice,
    /// Where each voice reads its sound, beside `voices`.
    cursors: []sound.Cursor,
    buses: [max_buses]Bus = @splat(.{}),
    bus_count: u8 = 1,
    listener: Listener = .{},
    commands: Ring(Command, command_capacity) = .{},
    finished: Ring(Finished, max_voices * 2) = .{},
    /// Commands applied so far, published after each batch; what a command
    /// retired may be freed once this passes it.
    applied: std.atomic.Value(u64) = .init(0),
    mix: [max_buses][block_frames * 2]f32 = undefined,

    pub fn create(gpa: std.mem.Allocator, sample_rate: u32, voice_count: u16) !*Mixer {
        std.debug.assert(voice_count > 0 and voice_count <= max_voices);
        const self = try gpa.create(Mixer);
        errdefer gpa.destroy(self);
        const voices = try gpa.alloc(Voice, voice_count);
        errdefer gpa.free(voices);
        const cursors = try gpa.alloc(sound.Cursor, voice_count);
        self.* = .{ .sample_rate = sample_rate, .voices = voices, .cursors = cursors };
        @memset(cursors, .{});
        @memset(self.voices, .{});
        return self;
    }

    pub fn destroy(self: *Mixer, gpa: std.mem.Allocator) void {
        gpa.free(self.voices);
        gpa.free(self.cursors);
        gpa.destroy(self);
    }

    /// Applies waiting commands and mixes `out.len / 2` stereo frames.
    pub fn render(self: *Mixer, out: []f32) void {
        var applied: u64 = 0;
        while (self.commands.pop()) |command| : (applied += 1) self.apply(command);
        if (applied > 0) self.applied.store(self.applied.load(.monotonic) + applied, .release);
        var at: usize = 0;
        while (at < out.len) {
            const frames: usize = @min(block_frames, (out.len - at) / 2);
            self.mixBlock(out[at..][0 .. frames * 2]);
            at += frames * 2;
        }
    }

    /// For a device's render callback, with this mixer as `user`.
    pub fn renderCallback(user: ?*anyopaque, out: [*]f32, frames: u32) callconv(.c) void {
        const self: *Mixer = @ptrCast(@alignCast(user.?));
        self.render(out[0 .. @as(usize, frames) * 2]);
    }

    fn apply(self: *Mixer, command: Command) void {
        switch (command) {
            .play => |play| {
                const voice = &self.voices[play.slot];
                voice.* = .{
                    .data = play.data,
                    .serial = play.serial,
                    .start = play.start,
                    .position = play.start.start_frame,
                    .paused = play.start.paused,
                };
                self.cursors[play.slot].reset();
                if (play.start.fade_in_frames > 0) {
                    voice.fade = 0;
                    voice.fade_step = 1 / @as(f32, @floatFromInt(play.start.fade_in_frames));
                }
                voice.gains = self.targetGains(voice);
            },
            .stop => |stop| {
                const voice = &self.voices[stop.slot];
                if (voice.data == null) return;
                if (voice.paused) return self.release(stop.slot);
                voice.fadeTo(0, @max(stop.fade_frames, declick_frames), .release);
            },
            .pause => |pause| {
                const voice = &self.voices[pause.slot];
                if (voice.data == null or voice.fade_end == .release) return;
                if (pause.paused) {
                    if (!voice.paused) voice.fadeTo(0, declick_frames, .pause);
                } else {
                    voice.paused = false;
                    voice.fadeTo(1, declick_frames, .none);
                }
            },
            .volume => |set| self.voices[set.slot].start.volume = set.value,
            .pitch => |set| self.voices[set.slot].start.pitch = set.value,
            .pan => |set| self.voices[set.slot].start.pan = set.value,
            .position => |set| if (self.voices[set.slot].start.spatial) |*spatial| {
                spatial.position = set.value;
            },
            .bus_volume => |set| self.buses[set.bus].volume = set.value,
            .bus_add => |add| {
                self.buses[add.bus] = .{ .parent = add.parent };
                self.bus_count = @max(self.bus_count, add.bus + 1);
            },
            .listener => |listener| self.listener = listener,
            .release_sound => |data| for (self.voices, 0..) |voice, slot| {
                if (voice.data == data) self.release(@intCast(slot));
            },
        }
    }

    fn release(self: *Mixer, slot: u16) void {
        const voice = &self.voices[slot];
        voice.data = null;
        _ = self.finished.push(.{ .slot = slot, .serial = voice.serial });
    }

    fn mixBlock(self: *Mixer, out: []f32) void {
        for (self.mix[0..self.bus_count]) |*buffer| @memset(buffer[0..out.len], 0);
        for (self.voices, 0..) |*voice, slot| {
            if (voice.data != null and !voice.paused) self.mixVoice(voice, @intCast(slot), self.mix[voice.start.bus][0..out.len]);
        }
        const frames: f32 = @floatFromInt(out.len / 2);
        var bus = self.bus_count;
        while (bus > 0) {
            bus -= 1;
            const state = &self.buses[bus];
            const step = (state.volume - state.gain) / frames;
            const into = if (bus == 0) out else self.mix[state.parent][0..out.len];
            for (0..out.len / 2) |frame| {
                const gain = state.gain + step * @as(f32, @floatFromInt(frame + 1));
                for (0..2) |channel| {
                    const value = self.mix[bus][frame * 2 + channel] * gain;
                    if (bus == 0) {
                        into[frame * 2 + channel] = std.math.clamp(value, -1, 1);
                    } else {
                        into[frame * 2 + channel] += value;
                    }
                }
            }
            state.gain = state.volume;
        }
    }

    fn mixVoice(self: *Mixer, voice: *Voice, slot: u16, into: []f32) void {
        const data = voice.data.?;
        const cursor = &self.cursors[slot];
        const target = self.targetGains(voice);
        const frames = into.len / 2;
        const count: f32 = @floatFromInt(frames);
        const steps: [2]f32 = .{ (target[0] - voice.gains[0]) / count, (target[1] - voice.gains[1]) / count };
        const rate = @as(f64, @floatFromInt(data.sample_rate)) / @as(f64, @floatFromInt(self.sample_rate)) * @max(voice.start.pitch, 0);
        const end: f64 = @floatFromInt(data.frames);
        defer voice.gains = target;
        for (0..frames) |frame| {
            if (voice.position >= end) {
                if (!voice.start.looping) return self.release(slot);
                voice.position = @mod(voice.position, end);
            }
            const index: u32 = @intFromFloat(voice.position);
            const fraction: f32 = @floatCast(voice.position - @as(f64, @floatFromInt(index)));
            const a = cursor.read(data, index);
            const b = if (index + 1 < data.frames) cursor.read(data, index + 1) else if (voice.start.looping) data.first else [2]f32{ 0, 0 };
            const along: f32 = @floatFromInt(frame + 1);
            for (0..2) |channel| {
                const value = a[channel] + (b[channel] - a[channel]) * fraction;
                into[frame * 2 + channel] += value * (voice.gains[channel] + steps[channel] * along) * voice.fade;
            }
            voice.position += rate;
            if ((voice.fade != voice.fade_target or voice.fade_end != .none) and voice.advanceFade()) switch (voice.fade_end) {
                .none => {},
                .release => return self.release(slot),
                .pause => {
                    voice.paused = true;
                    voice.fade_end = .none;
                    return;
                },
            };
        }
    }

    /// Left and right gains from volume, pan and placement.
    fn targetGains(self: *const Mixer, voice: *const Voice) [2]f32 {
        var pan = voice.start.pan;
        var volume = voice.start.volume;
        if (voice.start.spatial) |spatial| {
            const listener = self.listener;
            const offset = sub(spatial.position, listener.position);
            const distance = length(offset);
            const clamped = std.math.clamp(distance, spatial.min_distance, @max(spatial.min_distance, spatial.max_distance));
            volume *= spatial.min_distance / @max(spatial.min_distance + spatial.rolloff * (clamped - spatial.min_distance), 1e-6);
            const right = normalize(cross(listener.forward, listener.up));
            if (distance > 1e-4) pan += dot(offset, right) / distance;
        }
        pan = std.math.clamp(pan, -1, 1);
        const gains: [2]f32 = if (voice.data.?.channels == 1) blk: {
            const angle = (pan + 1) * std.math.pi / 4;
            break :blk .{ @cos(angle), @sin(angle) };
        } else .{ @min(1, 1 - pan), @min(1, 1 + pan) };
        return .{ gains[0] * volume, gains[1] * volume };
    }
};

fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn length(a: Vec3) f32 {
    return @sqrt(dot(a, a));
}

fn normalize(a: Vec3) Vec3 {
    const len = length(a);
    return if (len > 0) .{ a[0] / len, a[1] / len, a[2] / len } else a;
}

fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
