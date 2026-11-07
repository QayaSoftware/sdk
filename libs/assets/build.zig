const std = @import("std");
const Sdk = @import("../../build/Sdk.zig");

/// assets' part of the SDK's build: the C and C++ codecs it is built on,
/// and the texture and font parsers, which are built optimized even in
/// Debug.
pub fn build(lib: *Sdk.Library) void {
    const b = lib.b;
    const target = lib.target;
    const optimize = lib.optimize;
    const asset_optimize: std.lang.Optimize = if (optimize == .debug) .fast else optimize;
    const validate_input = b.option(bool, "validate_input", "Check asset files before trusting them, and in Debug keep safety checks in the texture and font parsers (default: true)") orelse true;
    const parser_optimize: std.lang.Optimize = if (optimize == .debug and validate_input) .safe else asset_optimize;
    const features = b.addOptions();
    features.addOption(bool, "validate_input", validate_input);
    const features_module = features.createModule();
    const zmesh = b.lazyDependency("zmesh", .{ .target = target, .optimize = asset_optimize }) orelse return;
    const zstbi = b.lazyDependency("zstbi", .{ .target = target, .optimize = asset_optimize }) orelse return;

    const assets = lib.module;
    assets.addImport("build_features", features_module);
    assets.addImport("zmesh", zmesh.module("root"));
    assets.linkLibrary(zmesh.artifact("zmesh"));
    assets.addImport("zstbi", zstbi.module("root"));
    const ufbx = b.lazyDependency("ufbx", .{}) orelse return;
    assets.addImport("ufbx", ufbxModule(lib, target, asset_optimize, ufbx));
    const simplifier = b.addLibrary(.{
        .name = "assets_simplifier",
        .root_module = b.createModule(.{ .target = target, .optimize = asset_optimize, .link_libcpp = true }),
    });
    simplifier.root_module.addCSourceFile(.{
        .file = lib.path("src/third_party/meshoptimizer/simplifier.cpp"),
        .flags = &.{
            "-fno-exceptions",                                                     "-fno-rtti",
            "-Dmeshopt=rnd_meshopt",                                               "-Dmeshopt_Allocator=rnd_meshopt_Allocator",
            "-Dmeshopt_simplify=rnd_meshopt_simplify",                             "-Dmeshopt_simplifyEdge=rnd_meshopt_simplifyEdge",
            "-Dmeshopt_simplifyWithAttributes=rnd_meshopt_simplifyWithAttributes", "-Dmeshopt_simplifySloppy=rnd_meshopt_simplifySloppy",
            "-Dmeshopt_simplifyPrune=rnd_meshopt_simplifyPrune",                   "-Dmeshopt_simplifyPoints=rnd_meshopt_simplifyPoints",
            "-Dmeshopt_simplifyScale=rnd_meshopt_simplifyScale",
        },
    });
    simplifier.root_module.addCSourceFiles(.{
        .root = zmesh.path("libs/meshoptimizer"),
        .files = &.{ "vertexcodec.cpp", "indexcodec.cpp", "vertexfilter.cpp" },
        .flags = &.{ "-fno-exceptions", "-fno-rtti" },
    });
    assets.linkLibrary(simplifier);
    const basis = b.addLibrary(.{
        .name = "assets_basis",
        .root_module = b.createModule(.{ .target = target, .optimize = asset_optimize, .link_libcpp = true }),
    });
    basis.root_module.addCSourceFiles(.{
        .root = lib.path("src/third_party/basisu"),
        .files = &.{ "transcoder/basisu_transcoder.cpp", "rnd_basis.cpp" },
        .flags = &.{ "-DBASISD_SUPPORT_KTX2=1", "-DBASISD_SUPPORT_KTX2_ZSTD=1", "-fno-strict-aliasing", "-w" },
    });
    assets.linkLibrary(basis);
    const texture_codec = b.createModule(.{
        .root_source_file = lib.path("src/texture.zig"),
        .target = target,
        .optimize = parser_optimize,
    });
    assets.addImport("texture_codec", texture_codec);
    const font_baker = b.createModule(.{
        .root_source_file = lib.path("src/font_baker.zig"),
        .target = target,
        .optimize = parser_optimize,
    });
    font_baker.addImport("build_features", features_module);
    assets.addImport("font_baker", font_baker);

    lib.document("texture_codec");
    lib.addTest(texture_codec);
    lib.addTest(font_baker);
}

/// ufbx, the FBX reader: its header as a Zig module, its source built with
/// asset code's optimization.
fn ufbxModule(
    lib: *Sdk.Library,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    source: *std.Build.Dependency,
) *std.Build.Module {
    const b = lib.b;
    const header = b.addTranslateC(.{
        .root_source_file = source.path("ufbx.h"),
        .target = target,
        .optimize = optimize,
    });
    const module = header.createModule();
    module.addCSourceFile(.{ .file = source.path("ufbx.c") });
    module.link_libc = true;
    return module;
}
