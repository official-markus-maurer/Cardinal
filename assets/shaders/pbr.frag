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
layout(binding = 8) uniform sampler2D textures[];

// Material properties uniform buffer
layout(binding = 6) uniform MaterialProperties {
    vec3 albedoFactor;
    float metallicFactor;
    float roughnessFactor;
    vec3 emissiveFactor;
    float normalScale;
    float aoStrength;
    
    // Texture indices for descriptor indexing
    uint albedoTextureIndex;
    uint normalTextureIndex;
    uint metallicRoughnessTextureIndex;
    uint aoTextureIndex;
    uint emissiveTextureIndex;
    uint supportsDescriptorIndexing; // 1 if descriptor indexing path is active, 0 otherwise
} material;

// Lighting uniform buffer
layout(binding = 7) uniform LightingData {
    vec3 lightDirection;  // Directional light
    vec3 lightColor;
    float lightIntensity;
    vec3 ambientColor;
} lighting;

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
vec3 getNormalFromMap() {
    vec3 nrm;
    if (canUseArray(material.normalTextureIndex)) {
        nrm = sampleArray(material.normalTextureIndex, fragTexCoord).xyz;
    } else {
        nrm = texture(normalMap, fragTexCoord).xyz;
    }
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
    // Sample material properties
    vec3 albedo;
    if (canUseArray(material.albedoTextureIndex)) {
        albedo = sampleArray(material.albedoTextureIndex, fragTexCoord).rgb * material.albedoFactor;
    } else {
        albedo = texture(albedoMap, fragTexCoord).rgb * material.albedoFactor;
    }
    
    vec3 metallicRoughness;
    if (canUseArray(material.metallicRoughnessTextureIndex)) {
        metallicRoughness = sampleArray(material.metallicRoughnessTextureIndex, fragTexCoord).rgb;
    } else {
        metallicRoughness = texture(metallicRoughnessMap, fragTexCoord).rgb;
    }
    float metallic = metallicRoughness.b * material.metallicFactor;
    float roughness = metallicRoughness.g * material.roughnessFactor;
    
    float ao;
    if (canUseArray(material.aoTextureIndex)) {
        ao = sampleArray(material.aoTextureIndex, fragTexCoord).r * material.aoStrength;
    } else {
        ao = texture(aoMap, fragTexCoord).r * material.aoStrength;
    }
    
    vec3 emissive;
    if (canUseArray(material.emissiveTextureIndex)) {
        emissive = sampleArray(material.emissiveTextureIndex, fragTexCoord).rgb * material.emissiveFactor;
    } else {
        emissive = texture(emissiveMap, fragTexCoord).rgb * material.emissiveFactor;
    }
    
    // Get normal from normal map
    vec3 N = getNormalFromMap();
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