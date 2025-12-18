#ifndef CARDINAL_ENGINE_H
#define CARDINAL_ENGINE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Forward Declarations
// ============================================================================
struct GLFWwindow;

// ============================================================================
// Core: Log
// ============================================================================
typedef enum {
    CARDINAL_LOG_LEVEL_TRACE = 0,
    CARDINAL_LOG_LEVEL_DEBUG = 1,
    CARDINAL_LOG_LEVEL_INFO = 2,
    CARDINAL_LOG_LEVEL_WARN = 3,
    CARDINAL_LOG_LEVEL_ERROR = 4,
    CARDINAL_LOG_LEVEL_FATAL = 5
} CardinalLogLevel;

void cardinal_log_init(void);
void cardinal_log_init_with_level(CardinalLogLevel min_level);
void cardinal_log_set_level(CardinalLogLevel min_level);
CardinalLogLevel cardinal_log_get_level(void);
void cardinal_log_shutdown(void);
void cardinal_log_output_v(CardinalLogLevel level, const char *file, int line, const char *fmt, va_list args);

static inline void cardinal_log_output(CardinalLogLevel level, const char *file, int line, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    cardinal_log_output_v(level, file, line, fmt, args);
    va_end(args);
}

#ifdef __clang__
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu-zero-variadic-macro-arguments"
#endif

#ifdef _DEBUG
#define CARDINAL_LOG_TRACE(fmt, ...) cardinal_log_output(CARDINAL_LOG_LEVEL_TRACE, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
#define CARDINAL_LOG_DEBUG(fmt, ...) cardinal_log_output(CARDINAL_LOG_LEVEL_DEBUG, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
#define CARDINAL_LOG_INFO(fmt, ...)  cardinal_log_output(CARDINAL_LOG_LEVEL_INFO, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
#define CARDINAL_LOG_WARN(fmt, ...)  cardinal_log_output(CARDINAL_LOG_LEVEL_WARN, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
#define CARDINAL_LOG_ERROR(fmt, ...) cardinal_log_output(CARDINAL_LOG_LEVEL_ERROR, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
#define CARDINAL_LOG_FATAL(fmt, ...) cardinal_log_output(CARDINAL_LOG_LEVEL_FATAL, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
#else
#define CARDINAL_LOG_TRACE(fmt, ...) ((void)0)
#define CARDINAL_LOG_DEBUG(fmt, ...) ((void)0)
#define CARDINAL_LOG_INFO(fmt, ...)  ((void)0)
#define CARDINAL_LOG_WARN(fmt, ...)  cardinal_log_output(CARDINAL_LOG_LEVEL_WARN, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
#define CARDINAL_LOG_ERROR(fmt, ...) cardinal_log_output(CARDINAL_LOG_LEVEL_ERROR, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
#define CARDINAL_LOG_FATAL(fmt, ...) cardinal_log_output(CARDINAL_LOG_LEVEL_FATAL, __FILE__, __LINE__, fmt, ##__VA_ARGS__)
#endif

#ifdef __clang__
#pragma clang diagnostic pop
#endif

// ============================================================================
// Core: Transform
// ============================================================================
void cardinal_matrix_identity(float *matrix);
void cardinal_matrix_multiply(const float *a, const float *b, float *result);
void cardinal_matrix_from_trs(const float *translation, const float *rotation, const float *scale, float *matrix);
bool cardinal_matrix_decompose(const float *matrix, float *translation, float *rotation, float *scale);
bool cardinal_matrix_invert(const float *matrix, float *result);
void cardinal_matrix_transpose(const float *matrix, float *result);
void cardinal_transform_point(const float *matrix, const float *point, float *result);
void cardinal_transform_vector(const float *matrix, const float *vector, float *result);

// ============================================================================
// Core: Window
// ============================================================================
typedef struct CardinalWindowConfig {
    const char *title;
    uint32_t width;
    uint32_t height;
    bool resizable;
} CardinalWindowConfig;

typedef struct CardinalWindow {
    struct GLFWwindow *handle;
    uint32_t width;
    uint32_t height;
    bool should_close;
#ifdef _WIN32
    void* mutex; // CRITICAL_SECTION is opaque here
#else
    void* mutex; // pthread_mutex_t opaque
#endif
    bool resize_pending;
    uint32_t new_width;
    uint32_t new_height;
    bool is_minimized;
    bool was_minimized;
    void (*resize_callback)(uint32_t width, uint32_t height, void *user_data);
    void *resize_user_data;
} CardinalWindow;

CardinalWindow *cardinal_window_create(const CardinalWindowConfig *config);
void cardinal_window_poll(CardinalWindow *window);
void cardinal_window_destroy(CardinalWindow *window);
void *cardinal_window_get_native_handle(CardinalWindow *window);

// ============================================================================
// Assets: Scene
// ============================================================================
typedef struct CardinalVertex {
    float px, py, pz;
    float nx, ny, nz;
    float u, v;
    float bone_weights[4];
    uint32_t bone_indices[4];
} CardinalVertex;

typedef struct CardinalTextureTransform {
    float offset[2];
    float scale[2];
    float rotation;
} CardinalTextureTransform;

typedef enum CardinalSamplerWrap {
    CARDINAL_SAMPLER_WRAP_REPEAT = 0,
    CARDINAL_SAMPLER_WRAP_CLAMP_TO_EDGE = 1,
    CARDINAL_SAMPLER_WRAP_MIRRORED_REPEAT = 2
} CardinalSamplerWrap;

typedef enum CardinalSamplerFilter {
    CARDINAL_SAMPLER_FILTER_NEAREST = 0,
    CARDINAL_SAMPLER_FILTER_LINEAR = 1
} CardinalSamplerFilter;

typedef struct CardinalSampler {
    CardinalSamplerWrap wrap_s;
    CardinalSamplerWrap wrap_t;
    CardinalSamplerFilter min_filter;
    CardinalSamplerFilter mag_filter;
} CardinalSampler;

typedef enum CardinalAlphaMode {
    CARDINAL_ALPHA_MODE_OPAQUE = 0,
    CARDINAL_ALPHA_MODE_MASK = 1,
    CARDINAL_ALPHA_MODE_BLEND = 2
} CardinalAlphaMode;

typedef struct CardinalTexture {
    void *data; // Opaque or mapped
    uint32_t width;
    uint32_t height;
    uint32_t channels;
    CardinalSampler sampler;
    // ... potentially more fields
} CardinalTexture;

typedef struct CardinalMaterial {
    uint32_t albedo_texture;
    uint32_t normal_texture;
    uint32_t metallic_roughness_texture;
    uint32_t ao_texture;
    uint32_t emissive_texture;

    float albedo_factor[3];
    float metallic_factor;
    float roughness_factor;
    float emissive_factor[3];
    float normal_scale;
    float ao_strength;

    CardinalAlphaMode alpha_mode;
    float alpha_cutoff;
    bool double_sided;

    CardinalTextureTransform albedo_transform;
    CardinalTextureTransform normal_transform;
    CardinalTextureTransform metallic_roughness_transform;
    CardinalTextureTransform ao_transform;
    CardinalTextureTransform emissive_transform;

    void *ref_resource;
} CardinalMaterial;

typedef struct CardinalMesh {
    CardinalVertex *vertices;
    uint32_t vertex_count;
    uint32_t *indices;
    uint32_t index_count;
    uint32_t material_index;
    bool visible;
} CardinalMesh;

typedef struct CardinalSceneNode {
    char *name;
    float local_transform[16];
    float world_transform[16];
    bool world_transform_dirty;
    
    uint32_t *mesh_indices;
    uint32_t mesh_count;
    
    struct CardinalSceneNode *parent;
    struct CardinalSceneNode **children;
    uint32_t child_count;
    uint32_t child_capacity;
    
    bool is_bone;
    uint32_t bone_index;
    uint32_t skin_index;
} CardinalSceneNode;

// ============================================================================
// Core: Animation
// ============================================================================
typedef enum CardinalAnimationInterpolation {
  CARDINAL_ANIMATION_INTERPOLATION_LINEAR,
  CARDINAL_ANIMATION_INTERPOLATION_STEP,
  CARDINAL_ANIMATION_INTERPOLATION_CUBICSPLINE
} CardinalAnimationInterpolation;

typedef enum CardinalAnimationTargetPath {
  CARDINAL_ANIMATION_TARGET_TRANSLATION,
  CARDINAL_ANIMATION_TARGET_ROTATION,
  CARDINAL_ANIMATION_TARGET_SCALE,
  CARDINAL_ANIMATION_TARGET_WEIGHTS
} CardinalAnimationTargetPath;

typedef struct CardinalAnimationSampler {
  float *input;
  float *output;
  uint32_t input_count;
  uint32_t output_count;
  CardinalAnimationInterpolation interpolation;
} CardinalAnimationSampler;

typedef struct CardinalAnimationTarget {
  uint32_t node_index;
  CardinalAnimationTargetPath path;
} CardinalAnimationTarget;

typedef struct CardinalAnimationChannel {
  uint32_t sampler_index;
  CardinalAnimationTarget target;
} CardinalAnimationChannel;

typedef struct CardinalAnimation {
  char *name;
  CardinalAnimationSampler *samplers;
  uint32_t sampler_count;
  CardinalAnimationChannel *channels;
  uint32_t channel_count;
  float duration;
} CardinalAnimation;

typedef struct CardinalBone {
  char *name;
  uint32_t node_index;
  float inverse_bind_matrix[16];
  float current_matrix[16];
  uint32_t parent_index;
} CardinalBone;

typedef struct CardinalSkin {
  char *name;
  CardinalBone *bones;
  uint32_t bone_count;
  uint32_t *mesh_indices;
  uint32_t mesh_count;
  uint32_t root_bone_index;
} CardinalSkin;

typedef struct CardinalAnimationState {
  uint32_t animation_index;
  float current_time;
  float playback_speed;
  bool is_playing;
  bool is_looping;
  float blend_weight;
} CardinalAnimationState;

typedef struct CardinalAnimationSystem {
  CardinalAnimation *animations;
  uint32_t animation_count;
  CardinalSkin *skins;
  uint32_t skin_count;
  CardinalAnimationState *states;
  uint32_t state_count;
  float *bone_matrices;
  uint32_t bone_matrix_count;
} CardinalAnimationSystem;

CardinalAnimationSystem *cardinal_animation_system_create(uint32_t max_animations, uint32_t max_skins);
void cardinal_animation_system_destroy(CardinalAnimationSystem *system);
bool cardinal_animation_play(CardinalAnimationSystem *system, uint32_t animation_index, bool loop, float blend_weight);
bool cardinal_animation_pause(CardinalAnimationSystem *system, uint32_t animation_index);
bool cardinal_animation_stop(CardinalAnimationSystem *system, uint32_t animation_index);
bool cardinal_animation_set_speed(CardinalAnimationSystem *system, uint32_t animation_index, float speed);
void cardinal_animation_system_update(CardinalAnimationSystem *system, CardinalSceneNode **all_nodes, uint32_t all_node_count, float delta_time);

typedef struct CardinalScene {
    CardinalMesh *meshes;
    uint32_t mesh_count;
    CardinalMaterial *materials;
    uint32_t material_count;
    CardinalTexture *textures;
    uint32_t texture_count;
    
    CardinalSceneNode **root_nodes;
    uint32_t root_node_count;
    
    CardinalSceneNode **all_nodes;
    uint32_t all_node_count;
    
    CardinalAnimationSystem *animation_system;
    CardinalSkin *skins;
    uint32_t skin_count;
} CardinalScene;

// ============================================================================
// Core: Async Loader
// ============================================================================
typedef enum {
    CARDINAL_ASYNC_PRIORITY_LOW = 0,
    CARDINAL_ASYNC_PRIORITY_NORMAL = 1,
    CARDINAL_ASYNC_PRIORITY_HIGH = 2,
    CARDINAL_ASYNC_PRIORITY_CRITICAL = 3
} CardinalAsyncPriority;

typedef enum {
    CARDINAL_ASYNC_STATUS_PENDING = 0,
    CARDINAL_ASYNC_STATUS_RUNNING = 1,
    CARDINAL_ASYNC_STATUS_COMPLETED = 2,
    CARDINAL_ASYNC_STATUS_FAILED = 3,
    CARDINAL_ASYNC_STATUS_CANCELLED = 4
} CardinalAsyncStatus;

typedef struct CardinalAsyncTask CardinalAsyncTask;
typedef void (*CardinalAsyncCallback)(CardinalAsyncTask *task, void *user_data);

bool cardinal_async_loader_is_initialized(void);
CardinalAsyncStatus cardinal_async_get_task_status(CardinalAsyncTask *task);
const char *cardinal_async_get_error_message(CardinalAsyncTask *task);
bool cardinal_async_get_scene_result(CardinalAsyncTask *task, CardinalScene *out_scene);
void cardinal_async_free_task(CardinalAsyncTask *task);
void cardinal_async_cancel_task(CardinalAsyncTask *task);
uint32_t cardinal_async_process_completed_tasks(uint32_t max_tasks);

// ============================================================================
// Assets: Loader
// ============================================================================
void cardinal_scene_destroy(CardinalScene *scene);
bool cardinal_scene_load(const char *filepath, CardinalScene *out_scene);
CardinalAsyncTask *cardinal_scene_load_async(const char *filepath, CardinalAsyncPriority priority, CardinalAsyncCallback callback, void *user_data);

// ============================================================================
// Assets: Model Manager
// ============================================================================
typedef struct CardinalModelInstance {
    char *name;
    char *file_path;
    CardinalScene scene;
    float transform[16];
    bool visible;
    bool selected;
    uint32_t id;
    float bbox_min[3];
    float bbox_max[3];
    bool is_loading;
    CardinalAsyncTask *load_task;
} CardinalModelInstance;

typedef struct CardinalModelManager {
    CardinalModelInstance *models;
    uint32_t model_count;
    uint32_t model_capacity;
    uint32_t next_id;
    CardinalScene combined_scene;
    bool scene_dirty;
    uint32_t selected_model_id;
} CardinalModelManager;

bool cardinal_model_manager_init(CardinalModelManager *manager);
void cardinal_model_manager_destroy(CardinalModelManager *manager);
uint32_t cardinal_model_manager_add_scene(CardinalModelManager *manager, const CardinalScene *scene, const char *path, const char *name);
const CardinalScene *cardinal_model_manager_get_combined_scene(CardinalModelManager *manager);
CardinalModelInstance *cardinal_model_manager_get_model_by_index(CardinalModelManager *manager, uint32_t index);
void cardinal_model_manager_set_selected(CardinalModelManager *manager, uint32_t model_id);
void cardinal_model_manager_set_visible(CardinalModelManager *manager, uint32_t model_id, bool visible);
void cardinal_model_manager_remove_model(CardinalModelManager *manager, uint32_t model_id);
void cardinal_model_manager_set_transform(CardinalModelManager *manager, uint32_t model_id, const float *transform);
void cardinal_model_manager_update(CardinalModelManager *manager);
uint32_t cardinal_model_manager_get_total_mesh_count(const CardinalModelManager *manager);

// ============================================================================
// Renderer: Renderer
// ============================================================================
typedef struct CardinalCamera {
    float position[3];
    float target[3];
    float up[3];
    float fov;
    float aspect;
    float near_plane;
    float far_plane;
} CardinalCamera;

typedef struct CardinalLight {
    float direction[3];
    float color[3];
    float intensity;
    float ambient[3];
} CardinalLight;

typedef enum CardinalRenderingMode {
    CARDINAL_RENDERING_MODE_NORMAL = 0,
    CARDINAL_RENDERING_MODE_UV = 1,
    CARDINAL_RENDERING_MODE_WIREFRAME = 2,
    CARDINAL_RENDERING_MODE_MESH_SHADER = 3
} CardinalRenderingMode;

typedef struct CardinalRenderer {
    void *_opaque;
} CardinalRenderer;

bool cardinal_renderer_create(CardinalRenderer *out_renderer, CardinalWindow *window);
bool cardinal_renderer_create_headless(CardinalRenderer *out_renderer, uint32_t width, uint32_t height);
void cardinal_renderer_draw_frame(CardinalRenderer *renderer);
void cardinal_renderer_wait_idle(CardinalRenderer *renderer);
void cardinal_renderer_destroy(CardinalRenderer *renderer);
void cardinal_renderer_set_camera(CardinalRenderer *renderer, const CardinalCamera *camera);
void cardinal_renderer_set_lighting(CardinalRenderer *renderer, const CardinalLight *light);
void cardinal_renderer_enable_pbr(CardinalRenderer *renderer, bool enable);
bool cardinal_renderer_is_pbr_enabled(CardinalRenderer *renderer);
void cardinal_renderer_enable_mesh_shader(CardinalRenderer *renderer, bool enable);
bool cardinal_renderer_is_mesh_shader_enabled(CardinalRenderer *renderer);
bool cardinal_renderer_supports_mesh_shader(CardinalRenderer *renderer);
void cardinal_renderer_set_rendering_mode(CardinalRenderer *renderer, CardinalRenderingMode mode);
CardinalRenderingMode cardinal_renderer_get_rendering_mode(CardinalRenderer *renderer);

// ============================================================================
// Renderer: Internal
// ============================================================================
VkCommandBuffer cardinal_renderer_internal_current_cmd(CardinalRenderer *renderer, uint32_t image_index);
VkDevice cardinal_renderer_internal_device(CardinalRenderer *renderer);
VkPhysicalDevice cardinal_renderer_internal_physical_device(CardinalRenderer *renderer);
VkQueue cardinal_renderer_internal_graphics_queue(CardinalRenderer *renderer);
uint32_t cardinal_renderer_internal_graphics_queue_family(CardinalRenderer *renderer);
VkInstance cardinal_renderer_internal_instance(CardinalRenderer *renderer);
uint32_t cardinal_renderer_internal_swapchain_image_count(CardinalRenderer *renderer);
VkFormat cardinal_renderer_internal_swapchain_format(CardinalRenderer *renderer);
VkFormat cardinal_renderer_internal_depth_format(CardinalRenderer *renderer);
VkExtent2D cardinal_renderer_internal_swapchain_extent(CardinalRenderer *renderer);

void cardinal_renderer_set_ui_callback(CardinalRenderer *renderer, void (*callback)(VkCommandBuffer cmd));
void cardinal_renderer_immediate_submit(CardinalRenderer *renderer, void (*record)(VkCommandBuffer cmd));
void cardinal_renderer_immediate_submit_with_secondary(CardinalRenderer *renderer, void (*record)(VkCommandBuffer cmd), bool use_secondary);
void cardinal_renderer_upload_scene(CardinalRenderer *renderer, const CardinalScene *scene);
void cardinal_renderer_clear_scene(CardinalRenderer *renderer);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_ENGINE_H
