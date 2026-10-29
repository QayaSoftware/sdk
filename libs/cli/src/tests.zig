const std = @import("std");
const cli = @import("root.zig");

const testing = std.testing;

const Level = enum { debug, info, warn, very_loud };

const Server = struct {
    port: u16 = 8080,
    host: []const u8 = "localhost",
    verbose: bool = false,
    level: Level = .info,
    ratio: ?f32 = null,
    include: []const []const u8 = &.{},
    quiet: u8 = 0,
    name: []const u8,
    db: Database = .{},
    files: []const []const u8 = &.{},

    const Database = struct {
        host: []const u8 = "db.local",
        port: u16 = 5432,
    };

    pub const description = "Serves files.";
    pub const meta = .{
        .port = .{ .short = 'p', .help = "Port to listen on" },
        .verbose = .{ .short = 'v', .help = "Log every request" },
        .level = .{ .help = "How much to log" },
        .quiet = .{ .short = 'q', .count = true, .help = "Log less, more for each" },
        .include = .{ .short = 'I', .value_name = "DIR", .help = "Directories to include" },
        .name = .{ .help = "What to call the server", .env = "SERVER_NAME" },
        .files = .{ .positional = true, .help = "Files to serve" },
    };
};

const Tool = struct {
    verbose: bool = false,
    command: Command,

    const Command = union(enum) {
        build: Build,
        run: Run,
        clean,
        dry_run,

        pub const meta = .{ .clean = .{ .help = "Removes what was built" } };
    };

    const Build = struct {
        release: bool = false,
        target: []const u8 = "native",

        pub const description = "Builds the project.\nIt builds everything.";
        pub const meta = .{ .release = .{ .short = 'r' } };
    };

    const Run = struct {
        args: []const []const u8 = &.{},

        pub const meta = .{ .args = .{ .positional = true } };
    };

    pub const meta = .{ .verbose = .{ .short = 'v', .help = "Say more" } };
};

fn expectFailure(comptime T: type, args: []const []const u8, options: cli.Options, err: cli.Error, message: []const u8) !void {
    var diagnostics: cli.Diagnostics = .{};
    var with = options;
    with.diagnostics = &diagnostics;
    try testing.expectError(err, cli.parse(T, testing.allocator, args, with));
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(message, try std.fmt.bufPrint(&buffer, "{f}", .{diagnostics}));
}

fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "flags of every type parse into their fields" {
    const parsed = try cli.parse(Server, testing.allocator, &.{
        "--port",    "9000", "--host=example.com", "-v",  "--level", "very-loud", "--ratio", "0.5",
        "--include", "a",    "-I",                 "b",   "-Ic",     "--name",    "srv",     "-qqq",
        "--db-host", "db",   "--db-port=1",        "one", "two",
    }, .{});
    defer parsed.deinit();
    const server = parsed.value;
    try testing.expectEqual(@as(u16, 9000), server.port);
    try testing.expectEqualStrings("example.com", server.host);
    try testing.expect(server.verbose);
    try testing.expectEqual(Level.very_loud, server.level);
    try testing.expectEqual(@as(?f32, 0.5), server.ratio);
    try expectStrings(&.{ "a", "b", "c" }, server.include);
    try testing.expectEqualStrings("srv", server.name);
    try testing.expectEqual(@as(u8, 3), server.quiet);
    try testing.expectEqualStrings("db", server.db.host);
    try testing.expectEqual(@as(u16, 1), server.db.port);
    try expectStrings(&.{ "one", "two" }, server.files);
}

test "defaults fill what is not given, and what has none must be given" {
    const parsed = try cli.parse(Server, testing.allocator, &.{ "--name", "" }, .{});
    defer parsed.deinit();
    const server = parsed.value;
    try testing.expectEqual(@as(u16, 8080), server.port);
    try testing.expectEqualStrings("localhost", server.host);
    try testing.expect(!server.verbose);
    try testing.expectEqual(Level.info, server.level);
    try testing.expectEqual(@as(?f32, null), server.ratio);
    try testing.expectEqual(@as(usize, 0), server.include.len);
    try testing.expectEqualStrings("", server.name);
    try testing.expectEqualStrings("db.local", server.db.host);
    try expectFailure(Server, &.{}, .{}, error.MissingArgument, "missing '--name', which SERVER_NAME can also give");
}

test "short flags cluster, and take their value attached or after" {
    for ([_][]const []const u8{ &.{ "-vp80", "--name=n" }, &.{ "-vp", "80", "--name=n" }, &.{ "-v", "-p=80", "--name=n" } }) |args| {
        const parsed = try cli.parse(Server, testing.allocator, args, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value.verbose);
        try testing.expectEqual(@as(u16, 80), parsed.value.port);
    }
    const parsed = try cli.parse(Server, testing.allocator, &.{ "-qqq", "--name=n", "-q", "--port", "0x1F90" }, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(u8, 4), parsed.value.quiet);
    try testing.expectEqual(@as(u16, 8080), parsed.value.port);
}

test "a toggle turns off with no- or a value" {
    const cases = [_]struct { []const []const u8, bool }{
        .{ &.{ "--verbose", "--no-verbose" }, false },
        .{ &.{"--verbose=false"}, false },
        .{ &.{"--verbose=YES"}, true },
        .{ &.{ "--no-verbose", "-v" }, true },
    };
    for (cases) |case| {
        const args = try std.mem.concat(testing.allocator, []const u8, &.{ case[0], &.{"--name=n"} });
        defer testing.allocator.free(args);
        const parsed = try cli.parse(Server, testing.allocator, args, .{});
        defer parsed.deinit();
        try testing.expectEqual(case[1], parsed.value.verbose);
    }
    try expectFailure(Server, &.{ "--name=n", "--no-port" }, .{}, error.UnknownFlag, "unknown flag '--no-port'; did you mean '--db-port'?");
    try expectFailure(Server, &.{ "--name=n", "--verbose=maybe" }, .{}, error.InvalidValue, "invalid value 'maybe' for '--verbose': expected true or false");
}

test "-- ends the flags, and a negative number is a value" {
    const Shift = struct {
        offset: i32,
        delta: i32 = 0,
        rest: []const []const u8 = &.{},

        pub const meta = .{
            .offset = .{ .positional = true },
            .rest = .{ .positional = true },
        };
    };
    const parsed = try cli.parse(Shift, testing.allocator, &.{ "-5", "--delta", "-3", "--", "--not-a-flag", "-x" }, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i32, -5), parsed.value.offset);
    try testing.expectEqual(@as(i32, -3), parsed.value.delta);
    try expectStrings(&.{ "--not-a-flag", "-x" }, parsed.value.rest);
    try expectFailure(Shift, &.{}, .{}, error.MissingArgument, "missing '<offset>'");
    try expectFailure(Shift, &.{"x"}, .{}, error.InvalidValue, "invalid value 'x' for '<offset>': expected an integer from -2147483648 to 2147483647");
}

test "the environment falls between the command line and the defaults" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("APP_PORT", "7000");
    try env.put("APP_VERBOSE", "on");
    try env.put("APP_LEVEL", "warn");
    try env.put("APP_INCLUDE", "x,y");
    try env.put("APP_DB_HOST", "remote");
    try env.put("APP_QUIET", "2");
    try env.put("SERVER_NAME", "from-env");
    try env.put("PORT", "1234");

    const prefixed = try cli.parse(Server, testing.allocator, &.{ "--port", "1" }, .{ .env = &env, .env_prefix = "APP_" });
    defer prefixed.deinit();
    try testing.expectEqual(@as(u16, 1), prefixed.value.port);
    try testing.expect(prefixed.value.verbose);
    try testing.expectEqual(Level.warn, prefixed.value.level);
    try expectStrings(&.{ "x", "y" }, prefixed.value.include);
    try testing.expectEqualStrings("remote", prefixed.value.db.host);
    try testing.expectEqual(@as(u8, 2), prefixed.value.quiet);
    try testing.expectEqualStrings("from-env", prefixed.value.name);

    const plain = try cli.parse(Server, testing.allocator, &.{}, .{ .env = &env });
    defer plain.deinit();
    try testing.expectEqual(@as(u16, 8080), plain.value.port);
    try testing.expect(!plain.value.verbose);
    try testing.expectEqualStrings("from-env", plain.value.name);

    try env.put("APP_PORT", "lots");
    try expectFailure(Server, &.{}, .{ .env = &env, .env_prefix = "APP_" }, error.InvalidValue, "invalid value 'lots' in APP_PORT: expected an integer from 0 to 65535");
}

test "an env option names, forces or turns off a field's variable" {
    const Paths = struct {
        home: []const u8 = "",
        path: []const u8 = "",
        token: []const u8 = "",
        cache: []const u8 = "",

        pub const meta = .{
            .home = .{ .env = true },
            .token = .{ .env = "SECRET" },
            .cache = .{ .env = false },
        };
    };
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/me");
    try env.put("PATH", "/bin");
    try env.put("SECRET", "hunter2");
    try env.put("CACHE", "/tmp");
    try env.put("X_CACHE", "/tmp");
    try env.put("X_PATH", "/usr/bin");

    const plain = try cli.parse(Paths, testing.allocator, &.{}, .{ .env = &env });
    defer plain.deinit();
    try testing.expectEqualStrings("/home/me", plain.value.home);
    try testing.expectEqualStrings("", plain.value.path);
    try testing.expectEqualStrings("hunter2", plain.value.token);
    try testing.expectEqualStrings("", plain.value.cache);

    const prefixed = try cli.parse(Paths, testing.allocator, &.{}, .{ .env = &env, .env_prefix = "X_" });
    defer prefixed.deinit();
    try testing.expectEqualStrings("/usr/bin", prefixed.value.path);
    try testing.expectEqualStrings("", prefixed.value.cache);
}

test "a failed parse says what was wrong" {
    try expectFailure(Server, &.{ "--prot", "80" }, .{}, error.UnknownFlag, "unknown flag '--prot'; did you mean '--port'?");
    try expectFailure(Server, &.{"--port"}, .{}, error.MissingValue, "'--port' needs a value");
    try expectFailure(Server, &.{"-p"}, .{}, error.MissingValue, "'-p' needs a value");
    try expectFailure(Server, &.{ "--port", "abc" }, .{}, error.InvalidValue, "invalid value 'abc' for '--port': expected an integer from 0 to 65535");
    try expectFailure(Server, &.{ "-p", "70000" }, .{}, error.InvalidValue, "invalid value '70000' for '-p': expected an integer from 0 to 65535");
    try expectFailure(Server, &.{"-vx"}, .{}, error.UnknownFlag, "unknown flag '-x'");
    try expectFailure(Server, &.{ "--level", "loud" }, .{}, error.InvalidValue, "invalid value 'loud' for '--level': expected one of debug, info, warn or very-loud");
    try expectFailure(Tool, &.{ "build", "extra" }, .{}, error.UnexpectedArgument, "unexpected argument 'extra'");
}

test "commands parse the arguments after them into their payload" {
    {
        const parsed = try cli.parse(Tool, testing.allocator, &.{ "-v", "build", "-r", "--target", "x86" }, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value.verbose);
        try testing.expect(parsed.value.command.build.release);
        try testing.expectEqualStrings("x86", parsed.value.command.build.target);
    }
    {
        const parsed = try cli.parse(Tool, testing.allocator, &.{ "run", "a", "--", "-b" }, .{});
        defer parsed.deinit();
        try expectStrings(&.{ "a", "-b" }, parsed.value.command.run.args);
    }
    inline for (.{ .{ "clean", Tool.Command.clean }, .{ "dry-run", Tool.Command.dry_run } }) |case| {
        const parsed = try cli.parse(Tool, testing.allocator, &.{case[0]}, .{});
        defer parsed.deinit();
        try testing.expectEqual(case[1], parsed.value.command);
    }
    try expectFailure(Tool, &.{"bild"}, .{}, error.UnknownCommand, "unknown command 'bild'; did you mean 'build'?");
    try expectFailure(Tool, &.{"-v"}, .{}, error.MissingCommand, "missing a command: build, run, clean or dry-run");
    try expectFailure(Tool, &.{ "build", "--verbose" }, .{}, error.UnknownFlag, "unknown flag '--verbose'");
    try expectFailure(Tool, &.{ "clean", "now" }, .{}, error.UnexpectedArgument, "unexpected argument 'now'");
}

fn helpFor(comptime T: type, args: []const []const u8, options: cli.Options, program: []const u8, buffer: []u8) ![]const u8 {
    var diagnostics: cli.Diagnostics = .{};
    var with = options;
    with.diagnostics = &diagnostics;
    try testing.expectError(error.Help, cli.parse(T, testing.allocator, args, with));
    var writer: std.Io.Writer = .fixed(buffer);
    try diagnostics.writeHelp(&writer, program);
    return writer.buffered();
}

test "help is written for the command it was asked of" {
    var buffer: [2048]u8 = undefined;
    try testing.expectEqualStrings(
        \\Usage: tool [options] <command>
        \\
        \\Options:
        \\  -v, --verbose  Say more
        \\  -h, --help     Show this help
        \\
        \\Commands:
        \\  build    Builds the project.
        \\  run
        \\  clean    Removes what was built
        \\  dry-run
        \\
    , try helpFor(Tool, &.{ "-v", "--help", "build" }, .{}, "tool", &buffer));
    try testing.expectEqualStrings(
        \\Builds the project.
        \\It builds everything.
        \\
        \\Usage: tool build [options]
        \\
        \\Options:
        \\  -r, --release
        \\      --target <TARGET>  [default: native]
        \\  -h, --help             Show this help
        \\
    , try helpFor(Tool, &.{ "build", "-rh" }, .{}, "tool", &buffer));
    try testing.expectEqualStrings(
        \\Removes what was built
        \\
        \\Usage: tool clean [options]
        \\
        \\Options:
        \\  -h, --help  Show this help
        \\
    , try helpFor(Tool, &.{ "clean", "--help" }, .{}, "tool", &buffer));
}

test "help shows arguments, defaults, choices and environment variables" {
    var buffer: [4096]u8 = undefined;
    try testing.expectEqualStrings(
        \\Serves files.
        \\
        \\Usage: server [options] [<files>...]
        \\
        \\Arguments:
        \\  <files>...  Files to serve [env: APP_FILES]
        \\
        \\Options:
        \\  -p, --port <PORT>       Port to listen on [default: 8080] [env: APP_PORT]
        \\      --host <HOST>       [default: localhost] [env: APP_HOST]
        \\  -v, --verbose           Log every request [env: APP_VERBOSE]
        \\      --level <LEVEL>     How much to log [possible: debug, info, warn, very-loud] [default: info] [env: APP_LEVEL]
        \\      --ratio <RATIO>     [env: APP_RATIO]
        \\  -I, --include <DIR>...  Directories to include [env: APP_INCLUDE]
        \\  -q, --quiet             Log less, more for each [env: APP_QUIET]
        \\      --name <NAME>       What to call the server [env: SERVER_NAME]
        \\      --db-host <HOST>    [default: db.local] [env: APP_DB_HOST]
        \\      --db-port <PORT>    [default: 5432] [env: APP_DB_PORT]
        \\  -h, --help              Show this help
        \\
    , try helpFor(Server, &.{"-h"}, .{ .env_prefix = "APP_" }, "server", &buffer));
}

const Size = struct {
    width: u32,
    height: u32,

    pub const cli_expected = "a size such as 800x600";

    pub fn parseCli(_: std.mem.Allocator, text: []const u8) !Size {
        const x = std.mem.indexOfScalar(u8, text, 'x') orelse return error.NoX;
        return .{ .width = try std.fmt.parseInt(u32, text[0..x], 10), .height = try std.fmt.parseInt(u32, text[x + 1 ..], 10) };
    }
};

test "a type with parseCli parses itself" {
    const Window = struct {
        size: Size = .{ .width = 640, .height = 480 },
        sizes: []const Size = &.{},
    };
    const parsed = try cli.parse(Window, testing.allocator, &.{ "--size", "800x600", "--sizes=1x2", "--sizes", "3x4" }, .{});
    defer parsed.deinit();
    try testing.expectEqual(Size{ .width = 800, .height = 600 }, parsed.value.size);
    try testing.expectEqualSlices(Size, &.{ .{ .width = 1, .height = 2 }, .{ .width = 3, .height = 4 } }, parsed.value.sizes);
    try expectFailure(Window, &.{ "--size", "big" }, .{}, error.InvalidValue, "invalid value 'big' for '--size': expected a size such as 800x600");
}

test "parseLeaky allocates in the arena it is given" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tool = try cli.parseLeaky(Tool, arena.allocator(), &.{ "run", "x", "y" }, .{});
    try expectStrings(&.{ "x", "y" }, tool.command.run.args);
}
