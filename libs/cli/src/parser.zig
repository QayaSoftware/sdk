//! Arguments and environment variables parsed into a struct, by what `spec`
//! worked out of its type.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const spec = @import("spec.zig");
const value = @import("value.zig");
const help = @import("help.zig");

pub const Error = Allocator.Error || error{
    /// `--help` or `-h` was given: `Diagnostics.writeHelp` writes the help
    /// asked for.
    Help,
    /// A flag that no field is.
    UnknownFlag,
    /// A flag that takes a value was given none.
    MissingValue,
    /// A value that is not its field's type.
    InvalidValue,
    /// Nothing gave a value to a field that has no default and is not
    /// optional.
    MissingArgument,
    /// A positional argument with no field left to take it.
    UnexpectedArgument,
    UnknownCommand,
    MissingCommand,
};

pub const Options = struct {
    /// Where fields fall back to before their defaults.
    env: ?*const std.process.Environ.Map = null,
    /// What every field's environment variable starts with, as `APP_` for
    /// `APP_PORT`. Fields read the variables named after them only when
    /// there is one, so a field named `path` never reads `PATH`.
    env_prefix: []const u8 = "",
    diagnostics: ?*Diagnostics = null,
};

/// What went wrong, and the command it went wrong in, for its help.
pub const Diagnostics = struct {
    err: ?Error = null,
    /// The flag, positional argument or environment variable it is about,
    /// as `--port`, `-p`, `<file>` or `PORT`.
    name: []const u8 = "",
    /// The value rejected, the argument not expected, or the command not
    /// known.
    value: []const u8 = "",
    /// What the value should have been, as `an integer from 0 to 65535`.
    expected: []const u8 = "",
    /// A known name close to an unknown one.
    suggestion: ?[]const u8 = null,
    /// Whether `name` is an environment variable, after `prefix`.
    env: bool = false,
    prefix: []const u8 = "",
    /// The environment variable, after `alternative_prefix`, that could have
    /// given what is missing.
    alternative: ?[]const u8 = null,
    alternative_prefix: []const u8 = "",
    /// The prefix environment variables were read with.
    env_prefix: []const u8 = "",
    /// The commands given, down to the one parsing stopped in.
    commands: [max_commands][]const u8 = undefined,
    depth: usize = 0,
    write_help: ?help.Write = null,
    write_usage: ?help.Write = null,

    pub const max_commands = 8;

    pub fn format(self: Diagnostics, writer: *Writer) Writer.Error!void {
        const err = self.err orelse return writer.writeAll("no error");
        switch (err) {
            error.Help => try writer.writeAll("help was asked for"),
            error.OutOfMemory => try writer.writeAll("out of memory"),
            error.UnknownFlag => try writer.print("unknown flag '{s}'", .{self.name}),
            error.MissingValue => try writer.print("'{s}' needs a value", .{self.name}),
            error.InvalidValue => if (self.env)
                try writer.print("invalid value '{s}' in {s}{s}: expected {s}", .{ self.value, self.prefix, self.name, self.expected })
            else
                try writer.print("invalid value '{s}' for '{s}': expected {s}", .{ self.value, self.name, self.expected }),
            error.MissingArgument => {
                try writer.print("missing '{s}'", .{self.name});
                if (self.alternative) |alternative| try writer.print(", which {s}{s} can also give", .{ self.alternative_prefix, alternative });
            },
            error.UnexpectedArgument => try writer.print("unexpected argument '{s}'", .{self.value}),
            error.UnknownCommand => try writer.print("unknown command '{s}'", .{self.value}),
            error.MissingCommand => try writer.print("missing a command: {s}", .{self.expected}),
        }
        if (self.suggestion) |suggestion| try writer.print("; did you mean '{s}'?", .{suggestion});
    }

    /// Writes the help for the command parsing stopped in: what `--help`
    /// asked for, or where the error is.
    pub fn writeHelp(self: *const Diagnostics, writer: *Writer, program: []const u8) Writer.Error!void {
        const write = self.write_help orelse return;
        return write(writer, self.target(program));
    }

    /// Writes the usage line of the command parsing stopped in.
    pub fn writeUsage(self: *const Diagnostics, writer: *Writer, program: []const u8) Writer.Error!void {
        const write = self.write_usage orelse return;
        return write(writer, self.target(program));
    }

    fn target(self: *const Diagnostics, program: []const u8) help.Target {
        return .{ .program = program, .commands = self.commands[0..self.depth], .env_prefix = self.env_prefix };
    }
};

pub fn parseLeaky(comptime T: type, arena: Allocator, args: []const []const u8, options: Options) Error!T {
    var local: Diagnostics = .{};
    const diagnostics = options.diagnostics orelse &local;
    diagnostics.* = .{ .env_prefix = options.env_prefix };
    var state: State = .{ .arena = arena, .options = options, .diagnostics = diagnostics };
    return parseStruct(T, args, &state);
}

/// A flag or positional argument as given.
const Given = struct {
    /// Its value; null for a toggle or count given without one.
    text: ?[]const u8,
    /// How it was written: `--port`, `-p` or `<file>`.
    name: []const u8,
};

const State = struct {
    arena: Allocator,
    options: Options,
    diagnostics: *Diagnostics,

    const Details = struct {
        name: []const u8 = "",
        value: []const u8 = "",
        expected: []const u8 = "",
        suggestion: ?[]const u8 = null,
        env: bool = false,
        prefix: []const u8 = "",
        alternative: ?[]const u8 = null,
        alternative_prefix: []const u8 = "",
    };

    fn fail(self: *State, err: Error, details: Details) Error {
        const diagnostics = self.diagnostics;
        diagnostics.err = err;
        inline for (@typeInfo(Details).@"struct".field_names) |field_name| @field(diagnostics, field_name) = @field(details, field_name);
        return err;
    }

    /// Makes `T` the command errors and help are about.
    fn enter(self: *State, comptime T: type) void {
        self.diagnostics.write_help = help.Of(T).help;
        self.diagnostics.write_usage = help.Of(T).usage;
    }
};

/// `-` and each byte, for naming a short flag by its byte.
const short_names = names: {
    var names: [256][2]u8 = undefined;
    for (&names, 0..) |*name, c| name.* = .{ '-', c };
    break :names names;
};

fn parseStruct(comptime T: type, args: []const []const u8, state: *State) Error!T {
    const analysis = comptime spec.analyze(T);
    const specs = analysis.specs;
    const flag_names = comptime names: {
        var names: []const []const u8 = &.{"--help"};
        for (specs) |s| if (!s.positional and !s.hidden) {
            names = names ++ [_][]const u8{s.display()};
        };
        break :names names;
    };
    const arena = state.arena;
    state.enter(T);

    var result: T = undefined;
    initDefaults(T, &result);
    var given_lists: [specs.len]std.ArrayList(Given) = @splat(.empty);
    const given: []std.ArrayList(Given) = &given_lists;
    var next_positional: usize = 0;
    var command_at: ?usize = null;
    var only_positional = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!only_positional) {
            if (std.mem.eql(u8, arg, "--")) {
                only_positional = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--help") or (analysis.short_help and std.mem.eql(u8, arg, "-h"))) {
                return state.fail(error.Help, .{});
            }
            if (std.mem.startsWith(u8, arg, "--")) {
                const body = arg[2..];
                const equals = std.mem.indexOfScalar(u8, body, '=');
                const name = body[0 .. equals orelse body.len];
                const spelled = arg[0 .. 2 + name.len];
                const attached: ?[]const u8 = if (equals) |at| body[at + 1 ..] else null;
                if (findLong(specs, name)) |index| {
                    const text = switch (kindOf(specs, index)) {
                        .toggle, .count => attached,
                        .single, .list => attached orelse take: {
                            i += 1;
                            if (i == args.len) return state.fail(error.MissingValue, .{ .name = spelled });
                            break :take args[i];
                        },
                    };
                    try given[index].append(arena, .{ .text = text, .name = spelled });
                } else if (negated(specs, name)) |index| {
                    if (attached != null) return state.fail(error.UnknownFlag, .{ .name = spelled });
                    try given[index].append(arena, .{ .text = "false", .name = spelled });
                } else {
                    return state.fail(error.UnknownFlag, .{ .name = spelled, .suggestion = closest(spelled, flag_names) });
                }
                continue;
            }
            if (arg.len > 1 and arg[0] == '-' and !(isNumeric(arg[1]) and findShort(specs, arg[1]) == null)) {
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    const name: []const u8 = &short_names[arg[j]];
                    const index = findShort(specs, arg[j]) orelse {
                        if (analysis.short_help and arg[j] == 'h') return state.fail(error.Help, .{});
                        return state.fail(error.UnknownFlag, .{ .name = name });
                    };
                    switch (kindOf(specs, index)) {
                        .toggle, .count => try given[index].append(arena, .{ .text = null, .name = name }),
                        .single, .list => {
                            var rest = arg[j + 1 ..];
                            if (rest.len > 0 and rest[0] == '=') rest = rest[1..];
                            const text = if (rest.len > 0) rest else take: {
                                i += 1;
                                if (i == args.len) return state.fail(error.MissingValue, .{ .name = name });
                                break :take args[i];
                            };
                            try given[index].append(arena, .{ .text = text, .name = name });
                            break;
                        },
                    }
                }
                continue;
            }
        }
        if (analysis.positionals.len > 0 and next_positional < analysis.positionals.len) {
            const index = analysis.positionals[next_positional];
            try given[index].append(arena, .{ .text = arg, .name = displayOf(specs, index) });
            if (kindOf(specs, index) != .list) next_positional += 1;
        } else if (analysis.command != null) {
            command_at = i;
            break;
        } else {
            return state.fail(error.UnexpectedArgument, .{ .value = arg });
        }
    }

    if (comptime analysis.command) |command| {
        if (command_at) |at| {
            const depth = state.diagnostics.depth;
            try parseCommand(T, command, &result, args[at], args[at + 1 ..], state);
            state.diagnostics.depth = depth;
            state.enter(T);
        } else if (command.required) {
            return state.fail(error.MissingCommand, .{ .expected = comptime commandList(command.Union) });
        }
    }
    inline for (specs, 0..) |s, index| try apply(T, s, &result, given[index].items, state);
    return result;
}

fn parseCommand(comptime T: type, comptime command: spec.Command, result: *T, name: []const u8, rest: []const []const u8, state: *State) Error!void {
    const U = command.Union;
    const info = @typeInfo(U).@"union";
    inline for (info.field_names, info.field_types) |field_name, Field| {
        const word = comptime value.kebab(field_name);
        if (std.mem.eql(u8, name, word)) {
            const diagnostics = state.diagnostics;
            if (diagnostics.depth < diagnostics.commands.len) {
                diagnostics.commands[diagnostics.depth] = word;
                diagnostics.depth += 1;
            }
            const payload = try parseStruct(spec.Payload(U, field_name), rest, state);
            @field(result, command.field) = @unionInit(U, field_name, if (Field == void) {} else payload);
            return;
        }
    }
    return state.fail(error.UnknownCommand, .{ .value = name, .suggestion = closest(name, comptime commandNames(U)) });
}

/// Sets every field that has a value without being given one: its
/// default, null, false or zero.
fn initDefaults(comptime T: type, result: *T) void {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |field_name, Field, attrs| {
        const target = &@field(result, field_name);
        if (comptime attrs.defaultValue(Field)) |default| {
            target.* = default;
        } else if (@typeInfo(Field) == .optional) {
            target.* = null;
        } else if (Field == bool) {
            target.* = false;
        } else if (comptime spec.isGroup(Field)) {
            initDefaults(Field, target);
        } else if (comptime spec.option(spec.metaOf(T, field_name), "count", false)) {
            target.* = 0;
        }
    }
}

fn FieldOf(comptime T: type, comptime path: []const []const u8) type {
    const F = @FieldType(T, path[0]);
    return if (path.len == 1) F else FieldOf(F, path[1..]);
}

fn fieldOf(comptime T: type, comptime path: []const []const u8, result: *T) *FieldOf(T, path) {
    if (path.len == 1) return &@field(result, path[0]);
    return fieldOf(@FieldType(T, path[0]), path[1..], &@field(result, path[0]));
}

/// Gives the field `s` its value: from the arguments given, or else its
/// environment variable, or else its default.
fn apply(comptime T: type, comptime s: spec.Spec, result: *T, given: []const Given, state: *State) Error!void {
    const field = fieldOf(T, s.path, result);
    if (given.len > 0) return applyGiven(s, field, given, state);
    const prefix = if (s.prefixed) state.options.env_prefix else "";
    const env: ?[]const u8 = if (s.env) |name| (if (!s.needs_prefix or prefix.len > 0) name else null) else null;
    if (env) |name| if (state.options.env) |map| {
        var buffer: [256]u8 = undefined;
        if (std.fmt.bufPrint(&buffer, "{s}{s}", .{ prefix, name })) |full| {
            if (map.get(full)) |text| return applyEnv(s, field, text, name, prefix, state);
        } else |_| {}
    };
    if (s.required) return state.fail(error.MissingArgument, .{ .name = comptime s.display(), .alternative = env, .alternative_prefix = prefix });
}

fn applyGiven(comptime s: spec.Spec, field: *s.Field, given: []const Given, state: *State) Error!void {
    const last = given[given.len - 1];
    switch (s.kind) {
        .toggle => field.* = if (last.text) |text| value.parseBool(text) orelse return invalid(s, state, last.name, text, false, "") else true,
        .count => {
            var count: s.Value = 0;
            for (given) |one| {
                count = if (one.text) |text| try parseValue(s, state, one.name, text, false, "") else count +| 1;
            }
            field.* = count;
        },
        .single => field.* = try parseValue(s, state, last.name, last.text.?, false, ""),
        .list => {
            const items = try state.arena.alloc(s.Value, given.len);
            for (given, items) |one, *item| item.* = try parseValue(s, state, one.name, one.text.?, false, "");
            field.* = items;
        },
    }
}

fn applyEnv(comptime s: spec.Spec, field: *s.Field, text: []const u8, name: []const u8, prefix: []const u8, state: *State) Error!void {
    switch (s.kind) {
        .toggle => field.* = value.parseBool(text) orelse return invalid(s, state, name, text, true, prefix),
        .count, .single => field.* = try parseValue(s, state, name, text, true, prefix),
        .list => {
            const count = if (text.len == 0) 0 else std.mem.countScalar(u8, text, s.separator) + 1;
            const items = try state.arena.alloc(s.Value, count);
            var parts = std.mem.splitScalar(u8, text, s.separator);
            for (items) |*item| item.* = try parseValue(s, state, name, parts.next().?, true, prefix);
            field.* = items;
        },
    }
}

fn parseValue(comptime s: spec.Spec, state: *State, name: []const u8, text: []const u8, env: bool, prefix: []const u8) Error!s.Value {
    return value.parse(s.Value, state.arena, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidValue => invalid(s, state, name, text, env, prefix),
    };
}

fn invalid(comptime s: spec.Spec, state: *State, name: []const u8, text: []const u8, env: bool, prefix: []const u8) Error {
    return state.fail(error.InvalidValue, .{ .name = name, .value = text, .expected = comptime value.expected(s.Value), .env = env, .prefix = prefix });
}

fn findLong(comptime specs: []const spec.Spec, name: []const u8) ?usize {
    inline for (specs, 0..) |s, index| {
        if (!s.positional and std.mem.eql(u8, s.long, name)) return index;
    }
    return null;
}

/// The toggle `name` turns off as `no-<toggle>`.
fn negated(comptime specs: []const spec.Spec, name: []const u8) ?usize {
    if (!std.mem.startsWith(u8, name, "no-")) return null;
    const index = findLong(specs, name[3..]) orelse return null;
    inline for (specs, 0..) |s, at| if (at == index) return if (s.kind == .toggle) index else null;
    return null;
}

fn findShort(comptime specs: []const spec.Spec, c: u8) ?usize {
    inline for (specs, 0..) |s, index| {
        if (s.short) |short| if (!s.positional and short == c) return index;
    }
    return null;
}

fn displayOf(comptime specs: []const spec.Spec, index: usize) []const u8 {
    inline for (specs, 0..) |s, at| if (at == index) return comptime s.display();
    unreachable;
}

/// Whether an argument starting `-` and then `c` is a negative number.
fn isNumeric(c: u8) bool {
    return std.ascii.isDigit(c) or c == '.';
}

fn commandNames(comptime U: type) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (@typeInfo(U).@"union".field_names) |field_name| {
            if (!spec.option(spec.metaOf(U, field_name), "hidden", false)) names = names ++ [_][]const u8{value.kebab(field_name)};
        }
        return names;
    }
}

fn commandList(comptime U: type) []const u8 {
    comptime {
        const names = commandNames(U);
        var text: []const u8 = "";
        for (names, 0..) |name, i| {
            if (i > 0) text = text ++ (if (i + 1 == names.len) " or " else ", ");
            text = text ++ name;
        }
        return text;
    }
}

/// The candidate closest to `name` by edits, if it is close enough to be
/// what was meant.
fn closest(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance = @max(name.len / 3, 2) + 1;
    for (candidates) |candidate| {
        const d = distance(name, candidate);
        if (d < best_distance) {
            best = candidate;
            best_distance = d;
        }
    }
    return best;
}

/// How many bytes to insert, delete or change to make `a` into `b`.
fn distance(a: []const u8, b: []const u8) usize {
    var row: [64]usize = undefined;
    if (b.len >= row.len) return std.math.maxInt(usize);
    for (row[0 .. b.len + 1], 0..) |*cell, j| cell.* = j;
    for (a, 1..) |ca, i| {
        var diagonal = row[0];
        row[0] = i;
        for (b, 1..) |cb, j| {
            const above = row[j];
            row[j] = @min(above + 1, row[j - 1] + 1, diagonal + @intFromBool(ca != cb));
            diagonal = above;
        }
    }
    return row[b.len];
}

fn kindOf(comptime specs: []const spec.Spec, index: usize) spec.Kind {
    inline for (specs, 0..) |s, at| if (at == index) return s.kind;
    unreachable;
}
