//! The physical inputs bindings are made of, independent of any windowing
//! library: keys, mouse buttons, wheel steps, gamepad buttons and axes,
//! motion, and inputs of the application's own. Each has a name for text,
//! as `ctrl+s` or `pad:south`, and one for showing, as `Ctrl+S`.
const std = @import("std");
const Writer = std.Io.Writer;

/// A key, by where it is on a US keyboard rather than what it types.
pub const Key = enum(u16) {
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    @"0",
    @"1",
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",
    @"9",
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    escape,
    enter,
    tab,
    backspace,
    space,
    insert,
    delete,
    home,
    end,
    page_up,
    page_down,
    up,
    down,
    left,
    right,
    caps_lock,
    scroll_lock,
    num_lock,
    print_screen,
    pause,
    menu,
    grave,
    minus,
    equal,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    apostrophe,
    comma,
    period,
    slash,
    /// Keys beside the left shift and the enter key on keyboards outside the US.
    world_1,
    world_2,
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    kp_decimal,
    kp_divide,
    kp_multiply,
    kp_subtract,
    kp_add,
    kp_enter,
    kp_equal,
    left_shift,
    left_ctrl,
    left_alt,
    left_super,
    right_shift,
    right_ctrl,
    right_alt,
    right_super,
    /// Either shift, ctrl, alt or super key: held while either side is.
    shift,
    ctrl,
    alt,
    super,
    volume_up,
    volume_down,
    mute,
    media_play,
    media_stop,
    media_next,
    media_previous,

    /// The modifier this key is, either side.
    pub fn modifier(self: Key) ?Modifier {
        return switch (self) {
            .left_shift, .right_shift, .shift => .shift,
            .left_ctrl, .right_ctrl, .ctrl => .ctrl,
            .left_alt, .right_alt, .alt => .alt,
            .left_super, .right_super, .super => .super,
            else => null,
        };
    }

    /// The key that is held while either side of this one is.
    pub fn either(self: Key) ?Key {
        return switch (self) {
            .left_shift, .right_shift => .shift,
            .left_ctrl, .right_ctrl => .ctrl,
            .left_alt, .right_alt => .alt,
            .left_super, .right_super => .super,
            else => null,
        };
    }

    pub fn displayName(self: Key) []const u8 {
        return switch (self) {
            inline .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z => |letter| comptime upper(@tagName(letter)),
            inline .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20, .f21, .f22, .f23, .f24 => |function| comptime upper(@tagName(function)),
            inline .kp_0, .kp_1, .kp_2, .kp_3, .kp_4, .kp_5, .kp_6, .kp_7, .kp_8, .kp_9 => |digit| "Num " ++ @tagName(digit)[3..],
            .escape => "Esc",
            .enter => "Enter",
            .tab => "Tab",
            .backspace => "Backspace",
            .space => "Space",
            .insert => "Insert",
            .delete => "Delete",
            .home => "Home",
            .end => "End",
            .page_up => "Page Up",
            .page_down => "Page Down",
            .up => "Up",
            .down => "Down",
            .left => "Left",
            .right => "Right",
            .caps_lock => "Caps Lock",
            .scroll_lock => "Scroll Lock",
            .num_lock => "Num Lock",
            .print_screen => "Print Screen",
            .pause => "Pause",
            .menu => "Menu",
            .grave => "`",
            .minus => "-",
            .equal => "=",
            .left_bracket => "[",
            .right_bracket => "]",
            .backslash => "\\",
            .semicolon => ";",
            .apostrophe => "'",
            .comma => ",",
            .period => ".",
            .slash => "/",
            .world_1 => "World 1",
            .world_2 => "World 2",
            .kp_decimal => "Num .",
            .kp_divide => "Num /",
            .kp_multiply => "Num *",
            .kp_subtract => "Num -",
            .kp_add => "Num +",
            .kp_enter => "Num Enter",
            .kp_equal => "Num =",
            .left_shift => "Left Shift",
            .left_ctrl => "Left Ctrl",
            .left_alt => "Left Alt",
            .left_super => "Left Super",
            .right_shift => "Right Shift",
            .right_ctrl => "Right Ctrl",
            .right_alt => "Right Alt",
            .right_super => "Right Super",
            .shift => "Shift",
            .ctrl => "Ctrl",
            .alt => "Alt",
            .super => "Super",
            .volume_up => "Volume Up",
            .volume_down => "Volume Down",
            .mute => "Mute",
            .media_play => "Play",
            .media_stop => "Stop",
            .media_next => "Next",
            .media_previous => "Previous",
            inline else => |digit| @tagName(digit),
        };
    }

    const aliases = std.StaticStringMap(Key).initComptime(.{
        .{ "esc", .escape },        .{ "return", .enter },             .{ "del", .delete },
        .{ "ins", .insert },        .{ "pgup", .page_up },             .{ "pgdn", .page_down },
        .{ "pageup", .page_up },    .{ "pagedown", .page_down },       .{ "spacebar", .space },
        .{ "`", .grave },           .{ "-", .minus },                  .{ "=", .equal },
        .{ "plus", .equal },        .{ "[", .left_bracket },           .{ "]", .right_bracket },
        .{ "\\", .backslash },      .{ ";", .semicolon },              .{ "'", .apostrophe },
        .{ ",", .comma },           .{ ".", .period },                 .{ "/", .slash },
        .{ "control", .ctrl },      .{ "option", .alt },               .{ "opt", .alt },
        .{ "cmd", .super },         .{ "command", .super },            .{ "meta", .super },
        .{ "win", .super },         .{ "windows", .super },            .{ "logo", .super },
        .{ "arrow_up", .up },       .{ "arrow_down", .down },          .{ "arrow_left", .left },
        .{ "arrow_right", .right }, .{ "printscreen", .print_screen },
    });

    /// The key named `text`, in lower case: its tag, or an alias such as
    /// `esc`, `pgup`, `cmd` or a symbol such as `` ` ``.
    pub fn parse(text: []const u8) ?Key {
        return std.meta.stringToEnum(Key, text) orelse aliases.get(text);
    }
};

/// The modifiers chords can require, either side.
pub const Modifier = enum { ctrl, shift, alt, super };

/// Which modifiers are held, or a chord requires.
pub const Mods = packed struct(u8) {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
    _: u4 = 0,

    pub fn with(self: Mods, which: Modifier, held: bool) Mods {
        var mods = self;
        switch (which) {
            inline else => |tag| @field(mods, @tagName(tag)) = held,
        }
        return mods;
    }

    pub fn has(self: Mods, which: Modifier) bool {
        return switch (which) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }

    pub fn bits(self: Mods) u8 {
        return @bitCast(self);
    }

    pub fn count(self: Mods) u8 {
        return @popCount(self.bits());
    }

    /// Whether every modifier of `self` is in `other`.
    pub fn within(self: Mods, other: Mods) bool {
        return self.bits() & ~other.bits() == 0;
    }

    const modifiers = std.StaticStringMap(Modifier).initComptime(.{
        .{ "ctrl", .ctrl },   .{ "control", .ctrl }, .{ "shift", .shift },
        .{ "alt", .alt },     .{ "option", .alt },   .{ "opt", .alt },
        .{ "super", .super }, .{ "cmd", .super },    .{ "command", .super },
        .{ "meta", .super },  .{ "win", .super },    .{ "windows", .super },
        .{ "logo", .super },
    });

    /// The modifier named `text`, in lower case.
    pub fn parseModifier(text: []const u8) ?Modifier {
        return modifiers.get(text);
    }
};

pub const Mouse = enum(u16) {
    left,
    right,
    middle,
    back,
    forward,
    button_6,
    button_7,
    button_8,

    pub fn displayName(self: Mouse) []const u8 {
        return switch (self) {
            .left => "Left Click",
            .right => "Right Click",
            .middle => "Middle Click",
            .back => "Mouse Back",
            .forward => "Mouse Forward",
            .button_6 => "Mouse 6",
            .button_7 => "Mouse 7",
            .button_8 => "Mouse 8",
        };
    }

    const aliases = std.StaticStringMap(Mouse).initComptime(.{
        .{ "1", .left },     .{ "2", .right },    .{ "3", .middle },   .{ "4", .back }, .{ "5", .forward },
        .{ "6", .button_6 }, .{ "7", .button_7 }, .{ "8", .button_8 },
    });
};

/// A step of the wheel, which presses and releases at once.
pub const Wheel = enum(u16) {
    up,
    down,
    left,
    right,

    pub fn displayName(self: Wheel) []const u8 {
        return switch (self) {
            .up => "Wheel Up",
            .down => "Wheel Down",
            .left => "Wheel Left",
            .right => "Wheel Right",
        };
    }
};

/// A gamepad button, by its place: `south` is A on an Xbox pad and cross on
/// a PlayStation one.
pub const Button = enum(u16) {
    south,
    east,
    west,
    north,
    back,
    guide,
    start,
    left_stick,
    right_stick,
    left_shoulder,
    right_shoulder,
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
    misc,
    paddle_1,
    paddle_2,
    paddle_3,
    paddle_4,
    touchpad,

    pub fn displayName(self: Button) []const u8 {
        return switch (self) {
            .south => "Pad South",
            .east => "Pad East",
            .west => "Pad West",
            .north => "Pad North",
            .back => "Pad Back",
            .guide => "Pad Guide",
            .start => "Pad Start",
            .left_stick => "Left Stick",
            .right_stick => "Right Stick",
            .left_shoulder => "Left Bumper",
            .right_shoulder => "Right Bumper",
            .dpad_up => "D-pad Up",
            .dpad_down => "D-pad Down",
            .dpad_left => "D-pad Left",
            .dpad_right => "D-pad Right",
            .misc => "Pad Misc",
            .paddle_1 => "Paddle 1",
            .paddle_2 => "Paddle 2",
            .paddle_3 => "Paddle 3",
            .paddle_4 => "Paddle 4",
            .touchpad => "Touchpad",
        };
    }

    const aliases = std.StaticStringMap(Button).initComptime(.{
        .{ "a", .south },           .{ "cross", .south },      .{ "b", .east },
        .{ "circle", .east },       .{ "x", .west },           .{ "square", .west },
        .{ "y", .north },           .{ "triangle", .north },   .{ "select", .back },
        .{ "home", .guide },        .{ "ls", .left_stick },    .{ "rs", .right_stick },
        .{ "l3", .left_stick },     .{ "r3", .right_stick },   .{ "lb", .left_shoulder },
        .{ "rb", .right_shoulder }, .{ "l1", .left_shoulder }, .{ "r1", .right_shoulder },
        .{ "up", .dpad_up },        .{ "down", .dpad_down },   .{ "left", .dpad_left },
        .{ "right", .dpad_right },
    });
};

/// A gamepad's analog axis: sticks from -1 to 1, and triggers from 0 to 1.
pub const Axis = enum(u16) {
    left_x,
    left_y,
    right_x,
    right_y,
    left_trigger,
    right_trigger,

    pub fn displayName(self: Axis) []const u8 {
        return switch (self) {
            .left_x => "Left Stick X",
            .left_y => "Left Stick Y",
            .right_x => "Right Stick X",
            .right_y => "Right Stick Y",
            .left_trigger => "Left Trigger",
            .right_trigger => "Right Trigger",
        };
    }

    const aliases = std.StaticStringMap(Axis).initComptime(.{
        .{ "lx", .left_x },       .{ "ly", .left_y },        .{ "rx", .right_x },      .{ "ry", .right_y },
        .{ "lt", .left_trigger }, .{ "rt", .right_trigger }, .{ "l2", .left_trigger }, .{ "r2", .right_trigger },
    });
};

/// Movement measured in amounts rather than positions: the mouse, and the
/// wheel's scrolling.
pub const Motion = enum(u16) {
    x,
    y,
    wheel_x,
    wheel_y,

    pub fn displayName(self: Motion) []const u8 {
        return switch (self) {
            .x => "Mouse X",
            .y => "Mouse Y",
            .wheel_x => "Scroll X",
            .wheel_y => "Scroll Y",
        };
    }
};

/// One physical input, in four bytes.
pub const Input = packed struct(u32) {
    code: u16,
    kind: Kind,
    _: u8 = 0,

    pub const Kind = enum(u8) {
        key,
        mouse,
        wheel,
        button,
        /// An analog axis, as its value.
        axis,
        /// An axis past the press threshold one way, as a button.
        axis_positive,
        axis_negative,
        /// Motion, as an amount each frame.
        motion,
        /// An input of the application's own: a touch zone, a MIDI note.
        custom,
    };

    pub fn key(which: Key) Input {
        return .{ .kind = .key, .code = @intFromEnum(which) };
    }

    pub fn mouse(which: Mouse) Input {
        return .{ .kind = .mouse, .code = @intFromEnum(which) };
    }

    pub fn wheel(which: Wheel) Input {
        return .{ .kind = .wheel, .code = @intFromEnum(which) };
    }

    pub fn button(which: Button) Input {
        return .{ .kind = .button, .code = @intFromEnum(which) };
    }

    pub fn axis(which: Axis) Input {
        return .{ .kind = .axis, .code = @intFromEnum(which) };
    }

    /// `which` pushed past the press threshold towards its positive end.
    pub fn axisPositive(which: Axis) Input {
        return .{ .kind = .axis_positive, .code = @intFromEnum(which) };
    }

    pub fn axisNegative(which: Axis) Input {
        return .{ .kind = .axis_negative, .code = @intFromEnum(which) };
    }

    pub fn motion(which: Motion) Input {
        return .{ .kind = .motion, .code = @intFromEnum(which) };
    }

    pub fn custom(code: u16) Input {
        return .{ .kind = .custom, .code = code };
    }

    pub fn id(self: Input) u32 {
        return @bitCast(self);
    }

    /// Whether it presses and releases, rather than having a value.
    pub fn isDigital(self: Input) bool {
        return self.kind != .axis and self.kind != .motion;
    }

    /// The key, if it is one.
    pub fn asKey(self: Input) ?Key {
        if (self.kind != .key) return null;
        return std.enums.fromInt(Key, self.code);
    }

    /// The modifier it is, if it is a modifier key.
    pub fn modifier(self: Input) ?Modifier {
        return if (self.asKey()) |k| k.modifier() else null;
    }

    pub const ParseError = error{UnknownInput};

    /// The input named `text`, in any case: a key as `space`, `f5` or `esc`;
    /// `mouse:left`; `wheel:up`; a gamepad button as `pad:south` or
    /// `pad:a`; an axis as `pad:left_x`, or as a button one way as
    /// `pad:left_x+` or `pad:rt+`; `motion:x`; or `custom:7`.
    pub fn parse(text: []const u8) ParseError!Input {
        var buffer: [32]u8 = undefined;
        if (text.len == 0 or text.len > buffer.len) return error.UnknownInput;
        const lower = std.ascii.lowerString(&buffer, text);
        const colon = std.mem.indexOfScalar(u8, lower, ':') orelse return .key(Key.parse(lower) orelse return error.UnknownInput);
        const space = lower[0..colon];
        const name = lower[colon + 1 ..];
        if (std.mem.eql(u8, space, "key")) return .key(Key.parse(name) orelse return error.UnknownInput);
        if (std.mem.eql(u8, space, "mouse")) return .mouse(named(Mouse, name) orelse return error.UnknownInput);
        if (std.mem.eql(u8, space, "wheel")) return .wheel(named(Wheel, name) orelse return error.UnknownInput);
        if (std.mem.eql(u8, space, "motion")) return .motion(named(Motion, name) orelse return error.UnknownInput);
        if (std.mem.eql(u8, space, "custom")) return .custom(std.fmt.parseInt(u16, name, 10) catch return error.UnknownInput);
        if (std.mem.eql(u8, space, "pad")) {
            if (named(Button, name)) |which| return .button(which);
            if (named(Axis, name)) |which| return .axis(which);
            if (name.len > 1 and (name[name.len - 1] == '+' or name[name.len - 1] == '-')) {
                const which = named(Axis, name[0 .. name.len - 1]) orelse return error.UnknownInput;
                return if (name[name.len - 1] == '+') .axisPositive(which) else .axisNegative(which);
            }
        }
        return error.UnknownInput;
    }

    fn named(comptime E: type, text: []const u8) ?E {
        if (std.meta.stringToEnum(E, text)) |value| return value;
        if (@hasDecl(E, "aliases")) return E.aliases.get(text);
        return null;
    }

    /// Writes the name `parse` reads, as `ctrl`, `mouse:left` or `pad:rt+`.
    pub fn writeText(self: Input, writer: *Writer) Writer.Error!void {
        switch (self.kind) {
            .key => try writer.writeAll(@tagName(self.asKey() orelse return writer.print("key:{d}", .{self.code}))),
            .mouse => try writer.print("mouse:{s}", .{tagOf(Mouse, self.code)}),
            .wheel => try writer.print("wheel:{s}", .{tagOf(Wheel, self.code)}),
            .button => try writer.print("pad:{s}", .{tagOf(Button, self.code)}),
            .axis => try writer.print("pad:{s}", .{tagOf(Axis, self.code)}),
            .axis_positive => try writer.print("pad:{s}+", .{tagOf(Axis, self.code)}),
            .axis_negative => try writer.print("pad:{s}-", .{tagOf(Axis, self.code)}),
            .motion => try writer.print("motion:{s}", .{tagOf(Motion, self.code)}),
            .custom => try writer.print("custom:{d}", .{self.code}),
        }
    }

    /// Writes the input as it is shown to a player, as `Space`, `Left Click`
    /// or `Right Trigger+`.
    pub fn format(self: Input, writer: *Writer) Writer.Error!void {
        switch (self.kind) {
            .key => try writer.writeAll(if (self.asKey()) |k| k.displayName() else "Key"),
            .mouse => try writer.writeAll(if (std.enums.fromInt(Mouse, self.code)) |m| m.displayName() else "Mouse"),
            .wheel => try writer.writeAll(if (std.enums.fromInt(Wheel, self.code)) |w| w.displayName() else "Wheel"),
            .button => try writer.writeAll(if (std.enums.fromInt(Button, self.code)) |b| b.displayName() else "Pad"),
            .axis, .axis_positive, .axis_negative => {
                try writer.writeAll(if (std.enums.fromInt(Axis, self.code)) |a| a.displayName() else "Axis");
                if (self.kind == .axis_positive) try writer.writeByte('+');
                if (self.kind == .axis_negative) try writer.writeByte('-');
            },
            .motion => try writer.writeAll(if (std.enums.fromInt(Motion, self.code)) |m| m.displayName() else "Motion"),
            .custom => try writer.print("Input {d}", .{self.code}),
        }
    }

    fn tagOf(comptime E: type, code: u16) []const u8 {
        return if (std.enums.fromInt(E, code)) |value| @tagName(value) else "?";
    }
};

fn upper(comptime text: []const u8) []const u8 {
    comptime {
        var out = text[0..text.len].*;
        for (&out) |*c| c.* = std.ascii.toUpper(c.*);
        const final = out;
        return &final;
    }
}
