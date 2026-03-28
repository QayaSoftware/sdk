const std = @import("std");
const World = @import("world.zig").World;
const registry = @import("registry.zig");

/// Minimal mask pair for conflict checks (tools, tests, custom schedulers).
pub const Masks = struct {
    read_mask: u64,
    write_mask: u64,
};

/// True if two systems cannot run concurrently (pairwise component-mask rules).
pub fn masksConflict(a: Masks, b: Masks) bool {
    if (a.write_mask & b.write_mask != 0) return true;
    if (a.write_mask & b.read_mask != 0) return true;
    if (a.read_mask & b.write_mask != 0) return true;
    return false;
}

pub fn Schedule(comptime Bundle: type) type {
    registry.assertMaxComponents(Bundle);
    const Info = registry.BundleInfo(Bundle);
    const W = World(Bundle);

    return struct {
        allocator: std.mem.Allocator,
        systems: std.ArrayListUnmanaged(SystemEntry),

        const SystemEntry = struct {
            run: *const fn (*W) anyerror!void,
            read_mask: u64,
            write_mask: u64,
        };

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
                .systems = .empty,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.systems.deinit(self.allocator);
        }

        pub fn addWithMasks(
            self: *@This(),
            comptime read: []const type,
            comptime write: []const type,
            comptime f: *const fn (*W) anyerror!void,
        ) !void {
            try self.systems.append(self.allocator, .{
                .run = f,
                .read_mask = Info.maskMany(read),
                .write_mask = Info.maskMany(write),
            });
        }

        pub fn add(self: *@This(), comptime write: []const type, comptime f: *const fn (*W) anyerror!void) !void {
            try self.addWithMasks(&.{}, write, f);
        }

        /// Run systems in registration order on one world.
        pub fn run(self: *const @This(), world: *W) !void {
            for (self.systems.items) |e| {
                try e.run(world);
            }
        }

        /// Greedy batching by masks, then strictly ordered batches. Within a batch, systems run on `pool`.
        pub fn runParallel(self: *const @This(), world: *W, pool: *std.Thread.Pool) !void {
            const sys = self.systems.items;
            if (sys.len == 0) return;

            const masks = try self.allocator.alloc(Masks, sys.len);
            defer self.allocator.free(masks);
            for (sys, 0..) |e, i| {
                masks[i] = .{ .read_mask = e.read_mask, .write_mask = e.write_mask };
            }

            const batches = try computeBatchesFromMasks(self.allocator, masks);
            defer freeBatches(self.allocator, batches);

            for (batches) |batch| {
                var wg: std.Thread.WaitGroup = .{};
                wg.reset();

                for (batch) |idx| {
                    const entry = sys[idx];
                    const Runner = struct {
                        fn call(w: *W, f: *const fn (*W) anyerror!void) void {
                            f(w) catch |err| {
                                std.debug.panic("parallel system failed: {s}", .{@errorName(err)});
                            };
                        }
                    };
                    pool.spawnWg(&wg, Runner.call, .{ world, entry.run });
                }
                wg.wait();
            }
        }

        pub fn len(self: *const @This()) usize {
            return self.systems.items.len;
        }
    };
}

fn computeBatchesFromMasks(allocator: std.mem.Allocator, masks: []const Masks) ![]const []const usize {
    var batch_lists: std.ArrayList(std.ArrayList(usize)) = .{};
    errdefer {
        for (batch_lists.items) |*b| b.deinit(allocator);
        batch_lists.deinit(allocator);
    }

    systems_loop: for (masks, 0..) |sys, i| {
        for (batch_lists.items) |*batch| {
            var ok = true;
            for (batch.items) |j| {
                const other = masks[j];
                if (masksConflict(sys, other)) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                try batch.append(allocator, i);
                continue :systems_loop;
            }
        }
        var nb: std.ArrayList(usize) = .{};
        try nb.append(allocator, i);
        try batch_lists.append(allocator, nb);
    }

    const out = try allocator.alloc([]const usize, batch_lists.items.len);
    errdefer {
        for (out) |batch| allocator.free(batch);
        allocator.free(out);
    }

    for (batch_lists.items, 0..) |*b, bi| {
        out[bi] = try b.toOwnedSlice(allocator);
    }
    for (batch_lists.items) |*b| {
        b.deinit(allocator);
    }
    batch_lists.deinit(allocator);
    return out;
}

fn freeBatches(allocator: std.mem.Allocator, batches: []const []const usize) void {
    for (batches) |b| allocator.free(b);
    allocator.free(batches);
}
