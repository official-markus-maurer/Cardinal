#version 450
#extension GL_EXT_nonuniform_qualifier : enable

// Input from vertex shader
layout(location = 0) in vec3 fragWorldPos;
layout(location = 1) in vec3 fragNormal;
layout(location = 2) in vec2 fragTexCoord;
layout(location = 3) in vec3 fragViewPos;

// Output color
layout(location = 0) out vec4 outColor;

// Material textures - fixed bindings (fallback mode)
layout(binding = 1) uniform sampler2D albedoMap;
layout(binding = 2) uniform sampler2D normalMap;
layout(binding = 3) uniform sampler2D metallicRoughnessMap;
layout(binding = 4) uniform sampler2D aoMap;
layout(binding = 5) uniform sampler2D emissiveMap;

// Texture array for descriptor indexing (when available)
layout(binding = 9) uniform sampler2D textures[];

// Texture transform structure
struct TextureTransform {
    vec2 offset;
    vec2 scale;
    float rotation;
};

// Material structure
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

// Push constants for per-mesh material properties
layout(push_constant) uniform PushConstants {
    layout(offset = 64) Material material;
};

// Lighting uniform buffer
layout(binding = 8) uniform LightingData {
    vec3 lightDirection;  // Directional light
    vec3 lightColor;
    float lightIntensity;
    vec3 ambientColor;
} lighting;

// Function to apply texture transform (scale, offset, rotation)
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
    
    // Apply offset (no Y-flip adjustment needed as textures are already flipped during loading)
    transformedUV += transform.offset;
    
    return transformedUV;
}

const float PI = 3.14159265359;

// Utility: checks if an index means "no texture"
bool isNoTex(uint idx) {
    return idx == 0xFFFFFFFFu; // UINT32_MAX means no texture provided
}

// Utility: sample from descriptor array with non-uniform index
vec4 sampleArray(uint idx, vec2 uv) {
    return texture(textures[nonuniformEXT(idx)], uv);
}

// Helper to decide if we should use descriptor array
bool canUseArray(uint idx) {
    return material.supportsDescriptorIndexing == 1u && !isNoTex(idx);
}

// Normal mapping function
vec3 getNormalFromMap(vec2 uv) {
    vec3 nrm = canUseArray(material.normalTextureIndex) ? 
        sampleArray(material.normalTextureIndex, uv).xyz : 
        texture(normalMap, uv).xyz;
    
    vec3 tangentNormal = nrm * 2.0 - 1.0;
    tangentNormal.xy *= material.normalScale;
    
    vec3 Q1 = dFdx(fragWorldPos);
    vec3 Q2 = dFdy(fragWorldPos);
    vec2 st1 = dFdx(fragTexCoord);
    vec2 st2 = dFdy(fragTexCoord);
    
    vec3 T = normalize(Q1 * st2.t - Q2 * st1.t);
    vec3 B = normalize(-Q1 * st2.s + Q2 * st1.s);
    vec3 N = normalize(fragNormal);
    
    mat3 TBN = mat3(T, B, N);
    return normalize(TBN * tangentNormal);
}

// GGX/Trowbridge-Reitz normal distribution function
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

// Fresnel function (Schlick approximation)
vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

void main() {
    // Apply texture transforms to UV coordinates
    vec2 albedoUV = applyTextureTransform(fragTexCoord, material.albedoTransform);
    vec2 normalUV = applyTextureTransform(fragTexCoord, material.normalTransform);
    vec2 metallicRoughnessUV = applyTextureTransform(fragTexCoord, material.metallicRoughnessTransform);
    vec2 aoUV = applyTextureTransform(fragTexCoord, material.aoTransform);
    vec2 emissiveUV = applyTextureTransform(fragTexCoord, material.emissiveTransform);
    
    // Sample material properties with transformed UVs
    vec3 albedo = vec3(material.albedoFactor);
    if (canUseArray(material.albedoTextureIndex)) {
        albedo *= sampleArray(material.albedoTextureIndex, albedoUV).rgb;
    } else {
        albedo *= texture(albedoMap, albedoUV).rgb;
    }
    
    vec3 metallicRoughness = canUseArray(material.metallicRoughnessTextureIndex) ?
        sampleArray(material.metallicRoughnessTextureIndex, metallicRoughnessUV).rgb :
        texture(metallicRoughnessMap, metallicRoughnessUV).rgb;
    float metallic = metallicRoughness.b * material.metallicFactor;
    float roughness = metallicRoughness.g * material.roughnessFactor;
    
    float ao = canUseArray(material.aoTextureIndex) ?
        sampleArray(material.aoTextureIndex, aoUV).r * material.aoStrength :
        texture(aoMap, aoUV).r * material.aoStrength;
    
    vec3 emissive = vec3(material.emissiveFactor);
    if (canUseArray(material.emissiveTextureIndex)) {
        emissive *= sampleArray(material.emissiveTextureIndex, emissiveUV).rgb;
    } else {
        emissive *= texture(emissiveMap, emissiveUV).rgb;
    }
    
    // Get normal from normal map
    vec3 N = getNormalFromMap(normalUV);
    vec3 V = normalize(fragViewPos - fragWorldPos);
    
    // Calculate reflectance at normal incidence
    vec3 F0 = vec3(0.04);
    F0 = mix(F0, albedo, metallic);
    
    // Reflectance equation
    vec3 Lo = vec3(0.0);
    
    // Directional light calculation
    vec3 L = normalize(-lighting.lightDirection);
    vec3 H = normalize(V + L);
    vec3 radiance = lighting.lightColor * lighting.lightIntensity;
    
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
    vec3 ambient = lighting.ambientColor * albedo * ao;
    
    vec3 color = ambient + Lo + emissive;
    
    // HDR tonemapping (Reinhard)
    color = color / (color + vec3(1.0));
    
    outColor = vec4(color, 1.0);
}