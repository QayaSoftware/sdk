//! An archetype entity component system: entities whose components live in
//! one table per set of component types, queried a table at a time;
//! resources, events delivered the frame after they are sent, schedules
//! that run non-conflicting systems concurrently, and prefabs editable in
//! code, at runtime and as JSON.
pub const Entity = @import("entity.zig").Entity;

pub const World = @import("world.zig").World;
pub const WorldError = @import("world.zig").Error;
pub const Query = World.Query;
pub const Chunk = World.Chunk;
pub const Commands = World.Commands;

pub const registry = @import("registry.zig");
pub const ComponentId = registry.ComponentId;
pub const ComponentInfo = registry.ComponentInfo;
pub const Mask = registry.Mask;
pub const register = registry.register;

pub const schedule = @import("schedule.zig");
pub const Schedule = schedule.Schedule;
pub const System = schedule.System;

pub const prefab = @import("prefab.zig");
pub const Prefab = prefab.Prefab;
pub const PrefabLibrary = prefab.PrefabLibrary;

test {
    _ = @import("world_tests.zig");
    _ = @import("schedule_tests.zig");
    _ = @import("prefab_tests.zig");
}
