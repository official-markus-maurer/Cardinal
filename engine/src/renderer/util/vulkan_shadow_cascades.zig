//! Cascaded shadow map math helpers.
//!
//! Computes cascade splits and light-space matrices for directional-light shadow mapping.
//!
//! TODO: Make the cascade Z range configurable per scene/cascade.
const std = @import("std");
const types = @import("../vulkan_types.zig");
const math = @import("../../core/math.zig");

fn mat4_ortho(left: f32, right: f32, bottom: f32, top: f32, zNear: f32, zFar: f32) math.Mat4 {
    return math.Mat4.ortho(left, right, bottom, top, zNear, zFar);
}

fn mat4_lookAt(eye: math.Vec3, center: math.Vec3, up: math.Vec3) math.Mat4 {
    return math.Mat4.lookAt(eye, center, up);
}

fn mul_mat4_vec3(m: math.Mat4, v: math.Vec3) math.Vec3 {
    const x = m.data[0] * v.x + m.data[4] * v.y + m.data[8] * v.z + m.data[12];
    const y = m.data[1] * v.x + m.data[5] * v.y + m.data[9] * v.z + m.data[13];
    const z = m.data[2] * v.x + m.data[6] * v.y + m.data[10] * v.z + m.data[14];
    return math.Vec3{ .x = x, .y = y, .z = z };
}

fn corners_at_dist(dist: f32, c_pos: math.Vec3, c_fwd: math.Vec3, c_right: math.Vec3, c_up: math.Vec3, tan_half_fov: f32, aspect: f32) [4]math.Vec3 {
    const height = dist * tan_half_fov * 2.0;
    const width = height * aspect;

    const center_slice = c_pos.add(c_fwd.mul(dist));
    const up_vec = c_up.mul(height * 0.5);
    const right_vec = c_right.mul(width * 0.5);

    return [4]math.Vec3{
        center_slice.sub(right_vec).add(up_vec),
        center_slice.add(right_vec).add(up_vec),
        center_slice.sub(right_vec).sub(up_vec),
        center_slice.add(right_vec).sub(up_vec),
    };
}

/// Builds cascade split depths and corresponding light-space matrices.
///
/// `out_splits` and `out_light_space` must have length >= `cascade_count`.
pub fn build_shadow_cascades(config: *const types.RendererConfig, ubo: *const types.PBRUniformBufferObject, light_dir_in: math.Vec3, cascade_count: usize, out_splits: []f32, out_light_space: []math.Mat4) void {
    if (cascade_count == 0) return;
    if (cascade_count > out_splits.len) return;
    if (cascade_count > out_light_space.len) return;

    const view = math.Mat4.fromArray(ubo.view);
    const proj = math.Mat4.fromArray(ubo.proj);

    const near_clip: f32 = config.shadow_near_clip;

    var far_clip: f32 = config.shadow_far_clip;
    const p10 = proj.data[10];
    const p14 = proj.data[14];
    if (@abs(1.0 + p10) > 0.001) {
        far_clip = p14 / (1.0 + p10);
    }

    const minZ = near_clip;
    const maxZ = far_clip;
    const ratio = maxZ / minZ;
    const range = maxZ - minZ;

    const lambda: f32 = config.shadow_split_lambda;

    const cam_pos = math.Vec3.fromArray(ubo.viewPos);
    const cam_right = math.Vec3{ .x = view.data[0], .y = view.data[4], .z = view.data[8] };
    const cam_up = math.Vec3{ .x = view.data[1], .y = view.data[5], .z = view.data[9] };
    const cam_forward = math.Vec3{ .x = -view.data[2], .y = -view.data[6], .z = -view.data[10] };

    const tan_half_fov = 1.0 / proj.data[5];
    const aspect = proj.data[5] / proj.data[0];

    var light_dir = light_dir_in.normalize();

    var last_split_dist: f32 = 0.0;
    var j: usize = 0;
    while (j < cascade_count) : (j += 1) {
        const p = @as(f32, @floatFromInt(j + 1)) / @as(f32, @floatFromInt(cascade_count));
        const logC = minZ * std.math.pow(f32, ratio, p);
        const uniC = minZ + range * p;
        const d = lambda * logC + (1.0 - lambda) * uniC;
        out_splits[j] = d;

        const corners_near = corners_at_dist(last_split_dist, cam_pos, cam_forward, cam_right, cam_up, tan_half_fov, aspect);
        const corners_far = corners_at_dist(d, cam_pos, cam_forward, cam_right, cam_up, tan_half_fov, aspect);
        const world_corners = [8]math.Vec3{ corners_near[0], corners_near[1], corners_near[2], corners_near[3], corners_far[0], corners_far[1], corners_far[2], corners_far[3] };

        var center = math.Vec3.zero();
        for (world_corners) |wc| center = center.add(wc);
        center = center.mul(1.0 / 8.0);

        const zero_pos = math.Vec3.zero();
        const ident_fwd = math.Vec3{ .x = 0, .y = 0, .z = -1 };
        const ident_right = math.Vec3{ .x = 1, .y = 0, .z = 0 };
        const ident_up = math.Vec3{ .x = 0, .y = 1, .z = 0 };
        const vs_corners_near = corners_at_dist(last_split_dist, zero_pos, ident_fwd, ident_right, ident_up, tan_half_fov, aspect);
        const vs_corners_far = corners_at_dist(d, zero_pos, ident_fwd, ident_right, ident_up, tan_half_fov, aspect);
        const vs_corners = [8]math.Vec3{ vs_corners_near[0], vs_corners_near[1], vs_corners_near[2], vs_corners_near[3], vs_corners_far[0], vs_corners_far[1], vs_corners_far[2], vs_corners_far[3] };

        var vs_center = math.Vec3.zero();
        for (vs_corners) |vc| vs_center = vs_center.add(vc);
        vs_center = vs_center.mul(1.0 / 8.0);

        var radius: f32 = 0.0;
        for (vs_corners) |vc| {
            const d2 = vc.sub(vs_center).lengthSq();
            radius = @max(radius, d2);
        }
        radius = std.math.sqrt(radius);
        radius *= 1.4;
        radius = @max(radius, 25.0);
        radius = std.math.ceil(radius * 16.0) / 16.0;

        var up = math.Vec3{ .x = 0, .y = 1, .z = 0 };
        if (std.math.approxEqAbs(f32, @abs(light_dir.dot(up)), 1.0, 0.001)) {
            up = math.Vec3{ .x = 0, .y = 0, .z = 1 };
        }

        const base_light_view = mat4_lookAt(light_dir.mul(-1.0), math.Vec3.zero(), up);
        var center_ls = mul_mat4_vec3(base_light_view, center);

        const shadow_map_width = @as(f32, @floatFromInt(config.shadow_map_size));
        const world_units_per_texel = (2.0 * radius) / shadow_map_width;

        center_ls.x = @floor((center_ls.x - radius) / world_units_per_texel) * world_units_per_texel + radius;
        center_ls.y = @floor((center_ls.y - radius) / world_units_per_texel) * world_units_per_texel + radius;

        const minX = center_ls.x - radius;
        const maxX = center_ls.x + radius;
        const minY = center_ls.y - radius;
        const maxY = center_ls.y + radius;

        const z_range = 4000.0;
        const minZ_ortho = center_ls.z - z_range;
        const maxZ_ortho = center_ls.z + z_range;

        const light_proj = mat4_ortho(minX, maxX, minY, maxY, maxZ_ortho, minZ_ortho);
        out_light_space[j] = light_proj.mul(base_light_view);

        last_split_dist = d;
    }
}
