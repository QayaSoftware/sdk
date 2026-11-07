//! Opacity micromaps baked from alpha textures: for each triangle of an
//! alpha tested mesh, which of its micro-triangles are see-through, solid or
//! both, so that ray traversal settles most hits without a shader. Triangles
//! are split into 4^`subdivision` micro-triangles numbered along the
//! space-filling curve of `VK_EXT_opacity_micromap`.
const std = @import("std");

/// What a micro-triangle, or a whole triangle, is. The values are those
/// micromap data stores.
pub const State = enum(u2) {
    transparent = 0,
    @"opaque" = 1,
    /// Partly cut out, mostly see-through: left to the shader.
    unknown_transparent = 2,
    /// Partly cut out, mostly solid: left to the shader.
    unknown_opaque = 3,
};

/// A baked micromap for every triangle of a mesh's full-detail level.
pub const Map = struct {
    subdivision: u8,
    /// Per triangle, a `State` for the whole triangle, or `micro` for one
    /// whose micro-triangles are in `data`.
    whole: []u8,
    /// `triangleBytes` for each triangle marked `micro`, in triangle order:
    /// two bits per micro-triangle, low bits first.
    data: []u8,

    pub const micro: u8 = 0xff;

    pub fn triangleBytes(subdivision: u8) usize {
        return ((@as(usize, 1) << @intCast(2 * subdivision)) * 2 + 7) / 8;
    }
};

/// Deepest subdivision `bake` uses: 256 micro-triangles, 64 bytes a triangle.
pub const max_subdivision = 4;

/// The barycentric coordinates (weights of the second and third corners) of
/// the corners of micro-triangle `index` of 4^`level`, as
/// `VK_EXT_opacity_micromap` numbers them.
pub fn microTriangle(index: u32, level: u5) [3][2]f32 {
    if (level == 0) return .{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } };
    const b0 = extractEvenBits(index);
    const b1 = extractEvenBits(index >> 1);
    const fx = prefixEor(b0);
    const fy = prefixEor(b0 & ~b1);
    const t = fy ^ b1;
    const mask = (@as(u32, 1) << level) - 1;
    var u = ((fx & ~t) | (b0 & ~t) | (~b0 & ~fx & t)) & mask;
    var v = (fy ^ b0) & mask;
    const w = ((~fx & ~t) | (b0 & ~t) | (~b0 & fx & t)) & mask;
    const upright = ((u ^ v ^ w) & 1) != 0;
    if (!upright) {
        u += 1;
        v += 1;
    }
    const scale = 1 / @as(f32, @floatFromInt(@as(u32, 1) << level));
    const step: f32 = if (upright) scale else -scale;
    const base = [2]f32{ @as(f32, @floatFromInt(u)) * scale, @as(f32, @floatFromInt(v)) * scale };
    return .{ base, .{ base[0] + step, base[1] }, .{ base[0], base[1] + step } };
}

fn extractEvenBits(value: u32) u32 {
    var x = value & 0x55555555;
    x = (x | (x >> 1)) & 0x33333333;
    x = (x | (x >> 2)) & 0x0f0f0f0f;
    x = (x | (x >> 4)) & 0x00ff00ff;
    x = (x | (x >> 8)) & 0x0000ffff;
    return x;
}

fn prefixEor(value: u32) u32 {
    var x = value;
    x ^= (x >> 1) & 0x7fff;
    x ^= (x >> 2) & 0x3fff;
    x ^= (x >> 4) & 0x0fff;
    x ^= (x >> 8) & 0x00ff;
    return x;
}

/// How texture coordinates outside 0..1 are read, as the material's sampler
/// does.
pub const Address = enum { repeat, mirrored_repeat, clamp_to_edge };

/// A texture's alpha, one byte per texel row after row, as the material's
/// sampler reads it.
pub const Texture = struct {
    width: u32,
    height: u32,
    alpha: []const u8,
    address: [2]Address,

    /// Bilinear alpha, 0 to 1, at `at` in texture coordinates.
    pub fn sample(self: Texture, at: [2]f32) f32 {
        const fx = at[0] * @as(f32, @floatFromInt(self.width)) - 0.5;
        const fy = at[1] * @as(f32, @floatFromInt(self.height)) - 0.5;
        const x: i64 = @intFromFloat(@floor(fx));
        const y: i64 = @intFromFloat(@floor(fy));
        const tx = fx - @floor(fx);
        const ty = fy - @floor(fy);
        var sum: f32 = 0;
        for (0..2) |dy| for (0..2) |dx| {
            const texel = self.alpha[wrap(y + @as(i64, @intCast(dy)), self.height, self.address[1]) * self.width + wrap(x + @as(i64, @intCast(dx)), self.width, self.address[0])];
            const weight = (if (dx == 0) 1 - tx else tx) * (if (dy == 0) 1 - ty else ty);
            sum += weight * @as(f32, @floatFromInt(texel));
        };
        return sum / 255;
    }
};

/// The alpha of a texture as the least and greatest of each 2x2 block, level
/// after level, for telling at once whether a region is all solid, all cut
/// out, or both.
pub const Pyramid = struct {
    widths: [max_levels]u32,
    heights: [max_levels]u32,
    /// Per level, the least and greatest alpha of each texel.
    least: [max_levels][]u8,
    greatest: [max_levels][]u8,
    levels: u32,
    address: [2]Address,

    const max_levels = 16;

    /// From `alpha`, one byte per texel, row after row; copied.
    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32, alpha: []const u8, address: [2]Address) !Pyramid {
        var self: Pyramid = .{ .widths = undefined, .heights = undefined, .least = undefined, .greatest = undefined, .levels = 0, .address = address };
        errdefer self.deinit(gpa);
        var w = width;
        var h = height;
        while (true) {
            const level = self.levels;
            self.widths[level] = w;
            self.heights[level] = h;
            self.least[level] = try gpa.alloc(u8, @as(usize, w) * h);
            self.levels += 1;
            self.greatest[level] = gpa.alloc(u8, @as(usize, w) * h) catch |err| {
                gpa.free(self.least[level]);
                self.levels -= 1;
                return err;
            };
            if (level == 0) {
                @memcpy(self.least[0], alpha[0..self.least[0].len]);
                @memcpy(self.greatest[0], alpha[0..self.greatest[0].len]);
            } else {
                const pw = self.widths[level - 1];
                const ph = self.heights[level - 1];
                for (0..h) |y| for (0..w) |x| {
                    var low: u8 = 255;
                    var high: u8 = 0;
                    for (0..2) |dy| for (0..2) |dx| {
                        const sx = @min(x * 2 + dx, pw - 1);
                        const sy = @min(y * 2 + dy, ph - 1);
                        low = @min(low, self.least[level - 1][sy * pw + sx]);
                        high = @max(high, self.greatest[level - 1][sy * pw + sx]);
                    };
                    self.least[level][y * w + x] = low;
                    self.greatest[level][y * w + x] = high;
                };
            }
            if ((w == 1 and h == 1) or self.levels == max_levels) break;
            w = (w + 1) / 2;
            h = (h + 1) / 2;
        }
        return self;
    }

    pub fn deinit(self: *Pyramid, gpa: std.mem.Allocator) void {
        for (self.least[0..self.levels], self.greatest[0..self.levels]) |least, greatest| {
            gpa.free(least);
            gpa.free(greatest);
        }
        self.levels = 0;
    }

    /// The least and greatest alpha, 0 to 1, that bilinear sampling can
    /// return anywhere in the box from `low` to `high` in texture
    /// coordinates.
    pub fn range(self: *const Pyramid, low: [2]f32, high: [2]f32) [2]f32 {
        const w0 = self.widths[0];
        const h0 = self.heights[0];
        const x0: i64 = @intFromFloat(@floor(low[0] * @as(f32, @floatFromInt(w0)) - 0.5));
        const y0: i64 = @intFromFloat(@floor(low[1] * @as(f32, @floatFromInt(h0)) - 0.5));
        const x1: i64 = @intFromFloat(@floor(high[0] * @as(f32, @floatFromInt(w0)) + 0.5));
        const y1: i64 = @intFromFloat(@floor(high[1] * @as(f32, @floatFromInt(h0)) + 0.5));
        const top = self.levels - 1;
        const whole_texture = [2]f32{ @as(f32, @floatFromInt(self.least[top][0])) / 255, @as(f32, @floatFromInt(self.greatest[top][0])) / 255 };
        if (x1 - x0 + 1 >= w0 or y1 - y0 + 1 >= h0) {
            const clamped = self.address[0] == .clamp_to_edge and self.address[1] == .clamp_to_edge;
            if (!clamped) return whole_texture;
        }
        var level: u5 = 0;
        while (level < top and ((x1 >> level) - (x0 >> level) > 8 or (y1 >> level) - (y0 >> level) > 8)) level += 1;
        const crosses = x0 < 0 or y0 < 0 or x1 >= w0 or y1 >= h0;
        const aligned = (w0 & ((@as(u32, 1) << level) - 1)) == 0 and (h0 & ((@as(u32, 1) << level) - 1)) == 0;
        if (crosses and !aligned and self.address[0] != .clamp_to_edge) return whole_texture;
        const w = self.widths[level];
        const h = self.heights[level];
        var least: u8 = 255;
        var greatest: u8 = 0;
        var y = y0 >> level;
        while (y <= y1 >> level) : (y += 1) {
            const row = wrap(y, h, self.address[1]);
            var x = x0 >> level;
            while (x <= x1 >> level) : (x += 1) {
                const at = row * w + wrap(x, w, self.address[0]);
                least = @min(least, self.least[level][at]);
                greatest = @max(greatest, self.greatest[level][at]);
            }
        }
        return .{ @as(f32, @floatFromInt(least)) / 255, @as(f32, @floatFromInt(greatest)) / 255 };
    }
};

/// Which texels of a texture are solid at one alpha cutoff, as a summed-area
/// table: how many solid texels any box holds is four lookups. Bilinear
/// sampling between texels that are all solid stays solid, and between
/// texels all cut out stays cut out, so a box of either kind settles every
/// sample in it.
pub const Coverage = struct {
    width: u32,
    height: u32,
    address: [2]Address,
    /// `sums[(y + 1) * (width + 1) + x + 1]`: solid texels with column at
    /// most `x` and row at most `y`.
    sums: []u32,

    /// Texels of `alpha`, one byte each row after row, are solid at
    /// `threshold` and above.
    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32, alpha: []const u8, threshold: u8, address: [2]Address) !Coverage {
        const stride = @as(usize, width) + 1;
        const sums = try gpa.alloc(u32, stride * (@as(usize, height) + 1));
        @memset(sums[0..stride], 0);
        for (0..height) |y| {
            var row: u32 = 0;
            sums[(y + 1) * stride] = 0;
            for (0..width) |x| {
                row += @intFromBool(alpha[y * width + x] >= threshold);
                sums[(y + 1) * stride + x + 1] = sums[y * stride + x + 1] + row;
            }
        }
        return .{ .width = width, .height = height, .address = address, .sums = sums };
    }

    pub fn deinit(self: *Coverage, gpa: std.mem.Allocator) void {
        gpa.free(self.sums);
    }

    /// Whether bilinear samples anywhere in the box from `low` to `high`
    /// in texture coordinates are all solid, all cut out, or both.
    pub fn range(self: *const Coverage, low: [2]f32, high: [2]f32) ?bool {
        var columns: [2][2]u32 = undefined;
        var rows: [2][2]u32 = undefined;
        const column_count = spans(&columns, @intFromFloat(@floor(low[0] * @as(f32, @floatFromInt(self.width)) - 0.5)), @intFromFloat(@floor(high[0] * @as(f32, @floatFromInt(self.width)) + 0.5)), self.width, self.address[0]);
        const row_count = spans(&rows, @intFromFloat(@floor(low[1] * @as(f32, @floatFromInt(self.height)) - 0.5)), @intFromFloat(@floor(high[1] * @as(f32, @floatFromInt(self.height)) + 0.5)), self.height, self.address[1]);
        var solid: u64 = 0;
        var total: u64 = 0;
        for (rows[0..row_count]) |row| for (columns[0..column_count]) |column| {
            solid += self.count(column[0], row[0], column[1], row[1]);
            total += @as(u64, column[1] - column[0] + 1) * (row[1] - row[0] + 1);
        };
        if (solid == total) return true;
        if (solid == 0) return false;
        return null;
    }

    fn count(self: *const Coverage, x0: u32, y0: u32, x1: u32, y1: u32) u64 {
        const stride = @as(usize, self.width) + 1;
        const a = self.sums[@as(usize, y1 + 1) * stride + x1 + 1];
        const b = self.sums[@as(usize, y0) * stride + x1 + 1];
        const c = self.sums[@as(usize, y1 + 1) * stride + x0];
        const d = self.sums[@as(usize, y0) * stride + x0];
        return @as(u64, a) + d - b - c;
    }
};

/// The texels from `first` to `last` of a texture `size` texels across, as at
/// most two runs within it; returns how many.
fn spans(out: *[2][2]u32, first: i64, last: i64, size: u32, address: Address) usize {
    const n: i64 = size;
    switch (address) {
        .clamp_to_edge => {
            out[0] = .{ @intCast(std.math.clamp(first, 0, n - 1)), @intCast(std.math.clamp(last, 0, n - 1)) };
            return 1;
        },
        .repeat => {
            if (last - first + 1 >= n) {
                out[0] = .{ 0, size - 1 };
                return 1;
            }
            const start = @mod(first, n);
            const end = start + (last - first);
            if (end < n) {
                out[0] = .{ @intCast(start), @intCast(end) };
                return 1;
            }
            out[0] = .{ @intCast(start), size - 1 };
            out[1] = .{ 0, @intCast(end - n) };
            return 2;
        },
        .mirrored_repeat => {
            const period = @divFloor(first, n);
            if (@divFloor(last, n) != period) {
                out[0] = .{ 0, size - 1 };
                return 1;
            }
            const a = wrap(first, size, .mirrored_repeat);
            const b = wrap(last, size, .mirrored_repeat);
            out[0] = .{ @intCast(@min(a, b)), @intCast(@max(a, b)) };
            return 1;
        },
    }
}

fn wrap(coordinate: i64, size: u32, address: Address) usize {
    const n: i64 = size;
    return @intCast(switch (address) {
        .repeat => @mod(coordinate, n),
        .clamp_to_edge => std.math.clamp(coordinate, 0, n - 1),
        .mirrored_repeat => blk: {
            const period = @mod(coordinate, 2 * n);
            break :blk if (period < n) period else 2 * n - 1 - period;
        },
    });
}

/// What `bake` reads of one mesh.
pub const Input = struct {
    /// The full-detail level's triangles, three indices each.
    indices: []const u32,
    /// Texture coordinates of each vertex, with the material's transform
    /// applied.
    uvs: []const [2]f32,
    /// Alpha of each vertex color, or empty for none.
    vertex_alpha: []const f32 = &.{},
    /// The material's base color alpha factor and alpha cutoff.
    factor: f32 = 1,
    cutoff: f32 = 0.5,
    /// The base color texture's alpha.
    texture: Texture,
    /// Settles whole regions at once where `factor` is 1 and there is no
    /// `vertex_alpha`; made at `cutoff`.
    coverage: ?*const Coverage = null,
    /// Settles whole regions at once otherwise.
    pyramid: ?*const Pyramid = null,
    subdivision: u8 = max_subdivision,
};

/// Bakes `input` into a micromap allocated from `allocator`. Null when no
/// triangle is cut out at all, which needs no micromap.
pub fn bake(allocator: std.mem.Allocator, input: Input) !?Map {
    const triangle_count = input.indices.len / 3;
    const whole = try allocator.alloc(u8, triangle_count);
    errdefer allocator.free(whole);
    const level: u5 = @intCast(input.subdivision);
    const bytes = Map.triangleBytes(input.subdivision);
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(allocator);
    var states: [1 << (2 * max_subdivision)]State = undefined;
    var any_cut = false;
    for (whole, 0..) |*out, triangle| {
        const corners = input.indices[triangle * 3 ..][0..3];
        const uv = [3][2]f32{ input.uvs[corners[0]], input.uvs[corners[1]], input.uvs[corners[2]] };
        const alpha = if (input.vertex_alpha.len == 0) [3]f32{ 1, 1, 1 } else [3]f32{ input.vertex_alpha[corners[0]], input.vertex_alpha[corners[1]], input.vertex_alpha[corners[2]] };
        const triangle_state = classifyTree(input, uv, alpha, 0, 0, level, &states);
        if (triangle_state) |state| {
            out.* = @backingInt(state);
            if (state != .@"opaque") any_cut = true;
            continue;
        }
        any_cut = true;
        out.* = Map.micro;
        const start = data.items.len;
        try data.appendNTimes(allocator, 0, bytes);
        const packed_states = data.items[start..][0..bytes];
        for (states[0 .. @as(usize, 1) << (2 * @as(u6, level))], 0..) |state, micro| {
            packed_states[micro / 4] |= @as(u8, @backingInt(state)) << @intCast((micro % 4) * 2);
        }
    }
    if (!any_cut) {
        allocator.free(whole);
        data.deinit(allocator);
        return null;
    }
    return .{ .subdivision = input.subdivision, .whole = whole, .data = try data.toOwnedSlice(allocator) };
}

/// Classifies micro-triangle `index` of 4^`level` and, where it is neither
/// all solid nor all cut out, its four children down to `target`, writing
/// the states of the micro-triangles of 4^`target` it covers into `states`.
/// Returns its state when one state covers all of it.
fn classifyTree(input: Input, uv: [3][2]f32, alpha: [3]f32, index: u32, level: u5, target: u5, states: []State) ?State {
    const bary = microTriangle(index, level);
    var corner_uv: [3][2]f32 = undefined;
    var corner_alpha: [3]f32 = undefined;
    for (bary, &corner_uv, &corner_alpha) |b, *at, *weight| {
        const w0 = 1 - b[0] - b[1];
        at.* = .{ w0 * uv[0][0] + b[0] * uv[1][0] + b[1] * uv[2][0], w0 * uv[0][1] + b[0] * uv[1][1] + b[1] * uv[2][1] };
        weight.* = w0 * alpha[0] + b[0] * alpha[1] + b[1] * alpha[2];
    }
    const low = [2]f32{ @min(corner_uv[0][0], corner_uv[1][0], corner_uv[2][0]), @min(corner_uv[0][1], corner_uv[1][1], corner_uv[2][1]) };
    const high = [2]f32{ @max(corner_uv[0][0], corner_uv[1][0], corner_uv[2][0]), @max(corner_uv[0][1], corner_uv[1][1], corner_uv[2][1]) };
    const scale_low = input.factor * @min(corner_alpha[0], corner_alpha[1], corner_alpha[2]);
    const scale_high = input.factor * @max(corner_alpha[0], corner_alpha[1], corner_alpha[2]);
    const covered = @as(usize, 1) << (2 * @as(u6, target - level));
    const first = @as(usize, index) * covered;
    const uniform: ?State = if (input.coverage != null and scale_low == 1 and scale_high == 1) blk: {
        const solid = input.coverage.?.range(low, high) orelse break :blk null;
        break :blk if (solid) .@"opaque" else .transparent;
    } else if (input.pyramid) |pyramid| blk: {
        const texture = pyramid.range(low, high);
        if (texture[0] * scale_low >= input.cutoff) break :blk .@"opaque";
        if (texture[1] * scale_high < input.cutoff) break :blk .transparent;
        break :blk null;
    } else null;
    if (uniform) |state| {
        @memset(states[first..][0..covered], state);
        return state;
    }
    if (level == target) {
        const center = [2]f32{ (corner_uv[0][0] + corner_uv[1][0] + corner_uv[2][0]) / 3, (corner_uv[0][1] + corner_uv[1][1] + corner_uv[2][1]) / 3 };
        const at_center = input.texture.sample(center) * input.factor * (corner_alpha[0] + corner_alpha[1] + corner_alpha[2]) / 3;
        states[first] = if (at_center >= input.cutoff) .unknown_opaque else .unknown_transparent;
        return null;
    }
    var children: [4]?State = undefined;
    for (&children, 0..) |*child, k| child.* = classifyTree(input, uv, alpha, index * 4 + @as(u32, @intCast(k)), level + 1, target, states);
    if (children[0] != null and children[0] == children[1] and children[0] == children[2] and children[0] == children[3]) return children[0];
    return null;
}

test "micro-triangles of a level tile their parent, in curve order" {
    for (1..5) |level_value| {
        const level: u5 = @intCast(level_value);
        var area: f32 = 0;
        for (0..@as(u32, 1) << (2 * level)) |index| {
            const child = microTriangle(@intCast(index), level);
            const parent = microTriangle(@intCast(index >> 2), level - 1);
            const centroid = [2]f32{ (child[0][0] + child[1][0] + child[2][0]) / 3, (child[0][1] + child[1][1] + child[2][1]) / 3 };
            try std.testing.expect(inside(parent, centroid));
            area += @abs((child[1][0] - child[0][0]) * (child[2][1] - child[0][1]) - (child[2][0] - child[0][0]) * (child[1][1] - child[0][1])) / 2;
        }
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), area, 1e-5);
    }
}

fn inside(triangle: [3][2]f32, point: [2]f32) bool {
    var sign: ?bool = null;
    for (0..3) |edge| {
        const a = triangle[edge];
        const b = triangle[(edge + 1) % 3];
        const cross = (b[0] - a[0]) * (point[1] - a[1]) - (b[1] - a[1]) * (point[0] - a[0]);
        if (@abs(cross) < 1e-7) continue;
        if (sign) |known| {
            if (known != (cross > 0)) return false;
        } else sign = cross > 0;
    }
    return true;
}

test "a half cut out texture bakes to solid, see-through and mixed micro-triangles" {
    const gpa = std.testing.allocator;
    var alpha: [64 * 64]u8 = undefined;
    for (0..64) |y| for (0..64) |x| {
        alpha[y * 64 + x] = if (x < 32) 255 else 0;
    };
    const address = [2]Address{ .clamp_to_edge, .clamp_to_edge };
    var coverage = try Coverage.init(gpa, 64, 64, &alpha, 128, address);
    defer coverage.deinit(gpa);
    var pyramid = try Pyramid.init(gpa, 64, 64, &alpha, address);
    defer pyramid.deinit(gpa);
    const texture: Texture = .{ .width = 64, .height = 64, .alpha = &alpha, .address = address };
    const indices = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    const uvs = [_][2]f32{ .{ 0, 0 }, .{ 0.4, 0 }, .{ 0, 0.4 }, .{ 0.6, 0 }, .{ 1, 0 }, .{ 0.6, 0.4 }, .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } };
    for ([_]bool{ true, false }) |with_coverage| {
        const map = (try bake(gpa, .{
            .indices = &indices,
            .uvs = &uvs,
            .texture = texture,
            .coverage = if (with_coverage) &coverage else null,
            .pyramid = if (with_coverage) null else &pyramid,
        })).?;
        defer gpa.free(map.whole);
        defer gpa.free(map.data);
        try std.testing.expectEqual(@backingInt(State.@"opaque"), map.whole[0]);
        try std.testing.expectEqual(@backingInt(State.transparent), map.whole[1]);
        try std.testing.expectEqual(Map.micro, map.whole[2]);
        try std.testing.expectEqual(Map.triangleBytes(max_subdivision), map.data.len);
        var counts: [4]u32 = @splat(0);
        for (0..256) |micro| counts[(map.data[micro / 4] >> @intCast((micro % 4) * 2)) & 3] += 1;
        try std.testing.expect(counts[@backingInt(State.@"opaque")] > 128);
        try std.testing.expect(counts[@backingInt(State.transparent)] > 32);
        try std.testing.expect(counts[@backingInt(State.unknown_opaque)] + counts[@backingInt(State.unknown_transparent)] < 64);
    }
}
