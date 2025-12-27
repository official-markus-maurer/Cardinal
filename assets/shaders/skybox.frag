#version 450
layout(location = 0) in vec3 inUVW;
layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform sampler2D skybox;

const vec2 invAtan = vec2(0.1591, 0.3183);

vec2 SampleSphericalMap(vec3 v)
{
    vec2 uv = vec2(atan(v.z, v.x), asin(v.y));
    uv *= invAtan;
    uv += 0.5;
    // Flip Y if needed (depends on texture)
    uv.y = 1.0 - uv.y;
    return uv;
}

void main() {
    vec2 uv = SampleSphericalMap(normalize(inUVW));
    vec3 color = texture(skybox, uv).rgb;
    
    // Simple Tone Mapping (Reinhard)
    // color = color / (color + vec3(1.0));
    // Gamma Correction
    // color = pow(color, vec3(1.0/2.2));
    
    // Output raw HDR if framebuffer supports it, or tonemapped if not.
    // Assuming we output to HDR buffer and tonemap later.
    
    outColor = vec4(color, 1.0);
}
