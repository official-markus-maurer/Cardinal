const C = @import("common.zig");

const std = C.std;
const EditorState = C.EditorState;
const VolumetricDirtyBox = C.VolumetricDirtyBox;
const VolumetricBrickKey = C.VolumetricBrickKey;
const memory = C.memory;
const async_loader = C.async_loader;

pub fn empty_dirty_box() VolumetricDirtyBox {
    return .{
        .min_x = std.math.maxInt(u32),
        .min_y = std.math.maxInt(u32),
        .min_z = std.math.maxInt(u32),
        .max_x = 0,
        .max_y = 0,
        .max_z = 0,
    };
}

pub fn dirty_box_is_valid(b: VolumetricDirtyBox) bool {
    return b.min_x <= b.max_x and b.min_y <= b.max_y and b.min_z <= b.max_z;
}

pub fn dirty_union(a: VolumetricDirtyBox, b: VolumetricDirtyBox) VolumetricDirtyBox {
    if (!dirty_box_is_valid(a)) return b;
    if (!dirty_box_is_valid(b)) return a;
    return .{
        .min_x = @min(a.min_x, b.min_x),
        .min_y = @min(a.min_y, b.min_y),
        .min_z = @min(a.min_z, b.min_z),
        .max_x = @max(a.max_x, b.max_x),
        .max_y = @max(a.max_y, b.max_y),
        .max_z = @max(a.max_z, b.max_z),
    };
}

pub fn mark_dirty_cells(state: *EditorState, entity_id: u64, box: VolumetricDirtyBox) void {
    mark_dirty_cells_masked(state, entity_id, box, C.all_lods_mask);
}

pub fn mark_dirty_cells_masked(state: *EditorState, entity_id: u64, box: VolumetricDirtyBox, lod_mask: u8) void {
    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    if (state.runtime.volumetric_dirty_boxes.getPtr(entity_id)) |existing| {
        existing.* = dirty_union(existing.*, box);
    } else {
        state.runtime.volumetric_dirty_boxes.put(alloc, entity_id, box) catch {};
    }

    if (state.runtime.volumetric_dirty_lod_masks.getPtr(entity_id)) |existing_mask| {
        existing_mask.* |= lod_mask;
        return;
    }
    state.runtime.volumetric_dirty_lod_masks.put(alloc, entity_id, lod_mask) catch {};
}

pub fn mark_dirty_bricks_masked(state: *EditorState, entity_id: u64, box: VolumetricDirtyBox, lod_mask: u8, base_res: u32) void {
    const axis = C.brick_axis_count(base_res);
    if (axis == 0) return;

    const bx0 = @min(axis - 1, box.min_x / C.brick_cells_base);
    const by0 = @min(axis - 1, box.min_y / C.brick_cells_base);
    const bz0 = @min(axis - 1, box.min_z / C.brick_cells_base);
    const bx1 = @min(axis - 1, box.max_x / C.brick_cells_base);
    const by1 = @min(axis - 1, box.max_y / C.brick_cells_base);
    const bz1 = @min(axis - 1, box.max_z / C.brick_cells_base);

    const alloc = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    var bz: u32 = bz0;
    while (bz <= bz1) : (bz += 1) {
        var by: u32 = by0;
        while (by <= by1) : (by += 1) {
            var bx: u32 = bx0;
            while (bx <= bx1) : (bx += 1) {
                const id: u32 = (bz * axis + by) * axis + bx;
                const key = VolumetricBrickKey{ .entity_id = entity_id, .brick_id = id };
                if (state.runtime.volumetric_dirty_brick_boxes.getPtr(key)) |existing| {
                    existing.* = dirty_union(existing.*, box);
                } else {
                    state.runtime.volumetric_dirty_brick_boxes.put(alloc, key, box) catch {};
                }
                if (state.runtime.volumetric_dirty_brick_lod_masks.getPtr(key)) |m| {
                    m.* |= lod_mask;
                } else {
                    state.runtime.volumetric_dirty_brick_lod_masks.put(alloc, key, lod_mask) catch {};
                }

                if (state.runtime.volumetric_brick_generation.getPtr(key)) |g| {
                    g.* +%= 1;
                } else {
                    state.runtime.volumetric_brick_generation.put(alloc, key, 1) catch {};
                }

                if (state.runtime.volumetric_brick_remesh_tasks.get(key)) |t| {
                    const status = async_loader.cardinal_async_get_task_status(t);
                    if (status == .PENDING) {
                        _ = async_loader.cardinal_async_cancel_task(t);
                        async_loader.cardinal_async_free_task(t);
                        _ = state.runtime.volumetric_brick_remesh_tasks.remove(key);
                    }
                }
            }
        }
    }
}

