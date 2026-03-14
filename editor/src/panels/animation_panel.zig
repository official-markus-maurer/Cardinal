//! Animation panel.
//!
//! Displays animations present in the currently loaded combined scene and provides basic playback
//! controls and time scrubbing.
//!
//! TODO: Add per-channel inspection and bone debug visualization.
const std = @import("std");
const engine = @import("cardinal_engine");
const animation = engine.animation;
const editor_state = @import("../editor_state.zig");
const c = @import("../c.zig").c;

/// Draws the animation panel.
pub fn draw_animation_panel(state: *editor_state.EditorState) void {
    if (state.ui.show_animation) {
        const open = c.imgui_bridge_begin("Animation", &state.ui.show_animation, 0);
        defer c.imgui_bridge_end();

        if (open) {
            if (state.runtime.scene_loaded and state.runtime.combined_scene.animation_system != null) {
                const anim_sys_opaque = state.runtime.combined_scene.animation_system.?;
                const anim_sys = @as(*animation.CardinalAnimationSystem, @ptrCast(@alignCast(anim_sys_opaque)));

                c.imgui_bridge_text("Animations (%d)", anim_sys.animation_count);
                c.imgui_bridge_separator();

                if (state.ui.selected_animation == -1 and anim_sys.animation_count > 0) {
                    state.ui.selected_animation = 0;
                    state.ui.animation_time = 0.0;
                }

                if (c.imgui_bridge_begin_child("##animation_list", 0, 120, true, 0)) {
                    var i: u32 = 0;
                    while (i < anim_sys.animation_count) : (i += 1) {
                        const anim = &anim_sys.animations.?[i];
                        const name = if (anim.name) |n| std.mem.span(n) else "Unnamed Animation";

                        const is_selected = (state.ui.selected_animation == @as(i32, @intCast(i)));
                        if (c.imgui_bridge_selectable(name.ptr, is_selected, 0)) {
                            state.ui.selected_animation = @as(i32, @intCast(i));
                            state.ui.animation_time = 0.0;
                        }

                        c.imgui_bridge_same_line(0, -1);
                        c.imgui_bridge_text_disabled("(%.2fs, %d channels)", anim.duration, anim.channel_count);
                    }
                    c.imgui_bridge_end_child();
                }

                c.imgui_bridge_separator();

                if (state.ui.selected_animation >= 0 and state.ui.selected_animation < anim_sys.animation_count) {
                    const current_anim = &anim_sys.animations.?[@intCast(state.ui.selected_animation)];

                    c.imgui_bridge_text("Playback Controls");

                    if (state.ui.animation_playing) {
                        if (c.imgui_bridge_button("Pause")) {
                            state.ui.animation_playing = false;
                            _ = animation.cardinal_animation_pause(anim_sys, @intCast(state.ui.selected_animation));
                        }
                    } else {
                        if (c.imgui_bridge_button("Play")) {
                            state.ui.animation_playing = true;
                            _ = animation.cardinal_animation_play(anim_sys, @intCast(state.ui.selected_animation), state.ui.animation_looping, 1.0);
                            _ = animation.cardinal_animation_set_speed(anim_sys, @intCast(state.ui.selected_animation), state.ui.animation_speed);
                        }
                    }

                    c.imgui_bridge_same_line(0, -1);
                    if (c.imgui_bridge_button("Stop")) {
                        state.ui.animation_playing = false;
                        state.ui.animation_time = 0.0;
                        _ = animation.cardinal_animation_stop(anim_sys, @intCast(state.ui.selected_animation));
                    }

                    c.imgui_bridge_same_line(0, -1);
                    _ = c.imgui_bridge_checkbox("Loop", &state.ui.animation_looping);

                    // Speed control
                    c.imgui_bridge_set_next_item_width(100);
                    if (c.imgui_bridge_slider_float("Speed", &state.ui.animation_speed, 0.1, 3.0, "%.1fx")) {
                        _ = animation.cardinal_animation_set_speed(anim_sys, @intCast(state.ui.selected_animation), state.ui.animation_speed);
                    }

                    c.imgui_bridge_separator();
                    c.imgui_bridge_text("Timeline");

                    c.imgui_bridge_text("Time: %.2f / %.2f seconds", state.ui.animation_time, current_anim.duration);

                    if (c.imgui_bridge_slider_float("##timeline", &state.ui.animation_time, 0.0, current_anim.duration, "%.2fs")) {
                        if (state.ui.animation_time < 0.0) state.ui.animation_time = 0.0;
                        if (state.ui.animation_time > current_anim.duration) {
                            if (state.ui.animation_looping) {
                                if (current_anim.duration > 0.000001) {
                                    state.ui.animation_time = @mod(state.ui.animation_time, current_anim.duration);
                                } else {
                                    state.ui.animation_time = 0.0;
                                }
                            } else {
                                state.ui.animation_time = current_anim.duration;
                                state.ui.animation_playing = false;
                            }
                        }
                        _ = animation.cardinal_animation_set_time(anim_sys, @intCast(state.ui.selected_animation), state.ui.animation_time);
                    }

                    c.imgui_bridge_separator();
                    c.imgui_bridge_text("Animation Info");
                    c.imgui_bridge_text("Name: %s", if (current_anim.name) |n| n else "Unnamed");
                    c.imgui_bridge_text("Duration: %.2f seconds", current_anim.duration);
                    c.imgui_bridge_text("Channels: %d", current_anim.channel_count);
                    c.imgui_bridge_text("Samplers: %d", current_anim.sampler_count);

                    if (c.imgui_bridge_collapsing_header("Channels", 0)) {
                        var i: u32 = 0;
                        while (i < current_anim.channel_count) : (i += 1) {
                            const channel = &current_anim.channels.?[i];
                            c.imgui_bridge_text("Channel %d: Node %d, Target %d", i, channel.target.node_index, @intFromEnum(channel.target.path));
                        }
                    }
                } else {
                    c.imgui_bridge_text_disabled("Select an animation to see controls");
                }
            } else {
                c.imgui_bridge_text("No animations");
                c.imgui_bridge_text_wrapped("Load a scene with animations to see animation controls.");
            }
        }
    }
}
