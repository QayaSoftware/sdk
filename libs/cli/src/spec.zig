//! What a struct's fields are on the command line and in the environment,
//! worked out at compile time from their types, their defaults and the
//! struct's `meta`.
const std = @import("std");
const Writer = std.Io.Writer;

const value = @import("value.zig");

/// How a field takes its values.
pub const Kind = enum {
    /// A bool: `--name` sets it, and `--no-name` or `--name=false` clears it.
    toggle,
    /// One value, as `--name value`; given again, the last one wins.
    single,
    /// Values given any number of times, gathered into a slice.
    list,
    /// An integer counting how many times it is given, as `-vvv`.
    count,
};

/// A field that takes values: a flag or a positional argument.
pub const Spec = struct {
    /// The field names from the struct parsed down to the field, through
    /// the groups it is in.
    path: []const []const u8,
    /// The field's type.
    Field: type,
    /// The type each value given is parsed as.
    Value: type,
    kind: Kind,
    positional: bool,
    /// The flag's name without its dashes, or the positional argument's name.
    long: []const u8,
    short: ?u8,
    /// The environment variable it falls back to, after the prefix when
    /// `prefixed`.
    env: ?[]const u8,
    prefixed: bool,
    /// Whether the variable is read only when parsing has a prefix: true for
    /// the names made from the field's, so a field named `path` does not
    /// read `PATH` by accident.
    needs_prefix: bool,
    help: []const u8,
    value_name: []const u8,
    hidden: bool,
    separator: u8,
    /// Whether it must be given: it has no default and is not optional.
    required: bool,
    /// Writes its default, when help shows one.
    default: ?*const fn (writer: *Writer) Writer.Error!void,

    /// How errors and usage name it: `--port` or `<file>`.
    pub fn display(comptime self: Spec) []const u8 {
        return if (self.positional) "<" ++ self.long ++ ">" else "--" ++ self.long;
    }
};

/// A field that is a tagged union: its tags are subcommands, each parsing
/// the arguments after it into its payload.
pub const Command = struct {
    field: []const u8,
    Union: type,
    optional: bool,
    required: bool,
};

pub const Analysis = struct {
    specs: []const Spec,
    command: ?Command,
    /// The indices in `specs` of the positional arguments, in order.
    positionals: []const usize,
    /// Whether `-h` asks for help, no field having taken it.
    short_help: bool,
};

const option_names = [_][]const u8{ "help", "short", "long", "env", "positional", "value_name", "hidden", "separator", "count" };
const command_option_names = [_][]const u8{ "help", "hidden" };

pub fn analyze(comptime T: type) Analysis {
    comptime {
        if (@typeInfo(T) != .@"struct") @compileError("cli: " ++ @typeName(T) ++ " is not a struct");
        var specs: []const Spec = &.{};
        var command: ?Command = null;
        collect(T, &.{}, "", "", null, &specs, &command, true);
        var positionals: []const usize = &.{};
        var short_help = true;
        for (specs, 0..) |s, i| {
            if (s.positional) {
                if (s.kind == .toggle or s.kind == .count) @compileError("cli: " ++ s.long ++ " in " ++ @typeName(T) ++ " cannot be positional, as a bool or a count");
                if (positionals.len > 0 and specs[positionals[positionals.len - 1]].kind == .list) {
                    @compileError("cli: " ++ s.long ++ " in " ++ @typeName(T) ++ " comes after a positional list, which takes every argument left");
                }
                positionals = positionals ++ [_]usize{i};
                continue;
            }
            if (std.mem.eql(u8, s.long, "help")) @compileError("cli: --help in " ++ @typeName(T) ++ " is taken by help");
            if (s.short == 'h') short_help = false;
            for (specs[0..i]) |other| {
                if (other.positional) continue;
                if (std.mem.eql(u8, other.long, s.long)) @compileError("cli: two fields of " ++ @typeName(T) ++ " are --" ++ s.long);
                if (s.short != null and other.short == s.short) @compileError("cli: two fields of " ++ @typeName(T) ++ " are -" ++ [_]u8{s.short.?});
            }
        }
        if (command != null and positionals.len > 0) @compileError("cli: " ++ @typeName(T) ++ " has both positional arguments and commands");
        return .{ .specs = specs, .command = command, .positionals = positionals, .short_help = short_help };
    }
}

fn collect(
    comptime T: type,
    comptime path: []const []const u8,
    comptime long_prefix: []const u8,
    comptime env_prefix: []const u8,
    comptime group_default: ?T,
    comptime specs: *[]const Spec,
    comptime command: *?Command,
    comptime top: bool,
) void {
    checkMeta(T);
    const info = @typeInfo(T).@"struct";
    for (info.field_names, info.field_types, info.field_attrs) |field_name, Field, attrs| {
        const meta = metaOf(T, field_name);
        const field_path = path ++ [_][]const u8{field_name};
        const default: ?Field = if (group_default) |group| @field(group, field_name) else attrs.defaultValue(Field);
        const optional = @typeInfo(Field) == .optional;
        const Inner = if (optional) @typeInfo(Field).optional.child else Field;
        if (isGroup(Inner)) {
            if (optional) @compileError("cli: the group " ++ field_name ++ " in " ++ @typeName(T) ++ " cannot be optional");
            const inner_default: ?Inner = if (default) |group| group else null;
            collect(Inner, field_path, long_prefix ++ value.kebab(field_name) ++ "-", env_prefix ++ value.screaming(field_name) ++ "_", inner_default, specs, command, false);
        } else if (@typeInfo(Inner) == .@"union") {
            if (!top) @compileError("cli: the commands " ++ field_name ++ " in " ++ @typeName(T) ++ " must be in the struct parsed, not a group");
            if (command.* != null) @compileError("cli: " ++ @typeName(T) ++ " has two fields of commands");
            if (@typeInfo(Inner).@"union".tag_type == null) @compileError("cli: the commands " ++ field_name ++ " in " ++ @typeName(T) ++ " must be a tagged union");
            checkCommandMeta(Inner);
            command.* = .{ .field = field_name, .Union = Inner, .optional = optional, .required = !optional and default == null };
        } else {
            specs.* = specs.* ++ [_]Spec{spec(Field, Inner, field_path, long_prefix ++ value.kebab(field_name), env_prefix ++ value.screaming(field_name), default, meta)};
        }
    }
}

fn spec(comptime Field: type, comptime Inner: type, comptime path: []const []const u8, comptime long: []const u8, comptime env: []const u8, comptime default: ?Field, comptime meta: anytype) Spec {
    const kind: Kind = if (Inner == bool)
        .toggle
    else if (option(meta, "count", false))
        .count
    else if (isList(Inner))
        .list
    else
        .single;
    const Value = switch (kind) {
        .toggle => bool,
        .count => if (@typeInfo(Inner) == .int) Inner else @compileError("cli: " ++ long ++ " counts, so it must be an integer"),
        .list => @typeInfo(Inner).pointer.child,
        .single => Inner,
    };
    value.check(Value);
    const env_option = option(meta, "env", true);
    const exact = @TypeOf(env_option) != bool;
    return .{
        .path = path,
        .Field = Field,
        .Value = Value,
        .kind = kind,
        .positional = option(meta, "positional", false),
        .long = option(meta, "long", long),
        .short = if (@hasField(@TypeOf(meta), "short")) meta.short else null,
        .env = if (exact) env_option else if (env_option) env else null,
        .prefixed = !exact,
        .needs_prefix = !exact and !@hasField(@TypeOf(meta), "env"),
        .help = option(meta, "help", ""),
        .value_name = option(meta, "value_name", value.screaming(path[path.len - 1])),
        .hidden = option(meta, "hidden", false),
        .separator = option(meta, "separator", ','),
        .required = default == null and Field == Inner and kind != .toggle and kind != .count,
        .default = if (default) |d| (if (value.shown(Field, d) and !(kind == .count and std.meta.eql(d, @as(Field, 0)))) DefaultOf(Field, d).write else null) else null,
    };
}

fn DefaultOf(comptime F: type, comptime default: F) type {
    return struct {
        fn write(writer: *Writer) Writer.Error!void {
            return value.write(F, writer, default);
        }
    };
}

/// Whether `T` is a group: a struct whose fields are flags of their own.
pub fn isGroup(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and !value.isCustom(T);
}

fn isList(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .slice and info.pointer.child != u8;
}

/// What `T.meta` says of the field `name`, or nothing.
pub fn metaOf(comptime T: type, comptime name: []const u8) MetaOf(T, name) {
    return if (@hasDecl(T, "meta") and @hasField(@TypeOf(T.meta), name)) @field(T.meta, name) else .{};
}

fn MetaOf(comptime T: type, comptime name: []const u8) type {
    return if (@hasDecl(T, "meta") and @hasField(@TypeOf(T.meta), name)) @TypeOf(@field(T.meta, name)) else struct {};
}

/// The option `name` of a field's meta, or `default`.
pub fn option(comptime meta: anytype, comptime name: []const u8, comptime default: anytype) if (@hasField(@TypeOf(meta), name)) @TypeOf(@field(meta, name)) else @TypeOf(default) {
    return if (@hasField(@TypeOf(meta), name)) @field(meta, name) else default;
}

fn checkMeta(comptime T: type) void {
    if (!@hasDecl(T, "meta")) return;
    const entries = @typeInfo(@TypeOf(T.meta)).@"struct";
    for (entries.field_names, entries.field_types) |entry, Entry| {
        if (!@hasField(T, entry)) @compileError("cli: " ++ @typeName(T) ++ ".meta has " ++ entry ++ ", which is not a field of " ++ @typeName(T));
        for (@typeInfo(Entry).@"struct".field_names) |key| {
            for (option_names) |known| {
                if (std.mem.eql(u8, key, known)) break;
            } else @compileError("cli: " ++ key ++ " in " ++ @typeName(T) ++ ".meta." ++ entry ++ " is not an option; the options are help, short, long, env, positional, value_name, hidden, separator and count");
        }
    }
}

fn checkCommandMeta(comptime U: type) void {
    if (!@hasDecl(U, "meta")) return;
    const entries = @typeInfo(@TypeOf(U.meta)).@"struct";
    for (entries.field_names, entries.field_types) |entry, Entry| {
        if (!@hasField(U, entry)) @compileError("cli: " ++ @typeName(U) ++ ".meta has " ++ entry ++ ", which is not a command of " ++ @typeName(U));
        for (@typeInfo(Entry).@"struct".field_names) |key| {
            for (command_option_names) |known| {
                if (std.mem.eql(u8, key, known)) break;
            } else @compileError("cli: " ++ key ++ " in " ++ @typeName(U) ++ ".meta." ++ entry ++ " is not an option of a command; those are help and hidden");
        }
    }
}

/// What a command's payload is parsed as: its struct, or for `void` an
/// empty one, described by the command's help.
pub fn Payload(comptime U: type, comptime tag: []const u8) type {
    const T = @FieldType(U, tag);
    if (T == void) return struct {
        pub const description = commandHelp(U, tag);
    };
    if (@typeInfo(T) != .@"struct") @compileError("cli: the command " ++ tag ++ " of " ++ @typeName(U) ++ " must hold a struct or nothing");
    return T;
}

/// What a command does: its meta's help, or else the first line of its
/// struct's description.
pub fn commandHelp(comptime U: type, comptime tag: []const u8) []const u8 {
    const meta = metaOf(U, tag);
    if (@hasField(@TypeOf(meta), "help")) return meta.help;
    const T = @FieldType(U, tag);
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "description")) {
        const text: []const u8 = T.description;
        return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    }
    return "";
}
