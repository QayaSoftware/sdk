//! Logging for std.log: `logFn` makes the function for `std_options.logFn`,
//! writing each record to the terminal, a file or a directory of them, and
//! memory, decorated as asked. It needs no setup, holds no allocator and
//! writes through std.debug's Io, so it works from the first line of `main`
//! to a panic.
//!
//!     pub const std_options: std.Options = .{
//!         .log_level = .debug,
//!         .logFn = logging.logFn(.{ .file = .{ .target = .{ .directory = "logs" } } }),
//!     };
//!
//! A message is formatted once, on the logging thread, before the lock that
//! writes it to the sinks is taken. Levels can change at runtime for every
//! scope or one, even by name from a console; frames, thread names,
//! listeners, repeat collapsing, `once`, `throttled` and `Timer` are there
//! for engines, and `panic` writes the panic to the file before dying.
const std = @import("std");
const Writer = std.Io.Writer;

const core = @import("core.zig");
const format = @import("format.zig");
const logger = @import("logger.zig");

pub const Level = std.log.Level;
pub const levelText = format.levelText;
pub const Record = format.Record;
pub const Decorations = format.Decorations;
pub const Time = format.Time;
pub const LevelLabel = format.LevelLabel;
pub const Theme = format.Theme;
pub const Format = format.Format;
pub const Config = logger.Config;
pub const Terminal = logger.Terminal;
pub const Color = logger.Color;
pub const File = logger.File;
pub const Target = core.Target;
pub const Listener = core.Listener;
pub const Stats = core.Stats;
pub const LevelError = core.LevelError;
pub const SetFileError = core.SetFileError;

/// A logger made from `config`: its `log` is what `logFn` returns, and it
/// has its own `flush`, `writeRecent`, `setFile`, `once` and `throttled`.
pub const Logger = logger.Logger;

/// The function for `std_options.logFn`, logging as `config` says.
pub fn logFn(comptime config: Config) @TypeOf(std.log.defaultLog) {
    return Logger(config).log;
}

/// Sets the frame records are stamped with.
pub fn setFrame(number: u64) void {
    core.frame.store(number, .monotonic);
}

pub fn frame() u64 {
    return core.frame.load(.monotonic);
}

/// Names the calling thread in its records, or with null numbers it again;
/// `name` must last as long as the thread logs, as a literal does.
pub fn nameThread(name: ?[]const u8) void {
    core.thread_name = name;
}

/// Sets the most detailed level `scope` logs; null gives it the default
/// level again.
pub fn setLevel(comptime scope: @EnumLiteral(), level: ?Level) void {
    const state = &core.ScopeOf(scope).state;
    if (!state.registered.load(.acquire)) core.register(state);
    state.level.store(if (level) |l| @intFromEnum(l) else core.inherit, .monotonic);
}

/// The level set for `scope`, or null when it has the default level.
pub fn levelOf(comptime scope: @EnumLiteral()) ?Level {
    return core.toLevel(core.ScopeOf(scope).state.level.load(.monotonic));
}

/// Sets the level of the scope named `name`, as a console command would;
/// a scope that has not logged yet gets it when it first does.
pub fn setLevelByName(name: []const u8, level: ?Level) LevelError!void {
    return core.setLevelByName(name, level);
}

pub fn levelOfName(name: []const u8) ?Level {
    return core.levelOfName(name);
}

/// Sets the most detailed level of every scope without its own; null gives
/// each logger the level its configuration says again.
pub fn setDefaultLevel(level: ?Level) void {
    core.default_level.store(if (level) |l| @intFromEnum(l) else core.inherit, .monotonic);
}

pub fn defaultLevel() ?Level {
    return core.toLevel(core.default_level.load(.monotonic));
}

/// The names of the scopes that have logged, copied into `buffer`, for a
/// console to complete.
pub fn scopeNames(buffer: [][]const u8) []const []const u8 {
    return core.scopeNames(buffer);
}

/// Calls `listener` with every record, with the logger's lock held: keep it
/// quick, such as by queueing the record's text. Records it logs reach the
/// sinks but no listener.
pub fn listen(listener: *Listener) void {
    core.listen(listener);
}

pub fn unlisten(listener: *Listener) void {
    core.unlisten(listener);
}

/// Writes out every file sink's buffer, and any counts of repeats.
pub fn flush() void {
    const locked = core.lock();
    defer core.unlock(locked);
    var instance = core.firstInstance();
    while (instance) |found| : (instance = found.next) found.flush(locked);
}

/// Writes the last `max_lines` lines each logger keeps in memory, oldest
/// first, as for a crash report.
pub fn writeRecent(writer: *Writer, max_lines: usize) Writer.Error!void {
    const locked = core.lock();
    defer core.unlock(locked);
    var instance = core.firstInstance();
    while (instance) |found| : (instance = found.next) try found.writeRecent(writer, max_lines);
}

/// Points every file sink at `target`, as when the place for logs is only
/// known at runtime; what they buffered before goes there. Given before
/// anything is logged, the first logger with a file sink opens it.
pub fn setFile(target: Target) SetFileError!void {
    const locked = core.lock();
    defer core.unlock(locked);
    var result: SetFileError!void = {};
    var any = false;
    var instance = core.firstInstance();
    while (instance) |found| : (instance = found.next) {
        if (!found.has_file) continue;
        any = true;
        found.setFile(target) catch |err| {
            result = err;
        };
    }
    if (!any) return core.holdTarget(target);
    return result;
}

/// What logging has written, collapsed, dropped and failed to write.
pub fn stats() Stats {
    const locked = core.lock();
    defer core.unlock(locked);
    return core.stats;
}

/// Logs through std.log only the first time this level, scope and format
/// are logged.
pub fn once(comptime level: Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    if (logger.Once(level, scope, fmt).done.swap(true, .monotonic)) return;
    stdLog(level, scope, fmt, args);
}

/// Logs through std.log at most once every `interval_ms` for this level,
/// scope and format, saying how many were left out since: for a warning
/// that would otherwise come every frame.
pub fn throttled(interval_ms: u32, comptime level: Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    const skipped = logger.Throttle(level, scope, fmt).pass(interval_ms) orelse return;
    if (skipped == 0) stdLog(level, scope, fmt, args) else stdLog(level, scope, fmt ++ " ({d} left out)", args ++ .{skipped});
}

fn stdLog(comptime level: Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    const name = comptime switch (level) {
        .err => "err",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
    @field(std.log.scoped(scope), name)(fmt, args);
}

/// Measures how long something takes, and logs it.
pub const Timer = struct {
    began: i96,

    pub fn start() Timer {
        return .{ .began = core.now(.awake) };
    }

    /// Nanoseconds since `start`.
    pub fn elapsed(self: Timer) u64 {
        return @intCast(@max(core.now(.awake) - self.began, 0));
    }

    /// Logs through std.log with the time since `start` after the message,
    /// as `loaded level.zon (12.3 ms)`.
    pub fn log(self: Timer, comptime level: Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
        stdLog(level, scope, fmt ++ " ({d:.1} ms)", args ++ .{milliseconds(self.elapsed())});
    }
};

/// `ns` nanoseconds in milliseconds.
pub fn milliseconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

threadlocal var panicking = false;

/// Logs a panic at the error level in the scope `panic` to every sink but
/// the terminal, which the default panic writes to, and to listeners;
/// writes out every file; then panics as std.debug does. Use it as
/// `pub const panic = std.debug.FullPanic(logging.panic);`.
pub fn panic(message: []const u8, first_trace_address: ?usize) noreturn {
    @branchHint(.cold);
    if (!panicking) {
        panicking = true;
        const locked = core.lock();
        const record: Record = .{
            .level = .err,
            .scope = "panic",
            .message = message,
            .time = core.now(.real),
            .elapsed = core.sinceStart(core.now(.awake)),
            .frame = core.frame.load(.monotonic),
            .thread = core.thread(),
        };
        var instance = core.firstInstance();
        while (instance) |found| : (instance = found.next) {
            found.flush(locked);
            found.record(&record);
            found.flush(false);
        }
        if (locked) core.notify(&record);
        core.unlock(locked);
    }
    std.debug.defaultPanic(message, first_trace_address);
}

test {
    _ = @import("tests.zig");
}
