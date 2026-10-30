const std = @import("std");
const logging = @import("logging");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn(.{
        .terminal = .{ .format = .{ .text = .{ .thread = true, .frame = true } } },
        .file = .{ .target = .{ .directory = "zig-out/logs" }, .keep = 5 },
        .memory = 16 * 1024,
    }),
};

pub const panic = std.debug.FullPanic(logging.panic);

const loader = std.log.scoped(.loader);
const physics = std.log.scoped(.physics);
const jobs = std.log.scoped(.jobs);

/// An in-game console: it keeps the last lines it hears, for drawing.
const Console = struct {
    listener: logging.Listener = .{ .call = hear },
    lines: [8][96]u8 = undefined,
    lengths: [8]usize = @splat(0),
    next: usize = 0,
    heard: usize = 0,

    fn hear(listener: *logging.Listener, record: *const logging.Record) void {
        const self: *Console = @fieldParentPtr("listener", listener);
        const line = std.fmt.bufPrint(&self.lines[self.next], "{s} {s}: {s}", .{ logging.levelText(record.level), record.scope, record.message }) catch &self.lines[self.next];
        self.lengths[self.next] = line.len;
        self.next = (self.next + 1) % self.lines.len;
        self.heard += 1;
    }
};

const worker_names = [_][]const u8{ "worker 1", "worker 2", "worker 3", "worker 4" };

fn work(index: usize) void {
    logging.nameThread(worker_names[index]);
    for (0..3) |job| jobs.info("finished job {d}", .{job});
}

pub fn main(init: std.process.Init) !void {
    logging.nameThread("main");
    var console: Console = .{};
    logging.listen(&console.listener);
    defer logging.unlisten(&console.listener);

    const timer = logging.Timer.start();
    var checksum: u64 = 0;
    for (0..2_000_000) |i| checksum +%= i *% 2654435761;
    std.mem.doNotOptimizeAway(checksum);
    timer.log(.info, .loader, "loaded {d} assets", .{240});

    for (0..120) |frame| {
        logging.setFrame(frame);
        physics.warn("body 7 fell out of the world", .{});
        logging.throttled(1000, .warn, .render, "frame {d} took too long", .{frame});
        logging.once(.warn, .audio, "no audio device; running silent", .{});
        if (frame == 60) loader.info("halfway there", .{});
    }

    var group: std.Io.Group = .init;
    for (0..worker_names.len) |index| group.concurrent(init.io, work, .{index}) catch work(index);
    try group.await(init.io);
    logging.flush();

    std.debug.print("\nthe console heard {d} records; its last lines:\n", .{console.heard});
    for (0..console.lines.len) |i| {
        const slot = (console.next + i) % console.lines.len;
        if (console.lengths[slot] > 0) std.debug.print("  | {s}\n", .{console.lines[slot][0..console.lengths[slot]]});
    }
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try logging.writeRecent(&writer, 4);
    std.debug.print("\nthe last 4 lines kept for a crash report:\n{s}", .{writer.buffered()});
    std.debug.print("\nthis run's log is in zig-out/logs; {d} records written\n", .{logging.stats().records});
}
