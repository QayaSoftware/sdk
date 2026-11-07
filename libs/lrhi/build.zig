const std = @import("std");
const Sdk = @import("../../build/Sdk.zig");

/// The backends lrhi can be built with; `-Dlrhi_backend` picks one.
pub const Backend = enum { vulkan };

/// A Slang shader entry point to compile, for `addShaders`.
pub const Shader = struct {
    src: []const u8,
    name: []const u8,
    defines: []const []const u8 = &.{},
    /// The entry point to compile and its stage.
    entry: []const u8,
    stage: []const u8,
};

/// Arguments every Slang shader is compiled with for `backend`.
pub fn slangArguments(backend: Backend) []const []const u8 {
    return switch (backend) {
        .vulkan => &.{ "-profile", "spirv_1_5", "-target", "spirv", "-fvk-use-scalar-layout", "-matrix-layout-column-major", "-O2", "-warnings-disable", "39001,41012,41035" },
    };
}

/// A program the build runs on the machine doing the build: one the package
/// manager fetched or built, or one found on PATH.
pub const Tool = union(enum) {
    path: std.Build.LazyPath,
    system: []const u8,

    /// A run step that starts the tool through `depfile`
    /// (build/depfile.zig), named for the work it does.
    pub fn command(self: Tool, b: *std.Build, depfile: std.Build.LazyPath, label: []const u8) *std.Build.Step.Run {
        const run = std.Build.Step.Run.create(b, b.fmt("compile {s}", .{label}));
        run.addFileArg2(depfile, .{});
        switch (self) {
            .path => |path| run.addFileArg2(path, .{}),
            .system => |name| run.addArg(name),
        }
        return run;
    }
};

/// A shader `ShaderTools.compile` compiled.
pub const Compiled = struct { code: std.Build.LazyPath, step: *std.Build.Step };

/// What compiling a shader takes: the compiler, the program it runs
/// through, and the backend it compiles for.
pub const ShaderTools = struct {
    slangc: Tool,
    depfile: std.Build.LazyPath,
    backend: Backend,

    /// The tools lrhi's build made, from the build `sdk` of the SDK: `b`
    /// itself, or an application's dependency's builder. Null while lrhi's
    /// dependencies are being fetched.
    pub fn of(sdk: *std.Build) ?ShaderTools {
        const paths = sdk.named_lazy_paths;
        return .{
            .slangc = if (paths.get("lrhi-slangc")) |path| .{ .path = path } else .{ .system = "slangc" },
            .depfile = paths.get("lrhi-depfile") orelse return null,
            .backend = chosenBackend(sdk),
        };
    }

    /// The `-Dlrhi_backend` the build `sdk` was given, as `build` reads it.
    fn chosenBackend(sdk: *std.Build) Backend {
        const option = sdk.user_input_options.get("lrhi_backend") orelse return .vulkan;
        return switch (option) {
            .scalar => |name| std.meta.stringToEnum(Backend, name) orelse .vulkan,
            else => .vulkan,
        };
    }

    /// Compiles one entry point of the Slang file `source` for the
    /// backend, with `includes` searched for what it includes, and returns
    /// the code and the step making it. Included files are tracked through a
    /// depfile, so editing a shared header rebuilds exactly the shaders that
    /// use it.
    pub fn compile(tools: ShaderTools, b: *std.Build, source: std.Build.LazyPath, shader: Shader, includes: []const std.Build.LazyPath, output_name: []const u8) Compiled {
        const command = tools.slangc.command(b, tools.depfile, shader.name);
        command.addFileArg2(source, .{});
        command.addArgs(slangArguments(tools.backend));
        command.addArgs(&.{ "-stage", shader.stage, "-entry", shader.entry });
        for (includes) |include| command.addDirectoryArg2(include, .{ .prefix = "-I" });
        for (shader.defines) |define| command.addArg(b.fmt("-D{s}", .{define}));
        command.addArg("-depfile");
        _ = command.addDepFileOutputArg2(b.fmt("{s}.d", .{shader.name}), .{});
        command.addArg("-o");
        return .{ .code = command.addOutputFileArg2(output_name, .{}), .step = &command.step };
    }
};

/// Compiles an application's own Slang shaders for the backend lrhi is
/// built with, and gives `module` each one's code as an anonymous import
/// named after it, for `@embedFile`. `qaya` is the application's dependency
/// on the SDK; `Shader.src` is relative to the application's build root.
/// Does nothing while lrhi's dependencies are being fetched.
pub fn addShaders(b: *std.Build, qaya: *std.Build.Dependency, module: *std.Build.Module, shaders: []const Shader) void {
    const tools = ShaderTools.of(qaya.builder) orelse return;
    for (shaders) |shader| {
        const code = tools.compile(b, b.path(shader.src), shader, &.{}, shader.name).code;
        module.addAnonymousImport(shader.name, .{ .root_source_file = code });
    }
}

/// lrhi's part of the SDK's build: the backend's bindings and loader, and
/// the shader tools every renderer on it needs.
pub fn build(lib: *Sdk.Library) void {
    const b = lib.b;
    const backend = b.option(Backend, "lrhi_backend", "The graphics API lrhi is built on (default: vulkan)") orelse .vulkan;
    const options = b.addOptions();
    options.addOption(Backend, "backend", backend);
    const module = lib.module;
    module.addOptions("lrhi_options", options);
    lib.import(module, "handles");

    const depfile = b.addExecutable(.{
        .name = "depfile",
        .root_module = b.createModule(.{
            .root_source_file = lib.path("build/depfile.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    lib.addTest(depfile.root_module);
    lib.addNamedLazyPath("depfile", depfile.getEmittedBin());
    if (!lib.sdk.system_tools) {
        const slangc = slangCompiler(b) orelse return;
        switch (slangc) {
            .path => |path| lib.addNamedLazyPath("slangc", path),
            .system => {},
        }
    }

    switch (backend) {
        .vulkan => {
            const vulkan_headers = b.lazyDependency("vulkan_headers", .{}) orelse return;
            const vulkan = b.lazyDependency("vulkan", .{
                .registry = vulkan_headers.path("registry/vk.xml"),
            }) orelse return;
            const volk = b.lazyDependency("volk", .{}) orelse return;
            module.addImport("vulkan", vulkan.module("vulkan-zig"));
            module.addImport("volk", volkModule(lib, vulkan_headers.path("include"), volk));
        },
    }

    const tools = ShaderTools.of(b) orelse return;
    const checks_module = b.createModule(.{
        .root_source_file = lib.path("checks/checks.zig"),
        .target = lib.target,
        .optimize = lib.optimize,
        .sanitize_thread = lib.sdk.thread_sanitizer,
    });
    checks_module.addImport("lrhi", module);
    const candidates: Shader = .{ .src = "checks/checks.slang", .name = "checks.comp", .entry = "candidatesMain", .stage = "compute" };
    checks_module.addAnonymousImport(candidates.name, .{ .root_source_file = tools.compile(b, lib.path(candidates.src), candidates, &.{}, candidates.name).code });
    const checks = b.addExecutable(.{ .name = "lrhi-checks", .root_module = checks_module, .use_llvm = true });
    checks.rdynamic = lib.sdk.thread_sanitizer;
    lib.addCheck(checks);
    const run_checks = b.addRunArtifact(checks);
    run_checks.has_side_effects = true;
    run_checks.addPassthruArgs();
    lib.step("checks", "Check staging reuse, mip copies, opacity micromaps and packed instances on a GPU, without a window").dependOn(&run_checks.step);
}

/// The volk loader, compiled from `source` with the Vulkan headers in
/// `vulkan_include`, and its header translated for Zig.
fn volkModule(
    lib: *Sdk.Library,
    vulkan_include: std.Build.LazyPath,
    /// The loader's source: `volk.c` and `volk.h` at its root.
    source: *std.Build.Dependency,
) *std.Build.Module {
    const b = lib.b;
    const target = lib.target;
    const volk = b.addTranslateC(.{
        .root_source_file = lib.path("src/vulkan/volk.h"),
        .target = target,
        .optimize = lib.optimize,
    });
    volk.addSystemIncludePath(vulkan_include);
    volk.addSystemIncludePath(source.path(""));
    const module = volk.createModule();
    module.addIncludePath(vulkan_include);
    module.addIncludePath(source.path(""));
    module.addCSourceFile(.{
        .file = source.path("volk.c"),
        .flags = if (target.result.os.tag == .windows) &.{"-DVK_USE_PLATFORM_WIN32_KHR"} else &.{},
    });
    module.link_libc = true;
    if (target.result.os.tag == .linux) module.linkSystemLibrary("dl", .{});
    return module;
}

/// The prebuilt Slang compiler for the build machine, or null while it is
/// being fetched. Hosts Slang ships no build for use `slangc` on PATH.
fn slangCompiler(b: *std.Build) ?Tool {
    const host = b.graph.host.result;
    const package: []const u8 = switch (host.os.tag) {
        .linux => switch (host.cpu.arch) {
            .x86_64 => "slang_linux_x86_64",
            .aarch64 => "slang_linux_aarch64",
            else => return .{ .system = "slangc" },
        },
        .macos => switch (host.cpu.arch) {
            .x86_64 => "slang_macos_x86_64",
            .aarch64 => "slang_macos_aarch64",
            else => return .{ .system = "slangc" },
        },
        .windows => switch (host.cpu.arch) {
            .x86_64 => "slang_windows_x86_64",
            .aarch64 => "slang_windows_aarch64",
            else => return .{ .system = "slangc" },
        },
        else => return .{ .system = "slangc" },
    };
    const slang = b.lazyDependency(package, .{}) orelse return null;
    return .{ .path = slang.path(if (host.os.tag == .windows) "bin/slangc.exe" else "bin/slangc") };
}
