/**
 * @file animation.h
 * @brief Animation system for Cardinal Engine
 *
 * This module provides comprehensive animation support including skeletal animation,
 * keyframe interpolation, and skin deformation. It supports glTF animation
 * specifications with channels, samplers, and animation clips.
 *
 * Key features:
 * - Skeletal animation with bone hierarchies
 * - Keyframe interpolation (linear, step, cubic spline)
 * - Animation blending and mixing
 * - Skin deformation with bone weights
 * - Animation playback control (play, pause, loop)
 *
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef CARDINAL_CORE_ANIMATION_H
#define CARDINAL_CORE_ANIMATION_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Animation interpolation types
 *
 * Defines the interpolation methods used for keyframe animation.
 * These correspond to glTF animation sampler interpolation modes.
 */
typedef enum CardinalAnimationInterpolation {
    CARDINAL_ANIMATION_INTERPOLATION_LINEAR,      /**< Linear interpolation between keyframes */
    CARDINAL_ANIMATION_INTERPOLATION_STEP,        /**< Step interpolation (no interpolation) */
    CARDINAL_ANIMATION_INTERPOLATION_CUBICSPLINE  /**< Cubic spline interpolation */
} CardinalAnimationInterpolation;

/**
 * @brief Animation target property types
 *
 * Defines which property of a scene node is being animated.
 * These correspond to glTF animation channel target paths.
 */
typedef enum CardinalAnimationTargetPath {
    CARDINAL_ANIMATION_TARGET_TRANSLATION,  /**< Node translation (position) */
    CARDINAL_ANIMATION_TARGET_ROTATION,     /**< Node rotation (quaternion) */
    CARDINAL_ANIMATION_TARGET_SCALE,        /**< Node scale */
    CARDINAL_ANIMATION_TARGET_WEIGHTS       /**< Morph target weights */
} CardinalAnimationTargetPath;

/**
 * @brief Animation sampler data
 *
 * Contains keyframe timing and value data for animation interpolation.
 * Each sampler defines how to interpolate between keyframes for a specific property.
 */
typedef struct CardinalAnimationSampler {
    float *input;                              /**< Array of keyframe times */
    float *output;                             /**< Array of keyframe values */
    uint32_t input_count;                      /**< Number of input keyframes */
    uint32_t output_count;                     /**< Number of output values */
    CardinalAnimationInterpolation interpolation; /**< Interpolation method */
} CardinalAnimationSampler;

/**
 * @brief Animation channel target
 *
 * Defines which scene node and property is being animated by a channel.
 */
typedef struct CardinalAnimationTarget {
    uint32_t node_index;                    /**< Index of target scene node */
    CardinalAnimationTargetPath path;       /**< Property being animated */
} CardinalAnimationTarget;

/**
 * @brief Animation channel
 *
 * Links an animation sampler to a specific target node and property.
 * Each channel animates one property of one node.
 */
typedef struct CardinalAnimationChannel {
    uint32_t sampler_index;                 /**< Index into animation's samplers array */
    CardinalAnimationTarget target;         /**< Target node and property */
} CardinalAnimationChannel;

/**
 * @brief Animation clip
 *
 * Contains all channels and samplers for a complete animation sequence.
 * Represents a single animation that can be played, paused, or looped.
 */
typedef struct CardinalAnimation {
    char *name;                             /**< Animation name (optional) */
    CardinalAnimationSampler *samplers;     /**< Array of animation samplers */
    uint32_t sampler_count;                 /**< Number of samplers */
    CardinalAnimationChannel *channels;     /**< Array of animation channels */
    uint32_t channel_count;                 /**< Number of channels */
    float duration;                         /**< Total animation duration in seconds */
} CardinalAnimation;

/**
 * @brief Bone/Joint data for skeletal animation
 *
 * Represents a single bone in a skeletal hierarchy with its bind pose
 * and current transformation matrices.
 */
typedef struct CardinalBone {
    char *name;                             /**< Bone name (optional) */
    uint32_t node_index;                    /**< Index of associated scene node */
    float inverse_bind_matrix[16];          /**< Inverse bind pose matrix */
    float current_matrix[16];               /**< Current transformation matrix */
    uint32_t parent_index;                  /**< Index of parent bone (UINT32_MAX for root) */
} CardinalBone;

/**
 * @brief Skin data for mesh deformation
 *
 * Contains the bone hierarchy and bind pose information needed
 * to deform a mesh based on skeletal animation.
 */
typedef struct CardinalSkin {
    char *name;                             /**< Skin name (optional) */
    CardinalBone *bones;                    /**< Array of bones in the skeleton */
    uint32_t bone_count;                    /**< Number of bones */
    uint32_t *mesh_indices;                 /**< Array of mesh indices using this skin */
    uint32_t mesh_count;                    /**< Number of meshes using this skin */
    uint32_t root_bone_index;               /**< Index of root bone */
} CardinalSkin;

/**
 * @brief Animation playback state
 *
 * Tracks the current state of an animation during playback,
 * including timing, looping, and blending information.
 */
typedef struct CardinalAnimationState {
    uint32_t animation_index;               /**< Index of animation being played */
    float current_time;                     /**< Current playback time */
    float playback_speed;                   /**< Playback speed multiplier */
    bool is_playing;                        /**< Whether animation is currently playing */
    bool is_looping;                        /**< Whether animation should loop */
    float blend_weight;                     /**< Blending weight for animation mixing */
} CardinalAnimationState;

/**
 * @brief Animation system context
 *
 * Contains all animation data and state for a scene, including
 * animations, skins, and playback states.
 */
typedef struct CardinalAnimationSystem {
    CardinalAnimation *animations;          /**< Array of animation clips */
    uint32_t animation_count;               /**< Number of animations */
    CardinalSkin *skins;                    /**< Array of skins */
    uint32_t skin_count;                    /**< Number of skins */
    CardinalAnimationState *states;         /**< Array of animation playback states */
    uint32_t state_count;                   /**< Number of active animation states */
    float *bone_matrices;                   /**< Flattened array of bone matrices for GPU */
    uint32_t bone_matrix_count;             /**< Number of bone matrices */
} CardinalAnimationSystem;

// Animation system management

/**
 * @brief Create a new animation system
 *
 * Allocates and initializes a new animation system with the specified
 * capacity for animations and skins.
 *
 * @param max_animations Maximum number of animations to support
 * @param max_skins Maximum number of skins to support
 * @return Pointer to new animation system, or NULL on failure
 */
CardinalAnimationSystem *cardinal_animation_system_create(uint32_t max_animations, uint32_t max_skins);

/**
 * @brief Destroy an animation system
 *
 * Frees all memory associated with an animation system, including
 * all animations, skins, and playback states.
 *
 * @param system Animation system to destroy
 */
void cardinal_animation_system_destroy(CardinalAnimationSystem *system);

/**
 * @brief Update animation system
 *
 * Updates all active animations by the specified delta time,
 * interpolating keyframes and updating bone matrices.
 *
 * @param system Animation system to update
 * @param delta_time Time elapsed since last update (in seconds)
 */
void cardinal_animation_system_update(CardinalAnimationSystem *system, float delta_time);

// Animation management

/**
 * @brief Add an animation to the system
 *
 * Adds a new animation clip to the animation system.
 *
 * @param system Animation system
 * @param animation Animation to add
 * @return Index of added animation, or UINT32_MAX on failure
 */
uint32_t cardinal_animation_system_add_animation(CardinalAnimationSystem *system, const CardinalAnimation *animation);

/**
 * @brief Add a skin to the system
 *
 * Adds a new skin to the animation system.
 *
 * @param system Animation system
 * @param skin Skin to add
 * @return Index of added skin, or UINT32_MAX on failure
 */
uint32_t cardinal_animation_system_add_skin(CardinalAnimationSystem *system, const CardinalSkin *skin);

// Animation playback control

/**
 * @brief Play an animation
 *
 * Starts playback of the specified animation with optional looping.
 *
 * @param system Animation system
 * @param animation_index Index of animation to play
 * @param loop Whether the animation should loop
 * @param blend_weight Blending weight for animation mixing
 * @return true on success, false on failure
 */
bool cardinal_animation_play(CardinalAnimationSystem *system, uint32_t animation_index, bool loop, float blend_weight);

/**
 * @brief Pause an animation
 *
 * Pauses playback of the specified animation.
 *
 * @param system Animation system
 * @param animation_index Index of animation to pause
 * @return true on success, false on failure
 */
bool cardinal_animation_pause(CardinalAnimationSystem *system, uint32_t animation_index);

/**
 * @brief Stop an animation
 *
 * Stops playback of the specified animation and resets its time to 0.
 *
 * @param system Animation system
 * @param animation_index Index of animation to stop
 * @return true on success, false on failure
 */
bool cardinal_animation_stop(CardinalAnimationSystem *system, uint32_t animation_index);

/**
 * @brief Set animation playback speed
 *
 * Sets the playback speed multiplier for the specified animation.
 *
 * @param system Animation system
 * @param animation_index Index of animation
 * @param speed Playback speed multiplier (1.0 = normal speed)
 * @return true on success, false on failure
 */
bool cardinal_animation_set_speed(CardinalAnimationSystem *system, uint32_t animation_index, float speed);

// Utility functions

/**
 * @brief Interpolate between keyframes
 *
 * Performs interpolation between keyframes based on the specified method.
 *
 * @param interpolation Interpolation method
 * @param time Current time
 * @param input Array of keyframe times
 * @param output Array of keyframe values
 * @param input_count Number of keyframes
 * @param component_count Number of components per value (e.g., 3 for translation, 4 for rotation)
 * @param result Output interpolated value
 * @return true on success, false on failure
 */
bool cardinal_animation_interpolate(CardinalAnimationInterpolation interpolation, float time,
                                   const float *input, const float *output,
                                   uint32_t input_count, uint32_t component_count,
                                   float *result);

/**
 * @brief Update bone matrices for a skin
 *
 * Computes the final bone transformation matrices for a skin based on
 * the current scene node transforms and inverse bind matrices.
 *
 * @param skin Skin to update
 * @param scene_nodes Array of scene nodes
 * @param bone_matrices Output array for bone matrices
 * @return true on success, false on failure
 */
bool cardinal_skin_update_bone_matrices(const CardinalSkin *skin, const struct CardinalSceneNode **scene_nodes, float *bone_matrices);

/**
 * @brief Destroy a skin and free its resources
 * @param skin The skin to destroy
 */
void cardinal_skin_destroy(CardinalSkin *skin);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_CORE_ANIMATION_H