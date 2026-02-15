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

// --- Externs from loader.c ---
extern fn cardinal_scene_load(file_path: [*:0]const u8, out_scene: *scene.CardinalScene) callconv(.c) bool;

// --- Constants ---
const INITIAL_MODEL_CAPACITY = 8;

// --- Struct Definitions ---

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

pub const CardinalModelManager = extern struct {
    models: ?[*]CardinalModelInstance,
    model_count: u32,
    model_capacity: u32,
    next_id: u32,
    combined_scene: scene.CardinalScene,
    scene_dirty: bool,
    selected_model_id: u32,
};

const FinalizeContext = struct {
    scene_task: *async_loader.CardinalAsyncTask,
};

const FinalizedModelData = struct {
    scene: scene.CardinalScene,
    bbox_min: [3]f32,
    bbox_max: [3]f32,
};

fn finalize_model_task(task: ?*async_loader.CardinalAsyncTask, user_data: ?*anyopaque) callconv(.c) bool {
    if (user_data == null) return false;
    const ctx = @as(*FinalizeContext, @ptrCast(@alignCast(user_data)));
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    defer memory.cardinal_free(allocator, ctx);

    // Free the scene task when we are done with it
    defer async_loader.cardinal_async_free_task(ctx.scene_task);

    // Check if scene load was successful
    if (ctx.scene_task.status != .COMPLETED) {
        if (ctx.scene_task.status == .FAILED) {
            const err_msg = async_loader.cardinal_async_get_error_message(ctx.scene_task);
            const err_str = if (err_msg) |msg| std.mem.span(msg) else "unknown error";
            model_log.err("Scene load task failed: {s}", .{err_str});
        } else {
            model_log.err("Scene load task did not complete (status: {any})", .{ctx.scene_task.status});
        }
        return false;
    }

    if (ctx.scene_task.result_data == null) {
        model_log.err("Scene load task completed but returned no result", .{});
        return false;
    }

    const loaded_scene_ptr = @as(*scene.CardinalScene, @ptrCast(@alignCast(ctx.scene_task.result_data)));

    // Allocate result data
    const result_ptr = memory.cardinal_alloc(allocator, @sizeOf(FinalizedModelData));
    if (result_ptr == null) {
        model_log.err("Failed to allocate finalize result data", .{});
        scene.cardinal_scene_destroy(loaded_scene_ptr);
        const engine_allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
        memory.cardinal_free(engine_allocator, loaded_scene_ptr);
        return false;
    }
    const result = @as(*FinalizedModelData, @ptrCast(@alignCast(result_ptr)));

    // Move scene data to result
    result.scene = loaded_scene_ptr.*;

    // Calculate bounds
    calculate_scene_bounds(&result.scene, &result.bbox_min, &result.bbox_max);

    // NOTE: We do NOT free loaded_scene_ptr here because async_loader.cardinal_async_free_task(ctx.scene_task)
    // will free the result_data (which is loaded_scene_ptr). Doing it here would cause a double free.

    if (task) |t| {
        t.result_data = result;
        t.result_size = @sizeOf(FinalizedModelData);
    }

    model_log.info("Async model finalization calculated bounds: min({d},{d},{d}) max({d},{d},{d})", .{ result.bbox_min[0], result.bbox_min[1], result.bbox_min[2], result.bbox_max[0], result.bbox_max[1], result.bbox_max[2] });
    return true;
}

// --- Helper Functions ---

fn generate_model_name(file_path: ?[*:0]const u8) ?[*:0]u8 {
    if (file_path == null) return null;

    const path_slice = std.mem.span(file_path.?);
    var filename_start: usize = 0;

    // Find last slash/backslash
    var i: usize = 0;
    while (i < path_slice.len) : (i += 1) {
        if (path_slice[i] == '/' or path_slice[i] == '\\') {
            filename_start = i + 1;
        }
    }

    const filename = path_slice[filename_start..];

    // Find last dot
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

fn optimize_scene_animations(scn: *scene.CardinalScene) void {
    if (scn.animation_system) |sys_opaque| {
        // Cast the opaque pointer to the actual animation system type
        const sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(sys_opaque)));

        // We can check if animations array exists
        if (sys.animations) |anims| {
            var i: u32 = 0;
            while (i < sys.animation_count) : (i += 1) {
                // Apply RDP optimization with a small tolerance
                // 0.0001 seems reasonable for visual fidelity while reducing redundant keys
                animation.cardinal_animation_optimize(&anims[i], 0.0001);
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

    // Safety check for meshes pointer
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

fn cleanup_combined_scene(manager: *CardinalModelManager) void {
    const s = &manager.combined_scene;
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    // Free Meshes Array (but NOT contents as they are shared)
    if (s.meshes) |meshes| {
        memory.cardinal_free(allocator, @ptrCast(meshes));
    }

    // Free Materials Array
    if (s.materials) |mats| {
        memory.cardinal_free(allocator, @ptrCast(mats));
    }

    // Free Textures Array
    if (s.textures) |texs| {
        var i: u32 = 0;
        while (i < s.texture_count) : (i += 1) {
            if (texs[i].ref_resource) |r| ref_counting.cardinal_ref_release(r);
            if (texs[i].path) |p| memory.cardinal_free(allocator, @ptrCast(p));

            // If we allocated data in rebuild (no ref), we must free it
            if (texs[i].ref_resource == null and texs[i].data != null) {
                memory.cardinal_free(allocator, @ptrCast(texs[i].data));
            }
        }
        memory.cardinal_free(allocator, @ptrCast(texs));
    }

    // Free Nodes Arrays (but NOT nodes themselves as they are shared)
    if (s.root_nodes) |nodes| memory.cardinal_free(allocator, @ptrCast(nodes));
    if (s.all_nodes) |nodes| memory.cardinal_free(allocator, @ptrCast(nodes));

    // Lights
    if (s.lights) |lights| memory.cardinal_free(allocator, @ptrCast(lights));

    // Skins (Deep Copied -> Destroy)
    if (s.skins) |skins_opaque| {
        const skins: [*]animation.CardinalSkin = @ptrCast(@alignCast(skins_opaque));
        var i: u32 = 0;
        while (i < s.skin_count) : (i += 1) {
            animation.cardinal_skin_destroy(&skins[i]);
        }
        memory.cardinal_free(allocator, @ptrCast(skins));
    }

    // Animation System (Deep Copied -> Destroy)
    if (s.animation_system) |sys| {
        animation.cardinal_animation_system_destroy(@ptrCast(@alignCast(sys)));
    }

    // Reset struct
    @memset(@as([*]u8, @ptrCast(s))[0..@sizeOf(scene.CardinalScene)], 0);
}

fn rebuild_combined_scene(manager: *CardinalModelManager) void {
    // Clean up existing combined scene safely (without destroying shared data)
    cleanup_combined_scene(manager);

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

    var i: u32 = 0;
    while (i < manager.model_count) : (i += 1) {
        const model = &models[i];
        if (model.visible and !model.is_loading) {
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

    // Allocate arrays
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

    // Allocate animation system if needed
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

        // Copy meshes (No baking vertices, just transform matrix)
        if (scn.meshes) |src_meshes| {
            var m: u32 = 0;
            while (m < scn.mesh_count) : (m += 1) {
                const src_mesh = &src_meshes[m];
                const dst_mesh = &manager.combined_scene.meshes.?[mesh_offset + m];

                if (src_mesh.vertices == null or src_mesh.vertex_count == 0 or
                    src_mesh.indices == null or src_mesh.index_count == 0)
                {
                    // Initialize empty
                    @memset(@as([*]u8, @ptrCast(dst_mesh))[0..@sizeOf(scene.CardinalMesh)], 0);
                    dst_mesh.visible = false;
                    continue;
                }

                // Shallow copy mesh data (vertices/indices pointers are shared)
                dst_mesh.* = src_mesh.*;
                dst_mesh.material_index += material_offset;

                // Apply model transform to mesh transform
                transform_math.cardinal_matrix_multiply(&model.transform, &src_mesh.transform, &dst_mesh.transform);
            }
        }

        // Deep copy materials
        if (scn.materials) |src_materials| {
            var mat: u32 = 0;
            while (mat < scn.material_count) : (mat += 1) {
                const src_material = &src_materials[mat];
                const dst_material = &manager.combined_scene.materials.?[material_offset + mat];

                dst_material.* = src_material.*;

                // Adjust texture indices
                if (dst_material.albedo_texture.is_valid()) dst_material.albedo_texture.index += texture_offset;
                if (dst_material.normal_texture.is_valid()) dst_material.normal_texture.index += texture_offset;
                if (dst_material.metallic_roughness_texture.is_valid()) dst_material.metallic_roughness_texture.index += texture_offset;
                if (dst_material.ao_texture.is_valid()) dst_material.ao_texture.index += texture_offset;
                if (dst_material.emissive_texture.is_valid()) dst_material.emissive_texture.index += texture_offset;
            }
        }

        // Deep copy textures
        if (scn.textures) |src_textures| {
            var tex: u32 = 0;
            while (tex < scn.texture_count) : (tex += 1) {
                const src_texture = &src_textures[tex];
                const dst_texture = &manager.combined_scene.textures.?[texture_offset + tex];

                dst_texture.* = src_texture.*;

                var used_ref_counting = false;
                if (src_texture.ref_resource) |res| {
                    // Directly increment ref count and use the existing resource pointer
                    // This ensures we preserve the link to the async loading resource
                    _ = @atomicRmw(u32, &res.ref_count, .Add, 1, .seq_cst);
                    dst_texture.ref_resource = res;

                    // Update data pointer from the resource directly
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

                // Copy path
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

                // Copy fallback texture
                if (dst_texture.ref_resource == null and src_texture.ref_resource != null) {
                    // Check if it's the fallback texture
                    if (src_texture.width == 2 and src_texture.height == 2) {
                        // Try to acquire again
                        if (src_texture.ref_resource.?.identifier) |id| {
                            if (ref_counting.cardinal_ref_acquire(id)) |acquired_res| {
                                dst_texture.ref_resource = acquired_res;
                                dst_texture.data = src_texture.data;
                            }
                        }
                    }
                }

                // Debug logging
                if (dst_texture.ref_resource == null and src_texture.ref_resource != null) {
                    model_log.warn("Texture copy failed to preserve ref_resource! Src: {*}, Dst: {*}", .{ src_texture.ref_resource, dst_texture.ref_resource });
                } else if (dst_texture.ref_resource != null) {
                    // model_log.debug("Texture copy preserved ref_resource: {*}", .{dst_texture.ref_resource});
                }
            }
        }

        // Copy Nodes
        if (scn.all_nodes) |src_nodes| {
            // Shallow copy node pointers
            @memcpy(manager.combined_scene.all_nodes.?[node_offset .. node_offset + scn.all_node_count], src_nodes[0..scn.all_node_count]);
        }

        // Copy Root Nodes
        if (scn.root_nodes) |src_roots| {
            if (manager.combined_scene.root_nodes) |dst_roots| {
                @memcpy(dst_roots[manager.combined_scene.root_node_count .. manager.combined_scene.root_node_count + scn.root_node_count], src_roots[0..scn.root_node_count]);
                manager.combined_scene.root_node_count += scn.root_node_count;
            }
        }

        // Copy Animation System Data
        if (scn.animation_system != null and manager.combined_scene.animation_system != null) {
            const src_sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(scn.animation_system.?)));
            const dst_sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(manager.combined_scene.animation_system.?)));

            // Copy Animations
            var anim_idx: u32 = 0;
            while (anim_idx < src_sys.animation_count) : (anim_idx += 1) {
                // We need to create a temporary copy to adjust indices before adding
                var anim = src_sys.animations.?[anim_idx];

                // Deep copy channels to adjust indices
                if (anim.channel_count > 0) {
                    const channels_ptr = memory.cardinal_alloc(allocator, anim.channel_count * @sizeOf(animation.CardinalAnimationChannel));
                    if (channels_ptr) |cp| {
                        const channels = @as([*]animation.CardinalAnimationChannel, @ptrCast(@alignCast(cp)));
                        @memcpy(channels[0..anim.channel_count], anim.channels.?[0..anim.channel_count]);

                        // Adjust node indices
                        var c_idx: u32 = 0;
                        while (c_idx < anim.channel_count) : (c_idx += 1) {
                            channels[c_idx].target.node_index += node_offset;
                        }

                        anim.channels = channels;
                        _ = animation.cardinal_animation_system_add_animation(dst_sys, &anim);
                        memory.cardinal_free(allocator, cp);
                    } else {
                        // Fallback: add as is (will point to wrong nodes)
                        _ = animation.cardinal_animation_system_add_animation(dst_sys, &anim);
                    }
                } else {
                    _ = animation.cardinal_animation_system_add_animation(dst_sys, &anim);
                }
            }

            // Copy Skins
            var skin_idx: u32 = 0;
            while (skin_idx < src_sys.skin_count) : (skin_idx += 1) {
                var skin = src_sys.skins.?[skin_idx];

                // We need to adjust mesh_indices and bone node indices
                // Skin structure is complex, might need deep copy of arrays if we can't modify in place.
                // cardinal_animation_system_add_skin makes a deep copy.
                // So we can allocate temps, modify, add, free.

                var new_mesh_indices: ?[*]u32 = null;
                var new_bones: ?[*]animation.CardinalBone = null;

                // Adjust Mesh Indices
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

                // Adjust Bones
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

                    // Shallow copy struct first
                    dst_skin.* = src_skin.*;

                    // Deep copy name
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

                    // Deep copy bones
                    if (src_skin.bone_count > 0 and src_skin.bones != null) {
                        const bones_ptr = memory.cardinal_alloc(allocator, src_skin.bone_count * @sizeOf(animation.CardinalBone));
                        if (bones_ptr) |bp| {
                            dst_skin.bones = @ptrCast(@alignCast(bp));
                            @memcpy(dst_skin.bones.?[0..src_skin.bone_count], src_skin.bones.?[0..src_skin.bone_count]);

                            // Deep copy bone names
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

                    // Deep copy mesh indices
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
            }
        }
    }

    manager.scene_dirty = false;

    model_log.debug("Rebuilt combined scene: {d} meshes, {d} materials, {d} textures, {d} nodes, {d} anims", .{ total_meshes, total_materials, total_textures, total_nodes, total_animations });
}

fn free_model_load_task(task: *async_loader.CardinalAsyncTask) void {
    const status = async_loader.cardinal_async_get_task_status(task);
    // If the task hasn't run (PENDING or CANCELLED), we need to clean up the custom data
    // because finalize_model_task won't run to do it.
    if (task.type == .CUSTOM and task.custom_data != null and (status == .PENDING or status == .CANCELLED)) {
        const ctx = @as(*FinalizeContext, @ptrCast(@alignCast(task.custom_data)));
        const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

        // Free the dependency scene task which is otherwise leaked
        async_loader.cardinal_async_free_task(ctx.scene_task);

        // Free the context struct
        memory.cardinal_free(allocator, ctx);

        // Clear custom_data to prevent double free if something else tries
        task.custom_data = null;
    }
    async_loader.cardinal_async_free_task(task);
}

// Public API
pub export fn cardinal_model_manager_init(manager: ?*CardinalModelManager) callconv(.c) bool {
    if (manager == null) return false;
    const mgr = manager.?;

    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(CardinalModelManager)], 0);
    mgr.next_id = 1;
    mgr.scene_dirty = true;

    model_log.debug("Model manager initialized", .{});
    return true;
}

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

    // Destroy combined scene to release references
    cleanup_combined_scene(mgr);

    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(CardinalModelManager)], 0);
    model_log.debug("Model manager destroyed", .{});
}

pub export fn cardinal_model_manager_load_model(manager: ?*CardinalModelManager, file_path: ?[*:0]const u8, name: ?[*:0]const u8) callconv(.c) u32 {
    if (manager == null or file_path == null) return 0;

    // Use the async loader but wait for completion to maintain synchronous API contract
    // Priority 2 = HIGH
    const id = cardinal_model_manager_load_model_async(manager, file_path, name, 2);
    if (id == 0) return 0;

    const model = cardinal_model_manager_get_model(manager, id);
    if (model == null) return 0;

    // Wait for the task chain to complete
    if (model.?.load_task) |task| {
        if (!async_loader.cardinal_async_wait_for_task(task, 0)) {
            model_log.err("Failed to wait for model load task for {s}", .{file_path.?});
            _ = cardinal_model_manager_remove_model(manager, id);
            return 0;
        }

        const status = async_loader.cardinal_async_get_task_status(task);
        if (status == .COMPLETED) {
            // Finalize the model (logic duplicated from update loop)
            var success = false;
            if (task.type == .CUSTOM) {
                if (task.result_data) |result_ptr| {
                    model_log.debug("Processing result data at {*}, model at {*}", .{ result_ptr, model.? });
                    const result = @as(*FinalizedModelData, @ptrCast(@alignCast(result_ptr)));

                    // Copy data to model
                    model.?.scene = result.scene;
                    model.?.bbox_min = result.bbox_min;
                    model.?.bbox_max = result.bbox_max;

                    // Free the result struct
                    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
                    memory.cardinal_free(allocator, result_ptr);

                    success = true;
                    model.?.is_loading = false;
                    manager.?.scene_dirty = true;

                    const model_name_str = if (model.?.name) |n| n else "Unnamed";
                    model_log.info("Synchronous (via Async) loading completed for model '{s}' (ID: {d}, {d} meshes)", .{ model_name_str, model.?.id, model.?.scene.mesh_count });
                } else {
                    model_log.err("Task completed but result_data is null", .{});
                }
            }

            // Cleanup task
            free_model_load_task(task);
            model.?.load_task = null;

            if (!success) {
                _ = cardinal_model_manager_remove_model(manager, id);
                return 0;
            }
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

    // 1. Create Scene Load Task (Dependency)
    // We don't set callbacks here as we'll handle everything in the chain
    const scene_task = async_loader.cardinal_async_load_scene(@ptrCast(file_path.?), @enumFromInt(priority), null, null);
    if (scene_task == null) {
        model_log.err("Failed to start async loading for {s}", .{file_path.?});
        if (model.name) |n| memory.cardinal_free(allocator, @ptrCast(n));
        if (model.file_path) |p| memory.cardinal_free(allocator, @ptrCast(p));
        // Reset loading state
        model.is_loading = false;
        return 0;
    }

    // 2. Create Context for Finalization
    const ctx_ptr = memory.cardinal_alloc(allocator, @sizeOf(FinalizeContext));
    if (ctx_ptr == null) {
        async_loader.cardinal_async_free_task(scene_task);
        if (model.name) |n| memory.cardinal_free(allocator, @ptrCast(n));
        if (model.file_path) |p| memory.cardinal_free(allocator, @ptrCast(p));
        return 0;
    }
    const ctx = @as(*FinalizeContext, @ptrCast(@alignCast(ctx_ptr)));
    ctx.scene_task = scene_task.?;

    // 3. Create Finalize Task (Dependent)
    // This runs after scene load completes
    // Note: We use create_custom_task (no submit) to ensure we can add dependencies before it starts
    const finalize_task = async_loader.cardinal_async_create_custom_task(finalize_model_task, ctx, @enumFromInt(priority), null, null);
    if (finalize_task == null) {
        memory.cardinal_free(allocator, ctx_ptr);
        async_loader.cardinal_async_free_task(scene_task);
        if (model.name) |n| memory.cardinal_free(allocator, @ptrCast(n));
        if (model.file_path) |p| memory.cardinal_free(allocator, @ptrCast(p));
        return 0;
    }

    // 4. Add Dependency
    // finalize_task depends on scene_task
    if (!async_loader.cardinal_async_add_dependency(finalize_task, scene_task)) {
        model_log.err("Failed to add task dependency", .{});
        // If dependency add fails, we should cleanup.
        // But since we haven't submitted finalize_task yet, we can safely free it.
        async_loader.cardinal_async_free_task(finalize_task);
        // scene_task is already submitted, let it run or cancel?
        // Let's try to cancel
        _ = async_loader.cardinal_async_cancel_task(scene_task);
        return 0;
    }

    // 5. Submit Finalize Task
    if (!async_loader.cardinal_async_submit_task(finalize_task)) {
        model_log.err("Failed to submit finalize task", .{});
        async_loader.cardinal_async_free_task(finalize_task);
        return 0;
    }

    model.load_task = finalize_task;

    mgr.model_count += 1;

    const model_name_str = if (model.name) |n| n else "Unnamed";
    model_log.info("Started async loading of model '{s}' from {s} (ID: {d}) with dependency chain", .{ model_name_str, file_path.?, model.id });

    return model.id;
}

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

    // Move scene data
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

pub export fn cardinal_model_manager_get_model(manager: ?*CardinalModelManager, model_id: u32) callconv(.c) ?*CardinalModelInstance {
    if (manager == null) return null;
    const mgr = manager.?;
    const index = find_model_index(mgr, model_id);
    if (index >= 0) {
        return &mgr.models.?[@intCast(index)];
    }
    return null;
}

pub export fn cardinal_model_manager_get_model_by_index(manager: ?*CardinalModelManager, index: u32) callconv(.c) ?*CardinalModelInstance {
    if (manager == null) return null;
    const mgr = manager.?;
    if (index >= mgr.model_count) return null;
    return &mgr.models.?[index];
}

pub export fn cardinal_model_manager_set_transform(manager: ?*CardinalModelManager, model_id: u32, transform: ?*const [16]f32) callconv(.c) bool {
    if (manager == null or transform == null) return false;
    const model = cardinal_model_manager_get_model(manager, model_id);
    if (model == null) return false;

    @memcpy(&model.?.transform, transform.?);
    manager.?.scene_dirty = true;
    return true;
}

pub export fn cardinal_model_manager_get_transform(manager: ?*CardinalModelManager, model_id: u32) callconv(.c) ?*const [16]f32 {
    const model = cardinal_model_manager_get_model(manager, model_id);
    if (model) |m| return &m.transform;
    return null;
}

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

pub export fn cardinal_model_manager_get_combined_scene(manager: ?*CardinalModelManager) callconv(.c) ?*const scene.CardinalScene {
    if (manager == null) return null;
    const mgr = manager.?;

    if (mgr.scene_dirty) {
        rebuild_combined_scene(mgr);
    }

    return &mgr.combined_scene;
}

pub export fn cardinal_model_manager_mark_dirty(manager: ?*CardinalModelManager) callconv(.c) void {
    if (manager) |mgr| mgr.scene_dirty = true;
}

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
                    var success = false;

                    if (task.type == .CUSTOM) {
                        // This is the finalize task in the dependency chain
                        if (task.result_data) |result_ptr| {
                            const result = @as(*FinalizedModelData, @ptrCast(@alignCast(result_ptr)));

                            // Copy data to model
                            model.scene = result.scene;
                            model.bbox_min = result.bbox_min;
                            model.bbox_max = result.bbox_max;

                            // Free the result struct (allocated in finalize_model_task)
                            const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
                            memory.cardinal_free(allocator, result_ptr);

                            success = true;
                            model.is_loading = false;
                            mgr.scene_dirty = true;

                            const model_name_str = if (model.name) |n| n else "Unnamed";
                            model_log.info("Async loading chain completed for model '{s}' (ID: {d}, {d} meshes)", .{ model_name_str, model.id, model.scene.mesh_count });
                        } else {
                            model_log.err("Finalize task completed but no result data found", .{});
                            success = false;
                        }
                    } else if (async_loader.cardinal_async_get_scene_result(task, &model.scene)) {
                        // Direct scene load task
                        calculate_scene_bounds(&model.scene, &model.bbox_min, &model.bbox_max);
                        model.is_loading = false;
                        mgr.scene_dirty = true;

                        const model_name_str = if (model.name) |n| n else "Unnamed";
                        model_log.info("Async loading completed for model '{s}' (ID: {d}, {d} meshes)", .{ model_name_str, model.id, model.scene.mesh_count });
                        success = true;
                    }

                    if (!success) {
                        const model_name_str = if (model.name) |n| n else "Unnamed";
                        model_log.err("Failed to get scene result for model '{s}'", .{model_name_str});
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

    scene.cardinal_scene_destroy(&mgr.combined_scene);
    @memset(@as([*]u8, @ptrCast(&mgr.combined_scene))[0..@sizeOf(scene.CardinalScene)], 0);
}
