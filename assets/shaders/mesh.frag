#version 450
#extension GL_EXT_nonuniform_qualifier : require

// Fragment shader for mesh shader pipeline with PBR support

// Input from vertex shader
layout(location = 0) in vec3 fragWorldPos;
layout(location = 1) in vec3 fragNormal;
layout(location = 2) in vec2 fragTexCoord;
layout(location = 3) in flat uint fragMaterialIndex;

// Output
layout(location = 0) out vec4 outColor;

// Material properties
layout(set = 1, binding = 0) uniform MaterialData {
    vec3 albedo;
    float metallic;
    float roughness;
    float ao; // Ambient occlusion
    vec3 emissive;
    float alpha;
} material;

// Lighting data
layout(set = 1, binding = 1) uniform LightingData {
    vec3 light_direction;
    vec3 light_color;
    vec3 ambient_color;
    vec3 camera_pos;
} lighting;

// Bindless texture array for descriptor indexing
layout(set = 1, binding = 3) uniform sampler2D bindlessTextures[];

// Material data structure
struct Material {
    vec3 albedoFactor;
    float metallicFactor;
    float roughnessFactor;
    float normalScale;
    vec3 emissiveFactor;
    uint albedoTextureIndex;
    uint normalTextureIndex;
    uint metallicRoughnessTextureIndex;
    uint aoTextureIndex;
    uint emissiveTextureIndex;
    uint supportsDescriptorIndexing;
};

// Material buffer
layout(set = 1, binding = 2) uniform MaterialBuffer {
    Material materials[256];
} materialBuffer;

// Constants
const float PI = 3.14159265359;

// Utility: checks if an index means "no texture"
bool isNoTex(uint idx) {
    return idx == 0xFFFFFFFFu; // UINT32_MAX means no texture provided
}

// Utility: sample from descriptor array with non-uniform index
vec4 sampleArray(uint idx, vec2 uv) {
    return texture(bindlessTextures[nonuniformEXT(idx)], uv);
}

// Helper to decide if we should use descriptor array
bool canUseArray(uint idx, uint supportsDescriptorIndexing) {
    return supportsDescriptorIndexing == 1u && !isNoTex(idx);
}

// PBR functions
vec3 getNormalFromMap(vec2 uv, Material material) {
    vec3 nrm = canUseArray(material.normalTextureIndex, material.supportsDescriptorIndexing) ? 
        sampleArray(material.normalTextureIndex, uv).xyz : 
        vec3(0.5, 0.5, 1.0); // Default normal
    
    vec3 tangentNormal = nrm * 2.0 - 1.0;
    tangentNormal.xy *= material.normalScale;
    
    vec3 Q1 = dFdx(fragWorldPos);
    vec3 Q2 = dFdy(fragWorldPos);
    vec2 st1 = dFdx(fragTexCoord);
    vec2 st2 = dFdy(fragTexCoord);
    
    vec3 N = normalize(fragNormal);
    vec3 T = normalize(Q1 * st2.t - Q2 * st1.t);
    vec3 B = -normalize(cross(N, T));
    mat3 TBN = mat3(T, B, N);
    
    return normalize(TBN * tangentNormal);
}

float DistributionGGX(vec3 N, vec3 H, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;
    
    float num = a2;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
    
    return num / denom;
}

float GeometrySchlickGGX(float NdotV, float roughness) {
    float r = (roughness + 1.0);
    float k = (r * r) / 8.0;
    
    float num = NdotV;
    float denom = NdotV * (1.0 - k) + k;
    
    return num / denom;
}

float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness) {
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2 = GeometrySchlickGGX(NdotV, roughness);
    float ggx1 = GeometrySchlickGGX(NdotL, roughness);
    
    return ggx1 * ggx2;
}

vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

void main() {
    // Get material from buffer
    Material mat = materialBuffer.materials[fragMaterialIndex];
    
    // Sample textures using bindless texture array
    vec3 albedo = mat.albedoFactor;
    if (canUseArray(mat.albedoTextureIndex, mat.supportsDescriptorIndexing)) {
        albedo *= sampleArray(mat.albedoTextureIndex, fragTexCoord).rgb;
    }
    
    float metallic = mat.metallicFactor;
    float roughness = mat.roughnessFactor;
    if (canUseArray(mat.metallicRoughnessTextureIndex, mat.supportsDescriptorIndexing)) {
        vec3 metallicRoughness = sampleArray(mat.metallicRoughnessTextureIndex, fragTexCoord).rgb;
        metallic *= metallicRoughness.b;
        roughness *= metallicRoughness.g;
    }
    
    float ao = 1.0;
    if (canUseArray(mat.aoTextureIndex, mat.supportsDescriptorIndexing)) {
        ao = sampleArray(mat.aoTextureIndex, fragTexCoord).r;
    }
    
    vec3 emissive = mat.emissiveFactor;
    if (canUseArray(mat.emissiveTextureIndex, mat.supportsDescriptorIndexing)) {
        emissive *= sampleArray(mat.emissiveTextureIndex, fragTexCoord).rgb;
    }
    
    // Calculate normal
    vec3 N = getNormalFromMap(fragTexCoord, mat);
    vec3 V = normalize(lighting.camera_pos - fragWorldPos);
    
    // Calculate reflectance at normal incidence
    vec3 F0 = vec3(0.04);
    F0 = mix(F0, albedo, metallic);
    
    // Reflectance equation
    vec3 Lo = vec3(0.0);
    
    // Directional light calculation
    vec3 L = normalize(-lighting.light_direction);
    vec3 H = normalize(V + L);
    vec3 radiance = lighting.light_color;
    
    // Cook-Torrance BRDF
    float NDF = DistributionGGX(N, H, roughness);
    float G = GeometrySmith(N, V, L, roughness);
    vec3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);
    
    vec3 kS = F;
    vec3 kD = vec3(1.0) - kS;
    kD *= 1.0 - metallic;
    
    vec3 numerator = NDF * G * F;
    float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0) + 0.0001;
    vec3 specular = numerator / denominator;
    
    float NdotL = max(dot(N, L), 0.0);
    Lo += (kD * albedo / PI + specular) * radiance * NdotL;
    
    // Ambient lighting
    vec3 ambient = lighting.ambient_color * albedo * ao;
    
    vec3 color = ambient + Lo + emissive;
    
    // HDR tonemapping
    color = color / (color + vec3(1.0));
    
    // Gamma correction
    color = pow(color, vec3(1.0/2.2));
    
    outColor = vec4(color, material.alpha);
}