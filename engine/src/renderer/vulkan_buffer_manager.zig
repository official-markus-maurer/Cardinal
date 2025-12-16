const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const types = @import("vulkan_types.zig");
const vk_allocator = @import("vulkan_allocator.zig");

const c = @import("vulkan_c.zig").c;


pub const VulkanBuffer = types.VulkanBuffer;

pub const VulkanBufferCreateInfo = extern struct {
    size: c.VkDeviceSize,
    usage: c.VkBufferUsageFlags,
    properties: c.VkMemoryPropertyFlags,
    persistentlyMapped: bool,
};

// Helper function to begin a single-time command buffer
fn begin_single_time_commands(device: c.VkDevice, commandPool: c.VkCommandPool) c.VkCommandBuffer {
    var allocInfo = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    allocInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocInfo.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocInfo.commandPool = commandPool;
    allocInfo.commandBufferCount = 1;

    var commandBuffer: c.VkCommandBuffer = null;
    _ = c.vkAllocateCommandBuffers(device, &allocInfo, &commandBuffer);

    var beginInfo = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    beginInfo.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    beginInfo.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    _ = c.vkBeginCommandBuffer(commandBuffer, &beginInfo);
    return commandBuffer;
}

// Helper function to end and submit a single-time command buffer with proper timeline synchronization
fn end_single_time_commands(device: c.VkDevice, commandPool: c.VkCommandPool, queue: c.VkQueue,
                            commandBuffer: c.VkCommandBuffer, vulkan_state: *types.VulkanState) void {
    log.cardinal_log_info("[BUFFER_MANAGER] CMD_END_START: Ending command buffer {any}", .{commandBuffer});
    const result = c.vkEndCommandBuffer(commandBuffer);
    if (result != c.VK_SUCCESS) {
        log.cardinal_log_error("[BUFFER_MANAGER] CMD_END_FAILED: Failed to end command buffer {any}: {d}",
            .{commandBuffer, result});
        c.vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
        return;
    }
    log.cardinal_log_info("[BUFFER_MANAGER] CMD_END_SUCCESS: Command buffer {any} ended successfully",
        .{commandBuffer});

    // Get current semaphore value first to ensure our value is always greater
    var current_value: u64 = 0;
    log.cardinal_log_info("[BUFFER_MANAGER] SEMAPHORE_QUERY: Getting timeline semaphore value for cmd {any}",
        .{commandBuffer});
    
    // Note: accessing function pointer from context
    const query_result = vulkan_state.context.vkGetSemaphoreCounterValue.?(
        vulkan_state.context.device, vulkan_state.sync.timeline_semaphore, &current_value);
        
    if (query_result != c.VK_SUCCESS) {
        log.cardinal_log_error("[BUFFER_MANAGER] SEMAPHORE_QUERY_FAILED: Failed to get timeline semaphore value for cmd {any}: {d}",
            .{commandBuffer, query_result});
        c.vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
        return;
    }
    log.cardinal_log_info("[BUFFER_MANAGER] SEMAPHORE_QUERY_SUCCESS: Current timeline value={d} for cmd {any}",
        .{current_value, commandBuffer});

    // Use atomic increment starting from current semaphore value + 1
    // This ensures we always get a value greater than the current semaphore value
    
    // Zig static variable equivalent
    const Static = struct {
        // Using volatile to match C implementation behavior for thread safety across calls
        // though standard Zig Atomic is preferred.
        // However, the C code used a static volatile/atomic variable inside the function.
        // We'll use a global atomic for this.
        var buffer_timeline_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    };

    // Initialize counter if it's behind the current semaphore value
    const counter_val = Static.buffer_timeline_counter.load(.seq_cst);
    if (counter_val <= current_value) {
        // Using cmpxchg to safely update if still behind, but simple store is what C code did roughly
        // C code: if (val <= cur) store(cur + 1)
        // We can just do a store, assuming this logic is safe enough as per original code
        Static.buffer_timeline_counter.store(current_value + 1, .seq_cst);
    }

    var timeline_value = Static.buffer_timeline_counter.fetchAdd(1, .seq_cst) + 1;

    // Handle overflow by resetting to current_value + 1
    if (timeline_value >= (std.math.maxInt(u64) - 10000)) {
        log.cardinal_log_warn("[BUFFER_MANAGER] Timeline counter near overflow, resetting", .{});
        timeline_value = current_value + 1;
        Static.buffer_timeline_counter.store(timeline_value + 1, .seq_cst);
    }

    // Validate timeline semaphore before use
    if (vulkan_state.sync.timeline_semaphore == null) {
        log.cardinal_log_error("[BUFFER_MANAGER] Timeline semaphore is NULL!", .{});
        c.vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
        return;
    }

    // Ensure timeline value is never 0
    if (timeline_value == 0) {
        log.cardinal_log_error("[BUFFER_MANAGER] Timeline value is 0! Forcing to 1", .{});
        timeline_value = 1;
    }

    log.cardinal_log_debug("[BUFFER_MANAGER] Using timeline value: {d} (current: {d})",
        .{timeline_value, current_value});

    // Submit command buffer with timeline semaphore signaling
    var cmd_buffer_info = std.mem.zeroes(c.VkCommandBufferSubmitInfo);
    cmd_buffer_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO;
    cmd_buffer_info.commandBuffer = commandBuffer;

    var signal_semaphore_info = std.mem.zeroes(c.VkSemaphoreSubmitInfo);
    signal_semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO;
    signal_semaphore_info.semaphore = vulkan_state.sync.timeline_semaphore;
    signal_semaphore_info.value = timeline_value;
    signal_semaphore_info.stageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;

    log.cardinal_log_debug("[BUFFER_MANAGER] About to submit with semaphore {any}, value {d}",
        .{vulkan_state.sync.timeline_semaphore, timeline_value});

    var submit_info = std.mem.zeroes(c.VkSubmitInfo2);
    submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2;
    submit_info.commandBufferInfoCount = 1;
    submit_info.pCommandBufferInfos = &cmd_buffer_info;
    submit_info.signalSemaphoreInfoCount = 1;
    submit_info.pSignalSemaphoreInfos = &signal_semaphore_info;

    log.cardinal_log_info("[BUFFER_MANAGER] CMD_SUBMIT: Submitting command buffer {any} with timeline value {d}",
        .{commandBuffer, timeline_value});
    
    const submit_result = vulkan_state.context.vkQueueSubmit2.?(queue, 1, &submit_info, null);
    if (submit_result != c.VK_SUCCESS) {
        log.cardinal_log_error("[BUFFER_MANAGER] CMD_SUBMIT_FAILED: Failed to submit command buffer {any}: {d}",
            .{commandBuffer, submit_result});
        log.cardinal_log_warn("[BUFFER_MANAGER] CMD_LEAK_WARNING: Command buffer {any} may leak due to submit failure - cannot free while potentially in pending state",
            .{commandBuffer});
        return;
    }
    log.cardinal_log_info("[BUFFER_MANAGER] CMD_SUBMIT_SUCCESS: Command buffer {any} submitted with timeline value {d}",
        .{commandBuffer, timeline_value});

    // Wait for completion using timeline semaphore with reasonable timeout
    var wait_info = std.mem.zeroes(c.VkSemaphoreWaitInfo);
    wait_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
    wait_info.semaphoreCount = 1;
    wait_info.pSemaphores = &vulkan_state.sync.timeline_semaphore;
    wait_info.pValues = &timeline_value;

    log.cardinal_log_info("[BUFFER_MANAGER] CMD_WAIT: Waiting for command buffer {any} completion (timeline value {d})",
        .{commandBuffer, timeline_value});
        
    const wait_result = vulkan_state.context.vkWaitSemaphores.?(vulkan_state.context.device, &wait_info, 10000000000); // 10 second timeout
    if (wait_result != c.VK_SUCCESS) {
        log.cardinal_log_error("[BUFFER_MANAGER] CMD_WAIT_FAILED: Timeline semaphore wait failed for cmd {any} (timeline {d}): {d}",
            .{commandBuffer, timeline_value, wait_result});
        log.cardinal_log_warn("[BUFFER_MANAGER] CMD_LEAK_WARNING: Command buffer {any} may leak due to wait failure - cannot free while potentially in pending state",
            .{commandBuffer});
        return;
    }
    log.cardinal_log_info("[BUFFER_MANAGER] CMD_WAIT_SUCCESS: Command buffer {any} completed (timeline value {d})",
        .{commandBuffer, timeline_value});

    // Update VulkanState timeline tracking to maintain coordination
    // This ensures other systems know about the latest completed timeline value
    if (timeline_value > vulkan_state.sync.current_frame_value) {
        vulkan_state.sync.current_frame_value = timeline_value;
        log.cardinal_log_info("[BUFFER_MANAGER] TIMELINE_UPDATE: Updated current_frame_value to {d} for cmd {any}",
            .{timeline_value, commandBuffer});
    }

    // Free the command buffer after completion
    log.cardinal_log_info("[BUFFER_MANAGER] CMD_FREE: Freeing command buffer {any}", .{commandBuffer});
    c.vkFreeCommandBuffers(device, commandPool, 1, &commandBuffer);
    log.cardinal_log_info("[BUFFER_MANAGER] CMD_FREE_SUCCESS: Command buffer {any} freed", .{commandBuffer});

    log.cardinal_log_info("[BUFFER_MANAGER] CMD_COMPLETE: Buffer operation completed successfully with timeline value {d}",
        .{timeline_value});
}

pub export fn vk_buffer_create(buffer_ptr: ?*VulkanBuffer, device: c.VkDevice, allocator_ptr: ?*types.VulkanAllocator,
                               createInfo_ptr: ?*const VulkanBufferCreateInfo) callconv(.c) bool {
    // Basic validation
    if (device == null or allocator_ptr == null or createInfo_ptr == null or buffer_ptr == null) {
        log.cardinal_log_error("Invalid parameters for buffer creation", .{});
        return false;
    }

    const buffer = buffer_ptr.?;
    const allocator = allocator_ptr.?;
    const createInfo = createInfo_ptr.?;

    if (createInfo.size == 0) {
        log.cardinal_log_error("Buffer size cannot be zero", .{});
        return false;
    }

    // Clear buffer struct
    @memset(@as([*]u8, @ptrCast(buffer))[0..@sizeOf(VulkanBuffer)], 0);

    // Create buffer info
    var bufferInfo = std.mem.zeroes(c.VkBufferCreateInfo);
    bufferInfo.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferInfo.size = createInfo.size;
    bufferInfo.usage = createInfo.usage;
    bufferInfo.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    // Allocate buffer and memory using allocator
    if (!vk_allocator.vk_allocator_allocate_buffer(allocator, &bufferInfo, &buffer.handle, &buffer.memory,
                                      createInfo.properties)) {
        log.cardinal_log_error("Failed to create and allocate buffer", .{});
        return false;
    }

    buffer.size = createInfo.size;
    buffer.usage = createInfo.usage;
    buffer.properties = createInfo.properties;
    buffer.mapped = null;

    // Map memory if requested
    if (createInfo.persistentlyMapped) {
        buffer.mapped = vk_buffer_map(buffer, device, 0, c.VK_WHOLE_SIZE);
        if (buffer.mapped == null) {
            log.cardinal_log_warn("Failed to persistently map buffer memory", .{});
        }
    }

    log.cardinal_log_debug("Created buffer with size {d} bytes", .{createInfo.size});
    return true;
}

fn wait_for_buffer_idle(buffer: *VulkanBuffer, device: c.VkDevice, vulkan_state: ?*types.VulkanState) void {
    if (vulkan_state) |state| {
        if (state.sync.timeline_semaphore != null) {
            var current_value: u64 = 0;
            log.cardinal_log_info("[BUFFER_MANAGER] SYNC_CHECK: Getting timeline semaphore value for buffer={any}",
                .{buffer.handle});
            
            const result = state.context.vkGetSemaphoreCounterValue.?(
                state.context.device, state.sync.timeline_semaphore, &current_value);
            
            log.cardinal_log_info("[BUFFER_MANAGER] SYNC_VALUE: buffer={any} semaphore_value={d} result={d}",
                .{buffer.handle, current_value, result});

            if (result == c.VK_SUCCESS and current_value > 0) {
                // Wait for all submitted operations to complete
                var wait_info = std.mem.zeroes(c.VkSemaphoreWaitInfo);
                wait_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO;
                wait_info.semaphoreCount = 1;
                wait_info.pSemaphores = &state.sync.timeline_semaphore;
                wait_info.pValues = &current_value;

                log.cardinal_log_info("[BUFFER_MANAGER] SYNC_WAIT: Waiting for timeline semaphore value {d} for buffer={any}",
                    .{current_value, buffer.handle});
                    
                const wait_result = state.context.vkWaitSemaphores.?(
                    state.context.device, &wait_info, 5000000000); // 5 second timeout
                    
                if (wait_result != c.VK_SUCCESS) {
                    log.cardinal_log_error("[BUFFER_MANAGER] SYNC_FAILED: Timeline semaphore wait failed for buffer={any}: {d}, falling back to device wait idle",
                        .{buffer.handle, wait_result});
                    const idle_result = c.vkDeviceWaitIdle(device);
                    log.cardinal_log_info("[BUFFER_MANAGER] DEVICE_WAIT_IDLE: result={d} for buffer={any}",
                        .{idle_result, buffer.handle});
                } else {
                    log.cardinal_log_info("[BUFFER_MANAGER] SYNC_SUCCESS: Timeline semaphore wait completed for buffer={any}",
                        .{buffer.handle});
                }
            } else {
                // Fallback to device wait idle if timeline semaphore query fails
                log.cardinal_log_warn("[BUFFER_MANAGER] SYNC_FALLBACK: Failed to get timeline semaphore value (result={d}, value={d}), using device wait idle for buffer={any}",
                    .{result, current_value, buffer.handle});
                const idle_result = c.vkDeviceWaitIdle(device);
                log.cardinal_log_info("[BUFFER_MANAGER] DEVICE_WAIT_IDLE: result={d} for buffer={any}",
                    .{idle_result, buffer.handle});
            }
        } else {
             // Fallback to device wait idle if no timeline semaphore available
            log.cardinal_log_warn("[BUFFER_MANAGER] NO_TIMELINE_SEMAPHORE: Using device wait idle for buffer={any}",
                .{buffer.handle});
            const idle_result = c.vkDeviceWaitIdle(device);
            log.cardinal_log_info("[BUFFER_MANAGER] DEVICE_WAIT_IDLE: result={d} for buffer={any}",
                .{idle_result, buffer.handle});
        }
    } else {
        // Fallback to device wait idle if no vulkan_state
        log.cardinal_log_warn("[BUFFER_MANAGER] NO_VULKAN_STATE: Using device wait idle for buffer={any}",
            .{buffer.handle});
        const idle_result = c.vkDeviceWaitIdle(device);
        log.cardinal_log_info("[BUFFER_MANAGER] DEVICE_WAIT_IDLE: result={d} for buffer={any}",
            .{idle_result, buffer.handle});
    }
}

fn cleanup_buffer_resources(buffer: *VulkanBuffer, device: c.VkDevice, allocator: ?*types.VulkanAllocator) void {
    // Unmap if mapped
    if (buffer.mapped != null) {
        log.cardinal_log_info("[BUFFER_MANAGER] UNMAP: Unmapping buffer={any}", .{buffer.handle});
        vk_buffer_unmap(buffer, device);
        log.cardinal_log_info("[BUFFER_MANAGER] UNMAPPED: buffer={any}", .{buffer.handle});
    }

    // Free buffer and memory
    if (allocator) |alloc| {
        log.cardinal_log_info("[BUFFER_MANAGER] FREE_START: About to free buffer={any} memory={any}",
            .{buffer.handle, buffer.memory});
        vk_allocator.vk_allocator_free_buffer(alloc, buffer.handle, buffer.memory);
        log.cardinal_log_info("[BUFFER_MANAGER] FREE_COMPLETE: Freed buffer={any} memory={any}",
            .{buffer.handle, buffer.memory});
    } else {
        log.cardinal_log_warn("Allocator is null, cannot free buffer memory", .{});
    }

    // Clear structure
    @memset(@as([*]u8, @ptrCast(buffer))[0..@sizeOf(VulkanBuffer)], 0);
}

pub export fn vk_buffer_destroy(buffer_ptr: ?*VulkanBuffer, device: c.VkDevice, allocator: ?*types.VulkanAllocator,
                                vulkan_state: ?*types.VulkanState) callconv(.c) void {
    if (buffer_ptr == null) {
        log.cardinal_log_warn("[BUFFER_MANAGER] DESTROY_SKIP: Invalid buffer pointer", .{});
        return;
    }
    const buffer = buffer_ptr.?;

    if (buffer.handle == null) {
        log.cardinal_log_warn("[BUFFER_MANAGER] DESTROY_SKIP: Invalid buffer or null handle", .{});
        return;
    }

    log.cardinal_log_info("[BUFFER_MANAGER] DESTROY_START: buffer={any} handle={any} memory={any} mapped={any}",
        .{buffer, buffer.handle, buffer.memory, buffer.mapped});

    // Wait for buffer to be idle
    wait_for_buffer_idle(buffer, device, vulkan_state);

    // Cleanup resources
    cleanup_buffer_resources(buffer, device, allocator);

    log.cardinal_log_info("[BUFFER_MANAGER] DESTROY_COMPLETE: Buffer structure cleared", .{});
}

pub export fn vk_buffer_upload_data(buffer_ptr: ?*VulkanBuffer, device: c.VkDevice, data: ?*const anyopaque,
                                    size: c.VkDeviceSize, offset: c.VkDeviceSize) callconv(.c) bool {
    if (data == null or buffer_ptr == null) {
        log.cardinal_log_error("Invalid parameters for buffer data upload", .{});
        return false;
    }
    const buffer = buffer_ptr.?;

    if (buffer.handle == null) {
        log.cardinal_log_error("Invalid buffer handle for data upload", .{});
        return false;
    }

    if (offset + size > buffer.size) {
        log.cardinal_log_error("Upload data exceeds buffer size", .{});
        return false;
    }

    // Check if buffer is host visible
    if ((buffer.properties & c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) == 0) {
        log.cardinal_log_error("Buffer is not host visible, cannot upload data directly", .{});
        return false;
    }

    var mappedData: ?*anyopaque = null;
    if (buffer.mapped) |mapped| {
        // Use existing mapping
        // Zig pointer arithmetic needs casting to byte pointer first
        const mappedBytes = @as([*]u8, @ptrCast(mapped));
        mappedData = @ptrCast(mappedBytes + offset);
        @memcpy(@as([*]u8, @ptrCast(mappedData))[0..size], @as([*]const u8, @ptrCast(data))[0..size]);
    } else {
        // Temporary mapping
        if (c.vkMapMemory(device, buffer.memory, offset, size, 0, &mappedData) != c.VK_SUCCESS) {
            log.cardinal_log_error("Failed to map buffer memory for data upload", .{});
            return false;
        }

        @memcpy(@as([*]u8, @ptrCast(mappedData))[0..size], @as([*]const u8, @ptrCast(data))[0..size]);
        c.vkUnmapMemory(device, buffer.memory);
    }

    // Flush if memory is not coherent
    if ((buffer.properties & c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) == 0) {
        var range = std.mem.zeroes(c.VkMappedMemoryRange);
        range.sType = c.VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
        range.memory = buffer.memory;
        range.offset = offset;
        range.size = size;
        _ = c.vkFlushMappedMemoryRanges(device, 1, &range);
    }

    return true;
}

pub export fn vk_buffer_map(buffer_ptr: ?*VulkanBuffer, device: c.VkDevice, offset: c.VkDeviceSize, size: c.VkDeviceSize) callconv(.c) ?*anyopaque {
    if (buffer_ptr == null) {
        log.cardinal_log_error("Invalid buffer pointer for mapping", .{});
        return null;
    }
    const buffer = buffer_ptr.?;

    if (buffer.handle == null) {
        log.cardinal_log_error("Invalid buffer handle for mapping", .{});
        return null;
    }

    if ((buffer.properties & c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) == 0) {
        log.cardinal_log_error("Buffer is not host visible, cannot map", .{});
        return null;
    }

    var mappedData: ?*anyopaque = null;
    if (c.vkMapMemory(device, buffer.memory, offset, size, 0, &mappedData) != c.VK_SUCCESS) {
        log.cardinal_log_error("Failed to map buffer memory", .{});
        return null;
    }

    if (buffer.mapped == null and size == c.VK_WHOLE_SIZE) {
        buffer.mapped = mappedData;
    }

    return mappedData;
}

pub export fn vk_buffer_unmap(buffer_ptr: ?*VulkanBuffer, device: c.VkDevice) callconv(.c) void {
    if (buffer_ptr == null) {
        return;
    }
    const buffer = buffer_ptr.?;

    if (buffer.handle == null) {
        return;
    }

    if (buffer.mapped != null) {
        c.vkUnmapMemory(device, buffer.memory);
        buffer.mapped = null;
    }
}

pub export fn vk_buffer_create_device_local(buffer_ptr: ?*VulkanBuffer, device: c.VkDevice,
                                            allocator_ptr: ?*types.VulkanAllocator, commandPool: c.VkCommandPool,
                                            queue: c.VkQueue, data: ?*const anyopaque, size: c.VkDeviceSize,
                                            usage: c.VkBufferUsageFlags, vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    if (data == null or size == 0 or buffer_ptr == null) {
        return false;
    }
    const buffer = buffer_ptr.?;
    const allocator = allocator_ptr.?; // Assuming allocator is required here as we use it

    // Create staging buffer
    var stagingInfo = std.mem.zeroes(VulkanBufferCreateInfo);
    stagingInfo.size = size;
    stagingInfo.usage = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    stagingInfo.properties = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    stagingInfo.persistentlyMapped = false;

    var stagingBuffer: VulkanBuffer = undefined;
    if (!vk_buffer_create(&stagingBuffer, device, allocator, &stagingInfo)) {
        log.cardinal_log_error("Failed to create staging buffer", .{});
        return false;
    }

    // Upload data to staging buffer
    if (!vk_buffer_upload_data(&stagingBuffer, device, data, size, 0)) {
        log.cardinal_log_error("Failed to upload data to staging buffer", .{});
        vk_buffer_destroy(&stagingBuffer, device, allocator, vulkan_state);
        return false;
    }

    // Create device local buffer
    var deviceBufferInfo = std.mem.zeroes(VulkanBufferCreateInfo);
    deviceBufferInfo.size = size;
    deviceBufferInfo.usage = @bitCast(@as(u32, @bitCast(c.VK_BUFFER_USAGE_TRANSFER_DST_BIT)) | usage);
    deviceBufferInfo.properties = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    deviceBufferInfo.persistentlyMapped = false;

    if (!vk_buffer_create(buffer, device, allocator, &deviceBufferInfo)) {
        log.cardinal_log_error("Failed to create device local buffer", .{});
        vk_buffer_destroy(&stagingBuffer, device, allocator, vulkan_state);
        return false;
    }

    // Copy from staging to device buffer
    if (!vk_buffer_copy(device, commandPool, queue, stagingBuffer.handle, buffer.handle, size, 0,
                        0, vulkan_state)) {
        log.cardinal_log_error("Failed to copy data to device buffer", .{});
        vk_buffer_destroy(buffer, device, allocator, vulkan_state);
        vk_buffer_destroy(&stagingBuffer, device, allocator, vulkan_state);
        return false;
    }

    // Clean up staging buffer
    vk_buffer_destroy(&stagingBuffer, device, allocator, vulkan_state);

    return true;
}

pub export fn vk_buffer_create_vertex(buffer: ?*VulkanBuffer, device: c.VkDevice, allocator: ?*types.VulkanAllocator,
                                      commandPool: c.VkCommandPool, queue: c.VkQueue, vertices: ?*const anyopaque,
                                      vertexSize: c.VkDeviceSize, vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    if (vertices == null or vertexSize == 0) {
        log.cardinal_log_error("Invalid vertex data for buffer creation", .{});
        return false;
    }

    if (!vk_buffer_create_device_local(buffer, device, allocator, commandPool, queue, vertices,
                                       vertexSize, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                                       vulkan_state)) {
        log.cardinal_log_error("Failed to create vertex buffer", .{});
        return false;
    }

    log.cardinal_log_debug("Created vertex buffer with {d} bytes", .{vertexSize});
    return true;
}

pub export fn vk_buffer_create_index(buffer: ?*VulkanBuffer, device: c.VkDevice, allocator: ?*types.VulkanAllocator,
                                     commandPool: c.VkCommandPool, queue: c.VkQueue, indices: ?*const anyopaque,
                                     indexSize: c.VkDeviceSize, vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    if (indices == null or indexSize == 0) {
        log.cardinal_log_error("Invalid index data for buffer creation", .{});
        return false;
    }

    if (!vk_buffer_create_device_local(buffer, device, allocator, commandPool, queue, indices,
                                       indexSize, c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT, vulkan_state)) {
        log.cardinal_log_error("Failed to create index buffer", .{});
        return false;
    }

    log.cardinal_log_debug("Created index buffer with {d} bytes", .{indexSize});
    return true;
}

pub export fn vk_buffer_create_uniform(buffer: ?*VulkanBuffer, device: c.VkDevice, allocator: ?*types.VulkanAllocator,
                                       size: c.VkDeviceSize) callconv(.c) bool {
    if (size == 0) {
        log.cardinal_log_error("Uniform buffer size cannot be zero", .{});
        return false;
    }

    var uniformInfo = std.mem.zeroes(VulkanBufferCreateInfo);
    uniformInfo.size = size;
    uniformInfo.usage = c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    uniformInfo.properties =
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    uniformInfo.persistentlyMapped = true;

    if (!vk_buffer_create(buffer, device, allocator, &uniformInfo)) {
        log.cardinal_log_error("Failed to create uniform buffer", .{});
        return false;
    }

    log.cardinal_log_debug("Created uniform buffer with {d} bytes", .{size});
    return true;
}

pub export fn vk_buffer_copy(device: c.VkDevice, commandPool: c.VkCommandPool, queue: c.VkQueue, srcBuffer: c.VkBuffer,
                             dstBuffer: c.VkBuffer, size: c.VkDeviceSize, srcOffset: c.VkDeviceSize,
                             dstOffset: c.VkDeviceSize, vulkan_state: ?*types.VulkanState) callconv(.c) bool {
    if (srcBuffer == null or dstBuffer == null or size == 0 or vulkan_state == null) {
        log.cardinal_log_error("Invalid parameters for buffer copy", .{});
        return false;
    }
    const state = vulkan_state.?;

    const commandBuffer = begin_single_time_commands(device, commandPool);
    if (commandBuffer == null) {
        log.cardinal_log_error("Failed to begin command buffer for buffer copy", .{});
        return false;
    }

    var copyRegion = std.mem.zeroes(c.VkBufferCopy);
    copyRegion.srcOffset = srcOffset;
    copyRegion.dstOffset = dstOffset;
    copyRegion.size = size;

    c.vkCmdCopyBuffer(commandBuffer, srcBuffer, dstBuffer, 1, &copyRegion);

    end_single_time_commands(device, commandPool, queue, commandBuffer, state);

    return true;
}
