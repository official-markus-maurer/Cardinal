#version 450

// Input from vertex shader
layout(location = 0) in vec2 fragTexCoord;

// Output color
layout(location = 0) out vec4 outColor;

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
};

// Push constants for per-mesh data (matching PBRPushConstants)
layout(push_constant, std430) uniform PushConstants {
    layout(offset = 0) mat4 modelMatrix;
    layout(offset = 64) Material material;
} pushConstants;

// Function to apply texture transform (same as PBR pipeline)
vec2 applyTextureTransform(vec2 uv, vec4 transform, float rotation) {
    vec2 offset = transform.xy;
    vec2 scale = transform.zw;
    
    // Apply transformations in correct order: translate to origin, scale, rotate, translate back, apply offset
    vec2 transformedUV = uv;
    
    // First, translate to origin (0.5, 0.5) for rotation
    vec2 center = vec2(0.5);
    transformedUV -= center;
    
    // Apply scale
    transformedUV *= scale;
    
    // Apply rotation
    if (rotation != 0.0) {
        float cosR = cos(rotation);
        float sinR = sin(rotation);
        mat2 rotMatrix = mat2(cosR, -sinR, sinR, cosR);
        transformedUV = rotMatrix * transformedUV;
    }
    
    // Translate back from origin
    transformedUV += center;
    
    // Apply offset
    transformedUV += offset;
    
    return transformedUV;
}

void main() {
    // Apply albedo texture transform to UV coordinates for visualization
    vec2 transformedUV = applyTextureTransform(fragTexCoord, pushConstants.material.textureTransforms[0], pushConstants.material.textureRotations[0]);
    
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
    
    // Output final color
    outColor = vec4(finalColor, 1.0);
}