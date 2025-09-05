/**
 * @file animation.c
 * @brief Animation system implementation for Cardinal Engine
 *
 * This file implements the animation system including keyframe interpolation,
 * animation playback control, and skeletal animation support.
 *
 * @author Markus Maurer
 * @version 1.0
 */

#include "cardinal/core/animation.h"
#include "cardinal/assets/scene.h"
#include "cardinal/core/transform.h"
#include "cardinal/core/log.h"

#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <float.h>

// Helper function to find keyframe indices for interpolation
static bool find_keyframe_indices(const float *input, uint32_t input_count, float time,
                                 uint32_t *prev_index, uint32_t *next_index, float *factor) {
    if (!input || input_count == 0) {
        return false;
    }

    // Handle edge cases
    if (time <= input[0]) {
        *prev_index = 0;
        *next_index = 0;
        *factor = 0.0f;
        return true;
    }
    
    if (time >= input[input_count - 1]) {
        *prev_index = input_count - 1;
        *next_index = input_count - 1;
        *factor = 0.0f;
        return true;
    }

    // Binary search for the correct interval
    uint32_t left = 0;
    uint32_t right = input_count - 1;
    
    while (left < right - 1) {
        uint32_t mid = (left + right) / 2;
        if (input[mid] <= time) {
            left = mid;
        } else {
            right = mid;
        }
    }

    *prev_index = left;
    *next_index = right;
    
    // Calculate interpolation factor
    float time_diff = input[right] - input[left];
    if (time_diff > 0.0f) {
        *factor = (time - input[left]) / time_diff;
    } else {
        *factor = 0.0f;
    }

    return true;
}

// Linear interpolation for vectors
static void lerp_vector(const float *a, const float *b, float t, uint32_t component_count, float *result) {
    for (uint32_t i = 0; i < component_count; ++i) {
        result[i] = a[i] + t * (b[i] - a[i]);
    }
}

// Spherical linear interpolation for quaternions
static void slerp_quaternion(const float *a, const float *b, float t, float *result) {
    float dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
    
    // If the dot product is negative, slerp won't take the shorter path
    float b_sign[4];
    if (dot < 0.0f) {
        dot = -dot;
        for (int i = 0; i < 4; ++i) {
            b_sign[i] = -b[i];
        }
    } else {
        for (int i = 0; i < 4; ++i) {
            b_sign[i] = b[i];
        }
    }
    
    // If the quaternions are very close, use linear interpolation
    if (dot > 0.9995f) {
        lerp_vector(a, b_sign, t, 4, result);
        // Normalize the result
        float length = sqrtf(result[0] * result[0] + result[1] * result[1] + 
                            result[2] * result[2] + result[3] * result[3]);
        if (length > 0.0f) {
            for (int i = 0; i < 4; ++i) {
                result[i] /= length;
            }
        }
        return;
    }
    
    // Calculate the angle between the quaternions
    float theta = acosf(dot);
    float sin_theta = sinf(theta);
    
    if (sin_theta > 0.0f) {
        float factor_a = sinf((1.0f - t) * theta) / sin_theta;
        float factor_b = sinf(t * theta) / sin_theta;
        
        for (int i = 0; i < 4; ++i) {
            result[i] = factor_a * a[i] + factor_b * b_sign[i];
        }
    } else {
        // Fallback to linear interpolation
        lerp_vector(a, b_sign, t, 4, result);
    }
}

// Cubic spline interpolation
static void cubic_spline_interpolate(const float *values, uint32_t prev_index, uint32_t next_index,
                                   float factor, uint32_t component_count, float *result) {
    // For cubic spline, we need tangent vectors
    // This is a simplified implementation - full cubic spline would require proper tangent calculation
    // For now, fall back to linear interpolation
    const float *prev_value = &values[prev_index * component_count];
    const float *next_value = &values[next_index * component_count];
    lerp_vector(prev_value, next_value, factor, component_count, result);
}

bool cardinal_animation_interpolate(CardinalAnimationInterpolation interpolation, float time,
                                   const float *input, const float *output,
                                   uint32_t input_count, uint32_t component_count,
                                   float *result) {
    if (!input || !output || !result || input_count == 0 || component_count == 0) {
        return false;
    }

    uint32_t prev_index, next_index;
    float factor;
    
    if (!find_keyframe_indices(input, input_count, time, &prev_index, &next_index, &factor)) {
        return false;
    }

    const float *prev_value = &output[prev_index * component_count];
    const float *next_value = &output[next_index * component_count];

    switch (interpolation) {
        case CARDINAL_ANIMATION_INTERPOLATION_STEP:
            memcpy(result, prev_value, component_count * sizeof(float));
            break;
            
        case CARDINAL_ANIMATION_INTERPOLATION_LINEAR:
            if (component_count == 4) {
                // Assume quaternion for 4-component values
                slerp_quaternion(prev_value, next_value, factor, result);
            } else {
                lerp_vector(prev_value, next_value, factor, component_count, result);
            }
            break;
            
        case CARDINAL_ANIMATION_INTERPOLATION_CUBICSPLINE:
            cubic_spline_interpolate(output, prev_index, next_index, factor, component_count, result);
            break;
            
        default:
            return false;
    }

    return true;
}

CardinalAnimationSystem *cardinal_animation_system_create(uint32_t max_animations, uint32_t max_skins) {
    CardinalAnimationSystem *system = (CardinalAnimationSystem*)calloc(1, sizeof(CardinalAnimationSystem));
    if (!system) {
        CARDINAL_LOG_ERROR("Failed to allocate animation system");
        return NULL;
    }

    if (max_animations > 0) {
        system->animations = (CardinalAnimation*)calloc(max_animations, sizeof(CardinalAnimation));
        if (!system->animations) {
            CARDINAL_LOG_ERROR("Failed to allocate animations array");
            free(system);
            return NULL;
        }
    }

    if (max_skins > 0) {
        system->skins = (CardinalSkin*)calloc(max_skins, sizeof(CardinalSkin));
        if (!system->skins) {
            CARDINAL_LOG_ERROR("Failed to allocate skins array");
            free(system->animations);
            free(system);
            return NULL;
        }
    }

    system->animation_count = 0;
    system->skin_count = 0;
    system->state_count = 0;
    system->bone_matrix_count = 0;

    CARDINAL_LOG_INFO("Animation system created with capacity for %u animations and %u skins",
                     max_animations, max_skins);
    return system;
}

void cardinal_animation_system_destroy(CardinalAnimationSystem *system) {
    if (!system) {
        return;
    }

    // Free animations
    if (system->animations) {
        for (uint32_t i = 0; i < system->animation_count; ++i) {
            CardinalAnimation *anim = &system->animations[i];
            free(anim->name);
            
            if (anim->samplers) {
                for (uint32_t j = 0; j < anim->sampler_count; ++j) {
                    free(anim->samplers[j].input);
                    free(anim->samplers[j].output);
                }
                free(anim->samplers);
            }
            
            free(anim->channels);
        }
        free(system->animations);
    }

    // Free skins
    if (system->skins) {
        for (uint32_t i = 0; i < system->skin_count; ++i) {
            CardinalSkin *skin = &system->skins[i];
            free(skin->name);
            
            if (skin->bones) {
                for (uint32_t j = 0; j < skin->bone_count; ++j) {
                    free(skin->bones[j].name);
                }
                free(skin->bones);
            }
            
            free(skin->mesh_indices);
        }
        free(system->skins);
    }

    free(system->states);
    free(system->bone_matrices);
    free(system);
    
    CARDINAL_LOG_DEBUG("Animation system destroyed");
}

uint32_t cardinal_animation_system_add_animation(CardinalAnimationSystem *system, const CardinalAnimation *animation) {
    if (!system || !animation) {
        return UINT32_MAX;
    }

    // For simplicity, assume we have space (in a real implementation, we'd resize arrays)
    uint32_t index = system->animation_count;
    CardinalAnimation *dest = &system->animations[index];
    
    // Copy animation data
    memset(dest, 0, sizeof(CardinalAnimation));
    
    if (animation->name) {
        size_t name_len = strlen(animation->name) + 1;
        dest->name = (char*)malloc(name_len);
        if (dest->name) {
            strcpy(dest->name, animation->name);
        }
    }
    
    dest->duration = animation->duration;
    dest->sampler_count = animation->sampler_count;
    dest->channel_count = animation->channel_count;
    
    // Copy samplers
    if (animation->sampler_count > 0) {
        dest->samplers = (CardinalAnimationSampler*)calloc(animation->sampler_count, sizeof(CardinalAnimationSampler));
        if (dest->samplers) {
            for (uint32_t i = 0; i < animation->sampler_count; ++i) {
                const CardinalAnimationSampler *src_sampler = &animation->samplers[i];
                CardinalAnimationSampler *dst_sampler = &dest->samplers[i];
                
                dst_sampler->interpolation = src_sampler->interpolation;
                dst_sampler->input_count = src_sampler->input_count;
                dst_sampler->output_count = src_sampler->output_count;
                
                // Copy input data
                if (src_sampler->input && src_sampler->input_count > 0) {
                    dst_sampler->input = (float*)malloc(src_sampler->input_count * sizeof(float));
                    if (dst_sampler->input) {
                        memcpy(dst_sampler->input, src_sampler->input, src_sampler->input_count * sizeof(float));
                    }
                }
                
                // Copy output data
                if (src_sampler->output && src_sampler->output_count > 0) {
                    dst_sampler->output = (float*)malloc(src_sampler->output_count * sizeof(float));
                    if (dst_sampler->output) {
                        memcpy(dst_sampler->output, src_sampler->output, src_sampler->output_count * sizeof(float));
                    }
                }
            }
        }
    }
    
    // Copy channels
    if (animation->channel_count > 0) {
        dest->channels = (CardinalAnimationChannel*)malloc(animation->channel_count * sizeof(CardinalAnimationChannel));
        if (dest->channels) {
            memcpy(dest->channels, animation->channels, animation->channel_count * sizeof(CardinalAnimationChannel));
        }
    }
    
    system->animation_count++;
    CARDINAL_LOG_DEBUG("Added animation '%s' at index %u", dest->name ? dest->name : "Unnamed", index);
    return index;
}

uint32_t cardinal_animation_system_add_skin(CardinalAnimationSystem *system, const CardinalSkin *skin) {
    if (!system || !skin) {
        return UINT32_MAX;
    }

    uint32_t index = system->skin_count;
    CardinalSkin *dest = &system->skins[index];
    
    memset(dest, 0, sizeof(CardinalSkin));
    
    if (skin->name) {
        size_t name_len = strlen(skin->name) + 1;
        dest->name = (char*)malloc(name_len);
        if (dest->name) {
            strcpy(dest->name, skin->name);
        }
    }
    
    dest->bone_count = skin->bone_count;
    dest->mesh_count = skin->mesh_count;
    dest->root_bone_index = skin->root_bone_index;
    
    // Copy bones
    if (skin->bone_count > 0) {
        dest->bones = (CardinalBone*)calloc(skin->bone_count, sizeof(CardinalBone));
        if (dest->bones) {
            for (uint32_t i = 0; i < skin->bone_count; ++i) {
                const CardinalBone *src_bone = &skin->bones[i];
                CardinalBone *dst_bone = &dest->bones[i];
                
                if (src_bone->name) {
                    size_t name_len = strlen(src_bone->name) + 1;
                    dst_bone->name = (char*)malloc(name_len);
                    if (dst_bone->name) {
                        strcpy(dst_bone->name, src_bone->name);
                    }
                }
                
                dst_bone->node_index = src_bone->node_index;
                dst_bone->parent_index = src_bone->parent_index;
                memcpy(dst_bone->inverse_bind_matrix, src_bone->inverse_bind_matrix, 16 * sizeof(float));
                memcpy(dst_bone->current_matrix, src_bone->current_matrix, 16 * sizeof(float));
            }
        }
    }
    
    // Copy mesh indices
    if (skin->mesh_count > 0) {
        dest->mesh_indices = (uint32_t*)malloc(skin->mesh_count * sizeof(uint32_t));
        if (dest->mesh_indices) {
            memcpy(dest->mesh_indices, skin->mesh_indices, skin->mesh_count * sizeof(uint32_t));
        }
    }
    
    system->skin_count++;
    CARDINAL_LOG_DEBUG("Added skin '%s' with %u bones at index %u", 
                      dest->name ? dest->name : "Unnamed", dest->bone_count, index);
    return index;
}

bool cardinal_animation_play(CardinalAnimationSystem *system, uint32_t animation_index, bool loop, float blend_weight) {
    if (!system || animation_index >= system->animation_count) {
        return false;
    }

    // Find existing state or create new one
    CardinalAnimationState *state = NULL;
    for (uint32_t i = 0; i < system->state_count; ++i) {
        if (system->states[i].animation_index == animation_index) {
            state = &system->states[i];
            break;
        }
    }
    
    if (!state) {
        // Create new state
        system->states = (CardinalAnimationState*)realloc(system->states, 
                                                          (system->state_count + 1) * sizeof(CardinalAnimationState));
        if (!system->states) {
            return false;
        }
        
        state = &system->states[system->state_count];
        system->state_count++;
        
        state->animation_index = animation_index;
        state->current_time = 0.0f;
    }
    
    state->is_playing = true;
    state->is_looping = loop;
    state->blend_weight = blend_weight;
    state->playback_speed = 1.0f;
    
    CARDINAL_LOG_DEBUG("Started animation %u with blend weight %.2f", animation_index, blend_weight);
    return true;
}

bool cardinal_animation_pause(CardinalAnimationSystem *system, uint32_t animation_index) {
    if (!system) {
        return false;
    }

    for (uint32_t i = 0; i < system->state_count; ++i) {
        if (system->states[i].animation_index == animation_index) {
            system->states[i].is_playing = false;
            CARDINAL_LOG_DEBUG("Paused animation %u", animation_index);
            return true;
        }
    }
    
    return false;
}

bool cardinal_animation_stop(CardinalAnimationSystem *system, uint32_t animation_index) {
    if (!system) {
        return false;
    }

    for (uint32_t i = 0; i < system->state_count; ++i) {
        if (system->states[i].animation_index == animation_index) {
            system->states[i].is_playing = false;
            system->states[i].current_time = 0.0f;
            CARDINAL_LOG_DEBUG("Stopped animation %u", animation_index);
            return true;
        }
    }
    
    return false;
}

bool cardinal_animation_set_speed(CardinalAnimationSystem *system, uint32_t animation_index, float speed) {
    if (!system) {
        return false;
    }

    for (uint32_t i = 0; i < system->state_count; ++i) {
        if (system->states[i].animation_index == animation_index) {
            system->states[i].playback_speed = speed;
            CARDINAL_LOG_DEBUG("Set animation %u speed to %.2f", animation_index, speed);
            return true;
        }
    }
    
    return false;
}

void cardinal_animation_system_update(CardinalAnimationSystem *system, float delta_time) {
    if (!system) {
        return;
    }

    // Update all active animation states
    for (uint32_t i = 0; i < system->state_count; ++i) {
        CardinalAnimationState *state = &system->states[i];
        
        if (!state->is_playing) {
            continue;
        }
        
        CardinalAnimation *animation = &system->animations[state->animation_index];
        
        // Update time
        state->current_time += delta_time * state->playback_speed;
        
        // Handle looping
        if (state->current_time >= animation->duration) {
            if (state->is_looping) {
                state->current_time = fmodf(state->current_time, animation->duration);
            } else {
                state->current_time = animation->duration;
                state->is_playing = false;
            }
        }
        
        // Apply animation to scene nodes (this would need scene node access)
        // For now, just log the update
        CARDINAL_LOG_TRACE("Animation %u time: %.3f/%.3f", 
                          state->animation_index, state->current_time, animation->duration);
    }
}

bool cardinal_skin_update_bone_matrices(const CardinalSkin *skin, const struct CardinalSceneNode **scene_nodes, float *bone_matrices) {
    if (!skin || !scene_nodes || !bone_matrices) {
        return false;
    }

    for (uint32_t i = 0; i < skin->bone_count; ++i) {
        const CardinalBone *bone = &skin->bones[i];
        const struct CardinalSceneNode *node = scene_nodes[bone->node_index];
        
        if (!node) {
            continue;
        }
        
        // Get world transform of the bone node
        const float *world_transform = cardinal_scene_node_get_world_transform((struct CardinalSceneNode*)node);
        
        // Multiply world transform by inverse bind matrix
        float *bone_matrix = &bone_matrices[i * 16];
        cardinal_matrix_multiply(world_transform, bone->inverse_bind_matrix, bone_matrix);
    }
    
    return true;
}

void cardinal_skin_destroy(CardinalSkin *skin) {
    if (!skin) {
        return;
    }
    
    // Free skin name
    free(skin->name);
    
    // Free bones array
    if (skin->bones) {
        for (uint32_t i = 0; i < skin->bone_count; ++i) {
            free(skin->bones[i].name);
        }
        free(skin->bones);
    }
    
    // Free mesh indices
    free(skin->mesh_indices);
    
    // Clear the skin structure
    memset(skin, 0, sizeof(CardinalSkin));
}