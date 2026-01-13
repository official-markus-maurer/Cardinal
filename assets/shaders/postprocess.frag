#version 450

layout (set = 0, binding = 0) uniform sampler2D inputColor;

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

void main() 
{
    vec3 color = texture(inputColor, inUV).rgb;

    // Tone Mapping
    color = ACESFilm(color);

    // Gamma Correction
    color = pow(color, vec3(1.0f / 2.2f));

    outColor = vec4(color, 1.0f);
}
