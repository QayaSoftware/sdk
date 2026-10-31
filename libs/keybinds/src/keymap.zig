const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const input = @import("input.zig");
const Input = input.Input;
const Mods = input.Mods;
const trigger_zig = @import("trigger.zig");
const Chord = trigger_zig.Chord;
const Trigger = trigger_zig.Trigger;
const Gesture = trigger_zig.Gesture;

/// A binding, by its place in its keymap.
pub const BindingId = enum(u32) { _ };

/// Bindings from triggers to the actions of `Action`, an enum, that hold in
/// the contexts of `Context`, an enum or void for none. A keymap is only the
/// definitions: a `Tracker` follows one player's or device's inputs through
/// it, so any number of trackers can share a keymap, from any threads, while
/// nothing changes it.
pub fn Keymap(comptime Action: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        settings: Settings,
        bindings: std.ArrayList(Binding) = .empty,
        /// Bumped by every change, so trackers notice and start over.
        generation: u64 = 0,
        /// Digital bindings by the inputs of their first chord, for a press
        /// to find what it can fire.
        by_input: std.AutoHashMapUnmanaged(u32, Span) = .empty,
        input_ids: std.ArrayList(u32) = .empty,
        /// Bindings by action, for values and descriptions.
        action_spans: [action_count]Span = @splat(.{}),
        action_ids: std.ArrayList(u32) = .empty,

        pub const ContextEnum = if (Context == void) enum {} else Context;
        pub const Contexts = std.EnumSet(ContextEnum);
        const actions = std.enums.EnumIndexer(Action);
        const action_count = actions.count;

        const Span = struct { start: u32 = 0, len: u32 = 0 };

        pub const Settings = struct {
            /// Whether a chord's modifiers must be exactly those held rather
            /// than among them, for bindings that do not say. Editors want
            /// this; games, where shift held to sprint must not stop space
            /// from jumping, do not.
            exact_modifiers: bool = false,
            /// How long the next chord of a sequence can take.
            sequence_timeout: u64 = std.time.ns_per_s,
            /// How far an axis must go for its half to press, as a button.
            axis_press: f32 = 0.5,
            /// How far back it must come for its half to release: below the
            /// press threshold, so it does not flicker at the edge.
            axis_release: f32 = 0.35,
            /// How far an axis must go to count at all; past it, its value is
            /// rescaled to start from zero.
            deadzone: f32 = 0.15,
        };

        pub const Binding = struct {
            action: Action,
            trigger: Trigger,
            gesture: Gesture,
            scale: f32,
            when: Contexts,
            unless: Contexts,
            exact: bool,
            priority: i8,
            consume: bool,
            kind: Kind,
            removed: bool = false,

            pub const Kind = enum {
                /// Pressed and released.
                digital,
                /// Gives an axis's value while the rest of its chord is held.
                analog,
                /// Gives motion amounts while the rest of its chord is held.
                motion,
            };
        };

        pub const Options = struct {
            gesture: Gesture = .press,
            /// What it adds to its action's value: while held, for a digital
            /// trigger; times the axis's value or the motion's amount
            /// otherwise. Negative for the other way, as `a` is to `d`.
            scale: f32 = 1,
            /// Contexts that must all be active for it to fire.
            when: []const ContextEnum = &.{},
            /// Contexts in which it does not fire.
            unless: []const ContextEnum = &.{},
            /// Whether its modifiers must be exactly those held; the keymap's
            /// setting unless set.
            exact: ?bool = null,
            /// Bindings of higher priority fire first, before the more
            /// specific.
            priority: i8 = 0,
            /// Whether firing stops the bindings after it in priority and
            /// specificity that the same press would fire.
            consume: bool = true,
        };

        pub const BindError = Allocator.Error || Trigger.ParseError || error{
            /// A gesture other than press on an axis or motion trigger, or a
            /// repeat with no interval.
            InvalidGesture,
        };

        /// What a tracker reports: a binding firing.
        pub const Event = struct {
            action: Action,
            gesture: Gesture.Tag,
            /// When it fired: the time of the input that set it off, or the
            /// exact deadline of a hold or repeat.
            time: u64,
            binding: BindingId,
            /// The tracker it happened in.
            caller: u32,
            /// For a repeat, which one, from 1.
            repeat: u32 = 0,
        };

        pub fn init(gpa: Allocator, settings: Settings) Self {
            return .{ .gpa = gpa, .settings = settings };
        }

        pub fn deinit(self: *Self) void {
            self.bindings.deinit(self.gpa);
            self.by_input.deinit(self.gpa);
            self.input_ids.deinit(self.gpa);
            self.action_ids.deinit(self.gpa);
            self.* = undefined;
        }

        /// Binds `action` to the trigger `text`, as `ctrl+s`, `space`,
        /// `pad:south`, `ctrl+k ctrl+c` or `pad:left_x`.
        pub fn bind(self: *Self, action: Action, text: []const u8, options: Options) BindError!BindingId {
            return self.bindTrigger(action, try Trigger.parse(text), options);
        }

        pub fn bindTrigger(self: *Self, action: Action, trigger: Trigger, options: Options) BindError!BindingId {
            const made = try self.make(action, trigger, options);
            const id = try self.add(made);
            try self.rebuild();
            return id;
        }

        fn make(self: *const Self, action: Action, trigger: Trigger, options: Options) BindError!Binding {
            const analog = trigger.first().analog();
            const kind: Binding.Kind = if (analog) |which| (if (which.kind == .motion) .motion else .analog) else .digital;
            if (kind != .digital and options.gesture != .press) return error.InvalidGesture;
            if (options.gesture == .repeat and options.gesture.repeat.interval == 0) return error.InvalidGesture;
            return .{
                .action = action,
                .trigger = trigger,
                .gesture = options.gesture,
                .scale = options.scale,
                .when = .initMany(options.when),
                .unless = .initMany(options.unless),
                .exact = options.exact orelse self.settings.exact_modifiers,
                .priority = options.priority,
                .consume = options.consume,
                .kind = kind,
            };
        }

        /// Puts `binding` in a removed binding's place, or at the end.
        fn add(self: *Self, made: Binding) Allocator.Error!BindingId {
            for (self.bindings.items, 0..) |*slot, index| if (slot.removed) {
                slot.* = made;
                return @fromBackingInt(@intCast(index));
            };
            try self.bindings.append(self.gpa, made);
            return @fromBackingInt(@intCast(self.bindings.items.len - 1));
        }

        pub fn unbind(self: *Self, id: BindingId) Allocator.Error!void {
            self.bindings.items[@backingInt(id)].removed = true;
            try self.rebuild();
        }

        /// Removes every binding of `action`.
        pub fn unbindAction(self: *Self, action: Action) Allocator.Error!void {
            for (self.bindings.items) |*b| if (b.action == action) {
                b.removed = true;
            };
            try self.rebuild();
        }

        pub fn clear(self: *Self) Allocator.Error!void {
            self.bindings.clearRetainingCapacity();
            try self.rebuild();
        }

        pub fn binding(self: *const Self, id: BindingId) *const Binding {
            return &self.bindings.items[@backingInt(id)];
        }

        /// The bindings of `action`, in the order made.
        pub fn bindingsOf(self: *const Self, action: Action) []const BindingId {
            const span = self.action_spans[actions.indexOf(action)];
            return @ptrCast(self.action_ids.items[span.start..][0..span.len]);
        }

        fn digitalFor(self: *const Self, which: Input) []const u32 {
            const span = self.by_input.get(which.id()) orelse return &.{};
            return self.input_ids.items[span.start..][0..span.len];
        }

        /// Rebuilds the indexes, and tells trackers to start over.
        fn rebuild(self: *Self) Allocator.Error!void {
            const gpa = self.gpa;
            const Pair = struct { key: u32, id: u32 };
            var pairs: std.ArrayList(Pair) = .empty;
            defer pairs.deinit(gpa);
            for (self.bindings.items, 0..) |*b, index| {
                if (b.removed or b.kind != .digital) continue;
                for (b.trigger.first().inputs()) |which| try pairs.append(gpa, .{ .key = which.id(), .id = @intCast(index) });
            }
            std.mem.sort(Pair, pairs.items, {}, struct {
                fn lessThan(_: void, a: Pair, b: Pair) bool {
                    return if (a.key != b.key) a.key < b.key else a.id < b.id;
                }
            }.lessThan);

            var by_input: std.AutoHashMapUnmanaged(u32, Span) = .empty;
            errdefer by_input.deinit(gpa);
            var input_ids: std.ArrayList(u32) = .empty;
            errdefer input_ids.deinit(gpa);
            try input_ids.ensureTotalCapacity(gpa, pairs.items.len);
            for (pairs.items, 0..) |pair, index| {
                input_ids.appendAssumeCapacity(pair.id);
                const entry = try by_input.getOrPut(gpa, pair.key);
                if (!entry.found_existing) entry.value_ptr.* = .{ .start = @intCast(index) };
                entry.value_ptr.len += 1;
            }

            var action_ids: std.ArrayList(u32) = .empty;
            errdefer action_ids.deinit(gpa);
            var action_spans: [action_count]Span = @splat(.{});
            for (&action_spans, 0..) |*span, action_index| {
                span.start = @intCast(action_ids.items.len);
                for (self.bindings.items, 0..) |*b, index| {
                    if (!b.removed and actions.indexOf(b.action) == action_index) try action_ids.append(gpa, @intCast(index));
                }
                span.len = @intCast(action_ids.items.len - span.start);
            }

            self.by_input.deinit(gpa);
            self.input_ids.deinit(gpa);
            self.action_ids.deinit(gpa);
            self.by_input = by_input;
            self.input_ids = input_ids;
            self.action_ids = action_ids;
            self.action_spans = action_spans;
            self.generation += 1;
        }

        pub const LoadError = Allocator.Error || Trigger.ParseError || error{
            /// A line without `=` between its action and trigger.
            ExpectedEquals,
            UnknownAction,
            UnknownContext,
            /// An option that is not one, or one with a bad value.
            InvalidOption,
            InvalidGesture,
        };

        /// What `load` does with the bindings already there.
        pub const LoadMode = enum {
            /// Replaces the bindings of the actions the text binds, and
            /// keeps the rest: defaults, overridden by a player's choices.
            replace_actions,
            /// Replaces every binding.
            replace_all,
            /// Adds to them.
            add,
        };

        /// Where text that does not load is wrong.
        pub const Diagnostics = struct {
            line: usize = 0,
            column: usize = 0,
            err: ?LoadError = null,

            pub fn format(self: Diagnostics, writer: *Writer) Writer.Error!void {
                try writer.print("line {d}, column {d}: {s}", .{ self.line, self.column, if (self.err) |err| @errorName(err) else "no error" });
            }
        };

        /// Loads bindings written one to a line as `action = trigger`,
        /// followed by options separated by commas:
        ///
        ///     # comments start with #
        ///     jump = space
        ///     jump = pad:south
        ///     save = ctrl+s, when editor
        ///     comment = ctrl+k ctrl+c
        ///     quick_save = f5, hold 500ms
        ///     zoom_in = ctrl+wheel:up, repeat 300ms 50ms, priority 1
        ///     move_x = a, scale -1
        ///     look_x = mouse:right+motion:x, scale 0.2, unless menu text
        ///
        /// The gestures are `press`, `release`, `hold <time>`, `tap <time>`,
        /// `double <time>` and `repeat <delay> <interval>`; the other options
        /// `scale <n>`, `when <contexts>`, `unless <contexts>`, `exact`,
        /// `loose`, `priority <n>` and `pass` (not consuming). Nothing
        /// changes unless all of it loads.
        pub fn load(self: *Self, text: []const u8, mode: LoadMode, diagnostics: ?*Diagnostics) LoadError!void {
            var loaded: std.ArrayList(Binding) = .empty;
            defer loaded.deinit(self.gpa);
            var lines = std.mem.splitScalar(u8, text, '\n');
            var number: usize = 0;
            while (lines.next()) |raw| {
                number += 1;
                const line = std.mem.trimEnd(u8, raw, "\r");
                const content = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t");
                if (content.len == 0) continue;
                var column: usize = 0;
                const made = self.parseLine(line, content, &column) catch |err| {
                    if (diagnostics) |diag| diag.* = .{ .line = number, .column = column, .err = err };
                    return err;
                };
                try loaded.append(self.gpa, made);
            }
            try self.bindings.ensureUnusedCapacity(self.gpa, loaded.items.len);
            switch (mode) {
                .replace_all => self.bindings.clearRetainingCapacity(),
                .replace_actions => for (loaded.items) |made| {
                    for (self.bindings.items) |*b| if (b.action == made.action) {
                        b.removed = true;
                    };
                },
                .add => {},
            }
            for (loaded.items) |made| _ = self.add(made) catch unreachable;
            try self.rebuild();
        }

        /// Reads a line's binding, keeping `at` at the column, from 1, of
        /// what it is reading, so an error says where.
        fn parseLine(self: *const Self, line: []const u8, content: []const u8, at: *usize) LoadError!Binding {
            const column = struct {
                fn of(whole: []const u8, part: []const u8) usize {
                    return @intFromPtr(part.ptr) - @intFromPtr(whole.ptr) + 1;
                }
            }.of;
            at.* = column(line, content);
            const equals = std.mem.indexOfScalar(u8, content, '=') orelse return error.ExpectedEquals;
            const name = std.mem.trim(u8, content[0..equals], " \t");
            at.* = column(line, name);
            const action = enumNamed(Action, name) orelse return error.UnknownAction;
            var parts = std.mem.splitScalar(u8, content[equals + 1 ..], ',');
            const trigger_text = std.mem.trim(u8, parts.first(), " \t");
            at.* = column(line, trigger_text);
            var made = try self.make(action, try Trigger.parse(trigger_text), .{});
            while (parts.next()) |raw_option| {
                const option = std.mem.trim(u8, raw_option, " \t");
                at.* = column(line, option);
                var words = std.mem.tokenizeAny(u8, option, " \t");
                const word = words.next() orelse return error.InvalidOption;
                if (std.mem.eql(u8, word, "press")) {
                    made.gesture = .press;
                } else if (std.mem.eql(u8, word, "release")) {
                    made.gesture = .release;
                } else if (std.mem.eql(u8, word, "hold")) {
                    made.gesture = .{ .hold = try duration(&words) };
                } else if (std.mem.eql(u8, word, "tap")) {
                    made.gesture = .{ .tap = try duration(&words) };
                } else if (std.mem.eql(u8, word, "double")) {
                    made.gesture = .{ .double_tap = try duration(&words) };
                } else if (std.mem.eql(u8, word, "repeat")) {
                    made.gesture = .{ .repeat = .{ .delay = try duration(&words), .interval = try duration(&words) } };
                } else if (std.mem.eql(u8, word, "scale")) {
                    made.scale = std.fmt.parseFloat(f32, words.next() orelse return error.InvalidOption) catch return error.InvalidOption;
                } else if (std.mem.eql(u8, word, "priority")) {
                    made.priority = std.fmt.parseInt(i8, words.next() orelse return error.InvalidOption, 10) catch return error.InvalidOption;
                } else if (std.mem.eql(u8, word, "when") or std.mem.eql(u8, word, "unless")) {
                    var set: Contexts = .empty;
                    while (words.next()) |context_name| {
                        at.* = column(line, context_name);
                        set.insert(enumNamed(ContextEnum, context_name) orelse return error.UnknownContext);
                    }
                    if (word[0] == 'w') made.when = set else made.unless = set;
                    continue;
                } else if (std.mem.eql(u8, word, "exact")) {
                    made.exact = true;
                } else if (std.mem.eql(u8, word, "loose")) {
                    made.exact = false;
                } else if (std.mem.eql(u8, word, "pass")) {
                    made.consume = false;
                } else return error.InvalidOption;
                if (words.next() != null) return error.InvalidOption;
            }
            at.* = column(line, trigger_text);
            if (made.kind != .digital and made.gesture != .press) return error.InvalidGesture;
            if (made.gesture == .repeat and made.gesture.repeat.interval == 0) return error.InvalidGesture;
            return made;
        }

        fn duration(words: *std.mem.TokenIterator(u8, .any)) LoadError!u64 {
            return trigger_zig.parseDuration(words.next() orelse return error.InvalidOption) orelse error.InvalidOption;
        }

        fn enumNamed(comptime E: type, name: []const u8) ?E {
            if (std.meta.stringToEnum(E, name)) |value| return value;
            var buffer: [64]u8 = undefined;
            if (name.len > buffer.len) return null;
            for (name, buffer[0..name.len]) |c, *out| out.* = if (c == '-') '_' else c;
            return std.meta.stringToEnum(E, buffer[0..name.len]);
        }

        /// Writes every binding as `load` reads it, by action.
        pub fn write(self: *const Self, writer: *Writer) Writer.Error!void {
            inline for (@typeInfo(Action).@"enum".field_names) |field_name| {
                for (self.bindingsOf(@field(Action, field_name))) |id| {
                    const b = self.binding(id);
                    try writer.print("{s} = ", .{field_name});
                    try b.trigger.writeText(writer);
                    switch (b.gesture) {
                        .press => {},
                        .release => try writer.writeAll(", release"),
                        .hold => |time| try writeOption(writer, "hold", &.{time}),
                        .tap => |time| try writeOption(writer, "tap", &.{time}),
                        .double_tap => |time| try writeOption(writer, "double", &.{time}),
                        .repeat => |repeat| try writeOption(writer, "repeat", &.{ repeat.delay, repeat.interval }),
                    }
                    if (b.scale != 1) try writer.print(", scale {d}", .{b.scale});
                    try writeContexts(writer, "when", b.when);
                    try writeContexts(writer, "unless", b.unless);
                    if (b.exact != self.settings.exact_modifiers) try writer.writeAll(if (b.exact) ", exact" else ", loose");
                    if (b.priority != 0) try writer.print(", priority {d}", .{b.priority});
                    if (!b.consume) try writer.writeAll(", pass");
                    try writer.writeByte('\n');
                }
            }
        }

        fn writeOption(writer: *Writer, name: []const u8, times: []const u64) Writer.Error!void {
            try writer.print(", {s}", .{name});
            for (times) |time| {
                try writer.writeByte(' ');
                try trigger_zig.writeDuration(writer, time);
            }
        }

        fn writeContexts(writer: *Writer, name: []const u8, set: Contexts) Writer.Error!void {
            if (set.count() == 0) return;
            try writer.print(", {s}", .{name});
            var each = set.iterator();
            while (each.next()) |context| try writer.print(" {t}", .{context});
        }

        /// Writes how to set `action` off, as it is shown to a player:
        /// each trigger, joined by ` / `, as `Ctrl+S / Pad South`.
        pub fn describe(self: *const Self, writer: *Writer, action: Action) Writer.Error!void {
            for (self.bindingsOf(action), 0..) |id, i| {
                if (i > 0) try writer.writeAll(" / ");
                try writer.print("{f}", .{self.binding(id).trigger});
            }
        }

        /// Two bindings that one press fires both of, to different ends.
        pub const Conflict = struct {
            first: BindingId,
            second: BindingId,
            /// Whether `second`'s trigger only begins with `first`'s, so
            /// pressing it fires `first` on the way.
            prefix: bool,
        };

        /// The bindings of different actions that the same press fires
        /// together, for a settings menu to warn about.
        pub fn conflicts(self: *const Self, gpa: Allocator) Allocator.Error![]Conflict {
            var found: std.ArrayList(Conflict) = .empty;
            errdefer found.deinit(gpa);
            const all = self.bindings.items;
            for (all, 0..) |*a, i| {
                if (a.removed or a.kind != .digital) continue;
                for (all[i + 1 ..], i + 1..) |*b, j| {
                    if (b.removed or b.kind != .digital or a.action == b.action) continue;
                    if (a.priority != b.priority or !a.consume or !b.consume) continue;
                    if (a.when.intersectWith(b.unless).count() != 0 or b.when.intersectWith(a.unless).count() != 0) continue;
                    if (!a.trigger.first().eql(b.trigger.first())) continue;
                    const prefix = a.trigger.len != b.trigger.len;
                    if (!prefix and !a.trigger.eql(&b.trigger)) continue;
                    const shorter, const longer = if (a.trigger.len <= b.trigger.len) .{ i, j } else .{ j, i };
                    try found.append(gpa, .{ .first = @fromBackingInt(@intCast(shorter)), .second = @fromBackingInt(@intCast(longer)), .prefix = prefix });
                }
            }
            return found.toOwnedSlice(gpa);
        }

        /// Follows one caller's inputs through a keymap: held inputs, the
        /// actions they hold down, timers and the events they fire. Feed it
        /// every input in the order it happened, with its time in
        /// nanoseconds from any fixed point, then `update` before reading
        /// it, and `endFrame` once read.
        pub const Tracker = struct {
            keymap: *const Self,
            gpa: Allocator,
            /// Who this tracker is for, as a player number, given to events.
            caller: u32,
            contexts: Contexts = .empty,
            generation: u64,
            /// The latest time fed; times before it count as it.
            now: u64 = 0,
            held: std.ArrayList(Held) = .empty,
            mods: Mods = .{},
            runs: std.ArrayList(Run) = .empty,
            /// Bindings started and not yet let go: armed or active.
            live: std.ArrayList(u32) = .empty,
            /// Bindings waiting on a hold or repeat deadline.
            timed: std.ArrayList(u32) = .empty,
            /// Sequences part way through, and when they give up.
            pending: std.ArrayList(Pending) = .empty,
            pending_deadline: u64 = 0,
            states: [action_count]ActionState = @splat(.{}),
            axes: std.ArrayList(Value) = .empty,
            deltas: std.ArrayList(Value) = .empty,
            events: std.ArrayList(Event) = .empty,
            /// How many of `events` handlers have seen.
            dispatched: usize = 0,
            capture: ?Capture = null,
            candidates: std.ArrayList(Candidate) = .empty,

            const Held = struct { input: Input, count: u8 };
            const Value = struct { input: Input, value: f32 };
            const Pending = struct { id: u32, step: u8 };
            const Candidate = struct { id: u32, priority: i8, specificity: u8 };

            const Run = struct {
                phase: Phase = .idle,
                /// The input that completed the chord.
                input: Input = undefined,
                start: u64 = 0,
                deadline: u64 = 0,
                /// When a double tap's first press was.
                first_tap: ?u64 = null,
                repeats: u32 = 0,

                const Phase = enum {
                    idle,
                    /// Completed, waiting for a deadline or a release to fire.
                    armed,
                    /// Fired, and holding its action down.
                    active,
                };
            };

            const ActionState = struct {
                /// How many bindings hold it down.
                down: u16 = 0,
                /// When it last went down.
                since: u64 = 0,
                presses: u32 = 0,
                releases: u32 = 0,
            };

            const Capture = struct {
                /// A modifier pressed alone, which is the chord if it is
                /// released before anything else is pressed.
                modifier: ?Input = null,
                result: ?Chord = null,
            };

            pub fn init(gpa: Allocator, keymap: *const Self, caller: u32) Tracker {
                return .{ .keymap = keymap, .gpa = gpa, .caller = caller, .generation = keymap.generation -% 1 };
            }

            pub fn deinit(self: *Tracker) void {
                const gpa = self.gpa;
                self.held.deinit(gpa);
                self.runs.deinit(gpa);
                self.live.deinit(gpa);
                self.timed.deinit(gpa);
                self.pending.deinit(gpa);
                self.axes.deinit(gpa);
                self.deltas.deinit(gpa);
                self.events.deinit(gpa);
                self.candidates.deinit(gpa);
                self.* = undefined;
            }

            /// Whether `action` is held down.
            pub fn down(self: *const Tracker, action: Action) bool {
                return self.states[actions.indexOf(action)].down > 0;
            }

            /// Whether `action` fired since the last `endFrame`.
            pub fn pressed(self: *const Tracker, action: Action) bool {
                return self.presses(action) > 0;
            }

            /// How many times `action` fired since the last `endFrame`: taps
            /// faster than frames are all counted.
            pub fn presses(self: *const Tracker, action: Action) u32 {
                return self.states[actions.indexOf(action)].presses;
            }

            /// Whether `action` stopped being down since the last `endFrame`.
            pub fn released(self: *const Tracker, action: Action) bool {
                return self.states[actions.indexOf(action)].releases > 0;
            }

            /// How long `action` has been down, if it is.
            pub fn heldFor(self: *const Tracker, action: Action) ?u64 {
                const state = self.states[actions.indexOf(action)];
                if (state.down == 0) return null;
                return self.now -| state.since;
            }

            /// `action`'s value: what its held digital bindings and its axes
            /// add up to, kept within -1 and 1, plus the motion its motion
            /// bindings gave since the last `endFrame`.
            pub fn value(self: *const Tracker, action: Action) f32 {
                const keymap = self.keymap;
                if (self.generation != keymap.generation) return 0;
                var level: f32 = 0;
                var moved: f32 = 0;
                for (keymap.bindingsOf(action)) |id| {
                    const index = @backingInt(id);
                    const b = &keymap.bindings.items[index];
                    switch (b.kind) {
                        .digital => if (self.runs.items[index].phase == .active and b.gesture.holds()) {
                            level += b.scale;
                        },
                        .analog => if (self.allowed(b) and self.holding(b.trigger.first(), b.exact)) {
                            level += self.deadzoned(self.valueOf(&self.axes, b.trigger.first().analog().?)) * b.scale;
                        },
                        .motion => if (self.allowed(b) and self.holding(b.trigger.first(), b.exact)) {
                            moved += self.valueOf(&self.deltas, b.trigger.first().analog().?) * b.scale;
                        },
                    }
                }
                return std.math.clamp(level, -1, 1) + moved;
            }

            /// The events since the last `endFrame`, in the order they
            /// happened.
            pub fn eventsSinceFrame(self: *const Tracker) []const Event {
                return self.events.items;
            }

            /// Whether `input` is held.
            pub fn isHeld(self: *const Tracker, which: Input) bool {
                return self.find(which) != null;
            }

            /// Makes `context` active or not. Bindings it stops are let go
            /// without firing.
            pub fn setContext(self: *Tracker, context: ContextEnum, active: bool) void {
                self.contexts.setPresent(context, active);
                self.recheck();
            }

            pub fn setContexts(self: *Tracker, contexts: Contexts) void {
                self.contexts = contexts;
                self.recheck();
            }

            /// Feeds the press of a digital input.
            pub fn press(self: *Tracker, which: Input, time: u64) Allocator.Error!void {
                std.debug.assert(which.isDigital());
                try self.prepare(time);
                const held = try self.hold(which) orelse return;
                if (self.capture) |*capture| {
                    if (capture.result != null) return;
                    if (which.modifier() != null) {
                        capture.modifier = which;
                    } else {
                        capture.modifier = null;
                        capture.result = .of(self.mods, &.{which});
                    }
                    return;
                }
                try self.handlePress(which);
                if (held) |either| try self.handlePress(either);
            }

            /// Fires what a press of `which` does: moving sequences on, or
            /// else completing chords.
            fn handlePress(self: *Tracker, which: Input) Allocator.Error!void {
                if (self.pending.items.len > 0 and try self.continueSequences(which)) return;
                try self.match(which);
            }

            /// Feeds the release of a digital input.
            pub fn release(self: *Tracker, which: Input, time: u64) Allocator.Error!void {
                std.debug.assert(which.isDigital());
                try self.prepare(time);
                const released_either = self.unhold(which) orelse return;
                if (self.capture) |*capture| if (capture.result == null) {
                    if (capture.modifier) |modifier| if (modifier.id() == which.id()) {
                        const key = if (which.asKey().?.either()) |either| Input.key(either) else which;
                        capture.result = .of(self.mods.with(which.modifier().?, false), &.{key});
                    };
                    return;
                };
                try self.letGo(which, false);
                if (released_either) |either| try self.letGo(either, false);
            }

            /// Feeds an analog axis's value: sticks from -1 to 1, triggers
            /// from 0 to 1. Its halves press and release as buttons.
            pub fn axis(self: *Tracker, which: input.Axis, amount: f32, time: u64) Allocator.Error!void {
                try self.prepare(time);
                try setValue(self.gpa, &self.axes, .axis(which), amount);
                const settings = self.keymap.settings;
                inline for (.{ .{ Input.axisPositive(which), amount }, .{ Input.axisNegative(which), -amount } }) |half| {
                    const held = self.isHeld(half[0]);
                    if (!held and half[1] >= settings.axis_press) try self.press(half[0], time);
                    if (held and half[1] < settings.axis_release) try self.release(half[0], time);
                }
            }

            /// Feeds an amount of motion, as the mouse moving or the wheel
            /// scrolling, added up until `endFrame`.
            pub fn motion(self: *Tracker, which: input.Motion, amount: f32) Allocator.Error!void {
                const slot = for (self.deltas.items) |*entry| {
                    if (entry.input.id() == Input.motion(which).id()) break entry;
                } else blk: {
                    try self.deltas.append(self.gpa, .{ .input = .motion(which), .value = 0 });
                    break :blk &self.deltas.items[self.deltas.items.len - 1];
                };
                slot.value += amount;
            }

            /// Feeds the wheel scrolling: its amounts as motion, and a step
            /// each way it moved, which presses and releases at once.
            pub fn wheel(self: *Tracker, x: f32, y: f32, time: u64) Allocator.Error!void {
                if (x != 0) try self.motion(.wheel_x, x);
                if (y != 0) try self.motion(.wheel_y, y);
                const steps = [_]struct { f32, input.Wheel, input.Wheel }{ .{ y, .up, .down }, .{ x, .right, .left } };
                for (steps) |step| if (step[0] != 0) {
                    const which: Input = .wheel(if (step[0] > 0) step[1] else step[2]);
                    try self.press(which, time);
                    try self.release(which, time);
                };
            }

            /// Fires every hold and repeat due by `now`, at its deadline.
            pub fn update(self: *Tracker, now: u64) Allocator.Error!void {
                try self.prepare(now);
            }

            /// Releases every held input, as when the window loses focus.
            pub fn releaseAll(self: *Tracker, time: u64) Allocator.Error!void {
                while (self.held.items.len > 0) {
                    const next = for (self.held.items) |entry| {
                        const k = entry.input.asKey() orelse break entry.input;
                        if (k.modifier() == null or k.either() != null) break entry.input;
                    } else self.held.items[self.held.items.len - 1].input;
                    try self.release(next, time);
                }
            }

            /// Clears what happened this frame: presses, releases, motion
            /// and events.
            pub fn endFrame(self: *Tracker) void {
                for (&self.states) |*state| {
                    state.presses = 0;
                    state.releases = 0;
                }
                self.deltas.clearRetainingCapacity();
                self.events.clearRetainingCapacity();
                self.dispatched = 0;
            }

            /// Starts listening for a chord to bind, as a settings menu does:
            /// until it is taken, presses fire nothing. A modifier pressed
            /// and released alone is captured as its key.
            pub fn startCapture(self: *Tracker) void {
                self.capture = .{};
            }

            /// The chord captured, which ends capturing; null while waiting.
            pub fn takeCapture(self: *Tracker) ?Chord {
                const capture = self.capture orelse return null;
                const result = capture.result orelse return null;
                self.capture = null;
                return result;
            }

            pub fn cancelCapture(self: *Tracker) void {
                self.capture = null;
            }

            /// Catches up with the keymap if it changed, then fires what is
            /// due by `time`.
            fn prepare(self: *Tracker, time: u64) Allocator.Error!void {
                if (self.generation != self.keymap.generation) try self.restart();
                try self.advance(@max(time, self.now));
            }

            /// Lets go of every binding and sizes the runs to the keymap's
            /// bindings, after the keymap changed.
            fn restart(self: *Tracker) Allocator.Error!void {
                for (&self.states) |*state| {
                    if (state.down > 0) state.releases += 1;
                    state.down = 0;
                }
                try self.runs.resize(self.gpa, self.keymap.bindings.items.len);
                @memset(self.runs.items, .{});
                self.live.clearRetainingCapacity();
                self.timed.clearRetainingCapacity();
                self.pending.clearRetainingCapacity();
                self.generation = self.keymap.generation;
            }

            fn advance(self: *Tracker, now: u64) Allocator.Error!void {
                while (true) {
                    var due: ?usize = null;
                    var earliest: u64 = now;
                    for (self.timed.items, 0..) |id, slot| {
                        const deadline = self.runs.items[id].deadline;
                        if (deadline <= earliest) {
                            earliest = deadline;
                            due = slot;
                        }
                    }
                    if (self.pending.items.len > 0 and self.pending_deadline <= earliest) {
                        self.now = self.pending_deadline;
                        self.pending.clearRetainingCapacity();
                        continue;
                    }
                    const slot = due orelse break;
                    const id = self.timed.items[slot];
                    const run = &self.runs.items[id];
                    const b = &self.keymap.bindings.items[id];
                    self.now = run.deadline;
                    switch (b.gesture) {
                        .hold => {
                            _ = self.timed.swapRemove(slot);
                            try self.emit(id, run.deadline, 0);
                            self.activate(id, run.deadline);
                        },
                        .repeat => |repeat| {
                            run.repeats += 1;
                            try self.emit(id, run.deadline, run.repeats);
                            run.deadline += repeat.interval;
                        },
                        else => unreachable,
                    }
                }
                self.now = now;
            }

            /// Holds `which`, and the either-side key of a modifier; null if it
            /// was already held, as a key the system repeats is, or else the
            /// either-side key it pressed with it.
            fn hold(self: *Tracker, which: Input) Allocator.Error!??Input {
                if (self.find(which) != null) return null;
                try self.held.ensureUnusedCapacity(self.gpa, 2);
                self.held.appendAssumeCapacity(.{ .input = which, .count = 1 });
                var either_pressed: ?Input = null;
                if (which.asKey()) |k| if (k.either()) |either| {
                    if (self.find(.key(either))) |slot| {
                        self.held.items[slot].count += 1;
                    } else {
                        self.held.appendAssumeCapacity(.{ .input = .key(either), .count = 1 });
                        either_pressed = .key(either);
                    }
                };
                if (which.modifier()) |modifier| self.mods = self.mods.with(modifier, true);
                return either_pressed;
            }

            /// Releases `which`; null if it was not held, or else the
            /// either-side key released with it.
            fn unhold(self: *Tracker, which: Input) ??Input {
                const slot = self.find(which) orelse return null;
                _ = self.held.orderedRemove(slot);
                var either_released: ?Input = null;
                if (which.asKey()) |k| if (k.either()) |either| if (self.find(.key(either))) |either_slot| {
                    self.held.items[either_slot].count -= 1;
                    if (self.held.items[either_slot].count == 0) {
                        _ = self.held.orderedRemove(either_slot);
                        either_released = .key(either);
                    }
                };
                if (which.modifier()) |modifier| if (!self.isHeld(.key(keyOf(modifier)))) {
                    self.mods = self.mods.with(modifier, false);
                };
                return either_released;
            }

            fn keyOf(modifier: input.Modifier) input.Key {
                return switch (modifier) {
                    .ctrl => .ctrl,
                    .shift => .shift,
                    .alt => .alt,
                    .super => .super,
                };
            }

            fn find(self: *const Tracker, which: Input) ?usize {
                for (self.held.items, 0..) |entry, slot| if (entry.input.id() == which.id()) return slot;
                return null;
            }

            fn valueOf(self: *const Tracker, list: *const std.ArrayList(Value), which: Input) f32 {
                _ = self;
                for (list.items) |entry| if (entry.input.id() == which.id()) return entry.value;
                return 0;
            }

            fn setValue(gpa: Allocator, list: *std.ArrayList(Value), which: Input, amount: f32) Allocator.Error!void {
                for (list.items) |*entry| if (entry.input.id() == which.id()) {
                    entry.value = amount;
                    return;
                };
                try list.append(gpa, .{ .input = which, .value = amount });
            }

            fn deadzoned(self: *const Tracker, amount: f32) f32 {
                const deadzone = self.keymap.settings.deadzone;
                const magnitude = @abs(amount);
                if (magnitude <= deadzone) return 0;
                return std.math.sign(amount) * @min((magnitude - deadzone) / (1 - deadzone), 1);
            }

            fn allowed(self: *const Tracker, b: *const Binding) bool {
                return b.when.subsetOf(self.contexts) and b.unless.intersectWith(self.contexts).count() == 0;
            }

            /// Whether the digital inputs of `chord` are held, and the
            /// modifiers held suit it.
            fn holding(self: *const Tracker, chord: *const Chord, exact: bool) bool {
                for (chord.inputs()) |which| if (which.isDigital() and !self.isHeld(which)) return false;
                const held: Mods = @bitCast(self.mods.bits() & ~chord.ownMods().bits());
                return if (exact) held.bits() == chord.mods.bits() else chord.mods.within(held);
            }

            /// Fires what a press of `which` completes: of the bindings whose
            /// first chord it completes, the highest in priority and then
            /// specificity, and the rest in turn until one consumes it.
            fn match(self: *Tracker, which: Input) Allocator.Error!void {
                const keymap = self.keymap;
                self.candidates.clearRetainingCapacity();
                for (keymap.digitalFor(which)) |id| {
                    const b = &keymap.bindings.items[id];
                    if (!self.allowed(b) or !self.holding(b.trigger.first(), b.exact)) continue;
                    try self.candidates.append(self.gpa, .{ .id = id, .priority = b.priority, .specificity = b.trigger.first().specificity() });
                }
                const found = self.candidates.items;
                std.sort.insertion(Candidate, found, {}, struct {
                    fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                        if (a.priority != b.priority) return a.priority > b.priority;
                        if (a.specificity != b.specificity) return a.specificity > b.specificity;
                        return a.id < b.id;
                    }
                }.lessThan);
                var group: usize = 0;
                while (group < found.len) {
                    var end = group + 1;
                    while (end < found.len and found[end].priority == found[group].priority and found[end].specificity == found[group].specificity) end += 1;
                    var consumed = false;
                    for (found[group..end]) |candidate| {
                        const b = &keymap.bindings.items[candidate.id];
                        consumed = consumed or b.consume;
                        if (b.trigger.len > 1) {
                            try self.pending.append(self.gpa, .{ .id = candidate.id, .step = 1 });
                            self.pending_deadline = self.now + keymap.settings.sequence_timeout;
                        } else {
                            try self.start(candidate.id, which);
                        }
                    }
                    if (consumed) break;
                    group = end;
                }
            }

            /// Moves sequences waiting on their next chord along; true if
            /// `which` moved any, which then consumes it.
            fn continueSequences(self: *Tracker, which: Input) Allocator.Error!bool {
                const keymap = self.keymap;
                var kept: usize = 0;
                var moved = false;
                for (0..self.pending.items.len) |at| {
                    const entry = self.pending.items[at];
                    const b = &keymap.bindings.items[entry.id];
                    const chord = &b.trigger.chords()[entry.step];
                    if (!chord.contains(which) or !self.allowed(b) or !self.holding(chord, b.exact)) continue;
                    moved = true;
                    if (entry.step + 1 == b.trigger.len) {
                        try self.start(entry.id, which);
                    } else {
                        self.pending.items[kept] = .{ .id = entry.id, .step = entry.step + 1 };
                        kept += 1;
                    }
                }
                if (!moved and which.modifier() != null) return false;
                self.pending.items.len = kept;
                if (kept > 0) self.pending_deadline = self.now + keymap.settings.sequence_timeout;
                return moved;
            }

            /// Starts the gesture of a binding whose trigger `which` just
            /// completed.
            fn start(self: *Tracker, id: u32, which: Input) Allocator.Error!void {
                const run = &self.runs.items[id];
                if (run.phase != .idle) return;
                try self.live.ensureUnusedCapacity(self.gpa, 1);
                try self.timed.ensureUnusedCapacity(self.gpa, 1);
                const b = &self.keymap.bindings.items[id];
                const now = self.now;
                run.input = which;
                run.start = now;
                run.repeats = 0;
                switch (b.gesture) {
                    .press => {
                        try self.emit(id, now, 0);
                        self.activate(id, now);
                    },
                    .repeat => |repeat| {
                        try self.emit(id, now, 0);
                        self.activate(id, now);
                        run.deadline = now + repeat.delay;
                        self.timed.appendAssumeCapacity(id);
                    },
                    .hold => |hold_for| {
                        run.phase = .armed;
                        run.deadline = now + hold_for;
                        self.timed.appendAssumeCapacity(id);
                    },
                    .release, .tap => run.phase = .armed,
                    .double_tap => |window| {
                        const second = if (run.first_tap) |first| now - first <= window else false;
                        run.first_tap = if (second) null else now;
                        if (second) {
                            try self.emit(id, now, 0);
                            self.activate(id, now);
                        }
                    },
                }
                if (run.phase != .idle) self.live.appendAssumeCapacity(id);
            }

            /// Ends the bindings that releasing `which` lets go of, firing
            /// their release and tap gestures unless `cancel`.
            fn letGo(self: *Tracker, which: Input, cancel: bool) Allocator.Error!void {
                const keymap = self.keymap;
                const modifier = which.modifier();
                const either_modifier = modifier != null and which.asKey().?.either() == null;
                var at = self.live.items.len;
                while (at > 0) {
                    at -= 1;
                    const id = self.live.items[at];
                    const chord = keymap.bindings.items[id].trigger.last();
                    if (chord.contains(which) or (either_modifier and chord.mods.has(modifier.?))) try self.finish(id, cancel);
                }
            }

            fn finish(self: *Tracker, id: u32, cancel: bool) Allocator.Error!void {
                const run = &self.runs.items[id];
                const b = &self.keymap.bindings.items[id];
                const now = self.now;
                if (run.phase == .armed and !cancel) switch (b.gesture) {
                    .release => try self.emit(id, now, 0),
                    .tap => |within| if (now - run.start <= within) try self.emit(id, now, 0),
                    else => {},
                };
                if (run.phase == .active) self.deactivate(id);
                run.phase = .idle;
                removeId(&self.live, id);
                removeId(&self.timed, id);
            }

            fn removeId(list: *std.ArrayList(u32), id: u32) void {
                for (list.items, 0..) |item, slot| if (item == id) {
                    _ = list.swapRemove(slot);
                    return;
                };
            }

            /// Lets go, without firing, of bindings the contexts no longer
            /// allow.
            fn recheck(self: *Tracker) void {
                if (self.generation != self.keymap.generation) return;
                var at = self.live.items.len;
                while (at > 0) {
                    at -= 1;
                    const id = self.live.items[at];
                    if (!self.allowed(&self.keymap.bindings.items[id])) self.finish(id, true) catch unreachable;
                }
                var kept: usize = 0;
                for (self.pending.items) |entry| if (self.allowed(&self.keymap.bindings.items[entry.id])) {
                    self.pending.items[kept] = entry;
                    kept += 1;
                };
                self.pending.items.len = kept;
            }

            fn emit(self: *Tracker, id: u32, time: u64, repeat: u32) Allocator.Error!void {
                const b = &self.keymap.bindings.items[id];
                try self.events.append(self.gpa, .{
                    .action = b.action,
                    .gesture = b.gesture,
                    .time = time,
                    .binding = @fromBackingInt(@intCast(id)),
                    .caller = self.caller,
                    .repeat = repeat,
                });
                self.states[actions.indexOf(b.action)].presses += 1;
            }

            fn activate(self: *Tracker, id: u32, time: u64) void {
                self.runs.items[id].phase = .active;
                const state = &self.states[actions.indexOf(self.keymap.bindings.items[id].action)];
                if (state.down == 0) state.since = time;
                state.down += 1;
            }

            fn deactivate(self: *Tracker, id: u32) void {
                const state = &self.states[actions.indexOf(self.keymap.bindings.items[id].action)];
                state.down -= 1;
                if (state.down == 0) state.releases += 1;
            }
        };

        /// What runs when an action fires: a function and its context.
        pub const Handler = struct {
            context: ?*anyopaque,
            call: *const fn (context: ?*anyopaque, event: Event) bool,

            /// `function(context, event)`, which returns true if it handled
            /// the event, so later handlers of its action do not see it, or
            /// nothing to let them.
            pub fn of(context: anytype, comptime function: anytype) Handler {
                const Erased = @TypeOf(context);
                const pointer = @typeInfo(Erased) == .pointer;
                if (!pointer and Erased != void) @compileError("keybinds: a handler's context is a pointer, or void for none");
                return .{
                    .context = if (pointer) @ptrCast(@constCast(context)) else null,
                    .call = struct {
                        fn call(erased: ?*anyopaque, event: Event) bool {
                            const typed: Erased = if (pointer) @ptrCast(@alignCast(erased.?)) else {};
                            const result = function(typed, event);
                            return if (@TypeOf(result) == bool) result else false;
                        }
                    }.call,
                };
            }
        };

        /// Handlers by action, which a tracker's events are dispatched to.
        pub const Handlers = struct {
            gpa: Allocator,
            lists: [action_count]std.ArrayList(Entry) = @splat(.empty),
            next_id: u32 = 0,

            const Entry = struct { id: u32, priority: i8, handler: Handler };

            pub const Id = enum(u32) { _ };

            pub fn init(gpa: Allocator) Handlers {
                return .{ .gpa = gpa };
            }

            pub fn deinit(self: *Handlers) void {
                for (&self.lists) |*list| list.deinit(self.gpa);
                self.* = undefined;
            }

            /// Runs `handler` when `action` fires; handlers of higher
            /// priority run first, and those of equal priority in the order
            /// added.
            pub fn on(self: *Handlers, action: Action, handler: Handler, options: struct { priority: i8 = 0 }) Allocator.Error!Id {
                const list = &self.lists[actions.indexOf(action)];
                var at = list.items.len;
                while (at > 0 and list.items[at - 1].priority < options.priority) at -= 1;
                try list.insert(self.gpa, at, .{ .id = self.next_id, .priority = options.priority, .handler = handler });
                self.next_id += 1;
                return @fromBackingInt(@intCast(self.next_id - 1));
            }

            pub fn off(self: *Handlers, id: Id) void {
                for (&self.lists) |*list| for (list.items, 0..) |entry, at| if (entry.id == @backingInt(id)) {
                    _ = list.orderedRemove(at);
                    return;
                };
            }

            /// Runs the handlers of every event `tracker` fired since it was
            /// last dispatched, in order.
            pub fn dispatch(self: *const Handlers, tracker: *Tracker) void {
                while (tracker.dispatched < tracker.events.items.len) {
                    const event = tracker.events.items[tracker.dispatched];
                    tracker.dispatched += 1;
                    for (self.lists[actions.indexOf(event.action)].items) |entry| {
                        if (entry.handler.call(entry.handler.context, event)) break;
                    }
                }
            }
        };
    };
}
