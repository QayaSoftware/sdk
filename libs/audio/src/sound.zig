const std = @import("std");
const qoa = @import("qoa.zig");
const wav = @import("wav.zig");

/// A loaded sound, read-only once loaded: decoded samples, or a QOA file
/// the mixer decodes a frame at a time while it plays.
pub const Data = struct {
    sample_rate: u32,
    /// 1 or 2.
    channels: u8,
    /// Samples per channel.
    frames: u32,
    source: Source,
    /// The first frame, for interpolating across a loop's seam without
    /// decoding.
    first: [2]f32,

    pub const Source = union(enum) {
        /// Interleaved, in [-1, 1].
        samples: []f32,
        qoa: struct { bytes: []u8, info: qoa.Info },
    };

    /// Decodes WAV or QOA `bytes`, or with `stream` keeps a copy of QOA
    /// bytes to decode while playing. Fails with `error.UnknownFormat`,
    /// `error.UnsupportedChannels` past stereo, `error.EmptySound`, the
    /// decoders' errors or `error.OutOfMemory`.
    pub fn load(gpa: std.mem.Allocator, bytes: []const u8, stream: bool) !Data {
        var data: Data = if (qoa.matches(bytes)) try loadQoa(gpa, bytes, stream) else if (wav.matches(bytes)) try loadWav(gpa, bytes) else return error.UnknownFormat;
        errdefer data.deinit(gpa);
        var cursor: Cursor = .{};
        data.first = cursor.read(&data, 0);
        return data;
    }

    pub fn deinit(self: *Data, gpa: std.mem.Allocator) void {
        switch (self.source) {
            .samples => |samples| gpa.free(samples),
            .qoa => |file| gpa.free(file.bytes),
        }
        self.* = undefined;
    }

    /// Length in seconds.
    pub fn duration(self: Data) f64 {
        return @as(f64, @floatFromInt(self.frames)) / @as(f64, @floatFromInt(self.sample_rate));
    }

    fn loadWav(gpa: std.mem.Allocator, bytes: []const u8) !Data {
        const info = try wav.parse(bytes);
        if (info.channels > 2) return error.UnsupportedChannels;
        if (info.frames == 0) return error.EmptySound;
        const samples = try gpa.alloc(f32, info.data.len / (info.bits / 8));
        for (samples, 0..) |*value, index| value.* = info.sample(index);
        return .{ .sample_rate = info.sample_rate, .channels = @intCast(info.channels), .frames = info.frames, .source = .{ .samples = samples }, .first = undefined };
    }

    fn loadQoa(gpa: std.mem.Allocator, bytes: []const u8, stream: bool) !Data {
        const info = try qoa.parse(bytes);
        if (info.channels > 2) return error.UnsupportedChannels;
        const channels: usize = info.channels;
        if (stream) {
            for (0..info.frameCount()) |index| _ = try qoa.checkFrame(bytes, info, @intCast(index));
            return .{ .sample_rate = info.sample_rate, .channels = info.channels, .frames = info.frames, .source = .{ .qoa = .{ .bytes = try gpa.dupe(u8, bytes), .info = info } }, .first = undefined };
        }
        const samples = try gpa.alloc(f32, @as(usize, info.frames) * channels);
        errdefer gpa.free(samples);
        var decoded: [qoa.frame_len * 2]i16 = undefined;
        for (0..info.frameCount()) |index| {
            const count = try qoa.decodeFrame(bytes, info, @intCast(index), &decoded);
            const into = samples[index * qoa.frame_len * channels ..][0 .. count * channels];
            for (into, decoded[0..into.len]) |*value, sample| value.* = @as(f32, @floatFromInt(sample)) / 32768;
        }
        return .{ .sample_rate = info.sample_rate, .channels = info.channels, .frames = info.frames, .source = .{ .samples = samples }, .first = undefined };
    }
};

/// Where one voice reads a sound: for a streamed sound, the QOA frame it
/// decoded last, and the frame before it's final sample, so reading forward
/// across a frame boundary decodes each frame once.
pub const Cursor = struct {
    const none = std.math.maxInt(u32);

    frame: u32 = none,
    count: u32 = 0,
    decoded: [qoa.frame_len * 2]i16 = undefined,
    /// The last sample of frame `frame - 1`, when `tail_valid`.
    tail: [2]f32 = .{ 0, 0 },
    tail_valid: bool = false,

    /// Forgets what was decoded, for a new sound.
    pub fn reset(self: *Cursor) void {
        self.frame = none;
        self.tail_valid = false;
    }

    /// Frame `index` of `data`, below `data.frames`, as left and right.
    pub fn read(self: *Cursor, data: *const Data, index: u32) [2]f32 {
        switch (data.source) {
            .samples => |samples| return if (data.channels == 1)
                @splat(samples[index])
            else
                .{ samples[index * 2], samples[index * 2 + 1] },
            .qoa => |file| {
                const frame = index / qoa.frame_len;
                if (frame != self.frame) {
                    if (self.tail_valid and frame + 1 == self.frame and index + 1 == self.frame * qoa.frame_len) return self.tail;
                    const previous = if (self.frame != none and frame == self.frame + 1 and self.count > 0) self.local(data, self.count - 1) else null;
                    self.count = qoa.decodeFrame(file.bytes, file.info, frame, &self.decoded) catch 0;
                    self.frame = frame;
                    self.tail_valid = previous != null;
                    if (previous) |sample| self.tail = sample;
                }
                const offset = index - frame * qoa.frame_len;
                return if (offset < self.count) self.local(data, offset) else .{ 0, 0 };
            },
        }
    }

    fn local(self: *const Cursor, data: *const Data, offset: u32) [2]f32 {
        const scale = 1.0 / 32768.0;
        if (data.channels == 1) return @splat(@as(f32, @floatFromInt(self.decoded[offset])) * scale);
        return .{ @as(f32, @floatFromInt(self.decoded[offset * 2])) * scale, @as(f32, @floatFromInt(self.decoded[offset * 2 + 1])) * scale };
    }
};

test "a WAV file decodes to samples" {
    const gpa = std.testing.allocator;
    const bytes = try wav.encode16(gpa, &.{ 16384, -16384, 0 }, 1, 8000);
    defer gpa.free(bytes);
    var data = try Data.load(gpa, bytes, false);
    defer data.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 3), data.frames);
    try std.testing.expectEqual([2]f32{ 0.5, 0.5 }, data.first);
    var cursor: Cursor = .{};
    try std.testing.expectEqual([2]f32{ -0.5, -0.5 }, cursor.read(&data, 1));
    try std.testing.expectError(error.UnknownFormat, Data.load(gpa, "nothing", false));
}
