const std = @import("std");
const commands = @import("commands");

/// One connection's player: only its own task changes it.
const Player = struct {
    id: usize,
    score: u64 = 0,
};

/// What every task shares: it only changes through atomics.
const Server = struct {
    total: std.atomic.Value(u64) = .init(0),
};

const Source = struct {
    server: *Server,
    player: *Player,
};

const Dispatcher = commands.Dispatcher(Source);
const Context = Dispatcher.Context;

fn score(ctx: *const Context) !void {
    const points = ctx.argument(u32, "points");
    ctx.source.player.score += points;
    _ = ctx.source.server.total.fetchAdd(points, .monotonic);
}

/// A connection: its own source, its own commands, one shared dispatcher.
fn connection(dispatcher: *const Dispatcher, server: *Server, player: *Player, commands_run: u32) void {
    var line: [32]u8 = undefined;
    for (0..commands_run) |i| {
        const input = std.fmt.bufPrint(&line, "score {d}", .{i % 10}) catch unreachable;
        _ = dispatcher.execute(input, .{ .server = server, .player = player }, null) catch unreachable;
    }
}

/// Commands parsed on a connection's thread, to run on the main one.
const Pending = struct {
    mutex: std.Io.Mutex = .init,
    parses: std.ArrayList(Dispatcher.Parse) = .empty,
};

/// Parses on its own thread, so a bad command is caught where it was sent,
/// and leaves the running to the main thread. The input and buffer outlive
/// the parse, so it can cross threads.
fn submit(io: std.Io, gpa: std.mem.Allocator, dispatcher: *const Dispatcher, pending: *Pending, source: Source, input: []const u8, buffer: []u8) void {
    var diagnostics: commands.Diagnostics = .{};
    const parsed = dispatcher.parse(input, source, buffer, &diagnostics) catch {
        std.debug.print("rejected on its thread: {f}\n", .{diagnostics});
        return;
    };
    pending.mutex.lockUncancelable(io);
    defer pending.mutex.unlock(io);
    pending.parses.append(gpa, parsed) catch @panic("OOM");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var dispatcher = Dispatcher.init(gpa);
    defer dispatcher.deinit();
    const score_node = try dispatcher.literal(.root, "score", .{});
    _ = try dispatcher.argument(score_node, "points", commands.integer(u32, .{ .max = 100 }), .{ .executes = score });

    var server: Server = .{};
    var players: [16]Player = undefined;
    for (&players, 0..) |*player, id| player.* = .{ .id = id };

    const per_connection = 100_000;
    var group: std.Io.Group = .init;
    for (&players) |*player| {
        group.concurrent(io, connection, .{ &dispatcher, &server, player, per_connection }) catch connection(&dispatcher, &server, player, per_connection);
    }
    try group.await(io);
    var sum: u64 = 0;
    for (players) |player| sum += player.score;
    std.debug.print("{d} connections ran {d} commands at once: total {d} (expect {d}), players' scores add to {d}\n", .{
        players.len,
        players.len * per_connection,
        server.total.load(.monotonic),
        players.len * (per_connection / 10) * 45,
        sum,
    });

    var pending: Pending = .{};
    defer pending.parses.deinit(gpa);
    const inputs = [_][]const u8{ "score 7", "score 1000", "score 3", "scroe 1" };
    var buffers: [inputs.len][256]u8 = undefined;
    var submits: std.Io.Group = .init;
    for (inputs, &buffers, 0..) |input, *buffer, i| {
        const source: Source = .{ .server = &server, .player = &players[i] };
        submits.concurrent(io, submit, .{ io, gpa, &dispatcher, &pending, source, input, buffer }) catch submit(io, gpa, &dispatcher, &pending, source, input, buffer);
    }
    try submits.await(io);
    const before = server.total.load(.monotonic);
    for (pending.parses.items) |parsed| _ = try parsed.execute();
    std.debug.print("the main thread ran the {d} commands that parsed, adding {d} (expect 10)\n", .{ pending.parses.items.len, server.total.load(.monotonic) - before });
}
