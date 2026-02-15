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
    float emissiveStrength;
    vec2 _padding;
};

// Push constants for per-mesh data (matching PBRPushConstants)
layout(push_constant, std430) uniform PushConstants {
    layout(offset = 0) mat4 modelMatrix;
    layout(offset = 64) Material material;
} pushConstants;

void main() {
    vec2 uv = fragTexCoord;

    // Base color: Wrapped UV gradient (U=Red, V=Green)
    vec3 color = vec3(fract(uv.x), fract(uv.y), 0.0);

    // Minor Grid (10x10 per UV unit)
    // Using fwidth for consistent line width (anti-aliased)
    vec2 grid_uv = uv * 10.0;
    vec2 grid = abs(fract(grid_uv - 0.5) - 0.5) / fwidth(grid_uv);
    float line = min(grid.x, grid.y);
    float gridVal = 1.0 - min(line, 1.0);

    // Major Grid (1x1 per UV unit)
    vec2 major_grid = abs(fract(uv - 0.5) - 0.5) / fwidth(uv);
    float major_line = min(major_grid.x, major_grid.y);
    float major_gridVal = 1.0 - min(major_line, 1.0);

    // Mix grid lines (White) onto base color
    // Minor lines are 50% opacity, Major lines are 100% opacity
    color = mix(color, vec3(1.0), gridVal * 0.5);
    color = mix(color, vec3(1.0), major_gridVal);

    outColor = vec4(color, 1.0);
}
