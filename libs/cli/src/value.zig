//! Values parsed from text, and described and written for help.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Error = Allocator.Error || error{InvalidValue};

/// Whether `V` parses itself, with
/// `pub fn parseCli(arena: std.mem.Allocator, text: []const u8) !V`.
pub fn isCustom(comptime V: type) bool {
    return switch (@typeInfo(V)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(V, "parseCli"),
        else => false,
    };
}

/// Fails to compile unless a `V` can be parsed from text.
pub fn check(comptime V: type) void {
    if (isCustom(V) or V == []const u8 or V == bool) return;
    switch (@typeInfo(V)) {
        .int, .float, .@"enum" => {},
        else => @compileError("cli: a " ++ @typeName(V) ++ " cannot be parsed from text; give it a `pub fn parseCli(arena: std.mem.Allocator, text: []const u8) !" ++ @typeName(V) ++ "`"),
    }
}

/// Parses `text` as a `V`, copying text into `arena`. An integer can be
/// written in base 16, 8 or 2 with a `0x`, `0o` or `0b` prefix; an enum by
/// its tag, with `-` for `_`.
pub fn parse(comptime V: type, arena: Allocator, text: []const u8) Error!V {
    if (comptime isCustom(V)) return V.parseCli(arena, text) catch |err| {
        if (@as(anyerror, err) == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidValue;
    };
    if (V == []const u8) return arena.dupe(u8, text);
    switch (@typeInfo(V)) {
        .int => return std.fmt.parseInt(V, text, 0) catch error.InvalidValue,
        .float => return std.fmt.parseFloat(V, text) catch error.InvalidValue,
        .bool => return parseBool(text) orelse error.InvalidValue,
        .@"enum" => |info| {
            inline for (info.fields) |field| if (matches(field.name, text)) return @field(V, field.name);
            return error.InvalidValue;
        },
        else => comptime unreachable,
    }
}

/// `true`, `yes`, `on` or `1`, or `false`, `no`, `off` or `0`, in any case.
pub fn parseBool(text: []const u8) ?bool {
    for ([_][]const u8{ "true", "yes", "on", "1" }) |yes| if (std.ascii.eqlIgnoreCase(text, yes)) return true;
    for ([_][]const u8{ "false", "no", "off", "0" }) |no| if (std.ascii.eqlIgnoreCase(text, no)) return false;
    return null;
}

/// Whether `text` is `name`, with `-` allowed for `_`.
fn matches(comptime name: []const u8, text: []const u8) bool {
    if (text.len != name.len) return false;
    for (name, text) |a, b| if (a != b and !(a == '_' and b == '-')) return false;
    return true;
}

/// What a `V` is written as, for an error about a value that is not one.
pub fn expected(comptime V: type) []const u8 {
    if (isCustom(V)) return if (@hasDecl(V, "cli_expected")) V.cli_expected else "a valid " ++ shortName(V);
    if (V == []const u8) return "text";
    return switch (@typeInfo(V)) {
        .int => std.fmt.comptimePrint("an integer from {d} to {d}", .{ std.math.minInt(V), std.math.maxInt(V) }),
        .float => "a number",
        .bool => "true or false",
        .@"enum" => "one of " ++ choices(V, " or "),
        else => comptime unreachable,
    };
}

/// An enum's tags as written, joined by commas and `last` before the last.
pub fn choices(comptime E: type, comptime last: []const u8) []const u8 {
    comptime {
        const fields = @typeInfo(E).@"enum".fields;
        var text: []const u8 = "";
        for (fields, 0..) |field, i| {
            if (i > 0) text = text ++ (if (i + 1 == fields.len) last else ", ");
            text = text ++ kebab(field.name);
        }
        return text;
    }
}

fn shortName(comptime V: type) []const u8 {
    const name = @typeName(V);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[dot + 1 ..];
}

/// `name` with `-` for `_`.
pub fn kebab(comptime name: []const u8) []const u8 {
    comptime {
        var out = name[0..name.len].*;
        for (&out) |*c| if (c.* == '_') {
            c.* = '-';
        };
        const final = out;
        return &final;
    }
}

/// `name` in capitals with `_` for `-`, as environment variables are named.
pub fn screaming(comptime name: []const u8) []const u8 {
    comptime {
        var out = name[0..name.len].*;
        for (&out) |*c| c.* = if (c.* == '-') '_' else std.ascii.toUpper(c.*);
        const final = out;
        return &final;
    }
}

/// Whether help shows `v` as a default: not when it is nothing, as null,
/// false, zero for a count, or empty is.
pub fn shown(comptime F: type, comptime v: F) bool {
    return switch (@typeInfo(F)) {
        .optional => if (v) |child| shown(@typeInfo(F).optional.child, child) else false,
        .bool => v,
        .int, .float, .@"enum" => !isCustom(F) or @hasDecl(F, "format"),
        .pointer => v.len > 0 and (F == []const u8 or !isCustom(@typeInfo(F).pointer.child) or @hasDecl(@typeInfo(F).pointer.child, "format")),
        else => isCustom(F) and @hasDecl(F, "format"),
    };
}

/// Writes `v` as it would be given.
pub fn write(comptime F: type, writer: *Writer, v: F) Writer.Error!void {
    if (comptime isCustom(F)) return writer.print("{f}", .{v});
    if (F == []const u8) return writer.writeAll(v);
    switch (@typeInfo(F)) {
        .optional => |info| if (v) |child| try write(info.child, writer, child),
        .bool => try writer.writeAll(if (v) "true" else "false"),
        .int, .float => try writer.print("{d}", .{v}),
        .@"enum" => |info| inline for (info.fields) |field| {
            if (@field(F, field.name) == v) try writer.writeAll(comptime kebab(field.name));
        },
        .pointer => |info| for (v, 0..) |item, i| {
            if (i > 0) try writer.writeAll(", ");
            try write(info.child, writer, item);
        },
        else => comptime unreachable,
    }
}
