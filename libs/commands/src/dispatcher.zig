const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Reader = @import("Reader.zig");
const Space = Reader.Space;
const arguments = @import("arguments.zig");
const suggestions = @import("suggestions.zig");
const Suggestion = suggestions.Suggestion;
const Suggestions = suggestions.Suggestions;
const SuggestionBuilder = suggestions.Builder;

/// A node of a dispatcher's graph: the root, a literal word or an argument.
pub const Node = enum(u32) {
    root = 0,
    _,
};

/// A node as parsed: which one, where in the input, and its argument's
/// value, in the parse's buffer.
pub const Parsed = struct {
    node: Node,
    start: u32,
    end: u32,
    value: ?*const anyopaque,
};

pub const RegisterError = Allocator.Error || error{
    /// The name is empty or has a space in it.
    InvalidName,
    /// The parent redirects, so it cannot have children; or the node has
    /// children, so it cannot redirect.
    Redirected,
    /// An argument of that name, of another argument type, is already there.
    Conflict,
};

pub const ParseError = error{
    /// Nothing matched the first word.
    UnknownCommand,
    /// Nothing matched a word after the first.
    UnknownArgument,
    /// An argument rejected its text; the diagnostics say how.
    InvalidArgument,
    /// The input ended where no command is.
    IncompleteCommand,
    /// The buffer is too small for the nodes parsed and their values.
    NoSpaceLeft,
};

/// How big the buffer `execute` and `suggest` parse into is, on the stack.
pub const default_buffer_size = 4096;

/// Where and why a parse failed.
pub const Diagnostics = struct {
    input: []const u8 = "",
    /// Where in `input` the problem is.
    cursor: usize = 0,
    /// The error the parse returned, or for `error.InvalidArgument` the
    /// argument's own, such as `error.ExpectedInteger`.
    err: anyerror = error.UnknownCommand,
    /// The argument type, when it can explain `err`.
    describe: ?Describe = null,

    pub const Describe = struct {
        state: *const anyopaque,
        call: *const fn (state: *const anyopaque, err: anyerror, writer: *Writer) Writer.Error!bool,
    };

    /// Writes the error as a sentence, then where it is, as in
    /// `Expected integer at position 3: tp <--[HERE]`.
    pub fn format(self: Diagnostics, writer: *Writer) Writer.Error!void {
        const described = if (self.describe) |describe| try describe.call(describe.state, self.err, writer) else false;
        if (!described) try writer.writeAll(message(self.err));
        try writer.print(" at position {d}: ", .{self.cursor});
        const shown = self.cursor -| 10;
        if (shown > 0) try writer.writeAll("...");
        try writer.print("{s}<--[HERE]", .{self.input[shown..self.cursor]});
    }
};

/// A sentence for the errors parsing fails with, or the error's name.
pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownCommand => "Unknown command",
        error.UnknownArgument => "Incorrect argument for command",
        error.IncompleteCommand => "Incomplete command",
        error.ExpectedSeparator => "Expected whitespace to end one argument, but found trailing data",
        error.NoSpaceLeft => "Command is too long",
        error.ExpectedInteger => "Expected integer",
        error.InvalidInteger => "Invalid integer",
        error.IntegerTooSmall => "Integer is too small",
        error.IntegerTooLarge => "Integer is too large",
        error.ExpectedFloat => "Expected float",
        error.InvalidFloat => "Invalid float",
        error.FloatTooSmall => "Float is too small",
        error.FloatTooLarge => "Float is too large",
        error.ExpectedBool => "Expected bool",
        error.InvalidBool => "Invalid bool, expected true or false",
        error.ExpectedStartOfQuote => "Expected quote to start a string",
        error.ExpectedEndOfQuote => "Unclosed quoted string",
        error.InvalidEscape => "Invalid escape sequence in quoted string",
        error.ExpectedSymbol => "Expected a symbol",
        error.ExpectedWord => "Expected a word",
        error.InvalidChoice => "Invalid choice",
        else => @errorName(err),
    };
}

/// Commands as a graph from a root: literal words and typed arguments, each
/// node maybe running a command where the input ends there, and maybe
/// redirecting to another node, so commands chain into each other as
/// `execute as <targets> run <command>` does. `Source` is what commands run
/// for, such as a player or the console: given to each parse, it decides
/// which nodes are there at all.
///
/// Registering needs the dispatcher to itself. Parsing, executing,
/// suggesting and writing usage only read it, keeping their state on the
/// caller's stack or in the caller's buffer, so once registered any number
/// of threads can do those at once without locks.
pub fn Dispatcher(comptime Source: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        /// The names and argument types.
        arena: std.heap.ArenaAllocator,
        /// Every node, the root first once anything is registered.
        nodes: std.ArrayList(Data) = .empty,

        /// Runs a command, the input parsed into `ctx`.
        pub const Command = *const fn (ctx: *const Context) anyerror!void;
        /// Whether `source` can use a node; a node it cannot is not there
        /// for it.
        pub const Requirement = *const fn (source: Source) bool;
        /// The source a redirect goes on with.
        pub const Modifier = *const fn (ctx: *const Context) anyerror!Source;
        /// Gives each source a fork goes on with to `sources.add`.
        pub const Fork = *const fn (ctx: *const Context, sources: *Sources) anyerror!void;
        /// Suggests values for an argument being typed, in place of its
        /// argument type's suggestions.
        pub const Suggester = *const fn (ctx: *const Context, builder: *SuggestionBuilder) anyerror!void;

        /// Where parsing goes on after a node: among `target`'s children,
        /// in a new context.
        pub const Redirect = struct {
            target: Node,
            modify: Modify = .none,

            pub const Modify = union(enum) {
                /// The source stays as it was.
                none,
                /// The rest runs with the source this gives.
                map: Modifier,
                /// The rest runs once for each source this gives, and its
                /// errors are dropped: what runs is counted instead.
                fork: Fork,
            };

            pub fn to(target: Node) Redirect {
                return .{ .target = target };
            }

            pub fn map(target: Node, modifier: Modifier) Redirect {
                return .{ .target = target, .modify = .{ .map = modifier } };
            }

            pub fn fork(target: Node, each: Fork) Redirect {
                return .{ .target = target, .modify = .{ .fork = each } };
            }
        };

        pub const Options = struct {
            /// Runs when the input ends at the node.
            executes: ?Command = null,
            requires: ?Requirement = null,
            /// For an argument: suggests its values.
            suggests: ?Suggester = null,
            redirect: ?Redirect = null,
        };

        /// What a command runs with: its source, and the nodes parsed since
        /// the last redirect.
        pub const Context = struct {
            dispatcher: *const Self,
            source: Source,
            input: []const u8,
            nodes: []const Parsed,

            /// The value of the argument `name`, a `T`; it must be there.
            pub fn argument(self: *const Context, comptime T: type, name: []const u8) T {
                return self.optional(T, name) orelse std.debug.panic("commands: no argument '{s}' in '{s}'", .{ name, self.text() });
            }

            /// The value of the argument `name`, a `T`, if it was parsed.
            pub fn optional(self: *const Context, comptime T: type, name: []const u8) ?T {
                for (self.nodes) |parsed| {
                    const node = self.dispatcher.data(parsed.node);
                    const arg = node.argument orelse continue;
                    if (!std.mem.eql(u8, node.name, name)) continue;
                    if (std.debug.runtime_safety and !std.mem.eql(u8, arg.vtable.type_name, @typeName(T))) {
                        std.debug.panic("commands: argument '{s}' is a {s}, not a {s}", .{ name, arg.vtable.type_name, @typeName(T) });
                    }
                    return @as(*const T, @ptrCast(@alignCast(parsed.value.?))).*;
                }
                return null;
            }

            /// The input this context parsed.
            pub fn text(self: *const Context) []const u8 {
                if (self.nodes.len == 0) return "";
                return self.input[self.nodes[0].start..self.nodes[self.nodes.len - 1].end];
            }
        };

        /// The sources a fork goes on with.
        pub const Sources = struct {
            dispatcher: *const Self,
            input: []const u8,
            nodes: []const Parsed,
            /// How many commands ran without an error.
            count: usize = 0,

            /// Runs the rest of the command with `source`, dropping its
            /// errors.
            pub fn add(self: *Sources, source: Source) void {
                self.count += self.dispatcher.run(self.input, self.nodes, source, true) catch 0;
            }
        };

        /// An input parsed to a command, ready to run. It points into the
        /// input and the buffer it was parsed into, so it lasts as long as
        /// they do and the dispatcher is not changed; with them it can be
        /// handed to another thread to run.
        pub const Parse = struct {
            dispatcher: *const Self,
            source: Source,
            input: []const u8,
            nodes: []const Parsed,

            /// Runs the command, and returns how many times it ran: once,
            /// or once for each source after a fork, less the runs that
            /// failed. Without a fork, the command's error is returned.
            pub fn execute(self: *const Parse) anyerror!usize {
                return self.dispatcher.run(self.input, self.nodes, self.source, false);
            }
        };

        /// What a node is, for tools that show or send the graph.
        pub const Info = struct {
            name: []const u8,
            parent: Node,
            /// The argument's value type; null for a literal or the root.
            argument: ?[]const u8,
            executes: bool,
            redirect: ?Node,
        };

        const Data = struct {
            name: []const u8,
            parent: Node,
            argument: ?Argument,
            options: Options,
            /// Sorted by name, for parsing to find one by binary search.
            literals: std.ArrayList(Literal) = .empty,
            /// In the order added, which is the order parsing tries them in.
            arguments: std.ArrayList(Node) = .empty,
        };

        const Literal = struct { name: []const u8, node: Node };

        const Argument = struct {
            vtable: *const VTable,
            state: *const anyopaque,
        };

        const VTable = struct {
            kind_name: []const u8,
            type_name: []const u8,
            size: usize,
            alignment: std.mem.Alignment,
            parse: *const fn (state: *const anyopaque, reader: *Reader, source: *const Source, out: *anyopaque) anyerror!void,
            suggest: ?*const fn (state: *const anyopaque, builder: *SuggestionBuilder) anyerror!void,
            describe: ?*const fn (state: *const anyopaque, err: anyerror, writer: *Writer) Writer.Error!bool,
        };

        fn Erased(comptime K: type) type {
            return struct {
                const vtable: VTable = .{
                    .kind_name = @typeName(K),
                    .type_name = @typeName(K.Value),
                    .size = @sizeOf(K.Value),
                    .alignment = .of(K.Value),
                    .parse = parseValue,
                    .suggest = if (@hasDecl(K, "suggest")) suggestValues else null,
                    .describe = if (@hasDecl(K, "describe")) describeError else null,
                };

                const takes_source = @typeInfo(@TypeOf(K.parse)).@"fn".params.len == 3;

                fn parseValue(state: *const anyopaque, reader: *Reader, source: *const Source, out: *anyopaque) anyerror!void {
                    const kind: *const K = @ptrCast(@alignCast(state));
                    const value: *K.Value = @ptrCast(@alignCast(out));
                    value.* = if (takes_source) try kind.parse(reader, source.*) else try kind.parse(reader);
                }

                fn suggestValues(state: *const anyopaque, builder: *SuggestionBuilder) anyerror!void {
                    const kind: *const K = @ptrCast(@alignCast(state));
                    return kind.suggest(builder);
                }

                fn describeError(state: *const anyopaque, err: anyerror, writer: *Writer) Writer.Error!bool {
                    const kind: *const K = @ptrCast(@alignCast(state));
                    return kind.describe(err, writer);
                }
            };
        }

        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa, .arena = .init(gpa) };
        }

        pub fn deinit(self: *Self) void {
            for (self.nodes.items) |*node| {
                node.literals.deinit(self.gpa);
                node.arguments.deinit(self.gpa);
            }
            self.nodes.deinit(self.gpa);
            self.arena.deinit();
            self.* = undefined;
        }

        /// Adds the literal word `name` under `parent`, or gives the one
        /// already there `options`.
        pub fn literal(self: *Self, parent: Node, name: []const u8, options: Options) RegisterError!Node {
            try checkName(name);
            try self.addRoot();
            const literals = self.data(parent).literals.items;
            const index = lowerBound(literals, name);
            if (index < literals.len and std.mem.eql(u8, literals[index].name, name)) {
                const existing = literals[index].node;
                try self.configure(existing, options);
                return existing;
            }
            return self.addChild(parent, name, null, index, options);
        }

        /// Adds the argument `name` under `parent`, parsed by `kind`: an
        /// argument type, or an integer, float, bool or enum type. Gives the
        /// argument already there `options` if it has the same type.
        pub fn argument(self: *Self, parent: Node, name: []const u8, kind: anytype, options: Options) RegisterError!Node {
            const K = if (@TypeOf(kind) == type) arguments.Of(kind) else @TypeOf(kind);
            comptime arguments.check(K);
            try checkName(name);
            try self.addRoot();
            const vtable = &Erased(K).vtable;
            for (self.data(parent).arguments.items) |existing| {
                const node = self.data(existing);
                if (!std.mem.eql(u8, node.name, name)) continue;
                if (!std.mem.eql(u8, node.argument.?.vtable.kind_name, vtable.kind_name)) return error.Conflict;
                try self.configure(existing, options);
                return existing;
            }
            const state = try self.arena.allocator().create(K);
            state.* = if (@TypeOf(kind) == type) .{} else kind;
            return self.addChild(parent, name, .{ .vtable = vtable, .state = state }, 0, options);
        }

        /// Gives `node` the options set in `options`, keeping the others.
        pub fn configure(self: *Self, node: Node, options: Options) RegisterError!void {
            const target = self.data(node);
            if (options.redirect) |redirect| {
                std.debug.assert(@intFromEnum(redirect.target) < self.nodes.items.len);
                if (target.literals.items.len + target.arguments.items.len > 0) return error.Redirected;
                target.options.redirect = redirect;
            }
            if (options.executes) |executes| target.options.executes = executes;
            if (options.requires) |requires| target.options.requires = requires;
            if (options.suggests) |suggests| target.options.suggests = suggests;
        }

        fn addRoot(self: *Self) Allocator.Error!void {
            if (self.nodes.items.len > 0) return;
            try self.nodes.append(self.gpa, .{ .name = "", .parent = .root, .argument = null, .options = .{} });
        }

        fn addChild(self: *Self, parent: Node, name: []const u8, arg: ?Argument, index: usize, options: Options) RegisterError!Node {
            if (self.data(parent).options.redirect != null) return error.Redirected;
            if (options.redirect) |redirect| std.debug.assert(@intFromEnum(redirect.target) < self.nodes.items.len);
            const owned = try self.arena.allocator().dupe(u8, name);
            try self.nodes.ensureUnusedCapacity(self.gpa, 1);
            const owner = self.data(parent);
            if (arg == null) try owner.literals.ensureUnusedCapacity(self.gpa, 1) else try owner.arguments.ensureUnusedCapacity(self.gpa, 1);
            const node: Node = @enumFromInt(self.nodes.items.len);
            self.nodes.appendAssumeCapacity(.{ .name = owned, .parent = parent, .argument = arg, .options = options });
            if (arg == null) owner.literals.insertAssumeCapacity(index, .{ .name = owned, .node = node }) else owner.arguments.appendAssumeCapacity(node);
            return node;
        }

        fn checkName(name: []const u8) error{InvalidName}!void {
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, ' ') != null) return error.InvalidName;
        }

        fn data(self: *const Self, node: Node) *Data {
            return &self.nodes.items[@intFromEnum(node)];
        }

        fn lowerBound(literals: []const Literal, name: []const u8) usize {
            var low: usize = 0;
            var high = literals.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (std.mem.order(u8, literals[mid].name, name) == .lt) low = mid + 1 else high = mid;
            }
            return low;
        }

        fn findLiteral(literals: []const Literal, name: []const u8) ?Node {
            const index = lowerBound(literals, name);
            if (index < literals.len and std.mem.eql(u8, literals[index].name, name)) return literals[index].node;
            return null;
        }

        fn canUse(self: *const Self, node: Node, source: *const Source) bool {
            const requires = self.data(node).options.requires orelse return true;
            return requires(source.*);
        }

        /// Parses `input` for `source` into `buffer`, to a command ready to
        /// run. On an error, `diagnostics` says where and why.
        pub fn parse(self: *const Self, input: []const u8, source: Source, buffer: []u8, diagnostics: ?*Diagnostics) ParseError!Parse {
            var parser: Parser = .{ .dispatcher = self, .source = &source, .input = input, .space = .init(buffer) };
            const found = if (self.nodes.items.len == 0 or input.len > std.math.maxInt(u32)) false else parser.walk(.root, 0) catch {
                return fail(diagnostics, input, error.NoSpaceLeft, 0, error.NoSpaceLeft, null);
            };
            if (found) return .{ .dispatcher = self, .source = source, .input = input, .nodes = parser.space.stack(Parsed) };
            if (parser.incomplete) return fail(diagnostics, input, error.IncompleteCommand, input.len, error.IncompleteCommand, null);
            const failure = parser.failure;
            if (failure.err) |err| {
                const arg = failure.argument;
                const describe: ?Diagnostics.Describe = if (arg) |a| if (a.vtable.describe) |call| .{ .state = a.state, .call = call } else null else null;
                return fail(diagnostics, input, error.InvalidArgument, failure.cursor, err, describe);
            }
            const err: ParseError = if (failure.parsed) error.UnknownArgument else error.UnknownCommand;
            return fail(diagnostics, input, err, failure.cursor, err, null);
        }

        fn fail(diagnostics: ?*Diagnostics, input: []const u8, err: ParseError, cursor: usize, cause: anyerror, describe: ?Diagnostics.Describe) ParseError {
            if (diagnostics) |diag| diag.* = .{ .input = input, .cursor = @min(cursor, input.len), .err = cause, .describe = describe };
            return err;
        }

        /// Parses and runs `input` for `source`, parsing into a buffer of
        /// `default_buffer_size` on the stack. Returns how many times the
        /// command ran, as `Parse.execute` does.
        pub fn execute(self: *const Self, input: []const u8, source: Source, diagnostics: ?*Diagnostics) anyerror!usize {
            var buffer: [default_buffer_size]u8 = undefined;
            const parsed = try self.parse(input, source, &buffer, diagnostics);
            return parsed.execute();
        }

        fn run(self: *const Self, input: []const u8, nodes: []const Parsed, source: Source, forked: bool) anyerror!usize {
            const split = for (nodes[0 .. nodes.len - 1], 1..) |parsed, after| {
                if (self.data(parsed.node).options.redirect != null) break after;
            } else nodes.len;
            const ctx: Context = .{ .dispatcher = self, .source = source, .input = input, .nodes = nodes[0..split] };
            const last = self.data(nodes[split - 1].node);
            if (split == nodes.len) {
                last.options.executes.?(&ctx) catch |err| {
                    if (forked) return 0;
                    return err;
                };
                return 1;
            }
            const rest = nodes[split..];
            switch (last.options.redirect.?.modify) {
                .none => return self.run(input, rest, source, forked),
                .map => |modifier| {
                    const next = modifier(&ctx) catch |err| {
                        if (forked) return 0;
                        return err;
                    };
                    return self.run(input, rest, next, forked);
                },
                .fork => |each| {
                    var sources: Sources = .{ .dispatcher = self, .input = input, .nodes = rest };
                    each(&ctx, &sources) catch {};
                    return sources.count;
                },
            }
        }

        /// Suggestions for going on with `input` for `source`: the input up
        /// to the cursor, for suggestions at the cursor.
        pub fn suggest(self: *const Self, gpa: Allocator, input: []const u8, source: Source) anyerror!Suggestions {
            var result: Suggestions = .{ .arena = .init(gpa) };
            errdefer result.deinit();
            if (self.nodes.items.len == 0 or input.len > std.math.maxInt(u32)) return result;
            var buffer: [default_buffer_size]u8 = undefined;
            var parser: Parser = .{ .dispatcher = self, .source = &source, .input = input, .space = .init(&buffer) };
            var list: std.ArrayList(Suggestion) = .empty;
            var builder: SuggestionBuilder = .{ .input = input, .start = 0, .arena = result.arena.allocator(), .list = &list };
            try parser.complete(.root, 0, 0, &builder);
            result.items = suggestions.finish(list.items);
            return result;
        }

        /// Writes a line for each child of `node` that `source` can use:
        /// how to go on from `node`, in short, as in
        /// `give <target> <item> [<count>]`, `time (set|query)` and
        /// `run ...` for a redirect to the root.
        pub fn usage(self: *const Self, writer: *Writer, node: Node, source: Source) Writer.Error!void {
            if (self.nodes.items.len == 0) return;
            const optional = self.data(node).options.executes != null;
            var each = self.children(node);
            while (each.next()) |next| {
                if (!self.canUse(next, &source)) continue;
                try self.smartUsage(writer, next, &source, optional, false);
                try writer.writeByte('\n');
            }
        }

        /// Writes a line for each command under `node` that `source` can
        /// use, from `node`'s children down.
        pub fn allUsage(self: *const Self, writer: *Writer, node: Node, source: Source) Writer.Error!void {
            if (self.nodes.items.len == 0) return;
            var each = self.children(node);
            while (each.next()) |next| try self.allUsageOf(writer, next, &source, null);
        }

        const Prefix = struct { node: Node, parent: ?*const Prefix };

        fn allUsageOf(self: *const Self, writer: *Writer, node: Node, source: *const Source, parent: ?*const Prefix) Writer.Error!void {
            if (!self.canUse(node, source)) return;
            const prefix: Prefix = .{ .node = node, .parent = parent };
            const d = self.data(node);
            if (d.options.executes != null) {
                try self.writePrefix(writer, &prefix);
                try writer.writeByte('\n');
            }
            if (d.options.redirect) |redirect| {
                try self.writePrefix(writer, &prefix);
                try writer.writeByte(' ');
                try self.writeRedirect(writer, redirect.target);
                try writer.writeByte('\n');
                return;
            }
            var each = self.children(node);
            while (each.next()) |next| try self.allUsageOf(writer, next, source, &prefix);
        }

        fn writePrefix(self: *const Self, writer: *Writer, prefix: *const Prefix) Writer.Error!void {
            if (prefix.parent) |parent| {
                try self.writePrefix(writer, parent);
                try writer.writeByte(' ');
            }
            try self.writeUsageText(writer, prefix.node);
        }

        fn smartUsage(self: *const Self, writer: *Writer, node: Node, source: *const Source, optional: bool, deep: bool) Writer.Error!void {
            if (optional) try writer.writeByte('[');
            try self.writeUsageText(writer, node);
            if (optional) try writer.writeByte(']');
            if (deep) return;
            const d = self.data(node);
            if (d.options.redirect) |redirect| {
                try writer.writeByte(' ');
                return self.writeRedirect(writer, redirect.target);
            }
            const child_optional = d.options.executes != null;
            var usable: usize = 0;
            var only: Node = undefined;
            var each = self.children(node);
            while (each.next()) |next| if (self.canUse(next, source)) {
                usable += 1;
                only = next;
            };
            if (usable == 0) return;
            try writer.writeByte(' ');
            if (usable == 1) return self.smartUsage(writer, only, source, child_optional, child_optional);
            try writer.writeByte(if (child_optional) '[' else '(');
            var first = true;
            each = self.children(node);
            while (each.next()) |next| if (self.canUse(next, source)) {
                if (!first) try writer.writeByte('|');
                first = false;
                try self.writeUsageText(writer, next);
            };
            try writer.writeByte(if (child_optional) ']' else ')');
        }

        fn writeRedirect(self: *const Self, writer: *Writer, target: Node) Writer.Error!void {
            if (target == .root) return writer.writeAll("...");
            try writer.writeAll("-> ");
            try self.writeUsageText(writer, target);
        }

        /// Writes how `node` is written in usage: its name for a literal,
        /// `<name>` for an argument.
        pub fn writeUsageText(self: *const Self, writer: *Writer, node: Node) Writer.Error!void {
            if (self.nodes.items.len == 0) return;
            const d = self.data(node);
            if (d.argument == null) return writer.writeAll(d.name);
            try writer.print("<{s}>", .{d.name});
        }

        pub fn info(self: *const Self, node: Node) Info {
            if (self.nodes.items.len == 0) return .{ .name = "", .parent = .root, .argument = null, .executes = false, .redirect = null };
            const d = self.data(node);
            return .{
                .name = d.name,
                .parent = d.parent,
                .argument = if (d.argument) |arg| arg.vtable.type_name else null,
                .executes = d.options.executes != null,
                .redirect = if (d.options.redirect) |redirect| redirect.target else null,
            };
        }

        /// The child of `parent` named `name`: a literal if there is one.
        pub fn child(self: *const Self, parent: Node, name: []const u8) ?Node {
            if (self.nodes.items.len == 0) return null;
            const d = self.data(parent);
            if (findLiteral(d.literals.items, name)) |found| return found;
            for (d.arguments.items) |found| if (std.mem.eql(u8, self.data(found).name, name)) return found;
            return null;
        }

        /// The node at the end of `path` from the root, by name.
        pub fn find(self: *const Self, path: []const []const u8) ?Node {
            var node: Node = .root;
            for (path) |name| node = self.child(node, name) orelse return null;
            return node;
        }

        /// The children of `node`: its literals by name, then its arguments
        /// in the order added.
        pub fn children(self: *const Self, node: Node) Children {
            if (self.nodes.items.len == 0) return .{ .literals = &.{}, .arguments = &.{} };
            const d = self.data(node);
            return .{ .literals = d.literals.items, .arguments = d.arguments.items };
        }

        pub const Children = struct {
            literals: []const Literal,
            arguments: []const Node,
            index: usize = 0,

            pub fn next(self: *Children) ?Node {
                defer self.index += 1;
                if (self.index < self.literals.len) return self.literals[self.index].node;
                const index = self.index - self.literals.len;
                return if (index < self.arguments.len) self.arguments[index] else null;
            }
        };

        /// A depth-first walk of the graph over the input, which keeps the
        /// nodes it parsed so far as a stack in the buffer and backtracks by
        /// popping it.
        const Parser = struct {
            dispatcher: *const Self,
            source: *const Source,
            input: []const u8,
            space: Space,
            /// The furthest place a parse failed.
            failure: Failure = .{},
            /// Whether a parse read the whole input but ended where no
            /// command is.
            incomplete: bool = false,

            const Failure = struct {
                found: bool = false,
                cursor: usize = 0,
                /// Null when nothing matched.
                err: ?anyerror = null,
                argument: ?Argument = null,
                /// Whether anything was parsed before it.
                parsed: bool = false,
            };

            /// Parses the input from `cursor` as a child of `node`; true once
            /// a parse reads it all and ends at a command, its nodes left on
            /// the stack.
            fn walk(self: *Parser, node: Node, cursor: usize) error{NoSpaceLeft}!bool {
                const d = self.dispatcher.data(node);
                if (d.literals.items.len > 0) {
                    const end = std.mem.indexOfScalarPos(u8, self.input, cursor, ' ') orelse self.input.len;
                    if (findLiteral(d.literals.items, self.input[cursor..end])) |found| {
                        if (self.dispatcher.canUse(found, self.source)) return self.advance(found, cursor, end, null, self.space.mark());
                        self.fail(cursor, null, null);
                        return false;
                    }
                }
                var tried = false;
                for (d.arguments.items) |child_node| {
                    if (!self.dispatcher.canUse(child_node, self.source)) continue;
                    tried = true;
                    if (try self.attempt(child_node, cursor)) return true;
                }
                if (!tried) self.fail(cursor, null, null);
                return false;
            }

            fn attempt(self: *Parser, node: Node, cursor: usize) error{NoSpaceLeft}!bool {
                const arg = self.dispatcher.data(node).argument.?;
                const mark = self.space.mark();
                var reader: Reader = .{ .input = self.input, .cursor = cursor, .space = &self.space };
                const value = try self.space.allocBytes(arg.vtable.size, arg.vtable.alignment);
                arg.vtable.parse(arg.state, &reader, self.source, value) catch |err| {
                    if (err == error.NoSpaceLeft) return error.NoSpaceLeft;
                    self.space.restore(mark);
                    self.fail(reader.cursor, err, arg);
                    return false;
                };
                return self.advance(node, cursor, reader.cursor, value, mark);
            }

            fn advance(self: *Parser, node: Node, start: usize, end: usize, value: ?*const anyopaque, mark: Space.Mark) error{NoSpaceLeft}!bool {
                if (end < self.input.len and self.input[end] != ' ') {
                    self.space.restore(mark);
                    self.fail(end, error.ExpectedSeparator, null);
                    return false;
                }
                try self.space.push(Parsed, .{ .node = node, .start = @intCast(start), .end = @intCast(end), .value = value });
                if (try self.follow(node, end)) return true;
                self.space.restore(mark);
                return false;
            }

            fn follow(self: *Parser, node: Node, end: usize) error{NoSpaceLeft}!bool {
                const d = self.dispatcher.data(node);
                if (end == self.input.len) {
                    if (d.options.executes != null) return true;
                    self.incomplete = true;
                    return false;
                }
                const next = end + 1;
                if (d.options.redirect) |redirect| {
                    if (next < self.input.len) return self.walk(redirect.target, next);
                    self.incomplete = true;
                    return false;
                }
                if (next < self.input.len) return self.walk(node, next);
                self.fail(end, null, null);
                return false;
            }

            fn fail(self: *Parser, cursor: usize, err: ?anyerror, arg: ?Argument) void {
                const failure = &self.failure;
                if (failure.found and cursor < failure.cursor) return;
                if (failure.found and cursor == failure.cursor) {
                    const same = if (failure.err) |a| (if (err) |b| a == b else false) else err == null;
                    if (!same) {
                        failure.err = null;
                        failure.argument = null;
                    }
                    return;
                }
                failure.* = .{ .found = true, .cursor = cursor, .err = err, .argument = arg, .parsed = self.space.low > self.space.start };
            }

            /// Walks the input from `cursor` as a child of `node` as `walk`
            /// does, but along every way the input can be read, and
            /// suggests children wherever a way reaches the end. The current
            /// context's nodes start at `context` on the stack.
            fn complete(self: *Parser, node: Node, cursor: usize, context: usize, builder: *SuggestionBuilder) anyerror!void {
                if (cursor == self.input.len) return self.offer(node, cursor, context, builder);
                const d = self.dispatcher.data(node);
                const end = std.mem.indexOfScalarPos(u8, self.input, cursor, ' ') orelse self.input.len;
                var here = end == self.input.len;
                if (findLiteral(d.literals.items, self.input[cursor..end])) |child_node| {
                    if (!here and self.dispatcher.canUse(child_node, self.source)) {
                        try self.descend(child_node, cursor, end, null, self.space.mark(), context, builder);
                    }
                } else for (d.arguments.items) |child_node| {
                    if (!self.dispatcher.canUse(child_node, self.source)) continue;
                    const arg = self.dispatcher.data(child_node).argument.?;
                    const mark = self.space.mark();
                    var reader: Reader = .{ .input = self.input, .cursor = cursor, .space = &self.space };
                    const value = try self.space.allocBytes(arg.vtable.size, arg.vtable.alignment);
                    arg.vtable.parse(arg.state, &reader, self.source, value) catch |err| {
                        if (err == error.NoSpaceLeft) return error.NoSpaceLeft;
                        self.space.restore(mark);
                        here = true;
                        continue;
                    };
                    if (reader.cursor < self.input.len and self.input[reader.cursor] == ' ') {
                        try self.descend(child_node, cursor, reader.cursor, value, mark, context, builder);
                    } else {
                        self.space.restore(mark);
                        here = true;
                    }
                }
                if (here) try self.offer(node, cursor, context, builder);
            }

            fn descend(self: *Parser, node: Node, start: usize, end: usize, value: ?*const anyopaque, mark: Space.Mark, context: usize, builder: *SuggestionBuilder) anyerror!void {
                defer self.space.restore(mark);
                try self.space.push(Parsed, .{ .node = node, .start = @intCast(start), .end = @intCast(end), .value = value });
                if (self.dispatcher.data(node).options.redirect) |redirect| {
                    return self.complete(redirect.target, end + 1, self.space.stack(Parsed).len, builder);
                }
                return self.complete(node, end + 1, context, builder);
            }

            /// Suggests the children of `node` that complete the input from
            /// `cursor`.
            fn offer(self: *Parser, node: Node, cursor: usize, context: usize, builder: *SuggestionBuilder) anyerror!void {
                const d = self.dispatcher.data(node);
                builder.start = cursor;
                for (d.literals.items) |lit| {
                    if (self.dispatcher.canUse(lit.node, self.source)) try builder.add(lit.name);
                }
                for (d.arguments.items) |child_node| {
                    if (!self.dispatcher.canUse(child_node, self.source)) continue;
                    const child_data = self.dispatcher.data(child_node);
                    if (child_data.options.suggests) |suggests| {
                        const ctx: Context = .{ .dispatcher = self.dispatcher, .source = self.source.*, .input = self.input, .nodes = self.space.stack(Parsed)[context..] };
                        try suggests(&ctx, builder);
                    } else if (child_data.argument.?.vtable.suggest) |call| {
                        try call(child_data.argument.?.state, builder);
                    }
                }
            }
        };
    };
}
