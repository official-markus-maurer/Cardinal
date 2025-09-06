#version 450

// Vertex input attributes
layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inTexCoord;

// Uniform buffer for camera and transform data
layout(binding = 0) uniform UniformBufferObject {
    mat4 model;
    mat4 view;
    mat4 proj;
    vec3 viewPos;
} ubo;

// Texture transform structure (same as PBR pipeline)
struct TextureTransform {
    vec2 offset;
    vec2 scale;
    float rotation;
};

// Material structure for UV visualization (simplified from PBR)
struct Material {
    vec3 albedoFactor;
    float metallicFactor;
    vec3 emissiveFactor;
    float roughnessFactor;
    float normalScale;
    float aoStrength;
    uint albedoTextureIndex;
    uint normalTextureIndex;
    uint metallicRoughnessTextureIndex;
    uint aoTextureIndex;
    uint emissiveTextureIndex;
    uint supportsDescriptorIndexing;
    uint hasSkeleton;
    uint _padding0;
    TextureTransform albedoTransform;
    float _padding1;
    TextureTransform normalTransform;
    float _padding2;
    TextureTransform metallicRoughnessTransform;
    float _padding3;
    TextureTransform aoTransform;
    float _padding4;
    TextureTransform emissiveTransform;
};

// Push constants for per-mesh data (matching PBRPushConstants)
layout(push_constant) uniform PushConstants {
    mat4 modelMatrix;
    Material material;
} pushConstants;

// Output to fragment shader
layout(location = 0) out vec2 fragTexCoord;

void main() {
    // Transform position to world space using push constant model matrix
    vec4 worldPos = pushConstants.modelMatrix * vec4(inPosition, 1.0);
    
    // Pass through texture coordinates for UV visualization
    fragTexCoord = inTexCoord;
    
    // Final position in clip space
    gl_Position = ubo.proj * ubo.view * worldPos;
}