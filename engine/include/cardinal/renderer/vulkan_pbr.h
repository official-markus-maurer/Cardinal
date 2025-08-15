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
