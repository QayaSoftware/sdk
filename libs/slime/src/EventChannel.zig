//! Events of one type, delivered the frame after they are sent: systems read
//! last frame's events, which nothing changes until `update`, while this
//! frame's collect separately. A system running every frame sees each event
//! exactly once, whichever side of the sender it runs on, and reading never
//! races with sending.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn EventChannel(comptime E: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        io: std.Io,
        /// Sent last frame; read this frame.
        readable: std.ArrayList(E) = .empty,
        /// Sent this frame so far.
        pending: std.ArrayList(E) = .empty,
        /// Guards `pending`, which any system may send to at any time.
        mutex: std.Io.Mutex = .init,

        pub fn init(gpa: Allocator, io: std.Io) Self {
            return .{ .gpa = gpa, .io = io };
        }

        pub fn deinit(self: *Self) void {
            self.readable.deinit(self.gpa);
            self.pending.deinit(self.gpa);
        }

        pub fn send(self: *Self, event: E) Allocator.Error!void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.pending.append(self.gpa, event);
        }

        pub fn read(self: *const Self) []const E {
            return self.readable.items;
        }

        /// Makes this frame's events readable and drops last frame's.
        pub fn update(self: *Self) void {
            std.mem.swap(std.ArrayList(E), &self.readable, &self.pending);
            self.pending.clearRetainingCapacity();
        }
    };
}
