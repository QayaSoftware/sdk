const std = @import("std");
const Sdk = @import("../../build/Sdk.zig");
const lrhi_build = @import("../lrhi/build.zig");
const Tool = lrhi_build.Tool;

/// lrhi-fsr's part of the SDK's build: AMD's FidelityFX SDK, which is kept
/// in src/third_party/ffx_sdk, and the shader permutations it asks for.
pub fn build(lib: *Sdk.Library) void {
    const b = lib.b;
    const fidelityfx = b.option(bool, "fidelityfx", "Build AMD's FidelityFX SDK in, for FSR 2 and FSR 3 upscaling (default: true, false with -Dtsan)") orelse !lib.sdk.thread_sanitizer;
    const features = b.addOptions();
    features.addOption(bool, "fidelityfx", fidelityfx);
    const module = lib.module;
    lib.import(module, "lrhi");
    module.addOptions("build_features", features);
    if (!fidelityfx) return;
    const tools = lrhi_build.ShaderTools.of(b) orelse return;
    const glslang: Tool = if (lib.sdk.system_tools) .{ .system = "glslangValidator" } else glslangCompiler(b) orelse return;
    addFidelityFx(lib, tools.depfile, glslang);
}

/// glslang's command-line compiler built from source for the build machine,
/// without the HLSL front end or SPIR-V optimizer; null while it is being
/// fetched.
fn glslangCompiler(b: *std.Build) ?Tool {
    const source = b.lazyDependency("glslang", .{}) orelse return null;
    const module = b.createModule(.{ .target = b.graph.host, .optimize = .fast, .link_libcpp = true });
    const generated = b.addWriteFiles();
    _ = generated.add("glslang/build_info.h",
        \\#pragma once
        \\#define GLSLANG_VERSION_MAJOR 16
        \\#define GLSLANG_VERSION_MINOR 4
        \\#define GLSLANG_VERSION_PATCH 0
        \\#define GLSLANG_VERSION_FLAVOR ""
        \\#define GLSLANG_VERSION_GREATER_THAN(major, minor, patch) ((GLSLANG_VERSION_MAJOR) > (major) || ((major) == GLSLANG_VERSION_MAJOR && ((GLSLANG_VERSION_MINOR) > (minor) || ((minor) == GLSLANG_VERSION_MINOR && (GLSLANG_VERSION_PATCH) > (patch)))))
        \\#define GLSLANG_VERSION_GREATER_OR_EQUAL_TO(major, minor, patch) ((GLSLANG_VERSION_MAJOR) > (major) || ((major) == GLSLANG_VERSION_MAJOR && ((GLSLANG_VERSION_MINOR) > (minor) || ((minor) == GLSLANG_VERSION_MINOR && (GLSLANG_VERSION_PATCH >= (patch))))))
        \\#define GLSLANG_VERSION_LESS_THAN(major, minor, patch) ((GLSLANG_VERSION_MAJOR) < (major) || ((major) == GLSLANG_VERSION_MAJOR && ((GLSLANG_VERSION_MINOR) < (minor) || ((minor) == GLSLANG_VERSION_MINOR && (GLSLANG_VERSION_PATCH) < (patch)))))
        \\#define GLSLANG_VERSION_LESS_OR_EQUAL_TO(major, minor, patch) ((GLSLANG_VERSION_MAJOR) < (major) || ((major) == GLSLANG_VERSION_MAJOR && ((GLSLANG_VERSION_MINOR) < (minor) || ((minor) == GLSLANG_VERSION_MINOR && (GLSLANG_VERSION_PATCH <= (patch))))))
        \\
    );
    _ = generated.add("glslang/glsl_intrinsic_header.h",
        \\#pragma once
        \\#include <string>
        \\std::string getIntrinsic(const char* const*, int) { return ""; }
        \\
    );
    module.addIncludePath(generated.getDirectory());
    module.addIncludePath(source.path(""));
    module.addIncludePath(source.path("External"));
    const windows = b.graph.host.result.os.tag == .windows;
    module.addCSourceFiles(.{
        .root = source.path(""),
        .files = &(glslang_sources ++ [_][]const u8{if (windows) "glslang/OSDependent/Windows/ossource.cpp" else "glslang/OSDependent/Unix/ossource.cpp"}),
        .flags = &.{ "-std=c++17", "-w", "-DENABLE_SPIRV", "-DENABLE_OPT=0", "-fno-exceptions", "-fno-rtti" },
    });
    const exe = b.addExecutable(.{ .name = "glslang", .root_module = module });
    return .{ .path = exe.getEmittedBin() };
}

const glslang_sources = [_][]const u8{
    "glslang/GenericCodeGen/CodeGen.cpp",
    "glslang/GenericCodeGen/Link.cpp",
    "glslang/MachineIndependent/glslang_tab.cpp",
    "glslang/MachineIndependent/attribute.cpp",
    "glslang/MachineIndependent/Constant.cpp",
    "glslang/MachineIndependent/iomapper.cpp",
    "glslang/MachineIndependent/InfoSink.cpp",
    "glslang/MachineIndependent/Initialize.cpp",
    "glslang/MachineIndependent/IntermTraverse.cpp",
    "glslang/MachineIndependent/Intermediate.cpp",
    "glslang/MachineIndependent/ParseContextBase.cpp",
    "glslang/MachineIndependent/ParseHelper.cpp",
    "glslang/MachineIndependent/PoolAlloc.cpp",
    "glslang/MachineIndependent/RemoveTree.cpp",
    "glslang/MachineIndependent/Scan.cpp",
    "glslang/MachineIndependent/ShaderLang.cpp",
    "glslang/MachineIndependent/SpirvIntrinsics.cpp",
    "glslang/MachineIndependent/SymbolTable.cpp",
    "glslang/MachineIndependent/Versions.cpp",
    "glslang/MachineIndependent/intermOut.cpp",
    "glslang/MachineIndependent/limits.cpp",
    "glslang/MachineIndependent/linkValidate.cpp",
    "glslang/MachineIndependent/parseConst.cpp",
    "glslang/MachineIndependent/reflection.cpp",
    "glslang/MachineIndependent/preprocessor/Pp.cpp",
    "glslang/MachineIndependent/preprocessor/PpAtom.cpp",
    "glslang/MachineIndependent/preprocessor/PpContext.cpp",
    "glslang/MachineIndependent/preprocessor/PpScanner.cpp",
    "glslang/MachineIndependent/preprocessor/PpTokens.cpp",
    "glslang/MachineIndependent/propagateNoContraction.cpp",
    "glslang/ResourceLimits/ResourceLimits.cpp",
    "SPIRV/GlslangToSpv.cpp",
    "SPIRV/InReadableOrder.cpp",
    "SPIRV/Logger.cpp",
    "SPIRV/SpvBuilder.cpp",
    "SPIRV/SpvPostProcess.cpp",
    "SPIRV/doc.cpp",
    "SPIRV/SpvTools.cpp",
    "SPIRV/disassemble.cpp",
    "StandAlone/StandAlone.cpp",
};

const ffx_root = "src/third_party/ffx_sdk";
/// A switch of a FidelityFX shader. The flags src/limn_ffx.cpp
/// makes its contexts with decide which values are asked for, and only those
/// are compiled.
const FfxOption = struct {
    name: []const u8,
    /// The only value asked for, or null for both.
    value: ?u1 = null,
    /// The one pass it is ever set in.
    pass: ?[]const u8 = null,

    fn compiled(option: FfxOption, pass: []const u8, value: u1) bool {
        if (option.value) |only| return value == only;
        if (option.pass) |only| return value == 0 or std.mem.eql(u8, pass, only);
        return true;
    }
};
/// An effect of the FidelityFX SDK: each pass is a compute shader compiled
/// once for every combination of `options` that is asked for.
const FfxEffect = struct {
    /// The directory of its shaders.
    name: []const u8,
    /// What its options' names start with.
    prefix: []const u8,
    /// The first is the lowest bit of a combination's number.
    options: []const FfxOption,
    fixed: []const []const u8 = &.{},
    passes: []const []const u8,
};
fn ffxUpscalerOptions(comptime accumulate: []const u8) [6]FfxOption {
    return .{
        .{ .name = "OPTION_REPROJECT_USE_LANCZOS_TYPE" },
        .{ .name = "OPTION_HDR_COLOR_INPUT", .value = 1 },
        .{ .name = "OPTION_LOW_RESOLUTION_MOTION_VECTORS", .value = 1 },
        .{ .name = "OPTION_JITTERED_MOTION_VECTORS", .value = 0 },
        .{ .name = "OPTION_INVERTED_DEPTH", .value = 1 },
        .{ .name = "OPTION_APPLY_SHARPENING", .pass = accumulate },
    };
}
const ffx_sampler_options = [_][]const u8{
    "OPTION_UPSAMPLE_SAMPLERS_USE_DATA_HALF=0",
    "OPTION_ACCUMULATE_SAMPLERS_USE_DATA_HALF=0",
    "OPTION_REPROJECT_SAMPLERS_USE_DATA_HALF=1",
    "OPTION_POSTPROCESSLOCKSTATUS_SAMPLERS_USE_DATA_HALF=0",
    "OPTION_UPSAMPLE_USE_LANCZOS_TYPE=2",
};
const ffx_effects = [_]FfxEffect{
    .{ .name = "fsr2", .prefix = "FFX_FSR2", .options = &ffxUpscalerOptions("ffx_fsr2_accumulate_pass"), .fixed = &ffx_sampler_options, .passes = &.{
        "ffx_fsr2_accumulate_pass",                 "ffx_fsr2_autogen_reactive_pass", "ffx_fsr2_compute_luminance_pyramid_pass",
        "ffx_fsr2_depth_clip_pass",                 "ffx_fsr2_lock_pass",             "ffx_fsr2_rcas_pass",
        "ffx_fsr2_reconstruct_previous_depth_pass", "ffx_fsr2_tcr_autogen_pass",
    } },
    .{ .name = "fsr3upscaler", .prefix = "FFX_FSR3UPSCALER", .options = &ffxUpscalerOptions("ffx_fsr3upscaler_accumulate_pass"), .fixed = &ffx_sampler_options, .passes = &.{
        "ffx_fsr3upscaler_accumulate_pass",             "ffx_fsr3upscaler_autogen_reactive_pass", "ffx_fsr3upscaler_debug_view_pass",
        "ffx_fsr3upscaler_luma_instability_pass",       "ffx_fsr3upscaler_luma_pyramid_pass",     "ffx_fsr3upscaler_prepare_inputs_pass",
        "ffx_fsr3upscaler_prepare_reactivity_pass",     "ffx_fsr3upscaler_rcas_pass",             "ffx_fsr3upscaler_shading_change_pass",
        "ffx_fsr3upscaler_shading_change_pyramid_pass",
    } },
    .{
        .name = "frameinterpolation",
        .prefix = "FFX_FRAMEINTERPOLATION",
        .options = &.{
            .{ .name = "OPTION_LOW_RES_MOTION_VECTORS", .value = 1 },
            .{ .name = "OPTION_JITTER_MOTION_VECTORS", .value = 0 },
            .{ .name = "OPTION_INVERTED_DEPTH", .value = 1 },
        },
        .fixed = &ffx_sampler_options,
        .passes = &.{
            "ffx_frameinterpolation_compute_game_vector_field_inpainting_pyramid_pass",
            "ffx_frameinterpolation_compute_inpainting_pyramid_pass",
            "ffx_frameinterpolation_debug_view_pass",
            "ffx_frameinterpolation_disocclusion_mask_pass",
            "ffx_frameinterpolation_game_motion_vector_field_pass",
            "ffx_frameinterpolation_inpainting_pass",
            "ffx_frameinterpolation_optical_flow_vector_field_pass",
            "ffx_frameinterpolation_pass",
            "ffx_frameinterpolation_reconstruct_and_dilate_pass",
            "ffx_frameinterpolation_reconstruct_previous_depth_pass",
            "ffx_frameinterpolation_setup_pass",
        },
    },
    .{ .name = "opticalflow", .prefix = "FFX_OPTICALFLOW", .options = &.{.{ .name = "OPTION_HDR_COLOR_INPUT", .value = 0 }}, .passes = &.{
        "ffx_opticalflow_compute_luminance_pyramid_pass",
        "ffx_opticalflow_compute_optical_flow_advanced_pass_v5",
        "ffx_opticalflow_compute_scd_divergence_pass",
        "ffx_opticalflow_filter_optical_flow_pass_v5",
        "ffx_opticalflow_generate_scd_histogram_pass",
        "ffx_opticalflow_prepare_luma_pass",
        "ffx_opticalflow_scale_optical_flow_advanced_pass_v5",
    } },
};

/// Builds the FidelityFX SDK and the wrapper round it, and links lrhi-fsr
/// with them. The shader permutations that are asked for are
/// compiled with glslang and packed into the SDK's headers by
/// src/ffx_permutations.zig. SPD takes its barrier-only path: its wave path
/// writes shared memory that other quads may still be reading.
fn addFidelityFx(lib: *Sdk.Library, depfile: std.Build.LazyPath, glslang: Tool) void {
    const b = lib.b;
    const vulkan_headers = b.lazyDependency("vulkan_headers", .{}) orelse return;
    const volk = b.lazyDependency("volk", .{}) orelse return;
    const library = b.addLibrary(.{
        .name = "lrhi_fidelityfx",
        .root_module = b.createModule(.{ .target = lib.target, .optimize = if (lib.optimize == .debug) .fast else lib.optimize, .link_libcpp = true }),
    });
    const generator = b.addExecutable(.{
        .name = "ffx_permutations",
        .root_module = b.createModule(.{
            .root_source_file = lib.path("src/ffx_permutations.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const gpu = lib.path(ffx_root ++ "/include/FidelityFX/gpu");
    for (ffx_effects) |effect| {
        const option_names = b.allocator.alloc([]const u8, effect.options.len) catch @panic("OOM");
        for (effect.options, option_names) |option, *name| name.* = b.fmt("{s}_{s}", .{ effect.prefix, option.name });
        for (effect.passes) |pass| for ([_]bool{ false, true }) |half| {
            const name = if (half) b.fmt("{s}_16bit", .{pass}) else pass;
            const generate = b.addRunArtifact(generator);
            const headers = generate.addOutputDirectoryArg2(name, .{});
            generate.addArg(name);
            generate.addArg(std.mem.join(b.allocator, ",", option_names) catch @panic("OOM"));
            generate.addArg(if (half) "plain" else "with-16bit");
            for (0..@as(usize, 1) << @intCast(effect.options.len)) |combination| {
                const asked = for (effect.options, 0..) |option, bit| {
                    if (!option.compiled(pass, @truncate(combination >> @intCast(bit)))) break false;
                } else true;
                if (!asked) {
                    generate.addArg("-");
                    continue;
                }
                const compile = glslang.command(b, depfile, b.fmt("{s}_{d}", .{ name, combination }));
                compile.addArgs(&.{ "-V", "-S", "comp", "--target-env", "vulkan1.2", "-g", "-DFFX_GLSL=1", "-DFFX_GPU=1", if (half) "-DFFX_HALF=1" else "-DFFX_HALF=0", "-DFFX_SPD_NO_WAVE_OPERATIONS" });
                for (effect.fixed) |fixed| compile.addArg(b.fmt("-D{s}_{s}", .{ effect.prefix, fixed }));
                for (option_names, 0..) |option_name, bit| compile.addArg(b.fmt("-D{s}={d}", .{ option_name, (combination >> @intCast(bit)) & 1 }));
                compile.addDirectoryArg2(gpu, .{ .prefix = "-I" });
                compile.addDirectoryArg2(gpu.path(b, effect.name), .{ .prefix = "-I" });
                compile.addArg("--depfile");
                _ = compile.addDepFileOutputArg2(b.fmt("{s}_{d}.d", .{ name, combination }), .{});
                compile.addFileArg2(lib.path(b.fmt("{s}/src/backends/vk/shaders/{s}/{s}.glsl", .{ ffx_root, effect.name, pass })), .{});
                compile.addArg("-o");
                generate.addFileArg2(compile.addOutputFileArg2(b.fmt("{s}_{d}.spv", .{ name, combination }), .{}), .{});
            }
            library.root_module.addIncludePath(headers);
        };
    }
    for ([_][]const u8{ "include", "src", "src/shared", "src/components", "src/backends/shared" }) |directory| {
        library.root_module.addIncludePath(lib.path(b.fmt("{s}/{s}", .{ ffx_root, directory })));
    }
    library.root_module.addIncludePath(vulkan_headers.path("include"));
    library.root_module.addIncludePath(volk.path(""));
    const flags = [_][]const u8{
        "-std=c++17",                                "-w",                                           "-fno-strict-aliasing",
        "-include",                                  lib.pathFromRoot(ffx_root ++ "/limn_compat.h"), "-DFFX_FSR2",
        "-DFFX_FI",                                  "-DFFX_OF",                                     "-DFFX_FSR3UPSCALER",
        "-DFFX_SDK_DEFAULT_CONTEXT_SIZE=(1024*256)", "-fmax-type-align=4",
    };
    library.root_module.addCSourceFiles(.{
        .root = lib.path(ffx_root),
        .files = &.{
            "src/backends/vk/ffx_vk.cpp",
            "src/components/fsr2/ffx_fsr2.cpp",
            "src/components/fsr3upscaler/ffx_fsr3upscaler.cpp",
            "src/components/frameinterpolation/ffx_frameinterpolation.cpp",
            "src/components/opticalflow/ffx_opticalflow.cpp",
            "src/shared/ffx_assert.cpp",
            "src/shared/ffx_message.cpp",
            "src/shared/ffx_object_management.cpp",
            "src/shared/ffx_breadcrumbs_list.cpp",
            "src/backends/shared/ffx_shader_blobs.cpp",
            "src/backends/shared/blob_accessors/ffx_fsr2_shaderblobs.cpp",
            "src/backends/shared/blob_accessors/ffx_fsr3upscaler_shaderblobs.cpp",
            "src/backends/shared/blob_accessors/ffx_frameinterpolation_shaderblobs.cpp",
            "src/backends/shared/blob_accessors/ffx_opticalflow_shaderblobs.cpp",
        },
        .flags = &flags,
    });
    library.root_module.addCSourceFile(.{ .file = lib.path("src/limn_ffx.cpp"), .flags = &flags });
    lib.module.linkLibrary(library);
}
