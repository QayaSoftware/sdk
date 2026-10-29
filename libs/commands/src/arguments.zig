//! The argument types arguments parse with. Any value with a `Value` type and
//! a `parse` function is one:
//!
//!     pub fn parse(self: *const Self, reader: *Reader) !Value
//!     pub fn parse(self: *const Self, reader: *Reader, source: Source) !Value
//!
//! the second for a type that checks the text against the command's source.
//! It can also have
//!
//!     pub fn suggest(self: *const Self, builder: *SuggestionBuilder) !void
//!     pub fn describe(self: *const Self, err: anyerror, writer: *Writer) Writer.Error!bool
//!
//! to suggest values while one is typed, and to explain its errors, saying
//! whether it did. A failed parse leaves the reader's cursor where the
//! problem is. An integer, float, bool or enum type stands for its argument
//! type with no bounds.
const std = @import("std");
const Writer = std.Io.Writer;

const Reader = @import("Reader.zig");
const SuggestionBuilder = @import("suggestions.zig").Builder;

/// What the argument types here fail with, besides `Reader.Error`.
pub const Error = error{
    IntegerTooSmall,
    IntegerTooLarge,
    FloatTooSmall,
    FloatTooLarge,
    ExpectedWord,
    InvalidChoice,
};

/// An integer `T` in `min...max`.
pub fn Integer(comptime T: type) type {
    return struct {
        min: T = std.math.minInt(T),
        max: T = std.math.maxInt(T),

        pub const Value = T;

        /// Narrower integers parse as an `i64`, so a value out of their range
        /// is too small or large rather than invalid.
        const Wide = if (@typeInfo(T).int.bits < 64) i64 else T;

        pub fn parse(self: *const @This(), reader: *Reader) (Reader.Error || Error)!T {
            const start = reader.cursor;
            const value = try reader.readInt(Wide);
            if (value < self.min) {
                reader.cursor = start;
                return error.IntegerTooSmall;
            }
            if (value > self.max) {
                reader.cursor = start;
                return error.IntegerTooLarge;
            }
            return @intCast(value);
        }

        pub fn describe(self: *const @This(), err: anyerror, writer: *Writer) Writer.Error!bool {
            switch (err) {
                error.IntegerTooSmall => try writer.print("Integer must not be less than {d}", .{self.min}),
                error.IntegerTooLarge => try writer.print("Integer must not be more than {d}", .{self.max}),
                else => return false,
            }
            return true;
        }
    };
}

/// A float `T` in `min...max`.
pub fn Float(comptime T: type) type {
    return struct {
        min: T = -std.math.inf(T),
        max: T = std.math.inf(T),

        pub const Value = T;

        pub fn parse(self: *const @This(), reader: *Reader) (Reader.Error || Error)!T {
            const start = reader.cursor;
            const value = try reader.readFloat(T);
            if (value < self.min) {
                reader.cursor = start;
                return error.FloatTooSmall;
            }
            if (value > self.max) {
                reader.cursor = start;
                return error.FloatTooLarge;
            }
            return value;
        }

        pub fn describe(self: *const @This(), err: anyerror, writer: *Writer) Writer.Error!bool {
            switch (err) {
                error.FloatTooSmall => try writer.print("Float must not be less than {d}", .{self.min}),
                error.FloatTooLarge => try writer.print("Float must not be more than {d}", .{self.max}),
                else => return false,
            }
            return true;
        }
    };
}

/// `true` or `false`.
pub const Bool = struct {
    pub const Value = bool;

    pub fn parse(_: *const Bool, reader: *Reader) Reader.Error!bool {
        return reader.readBool();
    }

    pub fn suggest(_: *const Bool, builder: *SuggestionBuilder) !void {
        try builder.add("false");
        try builder.add("true");
    }
};

/// Text up to the next space.
pub const Word = struct {
    pub const Value = []const u8;

    pub fn parse(_: *const Word, reader: *Reader) Error![]const u8 {
        const text = reader.readWord();
        if (text.len == 0) return error.ExpectedWord;
        return text;
    }
};

/// A word, or text with spaces in quotes.
pub const String = struct {
    pub const Value = []const u8;

    pub fn parse(_: *const String, reader: *Reader) (Reader.Error || Error)![]const u8 {
        const quoted = reader.peek() == '"' or reader.peek() == '\'';
        const text = try reader.readString();
        if (!quoted and text.len == 0) return error.ExpectedWord;
        return text;
    }
};

/// The rest of the input, spaces and all.
pub const Greedy = struct {
    pub const Value = []const u8;

    pub fn parse(_: *const Greedy, reader: *Reader) Error![]const u8 {
        const text = reader.readRest();
        if (text.len == 0) return error.ExpectedWord;
        return text;
    }
};

/// One of `E`'s tags.
pub fn Choice(comptime E: type) type {
    return struct {
        pub const Value = E;

        pub fn parse(_: *const @This(), reader: *Reader) Error!E {
            const start = reader.cursor;
            const text = reader.readWord();
            if (text.len == 0) return error.ExpectedWord;
            return std.meta.stringToEnum(E, text) orelse {
                reader.cursor = start;
                return error.InvalidChoice;
            };
        }

        pub fn suggest(_: *const @This(), builder: *SuggestionBuilder) !void {
            inline for (@typeInfo(E).@"enum".fields) |field| try builder.add(field.name);
        }

        pub fn describe(_: *const @This(), err: anyerror, writer: *Writer) Writer.Error!bool {
            if (err != error.InvalidChoice) return false;
            const fields = @typeInfo(E).@"enum".fields;
            try writer.writeAll("Expected ");
            inline for (fields, 0..) |field, i| {
                if (i > 0) try writer.writeAll(if (i + 1 == fields.len) " or " else ", ");
                try writer.writeAll(field.name);
            }
            return true;
        }
    };
}

pub fn integer(comptime T: type, bounds: Integer(T)) Integer(T) {
    return bounds;
}

pub fn float(comptime T: type, bounds: Float(T)) Float(T) {
    return bounds;
}

pub fn choice(comptime E: type) Choice(E) {
    return .{};
}

pub const boolean: Bool = .{};
pub const word: Word = .{};
pub const string: String = .{};
pub const greedy: Greedy = .{};

/// The argument type `T` stands for.
pub fn Of(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .int => Integer(T),
        .float => Float(T),
        .bool => Bool,
        .@"enum" => Choice(T),
        else => @compileError("commands: " ++ @typeName(T) ++ " is not an argument type; give an integer, float, bool or enum type, or a value with a `Value` type and a `parse` function, such as commands.word"),
    };
}

/// Fails to compile unless `K` is an argument type.
pub fn check(comptime K: type) void {
    const container = switch (@typeInfo(K)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
    if (!container or !@hasDecl(K, "Value") or !@hasDecl(K, "parse")) {
        @compileError("commands: " ++ @typeName(K) ++ " is not an argument type: it needs a `Value` type and a `parse` function");
    }
    const params = @typeInfo(@TypeOf(K.parse)).@"fn".params.len;
    if (params != 2 and params != 3) {
        @compileError("commands: " ++ @typeName(K) ++ ".parse takes the argument type and a *Reader, and maybe the source");
    }
}
