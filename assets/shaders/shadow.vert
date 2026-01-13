#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inTexCoord;
layout(location = 3) in vec4 inBoneWeights;
layout(location = 4) in uvec4 inBoneIndices;
layout(location = 5) in vec2 inTexCoord1;

layout(binding = 0) uniform ShadowUBO {
    mat4 lightSpaceMatrices[4];
    vec4 cascadeSplits; 
} ubo;

layout(binding = 6) uniform BoneMatrices {
    mat4 bones[256];
} boneMatrices;

layout(push_constant) uniform PushConstants {
    mat4 modelMatrix;
    // packedInfo at offset 132 (same as pbr.vert)
    layout(offset = 132) uint packedInfo;
    // cascadeIndex was at 152, but we need to verify where it is passed from code
    // The C struct PBRPushConstants doesn't have cascadeIndex, it's likely passed via a different mechanism or offset?
    // Wait, shadow pass uses ShadowPushConstants? Let's check vulkan_types.zig
    layout(offset = 152) uint cascadeIndex;
} pushConstants;

layout(location = 0) out vec2 fragTexCoord;

void main() {
    vec3 finalPosition = inPosition;
    fragTexCoord = inTexCoord;
    
    // Extract hasSkeleton from packedInfo (bit 2)
    bool hasSkeleton = ((pushConstants.packedInfo >> 16) & 4u) != 0u;

    if (hasSkeleton) {
        mat4 boneTransform = mat4(0.0);
        for (int i = 0; i < 4; i++) {
            if (inBoneWeights[i] > 0.0) {
                if (inBoneIndices[i] < 256u) {
                    boneTransform += boneMatrices.bones[inBoneIndices[i]] * inBoneWeights[i];
                }
            }
        }
        finalPosition = (boneTransform * vec4(inPosition, 1.0)).xyz;
    }
    
    gl_Position = ubo.lightSpaceMatrices[pushConstants.cascadeIndex] * pushConstants.modelMatrix * vec4(finalPosition, 1.0);
}
