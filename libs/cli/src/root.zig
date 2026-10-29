//! Command line arguments and environment variables parsed into a struct by
//! its type. Each field is a flag named after it, as `--max-connections`
//! for `max_connections`, taking a value of the field's type: an integer,
//! float, enum, string, bool (a switch), optional, slice (given any number
//! of times), or any type with a `parseCli` function. A field with a
//! default, or an optional one, can be left out. A nested struct is a group
//! whose flags start with its name, and a tagged union is the subcommands,
//! each parsing the arguments after its name into its payload.
//!
//! A struct says more about its fields in a `meta` declaration, and about
//! itself in a `description`:
//!
//!     const Options = struct {
//!         port: u16 = 8080,
//!         verbose: bool = false,
//!         files: []const []const u8,
//!
//!         pub const description = "Serves files.";
//!         pub const meta = .{
//!             .port = .{ .short = 'p', .help = "Port to listen on" },
//!             .files = .{ .positional = true, .help = "Files to serve" },
//!         };
//!     };
//!
//! A field's options are `help`, `short`, `long` (its flag in place of the
//! name), `positional`, `value_name`, `hidden`, `count` (an integer counting
//! its flag, as `-vvv`), `separator` (between a list's values in an
//! environment variable; `,` unless set) and `env`: a variable's name, false
//! for none, or true to read the variable named after the field even
//! without a prefix. The command line wins over the environment, which wins
//! over defaults.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const parser = @import("parser.zig");
const help = @import("help.zig");

pub const Error = parser.Error;
pub const Options = parser.Options;
pub const Diagnostics = parser.Diagnostics;
pub const HelpTarget = help.Target;

/// A parsed `T` and the arena that holds its strings and slices.
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: @This()) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self.arena);
        }
    };
}

/// Parses `args`, without the program's name, and the environment
/// `options` gives, into a `T`.
pub fn parse(comptime T: type, gpa: Allocator, args: []const []const u8, options: Options) Error!Parsed(T) {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    return .{ .arena = arena, .value = try parseLeaky(T, arena.allocator(), args, options) };
}

/// Parses as `parse` does, allocating in `arena`, which the result's strings
/// and slices live in; what it allocates before an error is not freed.
pub fn parseLeaky(comptime T: type, arena: Allocator, args: []const []const u8, options: Options) Error!T {
    return parser.parseLeaky(T, arena, args, options);
}

pub const ProcessOptions = struct {
    env_prefix: []const u8 = "",
    /// The name help gives the program; the one it was run as unless set.
    program: ?[]const u8 = null,
};

/// Parses the process's arguments and environment into a `T` that lives as
/// long as the process. For `--help` it writes the help to stdout and exits
/// with 0; for an error it writes the error and usage to stderr and exits
/// with 2.
pub fn parseProcess(comptime T: type, init: std.process.Init, options: ProcessOptions) T {
    const arena = init.arena.allocator();
    const argv = init.minimal.args.toSlice(arena) catch @panic("out of memory");
    const args = arena.alloc([]const u8, argv.len -| 1) catch @panic("out of memory");
    for (args, argv[@min(argv.len, 1)..]) |*arg, given| arg.* = given;
    const program = options.program orelse if (argv.len > 0) std.fs.path.basename(argv[0]) else "program";
    var diagnostics: Diagnostics = .{};
    return parseLeaky(T, arena, args, .{ .env = init.environ_map, .env_prefix = options.env_prefix, .diagnostics = &diagnostics }) catch |err| {
        var buffer: [4096]u8 = undefined;
        if (err == error.OutOfMemory) @panic("out of memory");
        if (err == error.Help) {
            var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
            diagnostics.writeHelp(&stdout.interface, program) catch {};
            stdout.interface.flush() catch {};
            std.process.exit(0);
        }
        const stderr = init.io.lockStderr(&buffer, null) catch std.process.exit(2);
        const writer = &stderr.file_writer.interface;
        writer.print("error: {f}\n\n", .{diagnostics}) catch {};
        diagnostics.writeUsage(writer, program) catch {};
        writer.writeAll("\nFor more, try '--help'.\n") catch {};
        writer.flush() catch {};
        init.io.unlockStderr();
        std.process.exit(2);
    };
}

/// Writes `T`'s help: its description, usage, arguments, options and
/// commands.
pub fn writeHelp(comptime T: type, writer: *Writer, target: HelpTarget) Writer.Error!void {
    return help.writeHelp(T, writer, target);
}

/// Writes the line saying what `T` takes.
pub fn writeUsage(comptime T: type, writer: *Writer, target: HelpTarget) Writer.Error!void {
    return help.writeUsage(T, writer, target);
}

test {
    _ = @import("tests.zig");
}
