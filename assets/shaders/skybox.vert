#version 450
layout(location = 0) out vec3 outUVW;

layout(push_constant) uniform PushConstants {
    mat4 view;
    mat4 proj;
} pc;

// 8 corners of a cube
const vec3 corners[8] = vec3[8](
    vec3(-1.0, -1.0,  1.0), // 0: L-B-F
    vec3( 1.0, -1.0,  1.0), // 1: R-B-F
    vec3( 1.0,  1.0,  1.0), // 2: R-T-F
    vec3(-1.0,  1.0,  1.0), // 3: L-T-F
    vec3(-1.0, -1.0, -1.0), // 4: L-B-B
    vec3( 1.0, -1.0, -1.0), // 5: R-B-B
    vec3( 1.0,  1.0, -1.0), // 6: R-T-B
    vec3(-1.0,  1.0, -1.0)  // 7: L-T-B
);

// Triangle indices for the cube (CCW winding)
// However, since we are INSIDE the cube, we want to see the back faces (or disable culling)
// Vulkan Skybox pipeline typically disables culling, so order isn't critical for visibility,
// but let's stick to standard topology.
const int indices[36] = int[36](
    // Front
    0, 1, 2, 2, 3, 0,
    // Right
    1, 5, 6, 6, 2, 1,
    // Back
    5, 4, 7, 7, 6, 5,
    // Left
    4, 0, 3, 3, 7, 4,
    // Top
    3, 2, 6, 6, 7, 3,
    // Bottom
    4, 5, 1, 1, 0, 4
);

void main() {
    // Fetch vertex position using index array
    vec3 pos = corners[indices[gl_VertexIndex]];
    outUVW = pos;

    // Remove translation from view matrix
    // We do this manually to ensure we only rotate the skybox
    mat4 view = pc.view;
    view[3] = vec4(0.0, 0.0, 0.0, 1.0);

    // Project position
    vec4 clipPos = pc.proj * view * vec4(pos, 1.0);

    // Force Z to be on the far plane
    // By setting z = w, the depth value (z/w) becomes 1.0
    gl_Position = clipPos.xyww;
}