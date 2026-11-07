const Sdk = @import("../../build/Sdk.zig");
const lrhi_build = @import("../lrhi/build.zig");

/// lrhi-assets' part of the SDK's build: the two libraries it bridges, and
/// its checks on a GPU.
pub fn build(lib: *Sdk.Library) void {
    const b = lib.b;
    lib.import(lib.module, "lrhi");
    lib.import(lib.module, "assets");

    const tools = lrhi_build.ShaderTools.of(b) orelse return;
    const checks_module = b.createModule(.{
        .root_source_file = lib.path("checks/checks.zig"),
        .target = lib.target,
        .optimize = lib.optimize,
        .sanitize_thread = lib.sdk.thread_sanitizer,
    });
    lib.import(checks_module, "lrhi");
    lib.import(checks_module, "assets");
    checks_module.addImport("lrhi-assets", lib.module);
    const outcomes: lrhi_build.Shader = .{ .src = "checks/checks.slang", .name = "checks.comp", .entry = "outcomesMain", .stage = "compute" };
    checks_module.addAnonymousImport(outcomes.name, .{ .root_source_file = tools.compile(b, lib.path(outcomes.src), outcomes, &.{}, outcomes.name).code });
    const checks = b.addExecutable(.{ .name = "lrhi-assets-checks", .root_module = checks_module, .use_llvm = true });
    checks.rdynamic = lib.sdk.thread_sanitizer;
    lib.addCheck(checks);
    const run_checks = b.addRunArtifact(checks);
    run_checks.has_side_effects = true;
    lib.step("checks", "Check that baked opacity micromaps agree with their texture on a GPU, without a window").dependOn(&run_checks.step);
}
