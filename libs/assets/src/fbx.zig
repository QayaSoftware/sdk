//! FBX import through ufbx, into the same `Model` glTF files load into.
//! Scenes are turned to meters and glTF's axes, +Y up and right-handed, as
//! they are read.
//! Meshes, materials, textures and the node hierarchy load; skins,
//! animations, lights and cameras do not.
const std = @import("std");
const c = @import("ufbx");
const zmesh = @import("zmesh");
const model_file = @import("gltf.zig");

const Model = model_file.Model;
const Material = model_file.Material;
const Image = model_file.Image;
const ImageSource = model_file.ImageSource;
const TextureRef = model_file.TextureRef;
const FatVertex = model_file.FatVertex;

pub const Scene = c.ufbx_scene;

fn items(list: anytype) []@typeInfo(@TypeOf(list.data)).pointer.child {
    if (list.count == 0) return &.{};
    return list.data[0..list.count];
}

fn text(string: c.ufbx_string) []const u8 {
    if (string.length == 0) return "";
    return string.data[0..string.length];
}

fn typedId(object: anytype) u32 {
    return object.*.unnamed_0.element.typed_id;
}

fn vec2(value: c.ufbx_vec2) [2]f32 {
    const parts: *const [2]f64 = @ptrCast(&value);
    return .{ @floatCast(parts[0]), @floatCast(parts[1]) };
}

fn vec3(value: c.ufbx_vec3) [3]f32 {
    const parts: *const [3]f64 = @ptrCast(&value);
    return .{ @floatCast(parts[0]), @floatCast(parts[1]), @floatCast(parts[2]) };
}

fn vec4(value: c.ufbx_vec4) [4]f32 {
    const parts: *const [4]f64 = @ptrCast(&value);
    return .{ @floatCast(parts[0]), @floatCast(parts[1]), @floatCast(parts[2]), @floatCast(parts[3]) };
}

/// Reads and parses an FBX file. Free with `close`.
pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !*Scene {
    const bytes = try model_file.readFile(gpa, io, path);
    defer gpa.free(bytes);
    var options: c.ufbx_load_opts = .{};
    options.filename = .{ .data = path.ptr, .length = path.len };
    options.path_separator = '/';
    options.target_axes = c.ufbx_axes_right_handed_y_up;
    options.target_unit_meters = 1;
    options.space_conversion = c.UFBX_SPACE_CONVERSION_MODIFY_GEOMETRY;
    options.geometry_transform_handling = c.UFBX_GEOMETRY_TRANSFORM_HANDLING_MODIFY_GEOMETRY;
    options.inherit_mode_handling = c.UFBX_INHERIT_MODE_HANDLING_COMPENSATE;
    options.generate_missing_normals = true;
    options.ignore_animation = true;
    var failure: c.ufbx_error = .{};
    const scene = c.ufbx_load_memory(bytes.ptr, bytes.len, &options, &failure);
    if (scene == null) {
        std.log.warn("FBX: {s}: {s}", .{ path, text(failure.description) });
        return error.InvalidFbx;
    }
    return scene;
}

pub fn close(scene: *Scene) void {
    c.ufbx_free_scene(scene);
}

/// The file an FBX texture names, relative to the working directory: as
/// ufbx resolves it beside the FBX file, as written, or by its bare name
/// beside the FBX file or in a `textures` folder there. Null when none of
/// those exists.
fn findImage(arena: std.mem.Allocator, io: std.Io, model_path: []const u8, file: *const c.ufbx_texture_file) !?[]const u8 {
    const directory = std.fs.path.dirname(model_path) orelse ".";
    var tries: [5][]const u8 = undefined;
    var count: usize = 0;
    for ([_]c.ufbx_string{ file.filename, file.absolute_filename, file.relative_filename }) |string| {
        const name = text(string);
        if (name.len == 0) continue;
        const slashed = try arena.dupe(u8, name);
        std.mem.replaceScalar(u8, slashed, '\\', '/');
        tries[count] = slashed;
        count += 1;
    }
    const written = if (count > 0) tries[count - 1] else return null;
    const base = written[if (std.mem.lastIndexOfScalar(u8, written, '/')) |slash| slash + 1 else 0..];
    tries[count] = try std.fs.path.join(arena, &.{ directory, base });
    tries[count + 1] = try std.fs.path.join(arena, &.{ directory, "textures", base });
    count += 2;
    for (tries[0..count]) |candidate| {
        std.Io.Dir.cwd().access(io, candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

extern fn stbi_info_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, comp: *c_int) c_int;

/// Whether an image file's pixels carry alpha, from its header alone.
fn hasAlpha(header: []const u8) bool {
    if (header.len >= 128 and std.mem.eql(u8, header[0..4], "DDS ")) {
        const four_cc = header[84..88];
        if (std.mem.eql(u8, four_cc, "DXT3") or std.mem.eql(u8, four_cc, "DXT5")) return true;
        if (std.mem.eql(u8, four_cc, "DX10") and header.len >= 132) {
            const format = std.mem.readInt(u32, header[128..132], .little);
            return format >= 73 and format <= 78;
        }
        return false;
    }
    var width: c_int = 0;
    var height: c_int = 0;
    var components: c_int = 0;
    const length = std.math.cast(c_int, header.len) orelse return false;
    if (stbi_info_from_memory(header.ptr, length, &width, &height, &components) == 0) return false;
    return components == 2 or components == 4;
}

fn fileHasAlpha(io: std.Io, source: ImageSource) bool {
    switch (source) {
        .bytes => |bytes| return hasAlpha(bytes),
        .path => |path| {
            const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
            defer file.close(io);
            var header: [64 * 1024]u8 = undefined;
            var reader = file.readerStreaming(io, &.{});
            const read = reader.interface.readSliceShort(&header) catch return false;
            return hasAlpha(header[0..read]);
        },
        .gltf => return false,
    }
}

/// What `loadMaterials` knows of each texture file.
const Found = struct {
    source: ?ImageSource,
    /// Whether its pixels carry alpha; read only for base color textures.
    alpha: ?bool = null,
};

fn baseHasAlpha(io: std.Io, found: []Found, index: u32) bool {
    const into = &found[index];
    if (into.alpha == null) into.alpha = if (into.source) |source| fileHasAlpha(io, source) else false;
    return into.alpha.?;
}

fn textureRef(model: *Model, found: []const Found, texture: ?*c.ufbx_texture, srgb: bool) ?TextureRef {
    const source = texture orelse return null;
    if (!source.has_file or found[source.file_index].source == null) return null;
    const image = &model.images[source.file_index];
    if (srgb) image.srgb = true;
    image.uses += 1;
    var ref = TextureRef{ .image = source.file_index };
    ref.sampler.repeat_u = if (source.wrap_u == c.UFBX_WRAP_CLAMP) .clamp_to_edge else .repeat;
    ref.sampler.repeat_v = if (source.wrap_v == c.UFBX_WRAP_CLAMP) .clamp_to_edge else .repeat;
    if (source.has_uv_transform) {
        const matrix: *const [12]f64 = @ptrCast(&source.uv_to_texture);
        const scale = [2]f32{ @floatCast(matrix[0]), @floatCast(matrix[4]) };
        ref.transform = .{ .scale = scale, .offset = .{ @floatCast(matrix[9]), 1 - scale[1] - @as(f32, @floatCast(matrix[10])) } };
    }
    return ref;
}

fn map(material: *const c.ufbx_material, index: c_int) *const c.ufbx_material_map {
    return &material.pbr.unnamed_0.maps[@intCast(index)];
}

fn mapValue(value: *const c.ufbx_material_map) [4]f32 {
    return vec4(value.unnamed_0.value_vec4);
}

/// Gives the scene's materials and texture images to `model`, and where each
/// image is read from. Materials come from ufbx's PBR reading of each
/// shading model, plus one last default for meshes with none. A base color
/// texture with alpha makes its material alpha tested and two-sided, as FBX
/// files rarely say which surfaces are cut out.
pub fn loadMaterials(arena: std.mem.Allocator, io: std.Io, scene: *Scene, path: []const u8, model: *Model, options: model_file.LoadOptions) ![]ImageSource {
    const files = items(scene.texture_files);
    const found = try arena.alloc(Found, files.len);
    model.images = try arena.alloc(Image, files.len);
    const sources = try arena.alloc(ImageSource, files.len);
    for (files, found, model.images, sources) |*file, *into, *image, *source| {
        image.* = .{};
        into.* = .{ .source = null };
        if (file.content.size > 0) {
            into.source = .{ .bytes = @as([*]const u8, @ptrCast(file.content.data))[0..file.content.size] };
        } else if (try findImage(arena, io, path, file)) |image_path| {
            into.source = .{ .path = image_path };
            image.source_path = image_path;
            image.source_stamp = model_file.modelKey(io, image_path) catch 0;
        } else {
            std.log.warn("FBX: {s}: texture {s} not found", .{ path, text(file.relative_filename) });
        }
        source.* = into.source orelse .{ .bytes = &.{} };
    }

    const materials = items(scene.unnamed_0.unnamed_0.materials);
    model.materials = try arena.alloc(Material, materials.len + 1);
    model.materials[materials.len] = .{};
    for (materials, model.materials[0..materials.len]) |pointer, *material| {
        const source: *const c.ufbx_material = pointer;
        material.* = .{};
        const base = map(source, c.UFBX_MATERIAL_PBR_BASE_COLOR);
        const base_factor = map(source, c.UFBX_MATERIAL_PBR_BASE_FACTOR);
        material.base_color_texture = textureRef(model, found, base.texture, true);
        if (material.base_color_texture == null) {
            const color = mapValue(base);
            const factor: f32 = if (base_factor.has_value) @floatCast(base_factor.unnamed_0.value_real) else 1;
            material.base_color = .{ color[0] * factor, color[1] * factor, color[2] * factor, 1 };
        }
        const opacity = map(source, c.UFBX_MATERIAL_PBR_OPACITY);
        if (opacity.has_value and opacity.unnamed_0.value_real < 0.999) {
            material.base_color[3] = @floatCast(opacity.unnamed_0.value_real);
            material.alpha_mode = .blend;
        } else if (base.texture) |texture| if (texture.*.has_file and baseHasAlpha(io, found, texture.*.file_index)) {
            material.alpha_mode = .mask;
            material.double_sided = true;
        };

        material.normal_texture = textureRef(model, found, map(source, c.UFBX_MATERIAL_PBR_NORMAL_MAP).texture orelse source.fbx.unnamed_0.maps[@intCast(c.UFBX_MATERIAL_FBX_NORMAL_MAP)].texture, false);
        if (material.normal_texture) |ref| model.images[ref.image].normal_map = true;

        const specular = map(source, c.UFBX_MATERIAL_PBR_SPECULAR_COLOR).texture orelse map(source, c.UFBX_MATERIAL_PBR_SPECULAR_FACTOR).texture;
        if (options.packed_specular and specular != null) {
            material.metallic = 1;
            material.roughness = 1;
            material.metallic_roughness_texture = textureRef(model, found, specular, false);
        } else {
            const roughness = map(source, c.UFBX_MATERIAL_PBR_ROUGHNESS);
            const metalness = map(source, c.UFBX_MATERIAL_PBR_METALNESS);
            if (roughness.has_value) material.roughness = std.math.clamp(@as(f32, @floatCast(roughness.unnamed_0.value_real)), 0, 1);
            if (metalness.has_value) material.metallic = std.math.clamp(@as(f32, @floatCast(metalness.unnamed_0.value_real)), 0, 1);
            if (roughness.texture != null and roughness.texture == metalness.texture) {
                material.roughness = 1;
                material.metallic = 1;
                material.metallic_roughness_texture = textureRef(model, found, roughness.texture, false);
            }
            material.occlusion_texture = textureRef(model, found, map(source, c.UFBX_MATERIAL_PBR_AMBIENT_OCCLUSION).texture, false);
            if (material.occlusion_texture) |ref| model.images[ref.image].occlusion_uses += 1;
        }

        const emission = map(source, c.UFBX_MATERIAL_PBR_EMISSION_COLOR);
        const emission_factor = map(source, c.UFBX_MATERIAL_PBR_EMISSION_FACTOR);
        const strength: f32 = if (emission_factor.has_value) @floatCast(emission_factor.unnamed_0.value_real) else 1;
        material.emissive_texture = textureRef(model, found, emission.texture, true);
        const color = if (material.emissive_texture != null) [4]f32{ 1, 1, 1, 1 } else mapValue(emission);
        material.emissive = .{ color[0] * strength, color[1] * strength, color[2] * strength };

        if (source.features.unnamed_0.features[@intCast(c.UFBX_MATERIAL_FEATURE_DOUBLE_SIDED)].enabled) material.double_sided = true;
        if (source.features.unnamed_0.features[@intCast(c.UFBX_MATERIAL_FEATURE_UNLIT)].enabled) material.unlit = true;
    }
    for (model.images, sources) |image, *source| {
        if (image.uses == 0) source.* = .{ .bytes = &.{} };
    }
    return sources;
}

/// One drawn piece of a mesh: the faces of one material part, with the
/// material the node gives it.
const PartKey = struct { mesh: u32, part: u32, material: u32 };

/// Gives the scene's nodes, meshes and instances to `model`. A mesh part is
/// built once for every material it is drawn with.
pub fn loadGeometry(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, scene: *Scene, model: *Model, lods: model_file.LodOptions) !void {
    const nodes = items(scene.unnamed_0.unnamed_0.nodes);
    model.nodes = try arena.alloc(model_file.Node, nodes.len);
    for (nodes, model.nodes) |pointer, *node| {
        const source: *const c.ufbx_node = pointer;
        const matrix: *const [12]f64 = @ptrCast(&source.node_to_parent);
        var columns: [16]f32 = undefined;
        for (0..4) |column| {
            for (0..3) |row| columns[column * 4 + row] = @floatCast(matrix[column * 3 + row]);
            columns[column * 4 + 3] = if (column == 3) 1 else 0;
        }
        node.* = .{
            .name = try arena.dupe(u8, text(source.unnamed_0.element.name)),
            .parent = if (source.parent != null) typedId(source.parent) else null,
            .matrix = columns,
        };
    }

    const default_material: u32 = @intCast(model.materials.len - 1);
    var parts: std.AutoArrayHashMapUnmanaged(PartKey, PartJob) = .empty;
    defer parts.deinit(gpa);
    for (nodes) |pointer| {
        const node: *const c.ufbx_node = pointer;
        if (node.mesh == null) continue;
        const mesh: *c.ufbx_mesh = node.mesh;
        const node_materials = items(node.materials);
        for (items(mesh.material_parts)) |*part| {
            if (part.num_triangles == 0) continue;
            const material = if (part.index < node_materials.len) typedId(node_materials[part.index]) else default_material;
            const entry = try parts.getOrPut(gpa, .{ .mesh = typedId(mesh), .part = part.index, .material = material });
            if (!entry.found_existing) entry.value_ptr.* = .{ .gpa = gpa, .arena = arena, .mesh = mesh, .part = part, .material = material, .lods = lods };
        }
    }
    var group: std.Io.Group = .init;
    errdefer group.cancel(io);
    for (parts.values()) |*job| group.async(io, PartJob.run, .{job});
    try group.await(io);

    var meshes: std.ArrayList(model_file.Mesh) = .empty;
    const indices = try gpa.alloc(?u32, parts.count());
    defer gpa.free(indices);
    for (parts.values(), indices) |job, *index| {
        if (job.failure) |err| return err;
        index.* = null;
        const result = job.result orelse continue;
        index.* = @intCast(meshes.items.len);
        try meshes.append(arena, result);
    }
    var instances: std.ArrayList(model_file.Instance) = .empty;
    for (nodes) |pointer| {
        const node: *const c.ufbx_node = pointer;
        if (node.mesh == null) continue;
        const mesh: *c.ufbx_mesh = node.mesh;
        const node_materials = items(node.materials);
        for (items(mesh.material_parts)) |*part| {
            if (part.num_triangles == 0) continue;
            const material = if (part.index < node_materials.len) typedId(node_materials[part.index]) else default_material;
            const slot = parts.getIndex(.{ .mesh = typedId(mesh), .part = part.index, .material = material }).?;
            const index = indices[slot] orelse continue;
            try instances.append(arena, .{ .mesh = index, .node = typedId(node), .skin = null });
        }
    }
    model.meshes = meshes.items;
    model.instances = instances.items;
    if (model.meshes.len == 0 or model.instances.len == 0) return error.EmptyModel;
}

/// The triangles of one material part as a mesh, or null when it has none
/// with area.
/// One part of a mesh for `loadGeometry` to build on its own thread.
const PartJob = struct {
    gpa: std.mem.Allocator,
    /// Thread-safe, as `std.heap.ArenaAllocator` is over a thread-safe child.
    arena: std.mem.Allocator,
    mesh: *c.ufbx_mesh,
    part: *const c.ufbx_mesh_part,
    material: u32,
    lods: model_file.LodOptions,
    result: ?model_file.Mesh = null,
    failure: ?anyerror = null,

    fn run(self: *PartJob) std.Io.Cancelable!void {
        self.result = buildPart(self.gpa, self.arena, self.mesh, self.part, self.material, self.lods) catch |err| {
            self.failure = err;
            return;
        };
    }
};

fn buildPart(gpa: std.mem.Allocator, arena: std.mem.Allocator, mesh: *c.ufbx_mesh, part: *const c.ufbx_mesh_part, material: u32, lods: model_file.LodOptions) !?model_file.Mesh {
    const corners = try gpa.alloc(FatVertex, part.num_triangles * 3);
    defer gpa.free(corners);
    const triangle_corners = try gpa.alloc(u32, mesh.max_face_triangles * 3);
    defer gpa.free(triangle_corners);
    const uv_sets = items(mesh.uv_sets);
    const second_uv: ?*const c.ufbx_vertex_vec2 = if (uv_sets.len > 1) &uv_sets[1].vertex_uv else null;
    var count: usize = 0;
    for (items(part.face_indices)) |face_index| {
        const face = mesh.faces.data[face_index];
        const triangles = c.ufbx_triangulate_face(triangle_corners.ptr, triangle_corners.len, mesh, face);
        if (count + triangles * 3 > corners.len) return error.InvalidFbx;
        for (triangle_corners[0 .. triangles * 3]) |corner| {
            var fat = std.mem.zeroes(FatVertex);
            fat.vertex.position = vec3(attribute(mesh.vertex_position, corner));
            fat.vertex.normal = if (mesh.vertex_normal.exists) vec3(attribute(mesh.vertex_normal, corner)) else .{ 0, 0, 0 };
            fat.vertex.tangent = .{ 0, 0, 0, 1 };
            if (mesh.vertex_uv.exists) {
                const uv = vec2(attribute(mesh.vertex_uv, corner));
                fat.vertex.uv = .{ uv[0], 1 - uv[1] };
            }
            if (second_uv) |uvs| {
                const uv = vec2(attribute(uvs.*, corner));
                fat.vertex.uv1 = .{ uv[0], 1 - uv[1] };
            }
            fat.vertex.color = if (mesh.vertex_color.exists) model_file.packColor(&vec4(attribute(mesh.vertex_color, corner))) else 0xffffffff;
            fat.skin = .{ .joints = .{ 0, 0, 0, 0 }, .weights = .{ 1, 0, 0, 0 } };
            corners[count] = fat;
            count += 1;
        }
    }
    if (count < 3) return null;

    const remap = try gpa.alloc(u32, count);
    defer gpa.free(remap);
    const unique = zmesh.opt.generateVertexRemap(remap, null, FatVertex, corners[0..count]);
    const vertices = try gpa.alloc(FatVertex, unique);
    defer gpa.free(vertices);
    zmesh.opt.remapVertexBuffer(FatVertex, vertices, corners[0..count], remap);
    var result = try model_file.finishMesh(gpa, arena, vertices, remap, false, material, mesh.vertex_normal.exists, false, null, lods);
    try model_file.coarseFirst(gpa, &result);
    return result;
}

fn attribute(values: anytype, corner: u32) @typeInfo(@TypeOf(values.values.data)).pointer.child {
    return values.values.data[values.indices.data[corner]];
}

test "an ASCII FBX quad in centimeters loads in meters with its material" {
    const io = std.testing.io;
    model_file.acquireLibraries(io);
    defer model_file.releaseLibraries(io);
    const path = ".zig-cache/limn-test-quad.fbx";
    try model_file.writeTestFile(io, path,
        \\; FBX 7.4.0 project file
        \\FBXHeaderExtension:  {
        \\    FBXHeaderVersion: 1003
        \\    FBXVersion: 7400
        \\}
        \\GlobalSettings:  {
        \\    Version: 1000
        \\    Properties70:  {
        \\        P: "UpAxis", "int", "Integer", "",1
        \\        P: "UpAxisSign", "int", "Integer", "",1
        \\        P: "FrontAxis", "int", "Integer", "",2
        \\        P: "FrontAxisSign", "int", "Integer", "",1
        \\        P: "CoordAxis", "int", "Integer", "",0
        \\        P: "CoordAxisSign", "int", "Integer", "",1
        \\        P: "UnitScaleFactor", "double", "Number", "",1
        \\    }
        \\}
        \\Objects:  {
        \\    Geometry: 1000, "Geometry::Quad", "Mesh" {
        \\        Vertices: *12 {
        \\            a: 0,0,0,100,0,0,100,0,-100,0,0,-100
        \\        }
        \\        PolygonVertexIndex: *4 {
        \\            a: 0,1,2,-4
        \\        }
        \\        GeometryVersion: 124
        \\    }
        \\    Model: 2000, "Model::Quad", "Mesh" {
        \\        Version: 232
        \\        Properties70:  {
        \\            P: "Lcl Translation", "Lcl Translation", "", "A",0,200,0
        \\        }
        \\    }
        \\    Material: 3000, "Material::Glow", "" {
        \\        Version: 102
        \\        ShadingModel: "phong"
        \\        Properties70:  {
        \\            P: "DiffuseColor", "Color", "", "A",0.5,0.25,1
        \\            P: "EmissiveColor", "Color", "", "A",1,0,0
        \\            P: "EmissiveFactor", "Number", "", "A",2
        \\        }
        \\    }
        \\}
        \\Connections:  {
        \\    C: "OO",2000,0
        \\    C: "OO",1000,2000
        \\    C: "OO",3000,2000
        \\}
        \\
    );
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var model = try model_file.load(std.testing.allocator, io, path, .{});
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 1), model.meshes.len);
    try std.testing.expectEqual(@as(usize, 1), model.instances.len);
    const mesh = model.meshes[0];
    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.len);
    try std.testing.expectEqual(@as(u32, 6), mesh.lod0_index_count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5 * std.math.sqrt2), mesh.bounds_radius, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1), mesh.vertices[0].unpackNormal()[1], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 2), model.nodes[model.instances[0].node].matrix.?[13], 1e-4);
    const material = model.materials[mesh.material];
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), material.base_color[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 2), material.emissive[0], 1e-4);
}
