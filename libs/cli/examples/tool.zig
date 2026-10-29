const std = @import("std");
const cli = @import("cli");

const Tool = struct {
    verbose: bool = false,
    color: Color = .auto,
    command: Command,

    const Color = enum { auto, always, never };

    const Command = union(enum) {
        build: Build,
        run: Run,
        add: Add,
        clean,
        version,

        pub const meta = .{
            .clean = .{ .help = "Removes everything built" },
            .version = .{ .help = "Prints the version" },
        };
    };

    const Build = struct {
        release: bool = false,
        target: []const u8 = "native",
        jobs: ?u16 = null,
        define: []const []const u8 = &.{},

        pub const description = "Builds the project.";
        pub const meta = .{
            .release = .{ .short = 'r', .help = "Build with optimizations" },
            .target = .{ .short = 't', .help = "What to build for" },
            .jobs = .{ .short = 'j', .help = "How many jobs at once" },
            .define = .{ .short = 'D', .value_name = "NAME=VALUE", .help = "Defines for the build" },
        };
    };

    const Run = struct {
        release: bool = false,
        args: []const []const u8 = &.{},

        pub const description = "Builds and runs the project, passing it the arguments after --.";
        pub const meta = .{
            .release = .{ .short = 'r', .help = "Build with optimizations" },
            .args = .{ .positional = true, .help = "Arguments for the program" },
        };
    };

    const Add = struct {
        name: []const u8,
        version: []const u8 = "latest",
        dev: bool = false,

        pub const description = "Adds a dependency.";
        pub const meta = .{
            .name = .{ .positional = true, .help = "The package" },
            .version = .{ .positional = true, .help = "Which version" },
            .dev = .{ .help = "Only for development" },
        };
    };

    pub const description = "Builds, runs and manages a project.";
    pub const meta = .{
        .verbose = .{ .short = 'v', .help = "Say what is happening" },
        .color = .{ .help = "When to color the output" },
    };
};

pub fn main(init: std.process.Init) !void {
    const tool = cli.parseProcess(Tool, init, .{ .program = "tool" });
    if (tool.verbose) std.debug.print("(color {t})\n", .{tool.color});
    switch (tool.command) {
        .build => |build| std.debug.print("building for {s}{s}, {d} defines\n", .{ build.target, if (build.release) " with optimizations" else "", build.define.len }),
        .run => |run| {
            std.debug.print("running with", .{});
            for (run.args) |arg| std.debug.print(" '{s}'", .{arg});
            std.debug.print("\n", .{});
        },
        .add => |add| std.debug.print("adding {s}@{s}{s}\n", .{ add.name, add.version, if (add.dev) " for development" else "" }),
        .clean => std.debug.print("cleaning\n", .{}),
        .version => std.debug.print("tool 0.1.0\n", .{}),
    }
}
