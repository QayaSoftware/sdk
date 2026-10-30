//! Records, and how sinks write them: decorated text, JSON or a custom
//! format.
const std = @import("std");
const Writer = std.Io.Writer;
const Terminal = std.Io.Terminal;

const Level = std.log.Level;

/// One log message, as listeners and custom formats see it.
pub const Record = struct {
    level: Level,
    /// The scope's name; `default` for std.log's default scope.
    scope: []const u8,
    /// The formatted message, without a newline.
    message: []const u8,
    /// Wall-clock time, in nanoseconds since the Unix epoch.
    time: i96,
    /// Nanoseconds since logging started.
    elapsed: u64,
    /// The frame `setFrame` last set.
    frame: u64,
    thread: Thread,
    /// How many identical records that came right after this one it stands
    /// for; zero for an ordinary record.
    repeats: u32 = 0,

    pub const Thread = struct {
        /// Threads are numbered from 1 in the order they first log.
        number: u32,
        /// What `nameThread` called it.
        name: ?[]const u8 = null,
    };
};

/// How a text line shows when a record was logged.
pub const Time = enum {
    none,
    /// Seconds since logging started: `+   1.234s`.
    elapsed,
    /// The time of day in UTC: `14:03:22.123`.
    clock,
    /// The date and time in UTC: `2026-10-30 14:03:22.123`.
    date_time,
    /// Seconds since the Unix epoch: `1793368402.123`.
    unix,
};

/// How a text line shows a record's level.
pub const LevelLabel = enum {
    none,
    /// As std.log writes it, padded: `error  `, `warning`, `info   `, `debug  `.
    word,
    /// `ERR`, `WRN`, `INF`, `DBG`.
    short,
    /// `E`, `W`, `I`, `D`.
    letter,
};

/// What a text line shows besides the message, in order: time, level,
/// thread, frame and scope.
pub const Decorations = struct {
    time: Time = .elapsed,
    level: LevelLabel = .short,
    /// The scope, before the message; std.log's default scope is left out.
    scope: bool = true,
    /// The thread's name, or its number.
    thread: bool = false,
    /// The frame `setFrame` last set.
    frame: bool = false,

    /// `+   1.234s INF render: message`, for a terminal.
    pub const pretty: Decorations = .{};
    /// `I render: message`.
    pub const compact: Decorations = .{ .time = .none, .level = .letter };
    /// `2026-10-30 14:03:22.123 INF [main] f1234 render: message`, for files.
    pub const detailed: Decorations = .{ .time = .date_time, .thread = true, .frame = true };
    /// The message alone.
    pub const plain: Decorations = .{ .time = .none, .level = .none, .scope = false };
};

/// The colors a terminal shows each part in.
pub const Theme = struct {
    err: Terminal.Color = .red,
    warn: Terminal.Color = .yellow,
    info: Terminal.Color = .green,
    debug: Terminal.Color = .magenta,
    /// Times, threads, frames, scopes and repeat counts.
    meta: Terminal.Color = .dim,

    fn of(self: Theme, level: Level) Terminal.Color {
        return switch (level) {
            .err => self.err,
            .warn => self.warn,
            .info => self.info,
            .debug => self.debug,
        };
    }
};

/// How a sink writes each record, one per line.
pub const Format = union(enum) {
    /// The message after the decorations asked for.
    text: Decorations,
    /// One JSON object, with every field of the record.
    json,
    /// Writes the record without the newline, which is added after.
    custom: *const fn (record: *const Record, writer: *Writer) Writer.Error!void,
};

/// Where a line goes, and the terminal it colors, if any.
pub const Out = struct {
    writer: *Writer,
    terminal: ?Terminal = null,
    theme: Theme = .{},

    fn color(self: Out, which: Terminal.Color) void {
        const terminal = self.terminal orelse return;
        terminal.setColor(which) catch {};
    }
};

/// Writes `record` as one line in `format`.
pub fn writeLine(record: *const Record, format: Format, out: Out) Writer.Error!void {
    switch (format) {
        .text => |decorations| try writeText(record, decorations, out),
        .json => try writeJson(record, out.writer),
        .custom => |custom| try custom(record, out.writer),
    }
    try out.writer.writeByte('\n');
}

fn writeText(record: *const Record, decorations: Decorations, out: Out) Writer.Error!void {
    const writer = out.writer;
    if (decorations.time != .none) {
        out.color(out.theme.meta);
        try writeTime(writer, decorations.time, record.time, record.elapsed);
        out.color(.reset);
        try writer.writeByte(' ');
    }
    if (decorations.level != .none) {
        out.color(out.theme.of(record.level));
        out.color(.bold);
        try writer.writeAll(switch (decorations.level) {
            .none => unreachable,
            .word => switch (record.level) {
                .err => "error  ",
                .warn => "warning",
                .info => "info   ",
                .debug => "debug  ",
            },
            .short => switch (record.level) {
                .err => "ERR",
                .warn => "WRN",
                .info => "INF",
                .debug => "DBG",
            },
            .letter => switch (record.level) {
                .err => "E",
                .warn => "W",
                .info => "I",
                .debug => "D",
            },
        });
        out.color(.reset);
        try writer.writeByte(' ');
    }
    if (decorations.thread) {
        out.color(out.theme.meta);
        if (record.thread.name) |name| try writer.print("[{s}]", .{name}) else try writer.print("[#{d}]", .{record.thread.number});
        out.color(.reset);
        try writer.writeByte(' ');
    }
    if (decorations.frame) {
        out.color(out.theme.meta);
        try writer.print("f{d}", .{record.frame});
        out.color(.reset);
        try writer.writeByte(' ');
    }
    if (decorations.scope and !std.mem.eql(u8, record.scope, "default")) {
        out.color(out.theme.meta);
        out.color(.bold);
        try writer.print("{s}:", .{record.scope});
        out.color(.reset);
        try writer.writeByte(' ');
    }
    try writer.writeAll(record.message);
    if (record.repeats > 0) {
        out.color(out.theme.meta);
        try writer.print(" (repeated {d} more {s})", .{ record.repeats, if (record.repeats == 1) "time" else "times" });
        out.color(.reset);
    }
}

/// Writes `time`, nanoseconds since the Unix epoch, or `elapsed`,
/// nanoseconds since logging started, as `style` shows it.
pub fn writeTime(writer: *Writer, style: Time, time: i96, elapsed: u64) Writer.Error!void {
    const ns_per_s = std.time.ns_per_s;
    const ns_per_ms = std.time.ns_per_ms;
    switch (style) {
        .none => {},
        .elapsed => try writer.print("+{d:>4}.{d:0>3}s", .{ elapsed / ns_per_s, elapsed % ns_per_s / ns_per_ms }),
        .unix => {
            const since = @max(time, 0);
            try writer.print("{d}.{d:0>3}", .{ @divFloor(since, ns_per_s), @divFloor(@mod(since, ns_per_s), ns_per_ms) });
        },
        .clock, .date_time => {
            const civil = Civil.of(time);
            if (style == .date_time) try writer.print("{d:0>4}-{d:0>2}-{d:0>2} ", .{ civil.year, civil.month, civil.day });
            try writer.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ civil.hour, civil.minute, civil.second, civil.millisecond });
        },
    }
}

/// A moment as a UTC calendar date and time of day.
pub const Civil = struct {
    year: u32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16,

    /// `time`, nanoseconds since the Unix epoch, before which it clamps.
    pub fn of(time: i96) Civil {
        const ms: u64 = @intCast(@divFloor(@max(time, 0), std.time.ns_per_ms));
        const seconds = ms / 1000;
        const days = seconds / std.time.s_per_day;
        const in_day = seconds % std.time.s_per_day;
        const date = civilFromDays(days);
        return .{
            .year = date.year,
            .month = date.month,
            .day = date.day,
            .hour = @intCast(in_day / 3600),
            .minute = @intCast(in_day % 3600 / 60),
            .second = @intCast(in_day % 60),
            .millisecond = @intCast(ms % 1000),
        };
    }

    /// The calendar date `days` after 1970-01-01, by Howard Hinnant's
    /// days-to-civil algorithm, in constant time.
    fn civilFromDays(days: u64) struct { year: u32, month: u8, day: u8 } {
        const z = days + 719468;
        const era = z / 146097;
        const day_of_era = z - era * 146097;
        const year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
        const day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
        const shifted_month = (5 * day_of_year + 2) / 153;
        const day = day_of_year - (153 * shifted_month + 2) / 5 + 1;
        const month = if (shifted_month < 10) shifted_month + 3 else shifted_month - 9;
        const year = year_of_era + era * 400 + @intFromBool(month <= 2);
        return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
    }
};

fn writeJson(record: *const Record, writer: *Writer) Writer.Error!void {
    const civil = Civil.of(record.time);
    try writer.print("{{\"time\":\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z\",\"elapsed\":{d},\"level\":\"{s}\",\"scope\":", .{
        civil.year,   civil.month,       civil.day,      civil.hour,              civil.minute,
        civil.second, civil.millisecond, record.elapsed, levelText(record.level),
    });
    try writeJsonString(writer, record.scope);
    try writer.print(",\"thread\":{d},\"thread_name\":", .{record.thread.number});
    if (record.thread.name) |name| try writeJsonString(writer, name) else try writer.writeAll("null");
    try writer.print(",\"frame\":{d},\"message\":", .{record.frame});
    try writeJsonString(writer, record.message);
    try writer.print(",\"repeats\":{d}}}", .{record.repeats});
}

/// Writes `text` as a JSON string, escaping quotes, backslashes and control
/// characters.
pub fn writeJsonString(writer: *Writer, text: []const u8) Writer.Error!void {
    try writer.writeByte('"');
    var start: usize = 0;
    for (text, 0..) |c, i| {
        const escape: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0...8, 11, 12, 14...0x1f, 0x7f => "",
            else => null,
        };
        const replacement = escape orelse continue;
        try writer.writeAll(text[start..i]);
        if (replacement.len > 0) try writer.writeAll(replacement) else try writer.print("\\u{x:0>4}", .{c});
        start = i + 1;
    }
    try writer.writeAll(text[start..]);
    try writer.writeByte('"');
}

/// A level as std.log writes it: `error`, `warning`, `info` or `debug`.
pub fn levelText(level: Level) []const u8 {
    return switch (level) {
        inline else => |l| comptime l.asText(),
    };
}
