const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const window = @import("../core/window.zig");
const types = @import("vulkan_types.zig");
const vk_allocator = @import("vulkan_allocator.zig");

const c = @import("vulkan_c.zig").c;

// Validation statistics
var g_validation_stats = std.mem.zeroes(types.ValidationStats);

// Helper to filter messages
fn should_filter_message(message_id: i32, message_id_name: ?[*:0]const u8) bool {
    _ = message_id;
    if (message_id_name) |name| {
        // Layer version warnings
        if (c.strstr(name, "Loader-Message") != null and c.strstr(name, "older than") != null) {
            return true;
        }
        // Swapchain recreation messages
        if (c.strstr(name, "SWAPCHAIN") != null and c.strstr(name, "out of date") != null) {
            return true;
        }
    }
    return false;
}

fn get_message_type_string(message_type: c.VkDebugUtilsMessageTypeFlagsEXT) []const u8 {
    if ((message_type & c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT) != 0) {
        return "PERFORMANCE";
    } else if ((message_type & c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT) != 0) {
        return "VALIDATION";
    } else if ((message_type & c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT) != 0) {
        return "GENERAL";
    }
    return "UNKNOWN";
}

fn get_severity_string(message_severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT) []const u8 {
    if ((message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) != 0)
        return "ERROR";
    if ((message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) != 0)
        return "WARNING";
    if ((message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT) != 0)
        return "INFO";
    if ((message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT) != 0)
        return "VERBOSE";
    return "UNKNOWN";
}

fn debug_callback(
    message_severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
    message_type: c.VkDebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const c.VkDebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque
) callconv(.c) c.VkBool32 {
    _ = user_data;

    g_validation_stats.total_messages += 1;

    if ((message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) != 0)
        g_validation_stats.error_count += 1
    else if ((message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) != 0)
        g_validation_stats.warning_count += 1
    else if ((message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT) != 0)
        g_validation_stats.info_count += 1;

    if ((message_type & c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT) != 0)
        g_validation_stats.performance_count += 1
    else if ((message_type & c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT) != 0)
        g_validation_stats.validation_count += 1
    else if ((message_type & c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT) != 0)
        g_validation_stats.general_count += 1;

    const severity_str = get_severity_string(message_severity);
    const type_str = get_message_type_string(message_type);

    const msg_id_name = if (callback_data != null and callback_data.?.pMessageIdName != null) callback_data.?.pMessageIdName else @as([*c]const u8, "(no-id)");
    const msg_id_num = if (callback_data != null) callback_data.?.messageIdNumber else -1;
    const message = if (callback_data != null and callback_data.?.pMessage != null) callback_data.?.pMessage else @as([*c]const u8, "(null)");

    if (should_filter_message(msg_id_num, msg_id_name)) {
        g_validation_stats.filtered_count += 1;
        return c.VK_FALSE;
    }

    var buffer: [1400]u8 = undefined;
    _ = c.snprintf(&buffer, 1400, "VK_DEBUG [%s|%s] (%d:%s): %s", severity_str.ptr, type_str.ptr, msg_id_num, msg_id_name, message);
    const log_msg = std.mem.span(@as([*:0]u8, @ptrCast(&buffer)));

    if ((message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) != 0) {
        log.cardinal_log_error("{s}", .{log_msg});
        if ((message_type & c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT) != 0) {
            log.cardinal_log_error("[VALIDATION] This error indicates a Vulkan specification violation", .{});
        }
    } else if ((message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) != 0) {
        log.cardinal_log_warn("{s}", .{log_msg});
    } else if ((message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT) != 0) {
        log.cardinal_log_info("{s}", .{log_msg});
    } else {
        log.cardinal_log_debug("{s}", .{log_msg});
    }

    return c.VK_FALSE;
}

fn select_debug_severity_from_log_level() c.VkDebugUtilsMessageSeverityFlagsEXT {
    const lvl = log.cardinal_log_get_level();
    var sev: c.VkDebugUtilsMessageSeverityFlagsEXT = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    if (@intFromEnum(lvl) <= @intFromEnum(log.CardinalLogLevel.INFO)) {
        sev |= c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT;
    }
    if (@intFromEnum(lvl) <= @intFromEnum(log.CardinalLogLevel.DEBUG)) {
        sev |= c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT;
    }
    return sev;
}

fn validation_enabled() bool {
    return false;
    // if (builtin.mode == .Debug) return true;
    // We can't easily check for CARDINAL_ENABLE_VK_VALIDATION define from Zig if it was a CMake define
    // But we can check if we want to enable it via some other mechanism or just assume Debug builds only
    // For now, let's assume Debug only unless we find a way to check the define.
    // However, the C code had #if defined(_DEBUG) || defined(CARDINAL_ENABLE_VK_VALIDATION)
    // We'll stick to builtin.mode == .Debug for now.
    // return true;
}

pub export fn vk_get_validation_stats() callconv(.c) *const types.ValidationStats {
    return &g_validation_stats;
}

pub export fn vk_reset_validation_stats() callconv(.c) void {
    g_validation_stats = std.mem.zeroes(types.ValidationStats);
}

pub export fn vk_log_validation_stats() callconv(.c) void {
    if (g_validation_stats.total_messages == 0) {
        log.cardinal_log_info("[VALIDATION] No validation messages received", .{});
        return;
    }

    log.cardinal_log_info("[VALIDATION] Statistics Summary:", .{});
    log.cardinal_log_info("[VALIDATION]   Total messages: {d}", .{g_validation_stats.total_messages});
    log.cardinal_log_info("[VALIDATION]   Errors: {d}, Warnings: {d}, Info: {d}", .{g_validation_stats.error_count, g_validation_stats.warning_count, g_validation_stats.info_count});
    log.cardinal_log_info("[VALIDATION]   By type - Validation: {d}, Performance: {d}, General: {d}", .{g_validation_stats.validation_count, g_validation_stats.performance_count, g_validation_stats.general_count});
    log.cardinal_log_info("[VALIDATION]   Filtered messages: {d}", .{g_validation_stats.filtered_count});
}

// Layer settings definitions if missing
const VkLayerSettingTypeEXT = enum(i32) {
    BOOL32_EXT = 0,
    INT32_EXT = 1,
    INT64_EXT = 2,
    FLOAT32_EXT = 3,
    FLOAT64_EXT = 4,
    STRING_EXT = 5,
};

const VkLayerSettingEXT = extern struct {
    pLayerName: [*c]const u8,
    pSettingName: [*c]const u8,
    type: VkLayerSettingTypeEXT,
    valueCount: u32,
    pValues: ?*const anyopaque,
};

const VkLayerSettingsCreateInfoEXT = extern struct {
    sType: c.VkStructureType,
    pNext: ?*const anyopaque,
    settingCount: u32,
    pSettings: [*]const VkLayerSettingEXT,
};

fn setup_app_info(ai: *c.VkApplicationInfo) void {
    ai.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    ai.pNext = null;
    ai.pApplicationName = "Cardinal";
    ai.applicationVersion = c.VK_MAKE_VERSION(1, 0, 0);
    ai.pEngineName = "Cardinal";
    ai.engineVersion = c.VK_MAKE_VERSION(1, 0, 0);
    ai.apiVersion = c.VK_MAKE_API_VERSION(0, 1, 3, 0);
    log.cardinal_log_info("[INSTANCE] Using Vulkan API version 1.3", .{});
}

fn get_instance_extensions(out_extensions: *[*c]const [*c]const u8, out_count: *u32, out_allocated: *bool) bool {
    var glfw_count: u32 = 0;
    const glfw_exts = c.glfwGetRequiredInstanceExtensions(&glfw_count);

    out_allocated.* = false;

    if (glfw_exts == null) {
        log.cardinal_log_info("[INSTANCE] GLFW instance extensions unavailable (headless or no GLFW)", .{});
        out_count.* = 0;
        out_extensions.* = null;
        return true;
    }

    log.cardinal_log_info("[INSTANCE] GLFW requires {d} extensions", .{glfw_count});
    var i: u32 = 0;
    while (i < glfw_count) : (i += 1) {
        log.cardinal_log_info("[INSTANCE] GLFW extension {d}: {s}", .{i, std.mem.span(glfw_exts[i])});
    }

    if (!validation_enabled()) {
        out_extensions.* = glfw_exts;
        out_count.* = glfw_count;
        return true;
    }

    var need_debug_utils = true;
    i = 0;
    while (i < glfw_count) : (i += 1) {
        if (c.strcmp(glfw_exts[i], c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME) == 0) {
            need_debug_utils = false;
            break;
        }
    }
    const need_layer_settings = true;

    var extra_count: u32 = 0;
    if (need_debug_utils) extra_count += 1;
    if (need_layer_settings) extra_count += 1;

    if (extra_count == 0) {
        out_extensions.* = glfw_exts;
        out_count.* = glfw_count;
        return true;
    }

    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const exts = memory.cardinal_alloc(mem_alloc, @sizeOf([*c]const u8) * (glfw_count + extra_count));
    if (exts == null) return false;
    const exts_ptr = @as([*][*c]const u8, @ptrCast(@alignCast(exts)));

    i = 0;
    while (i < glfw_count) : (i += 1) {
        exts_ptr[i] = glfw_exts[i];
    }

    var current = glfw_count;
    if (need_debug_utils) {
        exts_ptr[current] = c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
        current += 1;
        log.cardinal_log_info("[INSTANCE] Adding debug utils extension", .{});
    }
    if (need_layer_settings) {
        exts_ptr[current] = "VK_EXT_layer_settings"; // Macro might not be available
        current += 1;
        log.cardinal_log_info("[INSTANCE] Adding layer settings extension", .{});
    }

    out_extensions.* = @ptrCast(@alignCast(exts));
    out_count.* = glfw_count + extra_count;
    out_allocated.* = true;
    return true;
}

fn configure_validation(ci: *c.VkInstanceCreateInfo, layers: [*]const [*c]const u8, debug_ci: *c.VkDebugUtilsMessengerCreateInfoEXT, layer_settings_ci: *VkLayerSettingsCreateInfoEXT, settings: *VkLayerSettingEXT) void {
    if (!validation_enabled()) {
        ci.enabledLayerCount = 0;
        ci.ppEnabledLayerNames = null;
        return;
    }

    log.cardinal_log_info("[INSTANCE] Validation enabled - enabling validation layers", .{});
    ci.enabledLayerCount = 1;
    ci.ppEnabledLayerNames = layers;
    log.cardinal_log_info("[INSTANCE] Enabling validation layer: {s}", .{std.mem.span(layers[0])});

    debug_ci.sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
    debug_ci.messageSeverity = select_debug_severity_from_log_level();
    debug_ci.messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    debug_ci.pfnUserCallback = debug_callback;

    const static = struct {
        var legacy_detection: c.VkBool32 = c.VK_TRUE;
    };
    settings.pLayerName = "VK_LAYER_KHRONOS_validation";
    settings.pSettingName = "legacy_detection";
    settings.type = .BOOL32_EXT;
    settings.valueCount = 1;
    settings.pValues = &static.legacy_detection;

    // Use constant for VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT if not defined
    // const VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT: c.VkStructureType = 1000396000;
    // layer_settings_ci.sType = VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT;
    // layer_settings_ci.pNext = debug_ci;
    // layer_settings_ci.settingCount = 1;
    // layer_settings_ci.pSettings = @as([*]const VkLayerSettingEXT, @ptrCast(settings));

    // Temporarily disable layer settings to avoid validation error VK_STRUCTURE_TYPE_MICROMAP_BUILD_INFO_EXT collision
    ci.pNext = debug_ci;

    _ = layer_settings_ci;

    log.cardinal_log_info("[INSTANCE] Debug messenger configured (layer settings skipped)", .{});
}

pub export fn vk_create_instance(s: ?*types.VulkanState) callconv(.c) bool {
    log.cardinal_log_info("[INSTANCE] Starting Vulkan instance creation", .{});
    if (s == null) return false;
    const vs = s.?;

    var ai = std.mem.zeroes(c.VkApplicationInfo);
    setup_app_info(&ai);

    var extensions: [*c]const [*c]const u8 = null;
    var extension_count: u32 = 0;
    var extensions_allocated = false;
    if (!get_instance_extensions(&extensions, &extension_count, &extensions_allocated)) {
        return false;
    }

    log.cardinal_log_info("[INSTANCE] Final extension count: {d}", .{extension_count});
    var i: u32 = 0;
    while (i < extension_count) : (i += 1) {
        log.cardinal_log_info("[INSTANCE] Extension {d}: {s}", .{i, if (extensions[i] != null) std.mem.span(extensions[i]) else "(null)"});
    }

    const layers = [_][*c]const u8{ "VK_LAYER_KHRONOS_validation" };
    var ci = std.mem.zeroes(c.VkInstanceCreateInfo);
    ci.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ci.pApplicationInfo = &ai;
    ci.enabledExtensionCount = extension_count;
    ci.ppEnabledExtensionNames = extensions;

    var debug_ci = std.mem.zeroes(c.VkDebugUtilsMessengerCreateInfoEXT);
    var layer_settings_ci = std.mem.zeroes(VkLayerSettingsCreateInfoEXT);
    var settings = std.mem.zeroes(VkLayerSettingEXT);

    configure_validation(&ci, &layers, &debug_ci, &layer_settings_ci, &settings);

    log.cardinal_log_info("[INSTANCE] Creating Vulkan instance...", .{});
    const result = c.vkCreateInstance(&ci, null, &vs.context.instance);

    if (extensions_allocated) {
        const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
        memory.cardinal_free(mem_alloc, @as(?*anyopaque, @ptrCast(@constCast(extensions))));
    }

    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[INSTANCE] vkCreateInstance failed with result: {d}", .{result});
        return false;
    }
    log.cardinal_log_info("[INSTANCE] Instance creation result: {d}", .{result});

    if (validation_enabled()) {
        const dfunc = @as(c.PFN_vkCreateDebugUtilsMessengerEXT, @ptrCast(c.vkGetInstanceProcAddr(vs.context.instance, "vkCreateDebugUtilsMessengerEXT")));
        if (dfunc) |func| {
            _ = func(vs.context.instance, &debug_ci, null, &vs.context.debug_messenger);
        }
    }

    log.cardinal_log_info("[INSTANCE] Vulkan instance created successfully", .{});
    return true;
}

pub export fn vk_pick_physical_device(s: ?*types.VulkanState) callconv(.c) bool {
    log.cardinal_log_info("[DEVICE] Starting physical device selection", .{});
    if (s == null) return false;
    const vs = s.?;

    var count: u32 = 0;
    var result = c.vkEnumeratePhysicalDevices(vs.context.instance, &count, null);
    log.cardinal_log_info("[DEVICE] Found {d} physical devices, enumerate result: {d}", .{count, result});
    
    if (count == 0) {
        log.cardinal_log_error("[DEVICE] No physical devices found!", .{});
        return false;
    }

    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const devices = memory.cardinal_alloc(mem_alloc, @sizeOf(c.VkPhysicalDevice) * count);
    if (devices == null) return false;
    const devices_ptr = @as([*]c.VkPhysicalDevice, @ptrCast(@alignCast(devices)));
    defer memory.cardinal_free(mem_alloc, devices);

    result = c.vkEnumeratePhysicalDevices(vs.context.instance, &count, devices_ptr);
    log.cardinal_log_info("[DEVICE] Enumerate devices result: {d}", .{result});
    
    vs.context.physical_device = devices_ptr[0];

    var props: c.VkPhysicalDeviceProperties = undefined;
    c.vkGetPhysicalDeviceProperties(vs.context.physical_device, &props);
    
    log.cardinal_log_info("[DEVICE] Selected device: {s} (API {d}.{d}.{d}, Driver {d}.{d}.{d})", .{
        std.mem.sliceTo(&props.deviceName, 0),
        c.VK_VERSION_MAJOR(props.apiVersion), c.VK_VERSION_MINOR(props.apiVersion), c.VK_VERSION_PATCH(props.apiVersion),
        c.VK_VERSION_MAJOR(props.driverVersion), c.VK_VERSION_MINOR(props.driverVersion), c.VK_VERSION_PATCH(props.driverVersion)
    });

    return vs.context.physical_device != null;
}

pub export fn vk_create_device(s: ?*types.VulkanState) callconv(.c) bool {
    log.cardinal_log_info("[DEVICE] Starting logical device creation", .{});
    if (s == null) return false;
    const vs = s.?;

    var qf_count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(vs.context.physical_device, &qf_count, null);
    log.cardinal_log_info("[DEVICE] Found {d} queue families", .{qf_count});

    const mem_alloc = memory.cardinal_get_allocator_for_category(.RENDERER);
    const qfp = memory.cardinal_alloc(mem_alloc, @sizeOf(c.VkQueueFamilyProperties) * qf_count);
    if (qfp == null) return false;
    const qfp_ptr = @as([*]c.VkQueueFamilyProperties, @ptrCast(@alignCast(qfp)));
    defer memory.cardinal_free(mem_alloc, qfp);
    
    c.vkGetPhysicalDeviceQueueFamilyProperties(vs.context.physical_device, &qf_count, qfp_ptr);

    vs.context.graphics_queue_family = 0;
    var i: u32 = 0;
    while (i < qf_count) : (i += 1) {
        if ((qfp_ptr[i].queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0) {
            vs.context.graphics_queue_family = i;
            break;
        }
    }
    log.cardinal_log_info("[DEVICE] Selected graphics family: {d}", .{vs.context.graphics_queue_family});

    var prio: f32 = 1.0;
    var qci = std.mem.zeroes(c.VkDeviceQueueCreateInfo);
    qci.sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = vs.context.graphics_queue_family;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;

    var physicalDeviceProperties: c.VkPhysicalDeviceProperties = undefined;
    c.vkGetPhysicalDeviceProperties(vs.context.physical_device, &physicalDeviceProperties);
    const apiVersion = physicalDeviceProperties.apiVersion;
    const majorVersion = c.VK_VERSION_MAJOR(apiVersion);
    const minorVersion = c.VK_VERSION_MINOR(apiVersion);
    log.cardinal_log_info("[DEVICE] Physical device supports Vulkan {d}.{d}.{d}", .{majorVersion, minorVersion, c.VK_VERSION_PATCH(apiVersion)});

    const vulkan_14_supported = (majorVersion > 1) or (majorVersion == 1 and minorVersion >= 4);
    const vulkan_12_supported = (majorVersion > 1) or (majorVersion == 1 and minorVersion >= 2);

    if (!vulkan_14_supported) {
        log.cardinal_log_error("[DEVICE] Vulkan 1.4 core is required but not supported (found {d}.{d})", .{majorVersion, minorVersion});
        return false;
    }
    log.cardinal_log_info("[DEVICE] Vulkan 1.4 core support confirmed", .{});

    var extension_count: u32 = 0;
    _ = c.vkEnumerateDeviceExtensionProperties(vs.context.physical_device, null, &extension_count, null);
    const available_extensions = memory.cardinal_alloc(mem_alloc, @sizeOf(c.VkExtensionProperties) * extension_count);
    if (available_extensions == null) return false;
    const available_extensions_ptr = @as([*]c.VkExtensionProperties, @ptrCast(@alignCast(available_extensions)));
    _ = c.vkEnumerateDeviceExtensionProperties(vs.context.physical_device, null, &extension_count, available_extensions_ptr);
    defer memory.cardinal_free(mem_alloc, available_extensions);

    var maintenance8_available = false;
    var mesh_shader_available = false;
    var fragment_shading_rate_available = false;
    var descriptor_indexing_available = false;
    var descriptor_buffer_available = false;
    var shader_quad_control_available = false;
    var shader_maximal_reconvergence_available = false;

    i = 0;
    while (i < extension_count) : (i += 1) {
        const extName = &available_extensions_ptr[i].extensionName;
        if (c.strcmp(extName, c.VK_KHR_MAINTENANCE_8_EXTENSION_NAME) == 0) {
            maintenance8_available = true;
            log.cardinal_log_info("[DEVICE] VK_KHR_maintenance8 extension available", .{});
        } else if (c.strcmp(extName, c.VK_EXT_MESH_SHADER_EXTENSION_NAME) == 0) {
            mesh_shader_available = true;
            log.cardinal_log_info("[DEVICE] VK_EXT_mesh_shader extension available", .{});
        } else if (c.strcmp(extName, c.VK_KHR_FRAGMENT_SHADING_RATE_EXTENSION_NAME) == 0) {
            fragment_shading_rate_available = true;
            log.cardinal_log_info("[DEVICE] VK_KHR_fragment_shading_rate extension available", .{});
        } else if (c.strcmp(extName, c.VK_EXT_DESCRIPTOR_INDEXING_EXTENSION_NAME) == 0) {
            descriptor_indexing_available = true;
            log.cardinal_log_info("[DEVICE] VK_EXT_descriptor_indexing extension available", .{});
        } else if (c.strcmp(extName, c.VK_EXT_DESCRIPTOR_BUFFER_EXTENSION_NAME) == 0) {
            descriptor_buffer_available = true;
            log.cardinal_log_info("[DEVICE] VK_EXT_descriptor_buffer extension available", .{});
        } else if (c.strcmp(extName, c.VK_KHR_SHADER_QUAD_CONTROL_EXTENSION_NAME) == 0) {
            shader_quad_control_available = true;
            log.cardinal_log_info("[DEVICE] VK_KHR_shader_quad_control extension available", .{});
        } else if (c.strcmp(extName, c.VK_KHR_SHADER_MAXIMAL_RECONVERGENCE_EXTENSION_NAME) == 0) {
            shader_maximal_reconvergence_available = true;
            log.cardinal_log_info("[DEVICE] VK_KHR_shader_maximal_reconvergence extension available", .{});
        }
    }

    if (!maintenance8_available) {
        log.cardinal_log_info("[DEVICE] VK_KHR_maintenance8 extension not available, using maintenance4 fallback", .{});
    }

    if (!mesh_shader_available) {
        log.cardinal_log_info("[DEVICE] VK_EXT_mesh_shader extension not available, using traditional vertex pipeline", .{});
    }

    if (mesh_shader_available and !fragment_shading_rate_available) {
        log.cardinal_log_error("[DEVICE] VK_EXT_mesh_shader requires VK_KHR_fragment_shading_rate but it's not available", .{});
        mesh_shader_available = false;
    }

    if (shader_quad_control_available and !shader_maximal_reconvergence_available) {
        log.cardinal_log_error("[DEVICE] VK_KHR_shader_quad_control requires VK_KHR_shader_maximal_reconvergence but it's not available", .{});
        shader_quad_control_available = false;
    }

    var device_extensions: [10][*c]const u8 = undefined;
    var enabled_extension_count: u32 = 0;

    if (!vs.swapchain.headless_mode) {
        device_extensions[enabled_extension_count] = c.VK_KHR_SWAPCHAIN_EXTENSION_NAME;
        enabled_extension_count += 1;
        log.cardinal_log_info("[DEVICE] Enabling VK_KHR_swapchain extension", .{});
    }

    if (maintenance8_available) {
        device_extensions[enabled_extension_count] = c.VK_KHR_MAINTENANCE_8_EXTENSION_NAME;
        enabled_extension_count += 1;
        log.cardinal_log_info("[DEVICE] Enabling VK_KHR_maintenance8 extension", .{});
    }

    if (mesh_shader_available) {
        device_extensions[enabled_extension_count] = c.VK_KHR_FRAGMENT_SHADING_RATE_EXTENSION_NAME;
        enabled_extension_count += 1;
        device_extensions[enabled_extension_count] = c.VK_EXT_MESH_SHADER_EXTENSION_NAME;
        enabled_extension_count += 1;
        log.cardinal_log_info("[DEVICE] Enabling VK_KHR_fragment_shading_rate + VK_EXT_mesh_shader", .{});
    }

    if (descriptor_indexing_available) {
        log.cardinal_log_info("[DEVICE] VK_EXT_descriptor_indexing available (promoted to Vulkan 1.2), enabling features only", .{});
    }

    if (descriptor_buffer_available) {
        device_extensions[enabled_extension_count] = c.VK_EXT_DESCRIPTOR_BUFFER_EXTENSION_NAME;
        enabled_extension_count += 1;
        log.cardinal_log_info("[DEVICE] Enabling VK_EXT_descriptor_buffer extension", .{});
    }

    if (shader_maximal_reconvergence_available) {
        device_extensions[enabled_extension_count] = c.VK_KHR_SHADER_MAXIMAL_RECONVERGENCE_EXTENSION_NAME;
        enabled_extension_count += 1;
        log.cardinal_log_info("[DEVICE] Enabling VK_KHR_shader_maximal_reconvergence extension", .{});
    }

    if (shader_quad_control_available) {
        device_extensions[enabled_extension_count] = c.VK_KHR_SHADER_QUAD_CONTROL_EXTENSION_NAME;
        enabled_extension_count += 1;
        log.cardinal_log_info("[DEVICE] Enabling VK_KHR_shader_quad_control extension", .{});
    }

    var shaderQuadControlFeatures = std.mem.zeroes(c.VkPhysicalDeviceShaderQuadControlFeaturesKHR);
    shaderQuadControlFeatures.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_QUAD_CONTROL_FEATURES_KHR;
    
    var shaderMaximalReconvergenceFeatures = std.mem.zeroes(c.VkPhysicalDeviceShaderMaximalReconvergenceFeaturesKHR);
    shaderMaximalReconvergenceFeatures.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_MAXIMAL_RECONVERGENCE_FEATURES_KHR;
    shaderMaximalReconvergenceFeatures.pNext = if (shader_quad_control_available) &shaderQuadControlFeatures else null;

    var descriptorBufferFeatures = std.mem.zeroes(c.VkPhysicalDeviceDescriptorBufferFeaturesEXT);
    descriptorBufferFeatures.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_FEATURES_EXT;
    descriptorBufferFeatures.pNext = if (shader_maximal_reconvergence_available) &shaderMaximalReconvergenceFeatures else null;

    var meshShaderFeatures = std.mem.zeroes(c.VkPhysicalDeviceMeshShaderFeaturesEXT);
    meshShaderFeatures.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT;
    if (descriptor_buffer_available) {
        meshShaderFeatures.pNext = &descriptorBufferFeatures;
    } else if (shader_maximal_reconvergence_available) {
        meshShaderFeatures.pNext = &shaderMaximalReconvergenceFeatures;
    } else {
        meshShaderFeatures.pNext = null;
    }

    var multiviewFeatures = std.mem.zeroes(c.VkPhysicalDeviceMultiviewFeatures);
    multiviewFeatures.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MULTIVIEW_FEATURES;
    if (mesh_shader_available) {
        multiviewFeatures.pNext = &meshShaderFeatures;
    } else if (descriptor_buffer_available) {
        multiviewFeatures.pNext = &descriptorBufferFeatures;
    } else if (shader_maximal_reconvergence_available) {
        multiviewFeatures.pNext = &shaderMaximalReconvergenceFeatures;
    } else {
        multiviewFeatures.pNext = null;
    }

    var fragmentShadingRateFeatures = std.mem.zeroes(c.VkPhysicalDeviceFragmentShadingRateFeaturesKHR);
    fragmentShadingRateFeatures.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADING_RATE_FEATURES_KHR;
    fragmentShadingRateFeatures.pNext = &multiviewFeatures;

    var maintenance8Features = std.mem.zeroes(c.VkPhysicalDeviceMaintenance8FeaturesKHR);
    maintenance8Features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_8_FEATURES_KHR;
    maintenance8Features.pNext = &fragmentShadingRateFeatures;

    var vulkan14Features = std.mem.zeroes(c.VkPhysicalDeviceVulkan14Features);
    vulkan14Features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES;
    vulkan14Features.pNext = if (maintenance8_available) @as(?*anyopaque, @ptrCast(&maintenance8Features)) else @as(?*anyopaque, @ptrCast(&fragmentShadingRateFeatures));

    var vulkan13Features = std.mem.zeroes(c.VkPhysicalDeviceVulkan13Features);
    vulkan13Features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
    vulkan13Features.pNext = &vulkan14Features;

    var vulkan12Features = std.mem.zeroes(c.VkPhysicalDeviceVulkan12Features);
    vulkan12Features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
    vulkan12Features.pNext = &vulkan13Features;

    var deviceFeatures2 = std.mem.zeroes(c.VkPhysicalDeviceFeatures2);
    deviceFeatures2.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    deviceFeatures2.pNext = &vulkan12Features;

    c.vkGetPhysicalDeviceFeatures2(vs.context.physical_device, &deviceFeatures2);
    log.cardinal_log_info("[DEVICE] Queried Vulkan 1.2, 1.3 and 1.4 features", .{});

    var subgroupProperties = std.mem.zeroes(c.VkPhysicalDeviceSubgroupProperties);
    subgroupProperties.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES;
    
    var props2 = std.mem.zeroes(c.VkPhysicalDeviceProperties2);
    props2.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    props2.pNext = &subgroupProperties;
    c.vkGetPhysicalDeviceProperties2(vs.context.physical_device, &props2);

    log.cardinal_log_info("[DEVICE] Subgroup properties: size={d}", .{subgroupProperties.subgroupSize});

    if ((subgroupProperties.supportedOperations & c.VK_SUBGROUP_FEATURE_BALLOT_BIT) == 0) {
        log.cardinal_log_error("[DEVICE] Subgroup ballot operations are required but not supported", .{});
        return false;
    }

    if (vulkan13Features.dynamicRendering == c.VK_FALSE or vulkan13Features.synchronization2 == c.VK_FALSE or vulkan13Features.maintenance4 == c.VK_FALSE) {
        log.cardinal_log_error("[DEVICE] Required Vulkan 1.3 features not supported", .{});
        return false;
    }

    if (maintenance8_available) {
        maintenance8Features.maintenance8 = c.VK_TRUE;
        log.cardinal_log_info("[DEVICE] VK_KHR_maintenance8 features enabled", .{});
    }

    if (mesh_shader_available) {
        multiviewFeatures.multiview = c.VK_TRUE;
        fragmentShadingRateFeatures.primitiveFragmentShadingRate = c.VK_TRUE;
        meshShaderFeatures.meshShader = c.VK_TRUE;
        if (meshShaderFeatures.taskShader == c.VK_TRUE) {
            log.cardinal_log_info("[DEVICE] VK_EXT_mesh_shader features enabled: meshShader + taskShader", .{});
        } else {
            log.cardinal_log_info("[DEVICE] VK_EXT_mesh_shader features enabled: meshShader only", .{});
        }
    }

    if (descriptor_indexing_available) {
        vulkan12Features.descriptorBindingVariableDescriptorCount = c.VK_TRUE;
        vulkan12Features.descriptorBindingSampledImageUpdateAfterBind = c.VK_TRUE;
        vulkan12Features.shaderSampledImageArrayNonUniformIndexing = c.VK_TRUE;
        vulkan12Features.runtimeDescriptorArray = c.VK_TRUE;
        vulkan12Features.descriptorBindingPartiallyBound = c.VK_TRUE;
        vulkan12Features.shaderUniformBufferArrayNonUniformIndexing = c.VK_TRUE;
        vulkan12Features.shaderStorageBufferArrayNonUniformIndexing = c.VK_TRUE;
        vulkan12Features.shaderStorageImageArrayNonUniformIndexing = c.VK_TRUE;
        log.cardinal_log_info("[DEVICE] VK_EXT_descriptor_indexing features enabled", .{});
    }

    if (descriptor_buffer_available) {
        descriptorBufferFeatures.descriptorBuffer = c.VK_TRUE;
        if (descriptorBufferFeatures.descriptorBufferImageLayoutIgnored == c.VK_TRUE) {
            log.cardinal_log_info("[DEVICE] VK_EXT_descriptor_buffer: descriptorBuffer + descriptorBufferImageLayoutIgnored", .{});
        } else {
            log.cardinal_log_info("[DEVICE] VK_EXT_descriptor_buffer: descriptorBuffer only", .{});
        }
        if (descriptorBufferFeatures.descriptorBufferPushDescriptors == c.VK_TRUE) {
            log.cardinal_log_info("[DEVICE] VK_EXT_descriptor_buffer push descriptors enabled", .{});
        }
    }

    if (shader_quad_control_available) {
        shaderQuadControlFeatures.shaderQuadControl = c.VK_TRUE;
        log.cardinal_log_info("[DEVICE] VK_KHR_shader_quad_control features enabled", .{});
    }

    if (shader_maximal_reconvergence_available) {
        shaderMaximalReconvergenceFeatures.shaderMaximalReconvergence = c.VK_TRUE;
        log.cardinal_log_info("[DEVICE] VK_KHR_shader_maximal_reconvergence features enabled", .{});
    }

    if (vulkan12Features.bufferDeviceAddress == c.VK_FALSE) {
        log.cardinal_log_error("[DEVICE] bufferDeviceAddress is required but not supported", .{});
        return false;
    }
    vulkan12Features.bufferDeviceAddress = c.VK_TRUE;

    vulkan13Features.dynamicRendering = c.VK_TRUE;
    vulkan13Features.synchronization2 = c.VK_TRUE;
    vulkan13Features.maintenance4 = c.VK_TRUE;

    if (vulkan14Features.globalPriorityQuery == c.VK_TRUE) log.cardinal_log_info("[DEVICE] Vulkan 1.4 globalPriorityQuery: enabled", .{});
    if (vulkan14Features.shaderSubgroupRotate == c.VK_TRUE) log.cardinal_log_info("[DEVICE] Vulkan 1.4 shaderSubgroupRotate: enabled", .{});
    if (vulkan14Features.shaderFloatControls2 == c.VK_TRUE) log.cardinal_log_info("[DEVICE] Vulkan 1.4 shaderFloatControls2: enabled", .{});
    if (vulkan14Features.shaderExpectAssume == c.VK_TRUE) log.cardinal_log_info("[DEVICE] Vulkan 1.4 shaderExpectAssume: enabled", .{});

    deviceFeatures2.pNext = &vulkan12Features;

    var dci = std.mem.zeroes(c.VkDeviceCreateInfo);
    dci.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = enabled_extension_count;
    dci.ppEnabledExtensionNames = &device_extensions;
    dci.pNext = &deviceFeatures2;

    log.cardinal_log_info("[DEVICE] Enabling {d} device extension(s)", .{dci.enabledExtensionCount});
    i = 0;
    while (i < dci.enabledExtensionCount) : (i += 1) {
        log.cardinal_log_info("[DEVICE] Device extension {d}: {s}", .{i, std.mem.span(device_extensions[i])});
    }

    const result = c.vkCreateDevice(vs.context.physical_device, &dci, null, &vs.context.device);
    log.cardinal_log_info("[DEVICE] Device creation result: {d}", .{result});

    if (result != c.VK_SUCCESS) {
        return false;
    }

    c.vkGetDeviceQueue(vs.context.device, vs.context.graphics_queue_family, 0, &vs.context.graphics_queue);
    vs.context.present_queue_family = vs.context.graphics_queue_family;
    vs.context.present_queue = vs.context.graphics_queue;

    vs.context.supports_dynamic_rendering = true;
    vs.context.supports_vulkan_12_features = vulkan_12_supported;
    vs.context.supports_vulkan_13_features = true;
    vs.context.supports_vulkan_14_features = true;
    vs.context.supports_maintenance4 = true;
    vs.context.supports_maintenance8 = maintenance8_available;
    vs.context.supports_mesh_shader = mesh_shader_available;
    vs.context.supports_descriptor_indexing = descriptor_indexing_available;
    vs.context.supports_descriptor_buffer = descriptor_buffer_available;
    vs.context.descriptor_buffer_extension_available = descriptor_buffer_available;
    vs.context.supports_shader_quad_control = shader_quad_control_available;
    vs.context.supports_shader_maximal_reconvergence = shader_maximal_reconvergence_available;
    vs.context.supports_buffer_device_address = true;

    // Load function pointers
    vs.context.vkCmdBeginRendering = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkCmdBeginRendering"));
    vs.context.vkCmdEndRendering = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkCmdEndRendering"));
    vs.context.vkCmdPipelineBarrier2 = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkCmdPipelineBarrier2"));
    
    vs.context.vkGetDeviceBufferMemoryRequirements = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkGetDeviceBufferMemoryRequirements"));
    vs.context.vkGetDeviceImageMemoryRequirements = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkGetDeviceImageMemoryRequirements"));

    vs.context.vkGetDeviceBufferMemoryRequirementsKHR = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkGetDeviceBufferMemoryRequirements"));
    if (vs.context.vkGetDeviceBufferMemoryRequirementsKHR == null) {
        vs.context.vkGetDeviceBufferMemoryRequirementsKHR = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkGetDeviceBufferMemoryRequirementsKHR"));
    }

    vs.context.vkGetDeviceImageMemoryRequirementsKHR = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkGetDeviceImageMemoryRequirements"));
    if (vs.context.vkGetDeviceImageMemoryRequirementsKHR == null) {
        vs.context.vkGetDeviceImageMemoryRequirementsKHR = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkGetDeviceImageMemoryRequirementsKHR"));
    }

    vs.context.vkQueueSubmit2 = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkQueueSubmit2"));
    vs.context.vkWaitSemaphores = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkWaitSemaphores"));
    vs.context.vkSignalSemaphore = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkSignalSemaphore"));
    vs.context.vkGetSemaphoreCounterValue = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkGetSemaphoreCounterValue"));
    vs.context.vkGetBufferDeviceAddress = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkGetBufferDeviceAddress"));

    if (descriptor_buffer_available) {
        vs.context.vkGetDescriptorSetLayoutSizeEXT = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkGetDescriptorSetLayoutSizeEXT"));
        vs.context.vkGetDescriptorSetLayoutBindingOffsetEXT = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkGetDescriptorSetLayoutBindingOffsetEXT"));
        vs.context.vkGetDescriptorEXT = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkGetDescriptorEXT"));
        vs.context.vkCmdBindDescriptorBuffersEXT = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkCmdBindDescriptorBuffersEXT"));
        vs.context.vkCmdSetDescriptorBufferOffsetsEXT = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkCmdSetDescriptorBufferOffsetsEXT"));
        vs.context.vkCmdBindDescriptorBufferEmbeddedSamplersEXT = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkCmdBindDescriptorBufferEmbeddedSamplersEXT"));
        vs.context.vkGetBufferOpaqueCaptureDescriptorDataEXT = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkGetBufferOpaqueCaptureDescriptorDataEXT"));
        vs.context.vkGetImageOpaqueCaptureDescriptorDataEXT = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkGetImageOpaqueCaptureDescriptorDataEXT"));
        vs.context.vkGetImageViewOpaqueCaptureDescriptorDataEXT = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkGetImageViewOpaqueCaptureDescriptorDataEXT"));
        vs.context.vkGetSamplerOpaqueCaptureDescriptorDataEXT = @ptrCast(c.vkGetDeviceProcAddr(vs.context.device, "vkGetSamplerOpaqueCaptureDescriptorDataEXT"));

        if (vs.context.vkGetDescriptorSetLayoutSizeEXT != null) {
            vs.context.supports_descriptor_buffer = true;

            var desc_buffer_props = std.mem.zeroes(c.VkPhysicalDeviceDescriptorBufferPropertiesEXT);
            desc_buffer_props.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT;
            
            var descriptorBufferProps2 = std.mem.zeroes(c.VkPhysicalDeviceProperties2);
            descriptorBufferProps2.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
            descriptorBufferProps2.pNext = &desc_buffer_props;

            c.vkGetPhysicalDeviceProperties2(vs.context.physical_device, &descriptorBufferProps2);
            vs.context.descriptor_buffer_uniform_buffer_size = desc_buffer_props.uniformBufferDescriptorSize;
            vs.context.descriptor_buffer_combined_image_sampler_size = desc_buffer_props.combinedImageSamplerDescriptorSize;
        } else {
            vs.context.supports_descriptor_buffer = false;
        }
    } else {
        vs.context.supports_descriptor_buffer = false;
    }

    if (!vk_allocator.vk_allocator_init(&vs.allocator, vs.context.instance, vs.context.physical_device, vs.context.device,
                           vs.context.vkGetDeviceBufferMemoryRequirements,
                           vs.context.vkGetDeviceImageMemoryRequirements,
                           vs.context.vkGetBufferDeviceAddress,
                           vs.context.vkGetDeviceBufferMemoryRequirementsKHR,
                           vs.context.vkGetDeviceImageMemoryRequirementsKHR,
                           vs.context.supports_maintenance8)) {
        log.cardinal_log_error("[DEVICE] Failed to initialize VulkanAllocator", .{});
        return false;
    }

    log.cardinal_log_info("[DEVICE] VulkanAllocator initialized", .{});
    return true;
}

pub export fn vk_create_surface(s: ?*types.VulkanState, win: ?*window.CardinalWindow) callconv(.c) bool {
    log.cardinal_log_info("[SURFACE] Creating surface from window", .{});
    if (s == null or win == null) return false;
    const vs = s.?;

    var sci = std.mem.zeroes(c.VkWin32SurfaceCreateInfoKHR);
    sci.sType = c.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;
    sci.hinstance = c.GetModuleHandleA(null);
    const native_handle = window.cardinal_window_get_native_handle(win);
    if (native_handle == null) return false;
    
    // Hack: HWND might be an odd value (not aligned), but Zig's pointer types expect alignment.
    // We write the handle value directly into the struct memory to bypass alignment checks.
    const hwnd_ptr = @as(*usize, @ptrCast(&sci.hwnd));
    hwnd_ptr.* = @intFromPtr(native_handle);

    const result = c.vkCreateWin32SurfaceKHR(vs.context.instance, &sci, null, &vs.context.surface);
    log.cardinal_log_info("[SURFACE] Surface create result: {d}", .{result});
    return result == c.VK_SUCCESS;
}

pub export fn vk_destroy_device_objects(s: ?*types.VulkanState) callconv(.c) void {
    log.cardinal_log_info("[DESTROY] Destroying device objects and cleanup", .{});
    if (s == null) return;
    const vs = s.?;

    if (vs.context.device != null) {
        _ = c.vkDeviceWaitIdle(vs.context.device);
    }

    vk_allocator.vk_allocator_shutdown(&vs.allocator);

    if (vs.context.device != null) {
        c.vkDestroyDevice(vs.context.device, null);
        vs.context.device = null;
    }

    if (vs.context.debug_messenger != null) {
        const dfunc = @as(c.PFN_vkDestroyDebugUtilsMessengerEXT, @ptrCast(c.vkGetInstanceProcAddr(vs.context.instance, "vkDestroyDebugUtilsMessengerEXT")));
        if (dfunc) |func| {
            func(vs.context.instance, vs.context.debug_messenger, null);
        }
        vs.context.debug_messenger = null;
    }

    if (vs.context.surface != null) {
        c.vkDestroySurfaceKHR(vs.context.instance, vs.context.surface, null);
        vs.context.surface = null;
    }

    if (vs.context.instance != null) {
        c.vkDestroyInstance(vs.context.instance, null);
        vs.context.instance = null;
    }
}

pub export fn vk_recreate_debug_messenger(s: ?*types.VulkanState) callconv(.c) void {
    if (s == null or s.?.context.instance == null) return;
    if (!validation_enabled()) return;
    const vs = s.?;

    if (vs.context.debug_messenger != null) {
        const dfunc = @as(c.PFN_vkDestroyDebugUtilsMessengerEXT, @ptrCast(c.vkGetInstanceProcAddr(vs.context.instance, "vkDestroyDebugUtilsMessengerEXT")));
        if (dfunc) |func| {
            func(vs.context.instance, vs.context.debug_messenger, null);
        }
        vs.context.debug_messenger = null;
    }

    const cfunc = @as(c.PFN_vkCreateDebugUtilsMessengerEXT, @ptrCast(c.vkGetInstanceProcAddr(vs.context.instance, "vkCreateDebugUtilsMessengerEXT")));
    if (cfunc) |func| {
        var ci = std.mem.zeroes(c.VkDebugUtilsMessengerCreateInfoEXT);
        ci.sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
        ci.messageSeverity = select_debug_severity_from_log_level();
        ci.messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
        ci.pfnUserCallback = debug_callback;

        const r = func(vs.context.instance, &ci, null, &vs.context.debug_messenger);
        log.cardinal_log_info("[INSTANCE] Recreated debug messenger (result={d})", .{r});
    }
}
