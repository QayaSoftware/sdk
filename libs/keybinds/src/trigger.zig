//! What sets a binding off: chords of inputs held together, in a sequence
//! of up to four, and the gesture made on the last.
const std = @import("std");
const Writer = std.Io.Writer;

const input = @import("input.zig");
const Input = input.Input;
const Mods = input.Mods;

/// Inputs held together with modifiers, as `ctrl+s` or `lb+rb`: pressing
/// the last of them while the rest are held completes it. A chord can hold
/// one axis or motion input, which then gives its value while the rest are
/// held, as `mouse:right+motion:x` does.
pub const Chord = struct {
    mods: Mods = .{},
    buffer: [max_inputs]Input = undefined,
    len: u8 = 0,

    pub const max_inputs = 4;

    pub fn of(mods: Mods, held: []const Input) Chord {
        std.debug.assert(held.len > 0 and held.len <= max_inputs);
        var chord: Chord = .{ .mods = mods, .len = @intCast(held.len) };
        @memcpy(chord.buffer[0..held.len], held);
        return chord;
    }

    pub fn inputs(self: *const Chord) []const Input {
        return self.buffer[0..self.len];
    }

    pub fn contains(self: *const Chord, which: Input) bool {
        for (self.inputs()) |held| if (held.id() == which.id()) return true;
        return false;
    }

    /// Its axis or motion input, if it has one.
    pub fn analog(self: *const Chord) ?Input {
        for (self.inputs()) |held| if (!held.isDigital()) return held;
        return null;
    }

    /// How much it asks for, which decides between chords one press
    /// completes at once: `ctrl+s` before `s`.
    pub fn specificity(self: *const Chord) u8 {
        return self.mods.count() + self.len;
    }

    /// The modifiers its own inputs are, which holding them does not count
    /// against: `shift` alone is a chord of the shift key, not of the shift
    /// modifier.
    pub fn ownMods(self: *const Chord) Mods {
        var mods: Mods = .{};
        for (self.inputs()) |held| if (held.modifier()) |which| {
            mods = mods.with(which, true);
        };
        return mods;
    }

    /// Whether both have the same modifiers and inputs, in any order.
    pub fn eql(self: *const Chord, other: *const Chord) bool {
        if (self.mods.bits() != other.mods.bits() or self.len != other.len) return false;
        for (self.inputs()) |held| if (!other.contains(held)) return false;
        return true;
    }

    /// Writes the chord as `parse` reads it, as `ctrl+shift+s`.
    pub fn writeText(self: *const Chord, writer: *Writer) Writer.Error!void {
        inline for (.{ "ctrl", "alt", "shift", "super" }) |name| {
            if (@field(self.mods, name)) try writer.writeAll(name ++ "+");
        }
        for (self.inputs(), 0..) |held, i| {
            if (i > 0) try writer.writeByte('+');
            try held.writeText(writer);
        }
    }

    /// Writes the chord as it is shown to a player, as `Ctrl+Shift+S`.
    pub fn format(self: Chord, writer: *Writer) Writer.Error!void {
        inline for (.{ .{ "ctrl", "Ctrl" }, .{ "alt", "Alt" }, .{ "shift", "Shift" }, .{ "super", "Super" } }) |name| {
            if (@field(self.mods, name[0])) try writer.writeAll(name[1] ++ "+");
        }
        for (self.inputs(), 0..) |held, i| {
            if (i > 0) try writer.writeByte('+');
            try held.format(writer);
        }
    }
};

/// Chords pressed one after another, as `ctrl+k ctrl+c`; most triggers are
/// a single chord.
pub const Trigger = struct {
    buffer: [max_chords]Chord = undefined,
    len: u8 = 0,

    pub const max_chords = 4;

    pub fn single(chord: Chord) Trigger {
        var trigger: Trigger = .{ .len = 1 };
        trigger.buffer[0] = chord;
        return trigger;
    }

    pub fn chords(self: *const Trigger) []const Chord {
        return self.buffer[0..self.len];
    }

    pub fn first(self: *const Trigger) *const Chord {
        return &self.buffer[0];
    }

    pub fn last(self: *const Trigger) *const Chord {
        return &self.buffer[self.len - 1];
    }

    pub fn eql(self: *const Trigger, other: *const Trigger) bool {
        if (self.len != other.len) return false;
        for (self.chords(), other.chords()) |*a, *b| if (!a.eql(b)) return false;
        return true;
    }

    pub const ParseError = Input.ParseError || error{
        EmptyTrigger,
        /// More than `Chord.max_inputs` inputs in a chord.
        TooManyInputs,
        /// More than `max_chords` chords in a sequence.
        TooManyChords,
        /// The same input twice in a chord.
        RepeatedInput,
        /// Two axis or motion inputs in a chord, or one in a sequence.
        MisplacedAnalog,
    };

    /// Reads a trigger: chords separated by spaces, each its modifiers and
    /// inputs joined by `+`, in any case, as `ctrl+shift+s`,
    /// `ctrl+k ctrl+c`, `lb+rb` or `mouse:right+motion:x`. A modifier last
    /// in a chord is its key: `shift` is the shift key, either side.
    pub fn parse(text: []const u8) ParseError!Trigger {
        var trigger: Trigger = .{};
        var words = std.mem.tokenizeAny(u8, text, " \t");
        while (words.next()) |word| {
            if (trigger.len == max_chords) return error.TooManyChords;
            trigger.buffer[trigger.len] = try parseChord(word);
            trigger.len += 1;
        }
        if (trigger.len == 0) return error.EmptyTrigger;
        if (trigger.len > 1) for (trigger.chords()) |*chord| if (chord.analog() != null) return error.MisplacedAnalog;
        return trigger;
    }

    fn parseChord(text: []const u8) ParseError!Chord {
        var chord: Chord = .{};
        var parts = std.mem.splitScalar(u8, text, '+');
        var buffer: [32]u8 = undefined;
        while (parts.next()) |part| {
            if (part.len == 0) {
                if (parts.peek() != null) return error.UnknownInput;
                continue;
            }
            if (part.len <= buffer.len and parts.peek() != null) {
                if (input.Mods.parseModifier(std.ascii.lowerString(&buffer, part))) |which| {
                    chord.mods = chord.mods.with(which, true);
                    continue;
                }
            }
            const parsed = try Input.parse(trailingPlus(text, part, &parts));
            if (chord.contains(parsed)) return error.RepeatedInput;
            if (!parsed.isDigital() and chord.analog() != null) return error.MisplacedAnalog;
            if (chord.len == Chord.max_inputs) return error.TooManyInputs;
            chord.buffer[chord.len] = parsed;
            chord.len += 1;
        }
        if (chord.len == 0) return error.EmptyTrigger;
        return chord;
    }

    /// A half axis named `pad:left_x+` ends in the `+` that also joins a
    /// chord's parts, so it is put back.
    fn trailingPlus(text: []const u8, part: []const u8, parts: *std.mem.SplitIterator(u8, .scalar)) []const u8 {
        const start = @intFromPtr(part.ptr) - @intFromPtr(text.ptr);
        const end = start + part.len;
        if (std.mem.indexOfScalar(u8, part, ':') == null or end >= text.len or text[end] != '+') return part;
        const rest = parts.rest();
        if (rest.len > 0 and rest[0] != '+') return part;
        _ = parts.next();
        return text[start .. end + 1];
    }

    /// Writes the trigger as `parse` reads it.
    pub fn writeText(self: *const Trigger, writer: *Writer) Writer.Error!void {
        for (self.chords(), 0..) |*chord, i| {
            if (i > 0) try writer.writeByte(' ');
            try chord.writeText(writer);
        }
    }

    /// Writes the trigger as it is shown to a player, as `Ctrl+K Ctrl+C`.
    pub fn format(self: Trigger, writer: *Writer) Writer.Error!void {
        for (self.chords(), 0..) |chord, i| {
            if (i > 0) try writer.writeByte(' ');
            try chord.format(writer);
        }
    }
};

/// How the last chord of a trigger is played. Durations are nanoseconds.
pub const Gesture = union(enum) {
    /// Fires when the chord completes; its action is down until a chord
    /// input is released.
    press,
    /// Fires when a chord input is released, the chord having completed.
    release,
    /// Fires once the chord has been held this long; its action is down
    /// from then until a chord input is released.
    hold: u64,
    /// Fires when the chord completes, then every `interval` after `delay`
    /// while it is held; its action is down meanwhile.
    repeat: Repeat,
    /// Fires when a chord input is released within this long of the chord
    /// completing.
    tap: u64,
    /// Fires when the chord completes the second time within this long of
    /// the first; its action is down until a chord input is released.
    double_tap: u64,

    pub const Repeat = struct { delay: u64, interval: u64 };

    pub const Tag = std.meta.Tag(Gesture);

    /// Whether its action is down while it is held, rather than only
    /// firing.
    pub fn holds(self: Gesture) bool {
        return switch (self) {
            .press, .hold, .repeat, .double_tap => true,
            .release, .tap => false,
        };
    }
};

/// `n` milliseconds, in the nanoseconds durations are.
pub fn ms(n: u64) u64 {
    return n * std.time.ns_per_ms;
}

/// Reads a duration such as `500ms`, `1.5s` or `250us`, in nanoseconds.
pub fn parseDuration(text: []const u8) ?u64 {
    const units = [_]struct { []const u8, f64 }{ .{ "ms", std.time.ns_per_ms }, .{ "us", std.time.ns_per_us }, .{ "ns", 1 }, .{ "s", std.time.ns_per_s } };
    for (units) |unit| {
        if (!std.mem.endsWith(u8, text, unit[0])) continue;
        const number = std.fmt.parseFloat(f64, text[0 .. text.len - unit[0].len]) catch return null;
        if (!(number >= 0) or number * unit[1] > 9.2e18) return null;
        return @intFromFloat(@round(number * unit[1]));
    }
    return null;
}

/// Writes a duration as `parseDuration` reads it, in the largest unit that
/// keeps it whole.
pub fn writeDuration(writer: *Writer, nanoseconds: u64) Writer.Error!void {
    if (nanoseconds != 0 and nanoseconds % std.time.ns_per_s == 0) return writer.print("{d}s", .{nanoseconds / std.time.ns_per_s});
    if (nanoseconds % std.time.ns_per_ms == 0) return writer.print("{d}ms", .{nanoseconds / std.time.ns_per_ms});
    if (nanoseconds % std.time.ns_per_us == 0) return writer.print("{d}us", .{nanoseconds / std.time.ns_per_us});
    return writer.print("{d}ns", .{nanoseconds});
}
