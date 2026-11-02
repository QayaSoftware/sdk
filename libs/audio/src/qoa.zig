//! The Quite OK Audio format (qoaformat.org): lossy 16-bit PCM at 3.2 bits
//! per sample, in frames of 5120 samples per channel that decode on their
//! own, so a file plays from memory one frame at a time.
const std = @import("std");

/// Samples per channel in every frame but the last.
pub const frame_len = 5120;
const slice_len = 20;
const slices_per_frame = frame_len / slice_len;
const file_header_size = 8;
/// Channels `parse` accepts; the format allows up to 255.
pub const max_channels = 8;

const scalefactors = [16]i32{ 1, 7, 21, 45, 84, 138, 211, 304, 421, 562, 731, 928, 1157, 1419, 1715, 2048 };
const dequant: [16][8]i32 = blk: {
    const steps = [8]f64{ 0.75, -0.75, 2.5, -2.5, 4.5, -4.5, 7, -7 };
    var table: [16][8]i32 = undefined;
    for (&table, scalefactors) |*row, scalefactor| {
        for (row, steps) |*value, step| value.* = @intFromFloat(@round(@as(f64, @floatFromInt(scalefactor)) * step));
    }
    break :blk table;
};

/// What a file's header and first frame declare.
pub const Info = struct {
    channels: u8,
    sample_rate: u32,
    /// Samples per channel.
    frames: u32,

    /// Frames of the file, the last one possibly short.
    pub fn frameCount(self: Info) u32 {
        return (self.frames + frame_len - 1) / frame_len;
    }
};

/// Whether `bytes` start like a QOA file.
pub fn matches(bytes: []const u8) bool {
    return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "qoaf");
}

/// Reads the header. Fails with `error.InvalidQoa` and, for a streaming
/// file of unknown length, `error.UnsupportedQoa`.
pub fn parse(bytes: []const u8) !Info {
    if (!matches(bytes) or bytes.len < file_header_size + 8) return error.InvalidQoa;
    const frames = std.mem.readInt(u32, bytes[4..8], .big);
    if (frames == 0) return error.UnsupportedQoa;
    const header = std.mem.readInt(u64, bytes[8..16], .big);
    const channels: u8 = @intCast(header >> 56);
    const sample_rate: u32 = @intCast((header >> 32) & 0xffffff);
    if (channels == 0 or sample_rate == 0) return error.InvalidQoa;
    if (channels > max_channels) return error.UnsupportedQoa;
    return .{ .channels = channels, .sample_rate = sample_rate, .frames = frames };
}

fn frameSize(channels: u32, samples: u32) usize {
    const slices = (samples + slice_len - 1) / slice_len;
    return 8 + 16 * @as(usize, channels) + 8 * @as(usize, slices) * channels;
}

fn frameOffset(info: Info, index: u32) usize {
    return file_header_size + @as(usize, index) * frameSize(info.channels, frame_len);
}

/// Checks frame `index`'s header against the file `info` describes, without
/// decoding it, and returns its samples per channel. Fails with
/// `error.InvalidQoa`.
pub fn checkFrame(bytes: []const u8, info: Info, index: u32) !u32 {
    if (index >= info.frameCount()) return error.InvalidQoa;
    const at = frameOffset(info, index);
    if (at + 8 > bytes.len) return error.InvalidQoa;
    const header = std.mem.readInt(u64, bytes[at..][0..8], .big);
    const samples: u32 = @intCast((header >> 16) & 0xffff);
    const size: usize = @intCast(header & 0xffff);
    if (header >> 56 != info.channels or samples != @min(frame_len, info.frames - index * frame_len) or
        size != frameSize(info.channels, samples) or at + size > bytes.len) return error.InvalidQoa;
    return samples;
}

/// Decodes frame `index` of the file `info` describes into `out`,
/// interleaved, and returns its samples per channel. `out` holds at least
/// `frame_len * info.channels` samples. Fails with `error.InvalidQoa`.
pub fn decodeFrame(bytes: []const u8, info: Info, index: u32, out: []i16) !u32 {
    const channels: usize = info.channels;
    std.debug.assert(out.len >= frame_len * channels);
    const samples = try checkFrame(bytes, info, index);
    var at = frameOffset(info, index) + 8;

    var lms: [max_channels]Lms = undefined;
    for (lms[0..channels]) |*state| {
        state.* = .{ .history = unpack(bytes[at..][0..8]), .weights = unpack(bytes[at + 8 ..][0..8]) };
        at += 16;
    }
    var start: u32 = 0;
    while (start < samples) : (start += slice_len) {
        const end = @min(start + slice_len, samples);
        for (lms[0..channels], 0..) |*state, channel| {
            var slice = std.mem.readInt(u64, bytes[at..][0..8], .big);
            at += 8;
            const row = &dequant[@intCast(slice >> 60)];
            slice <<= 4;
            for (start..end) |sample| {
                const residual = row[@intCast(slice >> 61)];
                const value = clamp16(state.predict() + residual);
                state.update(value, residual);
                out[sample * channels + channel] = @intCast(value);
                slice <<= 3;
            }
        }
    }
    return samples;
}

fn unpack(bytes: *const [8]u8) [4]i32 {
    var values: [4]i32 = undefined;
    for (&values, 0..) |*value, index| value.* = std.mem.readInt(i16, bytes[index * 2 ..][0..2], .big);
    return values;
}

fn clamp16(value: i32) i32 {
    return std.math.clamp(value, std.math.minInt(i16), std.math.maxInt(i16));
}

/// A channel's sign-sign LMS predictor.
const Lms = struct {
    history: [4]i32,
    weights: [4]i32,

    fn predict(self: Lms) i32 {
        var sum: i32 = 0;
        for (self.history, self.weights) |history, weight| sum +%= history *% weight;
        return sum >> 13;
    }

    fn update(self: *Lms, sample: i32, residual: i32) void {
        const delta = residual >> 4;
        for (&self.weights, self.history) |*weight, history| weight.* +%= if (history < 0) -delta else delta;
        self.history = .{ self.history[1], self.history[2], self.history[3], sample };
    }
};

/// Encodes interleaved `samples` to QOA by trying every scalefactor for each
/// slice; slow, for tests.
pub fn encodeForTest(gpa: std.mem.Allocator, samples: []const i16, channels: u8, sample_rate: u32) ![]u8 {
    const frames: u32 = @intCast(samples.len / channels);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "qoaf");
    try appendInt(gpa, &out, u32, frames);
    var lms: [max_channels]Lms = @splat(.{ .history = @splat(0), .weights = .{ 0, 0, -(1 << 13), 1 << 14 } });
    var frame_start: u32 = 0;
    while (frame_start < frames) : (frame_start += frame_len) {
        const count = @min(frame_len, frames - frame_start);
        try appendInt(gpa, &out, u64, @as(u64, channels) << 56 | @as(u64, sample_rate) << 32 | @as(u64, count) << 16 | frameSize(channels, count));
        for (lms[0..channels]) |state| {
            for ([2][4]i32{ state.history, state.weights }) |values| {
                var packed_values: u64 = 0;
                for (values) |value| packed_values = packed_values << 16 | @as(u16, @bitCast(@as(i16, @intCast(value))));
                try appendInt(gpa, &out, u64, packed_values);
            }
        }
        var start: u32 = 0;
        while (start < count) : (start += slice_len) {
            const end = @min(start + slice_len, count);
            for (lms[0..channels], 0..) |*state, channel| {
                var best: struct { err: u64, slice: u64, lms: Lms } = .{ .err = std.math.maxInt(u64), .slice = 0, .lms = state.* };
                for (dequant, 0..) |row, scalefactor| {
                    var trial = state.*;
                    var slice: u64 = scalefactor;
                    var err: u64 = 0;
                    for (start..end) |sample| {
                        const wanted: i32 = samples[(frame_start + sample) * channels + channel];
                        const predicted = trial.predict();
                        var pick: usize = 0;
                        for (row, 0..) |step, q| {
                            if (@abs(wanted - clamp16(predicted + step)) < @abs(wanted - clamp16(predicted + row[pick]))) pick = q;
                        }
                        const value = clamp16(predicted + row[pick]);
                        trial.update(value, row[pick]);
                        err += @as(u64, @abs(wanted - value)) * @abs(wanted - value);
                        slice = slice << 3 | pick;
                    }
                    if (err < best.err) best = .{ .err = err, .slice = slice << @intCast(3 * (slice_len - (end - start))), .lms = trial };
                }
                state.* = best.lms;
                try appendInt(gpa, &out, u64, best.slice);
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

fn appendInt(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    try out.appendSlice(gpa, &bytes);
}

test "dequantization matches the reference table" {
    try std.testing.expectEqual([8]i32{ 1, -1, 3, -3, 5, -5, 7, -7 }, dequant[0]);
    try std.testing.expectEqual([8]i32{ 5, -5, 18, -18, 32, -32, 49, -49 }, dequant[1]);
    try std.testing.expectEqual([8]i32{ 1536, -1536, 5120, -5120, 9216, -9216, 14336, -14336 }, dequant[15]);
}

test "a stereo signal survives encoding and decoding across frames" {
    const gpa = std.testing.allocator;
    const frames = frame_len * 2 + 777;
    const samples = try gpa.alloc(i16, frames * 2);
    defer gpa.free(samples);
    for (0..frames) |frame| {
        const t: f32 = @floatFromInt(frame);
        samples[frame * 2] = @intFromFloat(@sin(t * 0.05) * 12000);
        samples[frame * 2 + 1] = @intFromFloat(@sin(t * 0.013) * 9000);
    }
    const encoded = try encodeForTest(gpa, samples, 2, 44100);
    defer gpa.free(encoded);
    const info = try parse(encoded);
    try std.testing.expectEqual(Info{ .channels = 2, .sample_rate = 44100, .frames = frames }, info);
    try std.testing.expectEqual(@as(u32, 3), info.frameCount());

    var decoded: [frame_len * 2]i16 = undefined;
    var squared: f64 = 0;
    for (0..info.frameCount()) |index| {
        const count = try decodeFrame(encoded, info, @intCast(index), &decoded);
        try std.testing.expectEqual(@min(frame_len, frames - index * frame_len), count);
        for (decoded[0 .. count * 2], samples[index * frame_len * 2 ..][0 .. count * 2]) |got, wanted| {
            const err: f64 = @floatFromInt(@as(i32, got) - wanted);
            squared += err * err;
        }
    }
    try std.testing.expect(@sqrt(squared / @as(f64, frames * 2)) < 120);
}

test "truncated files are rejected" {
    const gpa = std.testing.allocator;
    const samples: [100]i16 = @splat(1000);
    const encoded = try encodeForTest(gpa, &samples, 1, 22050);
    defer gpa.free(encoded);
    const info = try parse(encoded);
    var decoded: [frame_len]i16 = undefined;
    try std.testing.expectError(error.InvalidQoa, decodeFrame(encoded[0 .. encoded.len - 1], info, 0, &decoded));
    try std.testing.expectError(error.InvalidQoa, decodeFrame(encoded, info, 1, &decoded));
    try std.testing.expectError(error.InvalidQoa, parse(encoded[0..12]));
}
