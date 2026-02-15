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

// Push constants for per-mesh data
layout(push_constant) uniform PushConstants {
    mat4 modelMatrix;
} pushConstants;

// Output to fragment shader
layout(location = 0) out vec3 fragWorldPos;
layout(location = 1) out vec3 fragNormal;

void main() {
    // Transform position to world space using push constant model matrix
    vec4 worldPos = pushConstants.modelMatrix * vec4(inPosition, 1.0);
    fragWorldPos = worldPos.xyz;
    
    // Transform normal to world space (for potential lighting in wireframe)
    fragNormal = normalize(mat3(pushConstants.modelMatrix) * inNormal);
    
    // Final position in clip space
    gl_Position = ubo.proj * ubo.view * worldPos;
}