const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("slime", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "slime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "slime", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const example_imports: []const std.Build.Module.Import = &.{
        .{ .name = "slime", .module = mod },
    };

    const basic_mod = b.createModule(.{
        .root_source_file = b.path("examples/basic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
    });
    const basic_exe = b.addExecutable(.{ .name = "slime-example", .root_module = basic_mod });
    b.installArtifact(basic_exe);
    const run_basic = b.addRunArtifact(basic_exe);
    run_basic.step.dependOn(b.getInstallStep());
    const example_step = b.step("example", "Run examples/basic.zig");
    example_step.dependOn(&run_basic.step);

    const prefabs_mod = b.createModule(.{
        .root_source_file = b.path("examples/prefabs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
    });
    const prefabs_exe = b.addExecutable(.{ .name = "slime-example-prefabs", .root_module = prefabs_mod });
    b.installArtifact(prefabs_exe);
    const run_prefabs = b.addRunArtifact(prefabs_exe);
    run_prefabs.step.dependOn(b.getInstallStep());
    const example_prefabs_step = b.step("example-prefabs", "Run examples/prefabs.zig");
    example_prefabs_step.dependOn(&run_prefabs.step);

    const parallel_mod = b.createModule(.{
        .root_source_file = b.path("examples/parallel.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
    });
    const parallel_exe = b.addExecutable(.{ .name = "slime-example-parallel", .root_module = parallel_mod });
    b.installArtifact(parallel_exe);
    const run_parallel = b.addRunArtifact(parallel_exe);
    run_parallel.step.dependOn(b.getInstallStep());
    const example_parallel_step = b.step("example-parallel", "Run examples/parallel.zig");
    example_parallel_step.dependOn(&run_parallel.step);

    const examples_all = b.step("examples", "Run basic, prefabs, and parallel examples");
    examples_all.dependOn(&run_basic.step);
    examples_all.dependOn(&run_prefabs.step);
    examples_all.dependOn(&run_parallel.step);

    const perf_mod = b.createModule(.{
        .root_source_file = b.path("examples/performance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
        .link_libc = true, // For c_allocator
    });
    const perf_exe = b.addExecutable(.{ .name = "slime-perf", .root_module = perf_mod });
    b.installArtifact(perf_exe);
    const run_perf = b.addRunArtifact(perf_exe);
    run_perf.step.dependOn(b.getInstallStep());
    const performance_step = b.step(
        "performance",
        "Run ECS micro-benchmarks (timer). Optional: zig build performance -Doptimize=ReleaseFast -- 100000",
    );
    performance_step.dependOn(&run_perf.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
        run_perf.addArgs(args);
    }
}
