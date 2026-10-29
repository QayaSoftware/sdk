//! Reads a command's text a piece at a time, for argument types to parse
//! their values with. Reads never allocate: text comes back as slices of the
//! input, except a quoted string with escapes, which is unescaped into the
//! parse's buffer.
const std = @import("std");

const Reader = @This();

/// The whole command.
input: []const u8,
/// Where the next read starts.
cursor: usize = 0,
/// The parse's buffer, for values that keep more than they read; none
/// outside a parse.
space: ?*Space = null,

/// What reads fail with, the cursor left where the problem is.
pub const Error = error{
    ExpectedInteger,
    InvalidInteger,
    ExpectedFloat,
    InvalidFloat,
    ExpectedBool,
    InvalidBool,
    ExpectedStartOfQuote,
    ExpectedEndOfQuote,
    InvalidEscape,
    ExpectedSymbol,
    NoSpaceLeft,
};

pub fn init(input: []const u8) Reader {
    return .{ .input = input };
}

/// The text not read yet.
pub fn remaining(self: *const Reader) []const u8 {
    return self.input[self.cursor..];
}

/// Whether everything is read.
pub fn atEnd(self: *const Reader) bool {
    return self.cursor >= self.input.len;
}

/// The next byte, without reading it; null at the end.
pub fn peek(self: *const Reader) ?u8 {
    return if (self.cursor < self.input.len) self.input[self.cursor] else null;
}

/// Reads the next byte; null at the end.
pub fn next(self: *Reader) ?u8 {
    const c = self.peek() orelse return null;
    self.cursor += 1;
    return c;
}

/// Reads `c`, which must be next.
pub fn expect(self: *Reader, c: u8) Error!void {
    if (self.peek() != c) return error.ExpectedSymbol;
    self.cursor += 1;
}

/// Reads `c` if it is next, and says whether it was.
pub fn consume(self: *Reader, c: u8) bool {
    if (self.peek() != c) return false;
    self.cursor += 1;
    return true;
}

pub fn skipWhitespace(self: *Reader) void {
    while (self.peek() == ' ') self.cursor += 1;
}

/// Reads up to the next space or the end: a word, empty when a space is next.
pub fn readWord(self: *Reader) []const u8 {
    const start = self.cursor;
    self.cursor = std.mem.indexOfScalarPos(u8, self.input, start, ' ') orelse self.input.len;
    return self.input[start..self.cursor];
}

/// Reads the rest of the input.
pub fn readRest(self: *Reader) []const u8 {
    defer self.cursor = self.input.len;
    return self.input[self.cursor..];
}

/// Reads a base-10 integer, with an optional `-`.
pub fn readInt(self: *Reader, comptime T: type) Error!T {
    const start = self.cursor;
    const number = self.readNumber();
    if (number.text.len == 0) return error.ExpectedInteger;
    if (number.plain and !number.point and number.digits > 0 and number.digits <= 18) {
        const magnitude: i64 = @intCast(number.mantissa);
        if (std.math.cast(T, if (number.negative) -magnitude else magnitude)) |value| return value;
    } else if (std.fmt.parseInt(T, number.text, 10)) |value| return value else |_| {}
    self.cursor = start;
    return error.InvalidInteger;
}

/// Reads a decimal number such as `-1.5`, `2` or `.5`.
pub fn readFloat(self: *Reader, comptime T: type) Error!T {
    const start = self.cursor;
    const number = self.readNumber();
    if (number.text.len == 0) return error.ExpectedFloat;
    if (number.plain and number.digits > 0) if (exactDecimal(T, number)) |value| return value;
    return std.fmt.parseFloat(T, number.text) catch {
        self.cursor = start;
        return error.InvalidFloat;
    };
}

/// A number's text, read in one pass with its digits as a whole number.
const Number = struct {
    text: []const u8,
    /// The digits as a whole number, wrapped if there are more than 19.
    mantissa: u64,
    digits: u32,
    /// How many digits are after the point.
    scale: u32,
    negative: bool,
    point: bool,
    /// Whether it is an optional `-`, digits, and at most one point.
    plain: bool,
};

/// Reads digits, points and minus signs: the text a number can be.
fn readNumber(self: *Reader) Number {
    const start = self.cursor;
    var number: Number = .{ .text = "", .mantissa = 0, .digits = 0, .scale = 0, .negative = false, .point = false, .plain = true };
    var i = start;
    if (i < self.input.len and self.input[i] == '-') {
        number.negative = true;
        i += 1;
    }
    while (i < self.input.len) : (i += 1) switch (self.input[i]) {
        '0'...'9' => |c| {
            number.mantissa = number.mantissa *% 10 +% (c - '0');
            number.digits += 1;
            number.scale += @intFromBool(number.point);
        },
        '.' => {
            number.plain = number.plain and !number.point;
            number.point = true;
        },
        '-' => number.plain = false,
        else => break,
    };
    self.cursor = i;
    number.text = self.input[start..i];
    return number;
}

/// A plain decimal as a `T`, when it has few enough digits that the digits
/// as a whole number and the power of ten they are divided by are both
/// exact in `T`, so one division rounds correctly (Clinger's fast path).
fn exactDecimal(comptime T: type, number: Number) ?T {
    const max_digits = switch (T) {
        f64 => 15,
        f32 => 7,
        else => return null,
    };
    const powers = comptime powers: {
        var all: [max_digits + 1]T = undefined;
        all[0] = 1;
        for (all[1..], all[0 .. all.len - 1]) |*power, previous| power.* = previous * 10;
        break :powers all;
    };
    if (number.digits > max_digits) return null;
    const value = @as(T, @floatFromInt(number.mantissa)) / powers[number.scale];
    return if (number.negative) -value else value;
}
/// Reads `true` or `false`.
pub fn readBool(self: *Reader) Error!bool {
    const start = self.cursor;
    const word = self.readWord();
    if (word.len == 0) return error.ExpectedBool;
    if (std.mem.eql(u8, word, "true")) return true;
    if (std.mem.eql(u8, word, "false")) return false;
    self.cursor = start;
    return error.InvalidBool;
}

/// Reads a string in double or single quotes, in which a backslash escapes
/// the quote or another backslash.
pub fn readQuoted(self: *Reader) Error![]const u8 {
    const quote = self.peek() orelse return error.ExpectedStartOfQuote;
    if (quote != '"' and quote != '\'') return error.ExpectedStartOfQuote;
    const start = self.cursor + 1;
    var escapes: usize = 0;
    const end = scan: {
        var i = start;
        while (i < self.input.len) : (i += 1) {
            const c = self.input[i];
            if (c == quote) break :scan i;
            if (c != '\\') continue;
            i += 1;
            if (i < self.input.len and self.input[i] != quote and self.input[i] != '\\') {
                self.cursor = i;
                return error.InvalidEscape;
            }
            escapes += 1;
        }
        self.cursor = self.input.len;
        return error.ExpectedEndOfQuote;
    };
    const raw = self.input[start..end];
    if (escapes == 0) {
        self.cursor = end + 1;
        return raw;
    }
    const text = try self.alloc(u8, raw.len - escapes);
    self.cursor = end + 1;
    var from: usize = 0;
    for (text) |*c| {
        if (raw[from] == '\\') from += 1;
        c.* = raw[from];
        from += 1;
    }
    return text;
}

/// Reads a quoted string if a quote is next, or else a word.
pub fn readString(self: *Reader) Error![]const u8 {
    return switch (self.peek() orelse return "") {
        '"', '\'' => self.readQuoted(),
        else => self.readWord(),
    };
}

/// Space for `n` values of `T` in the parse's buffer, which lasts as long as
/// the parse: for a value that keeps more than it reads, as an unescaped
/// string does.
pub fn alloc(self: *Reader, comptime T: type, n: usize) error{NoSpaceLeft}![]T {
    const space = self.space orelse return error.NoSpaceLeft;
    return space.alloc(T, n);
}

/// A parse's buffer: the nodes parsed grow up from its start, and the values
/// they hold down from its end, so a parse that backtracks gives both back
/// by restoring a mark.
pub const Space = struct {
    bytes: []u8,
    /// Where the stack of parsed nodes starts.
    start: usize,
    /// Where the stack ends.
    low: usize,
    /// Where the values start.
    high: usize,

    pub const Mark = struct { low: usize, high: usize };

    pub fn init(bytes: []u8) Space {
        const address = @intFromPtr(bytes.ptr);
        const start = @min(std.mem.Alignment.of(usize).forward(address) - address, bytes.len);
        return .{ .bytes = bytes, .start = start, .low = start, .high = bytes.len };
    }

    pub fn mark(self: *const Space) Mark {
        return .{ .low = self.low, .high = self.high };
    }

    pub fn restore(self: *Space, to: Mark) void {
        self.low = to.low;
        self.high = to.high;
    }

    pub fn alloc(self: *Space, comptime T: type, n: usize) error{NoSpaceLeft}![]T {
        const size = std.math.mul(usize, @sizeOf(T), n) catch return error.NoSpaceLeft;
        const bytes = try self.allocBytes(size, .of(T));
        return @as([*]T, @ptrCast(@alignCast(bytes)))[0..n];
    }

    pub fn allocBytes(self: *Space, size: usize, alignment: std.mem.Alignment) error{NoSpaceLeft}![*]u8 {
        if (size > self.high - self.low) return error.NoSpaceLeft;
        const base = @intFromPtr(self.bytes.ptr);
        const address = alignment.backward(base + self.high - size);
        if (address < base + self.low) return error.NoSpaceLeft;
        self.high = address - base;
        return self.bytes.ptr + self.high;
    }

    /// Pushes `item` on the stack, whose items are all `T`s no more aligned
    /// than a `usize`.
    pub fn push(self: *Space, comptime T: type, item: T) error{NoSpaceLeft}!void {
        comptime std.debug.assert(@alignOf(T) <= @alignOf(usize) and @sizeOf(T) % @alignOf(T) == 0);
        if (@sizeOf(T) > self.high - self.low) return error.NoSpaceLeft;
        const slot: *T = @ptrCast(@alignCast(self.bytes.ptr + self.low));
        slot.* = item;
        self.low += @sizeOf(T);
    }

    pub fn stack(self: *const Space, comptime T: type) []T {
        const base: [*]T = @ptrCast(@alignCast(self.bytes.ptr + self.start));
        return base[0 .. (self.low - self.start) / @sizeOf(T)];
    }
};
