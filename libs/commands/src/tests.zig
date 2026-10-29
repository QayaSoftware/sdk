const std = @import("std");
const commands = @import("root.zig");
const Reader = commands.Reader;

const testing = std.testing;

/// What commands write to, so tests can check what ran.
const Log = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    fn print(self: *Log, comptime format: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(self.buffer[self.len..], format, args) catch unreachable;
        self.len += written.len;
    }

    fn text(self: *const Log) []const u8 {
        return self.buffer[0..self.len];
    }
};

const Source = struct {
    log: *Log,
    name: []const u8 = "console",
    op: bool = true,
};

const Dispatcher = commands.Dispatcher(Source);
const Context = Dispatcher.Context;

const Direction = enum { north, south, east, west };

fn whoami(ctx: *const Context) !void {
    ctx.source.log.print("{s};", .{ctx.source.name});
}

fn echo(ctx: *const Context) !void {
    ctx.source.log.print("{s};", .{ctx.text()});
}

fn teleport(ctx: *const Context) !void {
    ctx.source.log.print("{d} {d} {d};", .{ ctx.argument(f64, "x"), ctx.argument(f64, "y"), ctx.argument(f64, "z") });
}

fn failing(_: *const Context) !void {
    return error.Failed;
}

fn isOp(source: Source) bool {
    return source.op;
}

fn asName(ctx: *const Context) !Source {
    const name = ctx.argument([]const u8, "name");
    if (std.mem.eql(u8, name, "nobody")) return error.NoSuchPlayer;
    return .{ .log = ctx.source.log, .name = name, .op = ctx.source.op };
}

fn eachName(ctx: *const Context, sources: *Dispatcher.Sources) !void {
    var names = std.mem.splitScalar(u8, ctx.argument([]const u8, "names"), ',');
    while (names.next()) |name| sources.add(.{ .log = ctx.source.log, .name = name });
}

fn failingIfNamed(ctx: *const Context) !void {
    if (std.mem.eql(u8, ctx.source.name, "fail")) return error.Failed;
    ctx.source.log.print("{s};", .{ctx.source.name});
}

/// tp <x> <y> <z>, tp <target> <destination>, give <target> <count>,
/// say <message>, and execute (as <name>|each <names>|run) ... .
fn sample(dispatcher: *Dispatcher) !void {
    const tp = try dispatcher.literal(.root, "tp", .{});
    const x = try dispatcher.argument(tp, "x", f64, .{});
    const y = try dispatcher.argument(x, "y", f64, .{});
    _ = try dispatcher.argument(y, "z", f64, .{ .executes = teleport });
    const target = try dispatcher.argument(tp, "target", commands.word, .{});
    _ = try dispatcher.argument(target, "destination", commands.word, .{ .executes = echo });

    const give = try dispatcher.literal(.root, "give", .{});
    const receiver = try dispatcher.argument(give, "target", commands.word, .{});
    _ = try dispatcher.argument(receiver, "count", commands.integer(u8, .{ .min = 1, .max = 64 }), .{ .executes = echo });

    const say = try dispatcher.literal(.root, "say", .{});
    _ = try dispatcher.argument(say, "message", commands.greedy, .{ .executes = echo });

    _ = try dispatcher.literal(.root, "whoami", .{ .executes = whoami });
    _ = try dispatcher.literal(.root, "fail", .{ .executes = failing });
    _ = try dispatcher.literal(.root, "check", .{ .executes = failingIfNamed });

    const execute = try dispatcher.literal(.root, "execute", .{});
    _ = try dispatcher.literal(execute, "run", .{ .redirect = .to(.root) });
    const as = try dispatcher.literal(execute, "as", .{});
    _ = try dispatcher.argument(as, "name", commands.word, .{ .redirect = .map(execute, asName) });
    const each = try dispatcher.literal(execute, "each", .{});
    _ = try dispatcher.argument(each, "names", commands.word, .{ .redirect = .fork(execute, eachName) });
}

fn expectRun(dispatcher: *const Dispatcher, input: []const u8, runs: usize, logged: []const u8) !void {
    var log: Log = .{};
    var diagnostics: commands.Diagnostics = .{};
    const ran = dispatcher.execute(input, .{ .log = &log }, &diagnostics) catch |err| {
        std.debug.print("'{s}' failed: {t}: {f}\n", .{ input, err, diagnostics });
        return err;
    };
    try testing.expectEqual(runs, ran);
    try testing.expectEqualStrings(logged, log.text());
}

fn expectFailure(dispatcher: *const Dispatcher, input: []const u8, err: commands.ParseError, explained: []const u8) !void {
    var log: Log = .{};
    var diagnostics: commands.Diagnostics = .{};
    try testing.expectError(err, dispatcher.execute(input, .{ .log = &log }, &diagnostics));
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(explained, try std.fmt.bufPrint(&buffer, "{f}", .{diagnostics}));
    try testing.expectEqualStrings("", log.text());
}

fn expectSuggestions(dispatcher: *const Dispatcher, input: []const u8, source: Source, expected: []const []const u8) !void {
    var suggestions = try dispatcher.suggest(testing.allocator, input, source);
    defer suggestions.deinit();
    var texts: [32][]const u8 = undefined;
    for (suggestions.items, 0..) |suggestion, i| texts[i] = suggestion.text;
    testing.expectEqualDeep(expected, texts[0..suggestions.items.len]) catch |err| {
        std.debug.print("suggestions for '{s}': {any}\n", .{ input, texts[0..suggestions.items.len] });
        return err;
    };
}

test "literals and arguments parse to the command where the input ends" {
    var dispatcher = Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    try sample(&dispatcher);
    try expectRun(&dispatcher, "tp 1 -2.5 .5", 1, "1 -2.5 0.5;");
    try expectRun(&dispatcher, "give bob 64", 1, "give bob 64;");
    try expectRun(&dispatcher, "say hello there,  world", 1, "say hello there,  world;");
}

test "every argument type parses its value" {
    const Command = struct {
        fn run(ctx: *const Context) !void {
            ctx.source.log.print("{d}|{d}|{}|{s}|{s}|{t}|{s}", .{
                ctx.argument(i32, "int"),
                ctx.argument(f32, "float"),
                ctx.argument(bool, "bool"),
                ctx.argument([]const u8, "word"),
                ctx.argument([]const u8, "string"),
                ctx.argument(Direction, "direction"),
                ctx.argument([]const u8, "rest"),
            });
        }
    };
    var dispatcher = Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    var node = try dispatcher.literal(.root, "all", .{});
    node = try dispatcher.argument(node, "int", i32, .{});
    node = try dispatcher.argument(node, "float", f32, .{});
    node = try dispatcher.argument(node, "bool", bool, .{});
    node = try dispatcher.argument(node, "word", commands.word, .{});
    node = try dispatcher.argument(node, "string", commands.string, .{});
    node = try dispatcher.argument(node, "direction", Direction, .{});
    _ = try dispatcher.argument(node, "rest", commands.greedy, .{ .executes = Command.run });

    try expectRun(&dispatcher, "all -7 0.25 true a:b/c \"say \\\"hi\\\" \\\\ there\" west and the rest", 1, "-7|0.25|true|a:b/c|say \"hi\" \\ there|west|and the rest");
    try expectRun(&dispatcher, "all 7 1 false w 'quoted, plain' north x", 1, "7|1|false|w|quoted, plain|north|x");
    try expectRun(&dispatcher, "all 7 1 false w unquoted north x", 1, "7|1|false|w|unquoted|north|x");
}

test "a literal wins over arguments, and arguments are tried in the order added" {
    var dispatcher = Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    const pick = try dispatcher.literal(.root, "pick", .{});
    _ = try dispatcher.literal(pick, "all", .{ .executes = whoami });
    _ = try dispatcher.argument(pick, "number", u32, .{ .executes = echo });
    _ = try dispatcher.argument(pick, "name", commands.word, .{ .executes = failing });
    try expectRun(&dispatcher, "pick all", 1, "console;");
    try expectRun(&dispatcher, "pick 12", 1, "pick 12;");
    try testing.expectError(error.Failed, dispatcher.execute("pick twelve", .{ .log = undefined }, null));
}

test "parsing backtracks to the way that reads the whole input" {
    var dispatcher = Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    try sample(&dispatcher);
    try expectRun(&dispatcher, "tp 1 2 3", 1, "1 2 3;");
    try expectRun(&dispatcher, "tp 1 bob", 1, "tp 1 bob;");
    try expectRun(&dispatcher, "tp alice bob", 1, "tp alice bob;");
}

test "a failed parse says where and why" {
    var dispatcher = Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    try sample(&dispatcher);
    try expectFailure(&dispatcher, "", error.UnknownCommand, "Unknown command at position 0: <--[HERE]");
    try expectFailure(&dispatcher, "nope", error.UnknownCommand, "Unknown command at position 0: <--[HERE]");
    try expectFailure(&dispatcher, "tp", error.IncompleteCommand, "Incomplete command at position 2: tp<--[HERE]");
    try expectFailure(&dispatcher, "give bob", error.IncompleteCommand, "Incomplete command at position 8: give bob<--[HERE]");
    try expectFailure(&dispatcher, "tp 1 2 3 4", error.UnknownArgument, "Incorrect argument for command at position 9: tp 1 2 3 <--[HERE]");
    try expectFailure(&dispatcher, "tp 1 ", error.UnknownArgument, "Incorrect argument for command at position 4: tp 1<--[HERE]");
    try expectFailure(&dispatcher, "give bob 0", error.InvalidArgument, "Integer must not be less than 1 at position 9: give bob <--[HERE]");
    try expectFailure(&dispatcher, "give bob 65", error.InvalidArgument, "Integer must not be more than 64 at position 9: give bob <--[HERE]");
    try expectFailure(&dispatcher, "give bob x", error.InvalidArgument, "Expected integer at position 9: give bob <--[HERE]");
    try expectFailure(&dispatcher, "give bob 1.5", error.InvalidArgument, "Invalid integer at position 9: give bob <--[HERE]");
    try expectFailure(&dispatcher, "give bob 5x", error.InvalidArgument, "Expected whitespace to end one argument, but found trailing data at position 10: give bob 5<--[HERE]");
    try expectFailure(&dispatcher, "execute as somebody whoami", error.UnknownArgument, "Incorrect argument for command at position 20: ... somebody <--[HERE]");
    try expectFailure(&dispatcher, "execute run", error.IncompleteCommand, "Incomplete command at position 11: ...xecute run<--[HERE]");
    try expectFailure(&dispatcher, "execute run ", error.IncompleteCommand, "Incomplete command at position 12: ...ecute run <--[HERE]");

    var diagnostics: commands.Diagnostics = .{};
    var buffer: [128]u8 = undefined;
    try testing.expectError(error.InvalidArgument, dispatcher.parse("give bob 0", .{ .log = undefined }, &buffer, &diagnostics));
    try testing.expectError(error.IntegerTooSmall, @as(anyerror!void, diagnostics.err));
    try testing.expectEqual(@as(usize, 9), diagnostics.cursor);
}

test "argument types explain their own errors" {
    var dispatcher = Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    const face = try dispatcher.literal(.root, "face", .{});
    _ = try dispatcher.argument(face, "direction", Direction, .{ .executes = echo });
    const speed = try dispatcher.literal(.root, "speed", .{});
    _ = try dispatcher.argument(speed, "value", commands.float(f32, .{ .min = 0, .max = 2.5 }), .{ .executes = echo });
    const quote = try dispatcher.literal(.root, "quote", .{});
    _ = try dispatcher.argument(quote, "text", commands.string, .{ .executes = echo });
    try expectFailure(&dispatcher, "face up", error.InvalidArgument, "Expected north, south, east or west at position 5: face <--[HERE]");
    try expectFailure(&dispatcher, "speed 3", error.InvalidArgument, "Float must not be more than 2.5 at position 6: speed <--[HERE]");
    try expectFailure(&dispatcher, "speed -1", error.InvalidArgument, "Float must not be less than 0 at position 6: speed <--[HERE]");
    try expectFailure(&dispatcher, "quote \"open", error.InvalidArgument, "Unclosed quoted string at position 11: ...uote \"open<--[HERE]");
    try expectFailure(&dispatcher, "quote \"a\\b\"", error.InvalidArgument, "Invalid escape sequence in quoted string at position 9: quote \"a\\<--[HERE]");
}

test "requirements hide nodes from the sources that cannot use them" {
    var dispatcher = Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    const stop = try dispatcher.literal(.root, "stop", .{ .requires = isOp, .executes = whoami });
    _ = try dispatcher.argument(stop, "reason", commands.greedy, .{ .executes = echo });
    _ = try dispatcher.literal(.root, "status", .{ .executes = whoami });
    var log: Log = .{};
    const player: Source = .{ .log = &log, .name = "player", .op = false };
    try testing.expectError(error.UnknownCommand, dispatcher.execute("stop", player, null));
    try testing.expectEqual(@as(usize, 1), try dispatcher.execute("stop now", .{ .log = &log }, null));
    try expectSuggestions(&dispatcher, "st", player, &.{"status"});
    try expectSuggestions(&dispatcher, "st", .{ .log = &log }, &.{ "status", "stop" });

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try dispatcher.usage(&writer, .root, player);
    try testing.expectEqualStrings("status\n", writer.buffered());
}

test "redirects chain commands, and forks run the rest once for each source" {
    var dispatcher = Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    try sample(&dispatcher);
    try expectRun(&dispatcher, "execute run whoami", 1, "console;");
    try expectRun(&dispatcher, "execute as bob run whoami", 1, "bob;");
    try expectRun(&dispatcher, "execute as bob as alice run whoami", 1, "alice;");
    try expectRun(&dispatcher, "execute run execute run execute as bob run tp 1 2 3", 1, "1 2 3;");
    try expectRun(&dispatcher, "execute each a,b,c run whoami", 3, "a;b;c;");
    try expectRun(&dispatcher, "execute each a,b as x run whoami", 2, "x;x;");
    try expectRun(&dispatcher, "execute each a,fail,c run check", 2, "a;c;");
    try expectRun(&dispatcher, "execute each a,nobody,c as nobody run whoami", 0, "");
    try expectRun(&dispatcher, "execute each a,b each c,d run whoami", 4, "c;d;c;d;");

    var log: Log = .{};
    try testing.expectError(error.NoSuchPlayer, dispatcher.execute("execute as nobody run whoami", .{ .log = &log }, null));
    try testing.expectError(error.Failed, dispatcher.execute("execute as fail run check", .{ .log = &log }, null));
}

test "a context holds the arguments parsed since the last redirect" {
    const Check = struct {
        fn run(ctx: *const Context) !void {
            try testing.expectEqual(@as(?[]const u8, null), ctx.optional([]const u8, "name"));
            try testing.expectEqualStrings("say hi", ctx.text());
            try testing.expectEqualStrings("hi", ctx.argument([]const u8, "message"));
            ctx.source.log.print("{s};", .{ctx.source.name});
        }
    };
    var dispatcher = Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    try sample(&dispatcher);
    try dispatcher.configure(dispatcher.find(&.{ "say", "message" }).?, .{ .executes = Check.run });
    try expectRun(&dispatcher, "execute as bob run say hi", 1, "bob;");
}

test "a parse runs later, from where it was parsed into" {
    var dispatcher = Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    try sample(&dispatcher);
    var log: Log = .{};
    var buffer: [256]u8 = undefined;
    const parsed = try dispatcher.parse("execute each a,b run say \"x\\\"y\"", .{ .log = &log }, &buffer, null);
    try testing.expectEqual(@as(usize, 2), try parsed.execute());
    try testing.expectEqual(@as(usize, 2), try parsed.execute());
    try testing.expectEqualStrings("say \"x\\\"y\";say \"x\\\"y\";say \"x\\\"y\";say \"x\\\"y\";", log.text());

    var small: [48]u8 = undefined;
    var diagnostics: commands.Diagnostics = .{};
    try testing.expectError(error.NoSpaceLeft, dispatcher.parse("execute run execute run execute run whoami", .{ .log = &log }, &small, &diagnostics));
    try testing.expectError(error.NoSpaceLeft, @as(anyerror!void, diagnostics.err));
}

const Player = struct {
    pub const Value = []const u8;

    pub fn parse(_: *const Player, reader: *Reader, source: Source) ![]const u8 {
        const start = reader.cursor;
        const name = reader.readWord();
        if (std.mem.eql(u8, name, source.name) or std.mem.eql(u8, name, "alice")) return name;
        reader.cursor = start;
        return error.UnknownPlayer;
    }

    pub fn suggest(_: *const Player, builder: *commands.SuggestionBuilder) !void {
        try builder.addTooltip("alice", "online");
        try builder.addTooltip("albert", "away");
    }

    pub fn describe(_: *const Player, err: anyerror, writer: *std.Io.Writer) std.Io.Writer.Error!bool {
        if (err != error.UnknownPlayer) return false;
        try writer.writeAll("No player was found");
        return true;
    }
};

test "an argument type can check its text against the source" {
    var dispatcher = Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    const msg = try dispatcher.literal(.root, "msg", .{});
    const to = try dispatcher.argument(msg, "to", Player{}, .{});
    _ = try dispatcher.argument(to, "text", commands.greedy, .{ .executes = echo });
    try expectRun(&dispatcher, "msg alice hello", 1, "msg alice hello;");
    try expectRun(&dispatcher, "msg console hello", 1, "msg console hello;");
    try expectFailure(&dispatcher, "msg bob hello", error.InvalidArgument, "No player was found at position 4: msg <--[HERE]");

    var log: Log = .{};
    var suggestions = try dispatcher.suggest(testing.allocator, "msg al", .{ .log = &log });
    defer suggestions.deinit();
    try testing.expectEqual(@as(usize, 2), suggestions.items.len);
    try testing.expectEqualDeep(commands.Suggestion{ .start = 4, .end = 6, .text = "albert", .tooltip = "away" }, suggestions.items[0]);
    try testing.expectEqualDeep(commands.Suggestion{ .start = 4, .end = 6, .text = "alice", .tooltip = "online" }, suggestions.items[1]);
}

test "suggestions complete what is being typed" {
    const Fruit = enum { apple, pear };
    const Varieties = struct {
        fn suggest(ctx: *const Context, builder: *commands.SuggestionBuilder) !void {
            const names: []const []const u8 = switch (ctx.argument(Fruit, "fruit")) {
                .apple => &.{ "Granny Smith", "Gala" },
                .pear => &.{"Conference"},
            };
            for (names) |name| try builder.add(name);
        }
    };
    var dispatcher = Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    try sample(&dispatcher);
    const pick = try dispatcher.literal(.root, "pick", .{});
    const fruit = try dispatcher.argument(pick, "fruit", Fruit, .{});
    _ = try dispatcher.argument(fruit, "variety", commands.greedy, .{ .suggests = Varieties.suggest, .executes = echo });
    const toggle = try dispatcher.literal(.root, "toggle", .{});
    _ = try dispatcher.argument(toggle, "on", bool, .{ .executes = echo });

    var log: Log = .{};
    const source: Source = .{ .log = &log };
    try expectSuggestions(&dispatcher, "", source, &.{ "check", "execute", "fail", "give", "pick", "say", "toggle", "tp", "whoami" });
    try expectSuggestions(&dispatcher, "T", source, &.{ "toggle", "tp" });
    try expectSuggestions(&dispatcher, "tp", source, &.{});
    try expectSuggestions(&dispatcher, "execute ", source, &.{ "as", "each", "run" });
    try expectSuggestions(&dispatcher, "execute as bob run w", source, &.{"whoami"});
    try expectSuggestions(&dispatcher, "execute each a,b ", source, &.{ "as", "each", "run" });
    try expectSuggestions(&dispatcher, "pick ", source, &.{ "apple", "pear" });
    try expectSuggestions(&dispatcher, "pick p", source, &.{"pear"});
    try expectSuggestions(&dispatcher, "pick apple ", source, &.{ "Gala", "Granny Smith" });
    try expectSuggestions(&dispatcher, "pick apple gr", source, &.{"Granny Smith"});
    try expectSuggestions(&dispatcher, "pick apple Granny S", source, &.{"Granny Smith"});
    try expectSuggestions(&dispatcher, "pick pear ", source, &.{"Conference"});
    try expectSuggestions(&dispatcher, "toggle ", source, &.{ "false", "true" });
    try expectSuggestions(&dispatcher, "nope ", source, &.{});

    var suggestions = try dispatcher.suggest(testing.allocator, "execute as bob run gi", source);
    defer suggestions.deinit();
    try testing.expectEqualDeep(commands.Suggestion{ .start = 19, .end = 21, .text = "give" }, suggestions.items[0]);
}

test "usage writes how to go on from a node" {
    var dispatcher = Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    const a = try dispatcher.literal(.root, "a", .{ .executes = whoami });
    _ = try dispatcher.literal(a, "b", .{ .executes = whoami });
    const c = try dispatcher.literal(.root, "c", .{});
    const x = try dispatcher.argument(c, "x", i32, .{});
    _ = try dispatcher.argument(x, "y", i32, .{ .executes = whoami });
    const d = try dispatcher.literal(.root, "d", .{});
    _ = try dispatcher.literal(d, "e", .{ .executes = whoami });
    _ = try dispatcher.literal(d, "f", .{ .executes = whoami });
    _ = try dispatcher.literal(.root, "r", .{ .redirect = .to(.root) });
    _ = try dispatcher.literal(.root, "s", .{ .redirect = .to(d) });

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try dispatcher.usage(&writer, .root, .{ .log = undefined });
    try testing.expectEqualStrings("a [b]\nc <x> <y>\nd (e|f)\nr ...\ns -> d\n", writer.buffered());

    writer = .fixed(&buffer);
    try dispatcher.usage(&writer, a, .{ .log = undefined });
    try testing.expectEqualStrings("[b]\n", writer.buffered());

    writer = .fixed(&buffer);
    try dispatcher.allUsage(&writer, .root, .{ .log = undefined });
    try testing.expectEqualStrings("a\na b\nc <x> <y>\nd e\nd f\nr ...\ns -> d\n", writer.buffered());
}

test "registering merges what is there and rejects what cannot work" {
    var dispatcher = Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    const tp = try dispatcher.literal(.root, "tp", .{});
    try testing.expectEqual(tp, try dispatcher.literal(.root, "tp", .{ .executes = whoami }));
    try expectRun(&dispatcher, "tp", 1, "console;");
    const x = try dispatcher.argument(tp, "x", i32, .{});
    try testing.expectEqual(x, try dispatcher.argument(tp, "x", commands.integer(i32, .{ .min = 0 }), .{}));
    try testing.expectError(error.Conflict, dispatcher.argument(tp, "x", f32, .{}));
    try testing.expectError(error.InvalidName, dispatcher.literal(.root, "", .{}));
    try testing.expectError(error.InvalidName, dispatcher.literal(.root, "a b", .{}));
    const run = try dispatcher.literal(.root, "run", .{ .redirect = .to(.root) });
    try testing.expectError(error.Redirected, dispatcher.literal(run, "more", .{}));
    try testing.expectError(error.Redirected, dispatcher.configure(tp, .{ .redirect = .to(.root) }));
}

test "the graph can be walked and described" {
    var dispatcher = Dispatcher.init(testing.allocator);
    defer dispatcher.deinit();
    try testing.expectEqual(@as(?commands.Node, null), dispatcher.find(&.{"tp"}));
    var empty = dispatcher.children(.root);
    try testing.expectEqual(@as(?commands.Node, null), empty.next());
    try sample(&dispatcher);
    const z = dispatcher.find(&.{ "tp", "x", "y", "z" }).?;
    const info = dispatcher.info(z);
    try testing.expectEqualStrings("z", info.name);
    try testing.expectEqualStrings("f64", info.argument.?);
    try testing.expect(info.executes);
    try testing.expectEqual(dispatcher.find(&.{ "tp", "x", "y" }).?, info.parent);
    try testing.expectEqual(dispatcher.find(&.{"execute"}), dispatcher.info(dispatcher.find(&.{ "execute", "as", "name" }).?).redirect);

    var names: [8][]const u8 = undefined;
    var count: usize = 0;
    var children = dispatcher.children(dispatcher.find(&.{"tp"}).?);
    while (children.next()) |node| : (count += 1) names[count] = dispatcher.info(node).name;
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "x", "target" }), names[0..count]);
}

test "commands run from many threads at once" {
    const Counter = std.atomic.Value(u64);
    const Shared = commands.Dispatcher(*Counter);
    const Worker = struct {
        fn add(ctx: *const Shared.Context) !void {
            _ = ctx.source.fetchAdd(ctx.argument(u32, "amount"), .monotonic);
        }

        fn run(dispatcher: *const Shared, counter: *Counter, failures: *std.atomic.Value(u32)) void {
            var buffer: [64]u8 = undefined;
            for (0..1000) |i| {
                const input = std.fmt.bufPrint(&buffer, "add {d}", .{i % 3}) catch unreachable;
                _ = dispatcher.execute(input, counter, null) catch {
                    _ = failures.fetchAdd(1, .monotonic);
                };
                var suggestions = dispatcher.suggest(testing.allocator, "a", counter) catch {
                    _ = failures.fetchAdd(1, .monotonic);
                    continue;
                };
                suggestions.deinit();
            }
        }
    };
    var dispatcher = Shared.init(testing.allocator);
    defer dispatcher.deinit();
    const add = try dispatcher.literal(.root, "add", .{});
    _ = try dispatcher.argument(add, "amount", u32, .{ .executes = Worker.add });

    var counter: Counter = .init(0);
    var failures: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    for (0..8) |_| group.concurrent(testing.io, Worker.run, .{ &dispatcher, &counter, &failures }) catch Worker.run(&dispatcher, &counter, &failures);
    try group.await(testing.io);
    try testing.expectEqual(@as(u32, 0), failures.load(.monotonic));
    try testing.expectEqual(@as(u64, 8 * 999), counter.load(.monotonic));
}

test "the reader reads numbers, words and quoted strings" {
    var reader = Reader.init("-12 3.5 word 'it\\'s' \"open");
    try testing.expectEqual(@as(i32, -12), try reader.readInt(i32));
    reader.skipWhitespace();
    try testing.expectEqual(@as(f64, 3.5), try reader.readFloat(f64));
    reader.skipWhitespace();
    try testing.expectEqualStrings("word", reader.readWord());
    reader.skipWhitespace();
    try testing.expectError(error.NoSpaceLeft, reader.readQuoted());

    var bytes: [16]u8 = undefined;
    var space: Reader.Space = .init(&bytes);
    reader.space = &space;
    try testing.expectEqualStrings("it's", try reader.readQuoted());
    reader.skipWhitespace();
    try testing.expectError(error.ExpectedEndOfQuote, reader.readQuoted());
    try testing.expect(reader.atEnd());

    reader = .init("--1 x");
    try testing.expectError(error.InvalidInteger, reader.readInt(i32));
    try testing.expectEqual(@as(usize, 0), reader.cursor);
}

test "numbers read in one pass agree with std.fmt" {
    const texts = [_][]const u8{ "0", "-0", "7", "-7", "0.1", "0.3", "-2.5", ".5", "5.", "123456789012345", "1234567.1", "1234567.89", "9007199254740993", "0.000001", "1.7976931348623157", "999999999999999999", "18446744073709551615", "-9223372036854775808" };
    for (texts) |text| {
        inline for (.{ f32, f64 }) |F| {
            var reader = Reader.init(text);
            const expected = try std.fmt.parseFloat(F, text);
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(F));
            try testing.expectEqual(@as(Bits, @bitCast(expected)), @as(Bits, @bitCast(try reader.readFloat(F))));
        }
        inline for (.{ u8, i32, u64, i64 }) |I| {
            var reader = Reader.init(text);
            if (std.fmt.parseInt(I, text, 10)) |expected| {
                try testing.expectEqual(expected, try reader.readInt(I));
            } else |_| {
                try testing.expectError(error.InvalidInteger, reader.readInt(I));
            }
        }
    }
    for ([_][]const u8{ "-", ".", "1-2", "1..2", "--1" }) |text| {
        var reader = Reader.init(text);
        try testing.expectError(error.InvalidFloat, reader.readFloat(f64));
        reader = .init(text);
        try testing.expectError(error.InvalidInteger, reader.readInt(i32));
    }
}
