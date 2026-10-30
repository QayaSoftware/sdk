//! Where records go besides the terminal: a file, or a directory of them,
//! and a ring of recent lines in memory.
const std = @import("std");
const Writer = std.Io.Writer;
const Dir = std.Io.Dir;
const File = std.Io.File;

const core = @import("core.zig");
const format = @import("format.zig");
const io = core.io;
const Target = core.Target;

/// A file, or a directory with a file for each run, written through a
/// buffer. Its writes never fail: what cannot be written is counted in
/// `core.stats` and logging carries on.
pub const FileSink = struct {
    interface: Writer,
    append: bool,
    max_bytes: ?u64,
    keep: usize,
    file: ?File = null,
    /// Where the next write goes in `file`.
    offset: u64 = 0,
    /// A directory target's directory, open.
    dir: ?Dir = null,
    target: ?Target = null,
    /// Whether a target was chosen, so the one configured is not opened
    /// over it.
    chosen: bool = false,
    path: [core.max_path]u8 = undefined,
    /// The elapsed time of the last flush.
    flushed_at: u64 = 0,

    pub const vtable: Writer.VTable = .{ .drain = drain };

    /// Closes what is open and opens `target`; what is buffered goes to it.
    pub fn open(self: *FileSink, target: Target) core.SetFileError!void {
        self.chosen = true;
        self.close();
        const path = switch (target) {
            inline else => |path| path,
        };
        if (path.len > core.max_path) return error.NameTooLong;
        @memcpy(self.path[0..path.len], path);
        const kept = self.path[0..path.len];
        switch (target) {
            .path => {
                if (std.fs.path.dirname(kept)) |parent| try Dir.cwd().createDirPath(io, parent);
                const file = try Dir.cwd().createFile(io, kept, .{ .truncate = !self.append });
                self.offset = if (self.append) file.length(io) catch 0 else 0;
                self.file = file;
                self.target = .{ .path = kept };
            },
            .directory => {
                self.dir = try Dir.cwd().createDirPathOpen(io, kept, .{ .open_options = .{ .iterate = true } });
                self.target = .{ .directory = kept };
                try self.openRunFile();
                self.prune();
            },
        }
    }

    /// Writes out what is buffered and closes the file; without a file,
    /// what is buffered stays for the target set later.
    pub fn close(self: *FileSink) void {
        self.flush();
        if (self.file) |file| file.close(io);
        if (self.dir) |dir| dir.close(io);
        self.file = null;
        self.dir = null;
        self.target = null;
    }

    pub fn flush(self: *FileSink) void {
        if (self.file == null) return;
        self.interface.flush() catch {};
    }

    /// Flushes as a record at `level` asks, and starts a new file once this
    /// one is too big.
    pub fn after(self: *FileSink, level: std.log.Level, flush_level: std.log.Level, elapsed: u64, interval: u64) void {
        if (self.file == null) return;
        if (@intFromEnum(level) <= @intFromEnum(flush_level) or elapsed -| self.flushed_at >= interval) {
            self.flush();
            self.flushed_at = elapsed;
        }
        const max = self.max_bytes orelse return;
        if (self.offset + self.interface.end >= max) self.rotate();
    }

    fn rotate(self: *FileSink) void {
        self.flush();
        const target = self.target orelse return;
        if (self.file) |file| file.close(io);
        self.file = null;
        switch (target) {
            .path => |path| {
                if (self.keep > 1) {
                    var from: [core.max_path + 24]u8 = undefined;
                    var to: [core.max_path + 24]u8 = undefined;
                    Dir.cwd().deleteFile(io, numbered(&to, path, self.keep - 1)) catch {};
                    var i = self.keep - 1;
                    while (i > 1) : (i -= 1) {
                        Dir.cwd().rename(numbered(&from, path, i - 1), Dir.cwd(), numbered(&to, path, i), io) catch {};
                    }
                    Dir.cwd().rename(path, Dir.cwd(), numbered(&to, path, 1), io) catch {
                        core.stats.failures += 1;
                    };
                }
                self.file = Dir.cwd().createFile(io, path, .{}) catch {
                    core.stats.failures += 1;
                    return;
                };
                self.offset = 0;
            },
            .directory => {
                self.openRunFile() catch {
                    core.stats.failures += 1;
                    return;
                };
                self.prune();
            },
        }
    }

    /// `path.number`, or `path` for 0.
    fn numbered(buffer: []u8, path: []const u8, number: usize) []const u8 {
        if (number == 0) return path;
        return std.fmt.bufPrint(buffer, "{s}.{d}", .{ path, number }) catch path;
    }

    /// Creates the directory's file for this run, named by the date and time
    /// in UTC, numbered if a file of that name is there already.
    fn openRunFile(self: *FileSink) !void {
        const dir = self.dir.?;
        const civil = format.Civil.of(core.now(.real));
        var stamp: [32]u8 = undefined;
        var name: [48]u8 = undefined;
        const base = std.fmt.bufPrint(&stamp, "{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}", .{ civil.year, civil.month, civil.day, civil.hour, civil.minute, civil.second }) catch unreachable;
        var number: usize = 1;
        while (true) : (number += 1) {
            const file_name = if (number == 1)
                std.fmt.bufPrint(&name, "{s}.log", .{base}) catch unreachable
            else
                std.fmt.bufPrint(&name, "{s}_{d}.log", .{ base, number }) catch unreachable;
            self.file = dir.createFile(io, file_name, .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => if (number < 1000) continue else return err,
                else => return err,
            };
            self.offset = 0;
            return;
        }
    }

    /// Deletes the directory's oldest run files until `keep` are left.
    fn prune(self: *FileSink) void {
        const dir = self.dir orelse return;
        while (true) {
            var count: usize = 0;
            var oldest: [64]u8 = undefined;
            var oldest_len: usize = 0;
            var iterator = dir.iterate();
            while (iterator.next(io) catch null) |entry| {
                if (entry.kind != .file or runOrder(entry.name) == null) continue;
                count += 1;
                if (oldest_len == 0 or olderRun(entry.name, oldest[0..oldest_len])) {
                    oldest_len = entry.name.len;
                    @memcpy(oldest[0..oldest_len], entry.name);
                }
            }
            if (count <= self.keep or oldest_len == 0) return;
            dir.deleteFile(io, oldest[0..oldest_len]) catch {
                core.stats.failures += 1;
                return;
            };
        }
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *FileSink = @alignCast(@fieldParentPtr("interface", w));
        var consumed: usize = 0;
        if (self.file == null) {
            for (data[0 .. data.len - 1]) |bytes| consumed += bytes.len;
            consumed += data[data.len - 1].len * splat;
            core.stats.dropped += consumed;
            return consumed;
        }
        self.write(w.buffer[0..w.end]);
        w.end = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.write(bytes);
            consumed += bytes.len;
        }
        for (0..splat) |_| self.write(data[data.len - 1]);
        return consumed + data[data.len - 1].len * splat;
    }

    /// Keeps `line` in the buffer, while there is no file, if all of it
    /// fits; otherwise counts it dropped.
    pub fn hold(self: *FileSink, line: []const u8) void {
        const w = &self.interface;
        if (line.len > w.buffer.len - w.end) {
            core.stats.dropped += line.len;
            return;
        }
        @memcpy(w.buffer[w.end..][0..line.len], line);
        w.end += line.len;
    }

    fn write(self: *FileSink, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const file = self.file orelse return;
        file.writePositionalAll(io, bytes, self.offset) catch {
            core.stats.failures += 1;
            return;
        };
        self.offset += bytes.len;
    }
};

/// How a run file is ordered among the others: by its date and time, then
/// its number; null for a name that is not a run file's.
fn runOrder(name: []const u8) ?struct { stamp: []const u8, number: u32 } {
    const stamp_len = "2026-10-30_14-03-22".len;
    if (name.len < stamp_len + ".log".len or !std.mem.endsWith(u8, name, ".log")) return null;
    const stamp = name[0..stamp_len];
    for (stamp, "0000-00-00_00-00-00") |c, pattern| {
        if (pattern == '0' and !std.ascii.isDigit(c)) return null;
        if (pattern != '0' and c != pattern) return null;
    }
    const rest = name[stamp_len .. name.len - ".log".len];
    if (rest.len == 0) return .{ .stamp = stamp, .number = 1 };
    if (rest[0] != '_') return null;
    const number = std.fmt.parseUnsigned(u32, rest[1..], 10) catch return null;
    return .{ .stamp = stamp, .number = number };
}

fn olderRun(a: []const u8, b: []const u8) bool {
    const first = runOrder(a).?;
    const second = runOrder(b).?;
    return switch (std.mem.order(u8, first.stamp, second.stamp)) {
        .lt => true,
        .gt => false,
        .eq => first.number < second.number,
    };
}

/// Recent lines, the oldest dropped whole to make room for the newest.
pub const Ring = struct {
    bytes: []u8,
    start: usize = 0,
    len: usize = 0,

    pub fn append(self: *Ring, data: []const u8) void {
        const capacity = self.bytes.len;
        if (capacity == 0) return;
        if (data.len >= capacity) {
            @memcpy(self.bytes, data[data.len - capacity ..]);
            self.start = 0;
            self.len = capacity;
            return;
        }
        while (self.len + data.len > capacity) self.dropLine();
        const end = (self.start + self.len) % capacity;
        const first = @min(data.len, capacity - end);
        @memcpy(self.bytes[end..][0..first], data[0..first]);
        @memcpy(self.bytes[0 .. data.len - first], data[first..]);
        self.len += data.len;
    }

    fn dropLine(self: *Ring) void {
        const capacity = self.bytes.len;
        const first = @min(self.len, capacity - self.start);
        const newline = if (std.mem.indexOfScalar(u8, self.bytes[self.start..][0..first], '\n')) |i|
            i
        else if (std.mem.indexOfScalar(u8, self.bytes[0 .. self.len - first], '\n')) |i|
            first + i
        else {
            self.start = 0;
            self.len = 0;
            return;
        };
        self.start = (self.start + newline + 1) % capacity;
        self.len -= newline + 1;
    }

    fn at(self: *const Ring, i: usize) u8 {
        return self.bytes[(self.start + i) % self.bytes.len];
    }

    /// Writes the last `max_lines` lines, oldest first.
    pub fn writeRecent(self: *const Ring, writer: *Writer, max_lines: usize) Writer.Error!void {
        var from = self.len;
        var lines: usize = 0;
        while (from > 0) : (from -= 1) {
            if (self.at(from - 1) != '\n') continue;
            if (lines == max_lines) break;
            lines += 1;
        }
        const begin = (self.start + from) % @max(self.bytes.len, 1);
        const count = self.len - from;
        const first = @min(count, self.bytes.len - begin);
        try writer.writeAll(self.bytes[begin..][0..first]);
        try writer.writeAll(self.bytes[0 .. count - first]);
    }
};
