const C = @import("common.zig");

const std = C.std;
const math = C.math;
const EditorState = C.EditorState;

pub const StreamingHooks = struct {
    on_chunk_visibility_changed: ?*const fn (state: *EditorState, entity_id: u64, visible: bool) void = null,
};

pub const StreamingConfig = struct {
    enable: bool = true,
    enable_frustum_culling: bool = true,
    unload_distance_multiplier: f32 = 10.0,
    lod0_distance_multiplier: f32 = 2.0,
    lod1_distance_multiplier: f32 = 5.0,
    lod_hysteresis: f32 = 0.15,
    crack_free_lod: bool = false,
};

pub var g_streaming_hooks: StreamingHooks = .{};
pub var streaming_config: StreamingConfig = .{};

pub fn set_streaming_hooks(hooks: StreamingHooks) void {
    g_streaming_hooks = hooks;
}

pub fn sphere_intersects_aabb(center: math.Vec3, radius: f32, aabb_min: math.Vec3, aabb_max: math.Vec3) bool {
    var d2: f32 = 0.0;
    const c = [3]f32{ center.x, center.y, center.z };
    const mn = [3]f32{ aabb_min.x, aabb_min.y, aabb_min.z };
    const mx = [3]f32{ aabb_max.x, aabb_max.y, aabb_max.z };
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const v = c[i];
        if (v < mn[i]) {
            const diff = mn[i] - v;
            d2 += diff * diff;
        } else if (v > mx[i]) {
            const diff = v - mx[i];
            d2 += diff * diff;
        }
    }
    return d2 <= radius * radius;
}

pub fn compute_desired_lod_hysteresis(state: *EditorState, ent: C.engine.ecs_entity.Entity, vt: *const C.components.VolumetricTerrain, tr: *const C.components.Transform) u32 {
    const dist = tr.position.sub(state.runtime.camera.position).length();
    const base_size = @max(vt.size.x, @max(vt.size.y, vt.size.z));
    const d0 = base_size * streaming_config.lod0_distance_multiplier;
    const d1 = base_size * streaming_config.lod1_distance_multiplier;
    const h = std.math.clamp(streaming_config.lod_hysteresis, 0.0, 0.45);

    if (state.ui.terrain_sculpt_enabled and state.runtime.registry.entity_manager.is_alive(state.ui.selected_entity) and state.ui.selected_entity.id == ent.id) {
        return 0;
    }

    const prev: u32 = state.runtime.volumetric_lod_by_entity.get(ent.id) orelse 0;

    var lod: u32 = prev;
    switch (prev) {
        0 => {
            lod = if (dist > d0 * (1.0 + h)) 1 else 0;
        },
        1 => {
            if (dist < d0 * (1.0 - h)) {
                lod = 0;
            } else if (dist > d1 * (1.0 + h)) {
                lod = 2;
            } else {
                lod = 1;
            }
        },
        else => {
            lod = if (dist < d1 * (1.0 - h)) 1 else 2;
        },
    }

    if (lod >= C.lod_level_count) lod = C.lod_level_count - 1;
    return lod;
}

