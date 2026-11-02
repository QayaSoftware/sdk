//! Plays the WAV or QOA file given after `--`, or with none, a tone that
//! circles the listener for four seconds.
const std = @import("std");
const audio = @import("audio");

pub fn main(init: std.process.Init) !void {
    var engine = try audio.Engine.init(init.gpa, .{});
    defer engine.deinit();
    std.debug.print("{s} at {d} Hz\n", .{ engine.backend().?, engine.sampleRate() });

    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    defer args.deinit();
    _ = args.next();
    if (args.next()) |path| {
        const sound = try engine.loadFile(init.io, std.Io.Dir.cwd(), path, .{ .stream = true });
        const voice = try engine.play(sound, .{});
        std.debug.print("{s}: {d:.1} s\n", .{ path, engine.duration(sound).? });
        while (engine.isPlaying(voice)) {
            try init.io.sleep(.fromMilliseconds(10), .awake);
            engine.update();
        }
        return;
    }

    const rate = 48000;
    var samples: [rate]i16 = undefined;
    for (&samples, 0..) |*sample, index| {
        const t = @as(f32, @floatFromInt(index)) / rate;
        sample.* = @intFromFloat(@sin(t * 440 * std.math.tau) * 0.3 * 32767);
    }
    const bytes = try audio.wav.encode16(init.gpa, &samples, 1, rate);
    defer init.gpa.free(bytes);
    const tone = try engine.load(bytes, .{});
    const voice = try engine.play(tone, .{ .looping = true, .fade_in = 0.2, .spatial = .{ .position = .{ 0, 0, -2 } } });

    const steps = 400;
    for (0..steps) |step| {
        const angle = @as(f32, @floatFromInt(step)) / steps * std.math.tau;
        try engine.setPosition(voice, .{ @sin(angle) * 2, 0, -@cos(angle) * 2 });
        try engine.setPitch(voice, 1 + 0.25 * @sin(angle * 2));
        try init.io.sleep(.fromMilliseconds(10), .awake);
        engine.update();
    }
    try engine.stop(voice, 0.3);
    while (engine.isPlaying(voice)) {
        try init.io.sleep(.fromMilliseconds(10), .awake);
        engine.update();
    }
}
