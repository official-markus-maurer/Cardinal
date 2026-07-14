pub const std = @import("std");
pub const engine = @import("cardinal_engine");

pub const editor_state = @import("../../editor_state.zig");
pub const EditorState = editor_state.EditorState;
pub const VolumetricTerrainData = editor_state.VolumetricTerrainData;
pub const VolumetricDirtyBox = editor_state.VolumetricDirtyBox;
pub const VolumetricSplatDirtyRect = editor_state.VolumetricSplatDirtyRect;
pub const VolumetricBrickKey = editor_state.VolumetricBrickKey;
pub const VolumetricDensitySnapshotKey = editor_state.VolumetricDensitySnapshotKey;
pub const VolumetricDensitySnapshot = editor_state.VolumetricDensitySnapshot;
pub const MeshCapacity = editor_state.MeshCapacity;

pub const memory = engine.memory;
pub const async_loader = engine.async_loader;
pub const renderer = engine.vulkan_renderer;
pub const components = engine.ecs_components;
pub const node_factory = engine.ecs_node_factory;
pub const math = engine.math;
pub const model_manager = engine.model_manager;
pub const scene = engine.scene;

pub const vk = @import("../../c.zig").c;

pub const lod_level_count: u32 = 3;
pub const all_lods_mask: u8 = (@as(u8, 1) << @intCast(lod_level_count)) - 1;
pub const iso_epsilon: f32 = 1e-6;
pub const brick_cells_base: u32 = 32;
pub const max_brick_tasks_in_flight: u32 = 8;
pub const max_brick_tasks_to_schedule_per_update: u32 = 4;

pub const CellRange = struct {
    min: u32,
    max: u32,
};

pub fn lod_bit(lod: u32) u8 {
    return @as(u8, 1) << @intCast(lod);
}

pub fn sign_inside(d: f32) bool {
    return d <= iso_epsilon;
}

pub fn density_index(dims: u32, x: u32, y: u32, z: u32) usize {
    return (@as(usize, z) * @as(usize, dims) + @as(usize, y)) * @as(usize, dims) + @as(usize, x);
}

pub fn splat_offset(dims: u32, x: u32, y: u32, z: u32) usize {
    return density_index(dims, x, y, z) * 4;
}

pub fn sample_splat_slice(splat: []const u8, dims: u32, x: u32, y: u32, z: u32) u32 {
    const o = splat_offset(dims, x, y, z);
    return @as(u32, splat[o + 0]) | (@as(u32, splat[o + 1]) << 8) | (@as(u32, splat[o + 2]) << 16) | (@as(u32, splat[o + 3]) << 24);
}

pub fn sample_lod_splat(splat: []const u8, base_dims: u32, base_step: u32, x: u32, y: u32, z: u32) u32 {
    const bx = x * base_step;
    const by = y * base_step;
    const bz = z * base_step;
    return sample_splat_slice(splat, base_dims, bx, by, bz);
}

pub fn enforce_density_padding_shell(td: *VolumetricTerrainData) void {
    if (td.dims < 2) return;
    const last: i32 = @intCast(td.dims - 1);
    const pad: i32 = 1;

    const dims: u32 = td.dims;
    const last_u: u32 = @intCast(last);
    const pad_u: u32 = @intCast(pad);

    var z: u32 = 0;
    while (z < dims) : (z += 1) {
        var y: u32 = 0;
        while (y < dims) : (y += 1) {
            var x: u32 = 0;
            while (x <= pad_u and x < dims) : (x += 1) {
                const idx = density_index(dims, x, y, z);
                td.density[idx] = @max(td.density[idx], iso_epsilon);
            }
            if (last_u >= pad_u) {
                x = last_u - pad_u;
                while (x <= last_u and x < dims) : (x += 1) {
                    const idx = density_index(dims, x, y, z);
                    td.density[idx] = @max(td.density[idx], iso_epsilon);
                }
            }
        }
    }

    var y_face: u32 = 0;
    while (y_face <= pad_u and y_face < dims) : (y_face += 1) {
        z = 0;
        while (z < dims) : (z += 1) {
            var x: u32 = 0;
            while (x < dims) : (x += 1) {
                const idx = density_index(dims, x, y_face, z);
                td.density[idx] = @max(td.density[idx], iso_epsilon);
            }
        }
    }
    if (last_u >= pad_u) {
        y_face = last_u - pad_u;
        while (y_face <= last_u and y_face < dims) : (y_face += 1) {
            z = 0;
            while (z < dims) : (z += 1) {
                var x: u32 = 0;
                while (x < dims) : (x += 1) {
                    const idx = density_index(dims, x, y_face, z);
                    td.density[idx] = @max(td.density[idx], iso_epsilon);
                }
            }
        }
    }

    var z_face: u32 = 0;
    while (z_face <= pad_u and z_face < dims) : (z_face += 1) {
        var y: u32 = 0;
        while (y < dims) : (y += 1) {
            var x: u32 = 0;
            while (x < dims) : (x += 1) {
                const idx = density_index(dims, x, y, z_face);
                td.density[idx] = @max(td.density[idx], iso_epsilon);
            }
        }
    }
    if (last_u >= pad_u) {
        z_face = last_u - pad_u;
        while (z_face <= last_u and z_face < dims) : (z_face += 1) {
            var y: u32 = 0;
            while (y < dims) : (y += 1) {
                var x: u32 = 0;
                while (x < dims) : (x += 1) {
                    const idx = density_index(dims, x, y, z_face);
                    td.density[idx] = @max(td.density[idx], iso_epsilon);
                }
            }
        }
    }
}

pub fn ensure_data_id(vt: *components.VolumetricTerrain) void {
    if (vt.data_id == 0) vt.data_id = std.crypto.random.int(u64);
}

pub fn lod_resolution(base_resolution: u32, lod: u32) u32 {
    const r = if (base_resolution < 1) 1 else base_resolution;
    const step: u32 = @as(u32, 1) << @intCast(@min(lod, 30));
    const res = r / step;
    return if (res < 1) 1 else res;
}

pub fn dc_max_vertex_capacity(resolution: u32) u32 {
    const r = if (resolution < 1) 1 else resolution;
    const cubes: u64 = @as(u64, r) * @as(u64, r) * @as(u64, r);
    return if (cubes > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(cubes);
}

pub fn dc_max_index_capacity(resolution: u32) u32 {
    const r = if (resolution < 1) 1 else resolution;
    const rp1: u64 = @as(u64, r) + 1;
    const idx: u64 = 18 * @as(u64, r) * rp1 * rp1;
    return if (idx > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(idx);
}

pub fn brick_axis_count(base_res: u32) u32 {
    const r = if (base_res < 1) 1 else base_res;
    return (r + brick_cells_base - 1) / brick_cells_base;
}

pub fn brick_count(base_res: u32) u32 {
    const a = brick_axis_count(base_res);
    return a * a * a;
}

pub fn brick_id_to_coords(axis: u32, brick_id: u32) struct { bx: u32, by: u32, bz: u32 } {
    if (axis == 0) return .{ .bx = 0, .by = 0, .bz = 0 };
    const a2 = axis * axis;
    const bz = brick_id / a2;
    const rem = brick_id - bz * a2;
    const by = rem / axis;
    const bx = rem - by * axis;
    return .{ .bx = bx, .by = by, .bz = bz };
}

pub fn brick_cells_for_lod(lod: u32) u32 {
    const s: u32 = @as(u32, 1) << @intCast(@min(lod, 30));
    const v = brick_cells_base / s;
    return if (v < 1) 1 else v;
}

pub fn brick_cell_range_for_axis(res_lod: u32, lod: u32, axis: u32, brick_axis: u32) ?CellRange {
    if (axis == 0) return null;
    const cells = brick_cells_for_lod(lod);
    const start = brick_axis * cells;
    if (start >= res_lod) return null;
    const end_excl = @min(res_lod, start + cells);
    if (end_excl == 0) return null;
    return CellRange{ .min = start, .max = end_excl - 1 };
}

pub fn init_density_plane(dims: u32, size: math.Vec3, density: []f32) void {
    if (dims < 2) return;
    const res: u32 = dims - 1;
    const step = math.Vec3{
        .x = size.x / @as(f32, @floatFromInt(res)),
        .y = size.y / @as(f32, @floatFromInt(res)),
        .z = size.z / @as(f32, @floatFromInt(res)),
    };
    const half = size.mul(0.5);

    var z: u32 = 0;
    while (z < dims) : (z += 1) {
        var y: u32 = 0;
        while (y < dims) : (y += 1) {
            var x: u32 = 0;
            while (x < dims) : (x += 1) {
                const px = -half.x + step.x * @as(f32, @floatFromInt(x));
                const py = -half.y + step.y * @as(f32, @floatFromInt(y));
                const pz = -half.z + step.z * @as(f32, @floatFromInt(z));

                const ax = @abs(px) - half.x;
                const ay = @abs(py) - half.y;
                const az = @abs(pz) - half.z;
                const box_sdf = @max(ax, @max(ay, az));

                const halfspace_sdf = py;
                const sdf = @max(box_sdf, halfspace_sdf);
                density[density_index(dims, x, y, z)] = sdf;
            }
        }
    }
}

pub fn sample_density(td: *VolumetricTerrainData, x: u32, y: u32, z: u32) f32 {
    return td.density[density_index(td.dims, x, y, z)];
}
