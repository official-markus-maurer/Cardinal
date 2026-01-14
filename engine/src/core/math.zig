const std = @import("std");

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn toRadians(degrees: f32) f32 {
    return degrees * (std.math.pi / 180.0);
}

pub fn toDegrees(radians: f32) f32 {
    return radians * (180.0 / std.math.pi);
}

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
    _pad: f32 = 0,

    pub fn zero() Vec3 {
        return .{ .x = 0, .y = 0, .z = 0 };
    }

    pub fn one() Vec3 {
        return .{ .x = 1, .y = 1, .z = 1 };
    }

    pub fn add(self: Vec3, other: Vec3) Vec3 {
        const v1: @Vector(4, f32) = @bitCast(self);
        const v2: @Vector(4, f32) = @bitCast(other);
        const res = v1 + v2;
        return .{ .x = res[0], .y = res[1], .z = res[2] };
    }

    pub fn sub(self: Vec3, other: Vec3) Vec3 {
        const v1: @Vector(4, f32) = @bitCast(self);
        const v2: @Vector(4, f32) = @bitCast(other);
        const res = v1 - v2;
        return .{ .x = res[0], .y = res[1], .z = res[2] };
    }

    pub fn mul(self: Vec3, s: f32) Vec3 {
        const v1: @Vector(4, f32) = @bitCast(self);
        const v_s = @as(@Vector(4, f32), @splat(s));
        const res = v1 * v_s;
        return .{ .x = res[0], .y = res[1], .z = res[2] };
    }

    pub fn dot(self: Vec3, other: Vec3) f32 {
        const v1: @Vector(4, f32) = @bitCast(self);
        const v2: @Vector(4, f32) = @bitCast(other);
        // Mask out the w component (padding) to ensure it doesn't affect dot product
        const mask = @Vector(4, f32){ 1, 1, 1, 0 };
        const mul_res = v1 * v2 * mask;
        return @reduce(.Add, mul_res);
    }

    pub fn cross(self: Vec3, other: Vec3) Vec3 {
        // cross(a, b) = a.yzx * b.zxy - a.zxy * b.yzx
        const v1: @Vector(4, f32) = @bitCast(self);
        const v2: @Vector(4, f32) = @bitCast(other);

        // yzx: mask 1, 2, 0, 3
        const v1_yzx = @shuffle(f32, v1, undefined, @Vector(4, i32){ 1, 2, 0, 3 });
        const v2_zxy = @shuffle(f32, v2, undefined, @Vector(4, i32){ 2, 0, 1, 3 });

        const v1_zxy = @shuffle(f32, v1, undefined, @Vector(4, i32){ 2, 0, 1, 3 });
        const v2_yzx = @shuffle(f32, v2, undefined, @Vector(4, i32){ 1, 2, 0, 3 });

        const res = v1_yzx * v2_zxy - v1_zxy * v2_yzx;
        return .{ .x = res[0], .y = res[1], .z = res[2] };
    }

    pub fn lengthSq(self: Vec3) f32 {
        return self.dot(self);
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

    pub fn add(self: Vec4, other: Vec4) Vec4 {
        const v1: @Vector(4, f32) = @bitCast(self);
        const v2: @Vector(4, f32) = @bitCast(other);
        return @bitCast(v1 + v2);
    }

    pub fn sub(self: Vec4, other: Vec4) Vec4 {
        const v1: @Vector(4, f32) = @bitCast(self);
        const v2: @Vector(4, f32) = @bitCast(other);
        return @bitCast(v1 - v2);
    }

    pub fn mul(self: Vec4, s: f32) Vec4 {
        const v1: @Vector(4, f32) = @bitCast(self);
        const v_s = @as(@Vector(4, f32), @splat(s));
        return @bitCast(v1 * v_s);
    }

    pub fn dot(self: Vec4, other: Vec4) f32 {
        const v1: @Vector(4, f32) = @bitCast(self);
        const v2: @Vector(4, f32) = @bitCast(other);
        return @reduce(.Add, v1 * v2);
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
        // Optimized SIMD quaternion multiplication
        // q1 * q2
        // w = w1w2 - x1x2 - y1y2 - z1z2
        // x = w1x2 + x1w2 + y1z2 - z1y2
        // y = w1y2 - x1z2 + y1w2 + z1x2
        // z = w1z2 + x1y2 - y1x2 + z1w2

        const q2 = @as(@Vector(4, f32), @bitCast(other));

        const x1 = @as(@Vector(4, f32), @splat(self.x));
        const y1 = @as(@Vector(4, f32), @splat(self.y));
        const z1 = @as(@Vector(4, f32), @splat(self.z));
        const w1 = @as(@Vector(4, f32), @splat(self.w));

        // Term 1: w1 * q2
        var res = w1 * q2;

        // Term 2: x1 * (w2, -z2, y2, -x2)
        // q2 is (x2, y2, z2, w2) -> swizzle 3, 2, 1, 0
        var t2 = @shuffle(f32, q2, undefined, @Vector(4, i32){ 3, 2, 1, 0 });
        t2 = t2 * @Vector(4, f32){ 1, -1, 1, -1 };
        res = res + x1 * t2;

        // Term 3: y1 * (z2, w2, -x2, -y2)
        // q2 -> swizzle 2, 3, 0, 1
        var t3 = @shuffle(f32, q2, undefined, @Vector(4, i32){ 2, 3, 0, 1 });
        t3 = t3 * @Vector(4, f32){ 1, 1, -1, -1 };
        res = res + y1 * t3;

        // Term 4: z1 * (-y2, x2, w2, -z2)
        // q2 -> swizzle 1, 0, 3, 2
        var t4 = @shuffle(f32, q2, undefined, @Vector(4, i32){ 1, 0, 3, 2 });
        t4 = t4 * @Vector(4, f32){ -1, 1, 1, -1 };
        res = res + z1 * t4;

        return @bitCast(res);
    }

    pub fn toArray(self: Quat) [4]f32 {
        return .{ self.x, self.y, self.z, self.w };
    }

    // Add bitcast helper for Quat if needed
    pub fn toVec4(self: Quat) Vec4 {
        return @bitCast(self);
    }

    pub fn dot(self: Quat, other: Quat) f32 {
        const v1: @Vector(4, f32) = @bitCast(self);
        const v2: @Vector(4, f32) = @bitCast(other);
        return @reduce(.Add, v1 * v2);
    }

    pub fn normalize(self: Quat) Quat {
        const len_sq = self.dot(self);
        if (len_sq > 0) {
            const len = std.math.sqrt(len_sq);
            const v: @Vector(4, f32) = @bitCast(self);
            return @bitCast(v / @as(@Vector(4, f32), @splat(len)));
        }
        return self;
    }

    pub fn conjugate(self: Quat) Quat {
        return .{ .x = -self.x, .y = -self.y, .z = -self.z, .w = self.w };
    }

    pub fn fromAxisAngle(axis: Vec3, angle_radians: f32) Quat {
        const half_angle = angle_radians * 0.5;
        const s = std.math.sin(half_angle);
        const c = std.math.cos(half_angle);
        return .{
            .x = axis.x * s,
            .y = axis.y * s,
            .z = axis.z * s,
            .w = c,
        };
    }

    pub fn slerp(a: Quat, b: Quat, t: f32) Quat {
        var cos_theta = a.dot(b);
        var target = b;

        // If dot product is negative, reverse one quaternion to take the shorter path
        if (cos_theta < 0.0) {
            target = .{ .x = -b.x, .y = -b.y, .z = -b.z, .w = -b.w };
            cos_theta = -cos_theta;
        }

        const DOT_THRESHOLD = 0.9995;
        if (cos_theta > DOT_THRESHOLD) {
            // If inputs are very close, use linear interpolation (and normalize)
            const v_a: @Vector(4, f32) = @bitCast(a);
            const v_b: @Vector(4, f32) = @bitCast(target);
            const v_res = v_a + (v_b - v_a) * @as(@Vector(4, f32), @splat(t));
            const res: Quat = @bitCast(v_res);
            return res.normalize();
        }

        const angle = std.math.acos(cos_theta);
        const sin_angle = std.math.sin(angle);
        
        // Avoid division by zero
        if (std.math.approxEqAbs(f32, sin_angle, 0.0, 1e-6)) {
             return a;
        }

        const w1 = std.math.sin((1.0 - t) * angle) / sin_angle;
        const w2 = std.math.sin(t * angle) / sin_angle;

        const v_a: @Vector(4, f32) = @bitCast(a);
        const v_b: @Vector(4, f32) = @bitCast(target);
        
        return @bitCast(v_a * @as(@Vector(4, f32), @splat(w1)) + v_b * @as(@Vector(4, f32), @splat(w2)));
    }
};

pub const Mat4 = extern struct {
    data: [16]f32,

    pub fn identity() Mat4 {
        return .{
            .data = .{
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            },
        };
    }

    // Column-Major Matrix Multiplication
    // result = self * other
    pub fn mul(self: Mat4, other: Mat4) Mat4 {
        var result = Mat4{ .data = undefined };

        // Columns of self (A)
        const a0: @Vector(4, f32) = self.data[0..4].*;
        const a1: @Vector(4, f32) = self.data[4..8].*;
        const a2: @Vector(4, f32) = self.data[8..12].*;
        const a3: @Vector(4, f32) = self.data[12..16].*;

        comptime var i: usize = 0;
        inline while (i < 4) : (i += 1) {
            // Computing Column i of Result
            // Res_col_i = A * Col_i(B)
            // Res_col_i = B_0i * A_col0 + B_1i * A_col1 + B_2i * A_col2 + B_3i * A_col3

            const b_col_offset = i * 4;
            const b_col = other.data[b_col_offset..];

            const b0 = @as(@Vector(4, f32), @splat(b_col[0]));
            const b1 = @as(@Vector(4, f32), @splat(b_col[1]));
            const b2 = @as(@Vector(4, f32), @splat(b_col[2]));
            const b3 = @as(@Vector(4, f32), @splat(b_col[3]));

            const res_col = a0 * b0 + a1 * b1 + a2 * b2 + a3 * b3;

            result.data[b_col_offset..][0..4].* = res_col;
        }

        return result;
    }

    pub fn transformPoint(self: Mat4, p: Vec3) Vec3 {
        // v' = M * v (Column-Major)
        const x_splat = @as(@Vector(4, f32), @splat(p.x));
        const y_splat = @as(@Vector(4, f32), @splat(p.y));
        const z_splat = @as(@Vector(4, f32), @splat(p.z));
        const w_splat = @as(@Vector(4, f32), @splat(1.0));

        const col0: @Vector(4, f32) = self.data[0..4].*;
        const col1: @Vector(4, f32) = self.data[4..8].*;
        const col2: @Vector(4, f32) = self.data[8..12].*;
        const col3: @Vector(4, f32) = self.data[12..16].*;

        const res = x_splat * col0 + y_splat * col1 + z_splat * col2 + w_splat * col3;

        return .{ .x = res[0], .y = res[1], .z = res[2] };
    }

    pub fn transformVector(self: Mat4, v: Vec3) Vec3 {
        // v' = M * v with w=0 (Direction vector)
        const x_splat = @as(@Vector(4, f32), @splat(v.x));
        const y_splat = @as(@Vector(4, f32), @splat(v.y));
        const z_splat = @as(@Vector(4, f32), @splat(v.z));

        const col0: @Vector(4, f32) = self.data[0..4].*;
        const col1: @Vector(4, f32) = self.data[4..8].*;
        const col2: @Vector(4, f32) = self.data[8..12].*;

        const res = x_splat * col0 + y_splat * col1 + z_splat * col2;

        return .{ .x = res[0], .y = res[1], .z = res[2] };
    }

    pub fn fromArray(arr: [16]f32) Mat4 {
        return .{ .data = arr };
    }

    pub fn fromTRS(t: Vec3, r: Quat, s: Vec3) Mat4 {
        var m = Mat4{ .data = undefined };

        // Rotation elements
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

        const r00 = 1.0 - (yy + zz);
        const r01 = xy + wz;
        const r02 = xz - wy;
        const r10 = xy - wz;
        const r11 = 1.0 - (xx + zz);
        const r12 = yz + wx;
        const r20 = xz + wy;
        const r21 = yz - wx;
        const r22 = 1.0 - (xx + yy);

        // Apply Scale and Rotation (Column Major R * S)
        // Col 0 = Scale.x * Rotation.Col0
        m.data[0] = s.x * r00;
        m.data[1] = s.x * r01;
        m.data[2] = s.x * r02;
        m.data[3] = 0.0;

        // Col 1 = Scale.y * Rotation.Col1
        m.data[4] = s.y * r10;
        m.data[5] = s.y * r11;
        m.data[6] = s.y * r12;
        m.data[7] = 0.0;

        // Col 2 = Scale.z * Rotation.Col2
        m.data[8] = s.z * r20;
        m.data[9] = s.z * r21;
        m.data[10] = s.z * r22;
        m.data[11] = 0.0;

        // Col 3 = Translation
        m.data[12] = t.x;
        m.data[13] = t.y;
        m.data[14] = t.z;
        m.data[15] = 1.0;

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

        // Extract scale using SIMD
        const row0 = @as(@Vector(4, f32), self.data[0..4].*);
        const row1 = @as(@Vector(4, f32), self.data[4..8].*);
        const row2 = @as(@Vector(4, f32), self.data[8..12].*);
        const mask = @Vector(4, f32){ 1, 1, 1, 0 }; // Mask out w component

        var sx = std.math.sqrt(@reduce(.Add, (row0 * row0) * mask));
        const sy = std.math.sqrt(@reduce(.Add, (row1 * row1) * mask));
        const sz = std.math.sqrt(@reduce(.Add, (row2 * row2) * mask));

        // Check for negative determinant (3x3)
        // det = row0 . (row1 x row2)
        const row1_yzx = @shuffle(f32, row1, undefined, @Vector(4, i32){ 1, 2, 0, 3 });
        const row2_zxy = @shuffle(f32, row2, undefined, @Vector(4, i32){ 2, 0, 1, 3 });
        const row1_zxy = @shuffle(f32, row1, undefined, @Vector(4, i32){ 2, 0, 1, 3 });
        const row2_yzx = @shuffle(f32, row2, undefined, @Vector(4, i32){ 1, 2, 0, 3 });

        const cross_res = row1_yzx * row2_zxy - row1_zxy * row2_yzx;
        const det = @reduce(.Add, row0 * cross_res * mask);

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

    pub fn perspective(fov_y_radians: f32, aspect: f32, z_near: f32, z_far: f32) Mat4 {
        var m = Mat4.identity();
        @memset(&m.data, 0);

        const tan_half_fov = std.math.tan(fov_y_radians * 0.5);

        m.data[0] = 1.0 / (aspect * tan_half_fov);
        m.data[5] = -1.0 / tan_half_fov; // Flip Y for Vulkan (if convention requires it) - vulkan_renderer uses this
        m.data[10] = z_far / (z_near - z_far);
        m.data[11] = -1.0;
        m.data[14] = (z_near * z_far) / (z_near - z_far);

        return m;
    }

    pub fn ortho(left: f32, right: f32, bottom: f32, top: f32, z_near: f32, z_far: f32) Mat4 {
        var m = Mat4.identity();

        m.data[0] = 2.0 / (right - left);
        m.data[5] = 2.0 / (bottom - top); // Flip Y for Vulkan (top is usually -Y in clip space if Y is down? No, standard Vulkan Y is down)
        // vulkan_shadows uses 2/(top-bottom) then negates m.data[5] in comment, but actually uses 2/(top-bottom).
        // Let's stick to standard Vulkan ortho:
        // x: [left, right] -> [-1, 1]
        // y: [top, bottom] -> [-1, 1] (Y down in Vulkan)
        // z: [near, far] -> [0, 1]

        m.data[10] = 1.0 / (z_far - z_near);
        m.data[12] = -(right + left) / (right - left);
        m.data[13] = -(bottom + top) / (bottom - top);
        m.data[14] = -z_near / (z_far - z_near);

        return m;
    }

    pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
        const f = center.sub(eye).normalize();
        const s = f.cross(up).normalize();
        const u = s.cross(f);

        var m = Mat4.identity();
        m.data[0] = s.x;
        m.data[4] = s.y;
        m.data[8] = s.z;

        m.data[1] = u.x;
        m.data[5] = u.y;
        m.data[9] = u.z;

        m.data[2] = -f.x;
        m.data[6] = -f.y;
        m.data[10] = -f.z;

        m.data[12] = -s.dot(eye);
        m.data[13] = -u.dot(eye);
        m.data[14] = f.dot(eye);

        return m;
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
        const row0 = @as(@Vector(4, f32), self.data[0..4].*);
        const row1 = @as(@Vector(4, f32), self.data[4..8].*);
        const row2 = @as(@Vector(4, f32), self.data[8..12].*);
        const row3 = @as(@Vector(4, f32), self.data[12..16].*);

        const mask0 = @Vector(4, i32){ 0, ~@as(i32, 0), 1, ~@as(i32, 1) };
        const mask1 = @Vector(4, i32){ 2, ~@as(i32, 2), 3, ~@as(i32, 3) };

        const tmp0_v = @shuffle(f32, row0, row1, mask0); // 0, 4, 1, 5
        const tmp1_v = @shuffle(f32, row0, row1, mask1); // 2, 6, 3, 7
        const tmp2_v = @shuffle(f32, row2, row3, mask0); // 8, 12, 9, 13
        const tmp3_v = @shuffle(f32, row2, row3, mask1); // 10, 14, 11, 15

        // result row0: 0, 4, 8, 12 -> from tmp0_v (0, 4, 1, 5) and tmp2_v (8, 12, 9, 13).
        const res0 = @shuffle(f32, tmp0_v, tmp2_v, @Vector(4, i32){ 0, 1, ~@as(i32, 0), ~@as(i32, 1) });

        // result row1: 1, 5, 9, 13 -> from tmp0_v (0, 4, 1, 5) and tmp2_v (8, 12, 9, 13).
        const res1 = @shuffle(f32, tmp0_v, tmp2_v, @Vector(4, i32){ 2, 3, ~@as(i32, 2), ~@as(i32, 3) });

        // result row2: 2, 6, 10, 14 -> from tmp1_v (2, 6, 3, 7) and tmp3_v (10, 14, 11, 15).
        const res2 = @shuffle(f32, tmp1_v, tmp3_v, @Vector(4, i32){ 0, 1, ~@as(i32, 0), ~@as(i32, 1) });

        // result row3: 3, 7, 11, 15 -> from tmp1_v (2, 6, 3, 7) and tmp3_v (10, 14, 11, 15).
        const res3 = @shuffle(f32, tmp1_v, tmp3_v, @Vector(4, i32){ 2, 3, ~@as(i32, 2), ~@as(i32, 3) });

        var result = Mat4{ .data = undefined };
        result.data[0..4].* = res0;
        result.data[4..8].* = res1;
        result.data[8..12].* = res2;
        result.data[12..16].* = res3;

        return result;
    }
};

pub const Ray = extern struct {
    origin: Vec3,
    direction: Vec3,

    pub fn at(self: Ray, t: f32) Vec3 {
        return self.origin.add(self.direction.mul(t));
    }
};
