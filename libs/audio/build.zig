const std = @import("std");
const Sdk = @import("../../build/Sdk.zig");

/// miniaudio built for playback only: its decoders, engine, node graph and
/// resource manager are left out, as are the backends no target here needs.
const miniaudio_flags = [_][]const u8{
    "-DMA_NO_DECODING",
    "-DMA_NO_ENCODING",
    "-DMA_NO_GENERATION",
    "-DMA_NO_RESOURCE_MANAGER",
    "-DMA_NO_NODE_GRAPH",
    "-DMA_NO_ENGINE",
    "-DMA_ENABLE_ONLY_SPECIFIC_BACKENDS",
    "-DMA_ENABLE_WASAPI",
    "-DMA_ENABLE_PULSEAUDIO",
    "-DMA_ENABLE_ALSA",
    "-DMA_ENABLE_AAUDIO",
    "-DMA_ENABLE_OPENSL",
    "-DMA_ENABLE_NULL",
    "-fno-sanitize=undefined",
};

/// audio's part of the SDK's build: the device layer over miniaudio, and
/// its examples. Core Audio needs the macOS SDK's headers, so a build for
/// macOS from another host has only the null backend.
pub fn build(lib: *Sdk.Library) void {
    const b = lib.b;
    lib.import(lib.module, "handles");
    _ = lib.addExample("play", "Run examples/play.zig: a tone circling the listener, or a WAV or QOA file given after --");

    const miniaudio = b.lazyDependency("miniaudio", .{}) orelse return;
    const os = lib.target.result.os.tag;
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &miniaudio_flags) catch @panic("OOM");
    if (os == .macos and b.graph.host.result.os.tag == .macos) {
        flags.append(b.allocator, "-DMA_ENABLE_COREAUDIO") catch @panic("OOM");
    }
    const device = b.addLibrary(.{
        .name = "audio_device",
        .root_module = b.createModule(.{ .target = lib.target, .optimize = .fast, .link_libc = true }),
    });
    device.root_module.addIncludePath(miniaudio.path("."));
    device.root_module.addCSourceFile(.{ .file = lib.path("src/device.c"), .flags = flags.items });
    lib.module.linkLibrary(device);
}
