const std = @import("std");
const c = @import("vulkan_c.zig").c;
const types = @import("vulkan_types.zig");
const math = @import("../core/math.zig");
const log = @import("../core/log.zig");
const vk_pbr = @import("vulkan_pbr.zig");
const scene = @import("../assets/scene.zig");
const animation = @import("../core/animation.zig");
const wrappers = @import("vulkan_wrappers.zig");
const vk_renderer_frame = @import("vulkan_renderer_frame.zig");
const material_utils = @import("util/vulkan_material_utils.zig");

const SHADOW_MAP_SIZE = 2048;
const SHADOW_CASCADE_COUNT = 4;

fn mat4_identity() math.Mat4 {
    return math.Mat4.identity();
}

fn mat4_ortho(left: f32, right: f32, bottom: f32, top: f32, zNear: f32, zFar: f32) math.Mat4 {
    var m = math.Mat4.identity();
    m.data[0] = 2.0 / (right - left);
    m.data[5] = 2.0 / (top - bottom);
    m.data[10] = 1.0 / (zFar - zNear);
    m.data[12] = -(right + left) / (right - left);
    m.data[13] = -(top + bottom) / (top - bottom);
    m.data[14] = -zNear / (zFar - zNear);
    
    // m.data[5] *= -1.0; // Standard OpenGL Y-up
    
    return m;
}

fn mat4_lookAt(eye: math.Vec3, center: math.Vec3, up: math.Vec3) math.Mat4 {
    const f = center.sub(eye).normalize();
    const s = f.cross(up).normalize();
    const u = s.cross(f);
    
    var m = math.Mat4.identity();
    m.data[0] = s.x;
    m.data[4] = s.y;
    m.data[8] = s.z;
    
    m.data[1] = u.x;
    m.data[5] = u.y;
    m.data[9] = u.z;
    
    m.data[2] = -f.x;
    m.data[6] = -f.y;
    m.data[10] = -f.z;
    
    m.data[12] = -s.dot(eye);
    m.data[13] = -u.dot(eye);
    m.data[14] = f.dot(eye);
    
    return m;
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
        
        // 1. Calculate corners of sub-frustum in World Space
        //    NDC Z range: 0..1 (Vulkan)
        //    Split distances are linear 0..1? No, d is linear depth.
        //    Need to map d to NDC Z.
        //    Or just compute corners using trigonometry if we knew FOV/Aspect.
        //    Since we only have ViewProj, we can use Inverse ViewProj.
        //    NDC Z for a given linear depth z:
        //    z_ndc = P[2][2] + P[3][2]/z_view ? (Depends on projection matrix construction)
        
        //    Let's use the camera view frustum corners approach.
        //    (Assuming we can get FOV/Aspect from somewhere or derive from Proj)
        //    proj[1][1] = 1 / tan(fov/2).
        
        //    Alternative: Use computed 'd' (linear depth) to define sub-frustum.
        //    Center of sub-frustum in View Space:
        //    (0, 0, -(lastSplitDist + d)/2)
        
        //    Let's compute center of sub-frustum in World Space.
        //    CamPos + CamForward * ((lastSplitDist + d)/2).
        
        //    Need CamPos and CamForward.
        //    CamPos = ubo.viewPos (Vec3)
        //    CamForward = -View[2][0..2] (Row 2 of View Matrix)
        
        const camPos = math.Vec3.fromArray(ubo.viewPos);
        const camForwardRaw = math.Vec3{ .x = -view.data[2], .y = -view.data[6], .z = -view.data[10] };
        const camForward = camForwardRaw.normalize();
        
        const splitCenterDist = (lastSplitDist + d) * 0.5;
        const center = camPos.add(camForward.mul(splitCenterDist));
        
        // Calculate Light View Matrix
        // Eye = Center - LightDir * distance
        // Distance should be large enough to cover scene
        const lightDist = farClip; // Or computed
        const lightEye = center.sub(lightDir.mul(lightDist));
        
        var up = math.Vec3{ .x = 0, .y = 1, .z = 0 };
        if (std.math.approxEqAbs(f32, @abs(lightDir.dot(up)), 1.0, 0.001)) {
            up = math.Vec3{ .x = 0, .y = 0, .z = 1 };
        }
        const lightView = mat4_lookAt(lightEye, center, up);
        
        // Calculate Ortho Proj
        // Project frustum corners to Light View Space to find min/max
        // We need 8 corners of the sub-frustum in World Space.
        
        // To get corners:
        // H = tan(fov/2) * z
        // W = H * aspect
        // We need tan(fov/2) and aspect.
        // tan(fov/2) = 1.0 / proj[1][1] (data[5])
        // aspect = proj[1][1] / proj[0][0] (data[5] / data[0])
        
        const tanHalfFov = 1.0 / proj.data[5]; // Abs?
        const aspect = proj.data[5] / proj.data[0];
        
        const xn = lastSplitDist * tanHalfFov * aspect;
        const xf = d * tanHalfFov * aspect;
        const yn = lastSplitDist * tanHalfFov;
        const yf = d * tanHalfFov;
        
        // Corners in View Space
        // Near plane (z = -lastSplitDist)
        const v_n_tl = math.Vec3{ .x = -xn, .y = yn, .z = -lastSplitDist };
        const v_n_tr = math.Vec3{ .x = xn, .y = yn, .z = -lastSplitDist };
        const v_n_bl = math.Vec3{ .x = -xn, .y = -yn, .z = -lastSplitDist };
        const v_n_br = math.Vec3{ .x = xn, .y = -yn, .z = -lastSplitDist };
        
        // Far plane (z = -d)
        const v_f_tl = math.Vec3{ .x = -xf, .y = yf, .z = -d };
        const v_f_tr = math.Vec3{ .x = xf, .y = yf, .z = -d };
        const v_f_bl = math.Vec3{ .x = -xf, .y = -yf, .z = -d };
        const v_f_br = math.Vec3{ .x = xf, .y = -yf, .z = -d };
        
        const viewCorners = [8]math.Vec3{ v_n_tl, v_n_tr, v_n_bl, v_n_br, v_f_tl, v_f_tr, v_f_bl, v_f_br };
        
        // Transform to Light Space
        // World = InvView * ViewCorner
        // Light = LightView * World
        // Light = LightView * InvView * ViewCorner
        
        const invView = view.invert() orelse mat4_identity(); // Should not fail
        const toLight = lightView.mul(invView);
        
        var minX: f32 = std.math.floatMax(f32);
        var maxX: f32 = std.math.floatMin(f32);
        var minY: f32 = std.math.floatMax(f32);
        var maxY: f32 = std.math.floatMin(f32);
        var minZ_ls: f32 = std.math.floatMax(f32);
        var maxZ_ls: f32 = std.math.floatMin(f32);
        
        for (viewCorners) |vc| {
            const v4 = math.Vec4.fromVec3(vc, 1.0);
            // Manually multiply vec4
            var lc = math.Vec4.zero();
            var ki: usize = 0;
            while(ki < 4) : (ki += 1) {
                lc.x += toLight.data[0 * 4 + ki] * v4.toArray()[ki];
                lc.y += toLight.data[1 * 4 + ki] * v4.toArray()[ki];
                lc.z += toLight.data[2 * 4 + ki] * v4.toArray()[ki];
                lc.w += toLight.data[3 * 4 + ki] * v4.toArray()[ki];
            }
            
            minX = @min(minX, lc.x);
            maxX = @max(maxX, lc.x);
            minY = @min(minY, lc.y);
            maxY = @max(maxY, lc.y);
            minZ_ls = @min(minZ_ls, lc.z);
            maxZ_ls = @max(maxZ_ls, lc.z);
        }
        
        // Snap to texels to reduce shimmering
        // TODO: ... (skip for brevity, can add later)
        
        // Z margin
        const zMult = 10.0;
        if (minZ_ls < 0) minZ_ls *= zMult else minZ_ls /= zMult;
        if (maxZ_ls < 0) maxZ_ls /= zMult else maxZ_ls *= zMult;
        
        // Note: minZ_ls is more negative (farther), maxZ_ls is less negative (closer)
        // mat4_ortho takes zNear, zFar. 
        // We want closest objects to map to 0, farthest to 1.
        // So zNear should be close to maxZ_ls, zFar close to minZ_ls.
        // However, we need to ensure we capture objects in front of the camera slice (casters).
        // So we extend zNear (positive direction) and zFar (negative direction).
        
        // Since we are in Light View Space (looking down -Z):
        // Objects are at negative Z.
        // maxZ_ls is e.g. -10. minZ_ls is -100.
        // We want -10 to be near (0), -100 to be far (1).
        
        // mat4_ortho implementation maps zNear -> 0, zFar -> 1.
        // m.data[10] = 1.0 / (zFar - zNear);
        // m.data[14] = -zNear / (zFar - zNear);
        // z' = (z - zNear) / (zFar - zNear)
        
        // If zNear = 100 (positive, behind light), zFar = -500.
        // z = -10: (-10 - 100) / (-500 - 100) = -110 / -600 = ~0.18 (Visible)
        
        const lightProj = mat4_ortho(minX, maxX, minY, maxY, maxZ_ls + 200.0, minZ_ls - 200.0);
        
        // DEBUG: Force simple projection for Cascade 0
        // if (j == 0) {
             // ... (Static Debug Logic Removed) ...
        // } else {
             // Swap multiplication order here too
             lightSpaceMatrices[j] = lightView.mul(lightProj);
        // }
        
        log.cardinal_log_info("Shadow Cascade {d}: Split={d:.2}, minZ={d:.2}, maxZ={d:.2}", .{j, d, minZ_ls, maxZ_ls});
        
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
        const descriptorSets = [_]c.VkDescriptorSet{pipe.shadowDescriptorSet};
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.shadowPipelineLayout, 0, 1, &descriptorSets, 0, null);
        
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
            // Ideally we need a separate shader for alpha-tested shadows.
            
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
        }
    }
}
