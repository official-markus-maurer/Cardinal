//! Vulkan validation and debug utilities.
//!
//! Hosts the debug callback, validation statistics, and layer-settings configuration used by
//! instance creation and debug-messenger recreation.
const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const types = @import("vulkan_types.zig");
const c = @import("vulkan_c.zig").c;

const vk_log = log.ScopedLogger("VULKAN");

/// Aggregated statistics from the Vulkan debug callback.
var g_validation_stats = std.mem.zeroes(types.ValidationStats);

pub fn validation_enabled() bool {
    return builtin.mode == .Debug;
}

pub export fn vk_get_validation_stats() callconv(.c) *const types.ValidationStats {
    return &g_validation_stats;
}

pub export fn vk_reset_validation_stats() callconv(.c) void {
    g_validation_stats = std.mem.zeroes(types.ValidationStats);
}

pub export fn vk_log_validation_stats() callconv(.c) void {
    if (g_validation_stats.total_messages == 0) {
        vk_log.info("[VALIDATION] No validation messages received", .{});
        return;
    }

    vk_log.info("[VALIDATION] Statistics Summary:", .{});
    vk_log.info("[VALIDATION]   Total messages: {d}", .{g_validation_stats.total_messages});
    vk_log.info("[VALIDATION]   Errors: {d}, Warnings: {d}, Info: {d}", .{ g_validation_stats.error_count, g_validation_stats.warning_count, g_validation_stats.info_count });
    vk_log.info("[VALIDATION]   By type - Validation: {d}, Performance: {d}, General: {d}", .{ g_validation_stats.validation_count, g_validation_stats.performance_count, g_validation_stats.general_count });
    vk_log.info("[VALIDATION]   Filtered messages: {d}", .{g_validation_stats.filtered_count});
}

fn should_filter_message(message_id: i32, message_id_name: ?[*:0]const u8) bool {
    _ = message_id;
    if (message_id_name) |name| {
        if (c.strstr(name, "Loader-Message") != null and c.strstr(name, "older than") != null) {
            return true;
        }
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

fn debug_callback(message_severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT, message_type: c.VkDebugUtilsMessageTypeFlagsEXT, callback_data: ?*const c.VkDebugUtilsMessengerCallbackDataEXT, user_data: ?*anyopaque) callconv(.c) c.VkBool32 {
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
        vk_log.err("{s}", .{log_msg});
        if ((message_type & c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT) != 0) {
            vk_log.err("[VALIDATION] This error indicates a Vulkan specification violation", .{});
        }
    } else if ((message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) != 0) {
        vk_log.warn("{s}", .{log_msg});
    } else if ((message_severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT) != 0) {
        vk_log.info("{s}", .{log_msg});
    } else {
        vk_log.debug("{s}", .{log_msg});
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

/// Fills a debug messenger create info struct using current log severity settings.
pub fn fill_debug_messenger_create_info(ci: *c.VkDebugUtilsMessengerCreateInfoEXT) void {
    ci.* = std.mem.zeroes(c.VkDebugUtilsMessengerCreateInfoEXT);
    ci.sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
    ci.messageSeverity = select_debug_severity_from_log_level();
    ci.messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    ci.pfnUserCallback = debug_callback;
}

/// Layer settings type enum used by VK_EXT_layer_settings.
pub const VkLayerSettingTypeEXT = enum(i32) {
    BOOL32_EXT = 0,
    INT32_EXT = 1,
    INT64_EXT = 2,
    UINT32_EXT = 3,
    UINT64_EXT = 4,
    FLOAT32_EXT = 5,
    FLOAT64_EXT = 6,
    STRING_EXT = 7,
};

pub const VkLayerSettingEXT = extern struct {
    pLayerName: [*c]const u8,
    pSettingName: [*c]const u8,
    type: VkLayerSettingTypeEXT,
    valueCount: u32,
    pValues: ?*const anyopaque,
};

/// Configures instance creation for validation (layers + debug messenger + layer settings).
pub fn configure_validation(ci: *c.VkInstanceCreateInfo, layers: [*]const [*c]const u8, debug_ci: *c.VkDebugUtilsMessengerCreateInfoEXT) void {
    if (!validation_enabled()) {
        ci.enabledLayerCount = 0;
        ci.ppEnabledLayerNames = null;
        return;
    }

    vk_log.info("[INSTANCE] Validation enabled - enabling validation layers", .{});
    ci.enabledLayerCount = 1;
    ci.ppEnabledLayerNames = layers;
    vk_log.info("[INSTANCE] Enabling validation layer: {s}", .{std.mem.span(layers[0])});

    fill_debug_messenger_create_info(debug_ci);
    ci.pNext = debug_ci;
    vk_log.info("[INSTANCE] Debug messenger configured", .{});
}
