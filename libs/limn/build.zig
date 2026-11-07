const std = @import("std");
const Sdk = @import("../../build/Sdk.zig");
const lrhi_build = @import("../lrhi/build.zig");
const shader_gen = @import("src/render/core/shader_gen.zig");

const manifest = @import("src/render/shaders/manifest.zig");
/// A Slang shader entry point to compile, for `addShaders`.
pub const Shader = manifest.Shader;

const shader_dir = "src/render/shaders";

/// limn's part of the SDK's build: what its module is built with, the tools
/// it builds and gives applications, and its own steps.
pub fn build(lib: *Sdk.Library) void {
    const b = lib.b;
    const target = lib.target;
    const optimize = lib.optimize;
    const thread_sanitizer = lib.sdk.thread_sanitizer;
    const tools = lrhi_build.ShaderTools.of(b) orelse return;

    const shaders_step = lib.step("shaders", "Compile all shaders to SPIR-V");
    lib.addNamedLazyPath("shader_include", lib.path(shader_dir));

    const renderer = lib.module;
    lib.import(renderer, "handles");
    lib.import(renderer, "lrhi");
    lib.import(renderer, "lrhi-dlss");
    lib.import(renderer, "lrhi-fsr");
    lib.import(renderer, "lrhi-nrd");
    lib.import(renderer, "assets");
    lib.import(renderer, "lrhi-assets");
    const generated_shaders = b.addWriteFiles();
    _ = generated_shaders.add("frame_constants.slang", shader_gen.frame_slang);
    for (shader_gen.push_files) |file| _ = generated_shaders.add(file.name, file.text);
    const generated_dir = generated_shaders.getDirectory();
    const spirv_readonly = b.addExecutable(.{
        .name = "spirv_readonly",
        .root_module = b.createModule(.{
            .root_source_file = lib.path("src/render/core/spirv_readonly.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const shader_tools: ShaderTools = .{
        .lrhi = tools,
        .spirv_readonly = spirv_readonly.getEmittedBin(),
        .include = lib.path(shader_dir),
        .generated = generated_dir,
    };
    compileShaders(b, renderer, lib.root, manifest.renderer, shader_tools, shaders_step);
    lib.addNamedLazyPath("shader_generated", generated_dir);
    lib.addNamedLazyPath("spirv_readonly", shader_tools.spirv_readonly);
    const shader_reload = b.option(bool, "shader_reload", "Keep the shader source paths in the library for `shaders.reload` (default: Debug only)") orelse (optimize == .debug);
    const shader_options = b.addOptions();
    var shader_names: [manifest.renderer.len][]const u8 = undefined;
    var shader_sources: [manifest.renderer.len][]const u8 = undefined;
    var shader_defines: [manifest.renderer.len][]const u8 = undefined;
    var shader_entries: [manifest.renderer.len][]const u8 = undefined;
    var shader_stages: [manifest.renderer.len][]const u8 = undefined;
    var shader_read_only: [manifest.renderer.len]bool = undefined;
    for (manifest.renderer, 0..) |shader, index| {
        shader_names[index] = shader.name;
        shader_sources[index] = if (shader_reload) lib.pathFromRoot(shader.src) else "";
        shader_defines[index] = "";
        shader_entries[index] = shader.entry;
        shader_stages[index] = shader.stage;
        shader_read_only[index] = !shader.writable_reads;
        for (shader.defines) |define| shader_defines[index] = b.fmt("{s} -D{s}", .{ shader_defines[index], define });
    }
    shader_options.addOption([]const []const u8, "names", &shader_names);
    shader_options.addOption([]const []const u8, "sources", &shader_sources);
    shader_options.addOption([]const []const u8, "defines", &shader_defines);
    shader_options.addOption([]const []const u8, "entries", &shader_entries);
    shader_options.addOption([]const []const u8, "stages", &shader_stages);
    shader_options.addOption([]const bool, "read_only", &shader_read_only);
    shader_options.addOption([]const []const u8, "slang_arguments", lrhi_build.slangArguments(tools.backend));
    shader_options.addOption([]const u8, "include_dir", if (shader_reload) lib.pathFromRoot(shader_dir) else "");
    if (shader_reload) shader_options.addOptionPathUntracked("generated_dir", generated_dir) else shader_options.addOption([]const u8, "generated_dir", "");
    shader_options.addOption(bool, "reload", shader_reload);
    switch (tools.slangc) {
        .path => |path| shader_options.addOptionPath("slangc", path),
        .system => |name| shader_options.addOption([]const u8, "slangc", name),
    }
    renderer.addOptions("shader_sources", shader_options);

    b.installArtifact(lib.artifact);

    const apk_packer = b.addExecutable(.{
        .name = "apk",
        .root_module = b.createModule(.{ .root_source_file = lib.path("src/apk.zig"), .target = b.graph.host, .optimize = .safe }),
    });
    lib.addTest(apk_packer.root_module);
    lib.addNamedLazyPath("apk", apk_packer.getEmittedBin());

    const format_check = b.addSystemCommand(&.{
        b.graph.zig_exe, "fmt", "--check", lib.pathFromRoot("build.zig"), lib.pathFromRoot("src"),
    });
    const verify_step = lib.step("verify", "Check formatting, and run the tests, `limn-checks` and `lrhi-checks`");
    verify_step.dependOn(&format_check.step);
    verify_step.dependOn(lib.sdk.test_step);
    const checks_module = b.createModule(.{
        .root_source_file = lib.path("src/checks.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = thread_sanitizer,
    });
    checks_module.addImport("limn", renderer);
    const checks = b.addExecutable(.{ .name = "checks", .root_module = checks_module, .use_llvm = true });
    checks.rdynamic = thread_sanitizer;
    lib.addCheck(checks);
    const run_checks = b.addRunArtifact(checks);
    run_checks.has_side_effects = true;
    run_checks.addPassthruArgs();
    if (thread_sanitizer) run_checks.setEnvironmentVariable("TSAN_OPTIONS", b.fmt("suppressions={s}", .{lib.pathFromRoot("src/tsan.supp")}));
    lib.step("checks", "Check picking, shader reloading and running out of memory, without a window").dependOn(&run_checks.step);
    verify_step.dependOn(&run_checks.step);
    if (b.top_level_steps.get("lrhi-checks")) |lrhi_checks| verify_step.dependOn(&lrhi_checks.step);
    const costs_module = b.createModule(.{
        .root_source_file = lib.path("src/costs.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = thread_sanitizer,
    });
    costs_module.addImport("limn", renderer);
    const costs = b.addExecutable(.{ .name = "costs", .root_module = costs_module, .use_llvm = true });
    costs.rdynamic = thread_sanitizer;
    lib.addCheck(costs);
    const run_costs = b.addRunArtifact(costs);
    run_costs.has_side_effects = true;
    if (thread_sanitizer) run_costs.setEnvironmentVariable("TSAN_OPTIONS", b.fmt("suppressions={s}", .{lib.pathFromRoot("src/tsan.supp")}));
    run_costs.addPassthruArgs();
    lib.step("costs", "Print what frames record as 2D and 3D scenes grow, without a window").dependOn(&run_costs.step);
}

/// What compiling one of limn's shaders takes: lrhi's tools, the program
/// marking SPIR-V reads read-only, and the directories it includes from.
const ShaderTools = struct {
    lrhi: lrhi_build.ShaderTools,
    spirv_readonly: std.Build.LazyPath,
    include: std.Build.LazyPath,
    generated: std.Build.LazyPath,
};

/// Compiles an application's own Slang shaders the way limn compiles its
/// own, and gives `module` each one's code as an anonymous import named
/// after it, for `@embedFile`. `qaya` is the application's dependency on
/// the SDK; `Shader.src` is relative to the application's build root,
/// and the shaders can include limn's. Does nothing while limn's own
/// dependencies are being fetched.
pub fn addShaders(b: *std.Build, qaya: *std.Build.Dependency, module: *std.Build.Module, shaders: []const Shader) void {
    const paths = qaya.builder.named_lazy_paths;
    const tools: ShaderTools = .{
        .lrhi = lrhi_build.ShaderTools.of(qaya.builder) orelse return,
        .spirv_readonly = paths.get("limn-spirv_readonly") orelse return,
        .include = paths.get("limn-shader_include") orelse return,
        .generated = paths.get("limn-shader_generated") orelse return,
    };
    compileShaders(b, module, ".", shaders, tools, null);
}

/// Compiles each shader with lrhi's tools, followed by `spirv_readonly`
/// unless the shader opts out, and exposes the code to `module` as an
/// anonymous import. `Shader.src` is relative to `base`, in `b`'s build
/// root.
fn compileShaders(b: *std.Build, module: *std.Build.Module, base: []const u8, shaders: []const Shader, tools: ShaderTools, shaders_step: ?*std.Build.Step) void {
    for (shaders) |shader| {
        const source = b.path(b.pathJoin(&.{ base, shader.src }));
        const includes = [_]std.Build.LazyPath{ tools.include, tools.generated };
        const entry: lrhi_build.Shader = .{ .src = shader.src, .name = shader.name, .defines = shader.defines, .entry = shader.entry, .stage = shader.stage };
        if (shader.writable_reads) {
            const output = tools.lrhi.compile(b, source, entry, &includes, shader.name);
            module.addAnonymousImport(shader.name, .{ .root_source_file = output.code });
            if (shaders_step) |step| step.dependOn(output.step);
            continue;
        }
        const compiled = tools.lrhi.compile(b, source, entry, &includes, b.fmt("{s}.slang.spv", .{shader.name})).code;
        const mark = std.Build.Step.Run.create(b, b.fmt("mark {s} read-only", .{shader.name}));
        mark.addFileArg2(tools.spirv_readonly, .{});
        mark.addFileArg2(compiled, .{});
        const output = mark.addOutputFileArg2(shader.name, .{});
        module.addAnonymousImport(shader.name, .{ .root_source_file = output });
        if (shaders_step) |step| step.dependOn(&mark.step);
    }
}
