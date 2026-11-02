//! RIFF WAVE files of integer PCM (8, 16, 24 or 32 bits) or IEEE float (32
//! or 64 bits), plain or `WAVE_FORMAT_EXTENSIBLE`.
const std = @import("std");

const Encoding = enum { pcm, float };

/// A file's format and its sample bytes, which point into the file.
pub const Info = struct {
    channels: u16,
    sample_rate: u32,
    /// Samples per channel.
    frames: u32,
    encoding: Encoding,
    bits: u16,
    data: []const u8,

    /// Converts sample `index` of the interleaved data to [-1, 1].
    pub fn sample(self: Info, index: usize) f32 {
        const bytes = self.data[index * (self.bits / 8) ..];
        return switch (self.encoding) {
            .float => switch (self.bits) {
                32 => @bitCast(std.mem.readInt(u32, bytes[0..4], .little)),
                else => @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, bytes[0..8], .little)))),
            },
            .pcm => switch (self.bits) {
                8 => (@as(f32, @floatFromInt(bytes[0])) - 128) / 128,
                16 => @as(f32, @floatFromInt(std.mem.readInt(i16, bytes[0..2], .little))) / 32768,
                24 => @as(f32, @floatFromInt(std.mem.readInt(i24, bytes[0..3], .little))) / 8388608,
                else => @as(f32, @floatFromInt(std.mem.readInt(i32, bytes[0..4], .little))) / 2147483648,
            },
        };
    }
};

/// Whether `bytes` start like a WAVE file.
pub fn matches(bytes: []const u8) bool {
    return bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WAVE");
}

/// Finds the format and data chunks. Fails with `error.InvalidWav`, or
/// `error.UnsupportedWav` for compressed encodings.
pub fn parse(bytes: []const u8) !Info {
    if (!matches(bytes)) return error.InvalidWav;
    var format: ?struct { encoding: Encoding, channels: u16, sample_rate: u32, bits: u16 } = null;
    var at: usize = 12;
    while (at + 8 <= bytes.len) {
        const id = bytes[at..][0..4];
        const size = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        const body = bytes[at + 8 .. @min(bytes.len, at + 8 + @as(usize, size))];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len < 16) return error.InvalidWav;
            var tag = std.mem.readInt(u16, body[0..2], .little);
            if (tag == 0xfffe) {
                if (body.len < 26) return error.InvalidWav;
                tag = std.mem.readInt(u16, body[24..26], .little);
            }
            const bits = std.mem.readInt(u16, body[14..16], .little);
            const encoding: Encoding = switch (tag) {
                1 => if (bits == 8 or bits == 16 or bits == 24 or bits == 32) .pcm else return error.UnsupportedWav,
                3 => if (bits == 32 or bits == 64) .float else return error.UnsupportedWav,
                else => return error.UnsupportedWav,
            };
            format = .{
                .encoding = encoding,
                .channels = std.mem.readInt(u16, body[2..4], .little),
                .sample_rate = std.mem.readInt(u32, body[4..8], .little),
                .bits = bits,
            };
        } else if (std.mem.eql(u8, id, "data")) {
            const found = format orelse return error.InvalidWav;
            if (found.channels == 0 or found.sample_rate == 0) return error.InvalidWav;
            const frame_bytes = @as(usize, found.channels) * (found.bits / 8);
            return .{
                .channels = found.channels,
                .sample_rate = found.sample_rate,
                .frames = @intCast(body.len / frame_bytes),
                .encoding = found.encoding,
                .bits = found.bits,
                .data = body[0 .. body.len - body.len % frame_bytes],
            };
        }
        at += 8 + @as(usize, size) + size % 2;
    }
    return error.InvalidWav;
}

/// A WAVE file of 16-bit PCM `samples`, interleaved; for tests and examples.
pub fn encode16(gpa: std.mem.Allocator, samples: []const i16, channels: u16, sample_rate: u32) ![]u8 {
    const data_size: u32 = @intCast(samples.len * 2);
    const bytes = try gpa.alloc(u8, 44 + data_size);
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 36 + data_size, .little);
    @memcpy(bytes[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], channels, .little);
    std.mem.writeInt(u32, bytes[24..28], sample_rate, .little);
    std.mem.writeInt(u32, bytes[28..32], sample_rate * channels * 2, .little);
    std.mem.writeInt(u16, bytes[32..34], channels * 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], data_size, .little);
    for (samples, 0..) |value, index| std.mem.writeInt(i16, bytes[44 + index * 2 ..][0..2], value, .little);
    return bytes;
}

test "16-bit PCM reads back" {
    const gpa = std.testing.allocator;
    const bytes = try encode16(gpa, &.{ 0, 16384, -32768, 32767 }, 2, 48000);
    defer gpa.free(bytes);
    const info = try parse(bytes);
    try std.testing.expectEqual(@as(u16, 2), info.channels);
    try std.testing.expectEqual(@as(u32, 48000), info.sample_rate);
    try std.testing.expectEqual(@as(u32, 2), info.frames);
    try std.testing.expectEqual(@as(f32, 0.5), info.sample(1));
    try std.testing.expectEqual(@as(f32, -1), info.sample(2));
}

test "unknown chunks are skipped and compressed data refused" {
    const gpa = std.testing.allocator;
    const plain = try encode16(gpa, &.{ 1, 2, 3 }, 1, 8000);
    defer gpa.free(plain);
    var padded: std.ArrayList(u8) = .empty;
    defer padded.deinit(gpa);
    try padded.appendSlice(gpa, plain[0..12]);
    try padded.appendSlice(gpa, "LIST\x03\x00\x00\x00abc\x00");
    try padded.appendSlice(gpa, plain[12..]);
    try std.testing.expectEqual(@as(u32, 3), (try parse(padded.items)).frames);

    std.mem.writeInt(u16, padded.items[12 + 12 + 8 ..][0..2], 2, .little);
    try std.testing.expectError(error.UnsupportedWav, parse(padded.items));
    try std.testing.expectError(error.InvalidWav, parse("RIFF\x00\x00\x00\x00WAVE"));
}
