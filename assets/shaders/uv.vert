#version 450

// Vertex input attributes
layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inTexCoord;
layout(location = 3) in vec4 inBoneWeights;
layout(location = 4) in uvec4 inBoneIndices;
layout(location = 5) in vec2 inTexCoord1;
layout(location = 6) in vec4 inColor;

// Uniform buffer for camera and transform data
layout(binding = 0) uniform UniformBufferObject {
    mat4 model;
    mat4 view;
    mat4 proj;
    vec3 viewPos;
} ubo;

// Material structure
struct Material {
    vec4 albedo;
    vec4 emissiveAndRoughness;
    vec4 metallicNormalAO; // x=metallic, y=normalScale, z=aoStrength, w=alphaCutoff
    uint albedoTextureIndex;
    uint normalTextureIndex;
    uint metallicRoughnessTextureIndex;
    uint aoTextureIndex;
    uint emissiveTextureIndex;
    uint packedInfo; // Bits 0-15: uvSetIndices, Bits 16-31: flags
    vec4 textureTransforms[5]; // xy = offset, zw = scale
    float textureRotations[5]; // Array of rotations
    float emissiveStrength;
    vec2 _padding;
};

// Push constants for per-mesh data (matching PBRPushConstants)
layout(push_constant, std430) uniform PushConstants {
    layout(offset = 0) mat4 modelMatrix;
    layout(offset = 64) Material material;
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