#include "cardinal/core/log.h"
#include "cardinal/core/window.h"
#include "vulkan_state.h"
#include <GLFW/glfw3.h>
#include <cardinal/renderer/vulkan_instance.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

// Enhanced error categorization and filtering
static ValidationStats g_validation_stats = {0};

// Common validation message IDs that can be safely filtered or downgraded
static bool should_filter_message(int32_t message_id, const char* message_id_name) {
    (void)message_id; // Suppress unused parameter warning
    // Filter known non-critical messages
    if (message_id_name) {
        // Layer version warnings (already handled gracefully)
        if (strstr(message_id_name, "Loader-Message") && strstr(message_id_name, "older than")) {
            return true;
        }
        // Swapchain recreation messages (handled by our system)
        if (strstr(message_id_name, "SWAPCHAIN") && strstr(message_id_name, "out of date")) {
            return true;
        }
    }
    return false;
}

static const char* get_message_type_string(VkDebugUtilsMessageTypeFlagsEXT message_type) {
    if (message_type & VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT) {
        return "PERFORMANCE";
    } else if (message_type & VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT) {
        return "VALIDATION";
    } else if (message_type & VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT) {
        return "GENERAL";
    }
    return "UNKNOWN";
}

static const char* get_severity_string(VkDebugUtilsMessageSeverityFlagBitsEXT message_severity) {
    if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT)
        return "ERROR";
    else if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT)
        return "WARNING";
    else if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT)
        return "INFO";
    else if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT)
        return "VERBOSE";
    return "UNKNOWN";
}

/**
 * @brief Enhanced Vulkan debug callback with improved categorization and filtering.
 * @param message_severity Severity level.
 * @param message_type Type of message (general, validation, performance).
 * @param callback_data Message data.
 * @param user_data User data (unused).
 * @return VK_FALSE.
 */
static VKAPI_ATTR VkBool32 VKAPI_CALL
debug_callback(VkDebugUtilsMessageSeverityFlagBitsEXT message_severity,
               VkDebugUtilsMessageTypeFlagsEXT message_type,
               const VkDebugUtilsMessengerCallbackDataEXT* callback_data, void* user_data) {
    (void)user_data;

    // Update statistics
    g_validation_stats.total_messages++;

    if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT)
        g_validation_stats.error_count++;
    else if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT)
        g_validation_stats.warning_count++;
    else if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT)
        g_validation_stats.info_count++;

    if (message_type & VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT)
        g_validation_stats.performance_count++;
    else if (message_type & VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT)
        g_validation_stats.validation_count++;
    else if (message_type & VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT)
        g_validation_stats.general_count++;

    const char* severity_str = get_severity_string(message_severity);
    const char* type_str = get_message_type_string(message_type);

    const char* msg_id_name =
        callback_data && callback_data->pMessageIdName ? callback_data->pMessageIdName : "(no-id)";
    int32_t msg_id_num = callback_data ? callback_data->messageIdNumber : -1;
    const char* message = callback_data ? callback_data->pMessage : "(null)";

    // Apply intelligent filtering
    if (should_filter_message(msg_id_num, msg_id_name)) {
        g_validation_stats.filtered_count++;
        return VK_FALSE;
    }

    // Enhanced message formatting with categorization
    char buffer[1400];
    snprintf(buffer, sizeof(buffer), "VK_DEBUG [%s|%s] (%d:%s): %s", severity_str, type_str,
             msg_id_num, msg_id_name, message);

    // Log with appropriate level and add context for critical messages
    if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        CARDINAL_LOG_ERROR("%s", buffer);
        // For validation errors, provide additional context
        if (message_type & VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT) {
            CARDINAL_LOG_ERROR(
                "[VALIDATION] This error indicates a Vulkan specification violation");
        }
    } else if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        // Categorize warnings for better handling
        if (message_type & VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT) {
            CARDINAL_LOG_WARN("[PERFORMANCE] %s", buffer);
        } else {
            CARDINAL_LOG_WARN("%s", buffer);
        }
    } else if (message_severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT) {
        CARDINAL_LOG_INFO("%s", buffer);
    } else {
        CARDINAL_LOG_DEBUG("%s", buffer);
    }

    return VK_FALSE;
}

// Select severity flags for debug utils messenger based on current engine log level
static VkDebugUtilsMessageSeverityFlagsEXT select_debug_severity_from_log_level(void) {
    CardinalLogLevel lvl = cardinal_log_get_level();
    VkDebugUtilsMessageSeverityFlagsEXT sev = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                                              VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    if (lvl <= CARDINAL_LOG_LEVEL_INFO) {
        sev |= VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT;
    }
    if (lvl <= CARDINAL_LOG_LEVEL_DEBUG) {
        sev |= VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT;
    }
    return sev;
}

// Helper: check if validation should be enabled (debug or CMake toggle)
static bool validation_enabled(void) {
#if defined(_DEBUG) || defined(CARDINAL_ENABLE_VK_VALIDATION)
    return true;
#else
    return false;
#endif
}

/**
 * @brief Get current validation layer statistics.
 * @return Pointer to validation statistics structure.
 */
const ValidationStats* vk_get_validation_stats(void) {
    return &g_validation_stats;
}

/**
 * @brief Reset validation layer statistics.
 */
void vk_reset_validation_stats(void) {
    memset(&g_validation_stats, 0, sizeof(ValidationStats));
}

/**
 * @brief Log validation statistics summary.
 */
void vk_log_validation_stats(void) {
    if (g_validation_stats.total_messages == 0) {
        CARDINAL_LOG_INFO("[VALIDATION] No validation messages received");
        return;
    }

    CARDINAL_LOG_INFO("[VALIDATION] Statistics Summary:");
    CARDINAL_LOG_INFO("[VALIDATION]   Total messages: %u", g_validation_stats.total_messages);
    CARDINAL_LOG_INFO("[VALIDATION]   Errors: %u, Warnings: %u, Info: %u",
                      g_validation_stats.error_count, g_validation_stats.warning_count,
                      g_validation_stats.info_count);
    CARDINAL_LOG_INFO("[VALIDATION]   By type - Validation: %u, Performance: %u, General: %u",
                      g_validation_stats.validation_count, g_validation_stats.performance_count,
                      g_validation_stats.general_count);
    CARDINAL_LOG_INFO("[VALIDATION]   Filtered messages: %u", g_validation_stats.filtered_count);
}

#ifndef VK_EXT_layer_settings
    #define VK_EXT_LAYER_SETTINGS_EXTENSION_NAME "VK_EXT_layer_settings"
    #define VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT 1000396000

typedef enum VkLayerSettingTypeEXT {
    VK_LAYER_SETTING_TYPE_BOOL32_EXT = 0,
    VK_LAYER_SETTING_TYPE_INT32_EXT = 1,
    VK_LAYER_SETTING_TYPE_INT64_EXT = 2,
    VK_LAYER_SETTING_TYPE_FLOAT32_EXT = 3,
    VK_LAYER_SETTING_TYPE_FLOAT64_EXT = 4,
    VK_LAYER_SETTING_TYPE_STRING_EXT = 5,
    VK_LAYER_SETTING_TYPE_MAX_ENUM_EXT = 0x7FFFFFFF
} VkLayerSettingTypeEXT;

typedef struct VkLayerSettingEXT {
    const char* pLayerName;
    const char* pSettingName;
    VkLayerSettingTypeEXT type;
    uint32_t valueCount;
    const void* pValues;
} VkLayerSettingEXT;

typedef struct VkLayerSettingsCreateInfoEXT {
    VkStructureType sType;
    const void* pNext;
    uint32_t settingCount;
    const VkLayerSettingEXT* pSettings;
} VkLayerSettingsCreateInfoEXT;
#endif

/**
 * @brief Sets up the application info structure.
 */
static void setup_app_info(VkApplicationInfo* ai) {
    ai->sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    ai->pNext = NULL;
    ai->pApplicationName = "Cardinal";
    ai->applicationVersion = VK_MAKE_VERSION(1, 0, 0);
    ai->pEngineName = "Cardinal";
    ai->engineVersion = VK_MAKE_VERSION(1, 0, 0);
    ai->apiVersion = VK_MAKE_API_VERSION(0, 1, 4, 335);
    CARDINAL_LOG_INFO("[INSTANCE] Using Vulkan API version 1.4.335");
}

/**
 * @brief Prepares the list of instance extensions.
 * @param out_extensions Pointer to store the array of extensions.
 * @param out_count Pointer to store the extension count.
 * @return true if successful, false otherwise.
 */
static bool get_instance_extensions(const char*** out_extensions, uint32_t* out_count) {
    uint32_t glfw_count = 0;
    const char** glfw_exts = glfwGetRequiredInstanceExtensions(&glfw_count);

    if (!glfw_exts) {
        CARDINAL_LOG_INFO("[INSTANCE] GLFW instance extensions unavailable (headless or no GLFW)");
        // In headless, we might still need extensions, but for now we assume 0 if GLFW fails
        // or we could manually add VK_KHR_surface if needed, but GLFW usually handles this.
        *out_count = 0;
        *out_extensions = NULL;
        return true; // Not necessarily a failure if headless
    }

    CARDINAL_LOG_INFO("[INSTANCE] GLFW requires %u extensions", glfw_count);
    for (uint32_t i = 0; i < glfw_count; i++) {
        CARDINAL_LOG_INFO("[INSTANCE] GLFW extension %u: %s", i, glfw_exts[i]);
    }

    if (!validation_enabled()) {
        *out_extensions = glfw_exts;
        *out_count = glfw_count;
        return true;
    }

    // Add debug utils and layer settings extensions if validation is enabled
    bool need_debug_utils = true;
    for (uint32_t i = 0; i < glfw_count; ++i) {
        if (strcmp(glfw_exts[i], VK_EXT_DEBUG_UTILS_EXTENSION_NAME) == 0) {
            need_debug_utils = false;
            break;
        }
    }
    bool need_layer_settings = true; // Always try to add for configuration

    uint32_t extra_count = 0;
    if (need_debug_utils)
        extra_count++;
    if (need_layer_settings)
        extra_count++;

    if (extra_count == 0) {
        *out_extensions = glfw_exts;
        *out_count = glfw_count;
        return true;
    }

    const char** exts = (const char**)malloc(sizeof(char*) * (glfw_count + extra_count));
    if (!exts)
        return false;

    for (uint32_t i = 0; i < glfw_count; ++i)
        exts[i] = glfw_exts[i];

    uint32_t current = glfw_count;
    if (need_debug_utils) {
        exts[current++] = VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
        CARDINAL_LOG_INFO("[INSTANCE] Adding debug utils extension");
    }
    if (need_layer_settings) {
        exts[current++] = VK_EXT_LAYER_SETTINGS_EXTENSION_NAME;
        CARDINAL_LOG_INFO("[INSTANCE] Adding layer settings extension");
    }

    *out_extensions = exts;
    *out_count = glfw_count + extra_count;
    return true;
}

/**
 * @brief Configures validation layers and debug messenger.
 */
static void configure_validation(VkInstanceCreateInfo* ci, const char** layers,
                                 VkDebugUtilsMessengerCreateInfoEXT* debug_ci,
                                 VkLayerSettingsCreateInfoEXT* layer_settings_ci,
                                 VkLayerSettingEXT* settings) {
    if (!validation_enabled()) {
        ci->enabledLayerCount = 0;
        ci->ppEnabledLayerNames = NULL;
        return;
    }

    CARDINAL_LOG_INFO("[INSTANCE] Validation enabled - enabling validation layers");
    ci->enabledLayerCount = 1;
    ci->ppEnabledLayerNames = layers;
    CARDINAL_LOG_INFO("[INSTANCE] Enabling validation layer: %s", layers[0]);

    // Setup debug messenger
    debug_ci->sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
    debug_ci->messageSeverity = select_debug_severity_from_log_level();
    debug_ci->messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                            VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                            VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    debug_ci->pfnUserCallback = debug_callback;

    // Setup layer settings
    static VkBool32 legacy_detection = VK_TRUE;
    settings[0].pLayerName = "VK_LAYER_KHRONOS_validation";
    settings[0].pSettingName = "legacy_detection";
    settings[0].type = VK_LAYER_SETTING_TYPE_BOOL32_EXT;
    settings[0].valueCount = 1;
    settings[0].pValues = &legacy_detection;

    layer_settings_ci->sType = VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT;
    layer_settings_ci->pNext = debug_ci;
    layer_settings_ci->settingCount = 1;
    layer_settings_ci->pSettings = settings;

    ci->pNext = layer_settings_ci;

    CARDINAL_LOG_INFO("[INSTANCE] Debug messenger and legacy detection configured");
}

/**
 * @brief Creates the Vulkan instance.
 * @param s Vulkan state structure.
 * @return true on success, false on failure.
 */
bool vk_create_instance(VulkanState* s) {
    CARDINAL_LOG_INFO("[INSTANCE] Starting Vulkan instance creation");

    VkApplicationInfo ai;
    setup_app_info(&ai);

    const char** extensions = NULL;
    uint32_t extension_count = 0;
    if (!get_instance_extensions(&extensions, &extension_count)) {
        return false;
    }

    CARDINAL_LOG_INFO("[INSTANCE] Final extension count: %u", extension_count);
    for (uint32_t i = 0; i < extension_count; i++) {
        CARDINAL_LOG_INFO("[INSTANCE] Extension %u: %s", i,
                          extensions[i] ? extensions[i] : "(null)");
    }

    const char* layers[] = {"VK_LAYER_KHRONOS_validation"};
    VkInstanceCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ci.pApplicationInfo = &ai;
    ci.enabledExtensionCount = extension_count;
    ci.ppEnabledExtensionNames = extensions;

    // Stack allocated structs for pNext chain
    VkDebugUtilsMessengerCreateInfoEXT debug_ci = {0};
    VkLayerSettingsCreateInfoEXT layer_settings_ci = {0};
    VkLayerSettingEXT settings[1] = {0};

    configure_validation(&ci, layers, &debug_ci, &layer_settings_ci, settings);

    CARDINAL_LOG_INFO("[INSTANCE] Creating Vulkan instance...");
    VkResult result = vkCreateInstance(&ci, NULL, &s->context.instance);

    // Check if we allocated a custom extension array (different from GLFW's static one)
    // get_instance_extensions returns a malloc'd array if it added extra extensions
    // To check this robustly, we see if validation is enabled and extras were needed.
    // Simpler: if validation enabled, we likely malloc'd.
    // BUT `get_instance_extensions` returns `glfw_exts` (static from GLFW) if no extras added.
    // Let's just not free for now or add a flag.
    // Actually, `glfwGetRequiredInstanceExtensions` returns pointer to static array.
    // If we malloc'd, we should free.
    // Let's improve `get_instance_extensions` to return a flag or just handle it here.
    // Since I can't easily change the signature in the middle of this thought, I'll rely on the
    // logic: If validation enabled AND (debug utils OR layer settings added), then we malloc'd. A
    // cleaner way is to verify if extensions != glfwGetRequiredInstanceExtensions result. But I
    // don't want to call it again. I'll make a small fix: let's assume we leak the tiny array for
    // now OR fix it properly in a subsequent step if critical. Actually, I can check against the
    // pointer returned by glfw. Re-calling glfwGetRequiredInstanceExtensions is cheap (just returns
    // pointer).
    uint32_t dummy;
    const char** static_glfw_exts = glfwGetRequiredInstanceExtensions(&dummy);
    if (extensions && extensions != static_glfw_exts) {
        free((void*)extensions);
    }

    if (result != VK_SUCCESS) {
        CARDINAL_LOG_ERROR("[INSTANCE] vkCreateInstance failed with result: %d", result);
        return false;
    }
    CARDINAL_LOG_INFO("[INSTANCE] Instance creation result: %d", result);

    // Create persistent debug messenger if validation is enabled
    if (validation_enabled()) {
        PFN_vkCreateDebugUtilsMessengerEXT dfunc =
            (PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(
                s->context.instance, "vkCreateDebugUtilsMessengerEXT");
        if (dfunc) {
            dfunc(s->context.instance, &debug_ci, NULL, &s->context.debug_messenger);
        }
    }

    CARDINAL_LOG_INFO("[INSTANCE] Vulkan instance created successfully");
    return true;
}

/**
 * @brief Selects a suitable physical device.
 * @param s Vulkan state.
 * @return true if device selected, false otherwise.
 *
 * @todo Refactor to support multi-GPU selection with scoring.
 */
bool vk_pick_physical_device(VulkanState* s) {
    CARDINAL_LOG_INFO("[DEVICE] Starting physical device selection");
    uint32_t count = 0;
    VkResult result = vkEnumeratePhysicalDevices(s->context.instance, &count, NULL);
    CARDINAL_LOG_INFO("[DEVICE] Found %u physical devices, enumerate result: %d", count, result);
    (void)result; // silence unused in non-debug builds
    if (count == 0) {
        CARDINAL_LOG_ERROR("[DEVICE] No physical devices found!");
        return false;
    }
    VkPhysicalDevice* devices = (VkPhysicalDevice*)malloc(sizeof(VkPhysicalDevice) * count);
    result = vkEnumeratePhysicalDevices(s->context.instance, &count, devices);
    CARDINAL_LOG_INFO("[DEVICE] Enumerate devices result: %d", result);
    (void)result; // silence unused in non-debug builds
    s->context.physical_device = devices[0];

    // Log device properties
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(s->context.physical_device, &props);
    CARDINAL_LOG_INFO("[DEVICE] Selected device: %s (API %u.%u.%u, Driver %u.%u.%u)",
                      props.deviceName, VK_VERSION_MAJOR(props.apiVersion),
                      VK_VERSION_MINOR(props.apiVersion), VK_VERSION_PATCH(props.apiVersion),
                      VK_VERSION_MAJOR(props.driverVersion), VK_VERSION_MINOR(props.driverVersion),
                      VK_VERSION_PATCH(props.driverVersion));

    free(devices);
    return s->context.physical_device != VK_NULL_HANDLE;
}

/**
 * @brief Creates the logical Vulkan device.
 * @param s Vulkan state.
 * @return true on success, false on failure.
 *
 * @todo Improve queue family selection for dedicated transfer queues.
 */
bool vk_create_device(VulkanState* s) {
    CARDINAL_LOG_INFO("[DEVICE] Starting logical device creation");
    uint32_t qf_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(s->context.physical_device, &qf_count, NULL);
    CARDINAL_LOG_INFO("[DEVICE] Found %u queue families", qf_count);
    VkQueueFamilyProperties* qfp =
        (VkQueueFamilyProperties*)malloc(sizeof(VkQueueFamilyProperties) * qf_count);
    vkGetPhysicalDeviceQueueFamilyProperties(s->context.physical_device, &qf_count, qfp);

    s->context.graphics_queue_family = 0;
    for (uint32_t i = 0; i < qf_count; ++i) {
        if (qfp[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
            s->context.graphics_queue_family = i;
            break;
        }
    }
    CARDINAL_LOG_INFO("[DEVICE] Selected graphics family: %u", s->context.graphics_queue_family);

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qci.queueFamilyIndex = s->context.graphics_queue_family;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;

    // Query supported Vulkan API version
    VkPhysicalDeviceProperties physicalDeviceProperties;
    vkGetPhysicalDeviceProperties(s->context.physical_device, &physicalDeviceProperties);
    uint32_t apiVersion = physicalDeviceProperties.apiVersion;
    uint32_t majorVersion = VK_VERSION_MAJOR(apiVersion);
    uint32_t minorVersion = VK_VERSION_MINOR(apiVersion);
    CARDINAL_LOG_INFO("[DEVICE] Physical device supports Vulkan %u.%u.%u", majorVersion,
                      minorVersion, VK_VERSION_PATCH(apiVersion));

    // Require Vulkan 1.4 core support
    // Require Vulkan 1.4 as minimum - no fallbacks
    bool vulkan_14_supported = (majorVersion > 1) || (majorVersion == 1 && minorVersion >= 4);
    bool vulkan_12_supported = (majorVersion > 1) || (majorVersion == 1 && minorVersion >= 2);
    if (!vulkan_14_supported) {
        CARDINAL_LOG_ERROR("[DEVICE] Vulkan 1.4 core is required but not supported (found %u.%u)",
                           majorVersion, minorVersion);
        free(qfp);
        return false;
    }
    CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.4 core support confirmed");

    // Check for VK_KHR_maintenance8, VK_EXT_mesh_shader, VK_KHR_fragment_shading_rate,
    // VK_EXT_descriptor_indexing, and VK_EXT_descriptor_buffer extension availability
    uint32_t extension_count = 0;
    vkEnumerateDeviceExtensionProperties(s->context.physical_device, NULL, &extension_count, NULL);
    VkExtensionProperties* available_extensions =
        (VkExtensionProperties*)malloc(sizeof(VkExtensionProperties) * extension_count);
    vkEnumerateDeviceExtensionProperties(s->context.physical_device, NULL, &extension_count,
                                         available_extensions);

    bool maintenance8_available = false;
    bool mesh_shader_available = false;
    bool fragment_shading_rate_available = false;
    bool descriptor_indexing_available = false;
    bool descriptor_buffer_available = false;
    bool shader_quad_control_available = false;
    bool shader_maximal_reconvergence_available = false;
    for (uint32_t i = 0; i < extension_count; i++) {
        if (strcmp(available_extensions[i].extensionName, VK_KHR_MAINTENANCE_8_EXTENSION_NAME) ==
            0) {
            maintenance8_available = true;
            CARDINAL_LOG_INFO("[DEVICE] VK_KHR_maintenance8 extension available (spec version %u)",
                              available_extensions[i].specVersion);
        } else if (strcmp(available_extensions[i].extensionName,
                          VK_EXT_MESH_SHADER_EXTENSION_NAME) == 0) {
            mesh_shader_available = true;
            CARDINAL_LOG_INFO("[DEVICE] VK_EXT_mesh_shader extension available (spec version %u)",
                              available_extensions[i].specVersion);
        } else if (strcmp(available_extensions[i].extensionName,
                          VK_KHR_FRAGMENT_SHADING_RATE_EXTENSION_NAME) == 0) {
            fragment_shading_rate_available = true;
            CARDINAL_LOG_INFO(
                "[DEVICE] VK_KHR_fragment_shading_rate extension available (spec version %u)",
                available_extensions[i].specVersion);
        } else if (strcmp(available_extensions[i].extensionName,
                          VK_EXT_DESCRIPTOR_INDEXING_EXTENSION_NAME) == 0) {
            descriptor_indexing_available = true;
            CARDINAL_LOG_INFO(
                "[DEVICE] VK_EXT_descriptor_indexing extension available (spec version %u)",
                available_extensions[i].specVersion);
        } else if (strcmp(available_extensions[i].extensionName,
                          VK_EXT_DESCRIPTOR_BUFFER_EXTENSION_NAME) == 0) {
            descriptor_buffer_available = true;
            CARDINAL_LOG_INFO(
                "[DEVICE] VK_EXT_descriptor_buffer extension available (spec version %u)",
                available_extensions[i].specVersion);
        } else if (strcmp(available_extensions[i].extensionName,
                          VK_KHR_SHADER_QUAD_CONTROL_EXTENSION_NAME) == 0) {
            shader_quad_control_available = true;
            CARDINAL_LOG_INFO(
                "[DEVICE] VK_KHR_shader_quad_control extension available (spec version %u)",
                available_extensions[i].specVersion);
        } else if (strcmp(available_extensions[i].extensionName,
                          VK_KHR_SHADER_MAXIMAL_RECONVERGENCE_EXTENSION_NAME) == 0) {
            shader_maximal_reconvergence_available = true;
            CARDINAL_LOG_INFO("[DEVICE] VK_KHR_shader_maximal_reconvergence extension available "
                              "(spec version %u)",
                              available_extensions[i].specVersion);
        }
    }
    free(available_extensions);

    if (!maintenance8_available) {
        CARDINAL_LOG_INFO(
            "[DEVICE] VK_KHR_maintenance8 extension not available, using maintenance4 fallback");
    }

    if (!mesh_shader_available) {
        CARDINAL_LOG_INFO("[DEVICE] VK_EXT_mesh_shader extension not available, using traditional "
                          "vertex pipeline");
    }

    // Check mesh shader dependencies
    if (mesh_shader_available && !fragment_shading_rate_available) {
        CARDINAL_LOG_ERROR("[DEVICE] VK_EXT_mesh_shader requires VK_KHR_fragment_shading_rate but "
                           "it's not available");
        mesh_shader_available = false;
    }

    // Check shader quad control dependencies
    if (shader_quad_control_available && !shader_maximal_reconvergence_available) {
        CARDINAL_LOG_ERROR("[DEVICE] VK_KHR_shader_quad_control requires "
                           "VK_KHR_shader_maximal_reconvergence but it's not available");
        shader_quad_control_available = false;
    }

    // Build device extensions array
    const char* device_extensions[10] = {0};
    uint32_t enabled_extension_count = 0;

    if (!s->swapchain.headless_mode) {
        device_extensions[enabled_extension_count] = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
        enabled_extension_count++;
        CARDINAL_LOG_INFO("[DEVICE] Enabling VK_KHR_swapchain extension");
    }

    if (maintenance8_available) {
        device_extensions[enabled_extension_count] = VK_KHR_MAINTENANCE_8_EXTENSION_NAME;
        enabled_extension_count++;
        CARDINAL_LOG_INFO("[DEVICE] Enabling VK_KHR_maintenance8 extension");
    }

    if (mesh_shader_available) {
        device_extensions[enabled_extension_count] = VK_KHR_FRAGMENT_SHADING_RATE_EXTENSION_NAME;
        enabled_extension_count++;
        device_extensions[enabled_extension_count] = VK_EXT_MESH_SHADER_EXTENSION_NAME;
        enabled_extension_count++;
        CARDINAL_LOG_INFO(
            "[DEVICE] Enabling VK_KHR_fragment_shading_rate extension (required for mesh shaders)");
        CARDINAL_LOG_INFO("[DEVICE] Enabling VK_EXT_mesh_shader extension");
    }

    if (descriptor_indexing_available) {
        // VK_EXT_descriptor_indexing is promoted to core in Vulkan 1.2
        // We shouldn't enable the extension explicitly if we are using Vulkan 1.2+
        // However, we still need to enable the features in VkPhysicalDeviceVulkan12Features

        // device_extensions[enabled_extension_count] = VK_EXT_DESCRIPTOR_INDEXING_EXTENSION_NAME;
        // enabled_extension_count++;
        CARDINAL_LOG_INFO("[DEVICE] VK_EXT_descriptor_indexing available (promoted to Vulkan 1.2), "
                          "enabling features only");
    }

    if (descriptor_buffer_available) {
        device_extensions[enabled_extension_count] = VK_EXT_DESCRIPTOR_BUFFER_EXTENSION_NAME;
        enabled_extension_count++;
        CARDINAL_LOG_INFO("[DEVICE] Enabling VK_EXT_descriptor_buffer extension");
    }

    if (shader_maximal_reconvergence_available) {
        device_extensions[enabled_extension_count] =
            VK_KHR_SHADER_MAXIMAL_RECONVERGENCE_EXTENSION_NAME;
        enabled_extension_count++;
        CARDINAL_LOG_INFO("[DEVICE] Enabling VK_KHR_shader_maximal_reconvergence extension");
    }

    if (shader_quad_control_available) {
        device_extensions[enabled_extension_count] = VK_KHR_SHADER_QUAD_CONTROL_EXTENSION_NAME;
        enabled_extension_count++;
        CARDINAL_LOG_INFO("[DEVICE] Enabling VK_KHR_shader_quad_control extension");
    }

    // Setup feature chain: shader_quad_control -> shader_maximal_reconvergence -> descriptor_buffer
    // -> mesh_shader -> multiview -> fragment_shading_rate -> maintenance8 -> Vulkan 1.4 -> 1.3
    // -> 1.2
    VkPhysicalDeviceShaderQuadControlFeaturesKHR shaderQuadControlFeatures = {0};
    shaderQuadControlFeatures.sType =
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_QUAD_CONTROL_FEATURES_KHR;
    shaderQuadControlFeatures.pNext = NULL;

    VkPhysicalDeviceShaderMaximalReconvergenceFeaturesKHR shaderMaximalReconvergenceFeatures = {0};
    shaderMaximalReconvergenceFeatures.sType =
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_MAXIMAL_RECONVERGENCE_FEATURES_KHR;
    if (shader_quad_control_available) {
        shaderMaximalReconvergenceFeatures.pNext = (void*)&shaderQuadControlFeatures;
    } else {
        shaderMaximalReconvergenceFeatures.pNext = NULL;
    }

    VkPhysicalDeviceDescriptorBufferFeaturesEXT descriptorBufferFeatures = {0};
    descriptorBufferFeatures.sType =
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_FEATURES_EXT;
    if (shader_maximal_reconvergence_available) {
        descriptorBufferFeatures.pNext = (void*)&shaderMaximalReconvergenceFeatures;
    } else {
        descriptorBufferFeatures.pNext = NULL;
    }

    VkPhysicalDeviceMeshShaderFeaturesEXT meshShaderFeatures = {0};
    meshShaderFeatures.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT;
    if (descriptor_buffer_available) {
        meshShaderFeatures.pNext = (void*)&descriptorBufferFeatures;
    } else if (shader_maximal_reconvergence_available) {
        meshShaderFeatures.pNext = (void*)&shaderMaximalReconvergenceFeatures;
    } else {
        meshShaderFeatures.pNext = NULL;
    }

    // Required dependencies for mesh shaders
    VkPhysicalDeviceMultiviewFeatures multiviewFeatures = {0};
    multiviewFeatures.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MULTIVIEW_FEATURES;
    if (mesh_shader_available) {
        multiviewFeatures.pNext = (void*)&meshShaderFeatures;
    } else if (descriptor_buffer_available) {
        multiviewFeatures.pNext = (void*)&descriptorBufferFeatures;
    } else if (shader_maximal_reconvergence_available) {
        multiviewFeatures.pNext = (void*)&shaderMaximalReconvergenceFeatures;
    } else {
        multiviewFeatures.pNext = NULL;
    }

    VkPhysicalDeviceFragmentShadingRateFeaturesKHR fragmentShadingRateFeatures = {0};
    fragmentShadingRateFeatures.sType =
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADING_RATE_FEATURES_KHR;
    fragmentShadingRateFeatures.pNext = &multiviewFeatures;

    VkPhysicalDeviceMaintenance8FeaturesKHR maintenance8Features = {0};
    maintenance8Features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_8_FEATURES_KHR;
    maintenance8Features.pNext = (void*)&fragmentShadingRateFeatures;

    VkPhysicalDeviceVulkan14Features vulkan14Features = {0};
    vulkan14Features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES;
    vulkan14Features.pNext =
        maintenance8_available ? (void*)&maintenance8Features : (void*)&fragmentShadingRateFeatures;

    VkPhysicalDeviceVulkan13Features vulkan13Features = {0};
    vulkan13Features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
    vulkan13Features.pNext = &vulkan14Features;

    VkPhysicalDeviceVulkan12Features vulkan12Features = {0};
    vulkan12Features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
    vulkan12Features.pNext = &vulkan13Features;

    VkPhysicalDeviceFeatures2 deviceFeatures2 = {0};
    deviceFeatures2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    deviceFeatures2.pNext = &vulkan12Features;

    // Query available Vulkan 1.2, 1.3 and 1.4 features
    vkGetPhysicalDeviceFeatures2(s->context.physical_device, &deviceFeatures2);
    CARDINAL_LOG_INFO("[DEVICE] Queried Vulkan 1.2, 1.3 and 1.4 features");

    // Query subgroup properties (Vulkan 1.1 core)
    VkPhysicalDeviceSubgroupProperties subgroupProperties = {0};
    subgroupProperties.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES;

    VkPhysicalDeviceProperties2 props2 = {0};
    props2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    props2.pNext = &subgroupProperties;
    vkGetPhysicalDeviceProperties2(s->context.physical_device, &props2);

    CARDINAL_LOG_INFO(
        "[DEVICE] Subgroup properties: size=%u, supportedStages=0x%x, supportedOperations=0x%x",
        subgroupProperties.subgroupSize, subgroupProperties.supportedStages,
        subgroupProperties.supportedOperations);

    // Check if subgroup ballot operations are supported (required for task.task shader)
    if (!(subgroupProperties.supportedOperations & VK_SUBGROUP_FEATURE_BALLOT_BIT)) {
        CARDINAL_LOG_ERROR(
            "[DEVICE] Subgroup ballot operations are required but not supported by device");
        free(qfp);
        return false;
    }
    CARDINAL_LOG_INFO("[DEVICE] Subgroup ballot operations: supported");

    // Require all essential Vulkan 1.3 features - no conditionals
    if (!vulkan13Features.dynamicRendering) {
        CARDINAL_LOG_ERROR("[DEVICE] dynamicRendering is required but not supported by device");
        free(qfp);
        return false;
    }
    if (!vulkan13Features.synchronization2) {
        CARDINAL_LOG_ERROR("[DEVICE] synchronization2 is required but not supported by device");
        free(qfp);
        return false;
    }
    if (!vulkan13Features.maintenance4) {
        CARDINAL_LOG_ERROR("[DEVICE] maintenance4 is required but not supported by device");
        free(qfp);
        return false;
    }

    // Check maintenance8 features if extension is available
    if (maintenance8_available) {
        CARDINAL_LOG_INFO("[DEVICE] Checking VK_KHR_maintenance8 features");
        // maintenance8 provides: better synchronization, depth/stencil copies, 64 additional access
        // flags All maintenance8 features are optional, so we enable what's available
    }

    // Check mesh shader features if extension is available
    if (mesh_shader_available) {
        CARDINAL_LOG_INFO("[DEVICE] Checking VK_EXT_mesh_shader features");
        if (!meshShaderFeatures.meshShader) {
            CARDINAL_LOG_ERROR(
                "[DEVICE] meshShader feature is required but not supported by device");
            free(qfp);
            return false;
        }
        if (!meshShaderFeatures.taskShader) {
            CARDINAL_LOG_INFO("[DEVICE] taskShader feature not supported, mesh shaders will run "
                              "without task stage");
        }
    }

    // Check descriptor indexing features if extension is available (now part of Vulkan 1.2)
    if (descriptor_indexing_available) {
        CARDINAL_LOG_INFO("[DEVICE] Checking VK_EXT_descriptor_indexing features (via Vulkan 1.2)");
        if (!vulkan12Features.descriptorBindingVariableDescriptorCount) {
            CARDINAL_LOG_ERROR("[DEVICE] descriptorBindingVariableDescriptorCount is required but "
                               "not supported by device");
            free(qfp);
            return false;
        }
        if (!vulkan12Features.descriptorBindingSampledImageUpdateAfterBind) {
            CARDINAL_LOG_ERROR("[DEVICE] descriptorBindingSampledImageUpdateAfterBind is required "
                               "but not supported by device");
            free(qfp);
            return false;
        }
        if (!vulkan12Features.shaderSampledImageArrayNonUniformIndexing) {
            CARDINAL_LOG_ERROR("[DEVICE] shaderSampledImageArrayNonUniformIndexing is required but "
                               "not supported by device");
            free(qfp);
            return false;
        }
        if (!vulkan12Features.runtimeDescriptorArray) {
            CARDINAL_LOG_ERROR(
                "[DEVICE] runtimeDescriptorArray is required but not supported by device");
            free(qfp);
            return false;
        }
    }

    // Check descriptor buffer features if extension is available
    if (descriptor_buffer_available) {
        CARDINAL_LOG_INFO("[DEVICE] Checking VK_EXT_descriptor_buffer features");
        if (!descriptorBufferFeatures.descriptorBuffer) {
            CARDINAL_LOG_ERROR(
                "[DEVICE] descriptorBuffer feature is required but not supported by device");
            free(qfp);
            return false;
        }
        if (!descriptorBufferFeatures.descriptorBufferImageLayoutIgnored) {
            CARDINAL_LOG_INFO("[DEVICE] descriptorBufferImageLayoutIgnored not supported, will "
                              "need to manage image layouts manually");
        }
        if (!descriptorBufferFeatures.descriptorBufferPushDescriptors) {
            CARDINAL_LOG_INFO("[DEVICE] descriptorBufferPushDescriptors not supported, will use "
                              "regular descriptor buffers only");
        }
    }

    if (!vulkan12Features.bufferDeviceAddress) {
        CARDINAL_LOG_ERROR("[DEVICE] bufferDeviceAddress is required but not supported by device");
        free(qfp);
        return false;
    }

    // Enable all required Vulkan 1.2 features
    vulkan12Features.bufferDeviceAddress = VK_TRUE;

    // Enable all required Vulkan 1.3 features
    vulkan13Features.dynamicRendering = VK_TRUE;
    vulkan13Features.synchronization2 = VK_TRUE;
    vulkan13Features.maintenance4 = VK_TRUE;

    // Enable maintenance8 features if extension is available
    if (maintenance8_available) {
        // Enable all available maintenance8 features for enhanced functionality
        maintenance8Features.maintenance8 = VK_TRUE;
        CARDINAL_LOG_INFO("[DEVICE] VK_KHR_maintenance8 features enabled");
    }

    // Enable mesh shader features if extension is available
    if (mesh_shader_available) {
        // Enable required dependencies first
        multiviewFeatures.multiview = VK_TRUE;
        fragmentShadingRateFeatures.primitiveFragmentShadingRate = VK_TRUE;

        // Enable mesh shader features
        meshShaderFeatures.meshShader = VK_TRUE;
        if (meshShaderFeatures.taskShader) {
            meshShaderFeatures.taskShader = VK_TRUE;
            CARDINAL_LOG_INFO("[DEVICE] VK_EXT_mesh_shader features enabled: meshShader + "
                              "taskShader (with dependencies)");
        } else {
            CARDINAL_LOG_INFO("[DEVICE] VK_EXT_mesh_shader features enabled: meshShader only (with "
                              "dependencies)");
        }
        CARDINAL_LOG_INFO(
            "[DEVICE] Enabled mesh shader dependencies: multiview + primitiveFragmentShadingRate");
    }

    // Enable descriptor indexing features if extension is available (now part of Vulkan 1.2)
    if (descriptor_indexing_available) {
        // Enable all required descriptor indexing features for bindless textures
        vulkan12Features.descriptorBindingVariableDescriptorCount = VK_TRUE;
        vulkan12Features.descriptorBindingSampledImageUpdateAfterBind = VK_TRUE;
        vulkan12Features.shaderSampledImageArrayNonUniformIndexing = VK_TRUE;
        vulkan12Features.runtimeDescriptorArray = VK_TRUE;
        vulkan12Features.descriptorBindingPartiallyBound = VK_TRUE;
        vulkan12Features.shaderUniformBufferArrayNonUniformIndexing = VK_TRUE;
        vulkan12Features.shaderStorageBufferArrayNonUniformIndexing = VK_TRUE;
        vulkan12Features.shaderStorageImageArrayNonUniformIndexing = VK_TRUE;
        CARDINAL_LOG_INFO("[DEVICE] VK_EXT_descriptor_indexing features enabled via Vulkan 1.2: "
                          "bindless textures + update-after-bind + non-uniform indexing");
    }

    // Enable descriptor buffer features if extension is available
    if (descriptor_buffer_available) {
        // Enable core descriptor buffer functionality
        descriptorBufferFeatures.descriptorBuffer = VK_TRUE;

        // Enable optional features if supported
        if (descriptorBufferFeatures.descriptorBufferImageLayoutIgnored) {
            descriptorBufferFeatures.descriptorBufferImageLayoutIgnored = VK_TRUE;
            CARDINAL_LOG_INFO("[DEVICE] VK_EXT_descriptor_buffer features enabled: "
                              "descriptorBuffer + descriptorBufferImageLayoutIgnored");
        } else {
            CARDINAL_LOG_INFO(
                "[DEVICE] VK_EXT_descriptor_buffer features enabled: descriptorBuffer only");
        }

        if (descriptorBufferFeatures.descriptorBufferPushDescriptors) {
            descriptorBufferFeatures.descriptorBufferPushDescriptors = VK_TRUE;
            CARDINAL_LOG_INFO("[DEVICE] VK_EXT_descriptor_buffer push descriptors enabled");
        }
    }

    // Enable shader quad control features if extension is available
    if (shader_quad_control_available) {
        CARDINAL_LOG_INFO("[DEVICE] Checking VK_KHR_shader_quad_control features");
        if (!shaderQuadControlFeatures.shaderQuadControl) {
            CARDINAL_LOG_ERROR(
                "[DEVICE] shaderQuadControl feature is required but not supported by device");
            free(qfp);
            return false;
        }

        // Enable shader quad control functionality
        shaderQuadControlFeatures.shaderQuadControl = VK_TRUE;
        CARDINAL_LOG_INFO(
            "[DEVICE] VK_KHR_shader_quad_control features enabled: shaderQuadControl");
    }

    // Enable shader maximal reconvergence features if extension is available
    if (shader_maximal_reconvergence_available) {
        // Enable shader maximal reconvergence functionality
        shaderMaximalReconvergenceFeatures.shaderMaximalReconvergence = VK_TRUE;
        CARDINAL_LOG_INFO("[DEVICE] VK_KHR_shader_maximal_reconvergence features enabled: "
                          "shaderMaximalReconvergence");
    }

    // Enable useful Vulkan 1.4 features if available
    if (vulkan14Features.globalPriorityQuery) {
        vulkan14Features.globalPriorityQuery = VK_TRUE;
        CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.4 globalPriorityQuery: enabled");
    }
    if (vulkan14Features.shaderSubgroupRotate) {
        vulkan14Features.shaderSubgroupRotate = VK_TRUE;
        CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.4 shaderSubgroupRotate: enabled");
    }
    if (vulkan14Features.shaderFloatControls2) {
        vulkan14Features.shaderFloatControls2 = VK_TRUE;
        CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.4 shaderFloatControls2: enabled");
    }
    if (vulkan14Features.shaderExpectAssume) {
        vulkan14Features.shaderExpectAssume = VK_TRUE;
        CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.4 shaderExpectAssume: enabled");
    }

    // Log enabled feature status
    CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.2 feature status:");
    CARDINAL_LOG_INFO("[DEVICE]   bufferDeviceAddress: enabled");
    CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.3 feature status:");
    CARDINAL_LOG_INFO("[DEVICE]   synchronization2: enabled");
    CARDINAL_LOG_INFO("[DEVICE]   maintenance4: enabled (TODO: upgrade to maintenance8 extension)");
    CARDINAL_LOG_INFO("[DEVICE]   dynamicRendering: enabled");

    CARDINAL_LOG_INFO("[DEVICE] Enabling required Vulkan 1.2 features: bufferDeviceAddress");
    CARDINAL_LOG_INFO("[DEVICE] Enabling required Vulkan 1.3 features: dynamicRendering + "
                      "synchronization2 + maintenance4");
    if (maintenance8_available) {
        CARDINAL_LOG_INFO("[DEVICE] Enabling VK_KHR_maintenance8 extension features");
    }
    CARDINAL_LOG_INFO("[DEVICE] Enabling optional Vulkan 1.4 features where available");

    // Set up device creation with complete feature chain
    deviceFeatures2.pNext = &vulkan12Features;

    VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = enabled_extension_count;
    dci.ppEnabledExtensionNames = device_extensions;
    dci.pNext = &deviceFeatures2;

    CARDINAL_LOG_INFO("[DEVICE] Enabling %u device extension(s)", dci.enabledExtensionCount);
    for (uint32_t i = 0; i < dci.enabledExtensionCount; ++i) {
        CARDINAL_LOG_INFO("[DEVICE] Device extension %u: %s", i, device_extensions[i]);
    }

    VkResult result = vkCreateDevice(s->context.physical_device, &dci, NULL, &s->context.device);
    CARDINAL_LOG_INFO("[DEVICE] Device creation result: %d", result);
    free(qfp);
    if (result != VK_SUCCESS) {
        return false;
    }

    vkGetDeviceQueue(s->context.device, s->context.graphics_queue_family, 0,
                     &s->context.graphics_queue);
    CARDINAL_LOG_INFO("[DEVICE] Retrieved graphics queue");
    s->context.present_queue_family = s->context.graphics_queue_family;
    s->context.present_queue = s->context.graphics_queue;

    // Set dynamic rendering support flag and version feature flags
    s->context.supports_dynamic_rendering = true; // required
    s->context.supports_vulkan_12_features = vulkan_12_supported;
    s->context.supports_vulkan_13_features = true;                           // required
    s->context.supports_vulkan_14_features = true;                           // required
    s->context.supports_maintenance4 = true;                                 // required
    s->context.supports_maintenance8 = maintenance8_available;               // optional extension
    s->context.supports_mesh_shader = mesh_shader_available;                 // optional extension
    s->context.supports_descriptor_indexing = descriptor_indexing_available; // optional extension
    s->context.supports_descriptor_buffer = descriptor_buffer_available;     // optional extension
    s->context.descriptor_buffer_extension_available =
        descriptor_buffer_available; // for descriptor buffer utils
    s->context.supports_shader_quad_control = shader_quad_control_available; // optional extension
    s->context.supports_shader_maximal_reconvergence =
        shader_maximal_reconvergence_available;       // optional extension
    s->context.supports_buffer_device_address = true; // required
    CARDINAL_LOG_INFO("[DEVICE] Dynamic rendering support: enabled (required)");
    CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.2 features: %s",
                      s->context.supports_vulkan_12_features ? "available" : "unavailable");
    CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.3 features: available (required)");
    CARDINAL_LOG_INFO("[DEVICE] Vulkan 1.3 maintenance4: enabled (required)");
    CARDINAL_LOG_INFO("[DEVICE] VK_KHR_maintenance8: %s",
                      s->context.supports_maintenance8 ? "enabled" : "not available");
    CARDINAL_LOG_INFO("[DEVICE] VK_EXT_mesh_shader: %s",
                      s->context.supports_mesh_shader ? "enabled" : "not available");
    CARDINAL_LOG_INFO("[DEVICE] VK_EXT_descriptor_indexing: %s",
                      s->context.supports_descriptor_indexing ? "enabled" : "not available");
    CARDINAL_LOG_INFO("[DEVICE] VK_EXT_descriptor_buffer: %s",
                      s->context.supports_descriptor_buffer ? "enabled" : "not available");
    CARDINAL_LOG_INFO("[DEVICE] VK_KHR_shader_quad_control: %s",
                      s->context.supports_shader_quad_control ? "enabled" : "not available");
    CARDINAL_LOG_INFO("[DEVICE] VK_KHR_shader_maximal_reconvergence: %s",
                      s->context.supports_shader_maximal_reconvergence ? "enabled"
                                                                       : "not available");
    CARDINAL_LOG_INFO("[DEVICE] Buffer device address: enabled (required)");

    // Load dynamic rendering function pointers (core)
    s->context.vkCmdBeginRendering =
        (PFN_vkCmdBeginRendering)vkGetDeviceProcAddr(s->context.device, "vkCmdBeginRendering");
    s->context.vkCmdEndRendering =
        (PFN_vkCmdEndRendering)vkGetDeviceProcAddr(s->context.device, "vkCmdEndRendering");
    CARDINAL_LOG_INFO("[DEVICE] Loaded vkCmdBeginRendering: %p, vkCmdEndRendering: %p",
                      (void*)s->context.vkCmdBeginRendering, (void*)s->context.vkCmdEndRendering);

    // Load synchronization2 function pointer (core)
    s->context.vkCmdPipelineBarrier2 =
        (PFN_vkCmdPipelineBarrier2)vkGetDeviceProcAddr(s->context.device, "vkCmdPipelineBarrier2");
    if (!s->context.vkCmdPipelineBarrier2) {
        CARDINAL_LOG_ERROR("[DEVICE] Failed to load vkCmdPipelineBarrier2 (required)");
        free(qfp);
        return false;
    }
    CARDINAL_LOG_INFO("[DEVICE] Synchronization2 function loaded (vkCmdPipelineBarrier2)");

    // Load maintenance4 core functions (Vulkan 1.3): vkGetDeviceBufferMemoryRequirements /
    // vkGetDeviceImageMemoryRequirements
    s->context.vkGetDeviceBufferMemoryRequirements =
        (PFN_vkGetDeviceBufferMemoryRequirements)vkGetDeviceProcAddr(
            s->context.device, "vkGetDeviceBufferMemoryRequirements");
    s->context.vkGetDeviceImageMemoryRequirements =
        (PFN_vkGetDeviceImageMemoryRequirements)vkGetDeviceProcAddr(
            s->context.device, "vkGetDeviceImageMemoryRequirements");
    if (!s->context.vkGetDeviceBufferMemoryRequirements ||
        !s->context.vkGetDeviceImageMemoryRequirements) {
        CARDINAL_LOG_ERROR("[DEVICE] Failed to load maintenance4 functions (required)");
        free(qfp);
        return false;
    }
    CARDINAL_LOG_INFO("[DEVICE] maintenance4 functions loaded: BufferReqs=%p ImageReqs=%p",
                      (void*)s->context.vkGetDeviceBufferMemoryRequirements,
                      (void*)s->context.vkGetDeviceImageMemoryRequirements);

    // Load maintenance4 extension functions (these are the actual memory requirement functions)
    // Note: These functions are from VK_KHR_maintenance4, not maintenance8
    // They are promoted to core in Vulkan 1.3, so we try both core and KHR versions
    s->context.vkGetDeviceBufferMemoryRequirementsKHR =
        (PFN_vkGetDeviceBufferMemoryRequirementsKHR)vkGetDeviceProcAddr(
            s->context.device, "vkGetDeviceBufferMemoryRequirements");
    if (!s->context.vkGetDeviceBufferMemoryRequirementsKHR) {
        s->context.vkGetDeviceBufferMemoryRequirementsKHR =
            (PFN_vkGetDeviceBufferMemoryRequirementsKHR)vkGetDeviceProcAddr(
                s->context.device, "vkGetDeviceBufferMemoryRequirementsKHR");
    }

    s->context.vkGetDeviceImageMemoryRequirementsKHR =
        (PFN_vkGetDeviceImageMemoryRequirementsKHR)vkGetDeviceProcAddr(
            s->context.device, "vkGetDeviceImageMemoryRequirements");
    if (!s->context.vkGetDeviceImageMemoryRequirementsKHR) {
        s->context.vkGetDeviceImageMemoryRequirementsKHR =
            (PFN_vkGetDeviceImageMemoryRequirementsKHR)vkGetDeviceProcAddr(
                s->context.device, "vkGetDeviceImageMemoryRequirementsKHR");
    }

    if (s->context.vkGetDeviceBufferMemoryRequirementsKHR &&
        s->context.vkGetDeviceImageMemoryRequirementsKHR) {
        CARDINAL_LOG_INFO(
            "[DEVICE] Device memory requirement functions loaded: BufferReqs=%p ImageReqs=%p",
            (void*)s->context.vkGetDeviceBufferMemoryRequirementsKHR,
            (void*)s->context.vkGetDeviceImageMemoryRequirementsKHR);
    } else {
        CARDINAL_LOG_WARN(
            "[DEVICE] Failed to load device memory requirement functions, using fallback");
        s->context.vkGetDeviceBufferMemoryRequirementsKHR = NULL;
        s->context.vkGetDeviceImageMemoryRequirementsKHR = NULL;
    }

    // Load vkQueueSubmit2 (core)
    s->context.vkQueueSubmit2 =
        (PFN_vkQueueSubmit2)vkGetDeviceProcAddr(s->context.device, "vkQueueSubmit2");
    if (!s->context.vkQueueSubmit2) {
        CARDINAL_LOG_ERROR("[DEVICE] Failed to load vkQueueSubmit2 (required)");
        free(qfp);
        return false;
    }
    CARDINAL_LOG_INFO("[DEVICE] Loaded vkQueueSubmit2: %p", (void*)s->context.vkQueueSubmit2);

    // Load timeline semaphore function pointers (Vulkan 1.3 core - guaranteed available)
    s->context.vkWaitSemaphores =
        (PFN_vkWaitSemaphores)vkGetDeviceProcAddr(s->context.device, "vkWaitSemaphores");
    s->context.vkSignalSemaphore =
        (PFN_vkSignalSemaphore)vkGetDeviceProcAddr(s->context.device, "vkSignalSemaphore");
    s->context.vkGetSemaphoreCounterValue = (PFN_vkGetSemaphoreCounterValue)vkGetDeviceProcAddr(
        s->context.device, "vkGetSemaphoreCounterValue");

    CARDINAL_LOG_INFO("[DEVICE] Timeline semaphore functions loaded: vkWaitSemaphores=%p, "
                      "vkSignalSemaphore=%p, vkGetSemaphoreCounterValue=%p",
                      (void*)s->context.vkWaitSemaphores, (void*)s->context.vkSignalSemaphore,
                      (void*)s->context.vkGetSemaphoreCounterValue);

    // Load buffer device address function pointer (Vulkan 1.2 core, required in 1.3)
    s->context.vkGetBufferDeviceAddress = (PFN_vkGetBufferDeviceAddress)vkGetDeviceProcAddr(
        s->context.device, "vkGetBufferDeviceAddress");
    if (!s->context.vkGetBufferDeviceAddress) {
        CARDINAL_LOG_ERROR("[DEVICE] Failed to load vkGetBufferDeviceAddress (required)");
        return false;
    }
    CARDINAL_LOG_INFO("[DEVICE] Buffer device address function loaded: vkGetBufferDeviceAddress=%p",
                      (void*)s->context.vkGetBufferDeviceAddress);

    // Load VK_EXT_descriptor_buffer function pointers (if available)
    if (descriptor_buffer_available) {
        s->context.vkGetDescriptorSetLayoutSizeEXT =
            (PFN_vkGetDescriptorSetLayoutSizeEXT)vkGetDeviceProcAddr(
                s->context.device, "vkGetDescriptorSetLayoutSizeEXT");
        s->context.vkGetDescriptorSetLayoutBindingOffsetEXT =
            (PFN_vkGetDescriptorSetLayoutBindingOffsetEXT)vkGetDeviceProcAddr(
                s->context.device, "vkGetDescriptorSetLayoutBindingOffsetEXT");
        s->context.vkGetDescriptorEXT =
            (PFN_vkGetDescriptorEXT)vkGetDeviceProcAddr(s->context.device, "vkGetDescriptorEXT");
        s->context.vkCmdBindDescriptorBuffersEXT =
            (PFN_vkCmdBindDescriptorBuffersEXT)vkGetDeviceProcAddr(s->context.device,
                                                                   "vkCmdBindDescriptorBuffersEXT");
        s->context.vkCmdSetDescriptorBufferOffsetsEXT =
            (PFN_vkCmdSetDescriptorBufferOffsetsEXT)vkGetDeviceProcAddr(
                s->context.device, "vkCmdSetDescriptorBufferOffsetsEXT");
        s->context.vkCmdBindDescriptorBufferEmbeddedSamplersEXT =
            (PFN_vkCmdBindDescriptorBufferEmbeddedSamplersEXT)vkGetDeviceProcAddr(
                s->context.device, "vkCmdBindDescriptorBufferEmbeddedSamplersEXT");
        s->context.vkGetBufferOpaqueCaptureDescriptorDataEXT =
            (PFN_vkGetBufferOpaqueCaptureDescriptorDataEXT)vkGetDeviceProcAddr(
                s->context.device, "vkGetBufferOpaqueCaptureDescriptorDataEXT");
        s->context.vkGetImageOpaqueCaptureDescriptorDataEXT =
            (PFN_vkGetImageOpaqueCaptureDescriptorDataEXT)vkGetDeviceProcAddr(
                s->context.device, "vkGetImageOpaqueCaptureDescriptorDataEXT");
        s->context.vkGetImageViewOpaqueCaptureDescriptorDataEXT =
            (PFN_vkGetImageViewOpaqueCaptureDescriptorDataEXT)vkGetDeviceProcAddr(
                s->context.device, "vkGetImageViewOpaqueCaptureDescriptorDataEXT");
        s->context.vkGetSamplerOpaqueCaptureDescriptorDataEXT =
            (PFN_vkGetSamplerOpaqueCaptureDescriptorDataEXT)vkGetDeviceProcAddr(
                s->context.device, "vkGetSamplerOpaqueCaptureDescriptorDataEXT");

        if (s->context.vkGetDescriptorSetLayoutSizeEXT &&
            s->context.vkGetDescriptorSetLayoutBindingOffsetEXT && s->context.vkGetDescriptorEXT &&
            s->context.vkCmdBindDescriptorBuffersEXT &&
            s->context.vkCmdSetDescriptorBufferOffsetsEXT) {
            CARDINAL_LOG_INFO("[DEVICE] VK_EXT_descriptor_buffer functions loaded successfully");
            s->context.supports_descriptor_buffer = true;

            // Get descriptor buffer properties
            VkPhysicalDeviceDescriptorBufferPropertiesEXT desc_buffer_props = {
                .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT};

            VkPhysicalDeviceProperties2 descriptorBufferProps2 = {
                .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
                .pNext = &desc_buffer_props};

            vkGetPhysicalDeviceProperties2(s->context.physical_device, &descriptorBufferProps2);
            s->context.descriptor_buffer_uniform_buffer_size =
                desc_buffer_props.uniformBufferDescriptorSize;
            s->context.descriptor_buffer_combined_image_sampler_size =
                desc_buffer_props.combinedImageSamplerDescriptorSize;

            CARDINAL_LOG_INFO(
                "[DEVICE] Descriptor buffer sizes: UBO=%llu, CombinedImageSampler=%llu",
                (unsigned long long)s->context.descriptor_buffer_uniform_buffer_size,
                (unsigned long long)s->context.descriptor_buffer_combined_image_sampler_size);
        } else {
            CARDINAL_LOG_WARN("[DEVICE] Failed to load some VK_EXT_descriptor_buffer functions");
            s->context.supports_descriptor_buffer = false;
        }
    } else {
        s->context.supports_descriptor_buffer = false;
    }

    // Initialize unified Vulkan allocator
    if (!vk_allocator_init(
            &s->allocator, s->context.physical_device, s->context.device,
            s->context.vkGetDeviceBufferMemoryRequirements,
            s->context.vkGetDeviceImageMemoryRequirements, s->context.vkGetBufferDeviceAddress,
            s->context.vkGetDeviceBufferMemoryRequirementsKHR,
            s->context.vkGetDeviceImageMemoryRequirementsKHR, s->context.supports_maintenance8)) {
        CARDINAL_LOG_ERROR("[DEVICE] Failed to initialize VulkanAllocator");
        return false;
    }
    CARDINAL_LOG_INFO("[DEVICE] VulkanAllocator initialized (maintenance4=required, "
                      "maintenance8=%s, buffer device "
                      "address=enabled)",
                      s->context.supports_maintenance8 ? "enabled" : "not available");

    return true;
}

bool vk_create_surface(VulkanState* s, struct CardinalWindow* window) {
    CARDINAL_LOG_INFO("[SURFACE] Creating surface from window");
    VkWin32SurfaceCreateInfoKHR sci = {.sType = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR};
    sci.hinstance = GetModuleHandle(NULL);
    sci.hwnd = (HWND)cardinal_window_get_native_handle(window);
    VkResult result = vkCreateWin32SurfaceKHR(s->context.instance, &sci, NULL, &s->context.surface);
    CARDINAL_LOG_INFO("[SURFACE] Surface create result: %d", result);
    return result == VK_SUCCESS;
}

void vk_destroy_device_objects(VulkanState* s) {
    CARDINAL_LOG_INFO("[DESTROY] Destroying device objects and cleanup");
    if (s->context.device) {
        vkDeviceWaitIdle(s->context.device);
    }

    // Shutdown Vulkan allocator before destroying device
    vk_allocator_shutdown(&s->allocator);

    if (s->context.device) {
        vkDestroyDevice(s->context.device, NULL);
        s->context.device = VK_NULL_HANDLE;
    }
    if (s->context.debug_messenger) {
        PFN_vkDestroyDebugUtilsMessengerEXT dfunc =
            (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(
                s->context.instance, "vkDestroyDebugUtilsMessengerEXT");
        if (dfunc) {
            dfunc(s->context.instance, s->context.debug_messenger, NULL);
        }
        s->context.debug_messenger = VK_NULL_HANDLE;
    }
    if (s->context.surface) {
        vkDestroySurfaceKHR(s->context.instance, s->context.surface, NULL);
        s->context.surface = VK_NULL_HANDLE;
    }
    if (s->context.instance) {
        vkDestroyInstance(s->context.instance, NULL);
        s->context.instance = VK_NULL_HANDLE;
    }
}

void vk_recreate_debug_messenger(VulkanState* s) {
    if (!s || !s->context.instance)
        return;
    if (!validation_enabled())
        return;
    // Destroy existing messenger if any
    if (s->context.debug_messenger) {
        PFN_vkDestroyDebugUtilsMessengerEXT dfunc =
            (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(
                s->context.instance, "vkDestroyDebugUtilsMessengerEXT");
        if (dfunc) {
            dfunc(s->context.instance, s->context.debug_messenger, NULL);
        }
        s->context.debug_messenger = VK_NULL_HANDLE;
    }
    PFN_vkCreateDebugUtilsMessengerEXT cfunc =
        (PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(s->context.instance,
                                                                  "vkCreateDebugUtilsMessengerEXT");
    if (cfunc) {
        VkDebugUtilsMessengerCreateInfoEXT ci = {
            .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT};
        ci.messageSeverity = select_debug_severity_from_log_level();
        ci.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                         VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                         VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
        ci.pfnUserCallback = debug_callback;
        VkResult r = cfunc(s->context.instance, &ci, NULL, &s->context.debug_messenger);
        CARDINAL_LOG_INFO(
            "[INSTANCE] Recreated debug messenger (result=%d) with severity flags: 0x%x", r,
            ci.messageSeverity);
        (void)r; // silence unused in non-debug builds
    }
}
