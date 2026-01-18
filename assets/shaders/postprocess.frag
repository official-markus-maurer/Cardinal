#version 450

layout (set = 0, binding = 0) uniform sampler2D inputColor;
layout (set = 0, binding = 1) uniform sampler2D bloomTexture;
layout (set = 0, binding = 2) uniform PostProcessParams {
    float exposure;
    float contrast;
    float saturation;
    float bloomIntensity;
} params;

layout (location = 0) in vec2 inUV;
layout (location = 0) out vec4 outColor;

// Narkowicz 2015 ACES Tone Mapping
vec3 ACESFilm(vec3 x)
{
    float a = 2.51f;
    float b = 0.03f;
    float c = 2.43f;
    float d = 0.59f;
    float e = 0.14f;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0f, 1.0f);
}

// High-frequency noise for dithering
float InterleavedGradientNoise(vec2 position_screen)
{
    vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
    return fract(magic.z * fract(dot(position_screen, magic.xy)));
}

void main() 
{
    vec3 color = texture(inputColor, inUV).rgb;
    vec3 bloom = texture(bloomTexture, inUV).rgb;

    // Apply Exposure
    color *= params.exposure;

    // Add Bloom
    color += bloom * params.bloomIntensity;

    // Tone Mapping
    color = ACESFilm(color);

    // Color Correction
    // Contrast
    color = (color - 0.5) * params.contrast + 0.5;
    
    // Saturation
    float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(vec3(luminance), color, params.saturation);

    // Dithering (8-bit)
    float dither = (InterleavedGradientNoise(gl_FragCoord.xy) - 0.5) / 255.0;
    color += dither;

    // Gamma Correction
    color = pow(color, vec3(1.0f / 2.2f));

    outColor = vec4(color, 1.0f);
}
