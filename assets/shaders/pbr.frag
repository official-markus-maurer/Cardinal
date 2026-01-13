#version 450
#extension GL_EXT_nonuniform_qualifier : enable

// Input from vertex shader
layout(location = 0) in vec3 fragWorldPos;
layout(location = 1) in vec3 fragNormal;
layout(location = 2) in vec2 fragTexCoord;
layout(location = 3) in vec3 fragViewPos;
layout(location = 4) in vec2 fragTexCoord1;

layout(binding = 0) uniform UniformBufferObject {
    mat4 model;
    mat4 view;
    mat4 proj;
    vec4 viewPosAndDebug; // xyz = viewPos, w = debugFlags
} ubo;

// Output color
layout(location = 0) out vec4 outColor;

// Material textures - fixed bindings (fallback mode)
layout(binding = 1) uniform sampler2D albedoMap;
layout(binding = 2) uniform sampler2D normalMap;
layout(binding = 3) uniform sampler2D metallicRoughnessMap;
layout(binding = 4) uniform sampler2D aoMap;
layout(binding = 5) uniform sampler2D emissiveMap;

// Texture array for descriptor indexing (when available)
layout(set = 1, binding = 0) uniform sampler2D textures[];

// Texture transform structure
struct TextureTransform {
    vec2 offset;
    vec2 scale;
    float rotation;
};

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

// Push constants for per-mesh material properties
layout(push_constant, std430) uniform PushConstants {
    layout(offset = 64) Material material;
};

// Lighting buffer (SSBO)
struct Light {
    vec4 lightDirection; // w = type (0=Directional, 1=Point, 2=Spot)
    vec4 lightColor;     // w = intensity
    vec4 ambientColor;   // w = range
    vec4 lightPosition;  // w = unused
};

layout(std430, binding = 8) readonly buffer LightingBuffer {
    uint lightCount;
    uint _padding[3];
    Light lights[];
} lighting;

layout(binding = 7) uniform sampler2DArrayShadow shadowMap;

layout(binding = 9) uniform ShadowUBO {
    mat4 lightSpaceMatrices[4];
    vec4 cascadeSplits; 
} shadowData;

float ShadowCalculation(vec3 worldPos, vec3 N, vec3 L) {
    // Ensure normal and light direction are normalized for accurate bias calculation
    vec3 normal = normalize(N);
    vec3 lightDir = normalize(L);

    vec4 fragPosViewSpace = ubo.view * vec4(worldPos, 1.0);
    float depthValue = abs(fragPosViewSpace.z);
    
    int layer = -1;
    for (int i = 0; i < 4; i++) {
        if (depthValue < shadowData.cascadeSplits[i]) {
            layer = i;
            break;
        }
    }
    if (layer == -1) layer = 3;
    
    vec4 lightSpacePos = shadowData.lightSpaceMatrices[layer] * vec4(worldPos, 1.0);
    vec3 projCoords = lightSpacePos.xyz / lightSpacePos.w;
    projCoords.xy = projCoords.xy * 0.5 + 0.5;
    
    if (projCoords.z > 1.0) return 1.0;
    
    // Use geometry normal (passed as N) for bias to avoid self-shadowing acne on normal mapped surfaces
    float baseBias = max(0.00005 * (1.0 - dot(normal, lightDir)), 0.00001);
    
    // Scale by layer to prevent acne in lower resolution cascades
    // Use minimal scaling to keep bias consistent across transitions
    float bias = baseBias * (float(layer) * 0.1 + 1.0);
    
    float shadow = 0.0;
    vec2 texelSize = 1.0 / vec2(textureSize(shadowMap, 0));
    for(int x = -1; x <= 1; ++x) {
        for(int y = -1; y <= 1; ++y) {
             float pcfDepth = texture(shadowMap, vec4(projCoords.xy + vec2(x, y) * texelSize, layer, projCoords.z - bias)); 
             shadow += pcfDepth;
        }
    }
    shadow /= 9.0;
    
    // Cascade Blending
    if (layer < 3) {
        float splitDist = shadowData.cascadeSplits[layer];
        float blendOverlap = 3.0; // Increased blend region to 3 meters for smoother transition
        float distToEdge = splitDist - depthValue;
        
        if (distToEdge < blendOverlap) {
            int nextLayer = layer + 1;
            vec4 lightSpacePosNext = shadowData.lightSpaceMatrices[nextLayer] * vec4(worldPos, 1.0);
            vec3 projCoordsNext = lightSpacePosNext.xyz / lightSpacePosNext.w;
            projCoordsNext.xy = projCoordsNext.xy * 0.5 + 0.5;
            
            // Match bias scaling logic
            float biasNext = baseBias * (float(nextLayer) * 0.1 + 1.0);
            float shadowNext = 0.0;
            
            for(int x = -1; x <= 1; ++x) {
                for(int y = -1; y <= 1; ++y) {
                     float pcfDepth = texture(shadowMap, vec4(projCoordsNext.xy + vec2(x, y) * texelSize, nextLayer, projCoordsNext.z - biasNext)); 
                     shadowNext += pcfDepth;
                }
            }
            shadowNext /= 9.0;
            
            float t = smoothstep(blendOverlap, 0.0, distToEdge);
            shadow = mix(shadow, shadowNext, t);
        }
    }
    
    return 1.0 - shadow;
}


// Helper function to apply texture transform (scale, offset, rotation)
vec2 applyTextureTransform(vec2 uv, uint texIndex) {
    vec4 transform = material.textureTransforms[texIndex];
    float rotation = material.textureRotations[texIndex];
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
    
    // Apply offset (no Y-flip adjustment needed as textures are already flipped during loading)
    transformedUV += offset;
    
    return transformedUV;
}

const float PI = 3.14159265359;

// Utility: checks if an index means "no texture"
bool isNoTex(uint idx) {
    return idx == 0xFFFFFFFFu; // UINT32_MAX means no texture provided
}

// Utility: get UV coordinate based on UV set index
vec2 getUV(uint uvIndex) {
    if (uvIndex == 1) {
        return fragTexCoord1;
    }
    return fragTexCoord;
}

// Utility: unpack UV index from packed uint
uint getUVIndex(uint textureSlot) {
    // textureSlot: 0=Albedo, 1=Normal, 2=MR, 3=AO, 4=Emissive
    uint uvSetIndices = material.packedInfo & 0xFFFFu;
    return (uvSetIndices >> (textureSlot * 3)) & 0x7;
}

// Utility: sample from descriptor array with non-uniform index
vec4 sampleArray(uint idx, vec2 uv) {
    return texture(textures[nonuniformEXT(idx)], uv);
}

// Helper to unpack flags
uint getAlphaMode() {
    uint flags = material.packedInfo >> 16;
    return flags & 3u;
}

bool hasSkeleton() {
    uint flags = material.packedInfo >> 16;
    return (flags & 4u) != 0u;
}

bool supportsDescriptorIndexing() {
    uint flags = material.packedInfo >> 16;
    return (flags & 8u) != 0u;
}

// Helper to decide if we should use descriptor array
bool canUseArray(uint idx) {
    return supportsDescriptorIndexing() && !isNoTex(idx);
}

// Enhanced normal mapping function with quad control
vec3 getNormalFromMap(vec2 uv) {
    vec3 nrm;
    
    // Use quad control for enhanced texture sampling in conditional branches
    if (canUseArray(material.normalTextureIndex)) {
        // Enhanced derivatives for bindless texture sampling
        vec2 dx = dFdxFine(uv);
        vec2 dy = dFdyFine(uv);
        nrm = textureGrad(textures[nonuniformEXT(material.normalTextureIndex)], uv, dx, dy).xyz;
    } else {
        // Standard sampling with improved derivatives
        vec2 dx = dFdxFine(uv);
        vec2 dy = dFdyFine(uv);
        nrm = textureGrad(normalMap, uv, dx, dy).xyz;
    }
    
    vec3 tangentNormal = nrm * 2.0 - 1.0;
    tangentNormal.xy *= material.metallicNormalAO.y;
    
    // Enhanced derivative calculations with quad control
    vec3 Q1 = dFdxFine(fragWorldPos);
    vec3 Q2 = dFdyFine(fragWorldPos);
    
    // Use the UV set assigned to normal map for TBN calculation
    vec2 baseUV = getUV(getUVIndex(1));
    vec2 st1 = dFdxFine(baseUV);
    vec2 st2 = dFdyFine(baseUV);
    
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
    vec2 albedoUV = applyTextureTransform(getUV(getUVIndex(0)), 0);
    vec2 normalUV = applyTextureTransform(getUV(getUVIndex(1)), 1);
    vec2 metallicRoughnessUV = applyTextureTransform(getUV(getUVIndex(2)), 2);
    vec2 aoUV = applyTextureTransform(getUV(getUVIndex(3)), 3);
    vec2 emissiveUV = applyTextureTransform(getUV(getUVIndex(4)), 4);
    
    // Enhanced material property sampling with quad control
    vec4 albedoSample = vec4(1.0);
    vec3 albedo = vec3(material.albedo.xyz);
    if (!isNoTex(material.albedoTextureIndex)) {
        if (canUseArray(material.albedoTextureIndex)) {
            // Use enhanced derivatives for transformed UV coordinates
            vec2 dx = dFdxFine(albedoUV);
            vec2 dy = dFdyFine(albedoUV);
            albedoSample = textureGrad(textures[nonuniformEXT(material.albedoTextureIndex)], albedoUV, dx, dy);
        } else {
            vec2 dx = dFdxFine(albedoUV);
            vec2 dy = dFdyFine(albedoUV);
            albedoSample = textureGrad(albedoMap, albedoUV, dx, dy);
        }
        albedo *= albedoSample.rgb;
    }

    // Alpha Handling
    float alpha = albedoSample.a * material.albedo.a;
    
    // MASK mode (1): Discard if alpha is below cutoff
    uint alphaMode = getAlphaMode();
    if (alphaMode == 1) {
        float cutoff = material.metallicNormalAO.w;
        if (alpha < cutoff) {
            discard;
        }
        alpha = 1.0; // Treat as opaque after mask test
    } 
    // OPAQUE mode (0): Force alpha to 1.0
    else if (alphaMode == 0) {
        alpha = 1.0;
    }
    // BLEND mode (2): Use texture alpha (no change needed)
    
    vec3 metallicRoughness;
    float metallic;
    float roughness;
    if (!isNoTex(material.metallicRoughnessTextureIndex)) {
        if (canUseArray(material.metallicRoughnessTextureIndex)) {
            vec2 dx = dFdxFine(metallicRoughnessUV);
            vec2 dy = dFdyFine(metallicRoughnessUV);
            metallicRoughness = textureGrad(textures[nonuniformEXT(material.metallicRoughnessTextureIndex)], metallicRoughnessUV, dx, dy).rgb;
        } else {
            vec2 dx = dFdxFine(metallicRoughnessUV);
            vec2 dy = dFdyFine(metallicRoughnessUV);
            metallicRoughness = textureGrad(metallicRoughnessMap, metallicRoughnessUV, dx, dy).rgb;
        }
        metallic = metallicRoughness.b * material.metallicNormalAO.x;
        roughness = metallicRoughness.g * material.emissiveAndRoughness.w;
    } else {
        metallic = material.metallicNormalAO.x;
        roughness = material.emissiveAndRoughness.w;
    }
    
    float ao = 1.0; // Default AO value according to GLTF 2.0 spec
    if (!isNoTex(material.aoTextureIndex)) {
        if (canUseArray(material.aoTextureIndex)) {
            vec2 dx = dFdxFine(aoUV);
            vec2 dy = dFdyFine(aoUV);
            ao = textureGrad(textures[nonuniformEXT(material.aoTextureIndex)], aoUV, dx, dy).r;
        } else {
            vec2 dx = dFdxFine(aoUV);
            vec2 dy = dFdyFine(aoUV);
            ao = textureGrad(aoMap, aoUV, dx, dy).r;
        }
    }
    // Apply AO strength factor
    ao = mix(1.0, ao, material.metallicNormalAO.z);
    
    vec3 emissive = vec3(material.emissiveAndRoughness.xyz);
    if (!isNoTex(material.emissiveTextureIndex)) {
        if (canUseArray(material.emissiveTextureIndex)) {
            vec2 dx = dFdxFine(emissiveUV);
            vec2 dy = dFdyFine(emissiveUV);
            emissive *= textureGrad(textures[nonuniformEXT(material.emissiveTextureIndex)], emissiveUV, dx, dy).rgb;
        } else {
            vec2 dx = dFdxFine(emissiveUV);
            vec2 dy = dFdyFine(emissiveUV);
            emissive *= textureGrad(emissiveMap, emissiveUV, dx, dy).rgb;
        }
    }
    
    // Get normal from normal map
    vec3 N = getNormalFromMap(normalUV);
    vec3 V = normalize(fragViewPos - fragWorldPos);
    
    // Calculate reflectance at normal incidence
    vec3 F0 = vec3(0.04);
    F0 = mix(F0, albedo, metallic);
    
    // Reflectance equation
    vec3 Lo = vec3(0.0);
    vec3 totalAmbient = vec3(0.0);
    
    for (uint i = 0; i < lighting.lightCount; i++) {
        Light light = lighting.lights[i];

        // Directional light calculation
        vec3 L;
        float attenuation = 1.0;
        int type = int(light.lightDirection.w);

        if (type == 1) { // Point Light
            vec3 L_unnormalized = light.lightPosition.xyz - fragWorldPos;
            float dist = length(L_unnormalized);
            L = normalize(L_unnormalized);
            
            float range = light.ambientColor.w;
            if (range > 0.0) {
                float distSq = dist * dist;
                // Standard inverse square falloff
                attenuation = 1.0 / max(distSq, 0.01);
                
                // Windowing function to zero out at range
                float rangeSq = range * range;
                float factor = clamp(1.0 - (distSq * distSq) / (rangeSq * rangeSq), 0.0, 1.0);
                attenuation *= factor * factor;
            } else {
                 // If range is 0 or infinite, just inverse square
                 attenuation = 1.0 / max(dist * dist, 0.01);
            }
        } else { // Directional (default)
            L = normalize(-light.lightDirection.xyz);
        }

        float shadow = 0.0;
        if (type == 0) { // Directional
            // Pass geometry normal (fragNormal) instead of perturbed normal (N) for shadow bias calculation
            // This prevents shadow acne on surfaces with strong normal maps
            shadow = ShadowCalculation(fragWorldPos, normalize(fragNormal), L);
        }

        vec3 H = normalize(V + L);
        vec3 radiance = light.lightColor.rgb * light.lightColor.w * attenuation;
        
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
        Lo += (kD * albedo / PI + specular) * radiance * NdotL * (1.0 - shadow);
        
        // Accumulate ambient
        totalAmbient += light.ambientColor.rgb;
    }
    
    // Ambient lighting
    vec3 ambient = totalAmbient * albedo * ao;
    
    // Combine lighting components
    vec3 color = ambient + Lo;
    
    // Add emissive contribution AFTER tone mapping to preserve bright emissive materials
    // Apply improved tone mapping (ACES approximation)
    color = color / (color + vec3(1.0));
    
    // Add emissive after tone mapping to ensure it remains bright
    color += emissive * 5.0; // Boost emissive to make it glow
    
    // Apply gamma correction
    color = pow(color, vec3(1.0/2.2));
    
    outColor = vec4(color, alpha);
}