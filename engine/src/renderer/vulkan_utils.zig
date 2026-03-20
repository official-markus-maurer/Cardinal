//! Vulkan utility helpers.
//!
//! Provides common Vulkan result logging, pointer validation, and small creation helpers used by
//! multiple renderer modules.
const core = @import("vulkan_utils_core.zig");
const create = @import("vulkan_utils_create.zig");

pub const vk_utils_check_result = core.vk_utils_check_result;
pub const vk_utils_result_string = core.vk_utils_result_string;
pub const vk_utils_allocate = core.vk_utils_allocate;
pub const vk_utils_reallocate = core.vk_utils_reallocate;
pub const vk_utils_validate_pointer = core.vk_utils_validate_pointer;
pub const vk_utils_validate_handle = core.vk_utils_validate_handle;

pub const vk_utils_create_semaphore = create.vk_utils_create_semaphore;
pub const vk_utils_create_fence = create.vk_utils_create_fence;
pub const vk_utils_create_command_pool = create.vk_utils_create_command_pool;
pub const vk_utils_create_descriptor_pool = create.vk_utils_create_descriptor_pool;
pub const vk_utils_create_pipeline_layout = create.vk_utils_create_pipeline_layout;
pub const vk_utils_create_sampler = create.vk_utils_create_sampler;
