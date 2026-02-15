const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const Mat4 = math.Mat4;
const Quat = math.Quat;

const c = @cImport({
    @cInclude("math.h");
    @cInclude("string.h");
    @cInclude("float.h");
});

// Constants
const M_PI = 3.14159265358979323846;
const FLT_EPSILON = 1.19209290e-07;

// === Matrix Operations ===

pub export fn cardinal_matrix_identity(matrix: *[16]f32) callconv(.c) void {
    const m = Mat4.identity();
    matrix.* = m.data;
}

pub export fn cardinal_matrix_multiply(a: *const [16]f32, b: *const [16]f32, result: *[16]f32) callconv(.c) void {
    const ma = Mat4.fromArray(a.*);
    const mb = Mat4.fromArray(b.*);
    const res = ma.mul(mb);
    result.* = res.data;
}

pub export fn cardinal_matrix_from_trs(translation: ?*const [3]f32, rotation: ?*const [4]f32, scale: ?*const [3]f32, matrix: *[16]f32) callconv(.c) void {
    const t = if (translation) |tr| Vec3.fromArray(tr.*) else Vec3.zero();
    const r = if (rotation) |rot| Quat.fromArray(rot.*) else Quat.identity();
    const s = if (scale) |sc| Vec3.fromArray(sc.*) else Vec3.one();

    const m = Mat4.fromTRS(t, r, s);
    matrix.* = m.data;
}

pub export fn cardinal_matrix_from_rt_s(rotation: *const [9]f32, translation: *const [3]f32, scale: f32, result: *[16]f32) callconv(.c) void {
    const r = rotation.*;
    const t = translation.*;
    const s = scale;

    // NIF is Row-Major. Vulkan is Column-Major.
    // Input r: R00, R01, R02, R10, R11, R12, R20, R21, R22
    // Output result (Col-Major):
    // Col 0: M00, M01, M02, M03
    // Col 1: M10, M11, M12, M13
    
    // M00 = R00 * s
    // M10 = R01 * s
    // ...
    
    // Col 0
    result[0] = r[0] * s;
    result[1] = r[3] * s;
    result[2] = r[6] * s;
    result[3] = 0.0;

    // Col 1
    result[4] = r[1] * s;
    result[5] = r[4] * s;
    result[6] = r[7] * s;
    result[7] = 0.0;

    // Col 2
    result[8] = r[2] * s;
    result[9] = r[5] * s;
    result[10] = r[8] * s;
    result[11] = 0.0;

    // Col 3
    result[12] = t[0];
    result[13] = t[1];
    result[14] = t[2];
    result[15] = 1.0;
}

pub export fn cardinal_matrix_decompose(matrix: *const [16]f32, translation: ?*[3]f32, rotation: ?*[4]f32, scale: ?*[3]f32) callconv(.c) bool {
    const m = Mat4.fromArray(matrix.*);
    const result = m.decompose();

    if (translation) |t| {
        t.* = result.t.toArray();
    }

    if (scale) |s| {
        s.* = result.s.toArray();
    }

    if (rotation) |r| {
        r.* = result.r.toArray();
    }

    return true;
}

pub export fn cardinal_matrix_invert(matrix: *const [16]f32, result: *[16]f32) callconv(.c) bool {
    const m = Mat4.fromArray(matrix.*);
    if (m.invert()) |inv| {
        result.* = inv.data;
        return true;
    }
    return false;
}

pub export fn cardinal_matrix_transpose(matrix: *const [16]f32, result: *[16]f32) callconv(.c) void {
    const m = Mat4.fromArray(matrix.*);
    const t = m.transpose();
    result.* = t.data;
}

// === Vector Operations ===

pub export fn cardinal_transform_point(matrix: *const [16]f32, point: *const [3]f32, result: *[3]f32) callconv(.c) void {
    const m = Mat4.fromArray(matrix.*);
    const p = Vec3.fromArray(point.*);

    const res = m.transformPoint(p);
    result.* = res.toArray();
}

pub export fn cardinal_transform_vector(matrix: *const [16]f32, vector: *const [3]f32, result: *[3]f32) callconv(.c) void {
    const m = Mat4.fromArray(matrix.*);
    const v = Vec3.fromArray(vector.*);

    const res = m.transformVector(v);
    result.* = res.toArray();
}

pub export fn cardinal_transform_normal(matrix: *const [16]f32, normal: *const [3]f32, result: *[3]f32) callconv(.c) void {
    var inv_transpose: [9]f32 = undefined;
    const m = matrix.*;

    // Extract 3x3 upper-left matrix
    const mat3 = [9]f32{ m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10] };

    // Calculate determinant
    const det = mat3[0] * (mat3[4] * mat3[8] - mat3[5] * mat3[7]) -
        mat3[1] * (mat3[3] * mat3[8] - mat3[5] * mat3[6]) +
        mat3[2] * (mat3[3] * mat3[7] - mat3[4] * mat3[6]);

    if (@abs(det) < FLT_EPSILON) {
        // Fallback: just normalize
        result.* = normal.*;
        return;
    }

    const inv_det = 1.0 / det;

    inv_transpose[0] = (mat3[4] * mat3[8] - mat3[5] * mat3[7]) * inv_det;
    inv_transpose[1] = (mat3[2] * mat3[7] - mat3[1] * mat3[8]) * inv_det;
    inv_transpose[2] = (mat3[1] * mat3[5] - mat3[2] * mat3[4]) * inv_det;
    inv_transpose[3] = (mat3[5] * mat3[6] - mat3[3] * mat3[8]) * inv_det;
    inv_transpose[4] = (mat3[0] * mat3[8] - mat3[2] * mat3[6]) * inv_det;
    inv_transpose[5] = (mat3[2] * mat3[3] - mat3[0] * mat3[5]) * inv_det;
    inv_transpose[6] = (mat3[3] * mat3[7] - mat3[4] * mat3[6]) * inv_det;
    inv_transpose[7] = (mat3[1] * mat3[6] - mat3[0] * mat3[7]) * inv_det;
    inv_transpose[8] = (mat3[0] * mat3[4] - mat3[1] * mat3[3]) * inv_det;

    const n = Vec3.fromArray(normal.*);
    const res = Vec3{
        .x = inv_transpose[0] * n.x + inv_transpose[3] * n.y + inv_transpose[6] * n.z,
        .y = inv_transpose[1] * n.x + inv_transpose[4] * n.y + inv_transpose[7] * n.z,
        .z = inv_transpose[2] * n.x + inv_transpose[5] * n.y + inv_transpose[8] * n.z,
    };

    result.* = res.normalize().toArray();
}

pub export fn cardinal_quaternion_normalize(rotation: *[4]f32) callconv(.c) void {
    const q = Quat.fromArray(rotation.*);
    const n = q.normalize();
    rotation.* = n.toArray();
}
