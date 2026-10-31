//! A logger made from a configuration at compile time: the function
//! std.log calls, and the sinks it writes to.
const std = @import("std");
const Writer = std.Io.Writer;
const Level = std.log.Level;

const core = @import("core.zig");
const format = @import("format.zig");
const sinks = @import("sinks.zig");
const Record = format.Record;
const Format = format.Format;
const Decorations = format.Decorations;

pub const Config = struct {
    /// The most detailed level logged until `setDefaultLevel` or `setLevel`
    /// changes it; `std_options.log_level` leaves out what is more detailed
    /// still, at compile time.
    level: Level = .debug,
    /// Writes each record to stderr as it comes.
    terminal: ?Terminal = .{},
    /// Writes records to a file, or a directory of them, through a buffer.
    file: ?File = null,
    /// How many bytes of recent lines to keep for `writeRecent`.
    memory: usize = 0,
    /// How the lines kept in memory are written.
    memory_decorations: Decorations = .compact,
    /// Writes a record that repeats the one before it only as a count, once
    /// something else is logged, a second has passed, or on `flush`.
    collapse_repeats: bool = true,
    /// How long a message can be before it is formatted again, under the
    /// lock, into `overflow_buffer`.
    message_buffer: usize = 2048,
    /// How long a message can be at all; what is beyond is cut off, marked.
    overflow_buffer: usize = 64 * 1024,
};

pub const Terminal = struct {
    format: Format = .{ .text = .pretty },
    color: Color = .auto,
    theme: format.Theme = .{},
};

pub const Color = enum {
    /// Colors when stderr is a terminal that shows them and `NO_COLOR` is
    /// not set.
    auto,
    always,
    never,
};

pub const File = struct {
    /// Where to write; null until `setFile` says, keeping what comes before
    /// in the buffer.
    target: ?core.Target = null,
    format: Format = .{ .text = .detailed },
    /// For a path: add to what the file holds rather than emptying it.
    append: bool = true,
    /// Starts a new file once one holds this many bytes: the path's earlier
    /// ones are renamed `path.1`, `path.2` and so on, and a directory gets a
    /// new file.
    max_bytes: ?u64 = null,
    /// How many files to keep: the path and its renamed ones, or a
    /// directory's run files.
    keep: usize = 10,
    buffer: usize = 64 * 1024,
    /// Records at or above this level are written out at once.
    flush_level: Level = .warn,
    /// Other records are written out once this long has passed since the
    /// last time.
    flush_interval_ms: u32 = 1000,
};

const truncated = "... [truncated]";

pub fn Logger(comptime config: Config) type {
    if (config.message_buffer < truncated.len or config.overflow_buffer < truncated.len) {
        @compileError("logging: the message and overflow buffers must hold at least " ++ std.fmt.comptimePrint("{d}", .{truncated.len}) ++ " bytes");
    }
    return struct {
        var started = false;
        var instance: core.Instance = .{
            .flush = flushLocked,
            .record = recordLocked,
            .writeRecent = writeRecentLocked,
            .setFile = setFileLocked,
            .has_file = config.file != null,
        };

        var overflow: [config.overflow_buffer]u8 = undefined;

        const file_config = config.file orelse File{};
        var file_buffer: [if (config.file != null) file_config.buffer else 0]u8 = undefined;
        var file: sinks.FileSink = .{
            .interface = .{ .vtable = &sinks.FileSink.vtable, .buffer = &file_buffer },
            .append = file_config.append,
            .max_bytes = file_config.max_bytes,
            .keep = @max(file_config.keep, 1),
        };

        var ring_bytes: [config.memory]u8 = undefined;
        var ring: sinks.Ring = .{ .bytes = &ring_bytes };

        /// The record that repeats are compared with.
        var last: Record = undefined;
        var last_message: [config.message_buffer]u8 = undefined;
        var last_valid = false;
        var repeats: u32 = 0;
        /// When the repeats were last written as a count.
        var counted_at: u64 = 0;

        /// The function for `std_options.logFn`.
        pub fn log(comptime level: Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
            const state = &core.ScopeOf(scope).state;
            if (!state.registered.load(.acquire)) core.register(state);
            if (!enabled(level, state)) return;
            const time = core.now(.real);
            const elapsed = core.sinceStart(core.now(.awake));
            var buffer: [config.message_buffer]u8 = undefined;
            var writer: Writer = .fixed(&buffer);
            const fits = if (writer.print(fmt, args)) |_| true else |_| false;

            const locked = core.lock();
            defer core.unlock(locked);
            var record: Record = .{
                .level = level,
                .scope = state.name,
                .message = writer.buffered(),
                .time = time,
                .elapsed = elapsed,
                .frame = core.frame.load(.monotonic),
                .thread = core.thread(),
            };
            if (!fits) record.message = if (locked) formatOverflow(fmt, args) else mark(&buffer);
            emit(&record, locked);
        }

        /// Whether a record at `level` in the scope `state` is logged now.
        pub fn enabled(level: Level, state: *const core.Scope) bool {
            var max = state.level.load(.monotonic);
            if (max == core.inherit) max = core.default_level.load(.monotonic);
            if (max == core.inherit) max = @backingInt(config.level);
            return @backingInt(level) <= max;
        }

        /// Logs only the first time this level, scope and format are logged.
        pub fn once(comptime level: Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
            if (Once(level, scope, fmt).done.swap(true, .monotonic)) return;
            log(level, scope, fmt, args);
        }

        /// Logs at most once every `interval_ms` for this level, scope and
        /// format, saying how many were left out since.
        pub fn throttled(interval_ms: u32, comptime level: Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
            const skipped = Throttle(level, scope, fmt).pass(interval_ms) orelse return;
            if (skipped == 0) log(level, scope, fmt, args) else log(level, scope, fmt ++ " ({d} left out)", args ++ .{skipped});
        }

        /// Writes out the file's buffer, and any count of repeats.
        pub fn flush() void {
            const locked = core.lock();
            defer core.unlock(locked);
            flushLocked(locked);
        }

        /// Writes the last `max_lines` lines kept in memory, oldest first.
        pub fn writeRecent(writer: *Writer, max_lines: usize) Writer.Error!void {
            const locked = core.lock();
            defer core.unlock(locked);
            return writeRecentLocked(writer, max_lines);
        }

        /// Points the file sink at `target`, writing what it had buffered
        /// there.
        pub fn setFile(target: core.Target) core.SetFileError!void {
            const locked = core.lock();
            defer core.unlock(locked);
            return setFileLocked(target);
        }

        fn start() void {
            if (started) return;
            started = true;
            core.addInstance(&instance);
            if (config.file == null or file.chosen) return;
            const target = core.pending_target orelse file_config.target orelse return;
            core.pending_target = null;
            file.open(target) catch {
                core.stats.failures += 1;
            };
        }

        fn emit(record: *const Record, notify: bool) void {
            start();
            if (config.collapse_repeats) {
                if (repeated(record)) {
                    core.stats.collapsed += 1;
                    if (record.elapsed -| counted_at >= std.time.ns_per_s) countRepeats(notify);
                    return;
                }
                countRepeats(notify);
                remember(record);
            }
            write(record, true, notify);
        }

        fn write(record: *const Record, terminal: bool, notify: bool) void {
            core.stats.records += 1;
            if (terminal) if (config.terminal) |terminal_config| writeTerminal(record, terminal_config);
            if (config.file != null) writeFile(record);
            if (config.memory > 0) writeMemory(record);
            if (notify) core.notify(record);
        }

        fn writeTerminal(record: *const Record, terminal_config: Terminal) void {
            var buffer: [512]u8 = undefined;
            const stderr = std.debug.lockStderr(&buffer);
            defer std.debug.unlockStderr();
            var terminal = stderr.terminal();
            switch (terminal_config.color) {
                .auto => {},
                .always => if (terminal.mode == .no_color) {
                    terminal.mode = .escape_codes;
                },
                .never => terminal.mode = .no_color,
            }
            format.writeLine(record, terminal_config.format, .{ .writer = terminal.writer, .terminal = terminal, .theme = terminal_config.theme }) catch {
                core.stats.failures += 1;
            };
        }

        fn writeFile(record: *const Record) void {
            if (file.file == null) {
                var buffer: [config.message_buffer + 512]u8 = undefined;
                var writer: Writer = .fixed(&buffer);
                format.writeLine(record, file_config.format, .{ .writer = &writer }) catch {
                    core.stats.dropped += writer.end;
                    return;
                };
                file.hold(writer.buffered());
                return;
            }
            format.writeLine(record, file_config.format, .{ .writer = &file.interface }) catch {
                core.stats.failures += 1;
            };
            file.after(record.level, file_config.flush_level, record.elapsed, @as(u64, file_config.flush_interval_ms) * std.time.ns_per_ms);
        }

        fn writeMemory(record: *const Record) void {
            var buffer: [config.message_buffer + 256]u8 = undefined;
            var writer: Writer = .fixed(&buffer);
            format.writeLine(record, .{ .text = config.memory_decorations }, .{ .writer = &writer }) catch {
                buffer[buffer.len - 1] = '\n';
                writer.end = buffer.len;
            };
            ring.append(writer.buffered());
        }

        /// Whether `record` repeats the last one, which then counts it.
        fn repeated(record: *const Record) bool {
            if (!last_valid or last.level != record.level) return false;
            if (!std.mem.eql(u8, last.scope, record.scope) or !std.mem.eql(u8, last.message, record.message)) return false;
            repeats += 1;
            last.time = record.time;
            last.elapsed = record.elapsed;
            last.frame = record.frame;
            last.thread = record.thread;
            return true;
        }

        /// Writes the repeats counted so far as one record.
        fn countRepeats(notify: bool) void {
            if (repeats == 0) return;
            var count = last;
            count.repeats = repeats;
            repeats = 0;
            counted_at = count.elapsed;
            write(&count, true, notify);
        }

        fn remember(record: *const Record) void {
            last_valid = record.message.len <= last_message.len;
            if (!last_valid) return;
            @memcpy(last_message[0..record.message.len], record.message);
            last = record.*;
            last.message = last_message[0..record.message.len];
            counted_at = record.elapsed;
        }

        fn formatOverflow(comptime fmt: []const u8, args: anytype) []const u8 {
            var writer: Writer = .fixed(overflow[0 .. overflow.len - truncated.len]);
            writer.print(fmt, args) catch return mark(&overflow);
            return writer.buffered();
        }

        /// `buffer`, full, its end marked as cut off.
        fn mark(buffer: []u8) []const u8 {
            @memcpy(buffer[buffer.len - truncated.len ..], truncated);
            return buffer;
        }

        fn flushLocked(notify: bool) void {
            if (config.collapse_repeats) countRepeats(notify);
            if (config.file != null) file.flush();
        }

        fn recordLocked(record: *const Record) void {
            start();
            write(record, false, false);
        }

        fn writeRecentLocked(writer: *Writer, max_lines: usize) Writer.Error!void {
            if (config.memory == 0) return;
            return ring.writeRecent(writer, max_lines);
        }

        fn setFileLocked(target: core.Target) core.SetFileError!void {
            if (config.file == null) return error.NoFileSink;
            file.chosen = true;
            start();
            return file.open(target);
        }
    };
}

/// The state behind `once` for one level, scope and format.
pub fn Once(comptime level: Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8) type {
    return struct {
        comptime {
            _ = .{ level, scope, fmt };
        }
        pub var done: std.atomic.Value(bool) = .init(false);
    };
}

/// The state behind `throttled` for one level, scope and format.
pub fn Throttle(comptime level: Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8) type {
    return struct {
        comptime {
            _ = .{ level, scope, fmt };
        }
        var next: std.atomic.Value(i64) = .init(std.math.minInt(i64));
        var skipped: std.atomic.Value(u32) = .init(0);

        /// How many were left out since the last that passed, if this one
        /// passes.
        pub fn pass(interval_ms: u32) ?u32 {
            const now: i64 = @intCast(core.now(.awake));
            const allowed = next.load(.monotonic);
            if (now < allowed or next.cmpxchgStrong(allowed, now + @as(i64, interval_ms) * std.time.ns_per_ms, .monotonic, .monotonic) != null) {
                _ = skipped.fetchAdd(1, .monotonic);
                return null;
            }
            return skipped.swap(0, .monotonic);
        }
    };
}
