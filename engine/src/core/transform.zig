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

pub export fn cardinal_matrix_decompose(matrix: *const [16]f32, translation: ?* [3]f32, rotation: ?* [4]f32, scale: ?* [3]f32) callconv(.c) bool {
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
    
    // TODO: Temporary inline implementation
    const x = p.x;
    const y = p.y;
    const z = p.z;
    result[0] = m.data[0] * x + m.data[4] * y + m.data[8] * z + m.data[12];
    result[1] = m.data[1] * x + m.data[5] * y + m.data[9] * z + m.data[13];
    result[2] = m.data[2] * x + m.data[6] * y + m.data[10] * z + m.data[14];
}

pub export fn cardinal_transform_vector(matrix: *const [16]f32, vector: *const [3]f32, result: *[3]f32) callconv(.c) void {
    const m = Mat4.fromArray(matrix.*);
    const v = Vec3.fromArray(vector.*);
    
    const x = v.x;
    const y = v.y;
    const z = v.z;
    result[0] = m.data[0] * x + m.data[4] * y + m.data[8] * z;
    result[1] = m.data[1] * x + m.data[5] * y + m.data[9] * z;
    result[2] = m.data[2] * x + m.data[6] * y + m.data[10] * z;
}

pub export fn cardinal_transform_normal(matrix: *const [16]f32, normal: *const [3]f32, result: *[3]f32) callconv(.c) void {
    
    var inv_transpose: [9]f32 = undefined;
    const m = matrix.*;

    // Extract 3x3 upper-left matrix
    const mat3 = [9]f32{m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10]};

    // Calculate determinant
    const det = mat3[0] * (mat3[4] * mat3[8] - mat3[5] * mat3[7]) -
                mat3[1] * (mat3[3] * mat3[8] - mat3[5] * mat3[6]) +
                mat3[2] * (mat3[3] * mat3[7] - mat3[4] * mat3[6]);

    if (@abs(det) < FLT_EPSILON) {
        cardinal_transform_vector(matrix, normal, result);
        return;
    }

    // Calculate inverse transpose
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

    // Transform normal
    const x = normal[0];
    const y = normal[1];
    const z = normal[2];
    result[0] = inv_transpose[0] * x + inv_transpose[3] * y + inv_transpose[6] * z;
    result[1] = inv_transpose[1] * x + inv_transpose[4] * y + inv_transpose[7] * z;
    result[2] = inv_transpose[2] * x + inv_transpose[5] * y + inv_transpose[8] * z;
}

// === Quaternion Operations ===

pub export fn cardinal_quaternion_identity(quaternion: *[4]f32) callconv(.c) void {
    const q = Quat.identity();
    quaternion.* = q.toArray();
}

pub export fn cardinal_quaternion_multiply(a: *const [4]f32, b: *const [4]f32, result: *[4]f32) callconv(.c) void {
    // TODO: Implement in Math.zig but for now manual.
    const ax = a[0];
    const ay = a[1];
    const az = a[2];
    const aw = a[3];
    const bx = b[0];
    const by = b[1];
    const bz = b[2];
    const bw = b[3];

    result[0] = aw * bx + ax * bw + ay * bz - az * by;
    result[1] = aw * by - ax * bz + ay * bw + az * bx;
    result[2] = aw * bz + ax * by - ay * bx + az * bw;
    result[3] = aw * bw - ax * bx - ay * by - az * bz;
}

pub export fn cardinal_quaternion_normalize(quaternion: *[4]f32) callconv(.c) void {
    const x = quaternion[0];
    const y = quaternion[1];
    const z = quaternion[2];
    const w = quaternion[3];
    const length = std.math.sqrt(x * x + y * y + z * z + w * w);

    if (length > FLT_EPSILON) {
        const inv_length = 1.0 / length;
        quaternion[0] *= inv_length;
        quaternion[1] *= inv_length;
        quaternion[2] *= inv_length;
        quaternion[3] *= inv_length;
    } else {
        cardinal_quaternion_identity(quaternion);
    }
}

pub export fn cardinal_quaternion_to_matrix3(quaternion: *const [4]f32, matrix: *[9]f32) callconv(.c) void {
    const q = Quat.fromArray(quaternion.*);
    
    // Same logic as Mat4.fromTRS but only 3x3
    const x = q.x;
    const y = q.y;
    const z = q.z;
    const w = q.w;
    const x2 = x + x;
    const y2 = y + y;
    const z2 = z + z;
    const xx = x * x2;
    const xy = x * y2;
    const xz = x * z2;
    const yy = y * y2;
    const yz = y * z2;
    const zz = z * z2;
    const wx = w * x2;
    const wy = w * y2;
    const wz = w * z2;

    matrix[0] = 1.0 - (yy + zz);
    matrix[1] = xy + wz;
    matrix[2] = xz - wy;
    matrix[3] = xy - wz;
    matrix[4] = 1.0 - (xx + zz);
    matrix[5] = yz + wx;
    matrix[6] = xz + wy;
    matrix[7] = yz - wx;
    matrix[8] = 1.0 - (xx + yy);
}

pub export fn cardinal_quaternion_to_matrix4(quaternion: *const [4]f32, matrix: *[16]f32) callconv(.c) void {
    const q = Quat.fromArray(quaternion.*);
    const m = Mat4.fromTRS(Vec3.zero(), q, Vec3.one()); // T=0, S=1 -> only rotation
    matrix.* = m.data;
}

pub export fn cardinal_quaternion_from_euler(pitch: f32, yaw: f32, roll: f32, quaternion: *[4]f32) callconv(.c) void {
    const cy = std.math.cos(yaw * 0.5);
    const sy = std.math.sin(yaw * 0.5);
    const cp = std.math.cos(pitch * 0.5);
    const sp = std.math.sin(pitch * 0.5);
    const cr = std.math.cos(roll * 0.5);
    const sr = std.math.sin(roll * 0.5);

    quaternion[3] = cr * cp * cy + sr * sp * sy; // w
    quaternion[0] = sr * cp * cy - cr * sp * sy; // x
    quaternion[1] = cr * sp * cy + sr * cp * sy; // y
    quaternion[2] = cr * cp * sy - sr * sp * cy; // z
}

pub export fn cardinal_quaternion_to_euler(quaternion: *const [4]f32, pitch: *f32, yaw: *f32, roll: *f32) callconv(.c) void {
    const x = quaternion[0];
    const y = quaternion[1];
    const z = quaternion[2];
    const w = quaternion[3];

    // Roll (x-axis rotation)
    const sinr_cosp = 2 * (w * x + y * z);
    const cosr_cosp = 1 - 2 * (x * x + y * y);
    roll.* = std.math.atan2(sinr_cosp, cosr_cosp);

    // Pitch (y-axis rotation)
    const sinp = 2 * (w * y - z * x);
    if (@abs(sinp) >= 1) {
        pitch.* = std.math.copysign(@as(f32, M_PI / 2.0), sinp); // Use 90 degrees if out of range
    } else {
        pitch.* = std.math.asin(sinp);
    }

    // Yaw (z-axis rotation)
    const siny_cosp = 2 * (w * z + x * y);
    const cosy_cosp = 1 - 2 * (y * y + z * z);
    yaw.* = std.math.atan2(siny_cosp, cosy_cosp);
}

// === Utility Functions ===

pub export fn cardinal_matrix_equals(a: *const [16]f32, b: *const [16]f32, epsilon: f32) callconv(.c) bool {
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (@abs(a[i] - b[i]) > epsilon) {
            return false;
        }
    }
    return true;
}

pub export fn cardinal_matrix_get_translation(matrix: *const [16]f32, translation: *[3]f32) callconv(.c) void {
    translation[0] = matrix[12];
    translation[1] = matrix[13];
    translation[2] = matrix[14];
}

pub export fn cardinal_matrix_set_translation(matrix: *[16]f32, translation: *const [3]f32) callconv(.c) void {
    matrix[12] = translation[0];
    matrix[13] = translation[1];
    matrix[14] = translation[2];
}

pub export fn cardinal_matrix_get_scale(matrix: *const [16]f32, scale: *[3]f32) callconv(.c) void {
    // This logic duplicates Mat4.decompose scale extraction
    const m = Mat4.fromArray(matrix.*);
    const decomp = m.decompose();
    scale.* = decomp.s.toArray();
}
