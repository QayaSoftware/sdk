const std = @import("std");
const cli = @import("cli");

const Options = struct {
    port: u16 = 8080,
    host: []const u8 = "127.0.0.1",
    log: Log = .info,
    verbose: u8 = 0,
    workers: ?u32 = null,
    allow: []const []const u8 = &.{},
    token: []const u8,
    tls: Tls = .{},
    root: []const u8 = ".",

    const Log = enum { quiet, info, debug };

    const Tls = struct {
        cert: ?[]const u8 = null,
        key: ?[]const u8 = null,
    };

    pub const description = "Serves a directory over HTTP.";
    pub const meta = .{
        .port = .{ .short = 'p', .help = "Port to listen on" },
        .host = .{ .help = "Address to listen on" },
        .log = .{ .help = "How much to log" },
        .verbose = .{ .short = 'v', .count = true, .help = "Log more, more for each" },
        .workers = .{ .short = 'j', .help = "Worker threads; one per core unless set" },
        .allow = .{ .short = 'a', .value_name = "ORIGIN", .help = "Origins allowed to fetch" },
        .token = .{ .help = "Secret that requests must carry", .env = "DEMO_TOKEN" },
        .tls = .{},
        .root = .{ .positional = true, .help = "The directory to serve" },
    };
};

pub fn main(init: std.process.Init) !void {
    const options = cli.parseProcess(Options, init, .{ .env_prefix = "DEMO_" });
    std.debug.print(
        \\serving {s} on {s}:{d}
        \\  log {t}, verbosity {d}, workers {?d}
        \\  allowed origins: {d}
        \\  token: {d} bytes
        \\  tls: {s}
        \\
    , .{
        options.root,
        options.host,
        options.port,
        options.log,
        options.verbose,
        options.workers,
        options.allow.len,
        options.token.len,
        if (options.tls.cert != null and options.tls.key != null) "on" else "off",
    });
}
