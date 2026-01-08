const std = @import("std");
const scene = @import("scene.zig");
const transform_math = @import("../core/transform.zig");
const memory = @import("../core/memory.zig");
const log = @import("../core/log.zig");
const ref_counting = @import("../core/ref_counting.zig");
const async_loader = @import("../core/async_loader.zig");
const texture_loader = @import("texture_loader.zig");

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
    if (ctx.scene_task.status != .COMPLETED or ctx.scene_task.result_data == null) {
        model_log.err("Scene load task failed or no result", .{});
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

    // Cleanup the temporary scene struct container (contents are now owned by result)
    const engine_allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    memory.cardinal_free(engine_allocator, loaded_scene_ptr);

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

fn find_model_index(manager: *const CardinalModelManager, model_id: u32) i32 {
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

fn rebuild_combined_scene(manager: *CardinalModelManager) void {
    // Clear existing combined scene
    scene.cardinal_scene_destroy(&manager.combined_scene);
    @memset(@as([*]u8, @ptrCast(&manager.combined_scene))[0..@sizeOf(scene.CardinalScene)], 0);

    var total_meshes: u32 = 0;
    var total_materials: u32 = 0;
    var total_textures: u32 = 0;

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
        log.cardinal_log_debug("[MODEL_MGR] Allocated combined meshes: {any} size {d}", .{ ptr, total_meshes * @sizeOf(scene.CardinalMesh) });
    }
    const materials_ptr = memory.cardinal_calloc(allocator, total_materials, @sizeOf(scene.CardinalMaterial));
    const textures_ptr = memory.cardinal_calloc(allocator, total_textures, @sizeOf(scene.CardinalTexture));

    if (meshes_ptr == null or materials_ptr == null or textures_ptr == null) {
        log.cardinal_log_error("Failed to allocate memory for combined scene", .{});
        if (meshes_ptr) |p| memory.cardinal_free(allocator, p);
        if (materials_ptr) |p| memory.cardinal_free(allocator, p);
        if (textures_ptr) |p| memory.cardinal_free(allocator, p);
        return;
    }

    manager.combined_scene.meshes = @ptrCast(@alignCast(meshes_ptr));
    manager.combined_scene.materials = @ptrCast(@alignCast(materials_ptr));
    manager.combined_scene.textures = @ptrCast(@alignCast(textures_ptr));

    var mesh_offset: u32 = 0;
    var material_offset: u32 = 0;
    var texture_offset: u32 = 0;

    i = 0;
    while (i < manager.model_count) : (i += 1) {
        const model = &models[i];
        if (!model.visible or model.is_loading) continue;

        const scn = &model.scene;

        // Copy meshes with transformed vertices
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

                dst_mesh.* = src_mesh.*;
                dst_mesh.material_index += material_offset;

                // Copy and transform vertices
                const vertices_ptr = memory.cardinal_alloc(allocator, src_mesh.vertex_count * @sizeOf(scene.CardinalVertex));
                if (vertices_ptr) |vp| {
                    const dst_vertices: [*]scene.CardinalVertex = @ptrCast(@alignCast(vp));
                    dst_mesh.vertices = dst_vertices;

                    var v: u32 = 0;
                    while (v < src_mesh.vertex_count) : (v += 1) {
                        dst_vertices[v] = src_mesh.vertices.?[v];

                        // Transform position
                        const pos = [3]f32{ src_mesh.vertices.?[v].px, src_mesh.vertices.?[v].py, src_mesh.vertices.?[v].pz };
                        var transformed_pos: [3]f32 = undefined;
                        transform_math.cardinal_transform_point(&model.transform, &pos, &transformed_pos);

                        dst_vertices[v].px = transformed_pos[0];
                        dst_vertices[v].py = transformed_pos[1];
                        dst_vertices[v].pz = transformed_pos[2];

                        // Transform normal
                        const normal = [3]f32{ src_mesh.vertices.?[v].nx, src_mesh.vertices.?[v].ny, src_mesh.vertices.?[v].nz };
                        var transformed_normal: [3]f32 = undefined;
                        transform_math.cardinal_transform_normal(&model.transform, &normal, &transformed_normal);

                        dst_vertices[v].nx = transformed_normal[0];
                        dst_vertices[v].ny = transformed_normal[1];
                        dst_vertices[v].nz = transformed_normal[2];
                    }
                }

                // Copy indices
                const indices_ptr = memory.cardinal_alloc(allocator, src_mesh.index_count * @sizeOf(u32));
                if (indices_ptr) |ip| {
                    const dst_indices: [*]u32 = @ptrCast(@alignCast(ip));
                    dst_mesh.indices = dst_indices;
                    @memcpy(dst_indices[0..src_mesh.index_count], src_mesh.indices.?[0..src_mesh.index_count]);
                }
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
                    // Try to acquire the resource properly via the registry
                    var acquired = false;
                    if (res.identifier) |id| {
                        if (ref_counting.cardinal_ref_acquire(id)) |acquired_res| {
                            dst_texture.ref_resource = acquired_res;
                            acquired = true;
                        }
                    }

                    if (acquired) {
                        _ = @atomicRmw(u32, &dst_texture.ref_resource.?.ref_count, .Add, 0, .seq_cst); // Just to ensure visibility if needed, though acquire already did Add

                        // Update data pointer from the resource directly to ensure we have the latest data
                        if (dst_texture.ref_resource.?.resource) |r| {
                            const tex_data = @as(*texture_loader.TextureData, @ptrCast(@alignCast(r)));
                            dst_texture.data = tex_data.data;
                            dst_texture.width = tex_data.width;
                            dst_texture.height = tex_data.height;
                            dst_texture.channels = tex_data.channels;
                            dst_texture.is_hdr = tex_data.is_hdr;
                        } else {
                            dst_texture.data = src_texture.data;
                        }
                        used_ref_counting = true;
                    } else {
                        // Fallback: If we couldn't acquire (e.g. not in registry), we don't use ref counting
                        // and will fall through to deep copy below.
                        dst_texture.ref_resource = null;
                        if (res.identifier) |id| {
                            log.cardinal_log_warn("[MODEL_MGR] Failed to acquire ref for texture '{s}', falling back to copy", .{id});
                        }
                    }
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
                    log.cardinal_log_warn("[MODEL_MGR] Texture copy failed to preserve ref_resource! Src: {*}, Dst: {*}", .{ src_texture.ref_resource, dst_texture.ref_resource });
                } else if (dst_texture.ref_resource != null) {
                    // log.cardinal_log_debug("[MODEL_MGR] Texture copy preserved ref_resource: {*}", .{dst_texture.ref_resource});
                }
            }
        }

        mesh_offset += scn.mesh_count;
        material_offset += scn.material_count;
        texture_offset += scn.texture_count;
    }

    manager.combined_scene.mesh_count = total_meshes;
    manager.combined_scene.material_count = total_materials;
    manager.combined_scene.texture_count = total_textures;
    manager.scene_dirty = false;

    log.cardinal_log_debug("Rebuilt combined scene: {d} meshes, {d} materials, {d} textures", .{ total_meshes, total_materials, total_textures });
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

// --- Public API ---

pub export fn cardinal_model_manager_init(manager: ?*CardinalModelManager) callconv(.c) bool {
    if (manager == null) return false;
    const mgr = manager.?;

    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(CardinalModelManager)], 0);
    mgr.next_id = 1;
    mgr.scene_dirty = true;

    log.cardinal_log_debug("Model manager initialized", .{});
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
    scene.cardinal_scene_destroy(&mgr.combined_scene);

    @memset(@as([*]u8, @ptrCast(mgr))[0..@sizeOf(CardinalModelManager)], 0);
    log.cardinal_log_debug("Model manager destroyed", .{});
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
            log.cardinal_log_error("Failed to wait for model load task for {s}", .{file_path.?});
            _ = cardinal_model_manager_remove_model(manager, id);
            return 0;
        }

        const status = async_loader.cardinal_async_get_task_status(task);
        if (status == .COMPLETED) {
            // Finalize the model (logic duplicated from update loop)
            var success = false;
            if (task.type == .CUSTOM) {
                if (task.result_data) |result_ptr| {
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
                    log.cardinal_log_info("Synchronous (via Async) loading completed for model '{s}' (ID: {d}, {d} meshes)", .{ model_name_str, model.?.id, model.?.scene.mesh_count });
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
            log.cardinal_log_error("Model load failed: {s}", .{err_str});

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
        log.cardinal_log_error("Failed to start async loading for {s}", .{file_path.?});
        if (model.name) |n| memory.cardinal_free(allocator, @ptrCast(n));
        if (model.file_path) |p| memory.cardinal_free(allocator, @ptrCast(p));
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
    const finalize_task = async_loader.cardinal_async_submit_custom_task(finalize_model_task, ctx, @enumFromInt(priority), null, null);
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
        log.cardinal_log_error("Failed to add task dependency", .{});
        // Cleanup is tricky here since tasks are submitted.
        // But since we just submitted them, they might be pending.
        // We'll let them run (and fail/leak?) or try to cancel.
        // For robustness, we assume add_dependency works if tasks are fresh.
    }

    model.load_task = finalize_task;

    mgr.model_count += 1;

    const model_name_str = if (model.name) |n| n else "Unnamed";
    log.cardinal_log_info("Started async loading of model '{s}' from {s} (ID: {d}) with dependency chain", .{ model_name_str, file_path.?, model.id });

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

    calculate_scene_bounds(&model.scene, &model.bbox_min, &model.bbox_max);

    mgr.model_count += 1;
    mgr.scene_dirty = true;

    const model_name_str = if (model.name) |n| n else "Unnamed";
    log.cardinal_log_info("Added scene '{s}' to model manager (ID: {d}, {d} meshes)", .{ model_name_str, model.id, model.scene.mesh_count });

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
    log.cardinal_log_info("Removing model '{s}' (ID: {d})", .{ model_name_str, model_id });

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
                            log.cardinal_log_info("Async loading chain completed for model '{s}' (ID: {d}, {d} meshes)", .{ model_name_str, model.id, model.scene.mesh_count });
                        } else {
                            log.cardinal_log_error("Finalize task completed but no result data found", .{});
                            success = false;
                        }
                    } else if (async_loader.cardinal_async_get_scene_result(task, &model.scene)) {
                        // Direct scene load task
                        calculate_scene_bounds(&model.scene, &model.bbox_min, &model.bbox_max);
                        model.is_loading = false;
                        mgr.scene_dirty = true;

                        const model_name_str = if (model.name) |n| n else "Unnamed";
                        log.cardinal_log_info("Async loading completed for model '{s}' (ID: {d}, {d} meshes)", .{ model_name_str, model.id, model.scene.mesh_count });
                        success = true;
                    }

                    if (!success) {
                        const model_name_str = if (model.name) |n| n else "Unnamed";
                        log.cardinal_log_error("Failed to get scene result for model '{s}'", .{model_name_str});
                    }

                    free_model_load_task(model.load_task.?);
                    model.load_task = null;
                } else if (status == .FAILED) {
                    const error_msg = async_loader.cardinal_async_get_error_message(model.load_task.?);
                    const model_name_str = if (model.name) |n| n else "Unnamed";
                    const err_str = if (error_msg) |e| e else "Unknown error";
                    log.cardinal_log_error("Async loading failed for model '{s}': {s}", .{ model_name_str, err_str });

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

    log.cardinal_log_info("Clearing all models from manager", .{});

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
