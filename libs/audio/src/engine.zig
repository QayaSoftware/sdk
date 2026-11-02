const std = @import("std");
const handles = @import("handles");
const Device = @import("device.zig").Device;
const mixer = @import("mixer.zig");
const Mixer = mixer.Mixer;
const sound = @import("sound.zig");

pub const SoundTag = enum { sound };
/// A loaded sound, from `Engine.load`.
pub const Sound = handles.Handle(SoundTag);
pub const VoiceTag = enum { voice };
/// One playing of a sound, from `Engine.play`; stale once it ends.
pub const Voice = handles.Handle(VoiceTag);

/// A mixing bus: voices on it, and buses under it, are summed and scaled by
/// its volume. Buses live as long as the engine.
pub const Bus = enum(u8) {
    master = 0,
    _,
};

/// Where the mix goes.
pub const Output = enum {
    /// The system's default playback device, from its own thread.
    device,
    /// Nowhere until `Engine.render` is called, for tests, tools and
    /// applications with their own audio output.
    manual,
};

pub const Options = struct {
    output: Output = .device,
    /// Frames per second; 0 takes the device's own, or 48000 for `manual`.
    sample_rate: u32 = 0,
    /// Frames the device asks for at a time; 0 takes its own default.
    period_frames: u32 = 0,
    /// Voices playing at once, up to `mixer.max_voices`.
    max_voices: u16 = 64,
};

pub const LoadOptions = struct {
    /// Keep a QOA file encoded and decode it while it plays, for music and
    /// long ambience; WAV files are always decoded on load.
    stream: bool = false,
};

pub const PlayOptions = struct {
    volume: f32 = 1,
    /// Playback rate, 1 being the sound's own; changes pitch and speed.
    pitch: f32 = 1,
    /// -1 is left, 1 is right. Mono sounds pan with equal power, stereo
    /// sounds by balance.
    pan: f32 = 0,
    bus: Bus = .master,
    looping: bool = false,
    paused: bool = false,
    /// Seconds to fade in over.
    fade_in: f32 = 0,
    /// Seconds into the sound to start from.
    start: f32 = 0,
    /// With every voice in use, `play` takes the voice of the lowest
    /// priority, the oldest first, at or below this one.
    priority: u8 = 128,
    /// Places the voice in the world, heard from `Engine.setListener`.
    spatial: ?mixer.Spatial = null,
};

const Slot = struct {
    generation: u40 = 1,
    live: bool = false,
    priority: u8 = 0,
    order: u64 = 0,
};

const Pending = struct {
    data: *sound.Data,
    /// Commands the mixer must apply before `data` is unused; null until
    /// the command releasing it is queued.
    after: ?u64,
};

/// The game's side of the audio engine: loads sounds and plays them as
/// voices through a mixer on the audio thread. Its methods are for one
/// thread; call `update` once a frame.
pub const Engine = struct {
    gpa: std.mem.Allocator,
    mixer: *Mixer,
    device: ?Device,
    sounds: handles.HandleTable(*sound.Data, SoundTag),
    slots: []Slot,
    pending: std.ArrayList(Pending) = .empty,
    bus_count: u8 = 1,
    /// Commands queued so far.
    sent: u64 = 0,
    plays: u64 = 0,

    /// Opens the device and starts mixing. Fails with `error.NoAudioDevice`
    /// or `error.OutOfMemory`.
    pub fn init(gpa: std.mem.Allocator, options: Options) !Engine {
        const voices = std.math.clamp(options.max_voices, 1, mixer.max_voices);
        const slots = try gpa.alloc(Slot, voices);
        errdefer gpa.free(slots);
        @memset(slots, .{});
        var engine: Engine = .{
            .gpa = gpa,
            .mixer = undefined,
            .device = null,
            .sounds = .init(gpa),
            .slots = slots,
        };
        switch (options.output) {
            .manual => engine.mixer = try Mixer.create(gpa, if (options.sample_rate == 0) 48000 else options.sample_rate, voices),
            .device => {
                engine.mixer = try Mixer.create(gpa, 0, voices);
                errdefer engine.mixer.destroy(gpa);
                const device = try Device.open(options.sample_rate, options.period_frames, Mixer.renderCallback, engine.mixer);
                engine.mixer.sample_rate = device.sample_rate;
                try device.start();
                engine.device = device;
            },
        }
        return engine;
    }

    /// Closes the device and frees every sound.
    pub fn deinit(self: *Engine) void {
        if (self.device) |device| device.close();
        while (self.sounds.popAny()) |data| self.freeData(data);
        for (self.pending.items) |pending| self.freeData(pending.data);
        self.pending.deinit(self.gpa);
        self.sounds.deinit();
        self.mixer.destroy(self.gpa);
        self.gpa.free(self.slots);
        self.* = undefined;
    }

    /// Frames per second the mix runs at.
    pub fn sampleRate(self: *const Engine) u32 {
        return self.mixer.sample_rate;
    }

    /// The device's backend, such as "PulseAudio" or "WASAPI", or null for
    /// `manual` output.
    pub fn backend(self: *const Engine) ?[]const u8 {
        return if (self.device) |device| device.backend() else null;
    }

    /// Frees what the mixer is done with and ends voices it finished; call
    /// once a frame.
    pub fn update(self: *Engine) void {
        while (self.mixer.finished.pop()) |finished| {
            const slot = &self.slots[finished.slot];
            if (slot.live and slot.generation == finished.serial) self.retire(finished.slot);
        }
        const applied = self.mixer.applied.load(.acquire);
        var index: usize = 0;
        while (index < self.pending.items.len) {
            const pending = &self.pending.items[index];
            if (pending.after == null) {
                if (self.send(.{ .release_sound = pending.data })) |_| {
                    pending.after = self.sent;
                } else |_| {}
            }
            if (pending.after != null and applied >= pending.after.?) {
                self.freeData(self.pending.swapRemove(index).data);
            } else index += 1;
        }
    }

    /// Mixes `out.len / 2` interleaved stereo frames; `manual` output only.
    pub fn render(self: *Engine, out: []f32) void {
        std.debug.assert(self.device == null);
        self.mixer.render(out);
    }

    /// Loads a WAV or QOA file from `bytes`, which it copies. Fails with
    /// `error.UnknownFormat`, `error.InvalidWav`, `error.UnsupportedWav`,
    /// `error.InvalidQoa`, `error.UnsupportedQoa`, `error.UnsupportedChannels`,
    /// `error.EmptySound`, `error.HandleTableFull` or `error.OutOfMemory`.
    pub fn load(self: *Engine, bytes: []const u8, options: LoadOptions) !Sound {
        const data = try self.gpa.create(sound.Data);
        errdefer self.gpa.destroy(data);
        data.* = try sound.Data.load(self.gpa, bytes, options.stream);
        errdefer data.deinit(self.gpa);
        return self.sounds.insert(data);
    }

    /// `load` with the file at `path` in `dir`.
    pub fn loadFile(self: *Engine, io: std.Io, dir: std.Io.Dir, path: []const u8, options: LoadOptions) !Sound {
        const bytes = try dir.readFileAlloc(io, path, self.gpa, .unlimited);
        defer self.gpa.free(bytes);
        return self.load(bytes, options);
    }

    /// Ends the sound's voices and frees it once the mixer lets go of it, in
    /// a later `update`. Fails with `error.OutOfMemory`, leaving it loaded.
    pub fn unload(self: *Engine, handle: Sound) !void {
        if (self.sounds.get(handle) == null) return;
        try self.pending.ensureUnusedCapacity(self.gpa, 1);
        const data = self.sounds.remove(handle).?;
        const after: ?u64 = if (self.send(.{ .release_sound = data })) |_| self.sent else |_| null;
        self.pending.appendAssumeCapacity(.{ .data = data, .after = after });
    }

    /// Seconds the sound lasts at its own rate, or null for a stale handle.
    pub fn duration(self: *const Engine, handle: Sound) ?f64 {
        const data = self.sounds.get(handle) orelse return null;
        return data.*.duration();
    }

    /// Starts `handle` on a voice. Fails with `error.InvalidSound`,
    /// `error.NoFreeVoice` when every voice is busy at a higher priority, or
    /// `error.CommandQueueFull`.
    pub fn play(self: *Engine, handle: Sound, options: PlayOptions) !Voice {
        const data = (self.sounds.get(handle) orelse return error.InvalidSound).*;
        std.debug.assert(@backingInt(options.bus) < self.bus_count);
        const index = self.freeSlot(options.priority) orelse return error.NoFreeVoice;
        const slot = &self.slots[index];
        const generation = if (slot.live) nextGeneration(slot.generation) else slot.generation;
        const rate: f32 = @floatFromInt(data.sample_rate);
        const mix_rate: f32 = @floatFromInt(self.mixer.sample_rate);
        try self.send(.{ .play = .{
            .slot = index,
            .serial = generation,
            .data = data,
            .start = .{
                .volume = options.volume,
                .pitch = options.pitch,
                .pan = options.pan,
                .bus = @backingInt(options.bus),
                .looping = options.looping,
                .paused = options.paused,
                .fade_in_frames = @intFromFloat(@max(options.fade_in, 0) * mix_rate),
                .start_frame = @min(@max(options.start, 0) * rate, @as(f32, @floatFromInt(data.frames))),
                .spatial = options.spatial,
            },
        } });
        self.plays += 1;
        slot.* = .{ .generation = generation, .live = true, .priority = options.priority, .order = self.plays };
        return .{ .index = index, .generation = generation };
    }

    /// Whether `voice` is still playing or paused.
    pub fn isPlaying(self: *const Engine, voice: Voice) bool {
        return self.resolve(voice) != null;
    }

    /// Fades `voice` out over `fade` seconds and ends it. Fails with
    /// `error.CommandQueueFull`; a stale voice is ignored.
    pub fn stop(self: *Engine, voice: Voice, fade: f32) !void {
        const slot = self.resolve(voice) orelse return;
        try self.send(.{ .stop = .{ .slot = slot, .fade_frames = @intFromFloat(@max(fade, 0) * @as(f32, @floatFromInt(self.mixer.sample_rate))) } });
    }

    pub fn setPaused(self: *Engine, voice: Voice, paused: bool) !void {
        const slot = self.resolve(voice) orelse return;
        try self.send(.{ .pause = .{ .slot = slot, .paused = paused } });
    }

    pub fn setVolume(self: *Engine, voice: Voice, volume: f32) !void {
        const slot = self.resolve(voice) orelse return;
        try self.send(.{ .volume = .{ .slot = slot, .value = volume } });
    }

    pub fn setPitch(self: *Engine, voice: Voice, pitch: f32) !void {
        const slot = self.resolve(voice) orelse return;
        try self.send(.{ .pitch = .{ .slot = slot, .value = pitch } });
    }

    pub fn setPan(self: *Engine, voice: Voice, pan: f32) !void {
        const slot = self.resolve(voice) orelse return;
        try self.send(.{ .pan = .{ .slot = slot, .value = pan } });
    }

    /// Moves a voice started with `spatial`; others ignore it.
    pub fn setPosition(self: *Engine, voice: Voice, position: mixer.Vec3) !void {
        const slot = self.resolve(voice) orelse return;
        try self.send(.{ .position = .{ .slot = slot, .value = position } });
    }

    pub fn setListener(self: *Engine, listener: mixer.Listener) !void {
        try self.send(.{ .listener = listener });
    }

    /// Adds a bus feeding `parent`. Fails with `error.TooManyBuses` past
    /// `mixer.max_buses`, or `error.CommandQueueFull`.
    pub fn createBus(self: *Engine, parent: Bus) !Bus {
        std.debug.assert(@backingInt(parent) < self.bus_count);
        if (self.bus_count == mixer.max_buses) return error.TooManyBuses;
        try self.send(.{ .bus_add = .{ .bus = self.bus_count, .parent = @backingInt(parent) } });
        self.bus_count += 1;
        return @fromBackingInt(@intCast(self.bus_count - 1));
    }

    pub fn setBusVolume(self: *Engine, bus: Bus, volume: f32) !void {
        std.debug.assert(@backingInt(bus) < self.bus_count);
        try self.send(.{ .bus_volume = .{ .bus = @backingInt(bus), .value = volume } });
    }

    fn send(self: *Engine, command: mixer.Command) !void {
        if (!self.mixer.commands.push(command)) return error.CommandQueueFull;
        self.sent += 1;
    }

    fn resolve(self: *const Engine, voice: Voice) ?u16 {
        if (voice.index >= self.slots.len) return null;
        const slot = self.slots[voice.index];
        return if (slot.live and slot.generation == voice.generation) @intCast(voice.index) else null;
    }

    fn retire(self: *Engine, index: u16) void {
        const slot = &self.slots[index];
        slot.live = false;
        slot.generation = nextGeneration(slot.generation);
    }

    fn nextGeneration(generation: u40) u40 {
        return if (generation +% 1 == 0) 1 else generation + 1;
    }

    /// A slot to play in: a free one, or the live one of the lowest priority
    /// at or below `priority`, the oldest first.
    fn freeSlot(self: *const Engine, priority: u8) ?u16 {
        var victim: ?u16 = null;
        for (self.slots, 0..) |slot, index| {
            if (!slot.live) return @intCast(index);
            if (slot.priority > priority) continue;
            if (victim) |best| {
                const other = self.slots[best];
                if (slot.priority > other.priority or (slot.priority == other.priority and slot.order > other.order)) continue;
            }
            victim = @intCast(index);
        }
        return victim;
    }

    fn freeData(self: *Engine, data: *sound.Data) void {
        data.deinit(self.gpa);
        self.gpa.destroy(data);
    }
};
