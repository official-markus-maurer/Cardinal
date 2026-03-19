//! Animation runtime types and helpers.
//!
//! Provides a minimal animation system supporting playback, blending, and skinning matrix updates.
//! The API is C-ABI-friendly (`pub export fn`) and designed to be populated by asset loaders.
//!
const std = @import("std");
const builtin = @import("builtin");
const transform = @import("../core/transform.zig");
const scene = @import("scene.zig");
const memory = @import("../core/memory.zig");
const log = @import("../core/log.zig");
const sampling = @import("animation_sampling.zig");

const anim_log = log.ScopedLogger("ANIMATION");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("math.h");
    @cInclude("float.h");
});

/// Pi constant used by interpolation helpers.
const M_PI = 3.14159265358979323846;
/// Float epsilon used by stability checks.
const FLT_EPSILON = 1.19209290e-07;

/// Keyframe interpolation mode.
pub const CardinalAnimationInterpolation = enum(c_int) {
    LINEAR = 0,
    STEP = 1,
    CUBICSPLINE = 2,
};

/// Target property driven by an animation channel.
pub const CardinalAnimationTargetPath = enum(c_int) {
    TRANSLATION = 0,
    ROTATION = 1,
    SCALE = 2,
    WEIGHTS = 3,
};

/// Sampler with keyframe times and output values.
pub const CardinalAnimationSampler = extern struct {
    input: ?[*]f32,
    output: ?[*]f32,
    input_count: u32,
    output_count: u32,
    interpolation: CardinalAnimationInterpolation,
    last_index: u32,
};

/// Animation target (node + property path).
pub const CardinalAnimationTarget = extern struct {
    node_index: u32,
    path: CardinalAnimationTargetPath,
};

/// Animation channel binding a sampler to a target.
pub const CardinalAnimationChannel = extern struct {
    sampler_index: u32,
    target: CardinalAnimationTarget,
};

/// Animation clip data.
pub const CardinalAnimation = extern struct {
    name: ?[*:0]u8,
    samplers: ?[*]CardinalAnimationSampler,
    sampler_count: u32,
    channels: ?[*]CardinalAnimationChannel,
    channel_count: u32,
    duration: f32,
    events: ?[*]CardinalAnimationEvent,
    event_count: u32,
};

pub const CardinalAnimationEvent = extern struct {
    time: f32,
    name: ?[*:0]u8,
};

pub const CardinalAnimationFiredEvent = extern struct {
    animation_index: u32,
    time: f32,
    name: ?[*:0]u8,
};

/// Bone definition for a skin.
pub const CardinalBone = extern struct {
    name: ?[*:0]u8,
    node_index: u32,
    inverse_bind_matrix: [16]f32,
    current_matrix: [16]f32,
    parent_index: u32,
};

/// Skin definition referencing bones and meshes.
pub const CardinalSkin = extern struct {
    name: ?[*:0]u8,
    bones: ?[*]CardinalBone,
    bone_count: u32,
    mesh_indices: ?[*]u32,
    mesh_count: u32,
    root_bone_index: u32,
};

/// Runtime playback state for an animation clip.
pub const CardinalAnimationState = extern struct {
    animation_index: u32,
    current_time: f32,
    previous_time: f32,
    playback_speed: f32,
    is_playing: bool,
    is_looping: bool,
    blend_weight: f32,
    is_additive: bool,
    mask_weights: ?[*]f32,
    mask_count: u32,
};

/// Top-level animation system state (clips + skins + runtime states).
pub const CardinalAnimationSystem = extern struct {
    animations: ?[*]CardinalAnimation,
    animation_count: u32,
    skins: ?[*]CardinalSkin,
    skin_count: u32,
    states: ?[*]CardinalAnimationState,
    state_count: u32,
    bone_matrices: ?[*]f32,
    bone_matrix_count: u32,
    blend_states: ?[*]CardinalBlendState,
    blend_state_capacity: u32,
    blend_frame_id: u32,
    fired_events: ?[*]CardinalAnimationFiredEvent,
    fired_event_capacity: u32,
    fired_event_head: u32,
    fired_event_tail: u32,
};

const CardinalBlendState = extern struct {
    translation: [3]f32,
    rotation: [4]f32,
    scale: [3]f32,
    weight_t: f32,
    weight_r: f32,
    weight_s: f32,
    translation_add: [3]f32,
    rotation_add: [4]f32,
    scale_add: [3]f32,
    weight_t_add: f32,
    weight_r_add: f32,
    weight_s_add: f32,
    /// Frame stamp; equals `CardinalAnimationSystem.blend_frame_id` when touched this update.
    flags: u32,
};

fn quat_mul(a: *const [4]f32, b: *const [4]f32, out: *[4]f32) void {
    const ax = a[0];
    const ay = a[1];
    const az = a[2];
    const aw = a[3];

    const bx = b[0];
    const by = b[1];
    const bz = b[2];
    const bw = b[3];

    out[0] = aw * bx + ax * bw + ay * bz - az * by;
    out[1] = aw * by - ax * bz + ay * bw + az * bx;
    out[2] = aw * bz + ax * by - ay * bx + az * bw;
    out[3] = aw * bw - ax * bx - ay * by - az * bz;
}

pub export fn cardinal_animation_interpolate(interpolation: CardinalAnimationInterpolation, time: f32, input: ?[*]const f32, output: ?[*]const f32, input_count: u32, component_count: u32, result: ?[*]f32) callconv(.c) bool {
    if (input == null or output == null or result == null or input_count == 0 or component_count == 0) {
        return false;
    }
    const interp: u32 = @intCast(@intFromEnum(interpolation));
    return sampling.interpolate(interp, time, input.?, output.?, input_count, component_count, result.?);
}

fn sampler_interpolate_cached(sampler: *CardinalAnimationSampler, time: f32, component_count: u32, result: ?[*]f32) bool {
    if (sampler.input == null or sampler.output == null or result == null or sampler.input_count == 0 or component_count == 0) {
        return false;
    }
    const interp: u32 = @intCast(@intFromEnum(sampler.interpolation));
    return sampling.interpolate_cached(interp, time, sampler.input.?, sampler.output.?, sampler.input_count, component_count, &sampler.last_index, result.?);
}

/// Allocates a new animation system with preallocated animation/skin capacity.
pub export fn cardinal_animation_system_create(max_animations: u32, max_skins: u32) callconv(.c) ?*CardinalAnimationSystem {
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    const system_ptr = memory.cardinal_calloc(allocator, 1, @sizeOf(CardinalAnimationSystem));
    if (system_ptr == null) {
        anim_log.err("Failed to allocate animation system", .{});
        return null;
    }
    const system: *CardinalAnimationSystem = @ptrCast(@alignCast(system_ptr));

    if (max_animations > 0) {
        const animations_ptr = memory.cardinal_calloc(allocator, max_animations, @sizeOf(CardinalAnimation));
        if (animations_ptr == null) {
            anim_log.err("Failed to allocate animations array", .{});
            memory.cardinal_free(allocator, system);
            return null;
        }
        system.animations = @ptrCast(@alignCast(animations_ptr));
    }

    if (max_skins > 0) {
        const skins_ptr = memory.cardinal_calloc(allocator, max_skins, @sizeOf(CardinalSkin));
        if (skins_ptr == null) {
            anim_log.err("Failed to allocate skins array", .{});
            if (system.animations) |ptr| memory.cardinal_free(allocator, ptr);
            memory.cardinal_free(allocator, system);
            return null;
        }
        system.skins = @ptrCast(@alignCast(skins_ptr));
    }

    system.animation_count = 0;
    system.skin_count = 0;
    system.state_count = 0;

    system.bone_matrix_count = 256;
    system.blend_states = null;
    system.blend_state_capacity = 0;
    system.blend_frame_id = 1;

    system.fired_event_capacity = 256;
    system.fired_event_head = 0;
    system.fired_event_tail = 0;
    const fired_ptr = memory.cardinal_calloc(allocator, system.fired_event_capacity, @sizeOf(CardinalAnimationFiredEvent));
    if (fired_ptr) |ptr| {
        system.fired_events = @ptrCast(@alignCast(ptr));
    } else {
        system.fired_events = null;
        system.fired_event_capacity = 0;
    }

    const bone_matrices_ptr = memory.cardinal_alloc(allocator, system.bone_matrix_count * 16 * @sizeOf(f32));
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
        anim_log.err("Failed to allocate bone matrices buffer", .{});
        system.bone_matrix_count = 0;
    }

    anim_log.info("Animation system created with capacity for {d} animations and {d} skins", .{ max_animations, max_skins });
    return system;
}

/// Destroys an animation system and all owned allocations.
pub export fn cardinal_animation_system_destroy(system: ?*CardinalAnimationSystem) callconv(.c) void {
    if (system == null) return;
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

    if (system.?.animations) |animations| {
        var i: u32 = 0;
        while (i < system.?.animation_count) : (i += 1) {
            const anim = &animations[i];
            if (anim.name) |ptr| memory.cardinal_free(allocator, ptr);

            if (anim.events) |events| {
                var e: u32 = 0;
                while (e < anim.event_count) : (e += 1) {
                    if (events[e].name) |ptr| memory.cardinal_free(allocator, ptr);
                }
                memory.cardinal_free(allocator, events);
            }

            if (anim.samplers) |samplers| {
                var j: u32 = 0;
                while (j < anim.sampler_count) : (j += 1) {
                    if (samplers[j].input) |ptr| memory.cardinal_free(allocator, ptr);
                    if (samplers[j].output) |ptr| memory.cardinal_free(allocator, ptr);
                }
                memory.cardinal_free(allocator, anim.samplers);
            }

            if (anim.channels) |ptr| memory.cardinal_free(allocator, ptr);
        }
        memory.cardinal_free(allocator, system.?.animations);
    }

    if (system.?.skins) |skins| {
        var i: u32 = 0;
        while (i < system.?.skin_count) : (i += 1) {
            const skin = &skins[i];
            if (skin.name) |ptr| memory.cardinal_free(allocator, ptr);

            if (skin.bones) |bones| {
                var j: u32 = 0;
                while (j < skin.bone_count) : (j += 1) {
                    if (bones[j].name) |ptr| memory.cardinal_free(allocator, ptr);
                }
                memory.cardinal_free(allocator, skin.bones);
            }

            if (skin.mesh_indices) |ptr| memory.cardinal_free(allocator, ptr);
        }
        memory.cardinal_free(allocator, system.?.skins);
    }

    if (system.?.states) |states| {
        var i: u32 = 0;
        while (i < system.?.state_count) : (i += 1) {
            if (states[i].mask_weights) |ptr| memory.cardinal_free(allocator, ptr);
        }
        memory.cardinal_free(allocator, states);
    }

    if (system.?.fired_events) |ptr| memory.cardinal_free(allocator, ptr);
    if (system.?.bone_matrices) |ptr| memory.cardinal_free(allocator, ptr);
    memory.cardinal_free(allocator, system);

    anim_log.debug("Animation system destroyed", .{});
}

/// Adds an animation to the system (deep-copies name/samplers/channels).
pub export fn cardinal_animation_system_add_animation(system: ?*CardinalAnimationSystem, animation: ?*const CardinalAnimation) callconv(.c) u32 {
    if (system == null or animation == null) return std.math.maxInt(u32);

    const index = system.?.animation_count;
    const dest = &system.?.animations.?[index];
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

    _ = c.memset(dest, 0, @sizeOf(CardinalAnimation));

    if (animation.?.name) |name| {
        const name_len = c.strlen(name) + 1;
        const dest_name = memory.cardinal_alloc(allocator, name_len);
        if (dest_name) |ptr| {
            dest.name = @ptrCast(ptr);
            _ = c.strcpy(dest.name, name);
        }
    }

    dest.duration = animation.?.duration;
    dest.sampler_count = animation.?.sampler_count;
    dest.channel_count = animation.?.channel_count;
    dest.events = null;
    dest.event_count = 0;

    if (animation.?.sampler_count > 0) {
        const samplers_ptr = memory.cardinal_calloc(allocator, animation.?.sampler_count, @sizeOf(CardinalAnimationSampler));
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
                    const input_ptr = memory.cardinal_alloc(allocator, src_sampler.input_count * @sizeOf(f32));
                    if (input_ptr) |in_ptr| {
                        dst_sampler.input = @ptrCast(@alignCast(in_ptr));
                        @memcpy(dst_sampler.input.?[0..src_sampler.input_count], src_sampler.input.?[0..src_sampler.input_count]);
                    }
                }

                if (src_sampler.output != null and src_sampler.output_count > 0) {
                    const output_ptr = memory.cardinal_alloc(allocator, src_sampler.output_count * @sizeOf(f32));
                    if (output_ptr) |out_ptr| {
                        dst_sampler.output = @ptrCast(@alignCast(out_ptr));
                        @memcpy(dst_sampler.output.?[0..src_sampler.output_count], src_sampler.output.?[0..src_sampler.output_count]);
                    }
                }
            }
        }
    }

    if (animation.?.channel_count > 0) {
        const channels_ptr = memory.cardinal_alloc(allocator, animation.?.channel_count * @sizeOf(CardinalAnimationChannel));
        if (channels_ptr) |ptr| {
            dest.channels = @ptrCast(@alignCast(ptr));
            @memcpy(dest.channels.?[0..animation.?.channel_count], animation.?.channels.?[0..animation.?.channel_count]);
        }
    }

    system.?.animation_count += 1;
    anim_log.debug("Added animation '{s}' at index {d}", .{ if (dest.name) |n| std.mem.span(n) else "Unnamed", index });
    return index;
}

fn push_fired_event(sys: *CardinalAnimationSystem, anim_index: u32, time: f32, name: ?[*:0]u8) void {
    if (sys.fired_events == null or sys.fired_event_capacity == 0) return;
    const next_tail = (sys.fired_event_tail + 1) % sys.fired_event_capacity;
    if (next_tail == sys.fired_event_head) {
        sys.fired_event_head = (sys.fired_event_head + 1) % sys.fired_event_capacity;
    }
    sys.fired_events.?[sys.fired_event_tail] = .{ .animation_index = anim_index, .time = time, .name = name };
    sys.fired_event_tail = next_tail;
}

fn fire_animation_events(sys: *CardinalAnimationSystem, anim_index: u32, anim: *const CardinalAnimation, prev_time: f32, curr_time: f32, looped: bool) void {
    if (anim.events == null or anim.event_count == 0) return;
    if (prev_time == curr_time) return;

    const events = anim.events.?[0..anim.event_count];
    if (!looped) {
        for (events) |e| {
            if (e.time > prev_time and e.time <= curr_time) {
                push_fired_event(sys, anim_index, e.time, e.name);
            }
        }
        return;
    }

    for (events) |e| {
        if ((e.time > prev_time and e.time <= anim.duration) or (e.time >= 0.0 and e.time <= curr_time)) {
            push_fired_event(sys, anim_index, e.time, e.name);
        }
    }
}

pub export fn cardinal_animation_add_event(system: ?*CardinalAnimationSystem, animation_index: u32, time: f32, name: ?[*:0]const u8) callconv(.c) bool {
    if (system == null or name == null) return false;
    const sys = system.?;
    if (animation_index >= sys.animation_count) return false;

    const anim = &sys.animations.?[animation_index];
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

    const clamped_time = if (time < 0.0) 0.0 else if (time > anim.duration) anim.duration else time;

    const name_len = c.strlen(name.?) + 1;
    const name_ptr = memory.cardinal_alloc(allocator, name_len) orelse return false;
    const name_z: [*:0]u8 = @ptrCast(name_ptr);
    _ = c.strcpy(name_z, name.?);

    const old_count = anim.event_count;
    const new_count = old_count + 1;
    const new_bytes = @as(usize, new_count) * @sizeOf(CardinalAnimationEvent);

    const new_ptr = if (anim.events == null)
        memory.cardinal_calloc(allocator, new_count, @sizeOf(CardinalAnimationEvent))
    else
        memory.cardinal_realloc(allocator, anim.events, new_bytes);

    if (new_ptr == null) {
        memory.cardinal_free(allocator, name_ptr);
        return false;
    }

    anim.events = @ptrCast(@alignCast(new_ptr));

    var insert_at: u32 = 0;
    while (insert_at < old_count and anim.events.?[insert_at].time <= clamped_time) : (insert_at += 1) {}

    var i: u32 = old_count;
    while (i > insert_at) : (i -= 1) {
        anim.events.?[i] = anim.events.?[i - 1];
    }

    anim.events.?[insert_at] = .{ .time = clamped_time, .name = name_z };
    anim.event_count = new_count;
    return true;
}

pub export fn cardinal_animation_poll_event(system: ?*CardinalAnimationSystem, out_event: ?*CardinalAnimationFiredEvent) callconv(.c) bool {
    if (system == null or out_event == null) return false;
    const sys = system.?;
    if (sys.fired_events == null or sys.fired_event_capacity == 0) return false;
    if (sys.fired_event_head == sys.fired_event_tail) return false;

    out_event.?.* = sys.fired_events.?[sys.fired_event_head];
    sys.fired_event_head = (sys.fired_event_head + 1) % sys.fired_event_capacity;
    return true;
}

/// Adds a skin to the system (deep-copies name/bones/mesh indices).
pub export fn cardinal_animation_system_add_skin(system: ?*CardinalAnimationSystem, skin: ?*const CardinalSkin) callconv(.c) u32 {
    if (system == null or skin == null) return std.math.maxInt(u32);

    const index = system.?.skin_count;
    const dest = &system.?.skins.?[index];
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

    _ = c.memset(dest, 0, @sizeOf(CardinalSkin));

    if (skin.?.name) |name| {
        const name_len = c.strlen(name) + 1;
        const dest_name = memory.cardinal_alloc(allocator, name_len);
        if (dest_name) |ptr| {
            dest.name = @ptrCast(ptr);
            _ = c.strcpy(dest.name, name);
        }
    }

    const max_bones: u32 = 256;
    const bone_count: u32 = @min(skin.?.bone_count, max_bones);
    dest.bone_count = bone_count;
    dest.mesh_count = skin.?.mesh_count;
    dest.root_bone_index = if (bone_count == 0) 0 else @min(skin.?.root_bone_index, bone_count - 1);

    if (bone_count > 0 and skin.?.bones != null) {
        const bones_ptr = memory.cardinal_calloc(allocator, bone_count, @sizeOf(CardinalBone));
        if (bones_ptr) |ptr| {
            dest.bones = @ptrCast(@alignCast(ptr));
            var i: u32 = 0;
            while (i < bone_count) : (i += 1) {
                const src_bone = &skin.?.bones.?[i];
                const dst_bone = &dest.bones.?[i];

                if (src_bone.name) |name| {
                    const name_len = c.strlen(name) + 1;
                    const dest_name = memory.cardinal_alloc(allocator, name_len);
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
        } else {
            dest.bone_count = 0;
        }
    }

    if (skin.?.mesh_count > 0) {
        const indices_ptr = memory.cardinal_alloc(allocator, skin.?.mesh_count * @sizeOf(u32));
        if (indices_ptr) |ptr| {
            dest.mesh_indices = @ptrCast(@alignCast(ptr));
            @memcpy(dest.mesh_indices.?[0..skin.?.mesh_count], skin.?.mesh_indices.?[0..skin.?.mesh_count]);
        } else {
            dest.mesh_count = 0;
        }
    }

    system.?.skin_count += 1;
    anim_log.debug("Added skin '{s}' with {d} bones at index {d}", .{ if (dest.name) |n| std.mem.span(n) else "Unnamed", dest.bone_count, index });
    return index;
}

/// Starts playback of an animation, creating a state slot if needed.
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
        const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
        const new_count = system.?.state_count + 1;
        const new_bytes = new_count * @sizeOf(CardinalAnimationState);

        const new_states_ptr = if (system.?.states == null)
            memory.cardinal_calloc(allocator, new_count, @sizeOf(CardinalAnimationState))
        else
            memory.cardinal_realloc(allocator, system.?.states, new_bytes);

        if (new_states_ptr == null) return false;
        system.?.states = @ptrCast(@alignCast(new_states_ptr));

        state = &system.?.states.?[system.?.state_count];
        system.?.state_count += 1;

        state.?.animation_index = animation_index;
        state.?.current_time = 0.0;
        state.?.previous_time = 0.0;
        state.?.mask_weights = null;
        state.?.mask_count = 0;
        state.?.is_additive = false;
    }

    state.?.previous_time = state.?.current_time;
    state.?.is_playing = true;
    state.?.is_looping = loop;
    state.?.blend_weight = blend_weight;
    state.?.playback_speed = 1.0;

    anim_log.debug("Started animation {d} with blend weight {d:.2}", .{ animation_index, blend_weight });
    return true;
}

/// Pauses playback of an animation state (if present).
pub export fn cardinal_animation_pause(system: ?*CardinalAnimationSystem, animation_index: u32) callconv(.c) bool {
    if (system == null) return false;

    var i: u32 = 0;
    while (i < system.?.state_count) : (i += 1) {
        if (system.?.states.?[i].animation_index == animation_index) {
            system.?.states.?[i].is_playing = false;
            anim_log.debug("Paused animation {d}", .{animation_index});
            return true;
        }
    }

    return false;
}

/// Stops playback of an animation state (if present).
pub export fn cardinal_animation_stop(system: ?*CardinalAnimationSystem, animation_index: u32) callconv(.c) bool {
    if (system == null) return false;

    var i: u32 = 0;
    while (i < system.?.state_count) : (i += 1) {
        if (system.?.states.?[i].animation_index == animation_index) {
            system.?.states.?[i].is_playing = false;
            system.?.states.?[i].current_time = 0.0;
            system.?.states.?[i].previous_time = 0.0;
            anim_log.debug("Stopped animation {d}", .{animation_index});
            return true;
        }
    }

    return false;
}

/// Sets playback speed for an animation state (if present).
pub export fn cardinal_animation_set_speed(system: ?*CardinalAnimationSystem, animation_index: u32, speed: f32) callconv(.c) bool {
    if (system == null) return false;

    var i: u32 = 0;
    while (i < system.?.state_count) : (i += 1) {
        if (system.?.states.?[i].animation_index == animation_index) {
            system.?.states.?[i].playback_speed = speed;
            anim_log.debug("Set animation {d} speed to {d:.2}", .{ animation_index, speed });
            return true;
        }
    }

    return false;
}

/// Sets current playback time for an animation state (if present).
pub export fn cardinal_animation_set_time(system: ?*CardinalAnimationSystem, animation_index: u32, time: f32) callconv(.c) bool {
    if (system == null) return false;

    var i: u32 = 0;
    while (i < system.?.state_count) : (i += 1) {
        if (system.?.states.?[i].animation_index == animation_index) {
            system.?.states.?[i].current_time = time;
            system.?.states.?[i].previous_time = time;
            return true;
        }
    }

    return false;
}

fn find_state(system: *CardinalAnimationSystem, animation_index: u32) ?*CardinalAnimationState {
    var i: u32 = 0;
    while (i < system.state_count) : (i += 1) {
        if (system.states.?[i].animation_index == animation_index) {
            return &system.states.?[i];
        }
    }
    return null;
}

pub export fn cardinal_animation_set_additive(system: ?*CardinalAnimationSystem, animation_index: u32, additive: bool) callconv(.c) bool {
    if (system == null) return false;
    const s = system.?;
    if (animation_index >= s.animation_count) return false;

    const state = find_state(s, animation_index) orelse return false;
    state.is_additive = additive;
    return true;
}

pub export fn cardinal_animation_set_mask(system: ?*CardinalAnimationSystem, animation_index: u32, weights: ?[*]const f32, count: u32) callconv(.c) bool {
    if (system == null) return false;
    const s = system.?;
    if (animation_index >= s.animation_count) return false;

    const state = find_state(s, animation_index) orelse return false;
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

    if (state.mask_weights) |ptr| {
        memory.cardinal_free(allocator, ptr);
        state.mask_weights = null;
        state.mask_count = 0;
    }

    if (weights == null or count == 0) {
        return true;
    }

    const bytes = @as(usize, count) * @sizeOf(f32);
    const ptr = memory.cardinal_alloc(allocator, bytes) orelse return false;
    const dst = @as([*]f32, @ptrCast(@alignCast(ptr)));
    @memcpy(dst[0..count], weights.?[0..count]);

    state.mask_weights = dst;
    state.mask_count = count;
    return true;
}

/// Advances all active animation states and applies results to scene node transforms.
///
/// Maintains a per-node blend scratch buffer that grows geometrically to amortize allocations.
pub export fn cardinal_animation_system_update(system: ?*CardinalAnimationSystem, all_nodes: ?[*]?*scene.CardinalSceneNode, all_node_count: u32, delta_time: f32) callconv(.c) void {
    if (system == null) return;
    const sys = system.?;

    if (sys.blend_state_capacity < all_node_count) {
        const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
        if (sys.blend_states) |ptr| memory.cardinal_free(allocator, ptr);

        sys.blend_states = null;

        var new_capacity: u32 = if (sys.blend_state_capacity > 0) sys.blend_state_capacity else 256;
        while (new_capacity < all_node_count) {
            const doubled = std.math.mul(u32, new_capacity, 2) catch all_node_count;
            new_capacity = if (doubled < all_node_count) all_node_count else doubled;
        }

        const bytes = std.math.mul(usize, @as(usize, new_capacity), @sizeOf(CardinalBlendState)) catch {
            sys.blend_state_capacity = 0;
            return;
        };

        const ptr = memory.cardinal_alloc(allocator, bytes);
        if (ptr) |p| {
            sys.blend_state_capacity = new_capacity;
            sys.blend_states = @as([*]CardinalBlendState, @ptrCast(@alignCast(p)));
            _ = c.memset(sys.blend_states.?, 0, bytes);
        } else {
            sys.blend_state_capacity = 0;
            return;
        }
    }

    sys.blend_frame_id +%= 1;
    if (sys.blend_frame_id == 0) {
        sys.blend_frame_id = 1;
        if (sys.blend_states) |states| {
            _ = c.memset(states, 0, sys.blend_state_capacity * @sizeOf(CardinalBlendState));
        }
    }

    var i: u32 = 0;
    while (i < sys.state_count) : (i += 1) {
        const state = &sys.states.?[i];

        if (!state.is_playing) continue;

        const animation = &sys.animations.?[state.animation_index];

        const prev_time = state.current_time;
        state.current_time += delta_time * state.playback_speed;

        if (std.math.isNan(state.current_time)) {
            state.current_time = 0.0;
        }

        if (state.current_time >= animation.duration) {
            if (state.is_looping) {
                if (animation.duration > FLT_EPSILON) {
                    state.current_time = @mod(state.current_time, animation.duration);
                } else {
                    state.current_time = 0.0;
                }
            } else {
                state.current_time = animation.duration;
            }
        }

        state.previous_time = prev_time;
        const looped = state.is_looping and (state.current_time < prev_time) and (animation.duration > FLT_EPSILON);
        fire_animation_events(sys, state.animation_index, animation, prev_time, state.current_time, looped);

        var c_idx: u32 = 0;
        while (c_idx < animation.channel_count) : (c_idx += 1) {
            const channel = &animation.channels.?[c_idx];
            const sampler = &animation.samplers.?[channel.sampler_index];

            if (all_nodes == null or channel.target.node_index >= all_node_count) continue;
            if (all_nodes.?[channel.target.node_index] == null) continue;

            const node_idx = channel.target.node_index;
            const blend_state = &sys.blend_states.?[node_idx];

            var result: [4]f32 = undefined;
            var component_count: u32 = 3;
            if (channel.target.path == .ROTATION or channel.target.path == .WEIGHTS) {
                component_count = 4;
            }

            if (!sampler_interpolate_cached(sampler, state.current_time, component_count, &result)) continue;

            var weight = state.blend_weight;
            if (weight <= 0.001) continue;

            if (state.mask_weights != null and node_idx < state.mask_count) {
                weight *= state.mask_weights.?[node_idx];
                if (weight <= 0.001) continue;
            }

            if (blend_state.flags != sys.blend_frame_id) {
                blend_state.translation = .{ 0, 0, 0 };
                blend_state.rotation = .{ 0, 0, 0, 0 };
                blend_state.scale = .{ 0, 0, 0 };
                blend_state.weight_t = 0;
                blend_state.weight_r = 0;
                blend_state.weight_s = 0;
                blend_state.translation_add = .{ 0, 0, 0 };
                blend_state.rotation_add = .{ 0, 0, 0, 0 };
                blend_state.scale_add = .{ 0, 0, 0 };
                blend_state.weight_t_add = 0;
                blend_state.weight_r_add = 0;
                blend_state.weight_s_add = 0;
                blend_state.flags = sys.blend_frame_id;
            }

            const additive = state.is_additive;
            switch (channel.target.path) {
                .TRANSLATION => {
                    if (additive) {
                        blend_state.weight_t_add += weight;
                        blend_state.translation_add[0] += result[0] * weight;
                        blend_state.translation_add[1] += result[1] * weight;
                        blend_state.translation_add[2] += result[2] * weight;
                    } else {
                        blend_state.weight_t += weight;
                        blend_state.translation[0] += result[0] * weight;
                        blend_state.translation[1] += result[1] * weight;
                        blend_state.translation[2] += result[2] * weight;
                    }
                },
                .ROTATION => {
                    if (additive) {
                        if (blend_state.weight_r_add > 0) {
                            const dot = blend_state.rotation_add[0] * result[0] +
                                blend_state.rotation_add[1] * result[1] +
                                blend_state.rotation_add[2] * result[2] +
                                blend_state.rotation_add[3] * result[3];
                            if (dot < 0) {
                                blend_state.rotation_add[0] -= result[0] * weight;
                                blend_state.rotation_add[1] -= result[1] * weight;
                                blend_state.rotation_add[2] -= result[2] * weight;
                                blend_state.rotation_add[3] -= result[3] * weight;
                            } else {
                                blend_state.rotation_add[0] += result[0] * weight;
                                blend_state.rotation_add[1] += result[1] * weight;
                                blend_state.rotation_add[2] += result[2] * weight;
                                blend_state.rotation_add[3] += result[3] * weight;
                            }
                        } else {
                            blend_state.rotation_add[0] += result[0] * weight;
                            blend_state.rotation_add[1] += result[1] * weight;
                            blend_state.rotation_add[2] += result[2] * weight;
                            blend_state.rotation_add[3] += result[3] * weight;
                        }
                        blend_state.weight_r_add += weight;
                    } else {
                        if (blend_state.weight_r > 0) {
                            const dot = blend_state.rotation[0] * result[0] +
                                blend_state.rotation[1] * result[1] +
                                blend_state.rotation[2] * result[2] +
                                blend_state.rotation[3] * result[3];
                            if (dot < 0) {
                                blend_state.rotation[0] -= result[0] * weight;
                                blend_state.rotation[1] -= result[1] * weight;
                                blend_state.rotation[2] -= result[2] * weight;
                                blend_state.rotation[3] -= result[3] * weight;
                            } else {
                                blend_state.rotation[0] += result[0] * weight;
                                blend_state.rotation[1] += result[1] * weight;
                                blend_state.rotation[2] += result[2] * weight;
                                blend_state.rotation[3] += result[3] * weight;
                            }
                        } else {
                            blend_state.rotation[0] += result[0] * weight;
                            blend_state.rotation[1] += result[1] * weight;
                            blend_state.rotation[2] += result[2] * weight;
                            blend_state.rotation[3] += result[3] * weight;
                        }
                        blend_state.weight_r += weight;
                    }
                },
                .SCALE => {
                    if (additive) {
                        blend_state.weight_s_add += weight;
                        blend_state.scale_add[0] += (result[0] - 1.0) * weight;
                        blend_state.scale_add[1] += (result[1] - 1.0) * weight;
                        blend_state.scale_add[2] += (result[2] - 1.0) * weight;
                    } else {
                        blend_state.weight_s += weight;
                        blend_state.scale[0] += result[0] * weight;
                        blend_state.scale[1] += result[1] * weight;
                        blend_state.scale[2] += result[2] * weight;
                    }
                },
                else => {},
            }
        }
    }

    if (sys.blend_states) |states| {
        var n_idx: u32 = 0;
        while (n_idx < all_node_count) : (n_idx += 1) {
            const blend_state = &states[n_idx];
            if (blend_state.flags != sys.blend_frame_id) continue;

            const node = all_nodes.?[n_idx];
            if (node == null) continue;
            const scene_node = node.?;

            var current_t: [3]f32 = .{ 0, 0, 0 };
            var current_r: [4]f32 = .{ 0, 0, 0, 1 };
            var current_s: [3]f32 = .{ 1, 1, 1 };

            const local_matrix = &scene_node.local_transform;
            _ = transform.cardinal_matrix_decompose(local_matrix, &current_t, &current_r, &current_s);

            var t: [3]f32 = undefined;
            if (blend_state.weight_t > FLT_EPSILON) {
                const inv_weight = 1.0 / blend_state.weight_t;
                t[0] = blend_state.translation[0] * inv_weight;
                t[1] = blend_state.translation[1] * inv_weight;
                t[2] = blend_state.translation[2] * inv_weight;
            } else {
                t = current_t;
            }

            var s: [3]f32 = undefined;
            if (blend_state.weight_s > FLT_EPSILON) {
                const inv_weight = 1.0 / blend_state.weight_s;
                s[0] = blend_state.scale[0] * inv_weight;
                s[1] = blend_state.scale[1] * inv_weight;
                s[2] = blend_state.scale[2] * inv_weight;
            } else {
                s = current_s;
            }

            var r: [4]f32 = undefined;
            if (blend_state.weight_r > FLT_EPSILON) {
                r[0] = blend_state.rotation[0];
                r[1] = blend_state.rotation[1];
                r[2] = blend_state.rotation[2];
                r[3] = blend_state.rotation[3];
            } else {
                r = current_r;
            }
            transform.cardinal_quaternion_normalize(&r);

            if (blend_state.weight_t_add > FLT_EPSILON) {
                const inv_weight = 1.0 / blend_state.weight_t_add;
                t[0] += blend_state.translation_add[0] * inv_weight;
                t[1] += blend_state.translation_add[1] * inv_weight;
                t[2] += blend_state.translation_add[2] * inv_weight;
            }

            if (blend_state.weight_s_add > FLT_EPSILON) {
                const inv_weight = 1.0 / blend_state.weight_s_add;
                const dx = blend_state.scale_add[0] * inv_weight;
                const dy = blend_state.scale_add[1] * inv_weight;
                const dz = blend_state.scale_add[2] * inv_weight;
                s[0] *= 1.0 + dx;
                s[1] *= 1.0 + dy;
                s[2] *= 1.0 + dz;
            }

            if (blend_state.weight_r_add > FLT_EPSILON) {
                var delta: [4]f32 = .{
                    blend_state.rotation_add[0],
                    blend_state.rotation_add[1],
                    blend_state.rotation_add[2],
                    blend_state.rotation_add[3],
                };
                transform.cardinal_quaternion_normalize(&delta);
                var out_r: [4]f32 = undefined;
                quat_mul(&r, &delta, &out_r);
                r = out_r;
                transform.cardinal_quaternion_normalize(&r);
            }

            var new_transform: [16]f32 = undefined;
            transform.cardinal_matrix_from_trs(&t, &r, &s, &new_transform);
            scene.cardinal_scene_node_set_local_transform(node, &new_transform);
        }
    }

    if (all_nodes != null and all_node_count > 0) {
        var root_i: u32 = 0;
        while (root_i < all_node_count) : (root_i += 1) {
            const n = all_nodes.?[root_i] orelse continue;
            if (n.parent != null) continue;
            scene.cardinal_scene_node_update_transforms(n, null);
        }
    }
}

/// Writes skin bone matrices using `scene_nodes` for lookup (assumes indices are valid).
pub export fn cardinal_skin_update_bone_matrices(skin: ?*const CardinalSkin, scene_nodes: ?[*]?*const scene.CardinalSceneNode, bone_matrices: ?[*]f32) callconv(.c) bool {
    if (skin == null or scene_nodes == null or bone_matrices == null or skin.?.bones == null) return false;

    const max_bones: u32 = 256;
    const bone_count: u32 = @min(skin.?.bone_count, max_bones);
    var i: u32 = 0;
    while (i < bone_count) : (i += 1) {
        const bone = &skin.?.bones.?[i];
        const node = scene_nodes.?[bone.node_index];

        if (node == null) continue;

        const world_transform = scene.cardinal_scene_node_get_world_transform(@constCast(node));
        const bone_matrix = &bone_matrices.?[i * 16];
        const wt_ptr: *const [16]f32 = @ptrCast(world_transform);
        const ibm_ptr: *const [16]f32 = &bone.inverse_bind_matrix;
        const bm_ptr: *[16]f32 = @ptrCast(bone_matrix);
        transform.cardinal_matrix_multiply(wt_ptr, ibm_ptr, bm_ptr);
    }

    return true;
}

/// Writes skin bone matrices with bounds checking against `all_node_count`.
pub export fn cardinal_skin_update_bone_matrices_bounded(skin: ?*const CardinalSkin, scene_nodes: ?[*]?*const scene.CardinalSceneNode, all_node_count: u32, bone_matrices: ?[*]f32) callconv(.c) bool {
    if (skin == null or scene_nodes == null or bone_matrices == null or skin.?.bones == null) return false;

    const max_bones: u32 = 256;
    const bone_count: u32 = @min(skin.?.bone_count, max_bones);
    var i: u32 = 0;
    while (i < bone_count) : (i += 1) {
        const bone = &skin.?.bones.?[i];
        if (bone.node_index >= all_node_count) continue;
        const node = scene_nodes.?[bone.node_index];
        if (node == null) continue;

        const world_transform = scene.cardinal_scene_node_get_world_transform(@constCast(node));
        const bone_matrix = &bone_matrices.?[i * 16];
        const wt_ptr: *const [16]f32 = @ptrCast(world_transform);
        const ibm_ptr: *const [16]f32 = &bone.inverse_bind_matrix;
        const bm_ptr: *[16]f32 = @ptrCast(bone_matrix);
        transform.cardinal_matrix_multiply(wt_ptr, ibm_ptr, bm_ptr);
    }

    return true;
}

/// Writes mesh-local skin bone matrices using a mesh world transform for re-basing.
///
/// This variant enables applying the mesh transform in the vertex shader for skinned meshes.
pub export fn cardinal_skin_update_bone_matrices_bounded_mesh_local(
    skin: ?*const CardinalSkin,
    scene_nodes: ?[*]?*const scene.CardinalSceneNode,
    all_node_count: u32,
    mesh_world_transform: ?*const [16]f32,
    bone_matrices: ?[*]f32,
) callconv(.c) bool {
    if (skin == null or scene_nodes == null or bone_matrices == null or skin.?.bones == null or mesh_world_transform == null) return false;

    var mesh_inv: [16]f32 = undefined;
    if (!transform.cardinal_matrix_invert(mesh_world_transform.?, &mesh_inv)) return false;

    const max_bones: u32 = 256;
    const bone_count: u32 = @min(skin.?.bone_count, max_bones);
    var i: u32 = 0;
    while (i < bone_count) : (i += 1) {
        const bone = &skin.?.bones.?[i];
        if (bone.node_index >= all_node_count) continue;
        const node = scene_nodes.?[bone.node_index];
        if (node == null) continue;

        const world_transform = scene.cardinal_scene_node_get_world_transform(@constCast(node));
        const wt_ptr: *const [16]f32 = @ptrCast(world_transform);
        const ibm_ptr: *const [16]f32 = &bone.inverse_bind_matrix;

        var tmp: [16]f32 = undefined;
        transform.cardinal_matrix_multiply(&mesh_inv, wt_ptr, &tmp);

        const bone_matrix = &bone_matrices.?[i * 16];
        const bm_ptr: *[16]f32 = @ptrCast(bone_matrix);
        transform.cardinal_matrix_multiply(&tmp, ibm_ptr, bm_ptr);
    }

    return true;
}

/// Releases per-skin allocations (name/bones/mesh indices).
pub export fn cardinal_skin_destroy(skin: ?*CardinalSkin) callconv(.c) void {
    if (skin == null) return;
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

    if (skin.?.name) |ptr| memory.cardinal_free(allocator, ptr);

    if (skin.?.bones) |bones| {
        var i: u32 = 0;
        while (i < skin.?.bone_count) : (i += 1) {
            if (bones[i].name) |ptr| memory.cardinal_free(allocator, ptr);
        }
        memory.cardinal_free(allocator, skin.?.bones);
    }

    if (skin.?.mesh_indices) |ptr| memory.cardinal_free(allocator, ptr);
    _ = c.memset(skin, 0, @sizeOf(CardinalSkin));
}

fn rdp_simplify(times: [*]f32, values: [*]f32, component_count: u32, first: usize, last: usize, tolerance_sq: f32, kept_indices: []bool) !void {
    var max_dist_sq: f32 = 0;
    var index: usize = 0;

    const t_start = times[first];
    const t_end = times[last];
    const range = t_end - t_start;

    var i: usize = first + 1;
    while (i < last) : (i += 1) {
        const t = times[i];
        var factor: f32 = 0;
        if (range > 1e-6) {
            factor = (t - t_start) / range;
        }

        var dist_sq: f32 = 0;
        var comp_i: u32 = 0;
        while (comp_i < component_count) : (comp_i += 1) {
            const v = values[i * component_count + comp_i];
            const v1 = values[first * component_count + comp_i];
            const v2 = values[last * component_count + comp_i];
            const v_interp = v1 + (v2 - v1) * factor;
            const d = v - v_interp;
            dist_sq += d * d;
        }

        if (dist_sq > max_dist_sq) {
            max_dist_sq = dist_sq;
            index = i;
        }
    }

    if (max_dist_sq > tolerance_sq) {
        kept_indices[index] = true;
        try rdp_simplify(times, values, component_count, first, index, tolerance_sq, kept_indices);
        try rdp_simplify(times, values, component_count, index, last, tolerance_sq, kept_indices);
    }
}

/// Performs a best-effort in-place optimization pass on a single animation.
pub export fn cardinal_animation_optimize(animation: ?*CardinalAnimation, tolerance: f32) callconv(.c) void {
    if (animation == null) return;
    const anim = animation.?;
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);

    var i: u32 = 0;
    while (i < anim.sampler_count) : (i += 1) {
        const sampler = &anim.samplers.?[i];

        if (sampler.interpolation != .LINEAR) continue;
        if (sampler.input_count <= 2) continue;

        const component_count = sampler.output_count / sampler.input_count;
        if (component_count == 0) continue;

        var kept_indices = std.ArrayListUnmanaged(bool){};
        defer kept_indices.deinit(allocator.as_allocator());
        kept_indices.ensureTotalCapacity(allocator.as_allocator(), sampler.input_count) catch continue;

        kept_indices.appendNTimes(allocator.as_allocator(), false, sampler.input_count) catch continue;
        kept_indices.items[0] = true;
        kept_indices.items[sampler.input_count - 1] = true;

        rdp_simplify(sampler.input.?, sampler.output.?, component_count, 0, sampler.input_count - 1, tolerance * tolerance, kept_indices.items) catch continue;

        var new_count: u32 = 0;
        for (kept_indices.items) |keep| {
            if (keep) new_count += 1;
        }

        if (new_count < sampler.input_count) {
            const new_input = memory.cardinal_alloc(allocator, new_count * @sizeOf(f32));
            const new_output = memory.cardinal_alloc(allocator, new_count * component_count * @sizeOf(f32));

            if (new_input != null and new_output != null) {
                const ni: [*]f32 = @ptrCast(@alignCast(new_input));
                const no: [*]f32 = @ptrCast(@alignCast(new_output));

                var dst_idx: u32 = 0;
                var src_idx: u32 = 0;
                while (src_idx < sampler.input_count) : (src_idx += 1) {
                    if (kept_indices.items[src_idx]) {
                        ni[dst_idx] = sampler.input.?[src_idx];

                        var c_idx: u32 = 0;
                        while (c_idx < component_count) : (c_idx += 1) {
                            no[dst_idx * component_count + c_idx] = sampler.output.?[src_idx * component_count + c_idx];
                        }

                        dst_idx += 1;
                    }
                }

                if (sampler.input) |ptr| memory.cardinal_free(allocator, ptr);
                if (sampler.output) |ptr| memory.cardinal_free(allocator, ptr);

                sampler.input = ni;
                sampler.output = no;
                sampler.input_count = new_count;
                sampler.output_count = new_count * component_count;
                sampler.last_index = 0;

                anim_log.debug("Optimized sampler {d}: {d} -> {d} frames", .{ i, kept_indices.items.len, new_count });
            } else {
                if (new_input) |ptr| memory.cardinal_free(allocator, ptr);
                if (new_output) |ptr| memory.cardinal_free(allocator, ptr);
            }
        }
    }
}
