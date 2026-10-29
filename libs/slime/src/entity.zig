const std = @import("std");

/// A handle to an entity: its slot and the generation the slot was at when
/// the entity was made, so a handle to a despawned entity never resolves.
pub const Entity = packed struct(u64) {
    index: u32,
    generation: u32,

    pub const invalid: Entity = .{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn eql(self: Entity, other: Entity) bool {
        return self.index == other.index and self.generation == other.generation;
    }

    pub fn format(self: Entity, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Entity({d},{d})", .{ self.index, self.generation });
    }
};
