//! What every logger shares: the lock, the levels and scopes, listeners,
//! frames, threads, the loggers themselves and their counts.
const std = @import("std");
const Writer = std.Io.Writer;

const format = @import("format.zig");
const Record = format.Record;
const Level = std.log.Level;

/// The Io that logging reads clocks and writes files and stderr through:
/// std.debug's, so it works before the application has an Io, inside one,
/// and while panicking.
pub const io = std.Options.debug_io;

var mutex: std.Io.Mutex = .init;
/// Whether this thread holds the lock, so logging from inside a listener,
/// a custom format or a panic writes without locking again.
threadlocal var holding: bool = false;

/// Locks, unless this thread holds the lock already; says whether it did,
/// for `unlock`. Records are written under the lock in well under a
/// microsecond, so a thread finding it taken spins a little before it
/// sleeps.
pub fn lock() bool {
    if (holding) return false;
    var spins: usize = 0;
    while (!mutex.tryLock()) : (spins += 1) {
        if (spins == 128) {
            mutex.lockUncancelable(io);
            break;
        }
        std.atomic.spinLoopHint();
    }
    holding = true;
    return true;
}

pub fn unlock(locked: bool) void {
    if (!locked) return;
    holding = false;
    mutex.unlock(io);
}

/// Reads `clock` in nanoseconds.
pub fn now(clock: std.Io.Clock) i96 {
    return std.Io.Clock.now(clock, io).nanoseconds;
}

var start: std.atomic.Value(i64) = .init(std.math.minInt(i64));

/// Nanoseconds from when logging started, the first time this is asked, to
/// `awake`, a reading of the awake clock.
pub fn sinceStart(awake: i96) u64 {
    const reading: i64 = @intCast(awake);
    var began = start.load(.monotonic);
    if (began == std.math.minInt(i64)) {
        began = start.cmpxchgStrong(began, reading, .monotonic, .monotonic) orelse reading;
    }
    return @intCast(@max(reading - began, 0));
}

/// A level stored as a byte: a `Level`'s value, or `inherit`.
pub const inherit: u8 = 0xff;

pub var default_level: std.atomic.Value(u8) = .init(inherit);

/// A scope's runtime state, one for each scope logged with.
pub const Scope = struct {
    name: []const u8,
    level: std.atomic.Value(u8) = .init(inherit),
    registered: std.atomic.Value(bool) = .init(false),
    next: ?*Scope = null,
};

pub fn ScopeOf(comptime scope: @EnumLiteral()) type {
    return struct {
        pub var state: Scope = .{ .name = @tagName(scope) };
    };
}

var scopes: ?*Scope = null;

/// Levels set by name for scopes that have not logged yet.
var pending: [32]Pending = undefined;
var pending_count: usize = 0;

const Pending = struct {
    name: [max_name]u8,
    len: u8,
    level: u8,
};

pub const max_name = 64;

/// Adds `scope` to the scopes that can be found by name, giving it any level
/// set for its name before.
pub fn register(scope: *Scope) void {
    const locked = lock();
    defer unlock(locked);
    if (scope.registered.load(.monotonic)) return;
    for (pending[0..pending_count], 0..) |*entry, i| {
        if (!std.mem.eql(u8, entry.name[0..entry.len], scope.name)) continue;
        scope.level.store(entry.level, .monotonic);
        pending[i] = pending[pending_count - 1];
        pending_count -= 1;
        break;
    }
    scope.next = scopes;
    scopes = scope;
    scope.registered.store(true, .release);
}

pub const LevelError = error{
    /// The name is longer than any scope's can be.
    NameTooLong,
    /// Too many names were given levels before their scopes logged.
    TooManyNames,
};

pub fn setLevelByName(name: []const u8, level: ?Level) LevelError!void {
    if (name.len > max_name) return error.NameTooLong;
    const stored: u8 = if (level) |l| @backingInt(l) else inherit;
    const locked = lock();
    defer unlock(locked);
    var scope = scopes;
    while (scope) |found| : (scope = found.next) {
        if (!std.mem.eql(u8, found.name, name)) continue;
        found.level.store(stored, .monotonic);
        return;
    }
    for (pending[0..pending_count], 0..) |*entry, i| {
        if (!std.mem.eql(u8, entry.name[0..entry.len], name)) continue;
        if (level == null) {
            pending[i] = pending[pending_count - 1];
            pending_count -= 1;
        } else entry.level = stored;
        return;
    }
    if (level == null) return;
    if (pending_count == pending.len) return error.TooManyNames;
    pending[pending_count] = .{ .name = undefined, .len = @intCast(name.len), .level = stored };
    @memcpy(pending[pending_count].name[0..name.len], name);
    pending_count += 1;
}

/// The level set for the scope named `name`, if any; null when it inherits.
pub fn levelOfName(name: []const u8) ?Level {
    const locked = lock();
    defer unlock(locked);
    var scope = scopes;
    while (scope) |found| : (scope = found.next) {
        if (std.mem.eql(u8, found.name, name)) return toLevel(found.level.load(.monotonic));
    }
    for (pending[0..pending_count]) |entry| {
        if (std.mem.eql(u8, entry.name[0..entry.len], name)) return toLevel(entry.level);
    }
    return null;
}

pub fn toLevel(stored: u8) ?Level {
    return if (stored == inherit) null else @fromBackingInt(@intCast(stored));
}

/// Copies the names of the scopes that have logged into `buffer`.
pub fn scopeNames(buffer: [][]const u8) []const []const u8 {
    const locked = lock();
    defer unlock(locked);
    var count: usize = 0;
    var scope = scopes;
    while (scope) |found| : (scope = found.next) {
        if (count == buffer.len) break;
        buffer[count] = found.name;
        count += 1;
    }
    return buffer[0..count];
}

pub var frame: std.atomic.Value(u64) = .init(0);

var next_thread: std.atomic.Value(u32) = .init(1);
threadlocal var thread_number: u32 = 0;
pub threadlocal var thread_name: ?[]const u8 = null;

/// The calling thread, numbered the first time it asks.
pub fn thread() Record.Thread {
    if (thread_number == 0) thread_number = next_thread.fetchAdd(1, .monotonic);
    return .{ .number = thread_number, .name = thread_name };
}

/// Called with each record; embed it in what it reports to, and find that
/// again with `@fieldParentPtr`.
pub const Listener = struct {
    call: *const fn (listener: *Listener, record: *const Record) void,
    next: ?*Listener = null,
};

var listeners: ?*Listener = null;

pub fn listen(listener: *Listener) void {
    const locked = lock();
    defer unlock(locked);
    var current = listeners;
    while (current) |found| : (current = found.next) if (found == listener) return;
    listener.next = listeners;
    listeners = listener;
}

pub fn unlisten(listener: *Listener) void {
    const locked = lock();
    defer unlock(locked);
    var link = &listeners;
    while (link.*) |found| : (link = &found.next) {
        if (found != listener) continue;
        link.* = found.next;
        found.next = null;
        return;
    }
}

/// Calls every listener with `record`; the lock is held.
pub fn notify(record: *const Record) void {
    var current = listeners;
    while (current) |found| {
        const next = found.next;
        found.call(found, record);
        current = next;
    }
}

/// A logger made by `Logger`, for what works on all of them.
pub const Instance = struct {
    /// Writes out buffers and counts of repeats; the lock is held, and
    /// `notify` says whether listeners hear of the counts.
    flush: *const fn (notify: bool) void,
    /// Writes a record to every sink but the terminal; the lock is held.
    record: *const fn (record: *const Record) void,
    writeRecent: *const fn (writer: *Writer, max_lines: usize) Writer.Error!void,
    setFile: *const fn (target: Target) SetFileError!void,
    has_file: bool,
    next: ?*Instance = null,
};

var instances: ?*Instance = null;

/// Adds a logger to those `forEach` reaches; the lock is held.
pub fn addInstance(instance: *Instance) void {
    instance.next = instances;
    instances = instance;
}

/// The loggers that have logged; walked with the lock held.
pub fn firstInstance() ?*Instance {
    return instances;
}

pub const Target = union(enum) {
    /// One file, rotated as `path.1`, `path.2` and so on when it grows too big.
    path: []const u8,
    /// A directory with a file for each run, named by the date and time in
    /// UTC.
    directory: []const u8,
};

pub const SetFileError = std.Io.File.OpenError || std.Io.Dir.CreateDirPathOpenError || error{
    /// No logger has a file sink to point at the target.
    NoFileSink,
    NameTooLong,
};

/// What logging has done, and failed to do.
pub const Stats = struct {
    /// Records written.
    records: u64 = 0,
    /// Records collapsed into the one before them.
    collapsed: u64 = 0,
    /// Writes and file operations that failed; logging carries on past them.
    failures: u64 = 0,
    /// Bytes discarded because a file sink had no target yet and its buffer
    /// was full.
    dropped: u64 = 0,
};

/// Changed with the lock held.
pub var stats: Stats = .{};

/// The longest target path a file sink keeps.
pub const max_path = 1024;

/// A target `setFile` gave before a logger with a file sink logged, for the
/// first one to open.
pub var pending_target: ?Target = null;
var pending_path: [max_path]u8 = undefined;

/// Remembers `target` for the first logger with a file sink; the lock is
/// held.
pub fn holdTarget(target: Target) SetFileError!void {
    const path = switch (target) {
        inline else => |path| path,
    };
    if (path.len > max_path) return error.NameTooLong;
    @memcpy(pending_path[0..path.len], path);
    pending_target = switch (target) {
        .path => .{ .path = pending_path[0..path.len] },
        .directory => .{ .directory = pending_path[0..path.len] },
    };
}
