/**
 * @file vulkan_pbr.h
 * @brief Physically Based Rendering (PBR) pipeline for Cardinal Engine
 * 
 * This module implements a complete PBR rendering pipeline using Vulkan,
 * supporting modern material workflows with metallic-roughness shading.
 * The pipeline handles complex material properties, multiple texture types,
 * and advanced lighting calculations.
 * 
 * Key features:
 * - Metallic-roughness PBR workflow
 * - Multiple texture support (albedo, normal, metallic-roughness, AO, emissive)
 * - Texture coordinate transformations (KHR_texture_transform)
 * - Descriptor indexing for efficient texture binding
 * - Push constants for per-mesh material properties
 * - Uniform buffers for scene-wide data
 * - Optimized vertex and index buffer management
 * 
 * The pipeline supports both traditional descriptor sets and modern
 * descriptor indexing for improved performance with many textures.
 * 
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef CARDINAL_RENDERER_VULKAN_PBR_H
#define CARDINAL_RENDERER_VULKAN_PBR_H

#include <vulkan/vulkan.h>
#include <cardinal/assets/scene.h>
#include <stdbool.h>

// Forward declaration of VulkanAllocator
typedef struct VulkanAllocator VulkanAllocator;

#ifdef __cplusplus
extern "C" {
#endif

// Uniform buffer structures matching shader layouts
typedef struct PBRUniformBufferObject {
    float model[16];     // mat4
    float view[16];      // mat4
    float proj[16];      // mat4
    float viewPos[3];    // vec3
    float _padding1;     // Alignment
} PBRUniformBufferObject;

// Texture transform structure matching shader layout
typedef struct PBRTextureTransform {
    float offset[2];  // vec2
    float scale[2];   // vec2
    float rotation;   // float
} PBRTextureTransform;

// Push constant structure for per-mesh data (model matrix + material properties)
typedef struct PBRPushConstants {
    float modelMatrix[16];  // 4x4 model matrix (64 bytes)
    float albedoFactor[3];  // Material albedo factor (12 bytes)
    float metallicFactor;   // Material metallic factor (4 bytes)
    float emissiveFactor[3]; // Material emissive factor (12 bytes)
    float roughnessFactor;  // Material roughness factor (4 bytes)
    float normalScale;      // Normal map scale (4 bytes)
    float aoStrength;       // AO strength (4 bytes)
    uint32_t albedoTextureIndex;
    uint32_t normalTextureIndex;
    uint32_t metallicRoughnessTextureIndex;
    uint32_t aoTextureIndex;
    uint32_t emissiveTextureIndex;
    uint32_t supportsDescriptorIndexing;
    // Texture transforms matching shader Material structure layout
    PBRTextureTransform albedoTransform;
    float _padding1;
    PBRTextureTransform normalTransform;
    float _padding2;
    PBRTextureTransform metallicRoughnessTransform;
    float _padding3;
    PBRTextureTransform aoTransform;
    float _padding4;
    PBRTextureTransform emissiveTransform;
} PBRPushConstants;

// Legacy material properties structure (kept for compatibility)
typedef struct PBRMaterialProperties {
    float albedoFactor[3];
    float metallicFactor;
    float roughnessFactor;
    float emissiveFactor[3];
    float normalScale;
    float aoStrength;
    
    // Texture indices for material-specific textures when using descriptor indexing
    uint32_t albedoTextureIndex;
    uint32_t normalTextureIndex;
    uint32_t metallicRoughnessTextureIndex;
    uint32_t aoTextureIndex;
    uint32_t emissiveTextureIndex;
    uint32_t supportsDescriptorIndexing;  // 1 if supported, 0 if not
    float _padding[2];   // Alignment to 16 bytes
} PBRMaterialProperties;

typedef struct PBRLightingData {
    float lightDirection[3];
    float _padding1;
    float lightColor[3];
    float lightIntensity;
    float ambientColor[3];
    float _padding2;
} PBRLightingData;

// PBR pipeline state
typedef struct VulkanPBRPipeline {
    VkPipeline pipeline;
    VkPipelineLayout pipelineLayout;
    VkDescriptorSetLayout descriptorSetLayout;
    VkDescriptorPool descriptorPool;
    
    // Uniform buffers
    VkBuffer uniformBuffer;
    VkDeviceMemory uniformBufferMemory;
    void* uniformBufferMapped;
    
    VkBuffer materialBuffer;
    VkDeviceMemory materialBufferMemory;
    void* materialBufferMapped;
    
    VkBuffer lightingBuffer;
    VkDeviceMemory lightingBufferMemory;
    void* lightingBufferMapped;
    
    // Descriptor sets (one per material)
    VkDescriptorSet* descriptorSets;
    uint32_t descriptorSetCount;
    
    // Texture resources
    VkImage* textureImages;
    VkDeviceMemory* textureImageMemories;
    VkImageView* textureImageViews;
    VkSampler textureSampler;
    uint32_t textureCount;
    
    // Vertex buffer for scene
    VkBuffer vertexBuffer;
    VkDeviceMemory vertexBufferMemory;
    VkBuffer indexBuffer;
    VkDeviceMemory indexBufferMemory;
    
    // Feature support flags
    bool supportsDescriptorIndexing;
    
    bool initialized;
} VulkanPBRPipeline;

// Function declarations
bool vk_pbr_pipeline_create(VulkanPBRPipeline* pipeline, VkDevice device, VkPhysicalDevice physicalDevice, 
                            VkFormat swapchainFormat, VkFormat depthFormat,
                            VkCommandPool commandPool, VkQueue graphicsQueue, VulkanAllocator* allocator);

void vk_pbr_pipeline_destroy(VulkanPBRPipeline* pipeline, VkDevice device, VulkanAllocator* allocator);

bool vk_pbr_load_scene(VulkanPBRPipeline* pipeline, VkDevice device, VkPhysicalDevice physicalDevice,
                       VkCommandPool commandPool, VkQueue graphicsQueue, const CardinalScene* scene, VulkanAllocator* allocator);

void vk_pbr_update_uniforms(VulkanPBRPipeline* pipeline, const PBRUniformBufferObject* ubo,
                            const PBRLightingData* lighting);

void vk_pbr_render(VulkanPBRPipeline* pipeline, VkCommandBuffer commandBuffer, const CardinalScene* scene);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_RENDERER_VULKAN_PBR_H
