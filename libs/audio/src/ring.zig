const std = @import("std");

/// Fixed ring of `T` between one producing thread and one consuming thread;
/// neither waits, locks or allocates. `capacity` is a power of two.
pub fn Ring(comptime T: type, comptime capacity: u32) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));
    return struct {
        const Self = @This();

        items: [capacity]T = undefined,
        /// Next item to pop; written by the consumer only.
        head: std.atomic.Value(u32) = .init(0),
        /// Next item to push; written by the producer only.
        tail: std.atomic.Value(u32) = .init(0),

        /// False when full. Producer only.
        pub fn push(self: *Self, item: T) bool {
            const tail = self.tail.load(.monotonic);
            if (tail -% self.head.load(.acquire) == capacity) return false;
            self.items[tail % capacity] = item;
            self.tail.store(tail +% 1, .release);
            return true;
        }

        /// Null when empty. Consumer only.
        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            if (head == self.tail.load(.acquire)) return null;
            const item = self.items[head % capacity];
            self.head.store(head +% 1, .release);
            return item;
        }
    };
}

test "a ring keeps order and reports full and empty" {
    var ring: Ring(u32, 4) = .{};
    try std.testing.expectEqual(@as(?u32, null), ring.pop());
    for (0..4) |value| try std.testing.expect(ring.push(@intCast(value)));
    try std.testing.expect(!ring.push(9));
    try std.testing.expectEqual(@as(?u32, 0), ring.pop());
    try std.testing.expect(ring.push(4));
    for (1..5) |value| try std.testing.expectEqual(@as(?u32, @intCast(value)), ring.pop());
    try std.testing.expectEqual(@as(?u32, null), ring.pop());
}
