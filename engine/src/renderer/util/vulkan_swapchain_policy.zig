//! Swapchain selection policy helpers.
//!
//! Encapsulates the heuristics used to choose surface formats and present modes from available
//! device/surface capabilities.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("../vulkan_c.zig").c;

/// Chooses a surface format, honoring explicit preferences when provided.
pub fn choose_surface_format_with_preference(formats: [*]const c.VkSurfaceFormatKHR, count: u32, preferred_format: c.VkFormat, preferred_color_space: c.VkColorSpaceKHR, prefer_hdr_config: bool) c.VkSurfaceFormatKHR {
    if (count == 0) {
        return std.mem.zeroes(c.VkSurfaceFormatKHR);
    }

    if (preferred_format != c.VK_FORMAT_UNDEFINED) {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (formats[i].format == preferred_format and (preferred_color_space == 0 or formats[i].colorSpace == preferred_color_space)) {
                return formats[i];
            }
        }
    }

    if (preferred_color_space != 0) {
        var j: u32 = 0;
        while (j < count) : (j += 1) {
            if (formats[j].colorSpace == preferred_color_space) {
                return formats[j];
            }
        }
    }

    return choose_surface_format(formats, count, prefer_hdr_config);
}

/// Chooses the best surface format for the current HDR policy.
pub fn choose_surface_format(formats: [*]const c.VkSurfaceFormatKHR, count: u32, prefer_hdr_config: bool) c.VkSurfaceFormatKHR {
    if (count == 0) {
        return std.mem.zeroes(c.VkSurfaceFormatKHR);
    }

    var prefer_hdr = prefer_hdr_config;
    const env_hdr = c.getenv("CARDINAL_PREFER_HDR");
    if (env_hdr != null) {
        const h = env_hdr[0];
        if (h == '1' or h == 'T' or h == 't' or h == 'Y' or h == 'y') {
            prefer_hdr = true;
        }
    }

    var best_score: i32 = -1;
    var best = formats[0];

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const f = &formats[i];
        var score: i32 = 0;

        if (prefer_hdr) {
            if (f.colorSpace == c.VK_COLOR_SPACE_HDR10_ST2084_EXT or
                f.colorSpace == c.VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT or
                f.colorSpace == c.VK_COLOR_SPACE_BT2020_LINEAR_EXT)
            {
                score += 50;
            }
        }
        if (f.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            score += 10;
        }

        switch (f.format) {
            c.VK_FORMAT_R16G16B16A16_SFLOAT => {
                if (prefer_hdr) score += 40;
            },
            c.VK_FORMAT_A2B10G10R10_UNORM_PACK32 => {
                if (prefer_hdr) score += 30;
            },
            c.VK_FORMAT_B8G8R8A8_UNORM => {
                score += 20;
            },
            c.VK_FORMAT_R8G8B8A8_UNORM => {
                score += 15;
            },
            else => {},
        }

        if (score > best_score) {
            best_score = score;
            best = f.*;
        }
    }

    return best;
}

/// Chooses a present mode, preferring `preferred` when it is supported.
pub fn choose_present_mode(modes: [*]const c.VkPresentModeKHR, count: u32, preferred: c.VkPresentModeKHR) c.VkPresentModeKHR {
    var has_mailbox = false;
    var has_fifo_relaxed = false;
    var has_immediate = false;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const mode = modes[i];
        if (mode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
            has_mailbox = true;
        } else if (mode == c.VK_PRESENT_MODE_FIFO_RELAXED_KHR) {
            has_fifo_relaxed = true;
        } else if (mode == c.VK_PRESENT_MODE_IMMEDIATE_KHR) {
            has_immediate = true;
        }
    }

    if (preferred != c.VK_PRESENT_MODE_MAX_ENUM_KHR) {
        var idx: u32 = 0;
        while (idx < count) : (idx += 1) {
            if (modes[idx] == preferred) {
                return preferred;
            }
        }
    }

    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (has_fifo_relaxed) {
            return c.VK_PRESENT_MODE_FIFO_RELAXED_KHR;
        }
        return c.VK_PRESENT_MODE_FIFO_KHR;
    }

    if (has_mailbox) {
        return c.VK_PRESENT_MODE_MAILBOX_KHR;
    }
    if (has_immediate) {
        return c.VK_PRESENT_MODE_IMMEDIATE_KHR;
    }

    return c.VK_PRESENT_MODE_FIFO_KHR;
}
