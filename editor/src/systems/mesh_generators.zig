//! Procedural mesh generators used by editor tools.
//!
//! Provides small helpers to synthesize engine scene data (meshes/materials) for previewing or
//! authoring workflows (e.g. generating a flat terrain grid).
const std = @import("std");
const engine = @import("cardinal_engine");

const memory = engine.memory;
const scene = engine.scene;

const AllocBundle = struct {
    assets_alloc: *memory.CardinalAllocator,

    meshes_ptr: ?*anyopaque = null,
    materials_ptr: ?*anyopaque = null,
    vertices_ptr: ?*anyopaque = null,
    indices_ptr: ?*anyopaque = null,
    bottom_vertices_ptr: ?*anyopaque = null,
    bottom_indices_ptr: ?*anyopaque = null,
    wall_vertices_ptr: ?*anyopaque = null,
    wall_indices_ptr: ?*anyopaque = null,

    fn deinit(self: *AllocBundle) void {
        if (self.wall_indices_ptr) |p| memory.cardinal_free(self.assets_alloc, p);
        if (self.wall_vertices_ptr) |p| memory.cardinal_free(self.assets_alloc, p);
        if (self.bottom_indices_ptr) |p| memory.cardinal_free(self.assets_alloc, p);
        if (self.bottom_vertices_ptr) |p| memory.cardinal_free(self.assets_alloc, p);
        if (self.indices_ptr) |p| memory.cardinal_free(self.assets_alloc, p);
        if (self.vertices_ptr) |p| memory.cardinal_free(self.assets_alloc, p);
        if (self.materials_ptr) |p| memory.cardinal_free(self.assets_alloc, p);
        if (self.meshes_ptr) |p| memory.cardinal_free(self.assets_alloc, p);
        self.* = .{ .assets_alloc = self.assets_alloc };
    }
};

fn emit_wall_quad(wall_vertices: [*]scene.CardinalVertex, wall_indices: [*]u32, wall_v: *u32, wall_i: *u32, v0: scene.CardinalVertex, v1: scene.CardinalVertex, nx: f32, nz: f32, flip: bool, thickness: f32) void {
    const top0 = v0;
    const top1 = v1;
    var bot0 = v0;
    var bot1 = v1;
    bot0.py = v0.py - thickness;
    bot1.py = v1.py - thickness;

    var t0 = top0;
    var t1 = top1;
    t0.nx = nx;
    t0.ny = 0.0;
    t0.nz = nz;
    t1.nx = nx;
    t1.ny = 0.0;
    t1.nz = nz;
    bot0.nx = nx;
    bot0.ny = 0.0;
    bot0.nz = nz;
    bot1.nx = nx;
    bot1.ny = 0.0;
    bot1.nz = nz;

    const base_v = wall_v.*;
    wall_vertices[base_v + 0] = t0;
    wall_vertices[base_v + 1] = t1;
    wall_vertices[base_v + 2] = bot1;
    wall_vertices[base_v + 3] = bot0;

    const base_i = wall_i.*;
    if (!flip) {
        wall_indices[base_i + 0] = base_v + 0;
        wall_indices[base_i + 1] = base_v + 1;
        wall_indices[base_i + 2] = base_v + 2;
        wall_indices[base_i + 3] = base_v + 0;
        wall_indices[base_i + 4] = base_v + 2;
        wall_indices[base_i + 5] = base_v + 3;
    } else {
        wall_indices[base_i + 0] = base_v + 0;
        wall_indices[base_i + 1] = base_v + 2;
        wall_indices[base_i + 2] = base_v + 1;
        wall_indices[base_i + 3] = base_v + 0;
        wall_indices[base_i + 4] = base_v + 3;
        wall_indices[base_i + 5] = base_v + 2;
    }

    wall_v.* += 4;
    wall_i.* += 6;
}

/// Builds a flat grid mesh (and optional "thickness" walls) as a standalone scene.
pub fn build_flat_terrain_scene(grid_resolution: u32, world_size: f32, thickness: f32) ?scene.CardinalScene {
    const assets_alloc = memory.cardinal_get_allocator_for_category(.ASSETS);

    var out = std.mem.zeroes(scene.CardinalScene);

    const grid = if (grid_resolution < 2) 2 else grid_resolution;
    const verts_per_side: u32 = grid + 1;
    const vertex_count: u32 = verts_per_side * verts_per_side;
    const index_count: u32 = grid * grid * 6;

    if (thickness <= 0.01) {
        var allocs = AllocBundle{ .assets_alloc = assets_alloc };
        allocs.meshes_ptr = memory.cardinal_calloc(assets_alloc, 1, @sizeOf(scene.CardinalMesh)) orelse return null;
        errdefer allocs.deinit();
        allocs.materials_ptr = memory.cardinal_calloc(assets_alloc, 1, @sizeOf(scene.CardinalMaterial)) orelse return null;
        allocs.vertices_ptr = memory.cardinal_alloc(assets_alloc, @as(usize, vertex_count) * @sizeOf(scene.CardinalVertex)) orelse return null;
        allocs.indices_ptr = memory.cardinal_alloc(assets_alloc, @as(usize, index_count) * @sizeOf(u32)) orelse return null;

        const meshes: [*]scene.CardinalMesh = @ptrCast(@alignCast(allocs.meshes_ptr));
        const materials: [*]scene.CardinalMaterial = @ptrCast(@alignCast(allocs.materials_ptr));
        const vertices: [*]scene.CardinalVertex = @ptrCast(@alignCast(allocs.vertices_ptr));
        const indices: [*]u32 = @ptrCast(@alignCast(allocs.indices_ptr));

        const half = world_size * 0.5;

        var z: u32 = 0;
        while (z < verts_per_side) : (z += 1) {
            var x: u32 = 0;
            while (x < verts_per_side) : (x += 1) {
                const idx: u32 = z * verts_per_side + x;
                const fx: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(grid));
                const fz: f32 = @as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(grid));

                vertices[idx] = std.mem.zeroes(scene.CardinalVertex);
                vertices[idx].px = fx * world_size - half;
                vertices[idx].py = 0.0;
                vertices[idx].pz = fz * world_size - half;
                vertices[idx].nx = 0.0;
                vertices[idx].ny = 1.0;
                vertices[idx].nz = 0.0;
                vertices[idx].u = fx;
                vertices[idx].v = fz;
                vertices[idx].u1 = fx;
                vertices[idx].v1 = fz;
                vertices[idx].color = .{ 1.0, 0.0, 0.0, 1.0 };
            }
        }

        var ii: u32 = 0;
        z = 0;
        while (z < grid) : (z += 1) {
            var x: u32 = 0;
            while (x < grid) : (x += 1) {
                const idx0: u32 = z * verts_per_side + x;
                const idx1: u32 = idx0 + 1;
                const idx2: u32 = idx0 + verts_per_side;
                const idx3: u32 = idx2 + 1;

                indices[ii + 0] = idx0;
                indices[ii + 1] = idx2;
                indices[ii + 2] = idx1;
                indices[ii + 3] = idx1;
                indices[ii + 4] = idx2;
                indices[ii + 5] = idx3;
                ii += 6;
            }
        }

        materials[0] = std.mem.zeroes(scene.CardinalMaterial);
        const TextureHandle = @TypeOf(materials[0].albedo_texture);
        const invalid_tex: TextureHandle = .{ .index = std.math.maxInt(u32), .generation = 0 };
        materials[0].albedo_texture = invalid_tex;
        materials[0].normal_texture = invalid_tex;
        materials[0].metallic_roughness_texture = invalid_tex;
        materials[0].ao_texture = invalid_tex;
        materials[0].emissive_texture = invalid_tex;
        materials[0].albedo_factor = .{ 0.35, 0.6, 0.35, 1.0 };
        materials[0].metallic_factor = 0.0;
        materials[0].roughness_factor = 0.95;
        materials[0].emissive_factor = .{ 0.0, 0.0, 0.0 };
        materials[0].emissive_strength = 0.0;
        materials[0].normal_scale = 1.0;
        materials[0].ao_strength = 1.0;
        materials[0].alpha_mode = scene.CardinalAlphaMode.OPAQUE;
        materials[0].alpha_cutoff = 0.5;
        materials[0].double_sided = true;
        materials[0].uv_indices = .{ 0, 0, 0, 0, 0 };
        materials[0].albedo_transform = std.mem.zeroes(scene.CardinalTextureTransform);
        materials[0].normal_transform = std.mem.zeroes(scene.CardinalTextureTransform);
        materials[0].metallic_roughness_transform = std.mem.zeroes(scene.CardinalTextureTransform);
        materials[0].ao_transform = std.mem.zeroes(scene.CardinalTextureTransform);
        materials[0].emissive_transform = std.mem.zeroes(scene.CardinalTextureTransform);

        meshes[0] = std.mem.zeroes(scene.CardinalMesh);
        meshes[0].vertices = @ptrCast(vertices);
        meshes[0].vertex_count = vertex_count;
        meshes[0].indices = @ptrCast(indices);
        meshes[0].index_count = index_count;
        meshes[0].material_index = 0;
        meshes[0].visible = true;
        meshes[0].bounding_box_min = .{ -half, 0.0, -half };
        meshes[0].bounding_box_max = .{ half, 0.0, half };

        const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
        @memcpy(&meshes[0].transform, &identity);

        out.meshes = @ptrCast(meshes);
        out.mesh_count = 1;
        out.materials = @ptrCast(materials);
        out.material_count = 1;
        out.textures = null;
        out.texture_count = 0;
        out.lights = null;
        out.light_count = 0;
        out.root_nodes = null;
        out.root_node_count = 0;
        out.all_nodes = null;
        out.all_node_count = 0;
        out.animation_system = null;
        out.skins = null;
        out.skin_count = 0;
        return out;
    }

    var allocs = AllocBundle{ .assets_alloc = assets_alloc };
    allocs.meshes_ptr = memory.cardinal_calloc(assets_alloc, 3, @sizeOf(scene.CardinalMesh)) orelse return null;
    errdefer allocs.deinit();
    allocs.materials_ptr = memory.cardinal_calloc(assets_alloc, 1, @sizeOf(scene.CardinalMaterial)) orelse return null;
    allocs.vertices_ptr = memory.cardinal_alloc(assets_alloc, @as(usize, vertex_count) * @sizeOf(scene.CardinalVertex)) orelse return null;
    allocs.indices_ptr = memory.cardinal_alloc(assets_alloc, @as(usize, index_count) * @sizeOf(u32)) orelse return null;
    allocs.bottom_vertices_ptr = memory.cardinal_alloc(assets_alloc, @as(usize, vertex_count) * @sizeOf(scene.CardinalVertex)) orelse return null;
    allocs.bottom_indices_ptr = memory.cardinal_alloc(assets_alloc, @as(usize, index_count) * @sizeOf(u32)) orelse return null;

    const max_edges: u32 = 4 * grid * grid + 4 * grid;
    const wall_vertex_cap: u32 = max_edges * 4;
    const wall_index_cap: u32 = max_edges * 6;
    allocs.wall_vertices_ptr = memory.cardinal_alloc(assets_alloc, @as(usize, wall_vertex_cap) * @sizeOf(scene.CardinalVertex)) orelse return null;
    allocs.wall_indices_ptr = memory.cardinal_alloc(assets_alloc, @as(usize, wall_index_cap) * @sizeOf(u32)) orelse return null;

    const meshes: [*]scene.CardinalMesh = @ptrCast(@alignCast(allocs.meshes_ptr));
    const materials: [*]scene.CardinalMaterial = @ptrCast(@alignCast(allocs.materials_ptr));
    const vertices: [*]scene.CardinalVertex = @ptrCast(@alignCast(allocs.vertices_ptr));
    const indices: [*]u32 = @ptrCast(@alignCast(allocs.indices_ptr));
    const bottom_vertices: [*]scene.CardinalVertex = @ptrCast(@alignCast(allocs.bottom_vertices_ptr));
    const bottom_indices: [*]u32 = @ptrCast(@alignCast(allocs.bottom_indices_ptr));
    const wall_vertices: [*]scene.CardinalVertex = @ptrCast(@alignCast(allocs.wall_vertices_ptr));
    const wall_indices: [*]u32 = @ptrCast(@alignCast(allocs.wall_indices_ptr));

    const half = world_size * 0.5;
    const min_y: f32 = 0.0;
    const max_y: f32 = 0.0;
    const thickness_clamped: f32 = @max(0.01, thickness);

    var z: u32 = 0;
    while (z < verts_per_side) : (z += 1) {
        var x: u32 = 0;
        while (x < verts_per_side) : (x += 1) {
            const idx: u32 = z * verts_per_side + x;
            const fx: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(grid));
            const fz: f32 = @as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(grid));

            vertices[idx] = std.mem.zeroes(scene.CardinalVertex);
            vertices[idx].px = fx * world_size - half;
            vertices[idx].py = 0.0;
            vertices[idx].pz = fz * world_size - half;
            vertices[idx].nx = 0.0;
            vertices[idx].ny = 1.0;
            vertices[idx].nz = 0.0;
            vertices[idx].u = fx;
            vertices[idx].v = fz;
            vertices[idx].u1 = fx;
            vertices[idx].v1 = fz;
            vertices[idx].color = .{ 1.0, 0.0, 0.0, 1.0 };

            bottom_vertices[idx] = vertices[idx];
            bottom_vertices[idx].py = -thickness_clamped;
            bottom_vertices[idx].ny = -1.0;
        }
    }

    var ii: u32 = 0;
    z = 0;
    while (z < grid) : (z += 1) {
        var x: u32 = 0;
        while (x < grid) : (x += 1) {
            const idx0: u32 = z * verts_per_side + x;
            const idx1: u32 = idx0 + 1;
            const idx2: u32 = idx0 + verts_per_side;
            const idx3: u32 = idx2 + 1;

            indices[ii + 0] = idx0;
            indices[ii + 1] = idx2;
            indices[ii + 2] = idx1;
            indices[ii + 3] = idx1;
            indices[ii + 4] = idx2;
            indices[ii + 5] = idx3;
            ii += 6;
        }
    }

    ii = 0;
    z = 0;
    while (z < grid) : (z += 1) {
        var x: u32 = 0;
        while (x < grid) : (x += 1) {
            const idx0: u32 = z * verts_per_side + x;
            const idx1: u32 = idx0 + 1;
            const idx2: u32 = idx0 + verts_per_side;
            const idx3: u32 = idx2 + 1;

            bottom_indices[ii + 0] = idx0;
            bottom_indices[ii + 1] = idx1;
            bottom_indices[ii + 2] = idx2;
            bottom_indices[ii + 3] = idx1;
            bottom_indices[ii + 4] = idx3;
            bottom_indices[ii + 5] = idx2;
            ii += 6;
        }
    }

    materials[0] = std.mem.zeroes(scene.CardinalMaterial);
    const TextureHandle = @TypeOf(materials[0].albedo_texture);
    const invalid_tex: TextureHandle = .{ .index = std.math.maxInt(u32), .generation = 0 };
    materials[0].albedo_texture = invalid_tex;
    materials[0].normal_texture = invalid_tex;
    materials[0].metallic_roughness_texture = invalid_tex;
    materials[0].ao_texture = invalid_tex;
    materials[0].emissive_texture = invalid_tex;
    materials[0].albedo_factor = .{ 0.35, 0.6, 0.35, 1.0 };
    materials[0].metallic_factor = 0.0;
    materials[0].roughness_factor = 0.95;
    materials[0].emissive_factor = .{ 0.0, 0.0, 0.0 };
    materials[0].emissive_strength = 0.0;
    materials[0].normal_scale = 1.0;
    materials[0].ao_strength = 1.0;
    materials[0].alpha_mode = scene.CardinalAlphaMode.OPAQUE;
    materials[0].alpha_cutoff = 0.5;
    materials[0].double_sided = true;
    materials[0].uv_indices = .{ 0, 0, 0, 0, 0 };
    materials[0].albedo_transform = std.mem.zeroes(scene.CardinalTextureTransform);
    materials[0].normal_transform = std.mem.zeroes(scene.CardinalTextureTransform);
    materials[0].metallic_roughness_transform = std.mem.zeroes(scene.CardinalTextureTransform);
    materials[0].ao_transform = std.mem.zeroes(scene.CardinalTextureTransform);
    materials[0].emissive_transform = std.mem.zeroes(scene.CardinalTextureTransform);

    meshes[0] = std.mem.zeroes(scene.CardinalMesh);
    meshes[0].vertices = @ptrCast(vertices);
    meshes[0].vertex_count = vertex_count;
    meshes[0].indices = @ptrCast(indices);
    meshes[0].index_count = index_count;
    meshes[0].material_index = 0;
    meshes[0].visible = true;
    meshes[0].bounding_box_min = .{ -half, min_y, -half };
    meshes[0].bounding_box_max = .{ half, max_y, half };

    const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    @memcpy(&meshes[0].transform, &identity);

    meshes[1] = std.mem.zeroes(scene.CardinalMesh);
    meshes[1].vertices = @ptrCast(bottom_vertices);
    meshes[1].vertex_count = vertex_count;
    meshes[1].indices = @ptrCast(bottom_indices);
    meshes[1].index_count = index_count;
    meshes[1].material_index = 0;
    meshes[1].visible = true;
    meshes[1].bounding_box_min = .{ -half, -thickness_clamped, -half };
    meshes[1].bounding_box_max = .{ half, 0.0, half };
    @memcpy(&meshes[1].transform, &identity);

    meshes[2] = std.mem.zeroes(scene.CardinalMesh);
    meshes[2].vertices = @ptrCast(wall_vertices);
    meshes[2].vertex_count = 0;
    meshes[2].indices = @ptrCast(wall_indices);
    meshes[2].index_count = 0;
    meshes[2].material_index = 0;
    meshes[2].visible = true;
    meshes[2].bounding_box_min = .{ -half, -thickness_clamped, -half };
    meshes[2].bounding_box_max = .{ half, 0.0, half };
    @memcpy(&meshes[2].transform, &identity);

    var wall_v: u32 = 0;
    var wall_i: u32 = 0;

    var seg: u32 = 0;
    while (seg < grid) : (seg += 1) {
        const left0: u32 = seg * verts_per_side + 0;
        const left1: u32 = (seg + 1) * verts_per_side + 0;
        emit_wall_quad(wall_vertices, wall_indices, &wall_v, &wall_i, vertices[left0], vertices[left1], -1.0, 0.0, true, thickness_clamped);

        const right0: u32 = seg * verts_per_side + grid;
        const right1: u32 = (seg + 1) * verts_per_side + grid;
        emit_wall_quad(wall_vertices, wall_indices, &wall_v, &wall_i, vertices[right0], vertices[right1], 1.0, 0.0, false, thickness_clamped);

        const up0: u32 = 0 * verts_per_side + seg;
        const up1: u32 = 0 * verts_per_side + (seg + 1);
        emit_wall_quad(wall_vertices, wall_indices, &wall_v, &wall_i, vertices[up0], vertices[up1], 0.0, -1.0, false, thickness_clamped);

        const down0: u32 = grid * verts_per_side + seg;
        const down1: u32 = grid * verts_per_side + (seg + 1);
        emit_wall_quad(wall_vertices, wall_indices, &wall_v, &wall_i, vertices[down0], vertices[down1], 0.0, 1.0, true, thickness_clamped);
    }

    meshes[2].vertex_count = wall_v;
    meshes[2].index_count = wall_i;

    out.meshes = @ptrCast(meshes);
    out.mesh_count = 3;
    out.materials = @ptrCast(materials);
    out.material_count = 1;
    out.textures = null;
    out.texture_count = 0;
    out.lights = null;
    out.light_count = 0;
    out.root_nodes = null;
    out.root_node_count = 0;
    out.all_nodes = null;
    out.all_node_count = 0;
    out.animation_system = null;
    out.skins = null;
    out.skin_count = 0;

    return out;
}
