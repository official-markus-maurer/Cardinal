#version 450

// Input from vertex shader
layout(location = 0) in vec2 fragTexCoord;

// Output color
layout(location = 0) out vec4 outColor;

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

// Function to apply texture transform (same as PBR pipeline)
vec2 applyTextureTransform(vec2 uv, TextureTransform transform) {
    // Apply transformations in correct order: translate to origin, scale, rotate, translate back, apply offset
    vec2 transformedUV = uv;
    
    // First, translate to origin (0.5, 0.5) for rotation
    vec2 center = vec2(0.5);
    transformedUV -= center;
    
    // Apply scale
    transformedUV *= transform.scale;
    
    // Apply rotation
    if (transform.rotation != 0.0) {
        float cosR = cos(transform.rotation);
        float sinR = sin(transform.rotation);
        mat2 rotMatrix = mat2(cosR, -sinR, sinR, cosR);
        transformedUV = rotMatrix * transformedUV;
    }
    
    // Translate back from origin
    transformedUV += center;
    
    // Apply offset
    transformedUV += transform.offset;
    
    return transformedUV;
}

void main() {
    // Apply albedo texture transform to UV coordinates for visualization
    vec2 transformedUV = applyTextureTransform(fragTexCoord, pushConstants.material.albedoTransform);
    
    // Visualize transformed UV coordinates as colors
    // U coordinate maps to red channel
    // V coordinate maps to green channel
    // Blue channel is set to a constant value for better visibility
    
    vec3 uvColor = vec3(transformedUV.x, transformedUV.y, 0.5);
    
    // Enhanced grid pattern with quad control for better derivative calculations
    vec2 gridUV = transformedUV * 10.0;
    vec2 dxGrid = dFdxFine(gridUV);
    vec2 dyGrid = dFdyFine(gridUV);
    vec2 gridWidth = sqrt(dxGrid * dxGrid + dyGrid * dyGrid);
    
    vec2 grid = abs(fract(gridUV) - 0.5) / gridWidth;
    float gridLine = min(grid.x, grid.y);
    
    // Blend the UV color with grid lines
    vec3 finalColor = mix(vec3(0.0), uvColor, smoothstep(0.0, 1.0, gridLine));
    
    outColor = vec4(finalColor, 1.0);
}