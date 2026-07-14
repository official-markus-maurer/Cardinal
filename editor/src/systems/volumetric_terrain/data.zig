const C = @import("common.zig");
const Gpu = @import("gpu.zig");

const std = C.std;
const engine = C.engine;
const EditorState = C.EditorState;
const VolumetricTerrainData = C.VolumetricTerrainData;
const memory = C.memory;
const renderer = C.renderer;
const components = C.components;

pub fn ensure_volumetric_terrain_data_for_entity(state: *EditorState, entity: engine.ecs_entity.Entity) ?*VolumetricTerrainData {
    if (!state.runtime.registry.entity_manager.is_alive(entity)) return null;
    const vt = state.runtime.registry.get(components.VolumetricTerrain, entity) orelse return null;

    const dims: u32 = (if (vt.resolution < 1) 1 else vt.resolution) + 1;
    const want_len: usize = @as(usize, dims) * @as(usize, dims) * @as(usize, dims);

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    if (state.runtime.volumetric_terrain_data_by_entity.getPtr(entity.id)) |existing| {
        if (existing.dims == dims and existing.density.len == want_len) {
            if (state.runtime.registry.get(components.VolumetricTerrain, entity)) |vt_mut| {
                C.ensure_data_id(vt_mut);
                Gpu.ensure_volumetric_material_bound(state, vt_mut, existing);
            }
            return existing;
        }
        alloc.free(existing.density);
        alloc.free(existing.splat);
        if (existing.splat_handle != std.math.maxInt(u32)) {
            renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, existing.splat_handle);
            existing.splat_handle = std.math.maxInt(u32);
        }
        for (existing.layer_handles, 0..) |h, i| {
            if (h != std.math.maxInt(u32)) {
                renderer.cardinal_renderer_runtime_texture_free(state.runtime.renderer, h);
                existing.layer_handles[i] = std.math.maxInt(u32);
            }
        }
        _ = state.runtime.volumetric_terrain_data_by_entity.remove(entity.id);
    }

    const density = alloc.alloc(f32, want_len) catch return null;
    const splat = alloc.alloc(u8, want_len * 4) catch {
        alloc.free(density);
        return null;
    };
    C.init_density_plane(dims, vt.size, density);
    {
        var i: usize = 0;
        while (i < want_len) : (i += 1) {
            const o = i * 4;
            splat[o + 0] = 255;
            splat[o + 1] = 0;
            splat[o + 2] = 0;
            splat[o + 3] = 0;
        }
    }
    state.runtime.volumetric_terrain_data_by_entity.put(alloc, entity.id, .{
        .dims = dims,
        .density = density,
        .splat = splat,
        .splat_handle = std.math.maxInt(u32),
        .layer_handles = .{
            std.math.maxInt(u32),
            std.math.maxInt(u32),
            std.math.maxInt(u32),
            std.math.maxInt(u32),
        },
    }) catch {
        alloc.free(density);
        alloc.free(splat);
        return null;
    };
    const out = state.runtime.volumetric_terrain_data_by_entity.getPtr(entity.id) orelse return null;
    if (state.runtime.registry.get(components.VolumetricTerrain, entity)) |vt_mut| {
        C.ensure_data_id(vt_mut);
        Gpu.ensure_volumetric_material_bound(state, vt_mut, out);
    }
    return out;
}

