const std = @import("std");
const builtin = @import("builtin");
const transform = @import("transform.zig");
const scene = @import("../assets/scene.zig");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("math.h");
    @cInclude("float.h");
});

// Constants
const M_PI = 3.14159265358979323846;
const FLT_EPSILON = 1.19209290e-07;

// Enums
pub const CardinalAnimationInterpolation = enum(c_int) {
    LINEAR = 0,
    STEP = 1,
    CUBICSPLINE = 2,
};

pub const CardinalAnimationTargetPath = enum(c_int) {
    TRANSLATION = 0,
    ROTATION = 1,
    SCALE = 2,
    WEIGHTS = 3,
};

// Structs
pub const CardinalAnimationSampler = extern struct {
    input: ?[*]f32,
    output: ?[*]f32,
    input_count: u32,
    output_count: u32,
    interpolation: CardinalAnimationInterpolation,
};

pub const CardinalAnimationTarget = extern struct {
    node_index: u32,
    path: CardinalAnimationTargetPath,
};

pub const CardinalAnimationChannel = extern struct {
    sampler_index: u32,
    target: CardinalAnimationTarget,
};

pub const CardinalAnimation = extern struct {
    name: ?[*:0]u8,
    samplers: ?[*]CardinalAnimationSampler,
    sampler_count: u32,
    channels: ?[*]CardinalAnimationChannel,
    channel_count: u32,
    duration: f32,
};

pub const CardinalBone = extern struct {
    name: ?[*:0]u8,
    node_index: u32,
    inverse_bind_matrix: [16]f32,
    current_matrix: [16]f32,
    parent_index: u32,
};

pub const CardinalSkin = extern struct {
    name: ?[*:0]u8,
    bones: ?[*]CardinalBone,
    bone_count: u32,
    mesh_indices: ?[*]u32,
    mesh_count: u32,
    root_bone_index: u32,
};

pub const CardinalAnimationState = extern struct {
    animation_index: u32,
    current_time: f32,
    playback_speed: f32,
    is_playing: bool,
    is_looping: bool,
    blend_weight: f32,
};

pub const CardinalAnimationSystem = extern struct {
    animations: ?[*]CardinalAnimation,
    animation_count: u32,
    skins: ?[*]CardinalSkin,
    skin_count: u32,
    states: ?[*]CardinalAnimationState,
    state_count: u32,
    bone_matrices: ?[*]f32,
    bone_matrix_count: u32,
};

// Helper function to find keyframe indices for interpolation
fn find_keyframe_indices(input: [*]const f32, input_count: u32, time: f32, prev_index: *u32, next_index: *u32, factor: *f32) bool {
    if (input_count == 0) return false;

    // Handle edge cases
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

    // Binary search for the correct interval
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

    // Calculate interpolation factor
    const time_diff = input[right] - input[left];
    if (time_diff > 0.0) {
        factor.* = (time - input[left]) / time_diff;
    } else {
        factor.* = 0.0;
    }

    return true;
}

// Linear interpolation for vectors
fn lerp_vector(a: [*]const f32, b: [*]const f32, t: f32, component_count: u32, result: [*]f32) void {
    var i: u32 = 0;
    while (i < component_count) : (i += 1) {
        result[i] = a[i] + t * (b[i] - a[i]);
    }
}

// Spherical linear interpolation for quaternions
fn slerp_quaternion(a: [*]const f32, b: [*]const f32, t: f32, result: [*]f32) void {
    var dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];

    // If the dot product is negative, slerp won't take the shorter path
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

    // If the quaternions are very close, use linear interpolation
    if (dot > 0.9995) {
        lerp_vector(a, &b_sign, t, 4, result);
        // Normalize the result
        const length = std.math.sqrt(result[0] * result[0] + result[1] * result[1] + result[2] * result[2] + result[3] * result[3]);
        if (length > 0.0) {
            result[0] /= length;
            result[1] /= length;
            result[2] /= length;
            result[3] /= length;
        }
        return;
    }

    // Calculate the angle between the quaternions
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
        // Fallback to linear interpolation
        lerp_vector(a, &b_sign, t, 4, result);
    }
}

// Cubic spline interpolation
fn cubic_spline_interpolate(values: [*]const f32, prev_index: u32, next_index: u32, factor: f32, component_count: u32, result: [*]f32) void {
    // For cubic spline, we need tangent vectors
    // This is a simplified implementation - full cubic spline would require proper tangent
    // calculation For now, fall back to linear interpolation
    const prev_value = values + prev_index * component_count;
    const next_value = values + next_index * component_count;
    lerp_vector(prev_value, next_value, factor, component_count, result);
}

pub export fn cardinal_animation_interpolate(interpolation: CardinalAnimationInterpolation, time: f32, input: ?[*]const f32, output: ?[*]const f32, input_count: u32, component_count: u32, result: ?[*]f32) callconv(.c) bool {
    if (input == null or output == null or result == null or input_count == 0 or component_count == 0) {
        return false;
    }

    var prev_index: u32 = 0;
    var next_index: u32 = 0;
    var factor: f32 = 0.0;

    if (!find_keyframe_indices(input.?, input_count, time, &prev_index, &next_index, &factor)) {
        return false;
    }

    const prev_offset = prev_index * component_count;
    const next_offset = next_index * component_count;
    const prev_ptr = output.? + prev_offset;
    const next_ptr = output.? + next_offset;

    switch (interpolation) {
        .STEP => {
            const src_slice = output.?[prev_offset .. prev_offset + component_count];
            const dst_slice = result.?[0..component_count];
            @memcpy(dst_slice, src_slice);
        },
        .LINEAR => {
            if (component_count == 4) {
                // Assume quaternion for 4-component values
                slerp_quaternion(prev_ptr, next_ptr, factor, result.?);
            } else {
                lerp_vector(prev_ptr, next_ptr, factor, component_count, result.?);
            }
        },
        .CUBICSPLINE => {
            cubic_spline_interpolate(output.?, prev_index, next_index, factor, component_count, result.?);
        },
    }

    return true;
}

pub export fn cardinal_animation_system_create(max_animations: u32, max_skins: u32) callconv(.c) ?*CardinalAnimationSystem {
    const system_ptr = c.calloc(1, @sizeOf(CardinalAnimationSystem));
    if (system_ptr == null) {
        std.log.err("Failed to allocate animation system", .{});
        return null;
    }
    const system: *CardinalAnimationSystem = @ptrCast(@alignCast(system_ptr));

    if (max_animations > 0) {
        const animations_ptr = c.calloc(max_animations, @sizeOf(CardinalAnimation));
        if (animations_ptr == null) {
            std.log.err("Failed to allocate animations array", .{});
            c.free(system);
            return null;
        }
        system.animations = @ptrCast(@alignCast(animations_ptr));
    }

    if (max_skins > 0) {
        const skins_ptr = c.calloc(max_skins, @sizeOf(CardinalSkin));
        if (skins_ptr == null) {
            std.log.err("Failed to allocate skins array", .{});
            c.free(system.animations);
            c.free(system);
            return null;
        }
        system.skins = @ptrCast(@alignCast(skins_ptr));
    }

    system.animation_count = 0;
    system.skin_count = 0;
    system.state_count = 0;

    system.bone_matrix_count = 256; // Standard max bones
    const bone_matrices_ptr = c.malloc(system.bone_matrix_count * 16 * @sizeOf(f32));
    if (bone_matrices_ptr) |ptr| {
        system.bone_matrices = @ptrCast(@alignCast(ptr));
        var i: u32 = 0;
        while (i < system.bone_matrix_count) : (i += 1) {
            const matrix = system.bone_matrices.? + i * 16;
            _ = c.memset(matrix, 0, 16 * @sizeOf(f32));
            matrix[0] = 1.0;
            matrix[5] = 1.0;
            matrix[10] = 1.0;
            matrix[15] = 1.0;
        }
    } else {
        std.log.err("Failed to allocate bone matrices buffer", .{});
        system.bone_matrix_count = 0;
    }

    std.log.info("Animation system created with capacity for {d} animations and {d} skins", .{ max_animations, max_skins });
    return system;
}

pub export fn cardinal_animation_system_destroy(system: ?*CardinalAnimationSystem) callconv(.c) void {
    if (system == null) return;

    if (system.?.animations) |animations| {
        var i: u32 = 0;
        while (i < system.?.animation_count) : (i += 1) {
            const anim = &animations[i];
            c.free(anim.name);

            if (anim.samplers) |samplers| {
                var j: u32 = 0;
                while (j < anim.sampler_count) : (j += 1) {
                    c.free(samplers[j].input);
                    c.free(samplers[j].output);
                }
                c.free(anim.samplers);
            }

            c.free(anim.channels);
        }
        c.free(system.?.animations);
    }

    if (system.?.skins) |skins| {
        var i: u32 = 0;
        while (i < system.?.skin_count) : (i += 1) {
            const skin = &skins[i];
            c.free(skin.name);

            if (skin.bones) |bones| {
                var j: u32 = 0;
                while (j < skin.bone_count) : (j += 1) {
                    c.free(bones[j].name);
                }
                c.free(skin.bones);
            }

            c.free(skin.mesh_indices);
        }
        c.free(system.?.skins);
    }

    c.free(system.?.states);
    c.free(system.?.bone_matrices);
    c.free(system);

    std.log.debug("Animation system destroyed", .{});
}

pub export fn cardinal_animation_system_add_animation(system: ?*CardinalAnimationSystem, animation: ?*const CardinalAnimation) callconv(.c) u32 {
    if (system == null or animation == null) return std.math.maxInt(u32);

    const index = system.?.animation_count;
    const dest = &system.?.animations.?[index];

    _ = c.memset(dest, 0, @sizeOf(CardinalAnimation));

    if (animation.?.name) |name| {
        const name_len = c.strlen(name) + 1;
        const dest_name = c.malloc(name_len);
        if (dest_name) |ptr| {
            dest.name = @ptrCast(ptr);
            _ = c.strcpy(dest.name, name);
        }
    }

    dest.duration = animation.?.duration;
    dest.sampler_count = animation.?.sampler_count;
    dest.channel_count = animation.?.channel_count;

    if (animation.?.sampler_count > 0) {
        const samplers_ptr = c.calloc(animation.?.sampler_count, @sizeOf(CardinalAnimationSampler));
        if (samplers_ptr) |ptr| {
            dest.samplers = @ptrCast(@alignCast(ptr));
            var i: u32 = 0;
            while (i < animation.?.sampler_count) : (i += 1) {
                const src_sampler = &animation.?.samplers.?[i];
                const dst_sampler = &dest.samplers.?[i];

                dst_sampler.interpolation = src_sampler.interpolation;
                dst_sampler.input_count = src_sampler.input_count;
                dst_sampler.output_count = src_sampler.output_count;

                if (src_sampler.input != null and src_sampler.input_count > 0) {
                    const input_ptr = c.malloc(src_sampler.input_count * @sizeOf(f32));
                    if (input_ptr) |in_ptr| {
                        dst_sampler.input = @ptrCast(@alignCast(in_ptr));
                        @memcpy(dst_sampler.input.?[0..src_sampler.input_count], src_sampler.input.?[0..src_sampler.input_count]);
                    }
                }

                if (src_sampler.output != null and src_sampler.output_count > 0) {
                    const output_ptr = c.malloc(src_sampler.output_count * @sizeOf(f32));
                    if (output_ptr) |out_ptr| {
                        dst_sampler.output = @ptrCast(@alignCast(out_ptr));
                        @memcpy(dst_sampler.output.?[0..src_sampler.output_count], src_sampler.output.?[0..src_sampler.output_count]);
                    }
                }
            }
        }
    }

    if (animation.?.channel_count > 0) {
        const channels_ptr = c.malloc(animation.?.channel_count * @sizeOf(CardinalAnimationChannel));
        if (channels_ptr) |ptr| {
            dest.channels = @ptrCast(@alignCast(ptr));
            @memcpy(dest.channels.?[0..animation.?.channel_count], animation.?.channels.?[0..animation.?.channel_count]);
        }
    }

    system.?.animation_count += 1;
    std.log.debug("Added animation '{s}' at index {d}", .{ if (dest.name) |n| std.mem.span(n) else "Unnamed", index });
    return index;
}

pub export fn cardinal_animation_system_add_skin(system: ?*CardinalAnimationSystem, skin: ?*const CardinalSkin) callconv(.c) u32 {
    if (system == null or skin == null) return std.math.maxInt(u32);

    const index = system.?.skin_count;
    const dest = &system.?.skins.?[index];

    _ = c.memset(dest, 0, @sizeOf(CardinalSkin));

    if (skin.?.name) |name| {
        const name_len = c.strlen(name) + 1;
        const dest_name = c.malloc(name_len);
        if (dest_name) |ptr| {
            dest.name = @ptrCast(ptr);
            _ = c.strcpy(dest.name, name);
        }
    }

    dest.bone_count = skin.?.bone_count;
    dest.mesh_count = skin.?.mesh_count;
    dest.root_bone_index = skin.?.root_bone_index;

    if (skin.?.bone_count > 0) {
        const bones_ptr = c.calloc(skin.?.bone_count, @sizeOf(CardinalBone));
        if (bones_ptr) |ptr| {
            dest.bones = @ptrCast(@alignCast(ptr));
            var i: u32 = 0;
            while (i < skin.?.bone_count) : (i += 1) {
                const src_bone = &skin.?.bones.?[i];
                const dst_bone = &dest.bones.?[i];

                if (src_bone.name) |name| {
                    const name_len = c.strlen(name) + 1;
                    const dest_name = c.malloc(name_len);
                    if (dest_name) |n_ptr| {
                        dst_bone.name = @ptrCast(n_ptr);
                        _ = c.strcpy(dst_bone.name, name);
                    }
                }

                dst_bone.node_index = src_bone.node_index;
                dst_bone.parent_index = src_bone.parent_index;
                @memcpy(&dst_bone.inverse_bind_matrix, &src_bone.inverse_bind_matrix);
                @memcpy(&dst_bone.current_matrix, &src_bone.current_matrix);
            }
        }
    }

    if (skin.?.mesh_count > 0) {
        const indices_ptr = c.malloc(skin.?.mesh_count * @sizeOf(u32));
        if (indices_ptr) |ptr| {
            dest.mesh_indices = @ptrCast(@alignCast(ptr));
            @memcpy(dest.mesh_indices.?[0..skin.?.mesh_count], skin.?.mesh_indices.?[0..skin.?.mesh_count]);
        }
    }

    system.?.skin_count += 1;
    std.log.debug("Added skin '{s}' with {d} bones at index {d}", .{ if (dest.name) |n| std.mem.span(n) else "Unnamed", dest.bone_count, index });
    return index;
}

pub export fn cardinal_animation_play(system: ?*CardinalAnimationSystem, animation_index: u32, loop: bool, blend_weight: f32) callconv(.c) bool {
    if (system == null or animation_index >= system.?.animation_count) return false;

    var state: ?*CardinalAnimationState = null;
    var i: u32 = 0;
    while (i < system.?.state_count) : (i += 1) {
        if (system.?.states.?[i].animation_index == animation_index) {
            state = &system.?.states.?[i];
            break;
        }
    }

    if (state == null) {
        const new_states_ptr = c.realloc(system.?.states, (system.?.state_count + 1) * @sizeOf(CardinalAnimationState));
        if (new_states_ptr == null) return false;
        system.?.states = @ptrCast(@alignCast(new_states_ptr));

        state = &system.?.states.?[system.?.state_count];
        system.?.state_count += 1;

        state.?.animation_index = animation_index;
        state.?.current_time = 0.0;
    }

    state.?.is_playing = true;
    state.?.is_looping = loop;
    state.?.blend_weight = blend_weight;
    state.?.playback_speed = 1.0;

    std.log.debug("Started animation {d} with blend weight {d:.2}", .{ animation_index, blend_weight });
    return true;
}

pub export fn cardinal_animation_pause(system: ?*CardinalAnimationSystem, animation_index: u32) callconv(.c) bool {
    if (system == null) return false;

    var i: u32 = 0;
    while (i < system.?.state_count) : (i += 1) {
        if (system.?.states.?[i].animation_index == animation_index) {
            system.?.states.?[i].is_playing = false;
            std.log.debug("Paused animation {d}", .{animation_index});
            return true;
        }
    }

    return false;
}

pub export fn cardinal_animation_stop(system: ?*CardinalAnimationSystem, animation_index: u32) callconv(.c) bool {
    if (system == null) return false;

    var i: u32 = 0;
    while (i < system.?.state_count) : (i += 1) {
        if (system.?.states.?[i].animation_index == animation_index) {
            system.?.states.?[i].is_playing = false;
            system.?.states.?[i].current_time = 0.0;
            std.log.debug("Stopped animation {d}", .{animation_index});
            return true;
        }
    }

    return false;
}

pub export fn cardinal_animation_set_speed(system: ?*CardinalAnimationSystem, animation_index: u32, speed: f32) callconv(.c) bool {
    if (system == null) return false;

    var i: u32 = 0;
    while (i < system.?.state_count) : (i += 1) {
        if (system.?.states.?[i].animation_index == animation_index) {
            system.?.states.?[i].playback_speed = speed;
            std.log.debug("Set animation {d} speed to {d:.2}", .{ animation_index, speed });
            return true;
        }
    }

    return false;
}

pub export fn cardinal_animation_system_update(system: ?*CardinalAnimationSystem, all_nodes: ?[*]?*scene.CardinalSceneNode, all_node_count: u32, delta_time: f32) callconv(.c) void {
    if (system == null) return;

    var i: u32 = 0;
    while (i < system.?.state_count) : (i += 1) {
        const state = &system.?.states.?[i];

        if (!state.is_playing) continue;

        const animation = &system.?.animations.?[state.animation_index];

        state.current_time += delta_time * state.playback_speed;

        if (state.current_time >= animation.duration) {
            if (state.is_looping) {
                state.current_time = @mod(state.current_time, animation.duration);
            } else {
                state.current_time = animation.duration;
                state.is_playing = false;
            }
        }

        var c_idx: u32 = 0;
        while (c_idx < animation.channel_count) : (c_idx += 1) {
            const channel = &animation.channels.?[c_idx];
            const sampler = &animation.samplers.?[channel.sampler_index];

            if (all_nodes == null or channel.target.node_index >= all_node_count) continue;
            const node = all_nodes.?[channel.target.node_index];
            if (node == null) continue;

            var result: [4]f32 = undefined;
            var component_count: u32 = 3;
            if (channel.target.path == .ROTATION or channel.target.path == .WEIGHTS) {
                component_count = 4;
            }

            if (cardinal_animation_interpolate(sampler.interpolation, state.current_time, sampler.input, sampler.output, sampler.input_count, component_count, &result)) {
                var translation: [3]f32 = undefined;
                var rotation: [4]f32 = undefined;
                var scale: [3]f32 = undefined;
                _ = transform.cardinal_matrix_decompose(&node.?.local_transform, &translation, &rotation, &scale);

                switch (channel.target.path) {
                    .TRANSLATION => @memcpy(&translation, result[0..3]),
                    .ROTATION => @memcpy(&rotation, &result),
                    .SCALE => @memcpy(&scale, result[0..3]),
                    else => {},
                }

                var new_transform: [16]f32 = undefined;
                transform.cardinal_matrix_from_trs(&translation, &rotation, &scale, &new_transform);
                scene.cardinal_scene_node_set_local_transform(node, &new_transform);
            }
        }
    }
}

pub export fn cardinal_skin_update_bone_matrices(skin: ?*const CardinalSkin, scene_nodes: ?[*]?*const scene.CardinalSceneNode, bone_matrices: ?[*]f32) callconv(.c) bool {
    if (skin == null or scene_nodes == null or bone_matrices == null) return false;

    var i: u32 = 0;
    while (i < skin.?.bone_count) : (i += 1) {
        const bone = &skin.?.bones.?[i];
        const node = scene_nodes.?[bone.node_index];

        if (node == null) continue;

        const world_transform = scene.cardinal_scene_node_get_world_transform(@constCast(node));
        const bone_matrix = &bone_matrices.?[i * 16];
        // Cast to [16]f32 pointers for the Zig function
        const wt_ptr: *const [16]f32 = @ptrCast(world_transform);
        const ibm_ptr: *const [16]f32 = &bone.inverse_bind_matrix;
        const bm_ptr: *[16]f32 = @ptrCast(bone_matrix);
        transform.cardinal_matrix_multiply(wt_ptr, ibm_ptr, bm_ptr);
    }

    return true;
}

pub export fn cardinal_skin_destroy(skin: ?*CardinalSkin) callconv(.c) void {
    if (skin == null) return;

    c.free(skin.?.name);

    if (skin.?.bones) |bones| {
        var i: u32 = 0;
        while (i < skin.?.bone_count) : (i += 1) {
            c.free(bones[i].name);
        }
        c.free(skin.?.bones);
    }

    c.free(skin.?.mesh_indices);
    _ = c.memset(skin, 0, @sizeOf(CardinalSkin));
}
