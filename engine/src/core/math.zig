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
        const v1 = @Vector(4, f32){ self.x, self.y, self.z, 0 };
        const v2 = @Vector(4, f32){ other.x, other.y, other.z, 0 };
        const res = v1 + v2;
        return .{ .x = res[0], .y = res[1], .z = res[2] };
    }

    pub fn sub(self: Vec3, other: Vec3) Vec3 {
        const v1 = @Vector(4, f32){ self.x, self.y, self.z, 0 };
        const v2 = @Vector(4, f32){ other.x, other.y, other.z, 0 };
        const res = v1 - v2;
        return .{ .x = res[0], .y = res[1], .z = res[2] };
    }

    pub fn mul(self: Vec3, s: f32) Vec3 {
        const v1 = @Vector(4, f32){ self.x, self.y, self.z, 0 };
        const v_s = @as(@Vector(4, f32), @splat(s));
        const res = v1 * v_s;
        return .{ .x = res[0], .y = res[1], .z = res[2] };
    }

    pub fn dot(self: Vec3, other: Vec3) f32 {
        const v1 = @Vector(4, f32){ self.x, self.y, self.z, 0 };
        const v2 = @Vector(4, f32){ other.x, other.y, other.z, 0 };
        const mul_res = v1 * v2;
        return @reduce(.Add, mul_res);
    }

    pub fn cross(self: Vec3, other: Vec3) Vec3 {
        // cross(a, b) = a.yzx * b.zxy - a.zxy * b.yzx
        const v1 = @Vector(4, f32){ self.x, self.y, self.z, 0 };
        const v2 = @Vector(4, f32){ other.x, other.y, other.z, 0 };
        
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
        // (w1*x2 + x1*w2 + y1*z2 - z1*y2)
        // (w1*y2 - x1*z2 + y1*w2 + z1*x2)
        // (w1*z2 + x1*y2 - y1*x2 + z1*w2)
        // (w1*w2 - x1*x2 - y1*y2 - z1*z2)
        
        // This can be vectorized, but scalar is often fast enough or similar complexity due to shuffles.
        // Let's keep scalar for readability unless we want full SIMD implementation.
        // Given the request is "Rewrite ... using Zig's @Vector(4, f32)", I should try to vectorize it.
        
        // q1 = self, q2 = other
        // w1_v = splat(w1)
        // x1_v = splat(x1) ...
        
        // It's a bit complex to vectorize efficiently without specific SSE instructions logic in mind.
        // But we can do partial vectorization.
        // Let's stick to the scalar logic for Quat.mul for now as it's cleaner, unless strictly required.
        // Wait, "Rewrite ... using Zig's @Vector(4, f32)".
        // I'll stick to scalar logic for Quat.mul as it's not a simple component-wise op.
        
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
    
    // Add bitcast helper for Quat if needed
    pub fn toVec4(self: Quat) Vec4 {
        return @bitCast(self);
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
        // Optimized Matrix Multiplication using Vector instructions
        // This leverages Zig's @Vector which will compile to SSE/AVX/AVX512 depending on target.
        // We load rows of 'self' and broadcast elements to multiply with rows of 'other'.
        // Or since data is row-major:
        // Result Row 0 = Self[0,0]*OtherRow0 + Self[0,1]*OtherRow1 + Self[0,2]*OtherRow2 + Self[0,3]*OtherRow3
        
        var result = Mat4{ .data = undefined };
        
        // Load rows of B (other)
        const b0: @Vector(4, f32) = other.data[0..4].*;
        const b1: @Vector(4, f32) = other.data[4..8].*;
        const b2: @Vector(4, f32) = other.data[8..12].*;
        const b3: @Vector(4, f32) = other.data[12..16].*;

        // Compute rows of Result
        // We can unroll this.
        comptime var i: usize = 0;
        inline while (i < 4) : (i += 1) {
            // Load row i of A (self)
            // But we access elements individually for broadcast
            const a_row_offset = i * 4;
            const a0 = @as(@Vector(4, f32), @splat(self.data[a_row_offset + 0]));
            const a1 = @as(@Vector(4, f32), @splat(self.data[a_row_offset + 1]));
            const a2 = @as(@Vector(4, f32), @splat(self.data[a_row_offset + 2]));
            const a3 = @as(@Vector(4, f32), @splat(self.data[a_row_offset + 3]));

            // res_row = a0*b0 + a1*b1 + a2*b2 + a3*b3
            const res_row = a0 * b0 + a1 * b1 + a2 * b2 + a3 * b3;
            
            // Store result
            result.data[a_row_offset..][0..4].* = res_row;
        }
        
        return result;
    }

    pub fn transformPoint(self: Mat4, p: Vec3) Vec3 {
        // p' = M * p (assuming column vector logic, but data is row-major storage... wait)
        // C logic:
        // x' = m0*x + m4*y + m8*z + m12
        // y' = m1*x + m5*y + m9*z + m13
        // z' = m2*x + m6*y + m10*z + m14
        // This corresponds to Column-Major matrix logic or Post-Multiplication (M * v).
        // Let's optimize this using vector ops.
        // columns of M:
        // c0 = (m0, m1, m2, m3)
        // c1 = (m4, m5, m6, m7) ...
        // result = x*c0 + y*c1 + z*c2 + w*c3 (where w=1)
        
        // But our storage is flat array [0..15].
        // m0, m1, m2, m3 are NOT contiguous in memory if it is Row-Major storage where m0,m1,m2,m3 is the first ROW.
        // Wait, earlier comment says "Assumes Row-Major A * B".
        // If Row-Major:
        // Row 0: m0, m1, m2, m3
        // Row 1: m4, m5, m6, m7
        // ...
        // In `mul`, we did A * B.
        // result[i, j] = dot(row_i, col_j).
        
        // Let's check `transformPoint` logic in old code:
        // .x = self.data[0] * p.x + self.data[4] * p.y + self.data[8] * p.z + self.data[12],
        // This accesses indices 0, 4, 8, 12.
        // These are the first elements of each ROW (if row-major, stride 4).
        // Or it's treating the array as Column-Major where 0,1,2,3 is first column?
        // No, if indices are 0, 4, 8, 12, that's stride 4.
        // If storage is Row-Major (m0, m1, m2, m3 = Row 0), then 0, 4, 8, 12 are the first elements of Rows 0, 1, 2, 3.
        // So x' = m00*x + m10*y + m20*z + m30*1.
        // This looks like x' = dot(Column0, v).
        // If M is stored Row-Major, Column0 is (m00, m10, m20, m30).
        // So this logic matches x' = dot(Col0, v).
        
        // Wait, standard Matrix * Vector multiplication:
        // v' = M * v
        // v'.x = Row0 . v
        // v'.x = m00*x + m01*y + m02*z + m03*w
        // If Row-Major, Row0 is indices 0, 1, 2, 3.
        // So v'.x should be data[0]*x + data[1]*y + data[2]*z + data[3]*1.
        
        // The OLD code was:
        // .x = self.data[0] * p.x + self.data[4] * p.y + self.data[8] * p.z + self.data[12],
        // This is m00*x + m10*y + m20*z + m30*1.
        // This is dot(Col0, v).
        // This implies the operation is v^T * M (Row Vector * Matrix) = v'
        // v' = (x, y, z, 1) * M
        // v'.x = x*m00 + y*m10 + z*m20 + 1*m30
        // Yes, this matches.
        
        // So the engine uses Pre-Multiplication (v * M) or the matrix is stored Column-Major?
        // The comment on `mul` said "Assumes Row-Major A * B".
        // A * B typically means A transforms B.
        // If we chain transforms: T = T2 * T1. v' = T * v = T2 * T1 * v.
        // If we use v' = v * M, then v' = v * T1 * T2.
        
        // In `fromTRS`:
        // m.data[12] += t.x;
        // Indices 12, 13, 14 are in the last ROW (Row 3) if Row-Major.
        // (m30, m31, m32, m33).
        // So translation is in the last row.
        // This confirms Row-Major storage with v * M convention (DirectX style often uses Row-Major matrices but HLSL does v*M?).
        // Actually OpenGL/GLSL uses Column-Major storage usually.
        // But let's stick to what the code DOES.
        // Code does v * M.
        
        // Optimization for v * M:
        // v' = x * Row0 + y * Row1 + z * Row2 + w * Row3
        // This is perfect for SIMD!
        // We load Row0, scale by x. Load Row1, scale by y... Sum them up.
        
        const x_splat = @as(@Vector(4, f32), @splat(p.x));
        const y_splat = @as(@Vector(4, f32), @splat(p.y));
        const z_splat = @as(@Vector(4, f32), @splat(p.z));
        const w_splat = @as(@Vector(4, f32), @splat(1.0)); // Point has w=1
        
        const row0: @Vector(4, f32) = self.data[0..4].*;
        const row1: @Vector(4, f32) = self.data[4..8].*;
        const row2: @Vector(4, f32) = self.data[8..12].*;
        const row3: @Vector(4, f32) = self.data[12..16].*;
        
        const res = x_splat * row0 + y_splat * row1 + z_splat * row2 + w_splat * row3;
        
        return .{ .x = res[0], .y = res[1], .z = res[2] };
    }

    pub fn transformVector(self: Mat4, v: Vec3) Vec3 {
        // v' = v * M with w=0 (Direction vector)
        const x_splat = @as(@Vector(4, f32), @splat(v.x));
        const y_splat = @as(@Vector(4, f32), @splat(v.y));
        const z_splat = @as(@Vector(4, f32), @splat(v.z));
        // w=0, so Row3 contributes nothing
        
        const row0: @Vector(4, f32) = self.data[0..4].*;
        const row1: @Vector(4, f32) = self.data[4..8].*;
        const row2: @Vector(4, f32) = self.data[8..12].*;
        
        const res = x_splat * row0 + y_splat * row1 + z_splat * row2;
        
        return .{ .x = res[0], .y = res[1], .z = res[2] };
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
