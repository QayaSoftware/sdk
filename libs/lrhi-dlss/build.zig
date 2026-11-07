const std = @import("std");
const Sdk = @import("../../build/Sdk.zig");

const sdk_default = "dlss_sdk";
const sdk_version = "v310.9.1";

/// lrhi-dlss's part of the SDK's build: NVIDIA's SDK, when it is there, and
/// the step that fetches it.
pub fn build(lib: *Sdk.Library) void {
    const b = lib.b;
    const target = lib.target;
    const native_target = target.result.os.tag == b.graph.host.result.os.tag and target.result.cpu.arch == b.graph.host.result.cpu.arch and target.result.abi == b.graph.host.result.abi;
    const sdk = b.option([]const u8, "dlss_sdk", "Where NVIDIA's DLSS SDK is (default: dlss_sdk, which `zig build lrhi-dlss-sdk` fetches)") orelse Sdk.absolutePath(b, sdk_default);
    const found = Sdk.fileExists(b, b.pathResolve(&.{ sdk, "include", "nvsdk_ngx.h" }));
    const dlss = b.option(bool, "dlss", "Build NVIDIA DLSS upscaling and ray reconstruction in (default: true where the SDK is found)") orelse (found and native_target and supported(target) and !lib.sdk.thread_sanitizer);
    if (dlss and !found) std.debug.panic("no DLSS SDK at {s}; run `zig build lrhi-dlss-sdk` or pass -Ddlss_sdk", .{sdk});
    const features = b.addOptions();
    features.addOption(bool, "dlss", dlss);
    features.addOption([:0]const u8, "dlss_libraries", if (dlss) b.allocator.dupeSentinel(u8, b.pathResolve(&.{ sdk, libraries(target), "rel" }), 0) catch @panic("OOM") else "");
    features.addOption(bool, "dlss_logging", b.option(bool, "dlss_logging", "Let DLSS write its log (default: false)") orelse false);

    const fetch = b.addSystemCommand(&.{ "git", "clone", "--depth", "1", "--branch", sdk_version, "--filter=blob:none", "--sparse", "https://github.com/NVIDIA/DLSS", Sdk.absolutePath(b, sdk_default) });
    const trim = b.addSystemCommand(&.{ "git", "-C", Sdk.absolutePath(b, sdk_default), "sparse-checkout", "set", "include", libraries(target) });
    trim.step.dependOn(&fetch.step);
    lib.step("sdk", "Fetch NVIDIA's DLSS SDK into dlss_sdk, under NVIDIA's license; builds after it have DLSS").dependOn(&trim.step);

    const module = lib.module;
    lib.import(module, "lrhi");
    module.addOptions("build_features", features);
    if (dlss) addSdk(lib, sdk);
}

/// Whether the DLSS SDK has libraries for `target`.
fn supported(target: std.Build.ResolvedTarget) bool {
    return switch (target.result.os.tag) {
        .windows => target.result.cpu.arch == .x86_64,
        .linux => target.result.abi != .android and (target.result.cpu.arch == .x86_64 or target.result.cpu.arch == .aarch64),
        else => false,
    };
}

/// Where the DLSS SDK keeps its libraries for `target`.
fn libraries(target: std.Build.ResolvedTarget) []const u8 {
    return switch (target.result.os.tag) {
        .windows => "lib/Windows_x86_64",
        else => if (target.result.cpu.arch == .aarch64) "lib/Linux_aarch64" else "lib/Linux_x86_64",
    };
}

/// Builds src/limn_dlss.cpp against the DLSS SDK at `sdk` and links
/// NVIDIA's loader. That is built against the GNU C++ library, which `cc`
/// is asked for.
fn addSdk(lib: *Sdk.Library, sdk: []const u8) void {
    const b = lib.b;
    const target = lib.target;
    const module = lib.module;
    const vulkan_headers = b.lazyDependency("vulkan_headers", .{}) orelse return;
    const library = b.addLibrary(.{
        .name = "lrhi_dlss",
        .root_module = b.createModule(.{ .target = target, .optimize = if (lib.optimize == .debug) .fast else lib.optimize, .link_libcpp = true }),
    });
    library.root_module.addIncludePath(.{ .cwd_relative = b.pathResolve(&.{ sdk, "include" }) });
    library.root_module.addIncludePath(vulkan_headers.path("include"));
    library.root_module.addCSourceFile(.{ .file = lib.path("src/limn_dlss.cpp"), .flags = &.{ "-std=c++17", "-w" } });
    module.linkLibrary(library);
    const windows = target.result.os.tag == .windows;
    module.addObjectFile(.{ .cwd_relative = b.pathResolve(&.{ sdk, libraries(target), if (windows) "nvsdk_ngx_s.lib" else "libnvsdk_ngx.a" }) });
    if (!windows) {
        const gnu_cpp = std.mem.trim(u8, b.run(&.{ "cc", "-print-file-name=libstdc++.so.6" }), " \n");
        module.addObjectFile(.{ .cwd_relative = gnu_cpp });
        module.addRPath(.{ .cwd_relative = std.fs.path.dirname(gnu_cpp) orelse "." });
        module.linkSystemLibrary("dl", .{});
    }
}
