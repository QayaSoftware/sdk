const std = @import("std");
const Sdk = @import("../../build/Sdk.zig");

const sdk_default = "nrd_sdk";
/// The NRD release src/limn_nrd.cpp is written against.
const sdk_version = "v4.9.4";

/// lrhi-nrd's part of the SDK's build: NVIDIA's SDK, when it is built, and
/// the step that fetches and builds it.
pub fn build(lib: *Sdk.Library) void {
    const b = lib.b;
    const target = lib.target;
    const native_target = target.result.os.tag == b.graph.host.result.os.tag and target.result.cpu.arch == b.graph.host.result.cpu.arch and target.result.abi == b.graph.host.result.abi;
    const sdk = b.option([]const u8, "nrd_sdk", "Where NVIDIA's NRD SDK is, built (default: nrd_sdk, which `zig build lrhi-nrd-sdk` fetches and builds)") orelse Sdk.absolutePath(b, sdk_default);
    const found = Sdk.fileExists(b, b.pathResolve(&.{ sdk, "_Bin", "libNRD.a" }));
    const nrd = b.option(bool, "nrd", "Build NVIDIA's NRD denoiser in, for path tracing (default: true where the SDK is found)") orelse (found and native_target and !lib.sdk.thread_sanitizer);
    if (nrd and !found) std.debug.panic("no built NRD SDK at {s}; run `zig build lrhi-nrd-sdk` or pass -Dnrd_sdk", .{sdk});
    const features = b.addOptions();
    features.addOption(bool, "nrd", nrd);

    const fetch = b.addSystemCommand(&.{ "git", "clone", "--depth", "1", "--branch", sdk_version, "--recurse-submodules", "--shallow-submodules", "https://github.com/NVIDIA-RTX/NRD", Sdk.absolutePath(b, sdk_default) });
    const configure = b.addSystemCommand(&.{
        "cmake",                         "-S",                                          Sdk.absolutePath(b, sdk_default),
        "-B",                            Sdk.absolutePath(b, sdk_default ++ "/_Build"), "-DCMAKE_BUILD_TYPE=Release",
        "-DNRD_STATIC_LIBRARY=ON",       "-DNRD_EMBEDS_SPIRV_SHADERS=ON",               "-DNRD_EMBEDS_DXIL_SHADERS=OFF",
        "-DNRD_EMBEDS_DXBC_SHADERS=OFF", "-DNRD_NORMAL_ENCODING=4",                     "-DNRD_ROUGHNESS_ENCODING=1",
    });
    configure.addFileArg2(b.findProgramLazy(.{ .names = &.{"dxc"} }), .{ .prefix = "-DNRD_DXC_CUSTOM_PATH=" });
    const patch = b.addSystemCommand(&.{ "sed", "-i", "s/        --allResourcesBound$/        --allResourcesBound\n        -X -fspv-use-unknown-image-format/", Sdk.absolutePath(b, sdk_default ++ "/CMakeLists.txt") });
    patch.step.dependOn(&fetch.step);
    configure.step.dependOn(&patch.step);
    const build_sdk = b.addSystemCommand(&.{ "cmake", "--build", Sdk.absolutePath(b, sdk_default ++ "/_Build"), "-j", "8" });
    build_sdk.step.dependOn(&configure.step);
    lib.step("sdk", "Fetch NVIDIA's NRD SDK into nrd_sdk, under NVIDIA's license, and build it (needs cmake, a C++ compiler and dxc); builds after it have NRD").dependOn(&build_sdk.step);

    const module = lib.module;
    lib.import(module, "lrhi");
    module.addOptions("build_features", features);
    if (nrd) addSdk(lib, sdk);
}

/// Builds src/limn_nrd.cpp against the NRD SDK built at `sdk` and links its
/// library, which is built against the GNU C++ library.
fn addSdk(lib: *Sdk.Library, sdk: []const u8) void {
    const b = lib.b;
    const target = lib.target;
    const module = lib.module;
    const vulkan_headers = b.lazyDependency("vulkan_headers", .{}) orelse return;
    const library = b.addLibrary(.{
        .name = "lrhi_nrd",
        .root_module = b.createModule(.{ .target = target, .optimize = if (lib.optimize == .debug) .fast else lib.optimize, .link_libcpp = true }),
    });
    library.root_module.addIncludePath(.{ .cwd_relative = b.pathResolve(&.{ sdk, "Include" }) });
    library.root_module.addIncludePath(vulkan_headers.path("include"));
    library.root_module.addCSourceFile(.{ .file = lib.path("src/limn_nrd.cpp"), .flags = &.{ "-std=c++17", "-w", "-DNRD_STATIC_LIBRARY" } });
    module.linkLibrary(library);
    module.addObjectFile(.{ .cwd_relative = b.pathResolve(&.{ sdk, "_Bin", "libNRD.a" }) });
    if (target.result.os.tag != .windows) {
        const gnu_cpp = std.mem.trim(u8, b.run(&.{ "cc", "-print-file-name=libstdc++.so.6" }), " \n");
        module.addObjectFile(.{ .cwd_relative = gnu_cpp });
        module.addRPath(.{ .cwd_relative = std.fs.path.dirname(gnu_cpp) orelse "." });
    }
}
