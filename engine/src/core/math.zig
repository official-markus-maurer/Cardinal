const std = @import("std");

pub const Vec2 = extern struct {
    x: f32,
    y: f32,

    pub fn zero() Vec2 {
        return .{ .x = 0, .y = 0 };
    }

    pub fn one() Vec2 {
        return .{ .x = 1, .y = 1 };
    }

    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn scale(self: Vec2, s: f32) Vec2 {
        return .{ .x = self.x * s, .y = self.y * s };
    }

    pub fn toArray(self: Vec2) [2]f32 {
        return .{ self.x, self.y };
    }
};

pub const Vec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn zero() Vec3 {
        return .{ .x = 0, .y = 0, .z = 0 };
    }

    pub fn one() Vec3 {
        return .{ .x = 1, .y = 1, .z = 1 };
    }

    pub fn add(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
    }

    pub fn sub(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
    }

    pub fn mul(self: Vec3, s: f32) Vec3 {
        return .{ .x = self.x * s, .y = self.y * s, .z = self.z * s };
    }

    pub fn dot(self: Vec3, other: Vec3) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }

    pub fn cross(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.y * other.z - self.z * other.y,
            .y = self.z * other.x - self.x * other.z,
            .z = self.x * other.y - self.y * other.x,
        };
    }

    pub fn lengthSq(self: Vec3) f32 {
        return self.x * self.x + self.y * self.y + self.z * self.z;
    }

    pub fn length(self: Vec3) f32 {
        return std.math.sqrt(self.lengthSq());
    }

    pub fn normalize(self: Vec3) Vec3 {
        const len = self.length();
        if (len > 0) {
            return self.mul(1.0 / len);
        }
        return self;
    }

    pub fn toArray(self: Vec3) [3]f32 {
        return .{ self.x, self.y, self.z };
    }

    pub fn fromArray(arr: [3]f32) Vec3 {
        return .{ .x = arr[0], .y = arr[1], .z = arr[2] };
    }
};

pub const Vec4 = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn zero() Vec4 {
        return .{ .x = 0, .y = 0, .z = 0, .w = 0 };
    }

    pub fn fromVec3(v: Vec3, w: f32) Vec4 {
        return .{ .x = v.x, .y = v.y, .z = v.z, .w = w };
    }

    pub fn toArray(self: Vec4) [4]f32 {
        return .{ self.x, self.y, self.z, self.w };
    }
};

pub const Quat = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn identity() Quat {
        return .{ .x = 0, .y = 0, .z = 0, .w = 1 };
    }

    pub fn fromArray(arr: [4]f32) Quat {
        return .{ .x = arr[0], .y = arr[1], .z = arr[2], .w = arr[3] };
    }

    pub fn mul(self: Quat, other: Quat) Quat {
        return .{
            .x = self.w * other.x + self.x * other.w + self.y * other.z - self.z * other.y,
            .y = self.w * other.y - self.x * other.z + self.y * other.w + self.z * other.x,
            .z = self.w * other.z + self.x * other.y - self.y * other.x + self.z * other.w,
            .w = self.w * other.w - self.x * other.x - self.y * other.y - self.z * other.z,
        };
    }

    pub fn toArray(self: Quat) [4]f32 {
        return .{ self.x, self.y, self.z, self.w };
    }
};

pub const Mat4 = extern struct {
    data: [16]f32,

    pub fn identity() Mat4 {
        var m = Mat4{ .data = undefined };
        @memset(&m.data, 0);
        m.data[0] = 1;
        m.data[5] = 1;
        m.data[10] = 1;
        m.data[15] = 1;
        return m;
    }

    // Assumes Row-Major A * B for consistency with legacy code logic
    // result[i, j] = row(i) . col(j)
    // i = row, j = col
    // idx = i * 4 + j
    pub fn mul(self: Mat4, other: Mat4) Mat4 {
        var result = Mat4{ .data = undefined };
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            var j: usize = 0;
            while (j < 4) : (j += 1) {
                var sum: f32 = 0;
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    sum += self.data[i * 4 + k] * other.data[k * 4 + j];
                }
                result.data[i * 4 + j] = sum;
            }
        }
        return result;
    }

    pub fn transformPoint(self: Mat4, p: Vec3) Vec3 {
        return .{
            .x = self.data[0] * p.x + self.data[4] * p.y + self.data[8] * p.z + self.data[12],
            .y = self.data[1] * p.x + self.data[5] * p.y + self.data[9] * p.z + self.data[13],
            .z = self.data[2] * p.x + self.data[6] * p.y + self.data[10] * p.z + self.data[14],
        };
    }

    pub fn transformVector(self: Mat4, v: Vec3) Vec3 {
        return .{
            .x = self.data[0] * v.x + self.data[4] * v.y + self.data[8] * v.z,
            .y = self.data[1] * v.x + self.data[5] * v.y + self.data[9] * v.z,
            .z = self.data[2] * v.x + self.data[6] * v.y + self.data[10] * v.z,
        };
    }

    pub fn fromArray(arr: [16]f32) Mat4 {
        return .{ .data = arr };
    }

    pub fn fromTRS(t: Vec3, r: Quat, s: Vec3) Mat4 {
        // Based on transform.zig implementation
        var m = Mat4.identity();

        // Scale
        m.data[0] *= s.x;
        m.data[5] *= s.y;
        m.data[10] *= s.z;

        // Rotation
        const x = r.x;
        const y = r.y;
        const z = r.z;
        const w = r.w;
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

        var rot_matrix = Mat4.identity();
        rot_matrix.data[0] = 1.0 - (yy + zz);
        rot_matrix.data[1] = xy + wz;
        rot_matrix.data[2] = xz - wy;
        rot_matrix.data[4] = xy - wz;
        rot_matrix.data[5] = 1.0 - (xx + zz);
        rot_matrix.data[6] = yz + wx;
        rot_matrix.data[8] = xz + wy;
        rot_matrix.data[9] = yz - wx;
        rot_matrix.data[10] = 1.0 - (xx + yy);

        // Apply rotation
        // Row major: v * S * R * T.
        // m is currently S. Multiply by R.
        m = m.mul(rot_matrix);

        // Apply translation
        m.data[12] += t.x;
        m.data[13] += t.y;
        m.data[14] += t.z;

        return m;
    }

    pub fn decompose(self: Mat4) struct { t: Vec3, r: Quat, s: Vec3 } {
        var t: Vec3 = undefined;
        var r: Quat = undefined;
        var s: Vec3 = undefined;

        // Extract translation
        t.x = self.data[12];
        t.y = self.data[13];
        t.z = self.data[14];

        // Extract scale
        var sx = std.math.sqrt(self.data[0] * self.data[0] + self.data[1] * self.data[1] + self.data[2] * self.data[2]);
        const sy = std.math.sqrt(self.data[4] * self.data[4] + self.data[5] * self.data[5] + self.data[6] * self.data[6]);
        const sz = std.math.sqrt(self.data[8] * self.data[8] + self.data[9] * self.data[9] + self.data[10] * self.data[10]);

        // Check for negative determinant
        const det = self.data[0] * (self.data[5] * self.data[10] - self.data[6] * self.data[9]) -
            self.data[1] * (self.data[4] * self.data[10] - self.data[6] * self.data[8]) +
            self.data[2] * (self.data[4] * self.data[9] - self.data[5] * self.data[8]);
        if (det < 0) {
            sx = -sx;
        }

        s.x = sx;
        s.y = sy;
        s.z = sz;

        // Extract rotation
        var rot_matrix: [9]f32 = undefined;
        rot_matrix[0] = self.data[0] / sx;
        rot_matrix[1] = self.data[1] / sx;
        rot_matrix[2] = self.data[2] / sx;
        rot_matrix[3] = self.data[4] / sy;
        rot_matrix[4] = self.data[5] / sy;
        rot_matrix[5] = self.data[6] / sy;
        rot_matrix[6] = self.data[8] / sz;
        rot_matrix[7] = self.data[9] / sz;
        rot_matrix[8] = self.data[10] / sz;

        const trace = rot_matrix[0] + rot_matrix[4] + rot_matrix[8];
        if (trace > 0) {
            const val = std.math.sqrt(trace + 1.0) * 2;
            r.w = 0.25 * val;
            r.x = (rot_matrix[7] - rot_matrix[5]) / val;
            r.y = (rot_matrix[2] - rot_matrix[6]) / val;
            r.z = (rot_matrix[3] - rot_matrix[1]) / val;
        } else if ((rot_matrix[0] > rot_matrix[4]) and (rot_matrix[0] > rot_matrix[8])) {
            const val = std.math.sqrt(1.0 + rot_matrix[0] - rot_matrix[4] - rot_matrix[8]) * 2;
            r.w = (rot_matrix[7] - rot_matrix[5]) / val;
            r.x = 0.25 * val;
            r.y = (rot_matrix[1] + rot_matrix[3]) / val;
            r.z = (rot_matrix[2] + rot_matrix[6]) / val;
        } else if (rot_matrix[4] > rot_matrix[8]) {
            const val = std.math.sqrt(1.0 + rot_matrix[4] - rot_matrix[0] - rot_matrix[8]) * 2;
            r.w = (rot_matrix[2] - rot_matrix[6]) / val;
            r.x = (rot_matrix[1] + rot_matrix[3]) / val;
            r.y = 0.25 * val;
            r.z = (rot_matrix[5] + rot_matrix[7]) / val;
        } else {
            const val = std.math.sqrt(1.0 + rot_matrix[8] - rot_matrix[0] - rot_matrix[4]) * 2;
            r.w = (rot_matrix[3] - rot_matrix[1]) / val;
            r.x = (rot_matrix[2] + rot_matrix[6]) / val;
            r.y = (rot_matrix[5] + rot_matrix[7]) / val;
            r.z = 0.25 * val;
        }

        return .{ .t = t, .r = r, .s = s };
    }

    pub fn invert(self: Mat4) ?Mat4 {
        var inv: [16]f32 = undefined;
        const matrix = self.data;

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
        const FLT_EPSILON = 1.19209290e-07;

        if (@abs(det) < FLT_EPSILON)
            return null;

        det = 1.0 / det;

        var result = Mat4{ .data = undefined };
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            result.data[i] = inv[i] * det;
        }

        return result;
    }

    pub fn transpose(self: Mat4) Mat4 {
        var result = Mat4{ .data = undefined };
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            var j: usize = 0;
            while (j < 4) : (j += 1) {
                result.data[j * 4 + i] = self.data[i * 4 + j];
            }
        }
        return result;
    }
};
