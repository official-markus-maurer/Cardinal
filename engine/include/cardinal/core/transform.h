#ifndef CARDINAL_CORE_TRANSFORM_H
#define CARDINAL_CORE_TRANSFORM_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @file transform.h
 * @brief Transform utility functions for matrix operations and coordinate space conversions.
 */

// === Matrix Operations ===

/**
 * @brief Creates a 4x4 identity matrix.
 * @param matrix Output 4x4 matrix (16 floats, column-major).
 */
void cardinal_matrix_identity(float* matrix);

/**
 * @brief Multiplies two 4x4 matrices.
 * @param a First matrix (16 floats, column-major).
 * @param b Second matrix (16 floats, column-major).
 * @param result Output matrix (16 floats, column-major).
 */
void cardinal_matrix_multiply(const float* a, const float* b, float* result);

/**
 * @brief Creates a transformation matrix from translation, rotation (quaternion), and scale.
 * @param translation Translation vector (3 floats), can be NULL for no translation.
 * @param rotation Rotation quaternion (4 floats: x, y, z, w), can be NULL for no rotation.
 * @param scale Scale vector (3 floats), can be NULL for uniform scale of 1.
 * @param matrix Output 4x4 transformation matrix (16 floats, column-major).
 */
void cardinal_matrix_from_trs(const float* translation, const float* rotation, const float* scale, float* matrix);

/**
 * @brief Decomposes a transformation matrix into translation, rotation, and scale components.
 * @param matrix Input 4x4 transformation matrix (16 floats, column-major).
 * @param translation Output translation vector (3 floats), can be NULL if not needed.
 * @param rotation Output rotation quaternion (4 floats: x, y, z, w), can be NULL if not needed.
 * @param scale Output scale vector (3 floats), can be NULL if not needed.
 * @return true if decomposition was successful, false otherwise.
 */
bool cardinal_matrix_decompose(const float* matrix, float* translation, float* rotation, float* scale);

/**
 * @brief Inverts a 4x4 transformation matrix.
 * @param matrix Input 4x4 matrix (16 floats, column-major).
 * @param result Output inverted matrix (16 floats, column-major).
 * @return true if inversion was successful, false if matrix is singular.
 */
bool cardinal_matrix_invert(const float* matrix, float* result);

/**
 * @brief Transposes a 4x4 matrix.
 * @param matrix Input 4x4 matrix (16 floats, column-major).
 * @param result Output transposed matrix (16 floats, column-major).
 */
void cardinal_matrix_transpose(const float* matrix, float* result);

// === Vector Operations ===

/**
 * @brief Transforms a 3D point by a 4x4 matrix.
 * @param matrix 4x4 transformation matrix (16 floats, column-major).
 * @param point Input 3D point (3 floats).
 * @param result Output transformed point (3 floats).
 */
void cardinal_transform_point(const float* matrix, const float* point, float* result);

/**
 * @brief Transforms a 3D vector by a 4x4 matrix (ignores translation).
 * @param matrix 4x4 transformation matrix (16 floats, column-major).
 * @param vector Input 3D vector (3 floats).
 * @param result Output transformed vector (3 floats).
 */
void cardinal_transform_vector(const float* matrix, const float* vector, float* result);

/**
 * @brief Transforms a 3D normal by a 4x4 matrix (uses inverse transpose).
 * @param matrix 4x4 transformation matrix (16 floats, column-major).
 * @param normal Input 3D normal (3 floats).
 * @param result Output transformed normal (3 floats).
 */
void cardinal_transform_normal(const float* matrix, const float* normal, float* result);

// === Quaternion Operations ===

/**
 * @brief Creates an identity quaternion.
 * @param quaternion Output quaternion (4 floats: x, y, z, w).
 */
void cardinal_quaternion_identity(float* quaternion);

/**
 * @brief Multiplies two quaternions.
 * @param a First quaternion (4 floats: x, y, z, w).
 * @param b Second quaternion (4 floats: x, y, z, w).
 * @param result Output quaternion (4 floats: x, y, z, w).
 */
void cardinal_quaternion_multiply(const float* a, const float* b, float* result);

/**
 * @brief Normalizes a quaternion.
 * @param quaternion Input/output quaternion (4 floats: x, y, z, w).
 */
void cardinal_quaternion_normalize(float* quaternion);

/**
 * @brief Converts a quaternion to a 3x3 rotation matrix.
 * @param quaternion Input quaternion (4 floats: x, y, z, w).
 * @param matrix Output 3x3 rotation matrix (9 floats, column-major).
 */
void cardinal_quaternion_to_matrix3(const float* quaternion, float* matrix);

/**
 * @brief Converts a quaternion to a 4x4 rotation matrix.
 * @param quaternion Input quaternion (4 floats: x, y, z, w).
 * @param matrix Output 4x4 rotation matrix (16 floats, column-major).
 */
void cardinal_quaternion_to_matrix4(const float* quaternion, float* matrix);

/**
 * @brief Creates a quaternion from Euler angles (in radians).
 * @param pitch Rotation around X-axis (radians).
 * @param yaw Rotation around Y-axis (radians).
 * @param roll Rotation around Z-axis (radians).
 * @param quaternion Output quaternion (4 floats: x, y, z, w).
 */
void cardinal_quaternion_from_euler(float pitch, float yaw, float roll, float* quaternion);

/**
 * @brief Converts a quaternion to Euler angles (in radians).
 * @param quaternion Input quaternion (4 floats: x, y, z, w).
 * @param pitch Output rotation around X-axis (radians).
 * @param yaw Output rotation around Y-axis (radians).
 * @param roll Output rotation around Z-axis (radians).
 */
void cardinal_quaternion_to_euler(const float* quaternion, float* pitch, float* yaw, float* roll);

// === Utility Functions ===

/**
 * @brief Checks if two matrices are approximately equal.
 * @param a First matrix (16 floats).
 * @param b Second matrix (16 floats).
 * @param epsilon Tolerance for comparison.
 * @return true if matrices are approximately equal, false otherwise.
 */
bool cardinal_matrix_equals(const float* a, const float* b, float epsilon);

/**
 * @brief Extracts the translation component from a transformation matrix.
 * @param matrix Input 4x4 transformation matrix (16 floats, column-major).
 * @param translation Output translation vector (3 floats).
 */
void cardinal_matrix_get_translation(const float* matrix, float* translation);

/**
 * @brief Sets the translation component of a transformation matrix.
 * @param matrix Input/output 4x4 transformation matrix (16 floats, column-major).
 * @param translation Input translation vector (3 floats).
 */
void cardinal_matrix_set_translation(float* matrix, const float* translation);

/**
 * @brief Extracts the scale component from a transformation matrix.
 * @param matrix Input 4x4 transformation matrix (16 floats, column-major).
 * @param scale Output scale vector (3 floats).
 */
void cardinal_matrix_get_scale(const float* matrix, float* scale);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_CORE_TRANSFORM_H