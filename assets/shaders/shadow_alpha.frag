#version 450
#extension GL_EXT_nonuniform_qualifier : enable

layout(location = 0) in vec2 fragTexCoord;

// Bindless textures (Set 1)
layout(set = 1, binding = 0) uniform sampler2D textures[];

layout(push_constant) uniform PushConstants {
    layout(offset = 64) uint textureIndex;
    layout(offset = 68) float alphaCutoff;
} material;

void main() {
    if (material.textureIndex == 0xFFFFFFFF) {
        return;
    }

    float alpha = texture(textures[nonuniformEXT(material.textureIndex)], fragTexCoord).a;

    if (alpha < material.alphaCutoff) {
        discard;
    }
}
