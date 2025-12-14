#include "cardinal/core/transform.h"
#include <float.h>
#include <math.h>
#include <string.h>

#ifndef M_PI
    #define M_PI 3.14159265358979323846
#endif

// === Matrix Operations ===

void cardinal_matrix_identity(float* matrix) {
    memset(matrix, 0, 16 * sizeof(float));
    matrix[0] = matrix[5] = matrix[10] = matrix[15] = 1.0f;
}

void cardinal_matrix_multiply(const float* a, const float* b, float* result) {
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            result[i * 4 + j] = 0.0f;
            for (int k = 0; k < 4; k++) {
                result[i * 4 + j] += a[i * 4 + k] * b[k * 4 + j];
            }
        }
    }
}

void cardinal_matrix_from_trs(const float* translation, const float* rotation, const float* scale,
                              float* matrix) {
    // Start with identity
    cardinal_matrix_identity(matrix);

    // Apply scale
    if (scale) {
        matrix[0] *= scale[0];
        matrix[5] *= scale[1];
        matrix[10] *= scale[2];
    }

    // Apply rotation (quaternion to matrix)
    if (rotation) {
        float x = rotation[0], y = rotation[1], z = rotation[2], w = rotation[3];
        float x2 = x + x, y2 = y + y, z2 = z + z;
        float xx = x * x2, xy = x * y2, xz = x * z2;
        float yy = y * y2, yz = y * z2, zz = z * z2;
        float wx = w * x2, wy = w * y2, wz = w * z2;

        float rot_matrix[16];
        cardinal_matrix_identity(rot_matrix);
        rot_matrix[0] = 1.0f - (yy + zz);
        rot_matrix[1] = xy + wz;
        rot_matrix[2] = xz - wy;
        rot_matrix[4] = xy - wz;
        rot_matrix[5] = 1.0f - (xx + zz);
        rot_matrix[6] = yz + wx;
        rot_matrix[8] = xz + wy;
        rot_matrix[9] = yz - wx;
        rot_matrix[10] = 1.0f - (xx + yy);

        float temp[16];
        memcpy(temp, matrix, 16 * sizeof(float));
        cardinal_matrix_multiply(temp, rot_matrix, matrix);
    }

    // Apply translation
    if (translation) {
        matrix[12] += translation[0];
        matrix[13] += translation[1];
        matrix[14] += translation[2];
    }
}

bool cardinal_matrix_decompose(const float* matrix, float* translation, float* rotation,
                               float* scale) {
    // Extract translation
    if (translation) {
        translation[0] = matrix[12];
        translation[1] = matrix[13];
        translation[2] = matrix[14];
    }

    // Extract scale
    float sx = sqrtf(matrix[0] * matrix[0] + matrix[1] * matrix[1] + matrix[2] * matrix[2]);
    float sy = sqrtf(matrix[4] * matrix[4] + matrix[5] * matrix[5] + matrix[6] * matrix[6]);
    float sz = sqrtf(matrix[8] * matrix[8] + matrix[9] * matrix[9] + matrix[10] * matrix[10]);

    // Check for negative determinant (reflection)
    float det = matrix[0] * (matrix[5] * matrix[10] - matrix[6] * matrix[9]) -
                matrix[1] * (matrix[4] * matrix[10] - matrix[6] * matrix[8]) +
                matrix[2] * (matrix[4] * matrix[9] - matrix[5] * matrix[8]);
    if (det < 0) {
        sx = -sx;
    }

    if (scale) {
        scale[0] = sx;
        scale[1] = sy;
        scale[2] = sz;
    }

    // Extract rotation
    if (rotation) {
        // Remove scaling from the matrix
        float rot_matrix[9];
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
        float trace = rot_matrix[0] + rot_matrix[4] + rot_matrix[8];
        if (trace > 0) {
            float s = sqrtf(trace + 1.0f) * 2; // s = 4 * qw
            rotation[3] = 0.25f * s;
            rotation[0] = (rot_matrix[7] - rot_matrix[5]) / s;
            rotation[1] = (rot_matrix[2] - rot_matrix[6]) / s;
            rotation[2] = (rot_matrix[3] - rot_matrix[1]) / s;
        } else if ((rot_matrix[0] > rot_matrix[4]) && (rot_matrix[0] > rot_matrix[8])) {
            float s = sqrtf(1.0f + rot_matrix[0] - rot_matrix[4] - rot_matrix[8]) * 2; // s = 4 * qx
            rotation[3] = (rot_matrix[7] - rot_matrix[5]) / s;
            rotation[0] = 0.25f * s;
            rotation[1] = (rot_matrix[1] + rot_matrix[3]) / s;
            rotation[2] = (rot_matrix[2] + rot_matrix[6]) / s;
        } else if (rot_matrix[4] > rot_matrix[8]) {
            float s = sqrtf(1.0f + rot_matrix[4] - rot_matrix[0] - rot_matrix[8]) * 2; // s = 4 * qy
            rotation[3] = (rot_matrix[2] - rot_matrix[6]) / s;
            rotation[0] = (rot_matrix[1] + rot_matrix[3]) / s;
            rotation[1] = 0.25f * s;
            rotation[2] = (rot_matrix[5] + rot_matrix[7]) / s;
        } else {
            float s = sqrtf(1.0f + rot_matrix[8] - rot_matrix[0] - rot_matrix[4]) * 2; // s = 4 * qz
            rotation[3] = (rot_matrix[3] - rot_matrix[1]) / s;
            rotation[0] = (rot_matrix[2] + rot_matrix[6]) / s;
            rotation[1] = (rot_matrix[5] + rot_matrix[7]) / s;
            rotation[2] = 0.25f * s;
        }
    }

    return true;
}

bool cardinal_matrix_invert(const float* matrix, float* result) {
    float inv[16], det;
    int i;

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

    det = matrix[0] * inv[0] + matrix[1] * inv[4] + matrix[2] * inv[8] + matrix[3] * inv[12];

    if (fabsf(det) < FLT_EPSILON)
        return false;

    det = 1.0f / det;

    for (i = 0; i < 16; i++)
        result[i] = inv[i] * det;

    return true;
}

void cardinal_matrix_transpose(const float* matrix, float* result) {
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            result[j * 4 + i] = matrix[i * 4 + j];
        }
    }
}

// === Vector Operations ===

void cardinal_transform_point(const float* matrix, const float* point, float* result) {
    float x = point[0], y = point[1], z = point[2];
    result[0] = matrix[0] * x + matrix[4] * y + matrix[8] * z + matrix[12];
    result[1] = matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13];
    result[2] = matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14];
}

void cardinal_transform_vector(const float* matrix, const float* vector, float* result) {
    float x = vector[0], y = vector[1], z = vector[2];
    result[0] = matrix[0] * x + matrix[4] * y + matrix[8] * z;
    result[1] = matrix[1] * x + matrix[5] * y + matrix[9] * z;
    result[2] = matrix[2] * x + matrix[6] * y + matrix[10] * z;
}

void cardinal_transform_normal(const float* matrix, const float* normal, float* result) {
    // For normals, we need to use the inverse transpose of the upper 3x3 matrix
    float inv_transpose[9];

    // Extract 3x3 upper-left matrix
    float mat3[9] = {matrix[0], matrix[1], matrix[2], matrix[4], matrix[5],
                     matrix[6], matrix[8], matrix[9], matrix[10]};

    // Calculate determinant
    float det = mat3[0] * (mat3[4] * mat3[8] - mat3[5] * mat3[7]) -
                mat3[1] * (mat3[3] * mat3[8] - mat3[5] * mat3[6]) +
                mat3[2] * (mat3[3] * mat3[7] - mat3[4] * mat3[6]);

    if (fabsf(det) < FLT_EPSILON) {
        // Fallback to simple transformation if matrix is singular
        cardinal_transform_vector(matrix, normal, result);
        return;
    }

    // Calculate inverse transpose
    float inv_det = 1.0f / det;
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
    float x = normal[0], y = normal[1], z = normal[2];
    result[0] = inv_transpose[0] * x + inv_transpose[3] * y + inv_transpose[6] * z;
    result[1] = inv_transpose[1] * x + inv_transpose[4] * y + inv_transpose[7] * z;
    result[2] = inv_transpose[2] * x + inv_transpose[5] * y + inv_transpose[8] * z;
}

// === Quaternion Operations ===

void cardinal_quaternion_identity(float* quaternion) {
    quaternion[0] = 0.0f; // x
    quaternion[1] = 0.0f; // y
    quaternion[2] = 0.0f; // z
    quaternion[3] = 1.0f; // w
}

void cardinal_quaternion_multiply(const float* a, const float* b, float* result) {
    float ax = a[0], ay = a[1], az = a[2], aw = a[3];
    float bx = b[0], by = b[1], bz = b[2], bw = b[3];

    result[0] = aw * bx + ax * bw + ay * bz - az * by;
    result[1] = aw * by - ax * bz + ay * bw + az * bx;
    result[2] = aw * bz + ax * by - ay * bx + az * bw;
    result[3] = aw * bw - ax * bx - ay * by - az * bz;
}

void cardinal_quaternion_normalize(float* quaternion) {
    float x = quaternion[0], y = quaternion[1], z = quaternion[2], w = quaternion[3];
    float length = sqrtf(x * x + y * y + z * z + w * w);

    if (length > FLT_EPSILON) {
        float inv_length = 1.0f / length;
        quaternion[0] *= inv_length;
        quaternion[1] *= inv_length;
        quaternion[2] *= inv_length;
        quaternion[3] *= inv_length;
    } else {
        cardinal_quaternion_identity(quaternion);
    }
}

void cardinal_quaternion_to_matrix3(const float* quaternion, float* matrix) {
    float x = quaternion[0], y = quaternion[1], z = quaternion[2], w = quaternion[3];
    float x2 = x + x, y2 = y + y, z2 = z + z;
    float xx = x * x2, xy = x * y2, xz = x * z2;
    float yy = y * y2, yz = y * z2, zz = z * z2;
    float wx = w * x2, wy = w * y2, wz = w * z2;

    matrix[0] = 1.0f - (yy + zz);
    matrix[1] = xy + wz;
    matrix[2] = xz - wy;
    matrix[3] = xy - wz;
    matrix[4] = 1.0f - (xx + zz);
    matrix[5] = yz + wx;
    matrix[6] = xz + wy;
    matrix[7] = yz - wx;
    matrix[8] = 1.0f - (xx + yy);
}

void cardinal_quaternion_to_matrix4(const float* quaternion, float* matrix) {
    cardinal_matrix_identity(matrix);

    float x = quaternion[0], y = quaternion[1], z = quaternion[2], w = quaternion[3];
    float x2 = x + x, y2 = y + y, z2 = z + z;
    float xx = x * x2, xy = x * y2, xz = x * z2;
    float yy = y * y2, yz = y * z2, zz = z * z2;
    float wx = w * x2, wy = w * y2, wz = w * z2;

    matrix[0] = 1.0f - (yy + zz);
    matrix[1] = xy + wz;
    matrix[2] = xz - wy;
    matrix[4] = xy - wz;
    matrix[5] = 1.0f - (xx + zz);
    matrix[6] = yz + wx;
    matrix[8] = xz + wy;
    matrix[9] = yz - wx;
    matrix[10] = 1.0f - (xx + yy);
}

void cardinal_quaternion_from_euler(float pitch, float yaw, float roll, float* quaternion) {
    float cy = cosf(yaw * 0.5f);
    float sy = sinf(yaw * 0.5f);
    float cp = cosf(pitch * 0.5f);
    float sp = sinf(pitch * 0.5f);
    float cr = cosf(roll * 0.5f);
    float sr = sinf(roll * 0.5f);

    quaternion[3] = cr * cp * cy + sr * sp * sy; // w
    quaternion[0] = sr * cp * cy - cr * sp * sy; // x
    quaternion[1] = cr * sp * cy + sr * cp * sy; // y
    quaternion[2] = cr * cp * sy - sr * sp * cy; // z
}

void cardinal_quaternion_to_euler(const float* quaternion, float* pitch, float* yaw, float* roll) {
    float x = quaternion[0], y = quaternion[1], z = quaternion[2], w = quaternion[3];

    // Roll (x-axis rotation)
    float sinr_cosp = 2 * (w * x + y * z);
    float cosr_cosp = 1 - 2 * (x * x + y * y);
    *roll = atan2f(sinr_cosp, cosr_cosp);

    // Pitch (y-axis rotation)
    float sinp = 2 * (w * y - z * x);
    if (fabsf(sinp) >= 1)
        *pitch = copysignf((float)(M_PI / 2), sinp); // Use 90 degrees if out of range
    else
        *pitch = asinf(sinp);

    // Yaw (z-axis rotation)
    float siny_cosp = 2 * (w * z + x * y);
    float cosy_cosp = 1 - 2 * (y * y + z * z);
    *yaw = atan2f(siny_cosp, cosy_cosp);
}

// === Utility Functions ===

bool cardinal_matrix_equals(const float* a, const float* b, float epsilon) {
    for (int i = 0; i < 16; i++) {
        if (fabsf(a[i] - b[i]) > epsilon) {
            return false;
        }
    }
    return true;
}

void cardinal_matrix_get_translation(const float* matrix, float* translation) {
    translation[0] = matrix[12];
    translation[1] = matrix[13];
    translation[2] = matrix[14];
}

void cardinal_matrix_set_translation(float* matrix, const float* translation) {
    matrix[12] = translation[0];
    matrix[13] = translation[1];
    matrix[14] = translation[2];
}

void cardinal_matrix_get_scale(const float* matrix, float* scale) {
    scale[0] = sqrtf(matrix[0] * matrix[0] + matrix[1] * matrix[1] + matrix[2] * matrix[2]);
    scale[1] = sqrtf(matrix[4] * matrix[4] + matrix[5] * matrix[5] + matrix[6] * matrix[6]);
    scale[2] = sqrtf(matrix[8] * matrix[8] + matrix[9] * matrix[9] + matrix[10] * matrix[10]);

    // Check for negative determinant (reflection)
    float det = matrix[0] * (matrix[5] * matrix[10] - matrix[6] * matrix[9]) -
                matrix[1] * (matrix[4] * matrix[10] - matrix[6] * matrix[8]) +
                matrix[2] * (matrix[4] * matrix[9] - matrix[5] * matrix[8]);
    if (det < 0) {
        scale[0] = -scale[0];
    }
}
