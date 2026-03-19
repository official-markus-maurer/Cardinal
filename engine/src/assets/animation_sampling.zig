//! Stateless animation curve sampling.
//!
//! Provides pure interpolation helpers for glTF-style animation curves:
//! step/linear/cubic-spline, including quaternion-friendly paths.
//!
//! This is separated from the animation system to reduce rebuild scope and to allow
//! reuse in other animation backends.
//!
//! TODO: Add unit tests for edge cases (degenerate time ranges, quaternion sign flips).
const std = @import("std");

fn find_keyframe_indices(input: [*]const f32, input_count: u32, time: f32, prev_index: *u32, next_index: *u32, factor: *f32) bool {
    if (input_count == 0) return false;

    if (time <= input[0]) {
        prev_index.* = 0;
        next_index.* = 0;
        factor.* = 0.0;
        return true;
    }

    if (time >= input[input_count - 1]) {
        prev_index.* = input_count - 1;
        next_index.* = input_count - 1;
        factor.* = 0.0;
        return true;
    }

    var left: u32 = 0;
    var right: u32 = input_count - 1;

    while (left < right - 1) {
        const mid = (left + right) / 2;
        if (input[mid] <= time) {
            left = mid;
        } else {
            right = mid;
        }
    }

    prev_index.* = left;
    next_index.* = right;

    const time_diff = input[right] - input[left];
    factor.* = if (time_diff > 0.0) (time - input[left]) / time_diff else 0.0;
    return true;
}

fn find_keyframe_indices_with_hint(input: [*]const f32, input_count: u32, time: f32, last_index: *u32, prev_index: *u32, next_index: *u32, factor: *f32) bool {
    if (input_count == 0) return false;

    if (time <= input[0]) {
        prev_index.* = 0;
        next_index.* = 0;
        factor.* = 0.0;
        last_index.* = 0;
        return true;
    }

    if (time >= input[input_count - 1]) {
        const last = input_count - 1;
        prev_index.* = last;
        next_index.* = last;
        factor.* = 0.0;
        last_index.* = last;
        return true;
    }

    var idx = last_index.*;
    if (idx >= input_count) idx = 0;

    while (idx + 1 < input_count and time > input[idx + 1]) idx += 1;
    while (idx > 0 and time < input[idx]) idx -= 1;

    if (idx + 1 < input_count and input[idx] <= time and time <= input[idx + 1]) {
        prev_index.* = idx;
        next_index.* = idx + 1;
    } else {
        var left: u32 = 0;
        var right: u32 = input_count - 1;
        while (left < right - 1) {
            const mid = (left + right) / 2;
            if (input[mid] <= time) {
                left = mid;
            } else {
                right = mid;
            }
        }
        prev_index.* = left;
        next_index.* = right;
    }

    last_index.* = prev_index.*;
    const time_diff = input[next_index.*] - input[prev_index.*];
    factor.* = if (time_diff > 0.0) (time - input[prev_index.*]) / time_diff else 0.0;
    return true;
}

fn lerp_vector(a: [*]const f32, b: [*]const f32, t: f32, component_count: u32, result: [*]f32) void {
    var i: u32 = 0;
    while (i < component_count) : (i += 1) {
        result[i] = a[i] + t * (b[i] - a[i]);
    }
}

fn slerp_quaternion(a: [*]const f32, b: [*]const f32, t: f32, result: [*]f32) void {
    var dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];

    var b_sign: [4]f32 = undefined;
    if (dot < 0.0) {
        dot = -dot;
        b_sign[0] = -b[0];
        b_sign[1] = -b[1];
        b_sign[2] = -b[2];
        b_sign[3] = -b[3];
    } else {
        b_sign[0] = b[0];
        b_sign[1] = b[1];
        b_sign[2] = b[2];
        b_sign[3] = b[3];
    }

    if (dot > 0.9995) {
        lerp_vector(a, &b_sign, t, 4, result);
        const length = std.math.sqrt(result[0] * result[0] + result[1] * result[1] + result[2] * result[2] + result[3] * result[3]);
        if (length > 0.0) {
            result[0] /= length;
            result[1] /= length;
            result[2] /= length;
            result[3] /= length;
        }
        return;
    }

    const theta = std.math.acos(dot);
    const sin_theta = std.math.sin(theta);

    if (sin_theta > 0.0) {
        const factor_a = std.math.sin((1.0 - t) * theta) / sin_theta;
        const factor_b = std.math.sin(t * theta) / sin_theta;

        result[0] = factor_a * a[0] + factor_b * b_sign[0];
        result[1] = factor_a * a[1] + factor_b * b_sign[1];
        result[2] = factor_a * a[2] + factor_b * b_sign[2];
        result[3] = factor_a * a[3] + factor_b * b_sign[3];
    } else {
        lerp_vector(a, &b_sign, t, 4, result);
    }
}

fn cubic_spline_interpolate(values: [*]const f32, prev_index: u32, next_index: u32, factor: f32, time_diff: f32, component_count: u32, result: [*]f32) void {
    const prev_base = prev_index * component_count * 3;
    const prev_value = values + prev_base + component_count;

    if (prev_index == next_index or time_diff <= 0.0) {
        @memcpy(result[0..component_count], prev_value[0..component_count]);
        return;
    }

    const next_base = next_index * component_count * 3;
    const next_in_tangent = values + next_base;
    const next_value = values + next_base + component_count;
    const prev_out_tangent = values + prev_base + component_count * 2;

    const t = factor;
    const t2 = t * t;
    const t3 = t2 * t;

    const h00 = 2.0 * t3 - 3.0 * t2 + 1.0;
    const h10 = t3 - 2.0 * t2 + t;
    const h01 = -2.0 * t3 + 3.0 * t2;
    const h11 = t3 - t2;

    const tangent_scale = time_diff;

    var p1_sign: f32 = 1.0;
    if (component_count == 4) {
        const dot = prev_value[0] * next_value[0] +
            prev_value[1] * next_value[1] +
            prev_value[2] * next_value[2] +
            prev_value[3] * next_value[3];
        if (dot < 0.0) p1_sign = -1.0;
    }

    var i: u32 = 0;
    while (i < component_count) : (i += 1) {
        const p0 = prev_value[i];
        const m0 = prev_out_tangent[i] * tangent_scale;
        const p1 = next_value[i] * p1_sign;
        const m1 = next_in_tangent[i] * (tangent_scale * p1_sign);

        result[i] = h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1;
    }

    if (component_count == 4) {
        const len = std.math.sqrt(result[0] * result[0] + result[1] * result[1] + result[2] * result[2] + result[3] * result[3]);
        if (len > 0.0) {
            result[0] /= len;
            result[1] /= len;
            result[2] /= len;
            result[3] /= len;
        }
    }
}

/// Interpolates an animation sampler output at `time`.
///
/// `interpolation` expects `0=linear`, `1=step`, `2=cubic-spline` (matching the engine enum order).
pub fn interpolate(interpolation: u32, time: f32, input: [*]const f32, output: [*]const f32, input_count: u32, component_count: u32, result: [*]f32) bool {
    if (input_count == 0 or component_count == 0) return false;

    var prev_index: u32 = 0;
    var next_index: u32 = 0;
    var factor: f32 = 0.0;
    if (!find_keyframe_indices(input, input_count, time, &prev_index, &next_index, &factor)) return false;

    const prev_offset = prev_index * component_count;
    const next_offset = next_index * component_count;
    const prev_ptr = output + prev_offset;
    const next_ptr = output + next_offset;

    switch (interpolation) {
        1 => {
            @memcpy(result[0..component_count], output[prev_offset .. prev_offset + component_count]);
        },
        0 => {
            if (component_count == 4) {
                slerp_quaternion(prev_ptr, next_ptr, factor, result);
            } else {
                lerp_vector(prev_ptr, next_ptr, factor, component_count, result);
            }
        },
        2 => {
            const time_diff = input[next_index] - input[prev_index];
            cubic_spline_interpolate(output, prev_index, next_index, factor, time_diff, component_count, result);
        },
        else => return false,
    }
    return true;
}

/// Interpolates an animation sampler output at `time`, using `last_index` as a temporal hint.
///
/// This improves performance when sampling forward in time.
pub fn interpolate_cached(interpolation: u32, time: f32, input: [*]const f32, output: [*]const f32, input_count: u32, component_count: u32, last_index: *u32, result: [*]f32) bool {
    if (input_count == 0 or component_count == 0) return false;

    var prev_index: u32 = 0;
    var next_index: u32 = 0;
    var factor: f32 = 0.0;
    var hint = last_index.*;
    if (!find_keyframe_indices_with_hint(input, input_count, time, &hint, &prev_index, &next_index, &factor)) return false;
    last_index.* = hint;

    const prev_offset = prev_index * component_count;
    const next_offset = next_index * component_count;
    const prev_ptr = output + prev_offset;
    const next_ptr = output + next_offset;

    switch (interpolation) {
        1 => {
            @memcpy(result[0..component_count], output[prev_offset .. prev_offset + component_count]);
        },
        0 => {
            if (component_count == 4) {
                slerp_quaternion(prev_ptr, next_ptr, factor, result);
            } else {
                lerp_vector(prev_ptr, next_ptr, factor, component_count, result);
            }
        },
        2 => {
            const time_diff = input[next_index] - input[prev_index];
            cubic_spline_interpolate(output, prev_index, next_index, factor, time_diff, component_count, result);
        },
        else => return false,
    }
    return true;
}
