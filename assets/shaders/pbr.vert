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
    mat4 view;
    mat4 proj;
    vec4 viewPosAndDebug; // xyz = viewPos, w = debugFlags
    vec4 ambientColor;
} ubo;

// Bone matrices uniform buffer for skeletal animation
layout(binding = 6) uniform BoneMatrices {
    mat4 bones[256]; // Support up to 256 bones
} boneMatrices;

// Push constants for per-mesh data
layout(push_constant) uniform PushConstants {
    mat4 modelMatrix;
    // Material data occupies remaining space (offset 64+)
    // packedInfo is at offset 132 (64 + 68)
    layout(offset = 132) uint packedInfo; 
} pushConstants;

// Output to fragment shader
layout(location = 0) out vec3 fragWorldPos;
layout(location = 1) out vec3 fragNormal;
layout(location = 2) out vec2 fragTexCoord;
layout(location = 3) out vec3 fragViewPos;
layout(location = 4) out vec2 fragTexCoord1;
layout(location = 5) out vec4 fragColor;

void main() {
    vec3 finalPosition = inPosition;
    vec3 finalNormal = inNormal;
    
    // Extract hasSkeleton from packedInfo (bit 2, which is 4)
    bool hasSkeleton = ((pushConstants.packedInfo >> 16) & 4u) != 0u;

    // Apply skeletal animation if mesh has a skeleton
    if (hasSkeleton) {
        // Calculate bone transformation matrix
        mat4 boneTransform = mat4(0.0);
        
        // Blend up to 4 bone influences
        for (int i = 0; i < 4; i++) {
            if (inBoneWeights[i] > 0.0) {
                uint boneIndex = inBoneIndices[i];
                if (boneIndex < 256u) {
                    boneTransform += boneMatrices.bones[boneIndex] * inBoneWeights[i];
                }
            }
        }
        
        // Apply bone transformation to position and normal
        vec4 skinnedPos = boneTransform * vec4(inPosition, 1.0);
        finalPosition = skinnedPos.xyz;
        
        // Transform normal (use 3x3 part of bone matrix)
        finalNormal = normalize(mat3(boneTransform) * inNormal);
    }
    
    // Transform position to world space using push constant model matrix
    vec4 worldPos = pushConstants.modelMatrix * vec4(finalPosition, 1.0);
    fragWorldPos = worldPos.xyz;
    
    // Transform normal to world space (assuming uniform scaling)
    fragNormal = normalize(mat3(pushConstants.modelMatrix) * finalNormal);
    
    // Pass through texture coordinates
    fragTexCoord = inTexCoord;
    fragTexCoord1 = inTexCoord1;
    
    // Pass view position for lighting calculations
    fragViewPos = ubo.viewPosAndDebug.xyz;
    
    // Pass vertex color
    fragColor = inColor;

    // Final position in clip space
    gl_Position = ubo.proj * ubo.view * worldPos;
}