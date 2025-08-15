#version 450

// Input from vertex shader
layout(location = 0) in vec3 fragWorldPos;
layout(location = 1) in vec3 fragNormal;

// Output color
layout(location = 0) out vec4 outColor;

void main() {
    // Simple wireframe color - white lines
    // In wireframe mode, the rasterizer will only render triangle edges
    vec3 wireframeColor = vec3(1.0, 1.0, 1.0);
    
    // Optional: Add slight depth-based fading for better depth perception
    float depth = gl_FragCoord.z;
    float fade = 1.0 - (depth * 0.5);
    
    outColor = vec4(wireframeColor * fade, 1.0);
}