const std = @import("std");
const commands = @import("commands");

const Player = struct {
    name: []const u8,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
    diamonds: u32 = 0,
    op: bool = false,
};

const Server = struct {
    players: []Player,

    fn find(self: *const Server, name: []const u8) ?*Player {
        for (self.players) |*player| if (std.mem.eql(u8, player.name, name)) return player;
        return null;
    }
};

/// Who a command runs for: a player, or the console.
const Source = struct {
    server: *Server,
    player: ?*Player = null,

    fn name(self: Source) []const u8 {
        return if (self.player) |player| player.name else "console";
    }
};

const Dispatcher = commands.Dispatcher(Source);
const Context = Dispatcher.Context;

const Selector = union(enum) { all, self, name: []const u8 };

/// A player's name, `@s` for the source's own player, or `@a` for everyone.
const Targets = struct {
    pub const Value = Selector;

    pub fn parse(_: *const Targets, reader: *commands.Reader, source: Source) !Selector {
        const start = reader.cursor;
        const text = reader.readWord();
        if (std.mem.eql(u8, text, "@a")) return .all;
        if (std.mem.eql(u8, text, "@s")) {
            if (source.player != null) return .self;
            reader.cursor = start;
            return error.NotAPlayer;
        }
        if (source.server.find(text) != null) return .{ .name = text };
        reader.cursor = start;
        return error.UnknownPlayer;
    }

    pub fn describe(_: *const Targets, err: anyerror, writer: *std.Io.Writer) std.Io.Writer.Error!bool {
        try writer.writeAll(switch (err) {
            error.NotAPlayer => "Only a player is @s",
            error.UnknownPlayer => "No player was found",
            else => return false,
        });
        return true;
    }
};

/// Calls `each` for every player `selector` picks.
fn forTargets(ctx: *const Context, selector: Selector, each: anytype) !void {
    switch (selector) {
        .all => for (ctx.source.server.players) |*player| try each.run(player),
        .self => try each.run(ctx.source.player.?),
        .name => |name| try each.run(ctx.source.server.find(name).?),
    }
}

fn suggestTargets(ctx: *const Context, builder: *commands.SuggestionBuilder) !void {
    try builder.addTooltip("@a", "every player");
    if (ctx.source.player != null) try builder.addTooltip("@s", "yourself");
    for (ctx.source.server.players) |player| try builder.add(player.name);
}

fn isOp(source: Source) bool {
    return if (source.player) |player| player.op else true;
}

fn list(ctx: *const Context) !void {
    for (ctx.source.server.players) |player| {
        std.debug.print("  {s} at {d} {d} {d} with {d} diamonds\n", .{ player.name, player.x, player.y, player.z, player.diamonds });
    }
}

fn teleport(ctx: *const Context) !void {
    const Move = struct {
        x: f64,
        y: f64,
        z: f64,
        fn run(self: @This(), player: *Player) !void {
            player.x = self.x;
            player.y = self.y;
            player.z = self.z;
            std.debug.print("  teleported {s} to {d} {d} {d}\n", .{ player.name, self.x, self.y, self.z });
        }
    };
    const move: Move = .{ .x = ctx.argument(f64, "x"), .y = ctx.argument(f64, "y"), .z = ctx.argument(f64, "z") };
    const selector = ctx.optional(Selector, "targets") orelse Selector.self;
    if (selector == .self and ctx.source.player == null) return error.NotAPlayer;
    try forTargets(ctx, selector, move);
}

fn give(ctx: *const Context) !void {
    const Give = struct {
        count: u32,
        fn run(self: @This(), player: *Player) !void {
            player.diamonds += self.count;
            std.debug.print("  gave {s} {d} diamonds\n", .{ player.name, self.count });
        }
    };
    try forTargets(ctx, ctx.argument(Selector, "targets"), Give{ .count = ctx.optional(u32, "count") orelse 1 });
}

fn say(ctx: *const Context) !void {
    std.debug.print("  <{s}> {s}\n", .{ ctx.source.name(), ctx.argument([]const u8, "message") });
}

/// Runs the rest of `execute as <targets> ...` once for each target, as
/// that player.
fn asTargets(ctx: *const Context, sources: *Dispatcher.Sources) !void {
    const Add = struct {
        sources: *Dispatcher.Sources,
        server: *Server,
        fn run(self: @This(), player: *Player) !void {
            self.sources.add(.{ .server = self.server, .player = player });
        }
    };
    try forTargets(ctx, ctx.argument(Selector, "targets"), Add{ .sources = sources, .server = ctx.source.server });
}

fn help(ctx: *const Context) !void {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try ctx.dispatcher.usage(&writer, .root, ctx.source);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, writer.buffered(), "\n"), '\n');
    while (lines.next()) |line| std.debug.print("  /{s}\n", .{line});
}

fn register(dispatcher: *Dispatcher) !void {
    _ = try dispatcher.literal(.root, "help", .{ .executes = help });
    _ = try dispatcher.literal(.root, "list", .{ .executes = list });

    const say_node = try dispatcher.literal(.root, "say", .{});
    _ = try dispatcher.argument(say_node, "message", commands.greedy, .{ .executes = say });

    const tp = try dispatcher.literal(.root, "tp", .{ .requires = isOp });
    const targets = try dispatcher.argument(tp, "targets", Targets{}, .{ .suggests = suggestTargets });
    for ([_]commands.Node{ tp, targets }) |from| {
        const x = try dispatcher.argument(from, "x", f64, .{});
        const y = try dispatcher.argument(x, "y", f64, .{});
        _ = try dispatcher.argument(y, "z", f64, .{ .executes = teleport });
    }

    const give_node = try dispatcher.literal(.root, "give", .{ .requires = isOp });
    const receivers = try dispatcher.argument(give_node, "targets", Targets{}, .{ .suggests = suggestTargets, .executes = give });
    _ = try dispatcher.argument(receivers, "count", commands.integer(u32, .{ .min = 1, .max = 64 }), .{ .executes = give });

    const execute = try dispatcher.literal(.root, "execute", .{});
    _ = try dispatcher.literal(execute, "run", .{ .redirect = .to(.root) });
    const as = try dispatcher.literal(execute, "as", .{});
    _ = try dispatcher.argument(as, "targets", Targets{}, .{ .suggests = suggestTargets, .redirect = .fork(execute, asTargets) });
}

fn run(dispatcher: *const Dispatcher, source: Source, input: []const u8) void {
    std.debug.print("{s}> /{s}\n", .{ source.name(), input });
    var diagnostics: commands.Diagnostics = .{};
    const ran = dispatcher.execute(input, source, &diagnostics) catch |err| switch (err) {
        error.UnknownCommand, error.UnknownArgument, error.InvalidArgument, error.IncompleteCommand, error.NoSpaceLeft => {
            std.debug.print("  {f}\n", .{diagnostics});
            return;
        },
        else => {
            std.debug.print("  failed: {t}\n", .{err});
            return;
        },
    };
    if (ran != 1) std.debug.print("  ({d} ran)\n", .{ran});
}

fn complete(dispatcher: *const Dispatcher, gpa: std.mem.Allocator, source: Source, input: []const u8) !void {
    var suggestions = try dispatcher.suggest(gpa, input, source);
    defer suggestions.deinit();
    std.debug.print("{s}> /{s}<tab>:", .{ source.name(), input });
    for (suggestions.items) |suggestion| {
        std.debug.print(" {s}", .{suggestion.text});
        if (suggestion.tooltip) |tooltip| std.debug.print(" ({s})", .{tooltip});
    }
    std.debug.print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var players = [_]Player{ .{ .name = "alice", .op = true }, .{ .name = "bob" }, .{ .name = "carol" } };
    var server: Server = .{ .players = &players };
    const console: Source = .{ .server = &server };
    const alice: Source = .{ .server = &server, .player = &players[0] };
    const bob: Source = .{ .server = &server, .player = &players[1] };

    var dispatcher = Dispatcher.init(gpa);
    defer dispatcher.deinit();
    try register(&dispatcher);

    run(&dispatcher, console, "help");
    run(&dispatcher, bob, "help");
    run(&dispatcher, alice, "tp 10 64 -3.5");
    run(&dispatcher, console, "tp bob 1 2 3");
    run(&dispatcher, console, "give @a 5");
    run(&dispatcher, console, "execute as @a run say hi");
    run(&dispatcher, alice, "execute as bob run execute as carol run give @s 2");
    run(&dispatcher, console, "list");
    run(&dispatcher, bob, "tp 0 0 0");
    run(&dispatcher, console, "give dave 1");
    run(&dispatcher, console, "give bob 100");
    run(&dispatcher, console, "tp @s 1 2 3");
    run(&dispatcher, console, "tp bob 1 2");
    run(&dispatcher, console, "execute as @a run fly");

    std.debug.print("\n", .{});
    try complete(&dispatcher, gpa, bob, "");
    try complete(&dispatcher, gpa, console, "");
    try complete(&dispatcher, gpa, console, "execute ");
    try complete(&dispatcher, gpa, alice, "execute as ");
    try complete(&dispatcher, gpa, alice, "execute as @a run g");
    try complete(&dispatcher, gpa, console, "give c");
}
