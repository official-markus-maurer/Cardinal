//! Cascaded shadow mapping for the PBR pipeline.
//!
//! Computes cascade splits from the active camera, builds light-space matrices for a chosen
//! directional light, and records the shadow render pass.
const std = @import("std");
const c = @import("vulkan_c.zig").c;
const types = @import("vulkan_types.zig");
const math = @import("../core/math.zig");
const log = @import("../core/log.zig");
const vk_pbr = @import("vulkan_pbr.zig");
const scene = @import("../assets/scene.zig");
const animation = @import("../assets/animation.zig");
const wrappers = @import("vulkan_wrappers.zig");
const vk_pso = @import("vulkan_pso.zig");
const material_utils = @import("util/vulkan_material_utils.zig");
const descriptor_mgr = @import("vulkan_descriptor_manager.zig");
const cascade_math = @import("util/vulkan_shadow_cascades.zig");

const shadows_log = log.ScopedLogger("SHADOWS");

/// Records the shadow pass for the current frame when the PBR pipeline is active.
///
/// TODO: Tune depth bias per scene to reduce acne/peter-panning.
pub fn vk_shadow_render(s: *types.VulkanState, cmd: c.VkCommandBuffer) void {
    if (!s.pipelines.use_pbr_pipeline or !s.pipelines.pbr_pipeline.initialized) {
        return;
    }
    const pipe = &s.pipelines.pbr_pipeline;
    if (pipe.shadowPipeline == null) {
        shadows_log.warn("Shadow pipeline is null", .{});
        return;
    }

    const frame_check = if (s.sync.current_frame >= types.MAX_FRAMES_IN_FLIGHT) 0 else s.sync.current_frame;
    if (pipe.lightingBuffersMapped[frame_check] == null or pipe.uniformBuffersMapped[frame_check] == null) {
        shadows_log.warn("Buffers not mapped", .{});
        return;
    }

    const ubo = @as(*types.PBRUniformBufferObject, @ptrCast(@alignCast(pipe.uniformBuffersMapped[frame_check])));
    const lighting = @as(*types.PBRLightingBuffer, @ptrCast(@alignCast(pipe.lightingBuffersMapped[frame_check])));

    if (lighting.count == 0) {
        shadows_log.warn("No lights in lighting buffer", .{});
        return;
    }

    const decode_light_type = struct {
        fn call(raw: f32) types.PBRLightType {
            if (!std.math.isFinite(raw)) return .POINT;
            const v: i32 = @intFromFloat(@round(raw));
            return switch (v) {
                0 => .DIRECTIONAL,
                1 => .POINT,
                2 => .SPOT,
                else => .POINT,
            };
        }
    }.call;

    var lightDir: math.Vec3 = math.Vec3.zero();
    var bestIntensity: f32 = -1.0;
    var found = false;
    var i: u32 = 0;
    while (i < lighting.count) : (i += 1) {
        const l_type = decode_light_type(lighting.lights[i].lightDirection[3]);
        if (l_type == .DIRECTIONAL) {
            const intensity = lighting.lights[i].lightColor[3];
            if (intensity > bestIntensity) {
                bestIntensity = intensity;
                lightDir = math.Vec3{ .x = lighting.lights[i].lightDirection[0], .y = lighting.lights[i].lightDirection[1], .z = lighting.lights[i].lightDirection[2] };
                found = true;
            }
        }
    }

    if (found) {
        shadows_log.info("Using directional light with intensity {d:.2}: ({d:.2}, {d:.2}, {d:.2})", .{ bestIntensity, lightDir.x, lightDir.y, lightDir.z });
    }

    if (!found) {
        shadows_log.warn("No directional light found", .{});
        return;
    }

    lightDir = lightDir.normalize();

    var cascadeSplits = [_]f32{0} ** types.MAX_SHADOW_CASCADES;
    var lightSpaceMatrices = [_]math.Mat4{math.Mat4.identity()} ** types.MAX_SHADOW_CASCADES;
    const cascade_count_u32: u32 = @min(s.config.shadow_cascade_count, @as(u32, pipe.shadowCascadeViews.len));
    const cascade_count: usize = @intCast(cascade_count_u32);
    cascade_math.build_shadow_cascades(&s.config, ubo, lightDir, cascade_count, cascadeSplits[0..cascade_count], lightSpaceMatrices[0..cascade_count]);

    const frame = if (s.sync.current_frame >= types.MAX_FRAMES_IN_FLIGHT) 0 else s.sync.current_frame;
    if (pipe.shadowUBOsMapped[frame]) |ptr| {
        const matricesPtr = @as([*]math.Mat4, @ptrCast(@alignCast(ptr)));
        const fixed_count = pipe.shadowCascadeViews.len;
        var mi: usize = 0;
        while (mi < fixed_count) : (mi += 1) {
            matricesPtr[mi] = if (mi < cascade_count) lightSpaceMatrices[mi] else math.Mat4.identity();
        }
        const splitsPtr = @as([*]f32, @ptrCast(@alignCast(@as([*]u8, @ptrCast(ptr)) + 256)));
        var si: usize = 0;
        while (si < fixed_count) : (si += 1) {
            splitsPtr[si] = if (si < cascade_count) cascadeSplits[si] else 0;
        }
    }

    const scn = s.current_scene orelse return;

    if (pipe.shadowDescriptorSets[frame_check] == null and pipe.shadowDescriptorManager == null) {
        shadows_log.err("Shadow descriptor set is null (and no manager)", .{});
        return;
    }

    if (pipe.vertexBuffer == null) {
        return;
    }

    var j_layer: u32 = 0;
    while (j_layer < cascade_count_u32) : (j_layer += 1) {
        var indexOffset: u32 = 0;

        var renderingInfo = std.mem.zeroes(c.VkRenderingInfo);
        renderingInfo.sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO;
        renderingInfo.renderArea.extent.width = s.config.shadow_map_size;
        renderingInfo.renderArea.extent.height = s.config.shadow_map_size;
        renderingInfo.layerCount = 1;

        var depthAttachment = std.mem.zeroes(c.VkRenderingAttachmentInfo);
        depthAttachment.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
        depthAttachment.imageView = pipe.shadowCascadeViews[j_layer];

        depthAttachment.imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        depthAttachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        depthAttachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        depthAttachment.clearValue.depthStencil = .{ .depth = 1.0, .stencil = 0 };

        renderingInfo.pDepthAttachment = &depthAttachment;

        if (s.context.vkCmdBeginRendering) |func| {
            func(cmd, &renderingInfo);
        }

        var vp = std.mem.zeroes(c.VkViewport);
        vp.width = @floatFromInt(s.config.shadow_map_size);
        vp.height = @floatFromInt(s.config.shadow_map_size);
        vp.maxDepth = 1.0;
        c.vkCmdSetViewport(cmd, 0, 1, &vp);

        var sc = std.mem.zeroes(c.VkRect2D);
        sc.extent.width = s.config.shadow_map_size;
        sc.extent.height = s.config.shadow_map_size;
        c.vkCmdSetScissor(cmd, 0, 1, &sc);

        c.vkCmdSetDepthBias(cmd, 0.0, 0.0, 0.0);

        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.shadowPipeline);

        if (pipe.shadowDescriptorManager) |mgr| {
            var sets: ?[*]const c.VkDescriptorSet = null;
            var descriptorSets = [_]c.VkDescriptorSet{pipe.shadowDescriptorSets[frame_check]};

            const use_buffers = mgr.useDescriptorBuffers;
            if (use_buffers or (pipe.shadowDescriptorSets[frame_check] != null and @intFromPtr(pipe.shadowDescriptorSets[frame_check]) != 0)) {
                sets = &descriptorSets;
            }
            descriptor_mgr.vk_descriptor_manager_bind_sets(mgr, cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.shadowPipelineLayout, 0, 1, sets, 0, null);
        } else {
            if (pipe.shadowDescriptorSets[frame_check] != null and @intFromPtr(pipe.shadowDescriptorSets[frame_check]) != 0) {
                const descriptorSets = [_]c.VkDescriptorSet{pipe.shadowDescriptorSets[frame_check]};
                c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.shadowPipelineLayout, 0, 1, &descriptorSets, 0, null);
            }
        }

        const vertexBuffers = [_]c.VkBuffer{pipe.vertexBuffer};
        const offsets = [_]c.VkDeviceSize{0};
        c.vkCmdBindVertexBuffers(cmd, 0, 1, &vertexBuffers, &offsets);

        if (pipe.indexBuffer != null) {
            c.vkCmdBindIndexBuffer(cmd, pipe.indexBuffer, 0, c.VK_INDEX_TYPE_UINT32);
        }

        shadows_log.debug("Cascade {d}: Starting Pass 1 (Opaque)", .{j_layer});
        var m_i: u32 = 0;
        var drawn_count: u32 = 0;
        var candidate_count: u32 = 0;
        while (m_i < scn.mesh_count) : (m_i += 1) {
            shadows_log.debug("Pass 1: Mesh {d}", .{m_i});
            if (scn.meshes == null) {
                shadows_log.err("scn.meshes is null!", .{});
                break;
            }
            const mesh = &scn.meshes.?[m_i];

            if (mesh.index_count == 0) {
                continue;
            }

            var is_alpha_tested = false;
            if (mesh.material_index < scn.material_count) {
                shadows_log.debug("Checking material {d}", .{mesh.material_index});
                if (scn.materials) |mats| {
                    const mat = &mats[mesh.material_index];
                    if (mat.alpha_mode == scene.CardinalAlphaMode.MASK) {
                        is_alpha_tested = true;
                    }
                }
            }

            if (is_alpha_tested) {
                if (pipe.shadowAlphaPipeline != null and mesh.vertex_count > 0 and mesh.visible) {
                    candidate_count += 1;
                }
                const next_offset: u64 = @as(u64, indexOffset) + @as(u64, mesh.index_count);
                if (next_offset > @as(u64, pipe.totalIndexCount)) break;
                indexOffset = @intCast(next_offset);
                continue;
            }

            if (mesh.vertex_count == 0 or !mesh.visible) {
                const next_offset: u64 = @as(u64, indexOffset) + @as(u64, mesh.index_count);
                if (next_offset > @as(u64, pipe.totalIndexCount)) break;
                indexOffset = @intCast(next_offset);
                continue;
            }

            candidate_count += 1;
            drawn_count += 1;

            var packedInfo: u32 = 0;
            if (scn.animation_system != null and scn.skin_count > 0) {
                shadows_log.debug("Checking skins for mesh {d}. Skin count: {d}", .{ m_i, scn.skin_count });
                if (scn.skin_count < 100) {
                    if (scn.skins) |skins_ptr| {
                        const skins = @as([*]animation.CardinalSkin, @ptrCast(@alignCast(skins_ptr)));
                        var skin_idx: u32 = 0;
                        while (skin_idx < scn.skin_count) : (skin_idx += 1) {
                            const skin = &skins[skin_idx];
                            if (skin.mesh_count > 1000) {
                                shadows_log.warn("Skin {d} has suspicious mesh_count: {d}", .{ skin_idx, skin.mesh_count });
                                break;
                            }
                            if (skin.mesh_indices) |indices| {
                                var mesh_idx: u32 = 0;
                                while (mesh_idx < skin.mesh_count) : (mesh_idx += 1) {
                                    if (indices[mesh_idx] == m_i) {
                                        packedInfo |= (4 << 16);
                                        break;
                                    }
                                }
                            }
                            if ((packedInfo & (4 << 16)) != 0) break;
                        }
                    }
                } else {
                    shadows_log.err("Suspicious skin count: {d}", .{scn.skin_count});
                }
            }

            const cascadeIdx = @as(u32, @intCast(j_layer));
            var push = std.mem.zeroes(types.ShadowPushConstants);
            push.model = mesh.transform;
            push.packed_info = packedInfo;
            push.cascade_index = cascadeIdx;

            c.vkCmdPushConstants(cmd, pipe.shadowPipelineLayout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @intCast(@sizeOf(types.ShadowPushConstants)), &push);

            if (@as(u64, indexOffset) + @as(u64, mesh.index_count) > @as(u64, pipe.totalIndexCount)) {
                break;
            }

            c.vkCmdDrawIndexed(cmd, mesh.index_count, 1, indexOffset, 0, 0);

            const next_offset: u64 = @as(u64, indexOffset) + @as(u64, mesh.index_count);
            if (next_offset > @as(u64, pipe.totalIndexCount)) break;
            indexOffset = @intCast(next_offset);
        }

        if (pipe.shadowAlphaPipeline != null) {
            c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe.shadowAlphaPipeline);

            indexOffset = 0;
            m_i = 0;
            while (m_i < scn.mesh_count) : (m_i += 1) {
                if (scn.meshes == null) break;
                const mesh = &scn.meshes.?[m_i];

                if (mesh.index_count == 0) {
                    continue;
                }

                var is_alpha_tested = false;
                var texture_idx: u32 = 0;
                var alpha_cutoff: f32 = 0.5;

                if (mesh.material_index < scn.material_count and scn.materials != null) {
                    const mat = &scn.materials.?[mesh.material_index];
                    if (mat.alpha_mode == scene.CardinalAlphaMode.MASK) {
                        is_alpha_tested = true;
                        texture_idx = mat.albedo_texture.index;
                        alpha_cutoff = mat.alpha_cutoff;
                    }
                }

                if (!is_alpha_tested) {
                    const next_offset: u64 = @as(u64, indexOffset) + @as(u64, mesh.index_count);
                    if (next_offset > @as(u64, pipe.totalIndexCount)) break;
                    indexOffset = @intCast(next_offset);
                    continue;
                }

                if (mesh.vertex_count == 0 or !mesh.visible) {
                    const next_offset: u64 = @as(u64, indexOffset) + @as(u64, mesh.index_count);
                    if (next_offset > @as(u64, pipe.totalIndexCount)) break;
                    indexOffset = @intCast(next_offset);
                    continue;
                }

                drawn_count += 1;

                var packedInfo: u32 = 0;
                if (scn.animation_system != null and scn.skin_count > 0) {
                    if (scn.skin_count < 100 and scn.skins != null) {
                        const skins = @as([*]animation.CardinalSkin, @ptrCast(@alignCast(scn.skins.?)));
                        var skin_idx: u32 = 0;
                        while (skin_idx < scn.skin_count) : (skin_idx += 1) {
                            const skin = &skins[skin_idx];
                            if (skin.mesh_count > 1000) break;
                            if (skin.mesh_indices) |indices| {
                                var mesh_idx: u32 = 0;
                                while (mesh_idx < skin.mesh_count) : (mesh_idx += 1) {
                                    if (indices[mesh_idx] == m_i) {
                                        packedInfo |= (4 << 16);
                                        break;
                                    }
                                }
                            }
                            if ((packedInfo & (4 << 16)) != 0) break;
                        }
                    }
                }

                const cascadeIdx = @as(u32, @intCast(j_layer));
                var push = std.mem.zeroes(types.ShadowPushConstants);
                push.model = mesh.transform;
                push.texture_index = texture_idx;
                push.alpha_cutoff = alpha_cutoff;
                push.packed_info = packedInfo;
                push.cascade_index = cascadeIdx;

                c.vkCmdPushConstants(cmd, pipe.shadowPipelineLayout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @intCast(@sizeOf(types.ShadowPushConstants)), &push);

                if (@as(u64, indexOffset) + @as(u64, mesh.index_count) > @as(u64, pipe.totalIndexCount)) {
                    break;
                }

                c.vkCmdDrawIndexed(cmd, mesh.index_count, 1, indexOffset, 0, 0);

                const next_offset: u64 = @as(u64, indexOffset) + @as(u64, mesh.index_count);
                if (next_offset > @as(u64, pipe.totalIndexCount)) break;
                indexOffset = @intCast(next_offset);
            }
        }

        if (scn.mesh_count > 0 and j_layer == 0 and drawn_count == 0) {
            if (candidate_count > 0) {
                shadows_log.warn("No meshes drawn for cascade 0! Total meshes: {d}", .{scn.mesh_count});
            }
        }

        if (s.context.vkCmdEndRendering) |func| {
            func(cmd);
        }
    }
}
