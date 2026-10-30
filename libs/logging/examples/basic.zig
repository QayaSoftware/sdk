const std = @import("std");
const logging = @import("logging");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logging.logFn(.{ .level = .info }),
};

const render = std.log.scoped(.render);
const audio = std.log.scoped(.audio);

/// Another logger, writing JSON, called directly rather than through
/// std.log.
const Json = logging.Logger(.{ .terminal = .{ .format = .json }, .collapse_repeats = false });

/// One more, as std.log's own default would write, with the time of day.
const Classic = logging.Logger(.{ .terminal = .{ .format = .{ .text = .{ .time = .clock, .level = .word } } }, .collapse_repeats = false });

pub fn main() !void {
    std.log.info("hello from the default scope", .{});
    render.info("loaded {d} meshes in {d:.1} ms", .{ 12, 3.25 });
    render.debug("left out: the configured level is info", .{});
    audio.warn("device busy, retrying", .{});
    std.log.err("could not open the save: {t}", .{error.FileNotFound});

    logging.setLevel(.render, .debug);
    render.debug("shown now that render logs debug", .{});
    try logging.setLevelByName("audio", .err);
    audio.warn("left out: audio logs errors only", .{});

    for (0..5) |_| render.info("the same line, over and over", .{});
    render.info("something else, which ends the run of repeats", .{});

    Json.log(.info, .render, "drew \"frame\" {d}", .{1});
    Classic.log(.warn, .net, "ping {d} ms", .{180});
}
