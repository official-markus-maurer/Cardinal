#version 450

// Input from vertex shader
layout(location = 0) in vec3 fragWorldPos;
layout(location = 1) in vec3 fragNormal;

// Output color
layout(location = 0) out vec4 outColor;

void main() {
    // Enhanced wireframe rendering with quad control
    vec3 wireframeColor = vec3(1.0, 1.0, 1.0);
    
    // Enhanced depth-based fading with standard derivatives
    float depth = gl_FragCoord.z;
    float depthGradient = length(vec2(dFdx(depth), dFdy(depth)));
    
    // Use gradient information for better edge detection
    float edgeIntensity = 1.0 + depthGradient * 2.0;
    float fade = 1.0 - (depth * 0.5);
    
    // Enhanced wireframe with edge-aware intensity
    vec3 finalColor = wireframeColor * fade * edgeIntensity;
    
    outColor = vec4(finalColor, 1.0);
}