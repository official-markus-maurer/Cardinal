const std = @import("std");
const c = @import("vulkan_c.zig").c;
const types = @import("vulkan_types.zig");
const math = @import("../core/math.zig");
const log = @import("../core/log.zig");
const vk_pbr = @import("vulkan_pbr.zig");
const scene = @import("../assets/scene.zig");
const animation = @import("../core/animation.zig");
const wrappers = @import("vulkan_wrappers.zig");
const vk_pso = @import("vulkan_pso.zig");
const material_utils = @import("util/vulkan_material_utils.zig");
const descriptor_mgr = @import("vulkan_descriptor_manager.zig");

const SHADOW_MAP_SIZE = 2048;
const SHADOW_CASCADE_COUNT = 4;

fn mat4_identity() math.Mat4 {
    return math.Mat4.identity();
}

fn mat4_ortho(left: f32, right: f32, bottom: f32, top: f32, zNear: f32, zFar: f32) math.Mat4 {
    return math.Mat4.ortho(left, right, bottom, top, zNear, zFar);
}

fn mat4_lookAt(eye: math.Vec3, center: math.Vec3, up: math.Vec3) math.Mat4 {
    return math.Mat4.lookAt(eye, center, up);
}

pub fn vk_shadow_render(s: *types.VulkanState, cmd: c.VkCommandBuffer) void {
    if (!s.pipelines.use_pbr_pipeline or !s.pipelines.pbr_pipeline.initialized) {
        // log.cardinal_log_warn("Shadow: PBR pipeline not ready", .{});
        return;
    }
    const pipe = &s.pipelines.pbr_pipeline;
    if (pipe.shadowPipeline == null) {
        log.cardinal_log_warn("Shadow: Shadow pipeline is null", .{});
        return;
    }
    
    if (pipe.lightingBufferMapped == null or pipe.uniformBufferMapped == null) {
        log.cardinal_log_warn("Shadow: Buffers not mapped", .{});
        return;
    }

    const ubo = @as(*types.PBRUniformBufferObject, @ptrCast(@alignCast(pipe.uniformBufferMapped)));
    const lighting = @as(*types.PBRLightingBuffer, @ptrCast(@alignCast(pipe.lightingBufferMapped)));
    
    if (lighting.count == 0) {
        log.cardinal_log_warn("Shadow: No lights in lighting buffer", .{});
        return;
    }
    
    // Find first directional light
    var lightDir: math.Vec3 = math.Vec3.zero();
    var found = false;
    var i: u32 = 0;
    while(i < lighting.count) : (i += 1) {
        const l_type = lighting.lights[i].lightDirection[3];
        // Tolerance check for float equality
        if (l_type > -0.1 and l_type < 0.1) { // Directional (approx 0.0)
             lightDir = math.Vec3{
                 .x = lighting.lights[i].lightDirection[0],
                 .y = lighting.lights[i].lightDirection[1],
                 .z = lighting.lights[i].lightDirection[2]
             };
             found = true;
             log.cardinal_log_info("Shadow: Found directional light {d}: ({d:.2}, {d:.2}, {d:.2})", .{i, lightDir.x, lightDir.y, lightDir.z});
             break;
        }
    }
    
    if (!found) {
        log.cardinal_log_warn("Shadow: No directional light found", .{});
        return;
    }
    
    lightDir = lightDir.normalize();

    // Extract camera properties from UBO (assuming updated)
    // We need camera position and orientation (View Matrix) to calculate frustum splits
    // UBO has View and Proj.
    // We need inverse ViewProj to get frustum corners.
    const view = math.Mat4.fromArray(ubo.view);
    const proj = math.Mat4.fromArray(ubo.proj);
    
    var cascadeSplits = [_]f32{0} ** 4;
    var lightSpaceMatrices = [_]math.Mat4{mat4_identity()} ** 4;
    
    const nearClip: f32 = 0.1;
    const farClip: f32 = 1000.0; // TODO: Get from camera
    
    const minZ = nearClip;
    const maxZ = farClip;
    const ratio = maxZ / minZ;
    const range = maxZ - minZ;
    
    const lambda: f32 = 0.95;
    
    var lastSplitDist: f32 = 0.0;
    
    var j: usize = 0;
    while (j < SHADOW_CASCADE_COUNT) : (j += 1) {
        const p = @as(f32, @floatFromInt(j + 1)) / @as(f32, @floatFromInt(SHADOW_CASCADE_COUNT));
        const logC = minZ * std.math.pow(f32, ratio, p);
        const uniC = minZ + range * p;
        const d = lambda * logC + (1.0 - lambda) * uniC;
        cascadeSplits[j] = d; // Store actual depth for comparison
        
        // Corners in NDC
        // We use splitDist to interpolate between near and far corners?
        // Better: Project 8 corners of sub-frustum (lastSplitDist to d)
        // Or simpler: Use invViewProj and transform NDC corners
        
        // This requires recalculating corners for each split.
        // Simplified approach:
        // Calculate center of frustum slice, lookAt from light direction.
        // Or: Transform NDC corners to World, then to Light Space, then build Ortho.
        
        // Let's implement Stable CSM (Fit to scene).
        // For simplicity: Fit to frustum slice.
        
        // 1. Calculate corners of sub-frustum in World Space directly
        // This avoids dependency on invView matrix which might be problematic
        
        // Calculate World Space Frustum Corners
        // Center = camPos + camForward * dist
        // Width = dist * tanHalfFov * aspect * 2
        // Height = dist * tanHalfFov * 2
        
        const camPos = math.Vec3.fromArray(ubo.viewPos);
        // Extract Camera Basis from View Matrix (Column-Major)
        // Col 0: Right, Col 1: Up, Col 2: -Forward
        const camRight = math.Vec3{ .x = view.data[0], .y = view.data[4], .z = view.data[8] };
        const camUp = math.Vec3{ .x = view.data[1], .y = view.data[5], .z = view.data[9] };
        const camForward = math.Vec3{ .x = -view.data[2], .y = -view.data[6], .z = -view.data[10] };
        
        // Calculate Light View Matrix (Initial - only used to define split center if we wanted, but we use cam properties)
         // Actually we don't need this lightView anymore if we use the stabilized one.
         // But let's keep it for now if needed, or remove it.
         // const lightView_unused = mat4_lookAt(lightEye, center, up); // Unused now
         
         const tanHalfFov = 1.0 / proj.data[5]; // Can be negative if Y is flipped
         const aspect = proj.data[5] / proj.data[0];
         
         // Helper to get corners at a specific distance
         const getCornersAtDist = struct {
             fn call(dist: f32, cPos: math.Vec3, cFwd: math.Vec3, cRight: math.Vec3, cUp: math.Vec3, thf: f32, asp: f32) [4]math.Vec3 {
                const height = dist * thf * 2.0;
                const width = height * asp;
                
                const center_slice = cPos.add(cFwd.mul(dist));
                const up_vec = cUp.mul(height * 0.5);
                const right_vec = cRight.mul(width * 0.5);
                
                return [4]math.Vec3{
                    center_slice.sub(right_vec).add(up_vec),    // TL
                    center_slice.add(right_vec).add(up_vec),    // TR
                    center_slice.sub(right_vec).sub(up_vec),    // BL
                    center_slice.add(right_vec).sub(up_vec),    // BR
                };
            }
        }.call;
        
        const cornersNear = getCornersAtDist(lastSplitDist, camPos, camForward, camRight, camUp, tanHalfFov, aspect);
        const cornersFar = getCornersAtDist(d, camPos, camForward, camRight, camUp, tanHalfFov, aspect);
        
        const worldCorners = [8]math.Vec3{
            cornersNear[0], cornersNear[1], cornersNear[2], cornersNear[3],
            cornersFar[0], cornersFar[1], cornersFar[2], cornersFar[3]
        };

        // Calculate Centroid and Radius
        var center = math.Vec3.zero();
        for (worldCorners) |wc| {
            center = center.add(wc);
        }
        center = center.mul(1.0 / 8.0);
        
        var radius: f32 = 0.0;
        for (worldCorners) |wc| {
            const d2 = wc.sub(center).lengthSq();
            radius = @max(radius, d2);
        }
        radius = std.math.sqrt(radius);
        
        // Apply a padding factor to the radius to include shadow casters that are outside the frustum slice
        // but casting shadows into it. This reduces resolution but prevents shadow clipping artifacts.
        // A factor of 1.4 adds 40% padding which is usually sufficient for typical scenes.
        radius *= 1.4;

        // Enforce minimum radius to prevent clipping of nearby large objects (like walls) when looking close up
        // The first cascade can be very small (e.g. 1m), missing objects just outside the view.
        const min_radius: f32 = 25.0;
        radius = @max(radius, min_radius);
        
        // Round radius to stabilize scale (optional, but good for consistency)
        radius = std.math.ceil(radius * 16.0) / 16.0;
        
        // Construct Light View Matrix (Rotation Only + Center Offset)
        // We want to stabilize the shadow map by snapping to texels.
        // 1. Create a base LightView looking at Origin from LightDir.
        // 2. Project 'center' into this space.
        // 3. Snap the projected center to texel grid.
        // 4. Build Ortho projection around snapped center.
        
        var up = math.Vec3{ .x = 0, .y = 1, .z = 0 };
        if (std.math.approxEqAbs(f32, @abs(lightDir.dot(up)), 1.0, 0.001)) {
            up = math.Vec3{ .x = 0, .y = 0, .z = 1 };
        }
        
        // LightView looking at Origin (0,0,0) from Direction
        // eye = -lightDir (normalized direction vector as position? No, just direction matters for rotation)
        // Actually mat4_lookAt(eye, center, up)
        // We want a view matrix that aligns world with light.
        // Center = (0,0,0), Eye = -lightDir (so it looks towards 0 along lightDir).
        // This creates a view matrix with no large translation offset (except related to 0).
        const baseLightView = mat4_lookAt(lightDir.mul(-1.0), math.Vec3.zero(), up);
        
        // Helper to multiply Mat4 * Vec3 (assuming Col-Major matrix)
        const mulMat4Vec3 = struct {
            fn call(m: math.Mat4, v: math.Vec3) math.Vec3 {
                const x = m.data[0] * v.x + m.data[4] * v.y + m.data[8] * v.z + m.data[12];
                const y = m.data[1] * v.x + m.data[5] * v.y + m.data[9] * v.z + m.data[13];
                const z = m.data[2] * v.x + m.data[6] * v.y + m.data[10] * v.z + m.data[14];
                return math.Vec3{ .x = x, .y = y, .z = z };
            }
        }.call;
        
        // Project center to Light Space
        var centerLS = mulMat4Vec3(baseLightView, center);
        
        // Calculate Shadow Map Resolution
        const shadowMapWidth = @as(f32, @floatFromInt(SHADOW_MAP_SIZE));
        
        // World units per texel
        // The projection width is 2 * radius
        const worldUnitsPerTexel = (2.0 * radius) / shadowMapWidth;
        
        // Snap centerLS to texel grid
        centerLS.x = @floor(centerLS.x / worldUnitsPerTexel) * worldUnitsPerTexel;
        centerLS.y = @floor(centerLS.y / worldUnitsPerTexel) * worldUnitsPerTexel;
        
        const lightView = baseLightView;
        
        const minX = centerLS.x - radius;
        const maxX = centerLS.x + radius;
        const minY = centerLS.y - radius;
        const maxY = centerLS.y + radius;
        
        // Z-Bounds: Need to cover all potential blockers.
        const zRange = 4000.0; // Large enough margin
        const minZ_ortho = centerLS.z - zRange;
        const maxZ_ortho = centerLS.z + zRange;
        
        const lightProjFinal = mat4_ortho(minX, maxX, minY, maxY, maxZ_ortho, minZ_ortho);
        
        lightSpaceMatrices[j] = lightView.mul(lightProjFinal);
                
        lastSplitDist = d;
    }
    
    // Upload matrices
    if (pipe.shadowUBOMapped) |ptr| {
        const matricesPtr = @as([*]math.Mat4, @ptrCast(@alignCast(ptr)));
        @memcpy(matricesPtr[0..4], lightSpaceMatrices[0..4]);
        
        const splitsPtr = @as([*]f32, @ptrCast(@alignCast(@as([*]u8, @ptrCast(ptr)) + 256)));
        @memcpy(splitsPtr[0..4], cascadeSplits[0..4]);
    }
    
    // Render
    const scn = s.current_scene orelse return;
    
    // Image Barrier for Shadow Map (Undefined -> Depth Attachment)
    // We assume it starts Undefined or Shader Read Only from previous frame
    {
        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier2);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
        barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
        barrier.srcAccessMask = c.VK_ACCESS_2_SHADER_READ_BIT;
        barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED; // Discard contents
        barrier.newLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        barrier.image = pipe.shadowMapImage;
        barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = SHADOW_CASCADE_COUNT;
        
        var dep = std.mem.zeroes(c.VkDependencyInfo);
        dep.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
        dep.imageMemoryBarrierCount = 1;
        dep.pImageMemoryBarriers = &barrier;
        
        if (s.context.vkCmdPipelineBarrier2) |func| {
            func(cmd, &dep);
        } else {
            var barrier_v1 = std.mem.zeroes(c.VkImageMemoryBarrier);
            barrier_v1.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barrier_v1.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            barrier_v1.dstAccessMask = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
            barrier_v1.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            barrier_v1.newLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
            barrier_v1.image = pipe.shadowMapImage;
            barrier_v1.subresourceRange = barrier.subresourceRange;
            barrier_v1.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier_v1.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;

            c.vkCmdPipelineBarrier(
                cmd,
                c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
                0,
                0, null,
                0, null,
                1, &barrier_v1
            );
        }
    }
    
    // Check descriptors upfront
    if (pipe.shadowDescriptorSet == null and pipe.shadowDescriptorManager == null) {
        log.cardinal_log_error("Shadow: Shadow descriptor set is null (and no manager)", .{});
        return;
    }

    var j_layer: u32 = 0;
    while (j_layer < SHADOW_CASCADE_COUNT) : (j_layer += 1) {
        // Begin Rendering
        var renderingInfo = std.mem.zeroes(c.VkRenderingInfo);
        renderingInfo.sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO;
        renderingInfo.renderArea.extent.width = SHADOW_MAP_SIZE;
        renderingInfo.renderArea.extent.height = SHADOW_MAP_SIZE;
        renderingInfo.layerCount = 1;
        
        var depthAttachment = std.mem.zeroes(c.VkRenderingAttachmentInfo);
        depthAttachment.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        depthAttachment.imageView = pipe.shadowCascadeViews[j_layer];
        
        // Transition to attachment optimal BEFORE rendering
        {
            var barrier = std.mem.zeroes(c.VkImageMemoryBarrier2);
            barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
            barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT;
            barrier.srcAccessMask = c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
            barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
            barrier.oldLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
            barrier.newLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        }

        depthAttachment.imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        depthAttachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        depthAttachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        depthAttachment.clearValue.depthStencil = .{ .depth = 1.0, .stencil = 0 }; // Clear to 1.0 (Far)
        
        renderingInfo.pDepthAttachment = &depthAttachment;
        
        if (s.context.vkCmdBeginRendering) |func| {
            func(cmd, &renderingInfo);
        }
        
        // Set Viewport/Scissor
        var vp = std.mem.zeroes(c.VkViewport);
        vp.width = @floatFromInt(SHADOW_MAP_SIZE);
        vp.height = @floatFromInt(SHADOW_MAP_SIZE);
        vp.maxDepth = 1.0;
        c.vkCmdSetViewport(cmd, 0, 1, &vp);
        
        var sc = std.mem.zeroes(c.VkRect2D);
        sc.extent.width = SHADOW_MAP_SIZE;
        sc.extent.height = SHADOW_MAP_SIZE;
        c.vkCmdSetScissor(cmd, 0, 1, &sc);

        // Reduce bias to avoid pushing shadows out of depth range
        // c.vkCmdSetDepthBias(cmd, 1.25, 0.0, 1.75);
        c.vkCmdSetDepthBias(cmd, 0.0, 0.0, 0.0);
        
        // Bind Pipeline
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.shadowPipeline);
        
        // Bind Descriptor Set
        if (pipe.shadowDescriptorManager) |mgr| {
            var sets: ?[*]const c.VkDescriptorSet = null;
            var descriptorSets = [_]c.VkDescriptorSet{pipe.shadowDescriptorSet};
            
            const use_buffers = mgr.useDescriptorBuffers;
            if (use_buffers or (pipe.shadowDescriptorSet != null and @intFromPtr(pipe.shadowDescriptorSet) != 0)) {
                sets = &descriptorSets;
            }
            descriptor_mgr.vk_descriptor_manager_bind_sets(mgr, cmd, pipe.shadowPipelineLayout, 0, 1, sets, 0, null);
        } else {
            if (pipe.shadowDescriptorSet != null and @intFromPtr(pipe.shadowDescriptorSet) != 0) {
                const descriptorSets = [_]c.VkDescriptorSet{pipe.shadowDescriptorSet};
                c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.shadowPipelineLayout, 0, 1, &descriptorSets, 0, null);
            }
        }
        
        // Bind Vertex/Index Buffers
        const vertexBuffers = [_]c.VkBuffer{pipe.vertexBuffer};
        const offsets = [_]c.VkDeviceSize{0};
        c.vkCmdBindVertexBuffers(cmd, 0, 1, &vertexBuffers, &offsets);
        c.vkCmdBindIndexBuffer(cmd, pipe.indexBuffer, 0, c.VK_INDEX_TYPE_UINT32);
        
        // Loop Meshes
        var indexOffset: u32 = 0;
        var m_i: u32 = 0;
        var drawn_count: u32 = 0;
        while (m_i < scn.mesh_count) : (m_i += 1) {
            const mesh = &scn.meshes.?[m_i];
            
            // Verify mesh has valid indices in the buffer
            if (mesh.index_count == 0 or mesh.indices == null) {
                continue;
            }
            
            // Skip transparent objects for shadow map?
            // For now, render everything to ensure we see shadows.
            // TODO: Ideally we need a separate shader for alpha-tested shadows.
            
            // var is_opaque = true;
            // if (mesh.material_index < scn.material_count) {
            //     const mat = &scn.materials.?[mesh.material_index];
            //     if (mat.alpha_mode != scene.CardinalAlphaMode.OPAQUE) {
            //         is_opaque = false;
            //     }
            // }
            
            // if (!is_opaque) {
            //     indexOffset += mesh.index_count;
            //     continue;
            // }
            
            
            if (mesh.vertex_count == 0 or !mesh.visible) {
                indexOffset += mesh.index_count;
                continue;
            }

            drawn_count += 1;
            
            // Push Constants
            var pushData = std.mem.zeroes([156]u8);
            
            // Copy Model Matrix (first 64 bytes)
            const modelPtr = @as([*]const u8, @ptrCast(&mesh.transform));
            @memcpy(pushData[0..64], modelPtr[0..64]);
            
            // Has Skeleton
            var hasSkeleton: u32 = 0;
            if (scn.animation_system != null and scn.skin_count > 0) {
                 const skins = @as([*]animation.CardinalSkin, @ptrCast(@alignCast(scn.skins.?)));
                 var skin_idx: u32 = 0;
                 while (skin_idx < scn.skin_count) : (skin_idx += 1) {
                     const skin = &skins[skin_idx];
                     var mesh_idx: u32 = 0;
                     while (mesh_idx < skin.mesh_count) : (mesh_idx += 1) {
                         if (skin.mesh_indices.?[mesh_idx] == m_i) {
                             hasSkeleton = 1;
                             break;
                         }
                     }
                     if (hasSkeleton == 1) break;
                 }
            }
            
            const skelPtr = @as([*]const u8, @ptrCast(&hasSkeleton));
            @memcpy(pushData[148..152], skelPtr[0..4]);
            
            // Cascade Index
            const cascadeIdx = @as(u32, @intCast(j_layer));
            const casPtr = @as([*]const u8, @ptrCast(&cascadeIdx));
            @memcpy(pushData[152..156], casPtr[0..4]);
            
            c.vkCmdPushConstants(cmd, pipe.shadowPipelineLayout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, 156, &pushData);
            
            // Validate index buffer bounds
            if (indexOffset + mesh.index_count > pipe.totalIndexCount) {
                break;
            }

            c.vkCmdDrawIndexed(cmd, mesh.index_count, 1, indexOffset, 0, 0);
            
            indexOffset += mesh.index_count;
        }
        
        if (scn.mesh_count > 0 and j_layer == 0 and drawn_count == 0) {
            log.cardinal_log_warn("Shadow: No meshes drawn for cascade 0! Total meshes: {d}", .{scn.mesh_count});
        }
        
        // End Rendering
        if (s.context.vkCmdEndRendering) |func| {
            func(cmd);
        }
    }
    
    // Transition Shadow Map to Shader Read (All layers)
    {
        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier2);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2;
        barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT;
        barrier.srcAccessMask = c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_2_SHADER_READ_BIT;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
        barrier.image = pipe.shadowMapImage;
        barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = SHADOW_CASCADE_COUNT;
        
        var dep = std.mem.zeroes(c.VkDependencyInfo);
        dep.sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO;
        dep.imageMemoryBarrierCount = 1;
        dep.pImageMemoryBarriers = &barrier;
        
        if (s.context.vkCmdPipelineBarrier2) |func| {
            func(cmd, &dep);
        } else {
            var barrier_v1 = std.mem.zeroes(c.VkImageMemoryBarrier);
            barrier_v1.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barrier_v1.srcAccessMask = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
            barrier_v1.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            barrier_v1.oldLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
            barrier_v1.newLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
            barrier_v1.image = pipe.shadowMapImage;
            barrier_v1.subresourceRange = barrier.subresourceRange;
            barrier_v1.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier_v1.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;

            c.vkCmdPipelineBarrier(
                cmd,
                c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
                c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                0,
                0, null,
                0, null,
                1, &barrier_v1
            );
        }
    }
}
