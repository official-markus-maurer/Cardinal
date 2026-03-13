//! Small Vulkan C API wrappers with Zig error handling.
//!
//! Provides a lightweight `Device` wrapper that converts `VkResult` to a Zig error set.
//!
//! TODO: Expand coverage or delete this module if unused in favor of `vulkan_utils.zig`.
const std = @import("std");
const c = @import("vulkan_c.zig").c;

/// Vulkan error set mapped from `VkResult`.
pub const VulkanError = error{
    InitializationFailed,
    OutOfMemory,
    DeviceLost,
    ExtensionNotPresent,
    FeatureNotPresent,
    TooManyObjects,
    FormatNotSupported,
    FragmentedPool,
    Unknown,
    SurfaceLost,
    NativeWindowInUse,
    IncompatibleDriver,
};

/// Converts a `VkResult` into a Zig error.
fn checkResult(result: c.VkResult) VulkanError!void {
    if (result == c.VK_SUCCESS) return;
    return switch (result) {
        c.VK_ERROR_OUT_OF_HOST_MEMORY, c.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfMemory,
        c.VK_ERROR_INITIALIZATION_FAILED => error.InitializationFailed,
        c.VK_ERROR_DEVICE_LOST => error.DeviceLost,
        c.VK_ERROR_EXTENSION_NOT_PRESENT => error.ExtensionNotPresent,
        c.VK_ERROR_FEATURE_NOT_PRESENT => error.FeatureNotPresent,
        c.VK_ERROR_TOO_MANY_OBJECTS => error.TooManyObjects,
        c.VK_ERROR_FORMAT_NOT_SUPPORTED => error.FormatNotSupported,
        c.VK_ERROR_FRAGMENTED_POOL => error.FragmentedPool,
        c.VK_ERROR_SURFACE_LOST_KHR => error.SurfaceLost,
        c.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => error.NativeWindowInUse,
        c.VK_ERROR_INCOMPATIBLE_DRIVER => error.IncompatibleDriver,
        else => error.Unknown,
    };
}

/// Wrapper around a `VkDevice` handle.
pub const Device = struct {
    handle: c.VkDevice,

    /// Wraps an existing device handle.
    pub fn init(handle: c.VkDevice) Device {
        return .{ .handle = handle };
    }

    /// Waits for the device to become idle.
    pub fn waitIdle(self: Device) VulkanError!void {
        try checkResult(c.vkDeviceWaitIdle(self.handle));
    }

    /// Creates a shader module from SPIR-V bytecode.
    pub fn createShaderModule(self: Device, code: []const u8) VulkanError!c.VkShaderModule {
        var createInfo = std.mem.zeroes(c.VkShaderModuleCreateInfo);
        createInfo.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        createInfo.codeSize = code.len;
        createInfo.pCode = @ptrCast(@alignCast(code.ptr));

        var shaderModule: c.VkShaderModule = null;
        try checkResult(c.vkCreateShaderModule(self.handle, &createInfo, null, &shaderModule));
        return shaderModule;
    }

    /// Destroys a shader module.
    pub fn destroyShaderModule(self: Device, module: c.VkShaderModule) void {
        if (module != null) {
            c.vkDestroyShaderModule(self.handle, module, null);
        }
    }

    /// Creates a descriptor set layout from provided bindings.
    pub fn createDescriptorSetLayout(self: Device, bindings: []const c.VkDescriptorSetLayoutBinding) VulkanError!c.VkDescriptorSetLayout {
        var createInfo = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        createInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        createInfo.bindingCount = @intCast(bindings.len);
        createInfo.pBindings = bindings.ptr;

        var layout: c.VkDescriptorSetLayout = null;
        try checkResult(c.vkCreateDescriptorSetLayout(self.handle, &createInfo, null, &layout));
        return layout;
    }

    /// Destroys a descriptor set layout.
    pub fn destroyDescriptorSetLayout(self: Device, layout: c.VkDescriptorSetLayout) void {
        if (layout != null) {
            c.vkDestroyDescriptorSetLayout(self.handle, layout, null);
        }
    }

    /// Creates a descriptor pool.
    pub fn createDescriptorPool(self: Device, poolSizes: []const c.VkDescriptorPoolSize, maxSets: u32) VulkanError!c.VkDescriptorPool {
        var createInfo = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        createInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        createInfo.poolSizeCount = @intCast(poolSizes.len);
        createInfo.pPoolSizes = if (poolSizes.len > 0) poolSizes.ptr else null;
        createInfo.maxSets = maxSets;

        var pool: c.VkDescriptorPool = null;
        try checkResult(c.vkCreateDescriptorPool(self.handle, &createInfo, null, &pool));
        return pool;
    }

    /// Destroys a descriptor pool.
    pub fn destroyDescriptorPool(self: Device, pool: c.VkDescriptorPool) void {
        if (pool != null) {
            c.vkDestroyDescriptorPool(self.handle, pool, null);
        }
    }

    /// Allocates descriptor sets into `sets` (length must match `layouts`).
    pub fn allocateDescriptorSets(self: Device, descriptorPool: c.VkDescriptorPool, layouts: []const c.VkDescriptorSetLayout, sets: []c.VkDescriptorSet) VulkanError!void {
        if (layouts.len != sets.len) return error.InitializationFailed;

        var allocInfo = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        allocInfo.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocInfo.descriptorPool = descriptorPool;
        allocInfo.descriptorSetCount = @intCast(layouts.len);
        allocInfo.pSetLayouts = if (layouts.len > 0) layouts.ptr else null;

        try checkResult(c.vkAllocateDescriptorSets(self.handle, &allocInfo, sets.ptr));
    }

    /// Creates a pipeline layout.
    pub fn createPipelineLayout(self: Device, setLayouts: []const c.VkDescriptorSetLayout, pushConstantRanges: []const c.VkPushConstantRange) VulkanError!c.VkPipelineLayout {
        var createInfo = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        createInfo.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        createInfo.setLayoutCount = @intCast(setLayouts.len);
        createInfo.pSetLayouts = if (setLayouts.len > 0) setLayouts.ptr else null;
        createInfo.pushConstantRangeCount = @intCast(pushConstantRanges.len);
        createInfo.pPushConstantRanges = if (pushConstantRanges.len > 0) pushConstantRanges.ptr else null;

        var layout: c.VkPipelineLayout = null;
        try checkResult(c.vkCreatePipelineLayout(self.handle, &createInfo, null, &layout));
        return layout;
    }

    /// Destroys a pipeline layout.
    pub fn destroyPipelineLayout(self: Device, layout: c.VkPipelineLayout) void {
        if (layout != null) {
            c.vkDestroyPipelineLayout(self.handle, layout, null);
        }
    }

    /// Updates descriptor sets using `writes` and `copies`.
    pub fn updateDescriptorSets(self: Device, writes: []const c.VkWriteDescriptorSet, copies: []const c.VkCopyDescriptorSet) void {
        c.vkUpdateDescriptorSets(self.handle, @intCast(writes.len), if (writes.len > 0) writes.ptr else null, @intCast(copies.len), if (copies.len > 0) copies.ptr else null);
    }
};

/// Wrapper around a `VkQueue` handle.
pub const Queue = struct {
    handle: c.VkQueue,

    /// Wraps an existing queue handle.
    pub fn init(handle: c.VkQueue) Queue {
        return .{ .handle = handle };
    }

    /// Waits for the queue to become idle.
    pub fn waitIdle(self: Queue) VulkanError!void {
        try checkResult(c.vkQueueWaitIdle(self.handle));
    }

    /// Submits `submits` to the queue.
    pub fn submit(self: Queue, submits: []const c.VkSubmitInfo, fence: c.VkFence) VulkanError!void {
        try checkResult(c.vkQueueSubmit(self.handle, @intCast(submits.len), submits.ptr, fence));
    }
};

/// Wrapper around a `VkCommandBuffer` handle.
pub const CommandBuffer = struct {
    handle: c.VkCommandBuffer,

    /// Wraps an existing command buffer handle.
    pub fn init(handle: c.VkCommandBuffer) CommandBuffer {
        return .{ .handle = handle };
    }

    /// Begins recording using `usage` flags.
    pub fn beginRecording(self: CommandBuffer, usage: c.VkCommandBufferUsageFlags) VulkanError!void {
        var beginInfo = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        beginInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = usage;
        try checkResult(c.vkBeginCommandBuffer(self.handle, &beginInfo));
    }

    /// Ends recording.
    pub fn endRecording(self: CommandBuffer) VulkanError!void {
        try checkResult(c.vkEndCommandBuffer(self.handle));
    }

    /// Resets the command buffer.
    pub fn reset(self: CommandBuffer, flags: c.VkCommandBufferResetFlags) VulkanError!void {
        try checkResult(c.vkResetCommandBuffer(self.handle, flags));
    }

    /// Binds a pipeline.
    pub fn bindPipeline(self: CommandBuffer, bindPoint: c.VkPipelineBindPoint, pipeline: c.VkPipeline) void {
        c.vkCmdBindPipeline(self.handle, bindPoint, pipeline);
    }

    /// Binds descriptor sets.
    pub fn bindDescriptorSets(self: CommandBuffer, bindPoint: c.VkPipelineBindPoint, layout: c.VkPipelineLayout, firstSet: u32, sets: []const c.VkDescriptorSet, dynamicOffsets: []const u32) void {
        c.vkCmdBindDescriptorSets(self.handle, bindPoint, layout, firstSet, @intCast(sets.len), sets.ptr, @intCast(dynamicOffsets.len), if (dynamicOffsets.len > 0) dynamicOffsets.ptr else null);
    }

    /// Binds vertex buffers.
    pub fn bindVertexBuffers(self: CommandBuffer, firstBinding: u32, buffers: []const c.VkBuffer, offsets: []const c.VkDeviceSize) void {
        c.vkCmdBindVertexBuffers(self.handle, firstBinding, @intCast(buffers.len), buffers.ptr, offsets.ptr);
    }

    /// Binds an index buffer.
    pub fn bindIndexBuffer(self: CommandBuffer, buffer: c.VkBuffer, offset: c.VkDeviceSize, indexType: c.VkIndexType) void {
        c.vkCmdBindIndexBuffer(self.handle, buffer, offset, indexType);
    }

    /// Records a non-indexed draw call.
    pub fn draw(self: CommandBuffer, vertexCount: u32, instanceCount: u32, firstVertex: u32, firstInstance: u32) void {
        c.vkCmdDraw(self.handle, vertexCount, instanceCount, firstVertex, firstInstance);
    }

    /// Records an indexed draw call.
    pub fn drawIndexed(self: CommandBuffer, indexCount: u32, instanceCount: u32, firstIndex: u32, vertexOffset: i32, firstInstance: u32) void {
        c.vkCmdDrawIndexed(self.handle, indexCount, instanceCount, firstIndex, vertexOffset, firstInstance);
    }

    /// Pushes constants.
    pub fn pushConstants(self: CommandBuffer, layout: c.VkPipelineLayout, stageFlags: c.VkShaderStageFlags, offset: u32, size: u32, pValues: *const anyopaque) void {
        c.vkCmdPushConstants(self.handle, layout, stageFlags, offset, size, pValues);
    }

    /// Sets viewports.
    pub fn setViewport(self: CommandBuffer, firstViewport: u32, viewports: []const c.VkViewport) void {
        c.vkCmdSetViewport(self.handle, firstViewport, @intCast(viewports.len), viewports.ptr);
    }

    /// Sets scissors.
    pub fn setScissor(self: CommandBuffer, firstScissor: u32, scissors: []const c.VkRect2D) void {
        c.vkCmdSetScissor(self.handle, firstScissor, @intCast(scissors.len), scissors.ptr);
    }
};
