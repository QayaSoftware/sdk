const std = @import("std");
const logging = @import("logging");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn(.{}),
};

/// Each benchmark logs through its own logger, called directly.
const Filtered = logging.Logger(.{ .terminal = null, .level = .info, .memory = 1024 });
const Memory = logging.Logger(.{ .terminal = null, .memory = 256 * 1024, .collapse_repeats = false });
const Collapsing = logging.Logger(.{ .terminal = null, .memory = 256 * 1024 });
const Detailed = logging.Logger(.{ .terminal = null, .memory = 256 * 1024, .memory_decorations = .detailed, .collapse_repeats = false });
const Json = logging.Logger(.{ .terminal = null, .file = .{ .target = .{ .path = ".zig-cache/logging-performance/json.log" }, .append = false, .format = .json }, .collapse_repeats = false });
const FileOnly = logging.Logger(.{ .terminal = null, .file = .{ .target = .{ .path = ".zig-cache/logging-performance/text.log" }, .append = false }, .collapse_repeats = false });
const Heard = logging.Logger(.{ .terminal = null, .collapse_repeats = false });
const Shared = logging.Logger(.{ .terminal = null, .memory = 256 * 1024, .collapse_repeats = false, .message_buffer = 2049 });

const Count = struct {
    listener: logging.Listener = .{ .call = hear },
    count: u64 = 0,

    fn hear(listener: *logging.Listener, record: *const logging.Record) void {
        const self: *Count = @fieldParentPtr("listener", listener);
        self.count += record.message.len;
    }
};

fn elapsed(io: std.Io, since: std.Io.Timestamp) i96 {
    return std.Io.Clock.now(.awake, io).nanoseconds - since.nanoseconds;
}

fn row(name: []const u8, n: usize, ns: i96) void {
    const per: f64 = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
    std.debug.print("{s:<44} {d:>9} {d:>9.1} ns/record {d:>12.0} records/s\n", .{ name, n, per, 1e9 / per });
}

fn bench(comptime L: type, io: std.Io, name: []const u8, n: usize) void {
    const start = std.Io.Clock.now(.awake, io);
    for (0..n) |i| L.log(.info, .render, "frame {d} drew {d} meshes in {d:.2} ms", .{ i, i % 977, @as(f64, @floatFromInt(i % 100)) * 0.13 });
    L.flush();
    row(name, n, elapsed(io, start));
}

fn worker(n: usize) void {
    for (0..n) |i| Shared.log(.info, .worker, "job {d} done", .{i});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    defer args.deinit();
    _ = args.next();
    const n = if (args.next()) |text| try std.fmt.parseUnsigned(usize, text, 10) else 1_000_000;

    std.debug.print(
        \\records per benchmark: {d}  (pass a number to change it, e.g. zig build logging-performance -- 5000000)
        \\use ReleaseFast for meaningful numbers: zig build logging-performance -Doptimize=ReleaseFast
        \\
        \\
    , .{n});

    {
        const start = std.Io.Clock.now(.awake, io);
        for (0..n) |i| Filtered.log(.debug, .render, "frame {d}", .{i});
        row("left out by the runtime level", n, elapsed(io, start));
    }
    bench(Memory, io, "memory ring, compact", n);
    bench(Detailed, io, "memory ring, detailed (date, thread, frame)", n);
    {
        const start = std.Io.Clock.now(.awake, io);
        for (0..n) |_| Collapsing.log(.warn, .physics, "body 7 fell out of the world", .{});
        Collapsing.flush();
        row("the same record again, collapsed", n, elapsed(io, start));
    }
    bench(FileOnly, io, "file, detailed text, 64 KiB buffer", n);
    bench(Json, io, "file, json", n);
    {
        var count: Count = .{};
        logging.listen(&count.listener);
        defer logging.unlisten(&count.listener);
        bench(Heard, io, "listener only", n);
    }

    std.debug.print("\n", .{});
    for ([_]usize{ 1, 2, 4, 8 }) |tasks| {
        const per_task = n / tasks;
        var group: std.Io.Group = .init;
        const start = std.Io.Clock.now(.awake, io);
        for (0..tasks) |_| group.concurrent(io, worker, .{per_task}) catch worker(per_task);
        try group.await(io);
        var name: [64]u8 = undefined;
        row(try std.fmt.bufPrint(&name, "memory ring, {d} tasks at once", .{tasks}), per_task * tasks, elapsed(io, start));
    }
}
