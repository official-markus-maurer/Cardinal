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

    const frame_check = if (s.sync.current_frame >= types.MAX_FRAMES_IN_FLIGHT) 0 else s.sync.current_frame;
    if (pipe.lightingBuffersMapped[frame_check] == null or pipe.uniformBuffersMapped[frame_check] == null) {
        log.cardinal_log_warn("Shadow: Buffers not mapped", .{});
        return;
    }

    const ubo = @as(*types.PBRUniformBufferObject, @ptrCast(@alignCast(pipe.uniformBuffersMapped[frame_check])));
    const lighting = @as(*types.PBRLightingBuffer, @ptrCast(@alignCast(pipe.lightingBuffersMapped[frame_check])));

    if (lighting.count == 0) {
        log.cardinal_log_warn("Shadow: No lights in lighting buffer", .{});
        return;
    }

    // Find best directional light (highest intensity)
    var lightDir: math.Vec3 = math.Vec3.zero();
    var bestIntensity: f32 = -1.0;
    var found = false;
    var i: u32 = 0;
    while (i < lighting.count) : (i += 1) {
        const l_type = lighting.lights[i].lightDirection[3];
        // Tolerance check for float equality
        if (l_type > -0.1 and l_type < 0.1) { // Directional (approx 0.0)
            const intensity = lighting.lights[i].lightColor[3];
            if (intensity > bestIntensity) {
                bestIntensity = intensity;
                lightDir = math.Vec3{ .x = lighting.lights[i].lightDirection[0], .y = lighting.lights[i].lightDirection[1], .z = lighting.lights[i].lightDirection[2] };
                found = true;
            }
        }
    }

    if (found) {
        log.cardinal_log_info("Shadow: Using directional light with intensity {d:.2}: ({d:.2}, {d:.2}, {d:.2})", .{ bestIntensity, lightDir.x, lightDir.y, lightDir.z });
    }

    if (!found) {
        log.cardinal_log_warn("Shadow: No directional light found", .{});
        return;
    }

    lightDir = lightDir.normalize();

    // Extract camera properties from UBO
    // We need camera position and orientation (View Matrix) to calculate frustum splits
    const view = math.Mat4.fromArray(ubo.view);
    const proj = math.Mat4.fromArray(ubo.proj);

    var cascadeSplits = [_]f32{0} ** types.MAX_SHADOW_CASCADES;
    var lightSpaceMatrices = [_]math.Mat4{mat4_identity()} ** types.MAX_SHADOW_CASCADES;

    const nearClip: f32 = s.config.shadow_near_clip;

    // Extract far plane from projection matrix: far = proj[14] / (1.0 + proj[10])
    var farClip: f32 = s.config.shadow_far_clip;
    const p10 = proj.data[10];
    const p14 = proj.data[14];
    if (@abs(1.0 + p10) > 0.001) {
        farClip = p14 / (1.0 + p10);
    }

    const minZ = nearClip;
    const maxZ = farClip;
    const ratio = maxZ / minZ;
    const range = maxZ - minZ;

    const lambda: f32 = s.config.shadow_split_lambda;
    const cascade_count = @min(s.config.shadow_cascade_count, types.MAX_SHADOW_CASCADES);

    var lastSplitDist: f32 = 0.0;

    var j: usize = 0;
    while (j < cascade_count) : (j += 1) {
        const p = @as(f32, @floatFromInt(j + 1)) / @as(f32, @floatFromInt(cascade_count));
        const logC = minZ * std.math.pow(f32, ratio, p);
        const uniC = minZ + range * p;
        const d = lambda * logC + (1.0 - lambda) * uniC;
        cascadeSplits[j] = d; // Store actual depth for comparison

        // Calculate frustum slice corners in World Space directly

        const camPos = math.Vec3.fromArray(ubo.viewPos);
        // Extract Camera Basis from View Matrix (Column-Major)
        const camRight = math.Vec3{ .x = view.data[0], .y = view.data[4], .z = view.data[8] };
        const camUp = math.Vec3{ .x = view.data[1], .y = view.data[5], .z = view.data[9] };
        const camForward = math.Vec3{ .x = -view.data[2], .y = -view.data[6], .z = -view.data[10] };

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
                    center_slice.sub(right_vec).add(up_vec), // TL
                    center_slice.add(right_vec).add(up_vec), // TR
                    center_slice.sub(right_vec).sub(up_vec), // BL
                    center_slice.add(right_vec).sub(up_vec), // BR
                };
            }
        }.call;

        const cornersNear = getCornersAtDist(lastSplitDist, camPos, camForward, camRight, camUp, tanHalfFov, aspect);
        const cornersFar = getCornersAtDist(d, camPos, camForward, camRight, camUp, tanHalfFov, aspect);

        const worldCorners = [8]math.Vec3{ cornersNear[0], cornersNear[1], cornersNear[2], cornersNear[3], cornersFar[0], cornersFar[1], cornersFar[2], cornersFar[3] };

        // Calculate Centroid (in World Space) for positioning
        var center = math.Vec3.zero();
        for (worldCorners) |wc| {
            center = center.add(wc);
        }
        center = center.mul(1.0 / 8.0);

        // Calculate Radius in View Space (Stable)
        // We use identity camera frame to calculate the frustum slice in View Space
        const zeroPos = math.Vec3.zero();
        const identFwd = math.Vec3{ .x = 0, .y = 0, .z = -1 };
        const identRight = math.Vec3{ .x = 1, .y = 0, .z = 0 };
        const identUp = math.Vec3{ .x = 0, .y = 1, .z = 0 };

        const vsCornersNear = getCornersAtDist(lastSplitDist, zeroPos, identFwd, identRight, identUp, tanHalfFov, aspect);
        const vsCornersFar = getCornersAtDist(d, zeroPos, identFwd, identRight, identUp, tanHalfFov, aspect);

        const vsCorners = [8]math.Vec3{ vsCornersNear[0], vsCornersNear[1], vsCornersNear[2], vsCornersNear[3], vsCornersFar[0], vsCornersFar[1], vsCornersFar[2], vsCornersFar[3] };

        var vsCenter = math.Vec3.zero();
        for (vsCorners) |vc| {
            vsCenter = vsCenter.add(vc);
        }
        vsCenter = vsCenter.mul(1.0 / 8.0);

        var radius: f32 = 0.0;
        for (vsCorners) |vc| {
            const d2 = vc.sub(vsCenter).lengthSq();
            radius = @max(radius, d2);
        }
        radius = std.math.sqrt(radius);

        // Apply padding (1.4x) to radius to include shadow casters outside the frustum slice
        radius *= 1.4;

        // Enforce minimum radius to prevent clipping of nearby large objects
        const min_radius: f32 = 25.0;
        radius = @max(radius, min_radius);

        // Round radius to stabilize scale
        radius = std.math.ceil(radius * 16.0) / 16.0;

        // Construct Light View Matrix and stabilize by snapping to texels

        var up = math.Vec3{ .x = 0, .y = 1, .z = 0 };
        if (std.math.approxEqAbs(f32, @abs(lightDir.dot(up)), 1.0, 0.001)) {
            up = math.Vec3{ .x = 0, .y = 0, .z = 1 };
        }

        // Create base LightView looking at origin from light direction
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
        const shadowMapWidth = @as(f32, @floatFromInt(s.config.shadow_map_size));

        // World units per texel
        // The projection width is 2 * radius
        const worldUnitsPerTexel = (2.0 * radius) / shadowMapWidth;

        // Snap centerLS to texel grid
        // To stabilize, we must ensure that the 'minX' and 'minY' of the projection align with the texel grid.
        // lightProjFinal = ortho(minX, maxX, ...)
        // minX = centerLS.x - radius
        // We want (centerLS.x - radius) to be a multiple of worldUnitsPerTexel.
        // centerLS.x = floor( (centerLS.x - radius) / worldUnitsPerTexel ) * worldUnitsPerTexel + radius;
        // This ensures the left edge of the box is snapped.

        const snappedX = @floor((centerLS.x - radius) / worldUnitsPerTexel) * worldUnitsPerTexel + radius;
        const snappedY = @floor((centerLS.y - radius) / worldUnitsPerTexel) * worldUnitsPerTexel + radius;

        centerLS.x = snappedX;
        centerLS.y = snappedY;

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

        // Standard Column-Major: P * V (Apply View then Proj)
        lightSpaceMatrices[j] = lightProjFinal.mul(lightView);

        lastSplitDist = d;
    }

    // Upload matrices
    const frame = if (s.sync.current_frame >= types.MAX_FRAMES_IN_FLIGHT) 0 else s.sync.current_frame;
    if (pipe.shadowUBOsMapped[frame]) |ptr| {
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
        barrier.subresourceRange.layerCount = cascade_count;

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

            c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT, 0, 0, null, 0, null, 1, &barrier_v1);
        }
    }

    // Check descriptors upfront
    if (pipe.shadowDescriptorSets[frame_check] == null and pipe.shadowDescriptorManager == null) {
        log.cardinal_log_error("Shadow: Shadow descriptor set is null (and no manager)", .{});
        return;
    }

    var j_layer: u32 = 0;
    while (j_layer < s.config.shadow_cascade_count) : (j_layer += 1) {
        // Begin Rendering
        var renderingInfo = std.mem.zeroes(c.VkRenderingInfo);
        renderingInfo.sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO;
        renderingInfo.renderArea.extent.width = s.config.shadow_map_size;
        renderingInfo.renderArea.extent.height = s.config.shadow_map_size;
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
        vp.width = @floatFromInt(s.config.shadow_map_size);
        vp.height = @floatFromInt(s.config.shadow_map_size);
        vp.maxDepth = 1.0;
        c.vkCmdSetViewport(cmd, 0, 1, &vp);

        var sc = std.mem.zeroes(c.VkRect2D);
        sc.extent.width = s.config.shadow_map_size;
        sc.extent.height = s.config.shadow_map_size;
        c.vkCmdSetScissor(cmd, 0, 1, &sc);

        // Reduce bias to avoid pushing shadows out of depth range
        // c.vkCmdSetDepthBias(cmd, 1.25, 0.0, 1.75);
        c.vkCmdSetDepthBias(cmd, 0.0, 0.0, 0.0);

        // Bind Pipeline (Opaque)
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.shadowPipeline);

        // Bind Descriptor Set
        if (pipe.shadowDescriptorManager) |mgr| {
            var sets: ?[*]const c.VkDescriptorSet = null;
            var descriptorSets = [_]c.VkDescriptorSet{pipe.shadowDescriptorSets[frame_check]};

            const use_buffers = mgr.useDescriptorBuffers;
            if (use_buffers or (pipe.shadowDescriptorSets[frame_check] != null and @intFromPtr(pipe.shadowDescriptorSets[frame_check]) != 0)) {
                sets = &descriptorSets;
            }
            descriptor_mgr.vk_descriptor_manager_bind_sets(mgr, cmd, pipe.shadowPipelineLayout, 0, 1, sets, 0, null);
        } else {
            if (pipe.shadowDescriptorSets[frame_check] != null and @intFromPtr(pipe.shadowDescriptorSets[frame_check]) != 0) {
                const descriptorSets = [_]c.VkDescriptorSet{pipe.shadowDescriptorSets[frame_check]};
                c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.shadowPipelineLayout, 0, 1, &descriptorSets, 0, null);
            }
        }

        // Bind Vertex/Index Buffers
        const vertexBuffers = [_]c.VkBuffer{pipe.vertexBuffer};
        const offsets = [_]c.VkDeviceSize{0};
        c.vkCmdBindVertexBuffers(cmd, 0, 1, &vertexBuffers, &offsets);
        c.vkCmdBindIndexBuffer(cmd, pipe.indexBuffer, 0, c.VK_INDEX_TYPE_UINT32);

        // --- Pass 1: Opaque Meshes ---
        var indexOffset: u32 = 0;
        var m_i: u32 = 0;
        var drawn_count: u32 = 0;
        while (m_i < scn.mesh_count) : (m_i += 1) {
            const mesh = &scn.meshes.?[m_i];

            // Verify mesh has valid indices in the buffer
            if (mesh.index_count == 0 or mesh.indices == null) {
                continue;
            }

            var is_alpha_tested = false;
            if (mesh.material_index < scn.material_count) {
                const mat = &scn.materials.?[mesh.material_index];
                if (mat.alpha_mode == scene.CardinalAlphaMode.MASK) {
                    is_alpha_tested = true;
                }
            }

            if (is_alpha_tested) {
                // Skip alpha tested meshes in this pass
                indexOffset += mesh.index_count;
                continue;
            }

            if (mesh.vertex_count == 0 or !mesh.visible) {
                indexOffset += mesh.index_count;
                continue;
            }

            drawn_count += 1;

            // Push Constants
            // Layout (total 236 bytes aligned to maxPushConstantSize):
            // 0..64: Model Matrix (mat4)
            // 64..132: Material Data (PBR material data - not fully used here but space reserved)
            // 132..136: packedInfo (flags including hasSkeleton)
            // 136..152: Padding/Reserved
            // 152..156: Cascade Index

            // We need to construct this carefully to match PBR pipeline layout
            // Shadow push constant range in shader: 0..156 (covering model, flags, cascade)
            // But pipeline layout might be bigger (236)

            var pushData = std.mem.zeroes([156]u8);

            // Copy Model Matrix (first 64 bytes)
            const modelPtr = @as([*]const u8, @ptrCast(&mesh.transform));
            @memcpy(pushData[0..64], modelPtr[0..64]);

            // Has Skeleton
            var packedInfo: u32 = 0;
            if (scn.animation_system != null and scn.skin_count > 0) {
                const skins = @as([*]animation.CardinalSkin, @ptrCast(@alignCast(scn.skins.?)));
                var skin_idx: u32 = 0;
                while (skin_idx < scn.skin_count) : (skin_idx += 1) {
                    const skin = &skins[skin_idx];
                    var mesh_idx: u32 = 0;
                    while (mesh_idx < skin.mesh_count) : (mesh_idx += 1) {
                        if (skin.mesh_indices.?[mesh_idx] == m_i) {
                            // Set bit 2 (value 4) in upper 16 bits
                            packedInfo |= (4 << 16);
                            break;
                        }
                    }
                    if ((packedInfo & (4 << 16)) != 0) break;
                }
            }

            const infoPtr = @as([*]const u8, @ptrCast(&packedInfo));
            @memcpy(pushData[132..136], infoPtr[0..4]);

            // Cascade Index
            const cascadeIdx = @as(u32, @intCast(j_layer));
            const casPtr = @as([*]const u8, @ptrCast(&cascadeIdx));
            @memcpy(pushData[152..156], casPtr[0..4]);

            c.vkCmdPushConstants(cmd, pipe.shadowPipelineLayout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, 156, &pushData);

            // Validate index buffer bounds
            if (indexOffset + mesh.index_count > pipe.totalIndexCount) {
                break;
            }

            c.vkCmdDrawIndexed(cmd, mesh.index_count, 1, indexOffset, 0, 0);

            indexOffset += mesh.index_count;
        }

        // --- Pass 2: Alpha Tested Meshes ---
        if (pipe.shadowAlphaPipeline != null) {
            c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.shadowAlphaPipeline);

            // Re-bind descriptors (just in case pipeline bind disturbed them, though likely they are compatible)
            // But we already bound them to the layout which is shared.

            indexOffset = 0;
            m_i = 0;
            while (m_i < scn.mesh_count) : (m_i += 1) {
                const mesh = &scn.meshes.?[m_i];

                if (mesh.index_count == 0 or mesh.indices == null) {
                    continue;
                }

                var is_alpha_tested = false;
                var texture_idx: u32 = 0;
                var alpha_cutoff: f32 = 0.5;

                if (mesh.material_index < scn.material_count) {
                    const mat = &scn.materials.?[mesh.material_index];
                    if (mat.alpha_mode == scene.CardinalAlphaMode.MASK) {
                        is_alpha_tested = true;
                        texture_idx = mat.albedo_texture.index;
                        alpha_cutoff = mat.alpha_cutoff;
                    }
                }

                if (!is_alpha_tested) {
                    indexOffset += mesh.index_count;
                    continue;
                }

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

                // Material Data (Offset 64)
                // Texture Index (u32) at 64
                const texPtr = @as([*]const u8, @ptrCast(&texture_idx));
                @memcpy(pushData[64..68], texPtr[0..4]);

                // Alpha Cutoff (f32) at 68
                const cutPtr = @as([*]const u8, @ptrCast(&alpha_cutoff));
                @memcpy(pushData[68..72], cutPtr[0..4]);

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

                c.vkCmdPushConstants(cmd, pipe.shadowPipelineLayout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, 156, &pushData);

                // Validate index buffer bounds
                if (indexOffset + mesh.index_count > pipe.totalIndexCount) {
                    break;
                }

                c.vkCmdDrawIndexed(cmd, mesh.index_count, 1, indexOffset, 0, 0);

                indexOffset += mesh.index_count;
            }
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
        barrier.subresourceRange.layerCount = cascade_count;

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

            c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier_v1);
        }
    }
}
