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
    
    // Dithering to prevent banding
    vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
    float dither = (fract(magic.z * fract(dot(gl_FragCoord.xy, magic.xy))) - 0.5) / 255.0;
    color += dither;

    // Output raw HDR if framebuffer supports it, or tonemapped if not.
    // Assuming we output to HDR buffer and tonemap later.
    
    outColor = vec4(color, 1.0);
}
