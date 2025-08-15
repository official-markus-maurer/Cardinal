#include <cardinal/renderer/util/vulkan_shader_utils.h>
#include <cardinal/core/log.h>
#include <stdio.h>
#include <stdlib.h>

bool vk_shader_create_module(VkDevice device, const char* filename, VkShaderModule* shaderModule) {
    if (!filename || !shaderModule) {
        LOG_ERROR("Invalid parameters for shader module creation");
        return false;
    }

    FILE* file = fopen(filename, "rb");
    if (!file) {
        LOG_ERROR("Failed to open shader file: %s", filename);
        return false;
    }

    // Get file size
    fseek(file, 0, SEEK_END);
    long fileSize = ftell(file);
    fseek(file, 0, SEEK_SET);

    if (fileSize <= 0) {
        LOG_ERROR("Invalid shader file size: %ld", fileSize);
        fclose(file);
        return false;
    }

    // Allocate buffer for shader code
    char* code = malloc(fileSize);
    if (!code) {
        LOG_ERROR("Failed to allocate memory for shader code");
        fclose(file);
        return false;
    }

    // Read shader code
    size_t bytesRead = fread(code, 1, fileSize, file);
    fclose(file);

    if (bytesRead != (size_t)fileSize) {
        LOG_ERROR("Failed to read complete shader file");
        free(code);
        return false;
    }

    // Create shader module
    bool result = vk_shader_create_module_from_code(device, (const uint32_t*)code, fileSize, shaderModule);
    
    free(code);
    return result;
}

bool vk_shader_create_module_from_code(VkDevice device, const uint32_t* code, size_t codeSize, VkShaderModule* shaderModule) {
    if (!device || !code || codeSize == 0 || !shaderModule) {
        LOG_ERROR("Invalid parameters for shader module creation from code");
        return false;
    }

    VkShaderModuleCreateInfo createInfo = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = codeSize,
        .pCode = code,
    };

    VkResult result = vkCreateShaderModule(device, &createInfo, NULL, shaderModule);
    if (result != VK_SUCCESS) {
        LOG_ERROR("Failed to create shader module: %d", result);
        return false;
    }

    return true;
}

void vk_shader_destroy_module(VkDevice device, VkShaderModule shaderModule) {
    if (device && shaderModule != VK_NULL_HANDLE) {
        vkDestroyShaderModule(device, shaderModule, NULL);
    }
}
