//! Help and usage, written from what `spec` worked out.
const std = @import("std");
const Writer = std.Io.Writer;

const spec = @import("spec.zig");
const value = @import("value.zig");

/// Who help is written for.
pub const Target = struct {
    /// The program's name, as it is run.
    program: []const u8,
    /// The commands given before the arguments the help is about.
    commands: []const []const u8 = &.{},
    /// The prefix environment variables are read with.
    env_prefix: []const u8 = "",
};

pub const Write = *const fn (writer: *Writer, target: Target) Writer.Error!void;

pub fn Of(comptime T: type) type {
    return struct {
        pub fn help(writer: *Writer, target: Target) Writer.Error!void {
            return writeHelp(T, writer, target);
        }

        pub fn usage(writer: *Writer, target: Target) Writer.Error!void {
            return writeUsage(T, writer, target);
        }
    };
}

/// Writes the line saying what `T` takes, as in
/// `Usage: app [options] <input> [<rest>...]`.
pub fn writeUsage(comptime T: type, writer: *Writer, target: Target) Writer.Error!void {
    const analysis = comptime spec.analyze(T);
    try writer.print("Usage: {s}", .{target.program});
    for (target.commands) |command| try writer.print(" {s}", .{command});
    try writer.writeAll(" [options]");
    inline for (analysis.positionals) |index| {
        const s = analysis.specs[index];
        const label = comptime positionalLabel(s);
        try writer.writeAll(if (s.required) " " ++ label else " [" ++ label ++ "]");
    }
    if (comptime analysis.command) |command| try writer.writeAll(if (command.required) " <command>" else " [<command>]");
    try writer.writeByte('\n');
}

/// Writes `T`'s description, usage, arguments, options and commands.
pub fn writeHelp(comptime T: type, writer: *Writer, target: Target) Writer.Error!void {
    const analysis = comptime spec.analyze(T);
    if (@hasDecl(T, "description")) try writer.print("{s}\n\n", .{@as([]const u8, T.description)});
    try writeUsage(T, writer, target);

    if (analysis.positionals.len > 0) {
        try writer.writeAll("\nArguments:\n");
        const width = comptime width: {
            var widest: usize = 0;
            for (analysis.positionals) |index| widest = @max(widest, positionalLabel(analysis.specs[index]).len);
            break :width widest;
        };
        inline for (analysis.positionals) |index| {
            const s = analysis.specs[index];
            try row(writer, s, comptime positionalLabel(s), width, target);
        }
    }

    try writer.writeAll("\nOptions:\n");
    const help_label = if (analysis.short_help) "-h, --help" else "    --help";
    const width = comptime width: {
        var widest: usize = help_label.len;
        for (analysis.specs) |s| if (!s.positional and !s.hidden) {
            widest = @max(widest, flagLabel(s).len);
        };
        break :width widest;
    };
    inline for (analysis.specs) |s| if (!s.positional and !s.hidden) try row(writer, s, comptime flagLabel(s), width, target);
    try writer.writeAll("  " ++ help_label);
    try writer.splatByteAll(' ', width - help_label.len + 2);
    try writer.writeAll("Show this help\n");

    if (comptime analysis.command) |command| {
        const fields = @typeInfo(command.Union).@"union".fields;
        try writer.writeAll("\nCommands:\n");
        const command_width = comptime width: {
            var widest: usize = 0;
            for (fields) |field| widest = @max(widest, field.name.len);
            break :width widest;
        };
        inline for (fields) |field| {
            if (comptime spec.option(spec.metaOf(command.Union, field.name), "hidden", false)) continue;
            const name = comptime value.kebab(field.name);
            const about = comptime spec.commandHelp(command.Union, field.name);
            try writer.writeAll("  " ++ name);
            if (about.len > 0) {
                try writer.splatByteAll(' ', command_width - name.len + 2);
                try writer.writeAll(about);
            }
            try writer.writeByte('\n');
        }
    }
}

fn row(writer: *Writer, comptime s: spec.Spec, comptime label: []const u8, comptime width: usize, target: Target) Writer.Error!void {
    const choices = comptime if (@typeInfo(s.Value) == .@"enum" and !value.isCustom(s.Value)) "[possible: " ++ value.choices(s.Value, ", ") ++ "]" else "";
    const env: ?[]const u8 = if (s.env) |name| (if (!s.needs_prefix or target.env_prefix.len > 0) name else null) else null;
    try writer.writeAll("  " ++ label);
    if (s.help.len == 0 and choices.len == 0 and s.default == null and env == null) return writer.writeByte('\n');
    try writer.splatByteAll(' ', width - label.len + 2);
    var spaced = false;
    if (s.help.len > 0) {
        try writer.writeAll(s.help);
        spaced = true;
    }
    if (choices.len > 0) {
        if (spaced) try writer.writeByte(' ');
        try writer.writeAll(choices);
        spaced = true;
    }
    if (s.default) |write| {
        if (spaced) try writer.writeByte(' ');
        try writer.writeAll("[default: ");
        try write(writer);
        try writer.writeByte(']');
        spaced = true;
    }
    if (env) |name| {
        if (spaced) try writer.writeByte(' ');
        try writer.print("[env: {s}{s}]", .{ if (s.prefixed) target.env_prefix else "", name });
    }
    try writer.writeByte('\n');
}

fn flagLabel(comptime s: spec.Spec) []const u8 {
    const short = if (s.short) |c| "-" ++ [_]u8{c} ++ ", " else "    ";
    const takes = switch (s.kind) {
        .toggle, .count => "",
        .single => " <" ++ s.value_name ++ ">",
        .list => " <" ++ s.value_name ++ ">...",
    };
    return short ++ "--" ++ s.long ++ takes;
}

fn positionalLabel(comptime s: spec.Spec) []const u8 {
    return "<" ++ s.long ++ ">" ++ (if (s.kind == .list) "..." else "");
}
