const C = @import("common.zig");

const std = C.std;
const engine = C.engine;
const EditorState = C.EditorState;
const memory = C.memory;
const components = C.components;
const node_factory = C.node_factory;
const math = C.math;
const scene = C.scene;

const brick_axis_count = C.brick_axis_count;
const brick_id_to_coords = C.brick_id_to_coords;
const brick_cell_range_for_axis = C.brick_cell_range_for_axis;
const lod_level_count = C.lod_level_count;
const lod_resolution = C.lod_resolution;

pub fn get_model_combined_mesh_range(state: *EditorState, model_id: u32) ?struct { start: u32, count: u32 } {
    if (state.runtime.model_manager.models == null) return null;
    const models = state.runtime.model_manager.models.?;

    var offset: u32 = 0;
    var i: u32 = 0;
    while (i < state.runtime.model_manager.model_count) : (i += 1) {
        const m = &models[i];
        if (!m.visible or m.is_loading) continue;
        if (m.id == model_id) return .{ .start = offset, .count = m.scene.mesh_count };
        offset += m.scene.mesh_count;
    }
    return null;
}

fn get_model_mesh_for_volumetric(state: *EditorState, vt: *components.VolumetricTerrain) ?*scene.CardinalMesh {
    const model = C.model_manager.cardinal_model_manager_get_model(&state.runtime.model_manager, vt.model_id) orelse return null;
    if (model.scene.meshes == null or model.scene.mesh_count == 0) return null;
    const range = get_model_combined_mesh_range(state, vt.model_id) orelse return null;
    if (vt.mesh_index < range.start) return null;
    const local_index: u32 = vt.mesh_index - range.start;
    if (local_index >= model.scene.mesh_count) return null;
    return &model.scene.meshes.?[local_index];
}

fn has_any_brick_entity(state: *EditorState, parent_id: u64) bool {
    var view = state.runtime.registry.view(components.VolumetricTerrainBrick);
    var it = view.iterator();
    while (it.next()) |entry| {
        if (entry.component.parent_id == parent_id) return true;
    }
    return false;
}

pub fn ensure_brick_entities(state: *EditorState, parent_ent: engine.ecs_entity.Entity) void {
    if (!state.runtime.registry.entity_manager.is_alive(parent_ent)) return;
    if (has_any_brick_entity(state, parent_ent.id)) return;
    const vt = state.runtime.registry.get(components.VolumetricTerrain, parent_ent) orelse return;

    const base_res: u32 = if (vt.resolution < 1) 1 else vt.resolution;
    const axis = brick_axis_count(base_res);
    if (axis == 0) return;
    const bcount = axis * axis * axis;

    var material_index: u32 = 0;
    if (state.runtime.combined_scene.meshes != null and vt.mesh_index < state.runtime.combined_scene.mesh_count) {
        material_index = state.runtime.combined_scene.meshes.?[vt.mesh_index].material_index;
    }

    var brick_id: u32 = 0;
    while (brick_id < bcount) : (brick_id += 1) {
        const child = node_factory.create_node(state.runtime.registry, parent_ent, .MeshInstance3D, "VT Brick", .{}) catch continue;
        state.runtime.registry.add(child, components.EditorOnly{}) catch {};
        state.runtime.registry.add(child, components.VolumetricTerrainBrick{ .parent_id = parent_ent.id, .brick_id = brick_id }) catch {};
        state.runtime.registry.add(child, components.MeshRenderer{
            .mesh = .{ .index = vt.mesh_index + brick_id, .generation = 0 },
            .material = .{ .index = material_index, .generation = 0 },
            .visible = true,
            .cast_shadows = true,
            .receive_shadows = true,
        }) catch {};
    }
}

pub fn build_scene(resolution: u32, size: math.Vec3) ?scene.CardinalScene {
    const assets_alloc = memory.cardinal_get_allocator_for_category(.ASSETS);
    var out = std.mem.zeroes(scene.CardinalScene);

    const base_res = if (resolution < 1) 1 else resolution;
    const axis = brick_axis_count(base_res);
    const bcount = axis * axis * axis;
    const mesh_count: u32 = lod_level_count * bcount;

    const meshes_ptr = memory.cardinal_calloc(assets_alloc, mesh_count, @sizeOf(scene.CardinalMesh)) orelse return null;
    errdefer memory.cardinal_free(assets_alloc, meshes_ptr);
    const materials_ptr = memory.cardinal_calloc(assets_alloc, 1, @sizeOf(scene.CardinalMaterial)) orelse return null;
    errdefer memory.cardinal_free(assets_alloc, materials_ptr);

    const meshes: [*]scene.CardinalMesh = @ptrCast(@alignCast(meshes_ptr));
    const materials: [*]scene.CardinalMaterial = @ptrCast(@alignCast(materials_ptr));

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

    const half = size.mul(0.5);
    const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    var lod: u32 = 0;
    while (lod < lod_level_count) : (lod += 1) {
        const res_lod: u32 = lod_resolution(base_res, lod);
        const step_world = math.Vec3{
            .x = size.x / @as(f32, @floatFromInt(res_lod)),
            .y = size.y / @as(f32, @floatFromInt(res_lod)),
            .z = size.z / @as(f32, @floatFromInt(res_lod)),
        };

        var brick_id: u32 = 0;
        while (brick_id < bcount) : (brick_id += 1) {
            const idx = lod * bcount + brick_id;
            meshes[idx] = std.mem.zeroes(scene.CardinalMesh);
            meshes[idx].vertices = null;
            meshes[idx].vertex_count = 0;
            meshes[idx].indices = null;
            meshes[idx].index_count = 0;
            meshes[idx].material_index = 0;
            meshes[idx].visible = false;
            @memcpy(&meshes[idx].transform, &identity);

            const c = brick_id_to_coords(axis, brick_id);
            const rx = brick_cell_range_for_axis(res_lod, lod, axis, c.bx);
            const ry = brick_cell_range_for_axis(res_lod, lod, axis, c.by);
            const rz = brick_cell_range_for_axis(res_lod, lod, axis, c.bz);
            if (rx == null or ry == null or rz == null) {
                meshes[idx].bounding_box_min = .{ 0.0, 0.0, 0.0 };
                meshes[idx].bounding_box_max = .{ 0.0, 0.0, 0.0 };
                continue;
            }
            const bb_min = math.Vec3{
                .x = -half.x + step_world.x * @as(f32, @floatFromInt(rx.?.min)),
                .y = -half.y + step_world.y * @as(f32, @floatFromInt(ry.?.min)),
                .z = -half.z + step_world.z * @as(f32, @floatFromInt(rz.?.min)),
            };
            const bb_max = math.Vec3{
                .x = -half.x + step_world.x * @as(f32, @floatFromInt(rx.?.max + 1)),
                .y = -half.y + step_world.y * @as(f32, @floatFromInt(ry.?.max + 1)),
                .z = -half.z + step_world.z * @as(f32, @floatFromInt(rz.?.max + 1)),
            };
            meshes[idx].bounding_box_min = .{ bb_min.x, bb_min.y, bb_min.z };
            meshes[idx].bounding_box_max = .{ bb_max.x, bb_max.y, bb_max.z };
        }
    }

    out.meshes = @ptrCast(meshes);
    out.mesh_count = mesh_count;
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
