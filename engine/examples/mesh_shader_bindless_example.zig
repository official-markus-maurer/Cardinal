const std = @import("std");
const c = @cImport({
    @cInclude("vulkan/vulkan.h");
    @cInclude("cardinal/renderer/vulkan_mesh_shader.h");
    @cInclude("cardinal/renderer/vulkan_bindless.h");
    @cInclude("cardinal/core/log.h");
    @cInclude("math.h");
});

const log = @import("cardinal_engine").log;

/// Example function demonstrating mesh shader bindless rendering setup
pub export fn mesh_shader_bindless_example(vulkan_state: ?*c.VulkanState) callconv(.c) bool {
    // 1. Create mesh shader pipeline with bindless support
    var config = c.MeshShaderPipelineConfig{
        .task_shader_path = "shaders/task.spv",
        .mesh_shader_path = "shaders/mesh.spv",
        .fragment_shader_path = "shaders/mesh.frag.spv",
        .cull_mode = c.VK_CULL_MODE_BACK_BIT,
        .front_face = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .polygon_mode = c.VK_POLYGON_MODE_FILL,
        .blend_enable = false,
        .max_vertices_per_meshlet = 64,
        .max_primitives_per_meshlet = 126,
    };

    var pipeline: c.MeshShaderPipeline = undefined;
    if (!c.vk_mesh_shader_create_pipeline(vulkan_state, &config, 
                                         c.VK_FORMAT_B8G8R8A8_SRGB, // swapchain format
                                         c.VK_FORMAT_D32_SFLOAT,     // depth format
                                         &pipeline)) {
        log.cardinal_log_error("Failed to create mesh shader pipeline", .{});
        return false;
    }

    // 2. Set up uniform buffer data
    var uniform_data = c.MeshShaderUniformBuffer{
        .model = .{
            .{1.0, 0.0, 0.0, 0.0},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.0},
            .{0.0, 0.0, 0.0, 1.0},
        },
        .view = .{
            .{1.0, 0.0, 0.0, 0.0},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -5.0},
            .{0.0, 0.0, 0.0, 1.0},
        },
        .projection = .{
            .{1.0, 0.0, 0.0, 0.0},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.0},
            .{0.0, 0.0, 0.0, 1.0},
        },
        .materialIndex = 0,  // Index into the material buffer
    };

    // 3. Create uniform buffer
    var uniform_buffer: c.VkBuffer = null;
    var uniform_memory: c.VkDeviceMemory = null;
    if (!c.vk_mesh_shader_create_uniform_buffer(vulkan_state, &pipeline, &uniform_data,
                                               &uniform_buffer, &uniform_memory)) {
        log.cardinal_log_error("Failed to create mesh shader uniform buffer", .{});
        return false;
    }

    // 4. Set up material buffer for bindless textures
    var material_buffer_data: c.MeshShaderMaterialBuffer = std.mem.zeroes(c.MeshShaderMaterialBuffer);
    
    // Example: Set up first material with texture indices
    material_buffer_data.materials[0] = c.MeshShaderMaterial{
        .baseColorTextureIndex = 0,    // Index into bindless texture array
        .normalTextureIndex = 1,       // Index into bindless texture array
        .metallicRoughnessTextureIndex = 2,
        .emissiveTextureIndex = 3,
        .baseColorFactor = .{1.0, 1.0, 1.0, 1.0},
        .metallicFactor = 1.0,
        .roughnessFactor = 0.5,
        .emissiveFactor = .{0.0, 0.0, 0.0},
    };

    // Create material buffer
    var material_buffer: c.VkBuffer = null;
    // var material_memory: c.VkDeviceMemory = null;
    // Note: This would use a similar buffer creation function
    // vk_create_buffer(vulkan_state, sizeof(MeshShaderMaterialBuffer), 
    //                  VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, &material_buffer, &material_memory);

    // 5. Set up bindless texture array (example with 4 textures)
    var texture_views = [_]c.VkImageView{null} ** 4; // These would be loaded textures
    var sampler: c.VkSampler = null; // This would be a created sampler
    const texture_count: u32 = 4;

    // 6. Set up draw data
    var draw_data = c.MeshShaderDrawData{
        .meshlet_buffer = null,     // Would contain actual meshlet data
        .vertex_buffer = null,      // Would contain vertex data
        .index_buffer = null,       // Would contain index data
        .primitive_buffer = null,   // Would contain primitive data
        .draw_command_buffer = null, // Would contain draw commands
        .uniform_buffer = uniform_buffer,
        .uniform_memory = uniform_memory,
        .meshlet_count = 100,                 // Example meshlet count
        .vertex_count = 1000,
        .index_count = 3000,
        .primitive_count = 1000,
        .draw_command_count = 100,
    };

    // 7. Render using descriptor buffers (no descriptor sets)
    var command_buffer: c.VkCommandBuffer = null; // Would be from command pool
    var lighting_buffer: c.VkBuffer = null;       // Would contain lighting data

    // Update descriptor buffers
    if (!c.vk_mesh_shader_update_descriptor_buffers(vulkan_state, &pipeline, &draw_data,
                                                   material_buffer, lighting_buffer,
                                                   &texture_views, sampler, texture_count)) {
        log.cardinal_log_error("Failed to update mesh shader descriptor buffers", .{});
        return false;
    }
    
    // Draw mesh shader
    c.vk_mesh_shader_draw(command_buffer, vulkan_state, &pipeline, &draw_data);
    
    log.cardinal_log_info("Mesh shader descriptor buffer rendering completed successfully", .{});
    
    // Cleanup would go here...
    // vkDestroyBuffer(vulkan_state->device, uniform_buffer, NULL);
    // vkFreeMemory(vulkan_state->device, uniform_memory, NULL);
    
    return true;
}

/// Example of updating uniform buffer during rendering loop
pub export fn update_mesh_shader_uniforms_example(vulkan_state: ?*c.VulkanState,
                                          draw_data: ?*const c.MeshShaderDrawData,
                                          time: f32) callconv(.c) bool {
    // Create updated uniform data with animated transformation
    var uniform_data = c.MeshShaderUniformBuffer{
        .model = .{
            .{c.cosf(time), 0.0, c.sinf(time), 0.0},
            .{0.0, 1.0, 0.0, 0.0},
            .{-c.sinf(time), 0.0, c.cosf(time), 0.0},
            .{0.0, 0.0, 0.0, 1.0},
        },
        .view = .{
            .{1.0, 0.0, 0.0, 0.0},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, -5.0},
            .{0.0, 0.0, 0.0, 1.0},
        },
        .projection = .{
            .{1.0, 0.0, 0.0, 0.0},
            .{0.0, 1.0, 0.0, 0.0},
            .{0.0, 0.0, 1.0, 0.0},
            .{0.0, 0.0, 0.0, 1.0},
        },
        .materialIndex = @as(u32, @intFromFloat(time * 10)) % 256,  // Cycle through materials
    };

    // Update the uniform buffer
    if (draw_data) |dd| {
        return c.vk_mesh_shader_update_uniform_buffer(vulkan_state,
                                                     dd.uniform_buffer,
                                                     dd.uniform_memory,
                                                     &uniform_data);
    }
    return false;
}
