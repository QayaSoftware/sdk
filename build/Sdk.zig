//! The SDK's build. Each library gets a module named after it, from
//! libs/<name>/src/root.zig, its unit tests under `test` and `check`, its API
//! reference under `docs`, and a `-D<name>` option that leaves it out; its own
//! build.zig adds the rest through `Library`.
const std = @import("std");

const Sdk = @This();

/// What `zig build cross` builds for.
const cross_targets = [_][]const u8{ "x86_64-linux-gnu", "aarch64-linux-gnu", "x86_64-windows-gnu", "x86_64-macos", "aarch64-macos", "aarch64-linux-android" };

/// The Android API level builds target: Android 10.
const android_api = 29;

b: *std.Build,
target: std.Build.ResolvedTarget,
optimize: std.lang.Optimize,
test_step: *std.Build.Step,
check_step: *std.Build.Step,
docs_step: *std.Build.Step,
/// Trims a library's docs to its own modules.
docs_trim: *std.Build.Step.Compile,
/// The libraries added, for the docs' index.
libraries: std.ArrayList([]const u8) = .empty,
/// False while the NDK an Android build needs is being fetched.
ready: bool,

pub fn create(b: *std.Build) *Sdk {
    const target = b.standardTargetOptions(.{});
    const sdk = b.allocator.create(Sdk) catch @panic("OOM");
    sdk.* = .{
        .b = b,
        .target = target,
        .optimize = b.standardOptimizeOption(.{}),
        .test_step = b.step("test", "Run unit tests"),
        .check_step = b.step("check", "Compile everything and its tests without running them"),
        .docs_step = b.step("docs", "Generate API documentation in zig-out/docs"),
        .docs_trim = b.addExecutable(.{
            .name = "docs_trim",
            .root_module = b.createModule(.{ .root_source_file = b.path("build/docs_trim.zig"), .target = b.graph.host, .optimize = .safe }),
        }),
        .ready = !target.result.abi.isAndroid() or useAndroidNdk(b, target),
    };
    const cross_step = b.step("cross", "Build everything for every target, into zig-out/cross/<target>");
    var previous: ?*std.Build.Step = null;
    for (cross_targets) |cross_target| {
        const cross = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "install", b.fmt("-Dtarget={s}", .{cross_target}), "--prefix", b.fmt("zig-out/cross/{s}", .{cross_target}) });
        cross.setCwd(b.path("."));
        cross.has_side_effects = true;
        if (previous) |step| cross.step.dependOn(step);
        previous = &cross.step;
        cross_step.dependOn(&cross.step);
    }
    return sdk;
}

/// Adds the library in libs/`name`, whose build.zig is `library`, unless
/// `-D<name>=false` leaves it out.
pub fn add(sdk: *Sdk, comptime name: []const u8, comptime library: type) void {
    const b = sdk.b;
    if (!(b.option(bool, name, "Build " ++ name ++ " (default: true)") orelse true) or !sdk.ready) return;
    const module = b.addModule(name, .{
        .root_source_file = b.path("libs/" ++ name ++ "/src/root.zig"),
        .target = sdk.target,
        .optimize = sdk.optimize,
    });
    const lib = b.allocator.create(Library) catch @panic("OOM");
    lib.* = .{
        .sdk = sdk,
        .b = b,
        .name = name,
        .root = "libs/" ++ name,
        .target = sdk.target,
        .optimize = sdk.optimize,
        .module = module,
        .artifact = b.addLibrary(.{ .name = name, .root_module = module, .linkage = .static, .use_llvm = true }),
    };
    library.build(lib);
    lib.addTest(module);
    lib.addDocs();
    sdk.libraries.append(b.allocator, name) catch @panic("OOM");
}

/// Adds the docs' index, and gives an Android build the NDK's libc; called
/// once every library is added.
pub fn finish(sdk: *Sdk) void {
    const b = sdk.b;
    var index: std.ArrayList(u8) = .empty;
    index.appendSlice(b.allocator, "<!doctype html>\n<meta charset=\"utf-8\">\n<title>Qaya SDK</title>\n<ul>\n") catch @panic("OOM");
    for (sdk.libraries.items) |name| index.appendSlice(b.allocator, b.fmt("<li><a href=\"{s}/\">{s}</a></li>\n", .{ name, name })) catch @panic("OOM");
    index.appendSlice(b.allocator, "</ul>\n") catch @panic("OOM");
    const page = b.addWriteFiles().add("index.html", index.items);
    sdk.docs_step.dependOn(&b.addInstallFile(page, "docs/index.html").step);
    if (sdk.target.result.abi.isAndroid()) applyAndroidLibc(b);
}

/// A library of the SDK, as its build.zig sees it.
pub const Library = struct {
    sdk: *Sdk,
    b: *std.Build,
    name: []const u8,
    /// Where the library is in the SDK: libs/<name>.
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    /// The library's module, named after it, from src/root.zig.
    module: *std.Build.Module,
    /// The library built from `module`, which its docs come from.
    artifact: *std.Build.Step.Compile,
    /// The modules besides `module` that its docs show.
    documented: std.ArrayList([]const u8) = .empty,

    /// `sub_path` in the library.
    pub fn path(lib: *Library, sub_path: []const u8) std.Build.LazyPath {
        return lib.b.path(lib.b.pathJoin(&.{ lib.root, sub_path }));
    }

    /// `sub_path` in the library, as an absolute path.
    pub fn pathFromRoot(lib: *Library, sub_path: []const u8) []const u8 {
        return absolutePath(lib.b, lib.b.pathJoin(&.{ lib.root, sub_path }));
    }

    /// A top-level step named <library>-<name>.
    pub fn step(lib: *Library, name: []const u8, description: []const u8) *std.Build.Step {
        return lib.b.step(lib.b.fmt("{s}-{s}", .{ lib.name, name }), description);
    }

    /// Runs `module`'s tests under `test`, and compiles them under `check`.
    pub fn addTest(lib: *Library, module: *std.Build.Module) void {
        const tests = lib.b.addTest(.{ .root_module = module, .use_llvm = true });
        lib.addCheck(tests);
        lib.sdk.test_step.dependOn(&lib.b.addRunArtifact(tests).step);
    }

    /// Compiles `compile` under `check`.
    pub fn addCheck(lib: *Library, compile: *std.Build.Step.Compile) void {
        lib.sdk.check_step.dependOn(&compile.step);
    }

    /// Shows the module `name` in the library's docs too.
    pub fn document(lib: *Library, name: []const u8) void {
        lib.documented.append(lib.b.allocator, name) catch @panic("OOM");
    }

    /// Gives an application depending on the SDK `lazy_path`, as the named
    /// lazy path <library>-<name>.
    pub fn addNamedLazyPath(lib: *Library, name: []const u8, lazy_path: std.Build.LazyPath) void {
        lib.b.addNamedLazyPath(lib.b.fmt("{s}-{s}", .{ lib.name, name }), lazy_path);
    }

    /// An executable of examples/`name`.zig that imports the library: it is
    /// installed, compiled under `check`, and run with the arguments after
    /// `--` by the step <library>-<name>.
    pub fn addExample(lib: *Library, name: []const u8, description: []const u8) *std.Build.Step.Compile {
        const b = lib.b;
        const module = b.createModule(.{
            .root_source_file = lib.path(b.fmt("examples/{s}.zig", .{name})),
            .target = lib.target,
            .optimize = lib.optimize,
        });
        module.addImport(lib.name, lib.module);
        const exe = b.addExecutable(.{ .name = b.fmt("{s}-{s}", .{ lib.name, name }), .root_module = module, .use_llvm = true });
        b.installArtifact(exe);
        lib.addCheck(exe);
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        lib.step(name, description).dependOn(&run.step);
        return exe;
    }

    fn addDocs(lib: *Library) void {
        const b = lib.b;
        const docs = lib.artifact.getEmittedDocs();
        const trim = b.addRunArtifact(lib.sdk.docs_trim);
        trim.addFileArg2(docs.path(b, "sources.tar"), .{});
        const sources = trim.addOutputFileArg2("sources.tar", .{});
        trim.addArg(lib.name);
        trim.addArgs(lib.documented.items);
        for ([_][]const u8{ "index.html", "main.js", "main.wasm" }) |file| {
            lib.sdk.docs_step.dependOn(&b.addInstallFile(docs.path(b, file), b.fmt("docs/{s}/{s}", .{ lib.name, file })).step);
        }
        lib.sdk.docs_step.dependOn(&b.addInstallFile(sources, b.fmt("docs/{s}/sources.tar", .{lib.name})).step);
    }
};

/// `sub_path` in `b`'s package, as an absolute path, for what is kept past
/// the build: a dependency's root is relative to where the build runs.
pub fn absolutePath(b: *std.Build, sub_path: []const u8) []const u8 {
    const root = b.root.root_dir.path orelse ".";
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, root, b.allocator) catch |err| std.debug.panic("cannot resolve {s}: {t}", .{ root, err });
    return b.pathJoin(&.{ resolved, b.root.sub_path, sub_path });
}

/// Whether the file at the absolute `path` exists, and has the build
/// configured again when that changes: a missing file is watched for
/// through the nearest directory above it that exists.
pub fn fileExists(b: *std.Build, path: []const u8) bool {
    const io = b.graph.io;
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
        b.dependOnFileMetadata(.{ .cwd_relative = path });
        return true;
    } else |_| {}
    var parent = std.fs.path.dirname(path);
    while (parent) |directory| : (parent = std.fs.path.dirname(directory)) {
        std.Io.Dir.cwd().access(io, directory, .{}) catch continue;
        b.dependOnDirectoryContents(.{ .cwd_relative = directory });
        break;
    }
    return false;
}

/// Has build/android_libc.zig write a libc file for the fetched NDK's Bionic
/// sysroot for `target`, which `applyAndroidLibc` hands to the Android
/// compilations. Returns false while the NDK is being fetched.
fn useAndroidNdk(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const ndk = b.lazyDependency("android_ndk", .{}) orelse return false;
    const sysroot = ndk.path("toolchains/llvm/prebuilt/linux-x86_64/sysroot");
    const triple = switch (target.result.cpu.arch) {
        .x86_64 => "x86_64-linux-android",
        else => "aarch64-linux-android",
    };
    const tool = b.addExecutable(.{
        .name = "android_libc",
        .root_module = b.createModule(.{ .root_source_file = b.path("build/android_libc.zig"), .target = b.graph.host, .optimize = .safe }),
    });
    const write = b.addRunArtifact(tool);
    write.addDirectoryArg2(sysroot, .{});
    write.addArgs(&.{ triple, b.fmt("{d}", .{android_api}) });
    android_libc = write.addOutputFileArg2(b.fmt("{s}.libc", .{triple}), .{});
    android_libraries = sysroot.path(b, b.fmt("usr/lib/{s}/{d}", .{ triple, android_api }));
    return true;
}

/// The libc file `useAndroidNdk` has written, and where the NDK keeps the
/// system libraries, for `applyAndroidLibc`.
var android_libc: std.Build.LazyPath = undefined;
var android_libraries: std.Build.LazyPath = undefined;

/// Gives every Android compilation the build can reach, its packages'
/// included, the NDK's libc; tools built for the build machine keep its own.
/// An application building for Android calls it last in its own `build`,
/// once it depends on the SDK.
pub fn applyAndroidLibc(b: *std.Build) void {
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    for (b.top_level_steps.values()) |top| visitAndroidLibc(b, &top.step, &seen);
}

fn visitAndroidLibc(b: *std.Build, step: *std.Build.Step, seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void)) void {
    if ((seen.getOrPut(b.allocator, step) catch @panic("OOM")).found_existing) return;
    if (step.cast(std.Build.Step.Compile)) |compile| {
        if (compile.rootModuleTarget().abi.isAndroid()) {
            compile.setLibCFile(android_libc);
            compile.root_module.addLibraryPath(android_libraries);
            if (compile.kind == .exe or compile.kind == .@"test") compile.root_module.addObjectFile(android_libraries.path(b, "libc.so"));
        }
        var modules: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        visitModule(b, compile.root_module, &modules, seen);
    }
    for (step.dependencies.items) |dependency| visitAndroidLibc(b, dependency, seen);
}

fn visitModule(b: *std.Build, module: *std.Build.Module, modules: *std.AutoHashMapUnmanaged(*std.Build.Module, void), seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void)) void {
    if ((modules.getOrPut(b.allocator, module) catch @panic("OOM")).found_existing) return;
    if (module.resolved_target) |resolved| if (resolved.result.abi.isAndroid()) {
        module.pic = true;
    };
    for (module.link_objects.items) |object| switch (object) {
        .other_step => |other| visitAndroidLibc(b, &other.step, seen),
        else => {},
    };
    for (module.import_table.values()) |imported| visitModule(b, imported, modules, seen);
}
