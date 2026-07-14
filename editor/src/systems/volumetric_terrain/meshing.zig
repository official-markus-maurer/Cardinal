const C = @import("common.zig");

const std = C.std;
const math = C.math;
const scene = C.scene;
const VolumetricDirtyBox = C.VolumetricDirtyBox;

const iso_epsilon = C.iso_epsilon;
const lod_resolution = C.lod_resolution;
const sign_inside = C.sign_inside;
const brick_id_to_coords = C.brick_id_to_coords;
const brick_cell_range_for_axis = C.brick_cell_range_for_axis;
const sample_lod_splat = C.sample_lod_splat;

pub const BrickRemeshOutput = struct {
    has_update: bool = false,
    vertices: []scene.CardinalVertex = @constCast(&[_]scene.CardinalVertex{}),
    indices: []u32 = @constCast(&[_]u32{}),
    vertex_count: u32 = 0,
    index_count: u32 = 0,
};

pub fn write_vertex(out: [*]scene.CardinalVertex, idx: u32, p: math.Vec3, n: math.Vec3) void {
    out[idx] = std.mem.zeroes(scene.CardinalVertex);
    out[idx].px = p.x;
    out[idx].py = p.y;
    out[idx].pz = p.z;
    out[idx].nx = n.x;
    out[idx].ny = n.y;
    out[idx].nz = n.z;
    out[idx].u = 0.0;
    out[idx].v = 0.0;
    out[idx].u1 = 0.0;
    out[idx].v1 = 0.0;
    out[idx].bone_weights = .{ 0.0, 0.0, 0.0, 0.0 };
    out[idx].bone_indices = .{ 0, 0, 0, 0 };
    const up = std.math.clamp((n.y + 1.0) * 0.5, 0.0, 1.0);
    const grass_w = std.math.clamp((up - 0.35) / 0.35, 0.0, 1.0);
    const h = std.math.clamp((p.y + 32.0) / 64.0, 0.0, 1.0);

    const rock = [4]f32{ 0.45, 0.45, 0.48, 1.0 };
    const grass = [4]f32{ 0.22, 0.55, 0.24, 1.0 };
    const mid = [4]f32{
        rock[0] + (grass[0] - rock[0]) * grass_w,
        rock[1] + (grass[1] - rock[1]) * grass_w,
        rock[2] + (grass[2] - rock[2]) * grass_w,
        1.0,
    };

    const snow = [4]f32{ 0.85, 0.86, 0.9, 1.0 };
    const snow_w = std.math.clamp((h - 0.75) / 0.2, 0.0, 1.0);
    out[idx].color = .{
        mid[0] + (snow[0] - mid[0]) * snow_w,
        mid[1] + (snow[1] - mid[1]) * snow_w,
        mid[2] + (snow[2] - mid[2]) * snow_w,
        1.0,
    };
}

pub fn write_vertex_with_color(out: [*]scene.CardinalVertex, idx: u32, p: math.Vec3, n: math.Vec3, color: [4]f32, size: math.Vec3) void {
    out[idx] = std.mem.zeroes(scene.CardinalVertex);
    out[idx].px = p.x;
    out[idx].py = p.y;
    out[idx].pz = p.z;
    out[idx].nx = n.x;
    out[idx].ny = n.y;
    out[idx].nz = n.z;
    out[idx].u = (p.x / size.x) + 0.5;
    out[idx].v = (p.z / size.z) + 0.5;
    out[idx].u1 = out[idx].u;
    out[idx].v1 = out[idx].v;
    out[idx].bone_weights = .{ 0.0, 0.0, 0.0, 0.0 };
    out[idx].bone_indices = .{ 0, 0, 0, 0 };
    out[idx].color = .{ color[0], color[1], color[2], color[3] };
}

fn density_index(dims: u32, x: u32, y: u32, z: u32) usize {
    return C.density_index(dims, x, y, z);
}

fn sample_density_slice(density: []const f32, dims: u32, x: u32, y: u32, z: u32) f32 {
    return density[density_index(dims, x, y, z)];
}

fn sample_density_slice_clamped(density: []const f32, dims: u32, x: i32, y: i32, z: i32) f32 {
    const mx: i32 = @intCast(dims - 1);
    const cx: u32 = @intCast(std.math.clamp(x, 0, mx));
    const cy: u32 = @intCast(std.math.clamp(y, 0, mx));
    const cz: u32 = @intCast(std.math.clamp(z, 0, mx));
    return sample_density_slice(density, dims, cx, cy, cz);
}

fn sample_lod_density(density: []const f32, base_dims: u32, base_step: u32, x: u32, y: u32, z: u32) f32 {
    const bx = x * base_step;
    const by = y * base_step;
    const bz = z * base_step;
    return sample_density_slice(density, base_dims, bx, by, bz);
}

fn gradient_at_lod_sample(density: []const f32, base_dims: u32, base_step: u32, x: u32, y: u32, z: u32) math.Vec3 {
    const bx: i32 = @intCast(x * base_step);
    const by: i32 = @intCast(y * base_step);
    const bz: i32 = @intCast(z * base_step);
    const max_i: i32 = @intCast(base_dims - 1);

    const c = sample_density_slice_clamped(density, base_dims, bx, by, bz);

    const dx = if (bx <= 0)
        sample_density_slice_clamped(density, base_dims, bx + 1, by, bz) - c
    else if (bx >= max_i)
        c - sample_density_slice_clamped(density, base_dims, bx - 1, by, bz)
    else
        sample_density_slice_clamped(density, base_dims, bx + 1, by, bz) - sample_density_slice_clamped(density, base_dims, bx - 1, by, bz);

    const dy = if (by <= 0)
        sample_density_slice_clamped(density, base_dims, bx, by + 1, bz) - c
    else if (by >= max_i)
        c - sample_density_slice_clamped(density, base_dims, bx, by - 1, bz)
    else
        sample_density_slice_clamped(density, base_dims, bx, by + 1, bz) - sample_density_slice_clamped(density, base_dims, bx, by - 1, bz);

    const dz = if (bz <= 0)
        sample_density_slice_clamped(density, base_dims, bx, by, bz + 1) - c
    else if (bz >= max_i)
        c - sample_density_slice_clamped(density, base_dims, bx, by, bz - 1)
    else
        sample_density_slice_clamped(density, base_dims, bx, by, bz + 1) - sample_density_slice_clamped(density, base_dims, bx, by, bz - 1);

    const g = math.Vec3{ .x = dx, .y = dy, .z = dz };
    const len = g.length();
    return if (len > 0.000001) g.mul(1.0 / len) else math.Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
}

fn alloc_lod_scratch(alloc: std.mem.Allocator, base_density: []const f32, base_dims: u32, base_res: u32, lod: u32) ?struct {
    block: []u8,
    density: []f32,
    gradient: []math.Vec3,
    dims: u32,
    res: u32,
    cell_to_vert: []u32,
} {
    const res_lod: u32 = lod_resolution(base_res, lod);
    const dims_lod: u32 = res_lod + 1;
    const count: usize = @as(usize, dims_lod) * @as(usize, dims_lod) * @as(usize, dims_lod);
    const cell_count: usize = @as(usize, res_lod) * @as(usize, res_lod) * @as(usize, res_lod);

    const a_f32 = @alignOf(f32);
    const a_vec3 = @alignOf(math.Vec3);
    const a_u32 = @alignOf(u32);

    var bytes: usize = 0;
    bytes = std.mem.alignForward(usize, bytes, a_f32);
    bytes += count * @sizeOf(f32);
    bytes = std.mem.alignForward(usize, bytes, a_vec3);
    bytes += count * @sizeOf(math.Vec3);
    bytes = std.mem.alignForward(usize, bytes, a_u32);
    bytes += cell_count * @sizeOf(u32);

    const block = alloc.alloc(u8, bytes) catch return null;
    errdefer alloc.free(block);

    var off: usize = 0;
    off = std.mem.alignForward(usize, off, a_f32);
    const density_ptr: [*]f32 = @ptrCast(@alignCast(block.ptr + off));
    const density_grid: []f32 = density_ptr[0..count];
    off += count * @sizeOf(f32);

    off = std.mem.alignForward(usize, off, a_vec3);
    const grad_ptr: [*]math.Vec3 = @ptrCast(@alignCast(block.ptr + off));
    const grad_grid: []math.Vec3 = grad_ptr[0..count];
    off += count * @sizeOf(math.Vec3);

    off = std.mem.alignForward(usize, off, a_u32);
    const c2v_ptr: [*]u32 = @ptrCast(@alignCast(block.ptr + off));
    const cell_to_vert: []u32 = c2v_ptr[0..cell_count];
    @memset(cell_to_vert, std.math.maxInt(u32));

    const base_step: u32 = @as(u32, 1) << @intCast(@min(lod, 30));

    var z: u32 = 0;
    while (z < dims_lod) : (z += 1) {
        var y: u32 = 0;
        while (y < dims_lod) : (y += 1) {
            var x: u32 = 0;
            while (x < dims_lod) : (x += 1) {
                density_grid[density_index(dims_lod, x, y, z)] = sample_lod_density(base_density, base_dims, base_step, x, y, z);
            }
        }
    }

    z = 0;
    while (z < dims_lod) : (z += 1) {
        var y: u32 = 0;
        while (y < dims_lod) : (y += 1) {
            var x: u32 = 0;
            while (x < dims_lod) : (x += 1) {
                grad_grid[density_index(dims_lod, x, y, z)] = gradient_at_lod_sample(base_density, base_dims, base_step, x, y, z);
            }
        }
    }

    return .{
        .block = block,
        .density = density_grid,
        .gradient = grad_grid,
        .dims = dims_lod,
        .res = res_lod,
        .cell_to_vert = cell_to_vert,
    };
}

fn solve_3x3(a_in: [3][3]f32, b_in: [3]f32) ?[3]f32 {
    var a = a_in;
    var b = b_in;

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var pivot = i;
        var max_abs: f32 = @abs(a[i][i]);
        var r: usize = i + 1;
        while (r < 3) : (r += 1) {
            const v = @abs(a[r][i]);
            if (v > max_abs) {
                max_abs = v;
                pivot = r;
            }
        }
        if (max_abs < 1e-9) return null;
        if (pivot != i) {
            const tmp_row = a[i];
            a[i] = a[pivot];
            a[pivot] = tmp_row;
            const tmp_b = b[i];
            b[i] = b[pivot];
            b[pivot] = tmp_b;
        }

        const inv = 1.0 / a[i][i];
        a[i][i] = 1.0;
        a[i][0] *= inv;
        a[i][1] *= inv;
        a[i][2] *= inv;
        b[i] *= inv;

        r = 0;
        while (r < 3) : (r += 1) {
            if (r == i) continue;
            const f = a[r][i];
            if (@abs(f) < 1e-9) continue;
            a[r][i] = 0.0;
            a[r][0] -= f * a[i][0];
            a[r][1] -= f * a[i][1];
            a[r][2] -= f * a[i][2];
            b[r] -= f * b[i];
        }
    }

    return .{ b[0], b[1], b[2] };
}

fn qef_solve_position(ata: [3][3]f32, atb: [3]f32, fallback: math.Vec3) math.Vec3 {
    const sol = solve_3x3(ata, atb);
    if (sol) |s| {
        return math.Vec3{ .x = s[0], .y = s[1], .z = s[2] };
    }
    return fallback;
}

fn emit_quad(inds_out: [*]u32, i_count: *u32, a: u32, b: u32, c: u32, d: u32, flip: bool) void {
    if (flip) {
        inds_out[i_count.* + 0] = a;
        inds_out[i_count.* + 1] = c;
        inds_out[i_count.* + 2] = b;
        inds_out[i_count.* + 3] = a;
        inds_out[i_count.* + 4] = d;
        inds_out[i_count.* + 5] = c;
    } else {
        inds_out[i_count.* + 0] = a;
        inds_out[i_count.* + 1] = b;
        inds_out[i_count.* + 2] = c;
        inds_out[i_count.* + 3] = a;
        inds_out[i_count.* + 4] = c;
        inds_out[i_count.* + 5] = d;
    }
    i_count.* += 6;
}

fn cell_linear_index(res: u32, x: u32, y: u32, z: u32) usize {
    return (@as(usize, z) * @as(usize, res) + @as(usize, y)) * @as(usize, res) + @as(usize, x);
}

fn dual_contour_mesh(
    density: []const f32,
    gradient: []const math.Vec3,
    dims: u32,
    res: u32,
    size: math.Vec3,
    verts_out: [*]scene.CardinalVertex,
    inds_out: [*]u32,
    v_count: *u32,
    i_count: *u32,
    cell_to_vert: []u32,
) bool {
    if (res < 1) return true;
    const half = size.mul(0.5);
    const step = math.Vec3{
        .x = size.x / @as(f32, @floatFromInt(res)),
        .y = size.y / @as(f32, @floatFromInt(res)),
        .z = size.z / @as(f32, @floatFromInt(res)),
    };

    const corner = [_][3]u32{
        .{ 0, 0, 0 },
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 1, 1, 0 },
        .{ 0, 0, 1 },
        .{ 1, 0, 1 },
        .{ 0, 1, 1 },
        .{ 1, 1, 1 },
    };

    var z: u32 = 0;
    while (z < res) : (z += 1) {
        var y: u32 = 0;
        while (y < res) : (y += 1) {
            var x: u32 = 0;
            while (x < res) : (x += 1) {
                var mask: u8 = 0;
                var ci: usize = 0;
                while (ci < 8) : (ci += 1) {
                    const sx = x + corner[ci][0];
                    const sy = y + corner[ci][1];
                    const sz = z + corner[ci][2];
                    const d = density[density_index(dims, sx, sy, sz)];
                    if (sign_inside(d)) mask |= @as(u8, 1) << @intCast(ci);
                }
                if (mask == 0 or mask == 0xFF) continue;

                const cell_min = math.Vec3{
                    .x = -half.x + step.x * @as(f32, @floatFromInt(x)),
                    .y = -half.y + step.y * @as(f32, @floatFromInt(y)),
                    .z = -half.z + step.z * @as(f32, @floatFromInt(z)),
                };

                var ata: [3][3]f32 = .{ .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0 } };
                var atb: [3]f32 = .{ 0.0, 0.0, 0.0 };
                var n_sum = math.Vec3{ .x = 0.0, .y = 0.0, .z = 0.0 };

                const edge = [_][2]u8{
                    .{ 0, 1 },
                    .{ 0, 2 },
                    .{ 1, 3 },
                    .{ 2, 3 },
                    .{ 4, 5 },
                    .{ 4, 6 },
                    .{ 5, 7 },
                    .{ 6, 7 },
                    .{ 0, 4 },
                    .{ 1, 5 },
                    .{ 2, 6 },
                    .{ 3, 7 },
                };

                var edge_count: u32 = 0;
                var e: usize = 0;
                while (e < edge.len) : (e += 1) {
                    const c0 = edge[e][0];
                    const c1 = edge[e][1];
                    const inside0 = ((mask >> @intCast(c0)) & 1) != 0;
                    const inside1 = ((mask >> @intCast(c1)) & 1) != 0;
                    if (inside0 == inside1) continue;

                    const ax = x + corner[c0][0];
                    const ay = y + corner[c0][1];
                    const az = z + corner[c0][2];
                    const bx = x + corner[c1][0];
                    const by = y + corner[c1][1];
                    const bz = z + corner[c1][2];
                    const d0 = density[density_index(dims, ax, ay, az)];
                    const d1 = density[density_index(dims, bx, by, bz)];
                    const t = d0 / (d0 - d1);

                    const p0 = math.Vec3{
                        .x = cell_min.x + step.x * @as(f32, @floatFromInt(corner[c0][0])),
                        .y = cell_min.y + step.y * @as(f32, @floatFromInt(corner[c0][1])),
                        .z = cell_min.z + step.z * @as(f32, @floatFromInt(corner[c0][2])),
                    };
                    const p1 = math.Vec3{
                        .x = cell_min.x + step.x * @as(f32, @floatFromInt(corner[c1][0])),
                        .y = cell_min.y + step.y * @as(f32, @floatFromInt(corner[c1][1])),
                        .z = cell_min.z + step.z * @as(f32, @floatFromInt(corner[c1][2])),
                    };
                    const p = p0.add(p1.sub(p0).mul(t));

                    const g0 = gradient[density_index(dims, ax, ay, az)];
                    const g1 = gradient[density_index(dims, bx, by, bz)];
                    const n = g0.add(g1.sub(g0).mul(t));
                    const len = n.length();
                    const nn = if (len > 0.000001) n.mul(1.0 / len) else math.Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
                    n_sum = n_sum.add(nn);

                    const nx = nn.x;
                    const ny = nn.y;
                    const nz = nn.z;
                    const d = nx * p.x + ny * p.y + nz * p.z;

                    ata[0][0] += nx * nx;
                    ata[0][1] += nx * ny;
                    ata[0][2] += nx * nz;
                    ata[1][0] += ny * nx;
                    ata[1][1] += ny * ny;
                    ata[1][2] += ny * nz;
                    ata[2][0] += nz * nx;
                    ata[2][1] += nz * ny;
                    ata[2][2] += nz * nz;

                    atb[0] += nx * d;
                    atb[1] += ny * d;
                    atb[2] += nz * d;
                    edge_count += 1;
                }

                if (edge_count == 0) continue;

                const center = cell_min.add(step.mul(0.5));
                var pos = qef_solve_position(ata, atb, center);

                const cell_max = cell_min.add(step);
                pos.x = std.math.clamp(pos.x, cell_min.x, cell_max.x);
                pos.y = std.math.clamp(pos.y, cell_min.y, cell_max.y);
                pos.z = std.math.clamp(pos.z, cell_min.z, cell_max.z);

                const n_len = n_sum.length();
                const n_avg = if (n_len > 0.000001) n_sum.mul(1.0 / n_len) else math.Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
                write_vertex(verts_out, v_count.*, pos, n_avg);
                cell_to_vert[cell_linear_index(res, x, y, z)] = v_count.*;
                v_count.* += 1;
            }
        }
    }

    const invalid = std.math.maxInt(u32);
    z = 0;
    while (z < res) : (z += 1) {
        var y: u32 = 0;
        while (y < res) : (y += 1) {
            var x: u32 = 0;
            while (x < res) : (x += 1) {
                if (x + 1 < res and y + 1 < res) {
                    const ex = x + 1;
                    const ey = y + 1;
                    const d0 = density[density_index(dims, ex, ey, z)];
                    const d1 = density[density_index(dims, ex, ey, z + 1)];
                    if (sign_inside(d0) != sign_inside(d1)) {
                        const c0 = cell_to_vert[cell_linear_index(res, x, y, z)];
                        const c1 = cell_to_vert[cell_linear_index(res, x + 1, y, z)];
                        const c2 = cell_to_vert[cell_linear_index(res, x + 1, y + 1, z)];
                        const c3 = cell_to_vert[cell_linear_index(res, x, y + 1, z)];
                        if (c0 != invalid and c1 != invalid and c2 != invalid and c3 != invalid) {
                            emit_quad(inds_out, i_count, c0, c1, c2, c3, sign_inside(d0));
                        }
                    }
                }
                if (x + 1 < res and z + 1 < res) {
                    const zx = x + 1;
                    const zz = z + 1;
                    const d0 = density[density_index(dims, zx, y, zz)];
                    const d1 = density[density_index(dims, zx, y + 1, zz)];
                    if (sign_inside(d0) != sign_inside(d1)) {
                        const c0 = cell_to_vert[cell_linear_index(res, x, y, z)];
                        const c1 = cell_to_vert[cell_linear_index(res, x + 1, y, z)];
                        const c2 = cell_to_vert[cell_linear_index(res, x + 1, y, z + 1)];
                        const c3 = cell_to_vert[cell_linear_index(res, x, y, z + 1)];
                        if (c0 != invalid and c1 != invalid and c2 != invalid and c3 != invalid) {
                            emit_quad(inds_out, i_count, c0, c1, c2, c3, sign_inside(d0));
                        }
                    }
                }
                if (y + 1 < res and z + 1 < res) {
                    const zy = y + 1;
                    const zz = z + 1;
                    const d0 = density[density_index(dims, x, zy, zz)];
                    const d1 = density[density_index(dims, x + 1, zy, zz)];
                    if (sign_inside(d0) != sign_inside(d1)) {
                        const c0 = cell_to_vert[cell_linear_index(res, x, y, z)];
                        const c1 = cell_to_vert[cell_linear_index(res, x, y + 1, z)];
                        const c2 = cell_to_vert[cell_linear_index(res, x, y + 1, z + 1)];
                        const c3 = cell_to_vert[cell_linear_index(res, x, y, z + 1)];
                        if (c0 != invalid and c1 != invalid and c2 != invalid and c3 != invalid) {
                            emit_quad(inds_out, i_count, c0, c1, c2, c3, sign_inside(d0));
                        }
                    }
                }
            }
        }
    }

    return true;
}

pub fn mesh_lod(
    alloc: std.mem.Allocator,
    base_density: []const f32,
    base_dims: u32,
    base_res: u32,
    size: math.Vec3,
    lod: u32,
    verts_out: []scene.CardinalVertex,
    inds_out: []u32,
    v_count: *u32,
    i_count: *u32,
) bool {
    const scratch = alloc_lod_scratch(alloc, base_density, base_dims, base_res, lod) orelse return false;
    defer alloc.free(scratch.block);

    return dual_contour_mesh(
        scratch.density,
        scratch.gradient,
        scratch.dims,
        scratch.res,
        size,
        verts_out.ptr,
        inds_out.ptr,
        v_count,
        i_count,
        scratch.cell_to_vert,
    );
}

fn density_local_index(dims: [3]u32, x: u32, y: u32, z: u32) usize {
    return (@as(usize, z) * @as(usize, dims[1]) + @as(usize, y)) * @as(usize, dims[0]) + @as(usize, x);
}

fn sample_local(dims: [3]u32, gmin: [3]u32, x: u32, y: u32, z: u32) usize {
    return density_local_index(dims, x - gmin[0], y - gmin[1], z - gmin[2]);
}

fn cell_local(vdx: u32, vdy: u32, x: u32, y: u32, z: u32) usize {
    return (@as(usize, z) * @as(usize, vdy) + @as(usize, y)) * @as(usize, vdx) + @as(usize, x);
}

fn fetch(cell_to_vert: []const u32, vdx: u32, vdy: u32, vmin: [3]u32, x: u32, y: u32, z: u32) u32 {
    return cell_to_vert[cell_local(vdx, vdy, x - vmin[0], y - vmin[1], z - vmin[2])];
}

pub fn mesh_brick_lod(
    alloc: std.mem.Allocator,
    base_density: []const f32,
    base_splat: []const u8,
    base_dims: u32,
    base_res: u32,
    size: math.Vec3,
    lod: u32,
    axis: u32,
    brick_id: u32,
    dirty_box_base: VolumetricDirtyBox,
    out: *BrickRemeshOutput,
) bool {
    const res_lod: u32 = lod_resolution(base_res, lod);
    if (res_lod < 1) return true;
    const base_step: u32 = @as(u32, 1) << @intCast(@min(lod, 30));
    const coords = brick_id_to_coords(axis, brick_id);

    const rx_opt = brick_cell_range_for_axis(res_lod, lod, axis, coords.bx);
    const ry_opt = brick_cell_range_for_axis(res_lod, lod, axis, coords.by);
    const rz_opt = brick_cell_range_for_axis(res_lod, lod, axis, coords.bz);
    if (rx_opt == null or ry_opt == null or rz_opt == null) return true;
    const rx = rx_opt.?;
    const ry = ry_opt.?;
    const rz = rz_opt.?;

    const dmin = [3]u32{
        dirty_box_base.min_x / base_step,
        dirty_box_base.min_y / base_step,
        dirty_box_base.min_z / base_step,
    };
    const dmax = [3]u32{
        (dirty_box_base.max_x + base_step - 1) / base_step,
        (dirty_box_base.max_y + base_step - 1) / base_step,
        (dirty_box_base.max_z + base_step - 1) / base_step,
    };

    const face_min = [3]u32{
        @max(rx.min, @min(dmin[0], res_lod - 1)),
        @max(ry.min, @min(dmin[1], res_lod - 1)),
        @max(rz.min, @min(dmin[2], res_lod - 1)),
    };
    const face_max = [3]u32{
        @min(rx.max, @min(dmax[0], res_lod - 1)),
        @min(ry.max, @min(dmax[1], res_lod - 1)),
        @min(rz.max, @min(dmax[2], res_lod - 1)),
    };

    if (face_min[0] > face_max[0] or face_min[1] > face_max[1] or face_min[2] > face_max[2]) {
        out.has_update = false;
        return true;
    }

    out.has_update = true;

    const vmin = [3]u32{ rx.min, ry.min, rz.min };
    const vmax = [3]u32{
        @min(res_lod - 1, rx.max + 1),
        @min(res_lod - 1, ry.max + 1),
        @min(res_lod - 1, rz.max + 1),
    };

    const smin = vmin;
    const smax = [3]u32{
        @min(res_lod, vmax[0] + 1),
        @min(res_lod, vmax[1] + 1),
        @min(res_lod, vmax[2] + 1),
    };

    const gmin = [3]u32{
        if (smin[0] > 0) smin[0] - 1 else 0,
        if (smin[1] > 0) smin[1] - 1 else 0,
        if (smin[2] > 0) smin[2] - 1 else 0,
    };
    const gmax = [3]u32{
        @min(res_lod, smax[0] + 1),
        @min(res_lod, smax[1] + 1),
        @min(res_lod, smax[2] + 1),
    };

    const gdims = [3]u32{
        gmax[0] - gmin[0] + 1,
        gmax[1] - gmin[1] + 1,
        gmax[2] - gmin[2] + 1,
    };
    const sample_count: usize = @as(usize, gdims[0]) * @as(usize, gdims[1]) * @as(usize, gdims[2]);

    const vdx: u32 = vmax[0] - vmin[0] + 1;
    const vdy: u32 = vmax[1] - vmin[1] + 1;
    const vdz: u32 = vmax[2] - vmin[2] + 1;
    const cell_count: usize = @as(usize, vdx) * @as(usize, vdy) * @as(usize, vdz);

    const a_f32 = @alignOf(f32);
    const a_vec3 = @alignOf(math.Vec3);
    const a_u32 = @alignOf(u32);

    var bytes: usize = 0;
    bytes = std.mem.alignForward(usize, bytes, a_f32);
    bytes += sample_count * @sizeOf(f32);
    bytes = std.mem.alignForward(usize, bytes, a_vec3);
    bytes += sample_count * @sizeOf(math.Vec3);
    bytes = std.mem.alignForward(usize, bytes, a_vec3);
    bytes += sample_count * @sizeOf(math.Vec3);
    bytes = std.mem.alignForward(usize, bytes, a_u32);
    bytes += sample_count * @sizeOf(u32);
    bytes = std.mem.alignForward(usize, bytes, a_u32);
    bytes += cell_count * @sizeOf(u32);

    const block = alloc.alloc(u8, bytes) catch return false;
    errdefer alloc.free(block);

    var off: usize = 0;
    off = std.mem.alignForward(usize, off, a_f32);
    const density_ptr: [*]f32 = @ptrCast(@alignCast(block.ptr + off));
    const density_grid: []f32 = density_ptr[0..sample_count];
    off += sample_count * @sizeOf(f32);

    off = std.mem.alignForward(usize, off, a_vec3);
    const grad_ptr: [*]math.Vec3 = @ptrCast(@alignCast(block.ptr + off));
    const grad_grid: []math.Vec3 = grad_ptr[0..sample_count];
    off += sample_count * @sizeOf(math.Vec3);

    off = std.mem.alignForward(usize, off, a_vec3);
    const grad_tmp_ptr: [*]math.Vec3 = @ptrCast(@alignCast(block.ptr + off));
    const grad_tmp: []math.Vec3 = grad_tmp_ptr[0..sample_count];
    off += sample_count * @sizeOf(math.Vec3);

    off = std.mem.alignForward(usize, off, a_u32);
    const splat_ptr: [*]u32 = @ptrCast(@alignCast(block.ptr + off));
    const splat_grid: []u32 = splat_ptr[0..sample_count];
    off += sample_count * @sizeOf(u32);

    off = std.mem.alignForward(usize, off, a_u32);
    const c2v_ptr: [*]u32 = @ptrCast(@alignCast(block.ptr + off));
    const cell_to_vert: []u32 = c2v_ptr[0..cell_count];
    @memset(cell_to_vert, std.math.maxInt(u32));

    var gz: u32 = 0;
    while (gz < gdims[2]) : (gz += 1) {
        var gy: u32 = 0;
        while (gy < gdims[1]) : (gy += 1) {
            var gx: u32 = 0;
            while (gx < gdims[0]) : (gx += 1) {
                const sx = gmin[0] + gx;
                const sy = gmin[1] + gy;
                const sz = gmin[2] + gz;
                density_grid[density_local_index(gdims, gx, gy, gz)] = sample_lod_density(base_density, base_dims, base_step, sx, sy, sz);
                splat_grid[density_local_index(gdims, gx, gy, gz)] = sample_lod_splat(base_splat, base_dims, base_step, sx, sy, sz);
            }
        }
    }

    gz = 0;
    while (gz < gdims[2]) : (gz += 1) {
        var gy: u32 = 0;
        while (gy < gdims[1]) : (gy += 1) {
            var gx: u32 = 0;
            while (gx < gdims[0]) : (gx += 1) {
                const xm = if (gx == 0) 0 else gx - 1;
                const xp = if (gx + 1 >= gdims[0]) gdims[0] - 1 else gx + 1;
                const ym = if (gy == 0) 0 else gy - 1;
                const yp = if (gy + 1 >= gdims[1]) gdims[1] - 1 else gy + 1;
                const zm = if (gz == 0) 0 else gz - 1;
                const zp = if (gz + 1 >= gdims[2]) gdims[2] - 1 else gz + 1;

                const dx = density_grid[density_local_index(gdims, xp, gy, gz)] - density_grid[density_local_index(gdims, xm, gy, gz)];
                const dy = density_grid[density_local_index(gdims, gx, yp, gz)] - density_grid[density_local_index(gdims, gx, ym, gz)];
                const dz = density_grid[density_local_index(gdims, gx, gy, zp)] - density_grid[density_local_index(gdims, gx, gy, zm)];

                const g = math.Vec3{ .x = dx, .y = dy, .z = dz };
                const len = g.length();
                grad_grid[density_local_index(gdims, gx, gy, gz)] = if (len > 0.000001) g.mul(1.0 / len) else math.Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
            }
        }
    }

    gz = 0;
    while (gz < gdims[2]) : (gz += 1) {
        var gy: u32 = 0;
        while (gy < gdims[1]) : (gy += 1) {
            var gx: u32 = 0;
            while (gx < gdims[0]) : (gx += 1) {
                const xm = if (gx == 0) 0 else gx - 1;
                const xp = if (gx + 1 >= gdims[0]) gdims[0] - 1 else gx + 1;
                const ym = if (gy == 0) 0 else gy - 1;
                const yp = if (gy + 1 >= gdims[1]) gdims[1] - 1 else gy + 1;
                const zm = if (gz == 0) 0 else gz - 1;
                const zp = if (gz + 1 >= gdims[2]) gdims[2] - 1 else gz + 1;

                var sum = grad_grid[density_local_index(gdims, gx, gy, gz)];
                sum = sum.add(grad_grid[density_local_index(gdims, xm, gy, gz)]);
                sum = sum.add(grad_grid[density_local_index(gdims, xp, gy, gz)]);
                sum = sum.add(grad_grid[density_local_index(gdims, gx, ym, gz)]);
                sum = sum.add(grad_grid[density_local_index(gdims, gx, yp, gz)]);
                sum = sum.add(grad_grid[density_local_index(gdims, gx, gy, zm)]);
                sum = sum.add(grad_grid[density_local_index(gdims, gx, gy, zp)]);
                const len = sum.length();
                grad_tmp[density_local_index(gdims, gx, gy, gz)] = if (len > 0.000001) sum.mul(1.0 / len) else math.Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
            }
        }
    }
    @memcpy(grad_grid, grad_tmp);
    defer alloc.free(block);

    const brick_cells: u32 = (rx.max - rx.min + 1) * (ry.max - ry.min + 1) * (rz.max - rz.min + 1);
    const v_cap: usize = @as(usize, vdx) * @as(usize, vdy) * @as(usize, vdz) * 2;
    const i_cap: usize = 36 * @as(usize, brick_cells) * 2;
    out.vertices = alloc.alloc(scene.CardinalVertex, v_cap) catch return false;
    errdefer alloc.free(out.vertices);
    out.indices = alloc.alloc(u32, i_cap) catch return false;
    errdefer alloc.free(out.indices);

    const half = size.mul(0.5);
    const step_world = math.Vec3{
        .x = size.x / @as(f32, @floatFromInt(res_lod)),
        .y = size.y / @as(f32, @floatFromInt(res_lod)),
        .z = size.z / @as(f32, @floatFromInt(res_lod)),
    };

    const corner = [_][3]u32{
        .{ 0, 0, 0 },
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 1, 1, 0 },
        .{ 0, 0, 1 },
        .{ 1, 0, 1 },
        .{ 0, 1, 1 },
        .{ 1, 1, 1 },
    };
    const edge = [_][2]u8{
        .{ 0, 1 },
        .{ 0, 2 },
        .{ 1, 3 },
        .{ 2, 3 },
        .{ 4, 5 },
        .{ 4, 6 },
        .{ 5, 7 },
        .{ 6, 7 },
        .{ 0, 4 },
        .{ 1, 5 },
        .{ 2, 6 },
        .{ 3, 7 },
    };

    var v_count: u32 = 0;
    var i_count: u32 = 0;

    const invalid = std.math.maxInt(u32);

    var z: u32 = rz.min;
    while (z <= rz.max) : (z += 1) {
        var y: u32 = ry.min;
        while (y <= ry.max) : (y += 1) {
            var x: u32 = rx.min;
            while (x <= rx.max) : (x += 1) {
                var mask: u8 = 0;
                var ci: usize = 0;
                while (ci < 8) : (ci += 1) {
                    const sx = x + corner[ci][0];
                    const sy = y + corner[ci][1];
                    const sz = z + corner[ci][2];
                    const d = density_grid[sample_local(gdims, gmin, sx, sy, sz)];
                    if (sign_inside(d)) mask |= @as(u8, 1) << @intCast(ci);
                }
                if (mask == 0 or mask == 0xFF) continue;

                const cell_min = math.Vec3{
                    .x = -half.x + step_world.x * @as(f32, @floatFromInt(x)),
                    .y = -half.y + step_world.y * @as(f32, @floatFromInt(y)),
                    .z = -half.z + step_world.z * @as(f32, @floatFromInt(z)),
                };

                var ata: [3][3]f32 = .{ .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0 } };
                var atb: [3]f32 = .{ 0.0, 0.0, 0.0 };
                var n_sum = math.Vec3{ .x = 0.0, .y = 0.0, .z = 0.0 };

                var edge_count: u32 = 0;
                var e: usize = 0;
                while (e < edge.len) : (e += 1) {
                    const c0 = edge[e][0];
                    const c1 = edge[e][1];
                    const inside0 = ((mask >> @intCast(c0)) & 1) != 0;
                    const inside1 = ((mask >> @intCast(c1)) & 1) != 0;
                    if (inside0 == inside1) continue;

                    const ax = x + corner[c0][0];
                    const ay = y + corner[c0][1];
                    const az = z + corner[c0][2];
                    const bx = x + corner[c1][0];
                    const by = y + corner[c1][1];
                    const bz = z + corner[c1][2];
                    const d0 = density_grid[sample_local(gdims, gmin, ax, ay, az)];
                    const d1 = density_grid[sample_local(gdims, gmin, bx, by, bz)];
                    const t = d0 / (d0 - d1);

                    const p0 = math.Vec3{
                        .x = cell_min.x + step_world.x * @as(f32, @floatFromInt(corner[c0][0])),
                        .y = cell_min.y + step_world.y * @as(f32, @floatFromInt(corner[c0][1])),
                        .z = cell_min.z + step_world.z * @as(f32, @floatFromInt(corner[c0][2])),
                    };
                    const p1 = math.Vec3{
                        .x = cell_min.x + step_world.x * @as(f32, @floatFromInt(corner[c1][0])),
                        .y = cell_min.y + step_world.y * @as(f32, @floatFromInt(corner[c1][1])),
                        .z = cell_min.z + step_world.z * @as(f32, @floatFromInt(corner[c1][2])),
                    };
                    const p = p0.add(p1.sub(p0).mul(t));

                    const g0 = grad_grid[sample_local(gdims, gmin, ax, ay, az)];
                    const g1 = grad_grid[sample_local(gdims, gmin, bx, by, bz)];
                    const n = g0.add(g1.sub(g0).mul(t));
                    const len = n.length();
                    const nn = if (len > 0.000001) n.mul(1.0 / len) else math.Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
                    n_sum = n_sum.add(nn);

                    const nx = nn.x;
                    const ny = nn.y;
                    const nz = nn.z;
                    const d = nx * p.x + ny * p.y + nz * p.z;

                    ata[0][0] += nx * nx;
                    ata[0][1] += nx * ny;
                    ata[0][2] += nx * nz;
                    ata[1][0] += ny * nx;
                    ata[1][1] += ny * ny;
                    ata[1][2] += ny * nz;
                    ata[2][0] += nz * nx;
                    ata[2][1] += nz * ny;
                    ata[2][2] += nz * nz;

                    atb[0] += nx * d;
                    atb[1] += ny * d;
                    atb[2] += nz * d;
                    edge_count += 1;
                }
                if (edge_count == 0) continue;

                const center = cell_min.add(step_world.mul(0.5));
                var pos = qef_solve_position(ata, atb, center);
                const cell_max = cell_min.add(step_world);
                pos.x = std.math.clamp(pos.x, cell_min.x, cell_max.x);
                pos.y = std.math.clamp(pos.y, cell_min.y, cell_max.y);
                pos.z = std.math.clamp(pos.z, cell_min.z, cell_max.z);

                if (rx.min == 0 and x == 0) pos.x = cell_min.x;
                if (rx.max == res_lod - 1 and x == res_lod - 1) pos.x = cell_max.x;
                if (rz.min == 0 and z == 0) pos.z = cell_min.z;
                if (rz.max == res_lod - 1 and z == res_lod - 1) pos.z = cell_max.z;

                const n_len = n_sum.length();
                const n_avg = if (n_len > 0.000001) n_sum.mul(1.0 / n_len) else math.Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };

                var sr: u32 = 0;
                var sg: u32 = 0;
                var sb: u32 = 0;
                var sa: u32 = 0;
                var ci2: usize = 0;
                while (ci2 < 8) : (ci2 += 1) {
                    const sx = x + corner[ci2][0];
                    const sy = y + corner[ci2][1];
                    const sz2 = z + corner[ci2][2];
                    const splat_packed = splat_grid[sample_local(gdims, gmin, sx, sy, sz2)];
                    sr += splat_packed & 0xFF;
                    sg += (splat_packed >> 8) & 0xFF;
                    sb += (splat_packed >> 16) & 0xFF;
                    sa += (splat_packed >> 24) & 0xFF;
                }
                const inv = 1.0 / (255.0 * 8.0);
                const w0 = @as(f32, @floatFromInt(sr)) * inv;
                const w1 = @as(f32, @floatFromInt(sg)) * inv;
                const w2 = @as(f32, @floatFromInt(sb)) * inv;
                const w3 = @as(f32, @floatFromInt(sa)) * inv;
                const sumw = w0 + w1 + w2 + w3;
                const nrm = if (sumw > 0.000001) 1.0 / sumw else 1.0;
                const a0 = w0 * nrm;
                const a1 = w1 * nrm;
                const a2 = w2 * nrm;
                const a3 = w3 * nrm;

                const col = [4]f32{ a0, a1, a2, a3 };
                write_vertex_with_color(out.vertices.ptr, v_count, pos, n_avg, col, size);
                cell_to_vert[cell_local(vdx, vdy, x - vmin[0], y - vmin[1], z - vmin[2])] = v_count;
                v_count += 1;
            }
        }
    }

    z = rz.min;
    while (z <= rz.max) : (z += 1) {
        var y: u32 = ry.min;
        while (y <= ry.max) : (y += 1) {
            var x: u32 = rx.min;
            while (x <= rx.max) : (x += 1) {
                if (x + 1 < res_lod and y + 1 < res_lod) {
                    const ex = x + 1;
                    const ey = y + 1;
                    const d0 = density_grid[sample_local(gdims, gmin, ex, ey, z)];
                    const d1 = density_grid[sample_local(gdims, gmin, ex, ey, z + 1)];
                    if (sign_inside(d0) != sign_inside(d1)) {
                        const c0 = fetch(cell_to_vert, vdx, vdy, vmin, x, y, z);
                        const c1 = fetch(cell_to_vert, vdx, vdy, vmin, x + 1, y, z);
                        const c2 = fetch(cell_to_vert, vdx, vdy, vmin, x + 1, y + 1, z);
                        const c3 = fetch(cell_to_vert, vdx, vdy, vmin, x, y + 1, z);
                        if (c0 != invalid and c1 != invalid and c2 != invalid and c3 != invalid) {
                            emit_quad(out.indices.ptr, &i_count, c0, c1, c2, c3, sign_inside(d0));
                        }
                    }
                }
                if (x + 1 < res_lod and z + 1 < res_lod) {
                    const zx = x + 1;
                    const zz = z + 1;
                    const d0 = density_grid[sample_local(gdims, gmin, zx, y, zz)];
                    const d1 = density_grid[sample_local(gdims, gmin, zx, y + 1, zz)];
                    if (sign_inside(d0) != sign_inside(d1)) {
                        const c0 = fetch(cell_to_vert, vdx, vdy, vmin, x, y, z);
                        const c1 = fetch(cell_to_vert, vdx, vdy, vmin, x + 1, y, z);
                        const c2 = fetch(cell_to_vert, vdx, vdy, vmin, x + 1, y, z + 1);
                        const c3 = fetch(cell_to_vert, vdx, vdy, vmin, x, y, z + 1);
                        if (c0 != invalid and c1 != invalid and c2 != invalid and c3 != invalid) {
                            emit_quad(out.indices.ptr, &i_count, c0, c1, c2, c3, sign_inside(d0));
                        }
                    }
                }
                if (y + 1 < res_lod and z + 1 < res_lod) {
                    const zy = y + 1;
                    const zz = z + 1;
                    const d0 = density_grid[sample_local(gdims, gmin, x, zy, zz)];
                    const d1 = density_grid[sample_local(gdims, gmin, x + 1, zy, zz)];
                    if (sign_inside(d0) != sign_inside(d1)) {
                        const c0 = fetch(cell_to_vert, vdx, vdy, vmin, x, y, z);
                        const c1 = fetch(cell_to_vert, vdx, vdy, vmin, x, y + 1, z);
                        const c2 = fetch(cell_to_vert, vdx, vdy, vmin, x, y + 1, z + 1);
                        const c3 = fetch(cell_to_vert, vdx, vdy, vmin, x, y, z + 1);
                        if (c0 != invalid and c1 != invalid and c2 != invalid and c3 != invalid) {
                            emit_quad(out.indices.ptr, &i_count, c0, c1, c2, c3, sign_inside(d0));
                        }
                    }
                }
            }
        }
    }

    {
        const x_min = -half.x + step_world.x * @as(f32, @floatFromInt(rx.min));
        const x_max = -half.x + step_world.x * @as(f32, @floatFromInt(rx.max + 1));
        const z_min = -half.z + step_world.z * @as(f32, @floatFromInt(rz.min));
        const z_max = -half.z + step_world.z * @as(f32, @floatFromInt(rz.max + 1));
        const eps_x = step_world.x * 0.75;
        const eps_z = step_world.z * 0.75;
        const skirt_len = @max(0.001, step_world.y * 4.0);

        const add_skirt_edge = struct {
            fn f(o: *BrickRemeshOutput, i_count_ptr: *u32, v_count_ptr: *u32, a: u32, b: u32, skirt_depth: f32) void {
                const vc: usize = @intCast(v_count_ptr.*);
                const ic: usize = @intCast(i_count_ptr.*);
                if (o.vertices.len < vc + 2) return;
                if (o.indices.len < ic + 6) return;

                const va = o.vertices[@intCast(a)];
                const vb = o.vertices[@intCast(b)];

                const a_ex = v_count_ptr.*;
                const b_ex = v_count_ptr.* + 1;
                v_count_ptr.* += 2;

                var va2 = va;
                var vb2 = vb;
                va2.py -= skirt_depth;
                vb2.py -= skirt_depth;
                o.vertices[@intCast(a_ex)] = va2;
                o.vertices[@intCast(b_ex)] = vb2;

                o.indices[ic + 0] = a;
                o.indices[ic + 1] = b;
                o.indices[ic + 2] = b_ex;
                o.indices[ic + 3] = a;
                o.indices[ic + 4] = b_ex;
                o.indices[ic + 5] = a_ex;
                i_count_ptr.* += 6;
            }
        }.f;

        const base_i_count: u32 = i_count;
        var t: u32 = 0;
        while (t + 2 < base_i_count) : (t += 3) {
            const ti: usize = @intCast(t);
            const idx0 = out.indices[ti + 0];
            const idx1 = out.indices[ti + 1];
            const idx2 = out.indices[ti + 2];

            const v0 = out.vertices[@intCast(idx0)];
            const v1 = out.vertices[@intCast(idx1)];
            const v2 = out.vertices[@intCast(idx2)];

            const on_x_min_01 = (v0.px <= x_min + eps_x) and (v1.px <= x_min + eps_x);
            const on_x_min_12 = (v1.px <= x_min + eps_x) and (v2.px <= x_min + eps_x);
            const on_x_min_20 = (v2.px <= x_min + eps_x) and (v0.px <= x_min + eps_x);
            const on_x_max_01 = (v0.px >= x_max - eps_x) and (v1.px >= x_max - eps_x);
            const on_x_max_12 = (v1.px >= x_max - eps_x) and (v2.px >= x_max - eps_x);
            const on_x_max_20 = (v2.px >= x_max - eps_x) and (v0.px >= x_max - eps_x);
            const on_z_min_01 = (v0.pz <= z_min + eps_z) and (v1.pz <= z_min + eps_z);
            const on_z_min_12 = (v1.pz <= z_min + eps_z) and (v2.pz <= z_min + eps_z);
            const on_z_min_20 = (v2.pz <= z_min + eps_z) and (v0.pz <= z_min + eps_z);
            const on_z_max_01 = (v0.pz >= z_max - eps_z) and (v1.pz >= z_max - eps_z);
            const on_z_max_12 = (v1.pz >= z_max - eps_z) and (v2.pz >= z_max - eps_z);
            const on_z_max_20 = (v2.pz >= z_max - eps_z) and (v0.pz >= z_max - eps_z);

            if (on_x_min_01 or on_x_max_01 or on_z_min_01 or on_z_max_01) add_skirt_edge(out, &i_count, &v_count, idx0, idx1, skirt_len);
            if (on_x_min_12 or on_x_max_12 or on_z_min_12 or on_z_max_12) add_skirt_edge(out, &i_count, &v_count, idx1, idx2, skirt_len);
            if (on_x_min_20 or on_x_max_20 or on_z_min_20 or on_z_max_20) add_skirt_edge(out, &i_count, &v_count, idx2, idx0, skirt_len);
        }
    }

    out.vertex_count = v_count;
    out.index_count = i_count;
    return true;
}

pub fn mesh_brick_lod_range(
    alloc: std.mem.Allocator,
    base_density: []const f32,
    base_splat: []const u8,
    base_dims: u32,
    base_res: u32,
    size: math.Vec3,
    lod: u32,
    rx: C.CellRange,
    ry: C.CellRange,
    rz: C.CellRange,
    dirty_box_base: VolumetricDirtyBox,
    skirt_x_min: bool,
    skirt_x_max: bool,
    skirt_z_min: bool,
    skirt_z_max: bool,
    out: *BrickRemeshOutput,
) bool {
    const res_lod: u32 = lod_resolution(base_res, lod);
    if (res_lod < 1) return true;
    const base_step: u32 = @as(u32, 1) << @intCast(@min(lod, 30));

    const dmin = [3]u32{
        dirty_box_base.min_x / base_step,
        dirty_box_base.min_y / base_step,
        dirty_box_base.min_z / base_step,
    };
    const dmax = [3]u32{
        (dirty_box_base.max_x + base_step - 1) / base_step,
        (dirty_box_base.max_y + base_step - 1) / base_step,
        (dirty_box_base.max_z + base_step - 1) / base_step,
    };

    const face_min = [3]u32{
        @max(rx.min, @min(dmin[0], res_lod - 1)),
        @max(ry.min, @min(dmin[1], res_lod - 1)),
        @max(rz.min, @min(dmin[2], res_lod - 1)),
    };
    const face_max = [3]u32{
        @min(rx.max, @min(dmax[0], res_lod - 1)),
        @min(ry.max, @min(dmax[1], res_lod - 1)),
        @min(rz.max, @min(dmax[2], res_lod - 1)),
    };

    if (face_min[0] > face_max[0] or face_min[1] > face_max[1] or face_min[2] > face_max[2]) {
        out.has_update = false;
        return true;
    }

    out.has_update = true;

    const vmin = [3]u32{ rx.min, ry.min, rz.min };
    const vmax = [3]u32{
        @min(res_lod - 1, rx.max + 1),
        @min(res_lod - 1, ry.max + 1),
        @min(res_lod - 1, rz.max + 1),
    };

    const smin = vmin;
    const smax = [3]u32{
        @min(res_lod, vmax[0] + 1),
        @min(res_lod, vmax[1] + 1),
        @min(res_lod, vmax[2] + 1),
    };

    const gmin = [3]u32{
        if (smin[0] > 0) smin[0] - 1 else 0,
        if (smin[1] > 0) smin[1] - 1 else 0,
        if (smin[2] > 0) smin[2] - 1 else 0,
    };
    const gmax = [3]u32{
        @min(res_lod, smax[0] + 1),
        @min(res_lod, smax[1] + 1),
        @min(res_lod, smax[2] + 1),
    };

    const gdims = [3]u32{
        gmax[0] - gmin[0] + 1,
        gmax[1] - gmin[1] + 1,
        gmax[2] - gmin[2] + 1,
    };
    const sample_count: usize = @as(usize, gdims[0]) * @as(usize, gdims[1]) * @as(usize, gdims[2]);

    const vdx: u32 = vmax[0] - vmin[0] + 1;
    const vdy: u32 = vmax[1] - vmin[1] + 1;
    const vdz: u32 = vmax[2] - vmin[2] + 1;
    const cell_count: usize = @as(usize, vdx) * @as(usize, vdy) * @as(usize, vdz);

    const a_f32 = @alignOf(f32);
    const a_vec3 = @alignOf(math.Vec3);
    const a_u32 = @alignOf(u32);

    var bytes: usize = 0;
    bytes = std.mem.alignForward(usize, bytes, a_f32);
    bytes += sample_count * @sizeOf(f32);
    bytes = std.mem.alignForward(usize, bytes, a_vec3);
    bytes += sample_count * @sizeOf(math.Vec3);
    bytes = std.mem.alignForward(usize, bytes, a_vec3);
    bytes += sample_count * @sizeOf(math.Vec3);
    bytes = std.mem.alignForward(usize, bytes, a_u32);
    bytes += sample_count * @sizeOf(u32);
    bytes = std.mem.alignForward(usize, bytes, a_u32);
    bytes += cell_count * @sizeOf(u32);

    const block = alloc.alloc(u8, bytes) catch return false;
    defer alloc.free(block);

    var off: usize = 0;
    off = std.mem.alignForward(usize, off, a_f32);
    const density_ptr: [*]f32 = @ptrCast(@alignCast(block.ptr + off));
    const density_grid: []f32 = density_ptr[0..sample_count];
    off += sample_count * @sizeOf(f32);

    off = std.mem.alignForward(usize, off, a_vec3);
    const grad_ptr: [*]math.Vec3 = @ptrCast(@alignCast(block.ptr + off));
    const grad_grid: []math.Vec3 = grad_ptr[0..sample_count];
    off += sample_count * @sizeOf(math.Vec3);

    off = std.mem.alignForward(usize, off, a_vec3);
    const grad_tmp_ptr: [*]math.Vec3 = @ptrCast(@alignCast(block.ptr + off));
    const grad_tmp: []math.Vec3 = grad_tmp_ptr[0..sample_count];
    off += sample_count * @sizeOf(math.Vec3);

    off = std.mem.alignForward(usize, off, a_u32);
    const splat_ptr: [*]u32 = @ptrCast(@alignCast(block.ptr + off));
    const splat_grid: []u32 = splat_ptr[0..sample_count];
    off += sample_count * @sizeOf(u32);

    off = std.mem.alignForward(usize, off, a_u32);
    const c2v_ptr: [*]u32 = @ptrCast(@alignCast(block.ptr + off));
    const cell_to_vert: []u32 = c2v_ptr[0..cell_count];
    @memset(cell_to_vert, std.math.maxInt(u32));

    var gz: u32 = 0;
    while (gz < gdims[2]) : (gz += 1) {
        var gy: u32 = 0;
        while (gy < gdims[1]) : (gy += 1) {
            var gx: u32 = 0;
            while (gx < gdims[0]) : (gx += 1) {
                const sx = gmin[0] + gx;
                const sy = gmin[1] + gy;
                const sz = gmin[2] + gz;
                density_grid[density_local_index(gdims, gx, gy, gz)] = sample_lod_density(base_density, base_dims, base_step, sx, sy, sz);
                splat_grid[density_local_index(gdims, gx, gy, gz)] = sample_lod_splat(base_splat, base_dims, base_step, sx, sy, sz);
            }
        }
    }

    gz = 0;
    while (gz < gdims[2]) : (gz += 1) {
        var gy: u32 = 0;
        while (gy < gdims[1]) : (gy += 1) {
            var gx: u32 = 0;
            while (gx < gdims[0]) : (gx += 1) {
                const xm = if (gx == 0) 0 else gx - 1;
                const xp = if (gx + 1 >= gdims[0]) gdims[0] - 1 else gx + 1;
                const ym = if (gy == 0) 0 else gy - 1;
                const yp = if (gy + 1 >= gdims[1]) gdims[1] - 1 else gy + 1;
                const zm = if (gz == 0) 0 else gz - 1;
                const zp = if (gz + 1 >= gdims[2]) gdims[2] - 1 else gz + 1;

                const dx = density_grid[density_local_index(gdims, xp, gy, gz)] - density_grid[density_local_index(gdims, xm, gy, gz)];
                const dy = density_grid[density_local_index(gdims, gx, yp, gz)] - density_grid[density_local_index(gdims, gx, ym, gz)];
                const dz = density_grid[density_local_index(gdims, gx, gy, zp)] - density_grid[density_local_index(gdims, gx, gy, zm)];

                const g = math.Vec3{ .x = dx, .y = dy, .z = dz };
                const len = g.length();
                grad_grid[density_local_index(gdims, gx, gy, gz)] = if (len > 0.000001) g.mul(1.0 / len) else math.Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
            }
        }
    }

    gz = 0;
    while (gz < gdims[2]) : (gz += 1) {
        var gy: u32 = 0;
        while (gy < gdims[1]) : (gy += 1) {
            var gx: u32 = 0;
            while (gx < gdims[0]) : (gx += 1) {
                const xm = if (gx == 0) 0 else gx - 1;
                const xp = if (gx + 1 >= gdims[0]) gdims[0] - 1 else gx + 1;
                const ym = if (gy == 0) 0 else gy - 1;
                const yp = if (gy + 1 >= gdims[1]) gdims[1] - 1 else gy + 1;
                const zm = if (gz == 0) 0 else gz - 1;
                const zp = if (gz + 1 >= gdims[2]) gdims[2] - 1 else gz + 1;

                var sum = grad_grid[density_local_index(gdims, gx, gy, gz)];
                sum = sum.add(grad_grid[density_local_index(gdims, xm, gy, gz)]);
                sum = sum.add(grad_grid[density_local_index(gdims, xp, gy, gz)]);
                sum = sum.add(grad_grid[density_local_index(gdims, gx, ym, gz)]);
                sum = sum.add(grad_grid[density_local_index(gdims, gx, yp, gz)]);
                sum = sum.add(grad_grid[density_local_index(gdims, gx, gy, zm)]);
                sum = sum.add(grad_grid[density_local_index(gdims, gx, gy, zp)]);
                const len = sum.length();
                grad_tmp[density_local_index(gdims, gx, gy, gz)] = if (len > 0.000001) sum.mul(1.0 / len) else math.Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
            }
        }
    }
    @memcpy(grad_grid, grad_tmp);

    const brick_cells: u32 = (rx.max - rx.min + 1) * (ry.max - ry.min + 1) * (rz.max - rz.min + 1);
    const v_cap: usize = @as(usize, vdx) * @as(usize, vdy) * @as(usize, vdz) * 2;
    const i_cap: usize = 36 * @as(usize, brick_cells) * 2;
    out.vertices = alloc.alloc(scene.CardinalVertex, v_cap) catch return false;
    errdefer alloc.free(out.vertices);
    out.indices = alloc.alloc(u32, i_cap) catch return false;
    errdefer alloc.free(out.indices);

    const half = size.mul(0.5);
    const step_world = math.Vec3{
        .x = size.x / @as(f32, @floatFromInt(res_lod)),
        .y = size.y / @as(f32, @floatFromInt(res_lod)),
        .z = size.z / @as(f32, @floatFromInt(res_lod)),
    };

    const corner = [_][3]u32{
        .{ 0, 0, 0 },
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 1, 1, 0 },
        .{ 0, 0, 1 },
        .{ 1, 0, 1 },
        .{ 0, 1, 1 },
        .{ 1, 1, 1 },
    };
    const edge = [_][2]u8{
        .{ 0, 1 },
        .{ 0, 2 },
        .{ 1, 3 },
        .{ 2, 3 },
        .{ 0, 4 },
        .{ 1, 5 },
        .{ 2, 6 },
        .{ 3, 7 },
        .{ 4, 5 },
        .{ 4, 6 },
        .{ 5, 7 },
        .{ 6, 7 },
    };

    const invalid = std.math.maxInt(u32);

    var v_count: u32 = 0;
    var i_count: u32 = 0;

    var z: u32 = vmin[2];
    while (z <= vmax[2]) : (z += 1) {
        var y: u32 = vmin[1];
        while (y <= vmax[1]) : (y += 1) {
            var x: u32 = vmin[0];
            while (x <= vmax[0]) : (x += 1) {
                const cell_min = math.Vec3{
                    .x = -half.x + step_world.x * @as(f32, @floatFromInt(x)),
                    .y = -half.y + step_world.y * @as(f32, @floatFromInt(y)),
                    .z = -half.z + step_world.z * @as(f32, @floatFromInt(z)),
                };

                var ata: [3][3]f32 = .{ .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 0.0 } };
                var atb: [3]f32 = .{ 0.0, 0.0, 0.0 };
                var n_sum = math.Vec3.zero();
                var edge_count: u32 = 0;

                var edge_i: usize = 0;
                while (edge_i < edge.len) : (edge_i += 1) {
                    const c0: usize = @intCast(edge[edge_i][0]);
                    const c1: usize = @intCast(edge[edge_i][1]);
                    const ax = x + corner[c0][0];
                    const ay = y + corner[c0][1];
                    const az = z + corner[c0][2];
                    const bx = x + corner[c1][0];
                    const by = y + corner[c1][1];
                    const bz = z + corner[c1][2];

                    const d0 = density_grid[sample_local(gdims, gmin, ax, ay, az)];
                    const d1 = density_grid[sample_local(gdims, gmin, bx, by, bz)];
                    if (sign_inside(d0) == sign_inside(d1)) continue;
                    if (@abs(d0 - d1) < 1e-20) continue;
                    const t = d0 / (d0 - d1);

                    const p0 = math.Vec3{
                        .x = cell_min.x + step_world.x * @as(f32, @floatFromInt(corner[c0][0])),
                        .y = cell_min.y + step_world.y * @as(f32, @floatFromInt(corner[c0][1])),
                        .z = cell_min.z + step_world.z * @as(f32, @floatFromInt(corner[c0][2])),
                    };
                    const p1 = math.Vec3{
                        .x = cell_min.x + step_world.x * @as(f32, @floatFromInt(corner[c1][0])),
                        .y = cell_min.y + step_world.y * @as(f32, @floatFromInt(corner[c1][1])),
                        .z = cell_min.z + step_world.z * @as(f32, @floatFromInt(corner[c1][2])),
                    };
                    const p = p0.add(p1.sub(p0).mul(t));

                    const g0 = grad_grid[sample_local(gdims, gmin, ax, ay, az)];
                    const g1 = grad_grid[sample_local(gdims, gmin, bx, by, bz)];
                    const n = g0.add(g1.sub(g0).mul(t));
                    const len = n.length();
                    const nn = if (len > 0.000001) n.mul(1.0 / len) else math.Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };
                    n_sum = n_sum.add(nn);

                    const nx = nn.x;
                    const ny = nn.y;
                    const nz = nn.z;
                    const d = nx * p.x + ny * p.y + nz * p.z;

                    ata[0][0] += nx * nx;
                    ata[0][1] += nx * ny;
                    ata[0][2] += nx * nz;
                    ata[1][0] += ny * nx;
                    ata[1][1] += ny * ny;
                    ata[1][2] += ny * nz;
                    ata[2][0] += nz * nx;
                    ata[2][1] += nz * ny;
                    ata[2][2] += nz * nz;

                    atb[0] += nx * d;
                    atb[1] += ny * d;
                    atb[2] += nz * d;
                    edge_count += 1;
                }
                if (edge_count == 0) continue;

                const center = cell_min.add(step_world.mul(0.5));
                var pos = qef_solve_position(ata, atb, center);
                const cell_max = cell_min.add(step_world);
                pos.x = std.math.clamp(pos.x, cell_min.x, cell_max.x);
                pos.y = std.math.clamp(pos.y, cell_min.y, cell_max.y);
                pos.z = std.math.clamp(pos.z, cell_min.z, cell_max.z);

                const n_len = n_sum.length();
                const n_avg = if (n_len > 0.000001) n_sum.mul(1.0 / n_len) else math.Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 };

                var sr: u32 = 0;
                var sg: u32 = 0;
                var sb: u32 = 0;
                var sa: u32 = 0;
                var ci2: usize = 0;
                while (ci2 < 8) : (ci2 += 1) {
                    const sx = x + corner[ci2][0];
                    const sy = y + corner[ci2][1];
                    const sz2 = z + corner[ci2][2];
                    const splat_packed = splat_grid[sample_local(gdims, gmin, sx, sy, sz2)];
                    sr += splat_packed & 0xFF;
                    sg += (splat_packed >> 8) & 0xFF;
                    sb += (splat_packed >> 16) & 0xFF;
                    sa += (splat_packed >> 24) & 0xFF;
                }
                const inv = 1.0 / (255.0 * 8.0);
                const w0 = @as(f32, @floatFromInt(sr)) * inv;
                const w1 = @as(f32, @floatFromInt(sg)) * inv;
                const w2 = @as(f32, @floatFromInt(sb)) * inv;
                const w3 = @as(f32, @floatFromInt(sa)) * inv;
                const sumw = w0 + w1 + w2 + w3;
                const nrm = if (sumw > 0.000001) 1.0 / sumw else 1.0;
                const a0 = w0 * nrm;
                const a1 = w1 * nrm;
                const a2 = w2 * nrm;
                const a3 = w3 * nrm;

                const col = [4]f32{ a0, a1, a2, a3 };
                write_vertex_with_color(out.vertices.ptr, v_count, pos, n_avg, col, size);
                cell_to_vert[cell_local(vdx, vdy, x - vmin[0], y - vmin[1], z - vmin[2])] = v_count;
                v_count += 1;
            }
        }
    }

    z = rz.min;
    while (z <= rz.max) : (z += 1) {
        var y: u32 = ry.min;
        while (y <= ry.max) : (y += 1) {
            var x: u32 = rx.min;
            while (x <= rx.max) : (x += 1) {
                if (x + 1 < res_lod and y + 1 < res_lod) {
                    const ex = x + 1;
                    const ey = y + 1;
                    const d0 = density_grid[sample_local(gdims, gmin, ex, ey, z)];
                    const d1 = density_grid[sample_local(gdims, gmin, ex, ey, z + 1)];
                    if (sign_inside(d0) != sign_inside(d1)) {
                        const c0 = fetch(cell_to_vert, vdx, vdy, vmin, x, y, z);
                        const c1 = fetch(cell_to_vert, vdx, vdy, vmin, x + 1, y, z);
                        const c2 = fetch(cell_to_vert, vdx, vdy, vmin, x + 1, y + 1, z);
                        const c3 = fetch(cell_to_vert, vdx, vdy, vmin, x, y + 1, z);
                        if (c0 != invalid and c1 != invalid and c2 != invalid and c3 != invalid) {
                            emit_quad(out.indices.ptr, &i_count, c0, c1, c2, c3, sign_inside(d0));
                        }
                    }
                }
                if (x + 1 < res_lod and z + 1 < res_lod) {
                    const zx = x + 1;
                    const zz = z + 1;
                    const d0 = density_grid[sample_local(gdims, gmin, zx, y, zz)];
                    const d1 = density_grid[sample_local(gdims, gmin, zx, y + 1, zz)];
                    if (sign_inside(d0) != sign_inside(d1)) {
                        const c0 = fetch(cell_to_vert, vdx, vdy, vmin, x, y, z);
                        const c1 = fetch(cell_to_vert, vdx, vdy, vmin, x + 1, y, z);
                        const c2 = fetch(cell_to_vert, vdx, vdy, vmin, x + 1, y, z + 1);
                        const c3 = fetch(cell_to_vert, vdx, vdy, vmin, x, y, z + 1);
                        if (c0 != invalid and c1 != invalid and c2 != invalid and c3 != invalid) {
                            emit_quad(out.indices.ptr, &i_count, c0, c1, c2, c3, sign_inside(d0));
                        }
                    }
                }
                if (y + 1 < res_lod and z + 1 < res_lod) {
                    const zy = y + 1;
                    const zz = z + 1;
                    const d0 = density_grid[sample_local(gdims, gmin, x, zy, zz)];
                    const d1 = density_grid[sample_local(gdims, gmin, x + 1, zy, zz)];
                    if (sign_inside(d0) != sign_inside(d1)) {
                        const c0 = fetch(cell_to_vert, vdx, vdy, vmin, x, y, z);
                        const c1 = fetch(cell_to_vert, vdx, vdy, vmin, x, y + 1, z);
                        const c2 = fetch(cell_to_vert, vdx, vdy, vmin, x, y + 1, z + 1);
                        const c3 = fetch(cell_to_vert, vdx, vdy, vmin, x, y, z + 1);
                        if (c0 != invalid and c1 != invalid and c2 != invalid and c3 != invalid) {
                            emit_quad(out.indices.ptr, &i_count, c0, c1, c2, c3, sign_inside(d0));
                        }
                    }
                }
            }
        }
    }

    {
        const x_min = -half.x + step_world.x * @as(f32, @floatFromInt(rx.min));
        const x_max = -half.x + step_world.x * @as(f32, @floatFromInt(rx.max + 1));
        const z_min = -half.z + step_world.z * @as(f32, @floatFromInt(rz.min));
        const z_max = -half.z + step_world.z * @as(f32, @floatFromInt(rz.max + 1));
        const eps_x = step_world.x * 0.75;
        const eps_z = step_world.z * 0.75;
        const skirt_len = @max(0.001, step_world.y * 4.0);

        const add_skirt_edge = struct {
            fn f(o: *BrickRemeshOutput, i_count_ptr: *u32, v_count_ptr: *u32, a: u32, b: u32, skirt_depth: f32) void {
                const vc: usize = @intCast(v_count_ptr.*);
                const ic: usize = @intCast(i_count_ptr.*);
                if (o.vertices.len < vc + 2) return;
                if (o.indices.len < ic + 6) return;

                const va = o.vertices[@intCast(a)];
                const vb = o.vertices[@intCast(b)];

                const a_ex = v_count_ptr.*;
                const b_ex = v_count_ptr.* + 1;
                v_count_ptr.* += 2;

                var va2 = va;
                var vb2 = vb;
                va2.py -= skirt_depth;
                vb2.py -= skirt_depth;
                o.vertices[@intCast(a_ex)] = va2;
                o.vertices[@intCast(b_ex)] = vb2;

                o.indices[ic + 0] = a;
                o.indices[ic + 1] = b;
                o.indices[ic + 2] = b_ex;
                o.indices[ic + 3] = a;
                o.indices[ic + 4] = b_ex;
                o.indices[ic + 5] = a_ex;
                i_count_ptr.* += 6;
            }
        }.f;

        const base_i_count: u32 = i_count;
        var t: u32 = 0;
        while (t + 2 < base_i_count) : (t += 3) {
            const ti: usize = @intCast(t);
            const idx0 = out.indices[ti + 0];
            const idx1 = out.indices[ti + 1];
            const idx2 = out.indices[ti + 2];

            const v0 = out.vertices[@intCast(idx0)];
            const v1 = out.vertices[@intCast(idx1)];
            const v2 = out.vertices[@intCast(idx2)];

            const on_x_min_01 = (v0.px <= x_min + eps_x) and (v1.px <= x_min + eps_x);
            const on_x_min_12 = (v1.px <= x_min + eps_x) and (v2.px <= x_min + eps_x);
            const on_x_min_20 = (v2.px <= x_min + eps_x) and (v0.px <= x_min + eps_x);
            const on_x_max_01 = (v0.px >= x_max - eps_x) and (v1.px >= x_max - eps_x);
            const on_x_max_12 = (v1.px >= x_max - eps_x) and (v2.px >= x_max - eps_x);
            const on_x_max_20 = (v2.px >= x_max - eps_x) and (v0.px >= x_max - eps_x);
            const on_z_min_01 = (v0.pz <= z_min + eps_z) and (v1.pz <= z_min + eps_z);
            const on_z_min_12 = (v1.pz <= z_min + eps_z) and (v2.pz <= z_min + eps_z);
            const on_z_min_20 = (v2.pz <= z_min + eps_z) and (v0.pz <= z_min + eps_z);
            const on_z_max_01 = (v0.pz >= z_max - eps_z) and (v1.pz >= z_max - eps_z);
            const on_z_max_12 = (v1.pz >= z_max - eps_z) and (v2.pz >= z_max - eps_z);
            const on_z_max_20 = (v2.pz >= z_max - eps_z) and (v0.pz >= z_max - eps_z);

            if (skirt_x_min and on_x_min_01) add_skirt_edge(out, &i_count, &v_count, idx0, idx1, skirt_len);
            if (skirt_x_max and on_x_max_01) add_skirt_edge(out, &i_count, &v_count, idx0, idx1, skirt_len);
            if (skirt_z_min and on_z_min_01) add_skirt_edge(out, &i_count, &v_count, idx0, idx1, skirt_len);
            if (skirt_z_max and on_z_max_01) add_skirt_edge(out, &i_count, &v_count, idx0, idx1, skirt_len);

            if (skirt_x_min and on_x_min_12) add_skirt_edge(out, &i_count, &v_count, idx1, idx2, skirt_len);
            if (skirt_x_max and on_x_max_12) add_skirt_edge(out, &i_count, &v_count, idx1, idx2, skirt_len);
            if (skirt_z_min and on_z_min_12) add_skirt_edge(out, &i_count, &v_count, idx1, idx2, skirt_len);
            if (skirt_z_max and on_z_max_12) add_skirt_edge(out, &i_count, &v_count, idx1, idx2, skirt_len);

            if (skirt_x_min and on_x_min_20) add_skirt_edge(out, &i_count, &v_count, idx2, idx0, skirt_len);
            if (skirt_x_max and on_x_max_20) add_skirt_edge(out, &i_count, &v_count, idx2, idx0, skirt_len);
            if (skirt_z_min and on_z_min_20) add_skirt_edge(out, &i_count, &v_count, idx2, idx0, skirt_len);
            if (skirt_z_max and on_z_max_20) add_skirt_edge(out, &i_count, &v_count, idx2, idx0, skirt_len);
        }
    }

    out.vertex_count = v_count;
    out.index_count = i_count;
    return true;
}
