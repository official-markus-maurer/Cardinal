const std = @import("std");

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
    @memset(matrix, 0);
    matrix[0] = 1.0;
    matrix[5] = 1.0;
    matrix[10] = 1.0;
    matrix[15] = 1.0;
}

pub export fn cardinal_matrix_multiply(a: *const [16]f32, b: *const [16]f32, result: *[16]f32) callconv(.c) void {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            result[i * 4 + j] = 0.0;
            var k: usize = 0;
            while (k < 4) : (k += 1) {
                result[i * 4 + j] += a[i * 4 + k] * b[k * 4 + j];
            }
        }
    }
}

pub export fn cardinal_matrix_from_trs(translation: ?*const [3]f32, rotation: ?*const [4]f32, scale: ?*const [3]f32, matrix: *[16]f32) callconv(.c) void {
    // Start with identity
    cardinal_matrix_identity(matrix);

    // Apply scale
    if (scale) |s| {
        matrix[0] *= s[0];
        matrix[5] *= s[1];
        matrix[10] *= s[2];
    }

    // Apply rotation (quaternion to matrix)
    if (rotation) |r| {
        const x = r[0];
        const y = r[1];
        const z = r[2];
        const w = r[3];
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

        var rot_matrix: [16]f32 = undefined;
        cardinal_matrix_identity(&rot_matrix);
        rot_matrix[0] = 1.0 - (yy + zz);
        rot_matrix[1] = xy + wz;
        rot_matrix[2] = xz - wy;
        rot_matrix[4] = xy - wz;
        rot_matrix[5] = 1.0 - (xx + zz);
        rot_matrix[6] = yz + wx;
        rot_matrix[8] = xz + wy;
        rot_matrix[9] = yz - wx;
        rot_matrix[10] = 1.0 - (xx + yy);

        var temp: [16]f32 = undefined;
        @memcpy(&temp, matrix);
        cardinal_matrix_multiply(&temp, &rot_matrix, matrix);
    }

    // Apply translation
    if (translation) |t| {
        matrix[12] += t[0];
        matrix[13] += t[1];
        matrix[14] += t[2];
    }
}

pub export fn cardinal_matrix_decompose(matrix: *const [16]f32, translation: ?* [3]f32, rotation: ?* [4]f32, scale: ?* [3]f32) callconv(.c) bool {
    // Extract translation
    if (translation) |t| {
        t[0] = matrix[12];
        t[1] = matrix[13];
        t[2] = matrix[14];
    }

    // Extract scale
    var sx = std.math.sqrt(matrix[0] * matrix[0] + matrix[1] * matrix[1] + matrix[2] * matrix[2]);
    const sy = std.math.sqrt(matrix[4] * matrix[4] + matrix[5] * matrix[5] + matrix[6] * matrix[6]);
    const sz = std.math.sqrt(matrix[8] * matrix[8] + matrix[9] * matrix[9] + matrix[10] * matrix[10]);

    // Check for negative determinant (reflection)
    const det = matrix[0] * (matrix[5] * matrix[10] - matrix[6] * matrix[9]) -
                matrix[1] * (matrix[4] * matrix[10] - matrix[6] * matrix[8]) +
                matrix[2] * (matrix[4] * matrix[9] - matrix[5] * matrix[8]);
    if (det < 0) {
        sx = -sx;
    }

    if (scale) |s| {
        s[0] = sx;
        s[1] = sy;
        s[2] = sz;
    }

    // Extract rotation
    if (rotation) |r| {
        // Remove scaling from the matrix
        var rot_matrix: [9]f32 = undefined;
        rot_matrix[0] = matrix[0] / sx;
        rot_matrix[1] = matrix[1] / sx;
        rot_matrix[2] = matrix[2] / sx;
        rot_matrix[3] = matrix[4] / sy;
        rot_matrix[4] = matrix[5] / sy;
        rot_matrix[5] = matrix[6] / sy;
        rot_matrix[6] = matrix[8] / sz;
        rot_matrix[7] = matrix[9] / sz;
        rot_matrix[8] = matrix[10] / sz;

        // Convert rotation matrix to quaternion
        const trace = rot_matrix[0] + rot_matrix[4] + rot_matrix[8];
        if (trace > 0) {
            const s = std.math.sqrt(trace + 1.0) * 2; // s = 4 * qw
            r[3] = 0.25 * s;
            r[0] = (rot_matrix[7] - rot_matrix[5]) / s;
            r[1] = (rot_matrix[2] - rot_matrix[6]) / s;
            r[2] = (rot_matrix[3] - rot_matrix[1]) / s;
        } else if ((rot_matrix[0] > rot_matrix[4]) and (rot_matrix[0] > rot_matrix[8])) {
            const s = std.math.sqrt(1.0 + rot_matrix[0] - rot_matrix[4] - rot_matrix[8]) * 2; // s = 4 * qx
            r[3] = (rot_matrix[7] - rot_matrix[5]) / s;
            r[0] = 0.25 * s;
            r[1] = (rot_matrix[1] + rot_matrix[3]) / s;
            r[2] = (rot_matrix[2] + rot_matrix[6]) / s;
        } else if (rot_matrix[4] > rot_matrix[8]) {
            const s = std.math.sqrt(1.0 + rot_matrix[4] - rot_matrix[0] - rot_matrix[8]) * 2; // s = 4 * qy
            r[3] = (rot_matrix[2] - rot_matrix[6]) / s;
            r[0] = (rot_matrix[1] + rot_matrix[3]) / s;
            r[1] = 0.25 * s;
            r[2] = (rot_matrix[5] + rot_matrix[7]) / s;
        } else {
            const s = std.math.sqrt(1.0 + rot_matrix[8] - rot_matrix[0] - rot_matrix[4]) * 2; // s = 4 * qz
            r[3] = (rot_matrix[3] - rot_matrix[1]) / s;
            r[0] = (rot_matrix[2] + rot_matrix[6]) / s;
            r[1] = (rot_matrix[5] + rot_matrix[7]) / s;
            r[2] = 0.25 * s;
        }
    }

    return true;
}

pub export fn cardinal_matrix_invert(matrix: *const [16]f32, result: *[16]f32) callconv(.c) bool {
    var inv: [16]f32 = undefined;

    inv[0] = matrix[5] * matrix[10] * matrix[15] - matrix[5] * matrix[11] * matrix[14] -
             matrix[9] * matrix[6] * matrix[15] + matrix[9] * matrix[7] * matrix[14] +
             matrix[13] * matrix[6] * matrix[11] - matrix[13] * matrix[7] * matrix[10];

    inv[4] = -matrix[4] * matrix[10] * matrix[15] + matrix[4] * matrix[11] * matrix[14] +
             matrix[8] * matrix[6] * matrix[15] - matrix[8] * matrix[7] * matrix[14] -
             matrix[12] * matrix[6] * matrix[11] + matrix[12] * matrix[7] * matrix[10];

    inv[8] = matrix[4] * matrix[9] * matrix[15] - matrix[4] * matrix[11] * matrix[13] -
             matrix[8] * matrix[5] * matrix[15] + matrix[8] * matrix[7] * matrix[13] +
             matrix[12] * matrix[5] * matrix[11] - matrix[12] * matrix[7] * matrix[9];

    inv[12] = -matrix[4] * matrix[9] * matrix[14] + matrix[4] * matrix[10] * matrix[13] +
              matrix[8] * matrix[5] * matrix[14] - matrix[8] * matrix[6] * matrix[13] -
              matrix[12] * matrix[5] * matrix[10] + matrix[12] * matrix[6] * matrix[9];

    inv[1] = -matrix[1] * matrix[10] * matrix[15] + matrix[1] * matrix[11] * matrix[14] +
             matrix[9] * matrix[2] * matrix[15] - matrix[9] * matrix[3] * matrix[14] -
             matrix[13] * matrix[2] * matrix[11] + matrix[13] * matrix[3] * matrix[10];

    inv[5] = matrix[0] * matrix[10] * matrix[15] - matrix[0] * matrix[11] * matrix[14] -
             matrix[8] * matrix[2] * matrix[15] + matrix[8] * matrix[3] * matrix[14] +
             matrix[12] * matrix[2] * matrix[11] - matrix[12] * matrix[3] * matrix[10];

    inv[9] = -matrix[0] * matrix[9] * matrix[15] + matrix[0] * matrix[11] * matrix[13] +
             matrix[8] * matrix[1] * matrix[15] - matrix[8] * matrix[3] * matrix[13] -
             matrix[12] * matrix[1] * matrix[11] + matrix[12] * matrix[3] * matrix[9];

    inv[13] = matrix[0] * matrix[9] * matrix[14] - matrix[0] * matrix[10] * matrix[13] -
              matrix[8] * matrix[1] * matrix[14] + matrix[8] * matrix[2] * matrix[13] +
              matrix[12] * matrix[1] * matrix[10] - matrix[12] * matrix[2] * matrix[9];

    inv[2] = matrix[1] * matrix[6] * matrix[15] - matrix[1] * matrix[7] * matrix[14] -
             matrix[5] * matrix[2] * matrix[15] + matrix[5] * matrix[3] * matrix[14] +
             matrix[13] * matrix[2] * matrix[7] - matrix[13] * matrix[3] * matrix[6];

    inv[6] = -matrix[0] * matrix[6] * matrix[15] + matrix[0] * matrix[7] * matrix[14] +
             matrix[4] * matrix[2] * matrix[15] - matrix[4] * matrix[3] * matrix[14] -
             matrix[12] * matrix[2] * matrix[7] + matrix[12] * matrix[3] * matrix[6];

    inv[10] = matrix[0] * matrix[5] * matrix[15] - matrix[0] * matrix[7] * matrix[13] -
              matrix[4] * matrix[1] * matrix[15] + matrix[4] * matrix[3] * matrix[13] +
              matrix[12] * matrix[1] * matrix[7] - matrix[12] * matrix[3] * matrix[5];

    inv[14] = -matrix[0] * matrix[5] * matrix[14] + matrix[0] * matrix[6] * matrix[13] +
              matrix[4] * matrix[1] * matrix[14] - matrix[4] * matrix[2] * matrix[13] -
              matrix[12] * matrix[1] * matrix[6] + matrix[12] * matrix[2] * matrix[5];

    inv[3] = -matrix[1] * matrix[6] * matrix[11] + matrix[1] * matrix[7] * matrix[10] +
             matrix[5] * matrix[2] * matrix[11] - matrix[5] * matrix[3] * matrix[10] -
             matrix[9] * matrix[2] * matrix[7] + matrix[9] * matrix[3] * matrix[6];

    inv[7] = matrix[0] * matrix[6] * matrix[11] - matrix[0] * matrix[7] * matrix[10] -
             matrix[4] * matrix[2] * matrix[11] + matrix[4] * matrix[3] * matrix[10] +
             matrix[8] * matrix[2] * matrix[7] - matrix[8] * matrix[3] * matrix[6];

    inv[11] = -matrix[0] * matrix[5] * matrix[11] + matrix[0] * matrix[7] * matrix[9] +
              matrix[4] * matrix[1] * matrix[11] - matrix[4] * matrix[3] * matrix[9] -
              matrix[8] * matrix[1] * matrix[7] + matrix[8] * matrix[3] * matrix[5];

    inv[15] = matrix[0] * matrix[5] * matrix[10] - matrix[0] * matrix[6] * matrix[9] -
              matrix[4] * matrix[1] * matrix[10] + matrix[4] * matrix[2] * matrix[9] +
              matrix[8] * matrix[1] * matrix[6] - matrix[8] * matrix[2] * matrix[5];

    var det = matrix[0] * inv[0] + matrix[1] * inv[4] + matrix[2] * inv[8] + matrix[3] * inv[12];

    if (@abs(det) < FLT_EPSILON)
        return false;

    det = 1.0 / det;

    var i: usize = 0;
    while (i < 16) : (i += 1) {
        result[i] = inv[i] * det;
    }

    return true;
}

pub export fn cardinal_matrix_transpose(matrix: *const [16]f32, result: *[16]f32) callconv(.c) void {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            result[j * 4 + i] = matrix[i * 4 + j];
        }
    }
}

// === Vector Operations ===

pub export fn cardinal_transform_point(matrix: *const [16]f32, point: *const [3]f32, result: *[3]f32) callconv(.c) void {
    const x = point[0];
    const y = point[1];
    const z = point[2];
    result[0] = matrix[0] * x + matrix[4] * y + matrix[8] * z + matrix[12];
    result[1] = matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13];
    result[2] = matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14];
}

pub export fn cardinal_transform_vector(matrix: *const [16]f32, vector: *const [3]f32, result: *[3]f32) callconv(.c) void {
    const x = vector[0];
    const y = vector[1];
    const z = vector[2];
    result[0] = matrix[0] * x + matrix[4] * y + matrix[8] * z;
    result[1] = matrix[1] * x + matrix[5] * y + matrix[9] * z;
    result[2] = matrix[2] * x + matrix[6] * y + matrix[10] * z;
}

pub export fn cardinal_transform_normal(matrix: *const [16]f32, normal: *const [3]f32, result: *[3]f32) callconv(.c) void {
    // For normals, we need to use the inverse transpose of the upper 3x3 matrix
    var inv_transpose: [9]f32 = undefined;

    // Extract 3x3 upper-left matrix
    const mat3 = [9]f32{matrix[0], matrix[1], matrix[2], matrix[4], matrix[5],
                     matrix[6], matrix[8], matrix[9], matrix[10]};

    // Calculate determinant
    const det = mat3[0] * (mat3[4] * mat3[8] - mat3[5] * mat3[7]) -
                mat3[1] * (mat3[3] * mat3[8] - mat3[5] * mat3[6]) +
                mat3[2] * (mat3[3] * mat3[7] - mat3[4] * mat3[6]);

    if (@abs(det) < FLT_EPSILON) {
        // Fallback to simple transformation if matrix is singular
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
    quaternion[0] = 0.0; // x
    quaternion[1] = 0.0; // y
    quaternion[2] = 0.0; // z
    quaternion[3] = 1.0; // w
}

pub export fn cardinal_quaternion_multiply(a: *const [4]f32, b: *const [4]f32, result: *[4]f32) callconv(.c) void {
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
    const x = quaternion[0];
    const y = quaternion[1];
    const z = quaternion[2];
    const w = quaternion[3];
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
    cardinal_matrix_identity(matrix);

    const x = quaternion[0];
    const y = quaternion[1];
    const z = quaternion[2];
    const w = quaternion[3];
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
    matrix[4] = xy - wz;
    matrix[5] = 1.0 - (xx + zz);
    matrix[6] = yz + wx;
    matrix[8] = xz + wy;
    matrix[9] = yz - wx;
    matrix[10] = 1.0 - (xx + yy);
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
    scale[0] = std.math.sqrt(matrix[0] * matrix[0] + matrix[1] * matrix[1] + matrix[2] * matrix[2]);
    scale[1] = std.math.sqrt(matrix[4] * matrix[4] + matrix[5] * matrix[5] + matrix[6] * matrix[6]);
    scale[2] = std.math.sqrt(matrix[8] * matrix[8] + matrix[9] * matrix[9] + matrix[10] * matrix[10]);

    // Check for negative determinant (reflection)
    const det = matrix[0] * (matrix[5] * matrix[10] - matrix[6] * matrix[9]) -
                matrix[1] * (matrix[4] * matrix[10] - matrix[6] * matrix[8]) +
                matrix[2] * (matrix[4] * matrix[9] - matrix[5] * matrix[8]);
    if (det < 0) {
        scale[0] = -scale[0];
    }
}
