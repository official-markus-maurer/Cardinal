#version 450
#extension GL_EXT_nonuniform_qualifier : require

// Fragment shader for mesh shader pipeline with PBR support

// Input from vertex shader
layout(location = 0) in vec3 fragWorldPos;
layout(location = 1) in vec3 fragNormal;
layout(location = 2) in vec2 fragTexCoord;
layout(location = 3) in flat uint fragMaterialIndex;
layout(location = 4) in flat vec3 fragCameraPos;
layout(location = 5) in vec2 fragTexCoord1; // Added if mesh shader supports it, or reuse fragTexCoord

// Output
layout(location = 0) out vec4 outColor;

// Mesh UBO (for view matrix)
layout(set = 0, binding = 5) uniform UniformBuffer {
    mat4 model;
    mat4 view;
    mat4 proj;
    mat4 mvp;
    uint materialIndex;
    vec4 viewPos; // xyz = pos, w = unused
    vec4 ambientColor; // xyz = color, w = range/unused
} ubo;

// Material structure (Must match MeshShaderPushConstants in Zig)
struct Material {
    vec4 albedo;
    vec4 emissiveAndRoughness; // xyz = emissive, w = roughness
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

// Push constants for per-mesh material properties (offset 0)
layout(push_constant, std430) uniform PushConstants {
    Material material;
};

// Lighting data (SSBO) matching pbr.frag
struct Light {
    vec4 lightDirection; // w = type (0=Directional, 1=Point, 2=Spot)
    vec4 lightColor;     // w = intensity
    vec4 params;         // x = range, y = innerConeCos, z = outerConeCos
    vec4 lightPosition;  // w = unused
};

layout(std430, set = 1, binding = 1) readonly buffer LightingBuffer {
    uint lightCount;
    uint _padding[3];
    Light lights[];
} lighting;

// Shadow Map
layout(set = 1, binding = 3) uniform sampler2DArrayShadow shadowMap;

layout(set = 1, binding = 4) uniform ShadowUBO {
    mat4 lightSpaceMatrices[4];
    vec4 cascadeSplits; 
} shadowData;

// Bindless texture array for descriptor indexing (Must be last binding for variable count)
layout(set = 1, binding = 5) uniform sampler2D bindlessTextures[];

// Constants
const float PI = 3.14159265359;
const uint UINT32_MAX = 0xFFFFFFFFu;

// Helper Functions

// Utility: checks if an index means "no texture"
bool isNoTex(uint idx) {
    return idx == UINT32_MAX;
}

// Utility: get UV coordinate based on UV set index
vec2 getUV(uint uvIndex) {
    // Currently mesh shader only passes one UV set (fragTexCoord).
    // If we need UV1, we should add it to mesh shader outputs.
    // For now, fallback to fragTexCoord for all.
    return fragTexCoord;
}

// Utility: unpack UV index from packed uint
uint getUVIndex(uint textureSlot) {
    // textureSlot: 0=Albedo, 1=Normal, 2=MR, 3=AO, 4=Emissive
    uint uvSetIndices = material.packedInfo & 0xFFFFu;
    return (uvSetIndices >> (textureSlot * 3)) & 0x7;
}

// Helper to decide if we should use descriptor array
bool supportsDescriptorIndexing() {
    uint flags = material.packedInfo >> 16;
    return (flags & 8u) != 0u;
}

bool canUseArray(uint idx) {
    return supportsDescriptorIndexing() && !isNoTex(idx);
}

// Helper function to apply texture transform
vec2 applyTextureTransform(vec2 uv, uint texIndex) {
    vec4 transform = material.textureTransforms[texIndex];
    float rotation = material.textureRotations[texIndex];
    vec2 offset = transform.xy;
    vec2 scale = transform.zw;

    vec2 transformedUV = uv;
    vec2 center = vec2(0.5);
    transformedUV -= center;
    transformedUV *= scale;
    if (rotation != 0.0) {
        float cosR = cos(rotation);
        float sinR = sin(rotation);
        mat2 rotMatrix = mat2(cosR, -sinR, sinR, cosR);
        transformedUV = rotMatrix * transformedUV;
    }
    transformedUV += center;
    transformedUV += offset;
    return transformedUV;
}

// Enhanced normal mapping function
vec3 getNormalFromMap(vec2 uv) {
    vec3 nrm;
    if (canUseArray(material.normalTextureIndex)) {
        nrm = texture(bindlessTextures[nonuniformEXT(material.normalTextureIndex)], uv).xyz;
    } else {
        // Fallback or default normal
        nrm = vec3(0.5, 0.5, 1.0);
    }
    vec3 tangentNormal = nrm * 2.0 - 1.0;
    tangentNormal.xy *= material.metallicNormalAO.y;
    
    vec3 Q1 = dFdx(fragWorldPos);
    vec3 Q2 = dFdy(fragWorldPos);
    vec2 st1 = dFdx(uv);
    vec2 st2 = dFdy(uv);
    
    vec3 N = normalize(fragNormal);
    vec3 T = normalize(Q1 * st2.t - Q2 * st1.t);
    vec3 B = -normalize(cross(N, T));
    mat3 TBN = mat3(T, B, N);
    
    return normalize(TBN * tangentNormal);
}

// PBR Functions
float DistributionGGX(vec3 N, vec3 H, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;
    float nom = a2;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
    return nom / max(denom, 0.0000001);
}

float GeometrySchlickGGX(float NdotV, float roughness) {
    float r = (roughness + 1.0);
    float k = (r * r) / 8.0;
    float nom = NdotV;
    float denom = NdotV * (1.0 - k) + k;
    return nom / max(denom, 0.0000001);
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

// Shadow Calculation
const vec2 poissonDisk[16] = vec2[](
   vec2( -0.94201624, -0.39906216 ), vec2( 0.94558609, -0.76890725 ),
   vec2( -0.094184101, -0.92938870 ), vec2( 0.34495938, 0.29387760 ),
   vec2( -0.91588581, 0.45771432 ), vec2( -0.81544232, -0.87912464 ),
   vec2( -0.38277543, 0.27676845 ), vec2( 0.97484398, 0.75648379 ),
   vec2( 0.44323325, -0.97511554 ), vec2( 0.53742981, -0.47373420 ),
   vec2( -0.26496911, -0.41893023 ), vec2( 0.79197514, 0.19090188 ),
   vec2( -0.24188840, 0.99706507 ), vec2( -0.81409955, 0.91437590 ),
   vec2( 0.19984126, 0.78641367 ), vec2( 0.14383161, -0.14100790 )
);

float InterleavedGradientNoise(vec2 position_screen) {
    vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
    return fract(magic.z * fract(dot(position_screen, magic.xy)));
}

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
    
    if (projCoords.z > 1.0) return 0.0;
    
    float baseBias = max(0.00005 * (1.0 - dot(normal, lightDir)), 0.00001);
    float bias = baseBias * (float(layer) * 0.1 + 1.0);
    float shadow = 0.0;
    vec2 texelSize = 1.0 / vec2(textureSize(shadowMap, 0));
    
    float noise = InterleavedGradientNoise(gl_FragCoord.xy);
    float angle = noise * 6.28318530718;
    float s = sin(angle);
    float c = cos(angle);
    mat2 rot = mat2(c, -s, s, c);
    float filterRadius = 2.5;
    
    for(int i = 0; i < 16; ++i) {
        vec2 offset = rot * poissonDisk[i] * filterRadius * texelSize;
        shadow += texture(shadowMap, vec4(projCoords.xy + offset, layer, projCoords.z - bias));
    }
    shadow /= 16.0;
    
    if (layer < 3) {
        float splitDist = shadowData.cascadeSplits[layer];
        float blendOverlap = 3.0;
        float distToEdge = splitDist - depthValue;
        if (distToEdge < blendOverlap) {
            int nextLayer = layer + 1;
            vec4 lightSpacePosNext = shadowData.lightSpaceMatrices[nextLayer] * vec4(worldPos, 1.0);
            vec3 projCoordsNext = lightSpacePosNext.xyz / lightSpacePosNext.w;
            projCoordsNext.xy = projCoordsNext.xy * 0.5 + 0.5;
            float biasNext = baseBias * (float(nextLayer) * 0.1 + 1.0);
            float shadowNext = 0.0;
            for(int i = 0; i < 16; ++i) {
                vec2 offset = rot * poissonDisk[i] * filterRadius * texelSize;
                shadowNext += texture(shadowMap, vec4(projCoordsNext.xy + offset, nextLayer, projCoordsNext.z - biasNext));
            }
            shadowNext /= 16.0;
            float t = smoothstep(blendOverlap, 0.0, distToEdge);
            shadow = mix(shadow, shadowNext, t);
        }
    }
    return shadow;
}

void main() {
    // Albedo
    vec2 albedoUV = applyTextureTransform(getUV(getUVIndex(0)), 0);
    vec4 albedoSample = vec4(1.0);
    if (canUseArray(material.albedoTextureIndex)) {
        albedoSample = texture(bindlessTextures[nonuniformEXT(material.albedoTextureIndex)], albedoUV);
    }
    vec3 albedo = material.albedo.rgb * albedoSample.rgb;
    float alpha = material.albedo.a * albedoSample.a;

    // Alpha Masking
    uint alphaMode = material.packedInfo & 3u;
    if (alphaMode == 1u) { // MASK
        if (alpha < material.metallicNormalAO.w) discard;
    }

    // Normal
    vec2 normalUV = applyTextureTransform(getUV(getUVIndex(1)), 1);
    vec3 N = getNormalFromMap(normalUV);

    // Metallic/Roughness
    vec2 mrUV = applyTextureTransform(getUV(getUVIndex(2)), 2);
    float metallic = material.metallicNormalAO.x;
    float roughness = material.emissiveAndRoughness.w;
    if (canUseArray(material.metallicRoughnessTextureIndex)) {
        vec4 mrSample = texture(bindlessTextures[nonuniformEXT(material.metallicRoughnessTextureIndex)], mrUV);
        metallic *= mrSample.b;
        roughness *= mrSample.g;
    }

    // AO
    vec2 aoUV = applyTextureTransform(getUV(getUVIndex(3)), 3);
    float ao = 1.0;
    if (canUseArray(material.aoTextureIndex)) {
        ao = texture(bindlessTextures[nonuniformEXT(material.aoTextureIndex)], aoUV).r;
    }
    // Scale AO
    ao = mix(1.0, ao, material.metallicNormalAO.z);

    // Emissive
    vec2 emissiveUV = applyTextureTransform(getUV(getUVIndex(4)), 4);
    vec3 emissive = material.emissiveAndRoughness.rgb;
    if (canUseArray(material.emissiveTextureIndex)) {
        emissive *= texture(bindlessTextures[nonuniformEXT(material.emissiveTextureIndex)], emissiveUV).rgb;
    }
    emissive *= material.emissiveStrength;

    // PBR Lighting
    vec3 V = normalize(fragCameraPos - fragWorldPos);
    vec3 F0 = vec3(0.04); 
    F0 = mix(F0, albedo, metallic);

    vec3 Lo = vec3(0.0);

    for(uint i = 0; i < lighting.lightCount; ++i) {
        Light light = lighting.lights[i];
        
        vec3 L;
        float attenuation = 1.0;
        
        uint type = uint(light.lightDirection.w);
        
        if (type == 0) { // Directional
            L = normalize(-light.lightDirection.xyz);
        } else { // Point or Spot
            L = normalize(light.lightPosition.xyz - fragWorldPos);
            float distance = length(light.lightPosition.xyz - fragWorldPos);
            float range = light.params.x;
            if (distance > range) continue;
            
            float falloff = clamp(1.0 - pow(distance / range, 4.0), 0.0, 1.0);
            attenuation = falloff * falloff / (distance * distance + 1.0);
            
            if (type == 2) { // Spot
                float theta = dot(L, normalize(-light.lightDirection.xyz));
                float epsilon = light.params.y - light.params.z;
                float intensity = clamp((theta - light.params.z) / epsilon, 0.0, 1.0);
                attenuation *= intensity;
            }
        }
        
        vec3 H = normalize(V + L);
        float NdotL = max(dot(N, L), 0.0);
        
        // Shadow
        float shadow = 0.0;
        if (type == 0) { // Directional lights only for now
            // Fix: Pass negative light direction (vector TO light)
            shadow = ShadowCalculation(fragWorldPos, N, -light.lightDirection.xyz);
        }
        
        if (NdotL > 0.0) {
            float NDF = DistributionGGX(N, H, roughness);
            float G = GeometrySmith(N, V, L, roughness);
            vec3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);
            
            vec3 numerator = NDF * G * F;
            float denominator = 4.0 * max(dot(N, V), 0.0) * NdotL + 0.0001;
            vec3 specular = numerator / denominator;
            
            vec3 kS = F;
            vec3 kD = vec3(1.0) - kS;
            kD *= 1.0 - metallic;
            
            vec3 radiance = light.lightColor.rgb * light.lightColor.w * attenuation;
            
            Lo += (kD * albedo / PI + specular) * radiance * NdotL * (1.0 - shadow);
        }
    }
    
    // Ambient
    vec3 ambient = ubo.ambientColor.rgb * albedo * ao;
    vec3 color = ambient + Lo + emissive;
    
    // Linear output (post-process handles tone mapping)
    outColor = vec4(color, alpha);
}
