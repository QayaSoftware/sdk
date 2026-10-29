//! Suggestions for completing a command as it is typed.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A way to go on with the input: `text` in place of `input[start..end]`.
pub const Suggestion = struct {
    start: usize,
    end: usize,
    text: []const u8,
    /// What the suggestion means, for a tooltip beside it.
    tooltip: ?[]const u8 = null,
};

/// The suggestions for an input, sorted ignoring case and without repeats.
pub const Suggestions = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Suggestion = &.{},

    pub fn deinit(self: *Suggestions) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// What suggestions for the argument being typed are added to.
pub const Builder = struct {
    /// The input, up to where suggestions are wanted.
    input: []const u8,
    /// Where the argument being typed starts.
    start: usize,
    arena: Allocator,
    list: *std.ArrayList(Suggestion),

    /// What was typed of the argument, which suggestions complete.
    pub fn remaining(self: *const Builder) []const u8 {
        return self.input[self.start..];
    }

    /// Whether `text` completes what was typed, ignoring case.
    pub fn matches(self: *const Builder, text: []const u8) bool {
        return std.ascii.startsWithIgnoreCase(text, self.remaining());
    }

    /// Suggests `text` if it completes what was typed and is not just what
    /// was typed; `text` is copied.
    pub fn add(self: *Builder, text: []const u8) Allocator.Error!void {
        return self.addTooltip(text, null);
    }

    /// Suggests `text`, explained by `tooltip`, if it completes what was
    /// typed and is not just what was typed; both are copied.
    pub fn addTooltip(self: *Builder, text: []const u8, tooltip: ?[]const u8) Allocator.Error!void {
        if (!self.matches(text) or std.mem.eql(u8, text, self.remaining())) return;
        try self.list.append(self.arena, .{
            .start = self.start,
            .end = self.input.len,
            .text = try self.arena.dupe(u8, text),
            .tooltip = if (tooltip) |t| try self.arena.dupe(u8, t) else null,
        });
    }
};

/// Sorts `items` by where they start and then ignoring case, and drops
/// repeats.
pub fn finish(items: []Suggestion) []Suggestion {
    std.mem.sort(Suggestion, items, {}, lessThan);
    var kept: usize = 0;
    for (items) |item| {
        if (kept > 0) {
            const last = items[kept - 1];
            if (last.start == item.start and last.end == item.end and std.mem.eql(u8, last.text, item.text)) continue;
        }
        items[kept] = item;
        kept += 1;
    }
    return items[0..kept];
}

fn lessThan(_: void, a: Suggestion, b: Suggestion) bool {
    if (a.start != b.start) return a.start < b.start;
    return switch (std.ascii.orderIgnoreCase(a.text, b.text)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.text, b.text) == .lt,
    };
}
