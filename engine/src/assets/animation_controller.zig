const std = @import("std");
const memory = @import("../core/memory.zig");
const animation = @import("animation.zig");
const c = @cImport({
    @cInclude("string.h");
    @cInclude("math.h");
});

// === Asset Definitions ===

pub const AnimConditionOp = enum(c_int) {
    Greater = 0,
    Less = 1,
    Equal = 2,
    NotEqual = 3,
};

pub const AnimCondition = extern struct {
    param_hash: u32,
    operator: AnimConditionOp,
    threshold: f32,
};

pub const AnimTransition = extern struct {
    target_state_hash: u32,
    duration: f32,
    conditions: ?[*]AnimCondition,
    condition_count: u32,
};

pub const AnimNodeType = enum(c_int) {
    Clip = 0,
    Blend1D = 1,
};

pub const AnimNode = extern struct {
    type: AnimNodeType,
    // Clip
    animation_name_hash: u32,
    loop: bool,
    speed: f32,
    // Blend
    param_hash: u32,
    child_count: u32,
    children: ?[*]AnimNode,
    thresholds: ?[*]f32,
};

pub const AnimState = extern struct {
    name_hash: u32,
    root_node: ?*AnimNode,
    transitions: ?[*]AnimTransition,
    transition_count: u32,
};

pub const AnimStateMachineDef = extern struct {
    states: ?[*]AnimState,
    state_count: u32,
    start_state_hash: u32,
};

// === Runtime ===

const MAX_PARAMS = 32;

pub const AnimController = extern struct {
    definition: ?*const AnimStateMachineDef,
    system: ?*animation.CardinalAnimationSystem,
    
    current_state_index: u32,
    
    // Transition logic
    is_transitioning: bool,
    next_state_index: u32,
    transition_time: f32,
    transition_duration: f32,
    
    // Parameters
    param_hashes: [MAX_PARAMS]u32,
    param_values: [MAX_PARAMS]f32,
    param_count: u32,
    
    // State time
    current_state_time: f32,
    next_state_time: f32,
};

// Helper to hash string (fnv1a)
fn hash_string(str: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (str) |byte| {
        hash ^= byte;
        hash *%= 16777619;
    }
    return hash;
}

// Helper to find animation index by hash
fn find_animation_index(system: *animation.CardinalAnimationSystem, name_hash: u32) ?u32 {
    var i: u32 = 0;
    while (i < system.animation_count) : (i += 1) {
        const anim = &system.animations.?[i];
        if (anim.name) |name_ptr| {
            const len = c.strlen(name_ptr);
            const name = name_ptr[0..len];
            if (hash_string(name) == name_hash) {
                return i;
            }
        }
    }
    return null;
}

pub export fn cardinal_anim_controller_create(def: ?*const AnimStateMachineDef, system: ?*animation.CardinalAnimationSystem) callconv(.c) ?*AnimController {
    if (def == null or system == null) return null;
    
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    const ptr = memory.cardinal_calloc(allocator, 1, @sizeOf(AnimController));
    if (ptr == null) return null;
    
    const controller: *AnimController = @ptrCast(@alignCast(ptr));
    controller.definition = def;
    controller.system = system;
    
    // Find start state
    var i: u32 = 0;
    while (i < def.?.state_count) : (i += 1) {
        if (def.?.states.?[i].name_hash == def.?.start_state_hash) {
            controller.current_state_index = i;
            break;
        }
    }
    
    return controller;
}

pub export fn cardinal_anim_controller_destroy(controller: ?*AnimController) callconv(.c) void {
    if (controller == null) return;
    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE);
    memory.cardinal_free(allocator, controller);
}

pub export fn cardinal_anim_controller_set_param(controller: ?*AnimController, name: ?[*:0]const u8, value: f32) callconv(.c) void {
    if (controller == null or name == null) return;
    const ctrl = controller.?;
    const len = c.strlen(name);
    const hash = hash_string(name.?[0..len]);
    
    var i: u32 = 0;
    while (i < ctrl.param_count) : (i += 1) {
        if (ctrl.param_hashes[i] == hash) {
            ctrl.param_values[i] = value;
            return;
        }
    }
    
    if (ctrl.param_count < MAX_PARAMS) {
        ctrl.param_hashes[ctrl.param_count] = hash;
        ctrl.param_values[ctrl.param_count] = value;
        ctrl.param_count += 1;
    }
}

fn get_param_value(ctrl: *AnimController, hash: u32) f32 {
    var i: u32 = 0;
    while (i < ctrl.param_count) : (i += 1) {
        if (ctrl.param_hashes[i] == hash) {
            return ctrl.param_values[i];
        }
    }
    return 0.0;
}

fn evaluate_node(ctrl: *AnimController, node: *const AnimNode, time: f32, weight: f32) void {
    if (weight <= 0.001) return;
    
    switch (node.type) {
        .Clip => {
            const anim_idx = find_animation_index(ctrl.system.?, node.animation_name_hash);
            if (anim_idx) |idx| {
                // Try to find existing state first
                var found_state: ?*animation.CardinalAnimationState = null;
                var i: u32 = 0;
                while (i < ctrl.system.?.state_count) : (i += 1) {
                    if (ctrl.system.?.states.?[i].animation_index == idx) {
                        found_state = &ctrl.system.?.states.?[i];
                        break;
                    }
                }

                if (found_state == null) {
                    // Start it if not found
                    if (animation.cardinal_animation_play(ctrl.system, idx, node.loop, weight)) {
                        // Find it again
                        var j: u32 = 0;
                        while (j < ctrl.system.?.state_count) : (j += 1) {
                            if (ctrl.system.?.states.?[j].animation_index == idx) {
                                found_state = &ctrl.system.?.states.?[j];
                                break;
                            }
                        }
                    }
                }

                if (found_state) |state| {
                    // Force time (sync) and disable auto-advance
                    const anim = &ctrl.system.?.animations.?[idx];
                    if (anim.duration > 0) {
                        var t = time * node.speed;
                        if (node.loop) {
                            t = @mod(t, anim.duration);
                        } else {
                            if (t > anim.duration) t = anim.duration;
                        }
                        state.current_time = t;
                    }
                    
                    state.blend_weight = weight;
                    state.is_playing = true;
                    state.playback_speed = 0.0; // Controller drives the time
                }
            }
        },
        .Blend1D => {
            if (node.child_count == 0) return;
            const param_val = get_param_value(ctrl, node.param_hash);
            
            // Find children to blend
            // Simple linear blend between two closest thresholds
            var idx_a: u32 = 0;
            var idx_b: u32 = 0;
            var t: f32 = 0.0;
            
            if (node.child_count == 1) {
                evaluate_node(ctrl, &node.children.?[0], time, weight);
                return;
            }
            
            // Find interval
            // Assume sorted thresholds?
            // If not, we should sort or search. Assume sorted for now.
            
            if (param_val <= node.thresholds.?[0]) {
                evaluate_node(ctrl, &node.children.?[0], time, weight);
                return;
            }
            
            if (param_val >= node.thresholds.?[node.child_count - 1]) {
                evaluate_node(ctrl, &node.children.?[node.child_count - 1], time, weight);
                return;
            }
            
            var i: u32 = 0;
            while (i < node.child_count - 1) : (i += 1) {
                const t1 = node.thresholds.?[i];
                const t2 = node.thresholds.?[i+1];
                if (param_val >= t1 and param_val <= t2) {
                    idx_a = i;
                    idx_b = i+1;
                    if (t2 - t1 > 0.0001) {
                        t = (param_val - t1) / (t2 - t1);
                    }
                    break;
                }
            }
            
            evaluate_node(ctrl, &node.children.?[idx_a], time, weight * (1.0 - t));
            evaluate_node(ctrl, &node.children.?[idx_b], time, weight * t);
        }
    }
}

pub export fn cardinal_anim_controller_update(controller: ?*AnimController, delta_time: f32) callconv(.c) void {
    if (controller == null) return;
    const ctrl = controller.?;
    const def = ctrl.definition.?;
    
    // Reset all states weight to 0
    if (ctrl.system) |sys| {
        var i: u32 = 0;
        while (i < sys.state_count) : (i += 1) {
            sys.states.?[i].blend_weight = 0.0;
        }
    }

    // Check transitions
    if (!ctrl.is_transitioning) {
        const current_state = &def.states.?[ctrl.current_state_index];
        var i: u32 = 0;
        while (i < current_state.transition_count) : (i += 1) {
            const trans = &current_state.transitions.?[i];
            
            // Check conditions
            var all_met = true;
            var c_idx: u32 = 0;
            while (c_idx < trans.condition_count) : (c_idx += 1) {
                const cond = &trans.conditions.?[c_idx];
                const val = get_param_value(ctrl, cond.param_hash);
                
                const met = switch (cond.operator) {
                    .Greater => val > cond.threshold,
                    .Less => val < cond.threshold,
                    .Equal => @abs(val - cond.threshold) < 0.001,
                    .NotEqual => @abs(val - cond.threshold) >= 0.001,
                };
                
                if (!met) {
                    all_met = false;
                    break;
                }
            }
            
            if (all_met) {
                // Find next state index
                var next_idx: u32 = 0;
                while (next_idx < def.state_count) : (next_idx += 1) {
                    if (def.states.?[next_idx].name_hash == trans.target_state_hash) {
                        ctrl.is_transitioning = true;
                        ctrl.next_state_index = next_idx;
                        ctrl.transition_time = 0.0;
                        ctrl.transition_duration = trans.duration;
                        ctrl.next_state_time = 0.0;
                        break;
                    }
                }
                if (ctrl.is_transitioning) break;
            }
        }
    }
    
    // Update State Logic
    ctrl.current_state_time += delta_time;
    if (ctrl.is_transitioning) {
        ctrl.next_state_time += delta_time;
        ctrl.transition_time += delta_time;
        
        var t: f32 = 1.0;
        if (ctrl.transition_duration > 0) {
            t = ctrl.transition_time / ctrl.transition_duration;
        }
        
        if (t >= 1.0) {
            // Finish transition
            ctrl.current_state_index = ctrl.next_state_index;
            ctrl.current_state_time = ctrl.next_state_time;
            ctrl.is_transitioning = false;
            
            // Evaluate new current only
            if (def.states.?[ctrl.current_state_index].root_node) |node| {
                evaluate_node(ctrl, node, ctrl.current_state_time, 1.0);
            }
        } else {
            // Blend
            const w_next = t;
            const w_curr = 1.0 - t;
            
            if (def.states.?[ctrl.current_state_index].root_node) |node| {
                evaluate_node(ctrl, node, ctrl.current_state_time, w_curr);
            }
            if (def.states.?[ctrl.next_state_index].root_node) |node| {
                evaluate_node(ctrl, node, ctrl.next_state_time, w_next);
            }
        }
    } else {
        // Just current state
        if (def.states.?[ctrl.current_state_index].root_node) |node| {
            evaluate_node(ctrl, node, ctrl.current_state_time, 1.0);
        }
    }
}
