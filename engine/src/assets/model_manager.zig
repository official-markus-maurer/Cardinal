//! High-level manager for loaded model scenes.
//!
//! The model manager owns per-model `CardinalScene` instances and can build a combined scene
//! used for rendering/editor selection. The combined scene deep-copies materials/textures/skins
//! but shares node pointers with per-model scenes.
const std = @import("std");
const scene = @import("scene.zig");
const transform_math = @import("../core/transform.zig");
const memory = @import("../core/memory.zig");
const log = @import("../core/log.zig");
const ref_counting = @import("../core/ref_counting.zig");
const async_loader = @import("../core/async_loader.zig");
const texture_loader = @import("texture_loader.zig");
const animation = @import("animation.zig");

const model_log = log.ScopedLogger("MODEL");

const builtin = @import("builtin");

/// Synchronous scene load entrypoint.
extern fn cardinal_scene_load(file_path: [*:0]const u8, out_scene: *scene.CardinalScene) callconv(.c) bool;

/// Default initial capacity for the model array.
const INITIAL_MODEL_CAPACITY = 8;

/// A loaded model instance and its per-model scene data.
pub const CardinalModelInstance = extern struct {
    name: ?[*:0]u8,
    file_path: ?[*:0]u8,
    scene: scene.CardinalScene,
    transform: [16]f32,
    visible: bool,
    selected: bool,
    id: u32,
    bbox_min: [3]f32,
    bbox_max: [3]f32,
    is_loading: bool,
    load_task: ?*async_loader.CardinalAsyncTask,
};

/// Stateful container for loaded models and an optional combined scene snapshot.
pub const CardinalModelManager = extern struct {
    models: ?[*]CardinalModelInstance,
    model_count: u32,
    model_capacity: u32,
    next_id: u32,
    combined_scene: scene.CardinalScene,
    scene_dirty: bool,
    transform_dirty: bool,
    selected_model_id: u32,
};

/// Generates a display name derived from the file name.
fn generate_model_name(file_path: ?[*:0]const u8) ?[*:0]u8 {
    if (file_path == null) return null;

    const path_slice = std.mem.span(file_path.?);
    var filename_start: usize = 0;

    var i: usize = 0;
    while (i < path_slice.len) : (i += 1) {
        if (path_slice[i] == '/' or path_slice[i] == '\\') {
            filename_start = i + 1;
        }
    }

    const filename = path_slice[filename_start..];

    var ext_idx: usize = filename.len;
    i = 0;
    while (i < filename.len) : (i += 1) {
        if (filename[i] == '.') {
            ext_idx = i;
        }
    }

    const name_len = ext_idx;
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    const name_ptr = memory.cardinal_alloc(allocator, name_len + 1);
    if (name_ptr == null) return null;

    @memcpy(@as([*]u8, @ptrCast(name_ptr))[0..name_len], filename[0..name_len]);
    @as([*]u8, @ptrCast(name_ptr))[name_len] = 0;

    return @as([*:0]u8, @ptrCast(name_ptr));
}

/// Applies optional keyframe reduction passes to animations, if present.
///
/// This is a best-effort optimization step. It skips processing when the animation system pointer
/// is misaligned to avoid traps in safe builds.
fn optimize_scene_animations(scn: *scene.CardinalScene) void {
    if (scn.animation_system) |sys_opaque| {
        if (@intFromPtr(sys_opaque) % @alignOf(animation.CardinalAnimationSystem) != 0) {
            model_log.err("Animation system pointer unaligned: {p}. Skipping optimization.", .{sys_opaque});
            return;
        }

        const sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(sys_opaque)));

        if (sys.animation_count == 0) return;

        if (sys.animations) |anims| {
            var i: u32 = 0;
            if (sys.animation_count > 1000) {
                model_log.warn("Scene has unusually high animation count: {d}. Optimization may be slow or unsafe.", .{sys.animation_count});
            }

            while (i < sys.animation_count) : (i += 1) {
                const anim_ptr = &anims[i];

                if (anim_ptr.sampler_count > 0 and anim_ptr.samplers != null) {
                    animation.cardinal_animation_optimize(anim_ptr, 0.0001);
                }
            }
        }
    }
}

fn calculate_scene_bounds(scn: *const scene.CardinalScene, bbox_min: *[3]f32, bbox_max: *[3]f32) void {
    if (scn.mesh_count == 0) {
        bbox_min.* = .{ 0, 0, 0 };
        bbox_max.* = .{ 0, 0, 0 };
        return;
    }

    var first_vertex = true;

    if (scn.meshes == null) return;
    const meshes = scn.meshes.?;

    var m: u32 = 0;
    while (m < scn.mesh_count) : (m += 1) {
        const mesh = meshes[m];

        if (mesh.vertices == null) continue;
        const vertices = mesh.vertices.?;

        var v: u32 = 0;
        while (v < mesh.vertex_count) : (v += 1) {
            const vertex = vertices[v];

            if (first_vertex) {
                bbox_min[0] = vertex.px;
                bbox_max[0] = vertex.px;
                bbox_min[1] = vertex.py;
                bbox_max[1] = vertex.py;
                bbox_min[2] = vertex.pz;
                bbox_max[2] = vertex.pz;
                first_vertex = false;
            } else {
                if (vertex.px < bbox_min[0]) bbox_min[0] = vertex.px;
                if (vertex.py < bbox_min[1]) bbox_min[1] = vertex.py;
                if (vertex.pz < bbox_min[2]) bbox_min[2] = vertex.pz;
                if (vertex.px > bbox_max[0]) bbox_max[0] = vertex.px;
                if (vertex.py > bbox_max[1]) bbox_max[1] = vertex.py;
                if (vertex.pz > bbox_max[2]) bbox_max[2] = vertex.pz;
            }
        }
    }
}

fn expand_models_array(manager: *CardinalModelManager) bool {
    const new_capacity = if (manager.model_capacity == 0) INITIAL_MODEL_CAPACITY else manager.model_capacity * 2;
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    const new_models_ptr = memory.cardinal_realloc(allocator, manager.models, new_capacity * @sizeOf(CardinalModelInstance));

    if (new_models_ptr == null) {
        model_log.err("Failed to expand models array to capacity {d}", .{new_capacity});
        return false;
    }

    manager.models = @ptrCast(@alignCast(new_models_ptr));
    manager.model_capacity = new_capacity;
    return true;
}

pub fn find_model_index(manager: *const CardinalModelManager, model_id: u32) i32 {
    if (manager.models) |models| {
        var i: u32 = 0;
        while (i < manager.model_count) : (i += 1) {
            if (models[i].id == model_id) {
                return @intCast(i);
            }
        }
    }
    return -1;
}

/// Releases heap-owned allocations inside `manager.combined_scene`.
///
/// The combined scene intentionally shares mesh vertex/index pointers and node pointers with
/// per-model scenes, so this only frees the combined arrays and deep-copied resources.
fn cleanup_combined_scene(manager: *CardinalModelManager) void {
    const s = &manager.combined_scene;
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    if (s.meshes) |meshes| {
        memory.cardinal_free(allocator, @ptrCast(meshes));
    }

    if (s.materials) |mats| {
        memory.cardinal_free(allocator, @ptrCast(mats));
    }

    if (s.textures) |texs| {
        var i: u32 = 0;
        while (i < s.texture_count) : (i += 1) {
            if (texs[i].ref_resource) |r| ref_counting.cardinal_ref_release(r);
            if (texs[i].path) |p| memory.cardinal_free(allocator, @ptrCast(p));

            if (texs[i].ref_resource == null and texs[i].data != null) {
                memory.cardinal_free(allocator, @ptrCast(texs[i].data));
            }
        }
        memory.cardinal_free(allocator, @ptrCast(texs));
    }

    if (s.root_nodes) |nodes| memory.cardinal_free(allocator, @ptrCast(nodes));
    if (s.all_nodes) |nodes| memory.cardinal_free(allocator, @ptrCast(nodes));

    if (s.lights) |lights| memory.cardinal_free(allocator, @ptrCast(lights));

    if (s.skins) |skins_opaque| {
        const skins: [*]animation.CardinalSkin = @ptrCast(@alignCast(skins_opaque));
        var i: u32 = 0;
        while (i < s.skin_count) : (i += 1) {
            scene.destroy_scene_skin_assets(allocator, &skins[i]);
        }
        memory.cardinal_free(allocator, @ptrCast(skins));
    }

    if (s.animation_system) |sys| {
        animation.cardinal_animation_system_destroy(@ptrCast(@alignCast(sys)));
    }

    @memset(@as([*]u8, @ptrCast(s))[0..@sizeOf(scene.CardinalScene)], 0);
}

/// Rebuilds `manager.combined_scene` by concatenating all visible model scenes.
///
/// Mesh vertex/index data is shared, while materials/textures/skins are copied so their indices
/// can be re-based into a single scene namespace.
fn rebuild_combined_scene(manager: *CardinalModelManager) void {
    var total_meshes: u32 = 0;
    var total_materials: u32 = 0;
    var total_textures: u32 = 0;
    var total_nodes: u32 = 0;
    var total_animations: u32 = 0;
    var total_skins: u32 = 0;

    const models = if (manager.models) |m| m else {
        manager.scene_dirty = false;
        return;
    };

    var visible_indices = std.ArrayListUnmanaged(u32){};
    defer visible_indices.deinit(memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator());

    var i: u32 = 0;
    while (i < manager.model_count) : (i += 1) {
        const model = &models[i];
        if (model.visible and !model.is_loading) {
            visible_indices.append(memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator(), i) catch return;

            total_meshes += model.scene.mesh_count;
            total_materials += model.scene.material_count;
            total_textures += model.scene.texture_count;
            total_nodes += model.scene.all_node_count;

            if (model.scene.animation_system) |sys_opaque| {
                const sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(sys_opaque)));
                total_animations += sys.animation_count;
                total_skins += sys.skin_count;
            }
        }
    }

    if (total_meshes == 0) {
        manager.scene_dirty = false;
        return;
    }

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    const existing_meshes: u32 = manager.combined_scene.mesh_count;
    const existing_materials: u32 = manager.combined_scene.material_count;
    const existing_textures: u32 = manager.combined_scene.texture_count;
    const existing_nodes: u32 = manager.combined_scene.all_node_count;

    if (manager.combined_scene.meshes != null and
        manager.combined_scene.materials != null and
        manager.combined_scene.textures != null and
        manager.combined_scene.all_nodes != null and
        existing_meshes > 0 and
        total_animations == 0 and
        total_skins == 0)
    {
        var prefix_meshes: u32 = 0;
        var prefix_materials: u32 = 0;
        var prefix_textures: u32 = 0;
        var prefix_nodes: u32 = 0;
        var prefix_visible_count: u32 = 0;

        for (visible_indices.items) |model_idx| {
            if (prefix_meshes == existing_meshes and
                prefix_materials == existing_materials and
                prefix_textures == existing_textures and
                prefix_nodes == existing_nodes)
            {
                break;
            }

            const m = &models[model_idx];
            prefix_meshes += m.scene.mesh_count;
            prefix_materials += m.scene.material_count;
            prefix_textures += m.scene.texture_count;
            prefix_nodes += m.scene.all_node_count;
            prefix_visible_count += 1;
        }

        if (prefix_meshes == existing_meshes and
            prefix_materials == existing_materials and
            prefix_textures == existing_textures and
            prefix_nodes == existing_nodes and
            prefix_visible_count < visible_indices.items.len)
        {
            const new_meshes = total_meshes;
            const new_materials = total_materials;
            const new_textures = total_textures;
            const new_nodes = total_nodes;

            const meshes_bytes = std.math.mul(usize, @as(usize, new_meshes), @sizeOf(scene.CardinalMesh)) catch 0;
            const materials_bytes = std.math.mul(usize, @as(usize, new_materials), @sizeOf(scene.CardinalMaterial)) catch 0;
            const textures_bytes = std.math.mul(usize, @as(usize, new_textures), @sizeOf(scene.CardinalTexture)) catch 0;
            const nodes_bytes = std.math.mul(usize, @as(usize, new_nodes), @sizeOf(?*scene.CardinalSceneNode)) catch 0;

            const meshes_ptr = if (meshes_bytes > 0)
                memory.cardinal_realloc(allocator, @ptrCast(manager.combined_scene.meshes), meshes_bytes)
            else
                null;
            const materials_ptr = if (materials_bytes > 0)
                memory.cardinal_realloc(allocator, @ptrCast(manager.combined_scene.materials), materials_bytes)
            else
                null;
            const textures_ptr = if (textures_bytes > 0)
                memory.cardinal_realloc(allocator, @ptrCast(manager.combined_scene.textures), textures_bytes)
            else
                null;
            const nodes_ptr = if (nodes_bytes > 0)
                memory.cardinal_realloc(allocator, @ptrCast(manager.combined_scene.all_nodes), nodes_bytes)
            else
                null;

            if ((new_meshes == 0 or meshes_ptr != null) and
                (new_materials == 0 or materials_ptr != null) and
                (new_textures == 0 or textures_ptr != null) and
                (new_nodes == 0 or nodes_ptr != null))
            {
                manager.combined_scene.meshes = if (meshes_ptr) |p| @ptrCast(@alignCast(p)) else null;
                manager.combined_scene.materials = if (materials_ptr) |p| @ptrCast(@alignCast(p)) else null;
                manager.combined_scene.textures = if (textures_ptr) |p| @ptrCast(@alignCast(p)) else null;
                manager.combined_scene.all_nodes = if (nodes_ptr) |p| @ptrCast(@alignCast(p)) else null;

                var mesh_offset: u32 = existing_meshes;
                var material_offset: u32 = existing_materials;
                var texture_offset: u32 = existing_textures;
                var node_offset: u32 = existing_nodes;

                var append_i: usize = prefix_visible_count;
                while (append_i < visible_indices.items.len) : (append_i += 1) {
                    const model = &models[visible_indices.items[append_i]];
                    const scn = &model.scene;

                    if (scn.meshes) |src_meshes| {
                        var m: u32 = 0;
                        while (m < scn.mesh_count) : (m += 1) {
                            const src_mesh = &src_meshes[m];
                            const dst_mesh = &manager.combined_scene.meshes.?[mesh_offset + m];

                            if (src_mesh.vertices == null or src_mesh.vertex_count == 0 or
                                src_mesh.indices == null or src_mesh.index_count == 0)
                            {
                                @memset(@as([*]u8, @ptrCast(dst_mesh))[0..@sizeOf(scene.CardinalMesh)], 0);
                                dst_mesh.visible = false;
                                continue;
                            }

                            dst_mesh.* = src_mesh.*;
                            dst_mesh.material_index += material_offset;
                            transform_math.cardinal_matrix_multiply(&model.transform, &src_mesh.transform, &dst_mesh.transform);
                        }
                    }

                    if (scn.materials) |src_materials| {
                        var mat: u32 = 0;
                        while (mat < scn.material_count) : (mat += 1) {
                            const src_material = &src_materials[mat];
                            const dst_material = &manager.combined_scene.materials.?[material_offset + mat];

                            dst_material.* = src_material.*;
                            if (dst_material.albedo_texture.is_valid()) dst_material.albedo_texture.index += texture_offset;
                            if (dst_material.normal_texture.is_valid()) dst_material.normal_texture.index += texture_offset;
                            if (dst_material.metallic_roughness_texture.is_valid()) dst_material.metallic_roughness_texture.index += texture_offset;
                            if (dst_material.ao_texture.is_valid()) dst_material.ao_texture.index += texture_offset;
                            if (dst_material.emissive_texture.is_valid()) dst_material.emissive_texture.index += texture_offset;
                        }
                    }

                    if (scn.textures) |src_textures| {
                        var tex: u32 = 0;
                        while (tex < scn.texture_count) : (tex += 1) {
                            const src_texture = &src_textures[tex];
                            const dst_texture = &manager.combined_scene.textures.?[texture_offset + tex];

                            dst_texture.* = src_texture.*;

                            var used_ref_counting = false;
                            if (src_texture.ref_resource) |res| {
                                _ = @atomicRmw(u32, &res.ref_count, .Add, 1, .seq_cst);
                                dst_texture.ref_resource = res;

                                if (res.resource) |r| {
                                    const tex_data = @as(*texture_loader.TextureData, @ptrCast(@alignCast(r)));
                                    dst_texture.data = tex_data.data;
                                    dst_texture.width = tex_data.width;
                                    dst_texture.height = tex_data.height;
                                    dst_texture.channels = tex_data.channels;
                                    dst_texture.is_hdr = tex_data.is_hdr;
                                    dst_texture.format = tex_data.format;
                                    dst_texture.data_size = tex_data.data_size;
                                } else {
                                    dst_texture.data = src_texture.data;
                                }
                                used_ref_counting = true;
                            }

                            if (!used_ref_counting) {
                                dst_texture.ref_resource = null;
                                if (src_texture.data != null and src_texture.width > 0 and src_texture.height > 0) {
                                    const data_size = src_texture.width * src_texture.height * src_texture.channels;
                                    const data_ptr = memory.cardinal_alloc(allocator, data_size);
                                    if (data_ptr) |dp| {
                                        @memcpy(@as([*]u8, @ptrCast(dp))[0..data_size], @as([*]u8, @ptrCast(src_texture.data.?))[0..data_size]);
                                        dst_texture.data = @ptrCast(dp);
                                    } else {
                                        dst_texture.data = null;
                                    }
                                } else {
                                    dst_texture.data = null;
                                }
                            }

                            if (src_texture.path) |p| {
                                const path_len = std.mem.len(p);
                                const path_ptr = memory.cardinal_alloc(allocator, path_len + 1);
                                if (path_ptr) |pp| {
                                    @memcpy(@as([*]u8, @ptrCast(pp))[0..path_len], @as([*]const u8, @ptrCast(p))[0..path_len]);
                                    @as([*]u8, @ptrCast(pp))[path_len] = 0;
                                    dst_texture.path = @ptrCast(pp);
                                } else {
                                    dst_texture.path = null;
                                }
                            } else {
                                dst_texture.path = null;
                            }

                            if (dst_texture.ref_resource == null and src_texture.ref_resource != null) {
                                if (src_texture.width == 2 and src_texture.height == 2) {
                                    if (src_texture.ref_resource.?.identifier) |id| {
                                        if (ref_counting.cardinal_ref_acquire(id)) |acquired_res| {
                                            dst_texture.ref_resource = acquired_res;
                                            dst_texture.data = src_texture.data;
                                        }
                                    }
                                }
                            }

                            if (dst_texture.ref_resource == null and src_texture.ref_resource != null) {
                                model_log.warn("Texture copy failed to preserve ref_resource! Src: {*}, Dst: {*}", .{ src_texture.ref_resource, dst_texture.ref_resource });
                            }
                        }
                    }

                    if (scn.all_nodes) |src_nodes| {
                        @memcpy(manager.combined_scene.all_nodes.?[node_offset .. node_offset + scn.all_node_count], src_nodes[0..scn.all_node_count]);
                    }

                    mesh_offset += scn.mesh_count;
                    material_offset += scn.material_count;
                    texture_offset += scn.texture_count;
                    node_offset += scn.all_node_count;
                }

                manager.combined_scene.mesh_count = new_meshes;
                manager.combined_scene.material_count = new_materials;
                manager.combined_scene.texture_count = new_textures;
                manager.combined_scene.all_node_count = new_nodes;
                manager.scene_dirty = false;
                return;
            }
        }
    }

    cleanup_combined_scene(manager);

    const meshes_ptr = memory.cardinal_calloc(allocator, total_meshes, @sizeOf(scene.CardinalMesh));
    if (meshes_ptr) |ptr| {
        model_log.debug("Allocated combined meshes: {any} size {d}", .{ ptr, total_meshes * @sizeOf(scene.CardinalMesh) });
    }
    const materials_ptr = memory.cardinal_calloc(allocator, total_materials, @sizeOf(scene.CardinalMaterial));
    const textures_ptr = memory.cardinal_calloc(allocator, total_textures, @sizeOf(scene.CardinalTexture));
    const nodes_ptr = memory.cardinal_calloc(allocator, total_nodes, @sizeOf(?*scene.CardinalSceneNode));

    if (meshes_ptr == null or materials_ptr == null or textures_ptr == null or (total_nodes > 0 and nodes_ptr == null)) {
        model_log.err("Failed to allocate memory for combined scene", .{});
        if (meshes_ptr) |p| memory.cardinal_free(allocator, p);
        if (materials_ptr) |p| memory.cardinal_free(allocator, p);
        if (textures_ptr) |p| memory.cardinal_free(allocator, p);
        if (nodes_ptr) |p| memory.cardinal_free(allocator, p);
        return;
    }

    manager.combined_scene.meshes = @ptrCast(@alignCast(meshes_ptr));
    manager.combined_scene.materials = @ptrCast(@alignCast(materials_ptr));
    manager.combined_scene.textures = @ptrCast(@alignCast(textures_ptr));
    manager.combined_scene.all_nodes = @ptrCast(@alignCast(nodes_ptr));
    manager.combined_scene.all_node_count = total_nodes;

    if (total_animations > 0 or total_skins > 0) {
        manager.combined_scene.animation_system = @ptrCast(animation.cardinal_animation_system_create(total_animations, total_skins));
    }

    var mesh_offset: u32 = 0;
    var material_offset: u32 = 0;
    var texture_offset: u32 = 0;
    var node_offset: u32 = 0;

    i = 0;
    while (i < manager.model_count) : (i += 1) {
        const model = &models[i];
        if (!model.visible or model.is_loading) continue;

        const scn = &model.scene;

        if (scn.meshes) |src_meshes| {
            var m: u32 = 0;
            while (m < scn.mesh_count) : (m += 1) {
                const src_mesh = &src_meshes[m];
                const dst_mesh = &manager.combined_scene.meshes.?[mesh_offset + m];

                if (src_mesh.vertices == null or src_mesh.vertex_count == 0 or
                    src_mesh.indices == null or src_mesh.index_count == 0)
                {
                    @memset(@as([*]u8, @ptrCast(dst_mesh))[0..@sizeOf(scene.CardinalMesh)], 0);
                    dst_mesh.visible = false;
                    continue;
                }

                dst_mesh.* = src_mesh.*;
                dst_mesh.material_index += material_offset;

                transform_math.cardinal_matrix_multiply(&model.transform, &src_mesh.transform, &dst_mesh.transform);
            }
        }

        if (scn.materials) |src_materials| {
            var mat: u32 = 0;
            while (mat < scn.material_count) : (mat += 1) {
                const src_material = &src_materials[mat];
                const dst_material = &manager.combined_scene.materials.?[material_offset + mat];

                dst_material.* = src_material.*;

                if (dst_material.albedo_texture.is_valid()) dst_material.albedo_texture.index += texture_offset;
                if (dst_material.normal_texture.is_valid()) dst_material.normal_texture.index += texture_offset;
                if (dst_material.metallic_roughness_texture.is_valid()) dst_material.metallic_roughness_texture.index += texture_offset;
                if (dst_material.ao_texture.is_valid()) dst_material.ao_texture.index += texture_offset;
                if (dst_material.emissive_texture.is_valid()) dst_material.emissive_texture.index += texture_offset;
            }
        }

        if (scn.textures) |src_textures| {
            var tex: u32 = 0;
            while (tex < scn.texture_count) : (tex += 1) {
                const src_texture = &src_textures[tex];
                const dst_texture = &manager.combined_scene.textures.?[texture_offset + tex];

                dst_texture.* = src_texture.*;

                var used_ref_counting = false;
                if (src_texture.ref_resource) |res| {
                    _ = @atomicRmw(u32, &res.ref_count, .Add, 1, .seq_cst);
                    dst_texture.ref_resource = res;

                    if (res.resource) |r| {
                        const tex_data = @as(*texture_loader.TextureData, @ptrCast(@alignCast(r)));
                        dst_texture.data = tex_data.data;
                        dst_texture.width = tex_data.width;
                        dst_texture.height = tex_data.height;
                        dst_texture.channels = tex_data.channels;
                        dst_texture.is_hdr = tex_data.is_hdr;
                        dst_texture.format = tex_data.format;
                        dst_texture.data_size = tex_data.data_size;
                    } else {
                        dst_texture.data = src_texture.data;
                    }
                    used_ref_counting = true;
                }

                if (!used_ref_counting) {
                    dst_texture.ref_resource = null;
                    if (src_texture.data != null and src_texture.width > 0 and src_texture.height > 0) {
                        const data_size = src_texture.width * src_texture.height * src_texture.channels;
                        const data_ptr = memory.cardinal_alloc(allocator, data_size);
                        if (data_ptr) |dp| {
                            @memcpy(@as([*]u8, @ptrCast(dp))[0..data_size], @as([*]u8, @ptrCast(src_texture.data.?))[0..data_size]);
                            dst_texture.data = @ptrCast(dp);
                        } else {
                            dst_texture.data = null;
                        }
                    } else {
                        dst_texture.data = null;
                    }
                }

                if (src_texture.path) |p| {
                    const path_len = std.mem.len(p);
                    const path_ptr = memory.cardinal_alloc(allocator, path_len + 1);
                    if (path_ptr) |pp| {
                        @memcpy(@as([*]u8, @ptrCast(pp))[0..path_len], @as([*]const u8, @ptrCast(p))[0..path_len]);
                        @as([*]u8, @ptrCast(pp))[path_len] = 0;
                        dst_texture.path = @ptrCast(pp);
                    } else {
                        dst_texture.path = null;
                    }
                } else {
                    dst_texture.path = null;
                }

                if (dst_texture.ref_resource == null and src_texture.ref_resource != null) {
                    if (src_texture.width == 2 and src_texture.height == 2) {
                        if (src_texture.ref_resource.?.identifier) |id| {
                            if (ref_counting.cardinal_ref_acquire(id)) |acquired_res| {
                                dst_texture.ref_resource = acquired_res;
                                dst_texture.data = src_texture.data;
                            }
                        }
                    }
                }

                if (dst_texture.ref_resource == null and src_texture.ref_resource != null) {
                    model_log.warn("Texture copy failed to preserve ref_resource! Src: {*}, Dst: {*}", .{ src_texture.ref_resource, dst_texture.ref_resource });
                }
            }
        }

        if (scn.all_nodes) |src_nodes| {
            @memcpy(manager.combined_scene.all_nodes.?[node_offset .. node_offset + scn.all_node_count], src_nodes[0..scn.all_node_count]);
        }

        if (scn.root_nodes) |src_roots| {
            if (manager.combined_scene.root_nodes) |dst_roots| {
                @memcpy(dst_roots[manager.combined_scene.root_node_count .. manager.combined_scene.root_node_count + scn.root_node_count], src_roots[0..scn.root_node_count]);
                manager.combined_scene.root_node_count += scn.root_node_count;
            }
        }

        if (scn.animation_system != null and manager.combined_scene.animation_system != null) {
            const src_sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(scn.animation_system.?)));
            const dst_sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(manager.combined_scene.animation_system.?)));

            var anim_idx: u32 = 0;
            while (anim_idx < src_sys.animation_count) : (anim_idx += 1) {
                var anim = src_sys.animations.?[anim_idx];

                if (anim.channel_count > 0) {
                    const channels_ptr = memory.cardinal_alloc(allocator, anim.channel_count * @sizeOf(animation.CardinalAnimationChannel));
                    if (channels_ptr) |cp| {
                        const channels = @as([*]animation.CardinalAnimationChannel, @ptrCast(@alignCast(cp)));
                        @memcpy(channels[0..anim.channel_count], anim.channels.?[0..anim.channel_count]);

                        var c_idx: u32 = 0;
                        while (c_idx < anim.channel_count) : (c_idx += 1) {
                            channels[c_idx].target.node_index += node_offset;
                        }

                        anim.channels = channels;
                        _ = animation.cardinal_animation_system_add_animation(dst_sys, &anim);
                        memory.cardinal_free(allocator, cp);
                    } else {
                        _ = animation.cardinal_animation_system_add_animation(dst_sys, &anim);
                    }
                } else {
                    _ = animation.cardinal_animation_system_add_animation(dst_sys, &anim);
                }
            }

            var skin_idx: u32 = 0;
            while (skin_idx < src_sys.skin_count) : (skin_idx += 1) {
                var skin = src_sys.skins.?[skin_idx];

                var new_mesh_indices: ?[*]u32 = null;
                var new_bones: ?[*]animation.CardinalBone = null;

                if (skin.mesh_count > 0 and skin.mesh_indices != null) {
                    const mi_ptr = memory.cardinal_alloc(allocator, skin.mesh_count * @sizeOf(u32));
                    if (mi_ptr) |mip| {
                        new_mesh_indices = @ptrCast(@alignCast(mip));
                        @memcpy(new_mesh_indices.?[0..skin.mesh_count], skin.mesh_indices.?[0..skin.mesh_count]);

                        var m: u32 = 0;
                        while (m < skin.mesh_count) : (m += 1) {
                            new_mesh_indices.?[m] += mesh_offset;
                        }
                        skin.mesh_indices = new_mesh_indices;
                    }
                }

                if (skin.bone_count > 0 and skin.bones != null) {
                    const b_ptr = memory.cardinal_alloc(allocator, skin.bone_count * @sizeOf(animation.CardinalBone));
                    if (b_ptr) |bp| {
                        new_bones = @ptrCast(@alignCast(bp));
                        @memcpy(new_bones.?[0..skin.bone_count], skin.bones.?[0..skin.bone_count]);

                        var b: u32 = 0;
                        while (b < skin.bone_count) : (b += 1) {
                            new_bones.?[b].node_index += node_offset;
                        }
                        skin.bones = new_bones;
                    }
                }

                _ = animation.cardinal_animation_system_add_skin(dst_sys, &skin);

                if (new_mesh_indices) |ptr| memory.cardinal_free(allocator, ptr);
                if (new_bones) |ptr| memory.cardinal_free(allocator, ptr);
            }
        }

        mesh_offset += scn.mesh_count;
        material_offset += scn.material_count;
        texture_offset += scn.texture_count;
        node_offset += scn.all_node_count;
    }

    manager.combined_scene.mesh_count = total_meshes;
    manager.combined_scene.material_count = total_materials;
    manager.combined_scene.texture_count = total_textures;
    manager.combined_scene.skin_count = total_skins;
    if (manager.combined_scene.animation_system) |sys_opaque| {
        const sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(sys_opaque)));
        if (sys.skin_count > 0) {
            const skins_ptr = memory.cardinal_calloc(allocator, sys.skin_count, @sizeOf(animation.CardinalSkin));
            if (skins_ptr) |sp| {
                const dst_skins = @as([*]animation.CardinalSkin, @ptrCast(@alignCast(sp)));

                var skin_copy_idx: u32 = 0;
                while (skin_copy_idx < sys.skin_count) : (skin_copy_idx += 1) {
                    const src_skin = &sys.skins.?[skin_copy_idx];
                    const dst_skin = &dst_skins[skin_copy_idx];

                    dst_skin.* = src_skin.*;

                    if (src_skin.name) |n| {
                        const len = std.mem.len(n);
                        const n_ptr = memory.cardinal_alloc(allocator, len + 1);
                        if (n_ptr) |np| {
                            @memcpy(@as([*]u8, @ptrCast(np))[0..len], @as([*]const u8, @ptrCast(n))[0..len]);
                            @as([*]u8, @ptrCast(np))[len] = 0;
                            dst_skin.name = @ptrCast(np);
                        } else {
                            dst_skin.name = null;
                        }
                    } else {
                        dst_skin.name = null;
                    }

                    if (src_skin.bone_count > 0 and src_skin.bones != null) {
                        const bones_ptr = memory.cardinal_alloc(allocator, src_skin.bone_count * @sizeOf(animation.CardinalBone));
                        if (bones_ptr) |bp| {
                            dst_skin.bones = @ptrCast(@alignCast(bp));
                            @memcpy(dst_skin.bones.?[0..src_skin.bone_count], src_skin.bones.?[0..src_skin.bone_count]);

                            var b: u32 = 0;
                            while (b < src_skin.bone_count) : (b += 1) {
                                const src_bone = &src_skin.bones.?[b];
                                const dst_bone = &dst_skin.bones.?[b];

                                if (src_bone.name) |bn| {
                                    const blen = std.mem.len(bn);
                                    const bn_ptr = memory.cardinal_alloc(allocator, blen + 1);
                                    if (bn_ptr) |bnp| {
                                        @memcpy(@as([*]u8, @ptrCast(bnp))[0..blen], @as([*]const u8, @ptrCast(bn))[0..blen]);
                                        @as([*]u8, @ptrCast(bnp))[blen] = 0;
                                        dst_bone.name = @ptrCast(bnp);
                                    } else {
                                        dst_bone.name = null;
                                    }
                                } else {
                                    dst_bone.name = null;
                                }
                            }
                        } else {
                            dst_skin.bones = null;
                            dst_skin.bone_count = 0;
                        }
                    } else {
                        dst_skin.bones = null;
                        dst_skin.bone_count = 0;
                    }

                    if (src_skin.mesh_count > 0 and src_skin.mesh_indices != null) {
                        const mi_ptr = memory.cardinal_alloc(allocator, src_skin.mesh_count * @sizeOf(u32));
                        if (mi_ptr) |mip| {
                            dst_skin.mesh_indices = @ptrCast(@alignCast(mip));
                            @memcpy(dst_skin.mesh_indices.?[0..src_skin.mesh_count], src_skin.mesh_indices.?[0..src_skin.mesh_count]);
                        } else {
                            dst_skin.mesh_indices = null;
                            dst_skin.mesh_count = 0;
                        }
                    } else {
                        dst_skin.mesh_indices = null;
                        dst_skin.mesh_count = 0;
                    }
                }

                manager.combined_scene.skins = @ptrCast(dst_skins);
                manager.combined_scene.skin_count = sys.skin_count;
            } else {
                manager.combined_scene.skins = null;
                manager.combined_scene.skin_count = 0;
            }
        } else {
            manager.combined_scene.skins = null;
            manager.combined_scene.skin_count = 0;
        }
    }

    manager.scene_dirty = false;

    model_log.debug("Rebuilt combined scene: {d} meshes, {d} materials, {d} textures, {d} nodes, {d} anims", .{ total_meshes, total_materials, total_textures, total_nodes, total_animations });
}

fn update_combined_mesh_transforms(manager: *CardinalModelManager) void {
    if (manager.combined_scene.meshes == null) return;
    const models = manager.models orelse return;

    var mesh_offset: u32 = 0;
    var i: u32 = 0;
    while (i < manager.model_count) : (i += 1) {
        const model = &models[i];
        if (!model.visible or model.is_loading) continue;

        const scn = &model.scene;
        if (scn.mesh_count == 0 or scn.meshes == null) continue;

        var m: u32 = 0;
        while (m < scn.mesh_count) : (m += 1) {
            const src_mesh = &scn.meshes.?[m];
            const dst_mesh = &manager.combined_scene.meshes.?[mesh_offset + m];
            transform_math.cardinal_matrix_multiply(&model.transform, &src_mesh.transform, &dst_mesh.transform);
        }

        mesh_offset += scn.mesh_count;
    }
}

fn free_model_load_task(task: *async_loader.CardinalAsyncTask) void {
    const status = async_loader.cardinal_async_get_task_status(task);
    if (status == .RUNNING) return;
    _ = async_loader.cardinal_async_cancel_task(task);
    async_loader.cardinal_async_free_task(task);
}

/// Initializes a model manager in-place.
pub export fn cardinal_model_manager_init(manager: ?*CardinalModelManager) callconv(.c) bool {
    if (manager == null) return false;
    const mgr = manager.?;

    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(CardinalModelManager)], 0);
    mgr.next_id = 1;
    mgr.scene_dirty = true;

    model_log.debug("Model manager initialized", .{});
    return true;
}

/// Releases all loaded models and combined-scene resources.
pub export fn cardinal_model_manager_destroy(manager: ?*CardinalModelManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    if (mgr.models) |models| {
        var i: u32 = 0;
        while (i < mgr.model_count) : (i += 1) {
            const model = &models[i];

            if (model.name) |n| memory.cardinal_free(allocator, @ptrCast(n));
            if (model.file_path) |p| memory.cardinal_free(allocator, @ptrCast(p));
            scene.cardinal_scene_destroy(&model.scene);

            if (model.load_task) |task| {
                free_model_load_task(task);
            }
        }
        memory.cardinal_free(allocator, models);
    }

    cleanup_combined_scene(mgr);

    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(CardinalModelManager)], 0);
    model_log.debug("Model manager destroyed", .{});
}

/// Loads a model (blocking) via the async loader and returns its model id.
pub export fn cardinal_model_manager_load_model(manager: ?*CardinalModelManager, file_path: ?[*:0]const u8, name: ?[*:0]const u8) callconv(.c) u32 {
    if (manager == null or file_path == null) return 0;

    const id = cardinal_model_manager_load_model_async(manager, file_path, name, 2);
    if (id == 0) return 0;

    const model = cardinal_model_manager_get_model(manager, id);
    if (model == null) return 0;

    if (model.?.load_task) |task| {
        if (!async_loader.cardinal_async_wait_for_task(task, 0)) {
            model_log.err("Failed to wait for model load task for {s}", .{file_path.?});
            _ = cardinal_model_manager_remove_model(manager, id);
            return 0;
        }

        const status = async_loader.cardinal_async_get_task_status(task);
        if (status == .COMPLETED) {
            const got_scene = async_loader.cardinal_async_get_scene_result(task, &model.?.scene);

            free_model_load_task(task);
            model.?.load_task = null;

            if (!got_scene) {
                _ = cardinal_model_manager_remove_model(manager, id);
                return 0;
            }

            optimize_scene_animations(&model.?.scene);
            calculate_scene_bounds(&model.?.scene, &model.?.bbox_min, &model.?.bbox_max);
            model.?.is_loading = false;
            manager.?.scene_dirty = true;

            const model_name_str = if (model.?.name) |n| n else "Unnamed";
            model_log.info("Synchronous (via Async) loading completed for model '{s}' (ID: {d}, {d} meshes)", .{ model_name_str, model.?.id, model.?.scene.mesh_count });
        } else {
            const error_msg = async_loader.cardinal_async_get_error_message(task);
            const err_str = if (error_msg) |e| e else "Unknown error";
            model_log.err("Model load failed: {s}", .{err_str});

            free_model_load_task(task);
            model.?.load_task = null;
            _ = cardinal_model_manager_remove_model(manager, id);
            return 0;
        }
    }

    return id;
}

/// Starts an async model load and returns a model id immediately (0 on failure).
pub export fn cardinal_model_manager_load_model_async(manager: ?*CardinalModelManager, file_path: ?[*:0]const u8, name: ?[*:0]const u8, priority: c_int) callconv(.c) u32 {
    if (manager == null or file_path == null) return 0;
    const mgr = manager.?;

    if (mgr.model_count >= mgr.model_capacity) {
        if (!expand_models_array(mgr)) return 0;
    }

    const models = mgr.models.?;
    const model = &models[mgr.model_count];
    @memset(@as([*]u8, @ptrCast(model))[0..@sizeOf(CardinalModelInstance)], 0);

    model.id = mgr.next_id;
    mgr.next_id += 1;

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    const path_len = std.mem.len(file_path.?);
    const path_ptr = memory.cardinal_alloc(allocator, path_len + 1);
    if (path_ptr) |pp| {
        @memcpy(@as([*]u8, @ptrCast(pp))[0..path_len], @as([*]const u8, @ptrCast(file_path.?))[0..path_len]);
        @as([*]u8, @ptrCast(pp))[path_len] = 0;
        model.file_path = @ptrCast(pp);
    }

    if (name) |n| {
        const name_len = std.mem.len(n);
        const name_ptr = memory.cardinal_alloc(allocator, name_len + 1);
        if (name_ptr) |np| {
            @memcpy(@as([*]u8, @ptrCast(np))[0..name_len], @as([*]const u8, @ptrCast(n))[0..name_len]);
            @as([*]u8, @ptrCast(np))[name_len] = 0;
            model.name = @ptrCast(np);
        }
    } else {
        model.name = generate_model_name(file_path.?);
    }

    transform_math.cardinal_matrix_identity(&model.transform);
    model.visible = true;
    model.selected = false;
    model.is_loading = true;

    const scene_task = async_loader.cardinal_async_load_scene(@ptrCast(file_path.?), @enumFromInt(priority), null, null);
    if (scene_task == null) {
        model_log.err("Failed to start async loading for {s}", .{file_path.?});
        if (model.name) |n| memory.cardinal_free(allocator, @ptrCast(n));
        if (model.file_path) |p| memory.cardinal_free(allocator, @ptrCast(p));
        model.is_loading = false;
        return 0;
    }
    model.load_task = scene_task;

    mgr.model_count += 1;

    const model_name_str = if (model.name) |n| n else "Unnamed";
    model_log.info("Started async loading of model '{s}' from {s} (ID: {d})", .{ model_name_str, file_path.?, model.id });

    return model.id;
}

/// Adds a loaded scene to the manager, taking ownership of its internal allocations.
///
/// This copies `in_scene` into the model instance and zeroes `in_scene` to prevent double-free.
pub export fn cardinal_model_manager_add_scene(manager: ?*CardinalModelManager, in_scene: ?*scene.CardinalScene, file_path: ?[*:0]const u8, name: ?[*:0]const u8) callconv(.c) u32 {
    if (manager == null or in_scene == null) return 0;
    const mgr = manager.?;

    if (mgr.model_count >= mgr.model_capacity) {
        if (!expand_models_array(mgr)) return 0;
    }

    const models = mgr.models.?;
    const model = &models[mgr.model_count];
    @memset(@as([*]u8, @ptrCast(model))[0..@sizeOf(CardinalModelInstance)], 0);

    model.id = mgr.next_id;
    mgr.next_id += 1;

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    if (file_path) |p| {
        const path_len = std.mem.len(p);
        const path_ptr = memory.cardinal_alloc(allocator, path_len + 1);
        if (path_ptr) |pp| {
            @memcpy(@as([*]u8, @ptrCast(pp))[0..path_len], @as([*]const u8, @ptrCast(p))[0..path_len]);
            @as([*]u8, @ptrCast(pp))[path_len] = 0;
            model.file_path = @ptrCast(pp);
        }
    }

    if (name) |n| {
        const name_len = std.mem.len(n);
        const name_ptr = memory.cardinal_alloc(allocator, name_len + 1);
        if (name_ptr) |np| {
            @memcpy(@as([*]u8, @ptrCast(np))[0..name_len], @as([*]const u8, @ptrCast(n))[0..name_len]);
            @as([*]u8, @ptrCast(np))[name_len] = 0;
            model.name = @ptrCast(np);
        }
    } else {
        if (file_path) |p| {
            model.name = generate_model_name(p);
        } else {
            model.name = null;
        }
    }

    transform_math.cardinal_matrix_identity(&model.transform);
    model.visible = true;
    model.selected = false;
    model.is_loading = false;
    model.load_task = null;

    model.scene = in_scene.?.*;

    @memset(@as([*]u8, @ptrCast(in_scene.?))[0..@sizeOf(scene.CardinalScene)], 0);

    optimize_scene_animations(&model.scene);

    calculate_scene_bounds(&model.scene, &model.bbox_min, &model.bbox_max);

    mgr.model_count += 1;
    mgr.scene_dirty = true;

    const model_name_str = if (model.name) |n| n else "Unnamed";
    model_log.info("Added scene '{s}' to model manager (ID: {d}, {d} meshes)", .{ model_name_str, model.id, model.scene.mesh_count });

    return model.id;
}

/// Removes a model by id and destroys its scene/resources.
pub export fn cardinal_model_manager_remove_model(manager: ?*CardinalModelManager, model_id: u32) callconv(.c) bool {
    if (manager == null) return false;
    const mgr = manager.?;

    const index = find_model_index(mgr, model_id);
    if (index < 0) return false;
    const idx = @as(u32, @intCast(index));

    const models = mgr.models.?;
    const model = &models[idx];

    const model_name_str = if (model.name) |n| n else "Unnamed";
    model_log.info("Removing model '{s}' (ID: {d})", .{ model_name_str, model_id });

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    if (model.name) |n| memory.cardinal_free(allocator, @ptrCast(n));
    if (model.file_path) |p| memory.cardinal_free(allocator, @ptrCast(p));
    scene.cardinal_scene_destroy(&model.scene);

    if (model.load_task) |task| {
        free_model_load_task(task);
    }

    var i = idx;
    while (i < mgr.model_count - 1) : (i += 1) {
        models[i] = models[i + 1];
    }

    mgr.model_count -= 1;
    mgr.scene_dirty = true;

    if (mgr.selected_model_id == model_id) {
        mgr.selected_model_id = 0;
    }

    return true;
}

/// Returns the model instance for an id, or null if not found.
pub export fn cardinal_model_manager_get_model(manager: ?*CardinalModelManager, model_id: u32) callconv(.c) ?*CardinalModelInstance {
    if (manager == null) return null;
    const mgr = manager.?;
    const index = find_model_index(mgr, model_id);
    if (index >= 0) {
        return &mgr.models.?[@intCast(index)];
    }
    return null;
}

/// Returns the model instance at a stable array index, or null if out of range.
pub export fn cardinal_model_manager_get_model_by_index(manager: ?*CardinalModelManager, index: u32) callconv(.c) ?*CardinalModelInstance {
    if (manager == null) return null;
    const mgr = manager.?;
    if (index >= mgr.model_count) return null;
    return &mgr.models.?[index];
}

/// Sets the model transform matrix and marks the combined scene dirty.
pub export fn cardinal_model_manager_set_transform(manager: ?*CardinalModelManager, model_id: u32, transform: ?*const [16]f32) callconv(.c) bool {
    if (manager == null or transform == null) return false;
    const model = cardinal_model_manager_get_model(manager, model_id);
    if (model == null) return false;

    @memcpy(&model.?.transform, transform.?);
    if (manager.?.combined_scene.meshes == null and manager.?.scene_dirty == false) {
        manager.?.scene_dirty = true;
    } else {
        manager.?.transform_dirty = true;
    }
    return true;
}

/// Gets the model transform matrix, or null if not found.
pub export fn cardinal_model_manager_get_transform(manager: ?*CardinalModelManager, model_id: u32) callconv(.c) ?*const [16]f32 {
    const model = cardinal_model_manager_get_model(manager, model_id);
    if (model) |m| return &m.transform;
    return null;
}

/// Sets the model visibility and marks the combined scene dirty when changed.
pub export fn cardinal_model_manager_set_visible(manager: ?*CardinalModelManager, model_id: u32, visible: bool) callconv(.c) bool {
    if (manager == null) return false;
    const model = cardinal_model_manager_get_model(manager, model_id);
    if (model == null) return false;

    if (model.?.visible != visible) {
        model.?.visible = visible;
        manager.?.scene_dirty = true;
    }
    return true;
}

/// Marks one model as selected (clears previous selection).
pub export fn cardinal_model_manager_set_selected(manager: ?*CardinalModelManager, model_id: u32) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;

    if (mgr.selected_model_id != 0) {
        const prev_selected = cardinal_model_manager_get_model(manager, mgr.selected_model_id);
        if (prev_selected) |m| m.selected = false;
    }

    mgr.selected_model_id = model_id;
    if (model_id != 0) {
        const model = cardinal_model_manager_get_model(manager, model_id);
        if (model) |m| m.selected = true;
    }
}

/// Returns the combined scene snapshot, rebuilding it on demand if dirty.
pub export fn cardinal_model_manager_get_combined_scene(manager: ?*CardinalModelManager) callconv(.c) ?*const scene.CardinalScene {
    if (manager == null) return null;
    const mgr = manager.?;

    if (mgr.scene_dirty) {
        rebuild_combined_scene(mgr);
        mgr.scene_dirty = false;
    } else if (mgr.transform_dirty) {
        update_combined_mesh_transforms(mgr);
        mgr.transform_dirty = false;
    }

    return &mgr.combined_scene;
}

/// Forces the combined scene to be rebuilt on the next query.
pub export fn cardinal_model_manager_mark_dirty(manager: ?*CardinalModelManager) callconv(.c) void {
    if (manager) |mgr| mgr.scene_dirty = true;
}

/// Advances async load tasks and finalizes completed loads.
pub export fn cardinal_model_manager_update(manager: ?*CardinalModelManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;

    if (mgr.models) |models| {
        var i: u32 = 0;
        while (i < mgr.model_count) : (i += 1) {
            const model = &models[i];

            if (model.is_loading and model.load_task != null) {
                const status = async_loader.cardinal_async_get_task_status(model.load_task.?);

                if (status == .COMPLETED) {
                    const task = model.load_task.?;
                    const success = async_loader.cardinal_async_get_scene_result(task, &model.scene);

                    if (!success) {
                        const model_name_str = if (model.name) |n| n else "Unnamed";
                        model_log.err("Failed to get scene result for model '{s}'", .{model_name_str});
                    } else {
                        optimize_scene_animations(&model.scene);
                        calculate_scene_bounds(&model.scene, &model.bbox_min, &model.bbox_max);
                        model.is_loading = false;
                        mgr.scene_dirty = true;

                        const model_name_str = if (model.name) |n| n else "Unnamed";
                        model_log.info("Async loading completed for model '{s}' (ID: {d}, {d} meshes)", .{ model_name_str, model.id, model.scene.mesh_count });
                    }

                    free_model_load_task(model.load_task.?);
                    model.load_task = null;
                } else if (status == .FAILED) {
                    const error_msg = async_loader.cardinal_async_get_error_message(model.load_task.?);
                    const model_name_str = if (model.name) |n| n else "Unnamed";
                    const err_str = if (error_msg) |e| e else "Unknown error";
                    model_log.err("Async loading failed for model '{s}': {s}", .{ model_name_str, err_str });

                    free_model_load_task(model.load_task.?);
                    model.load_task = null;
                    model.is_loading = false;
                }
            }
        }
    }
}

/// Returns the number of loaded models.
pub export fn cardinal_model_manager_get_model_count(manager: ?*const CardinalModelManager) callconv(.c) u32 {
    if (manager == null) return 0;
    const mgr = manager.?;
    var count: u32 = 0;

    if (mgr.models) |models| {
        var i: u32 = 0;
        while (i < mgr.model_count) : (i += 1) {
            if (!models[i].is_loading) {
                count += 1;
            }
        }
    }
    return count;
}

/// Returns the total mesh count across all visible, loaded models.
pub export fn cardinal_model_manager_get_total_mesh_count(manager: ?*const CardinalModelManager) callconv(.c) u32 {
    if (manager == null) return 0;
    const mgr = manager.?;
    var total: u32 = 0;

    if (mgr.models) |models| {
        var i: u32 = 0;
        while (i < mgr.model_count) : (i += 1) {
            if (!models[i].is_loading) {
                total += models[i].scene.mesh_count;
            }
        }
    }
    return total;
}

/// Clears all models and combined-scene data.
pub export fn cardinal_model_manager_clear(manager: ?*CardinalModelManager) callconv(.c) void {
    if (manager == null) return;
    const mgr = manager.?;

    model_log.info("Clearing all models from manager", .{});

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    if (mgr.models) |models| {
        var i: u32 = 0;
        while (i < mgr.model_count) : (i += 1) {
            const model = &models[i];

            if (model.name) |n| memory.cardinal_free(allocator, @ptrCast(n));
            if (model.file_path) |p| memory.cardinal_free(allocator, @ptrCast(p));
            scene.cardinal_scene_destroy(&model.scene);

            if (model.load_task) |task| {
                free_model_load_task(task);
            }
        }
    }

    mgr.model_count = 0;
    mgr.selected_model_id = 0;
    mgr.scene_dirty = true;

    cleanup_combined_scene(mgr);
}
