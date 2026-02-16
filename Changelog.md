# Changelog

## 2026.02
- **Rendering / Render Graph**
  - SSAO blur-to-PBR transition is now handled via the Render Graph using `RESOURCE_ID_SSAO_BLURRED`; the manual blur-to-PBR image barrier was removed so cross-pass layout/access changes are fully declarative [vulkan_ssao.zig].
  - Shadow maps are modeled as a Render Graph resource (`RESOURCE_ID_SHADOW_MAP`), produced by the Shadow Pass and consumed by the PBR Pass; manual layout transitions between depth-attachment and shader-read were removed from the shadow rendering code [vulkan_types.zig], [vulkan_renderer.zig], [vulkan_shadows.zig], [vulkan_commands.zig].
  - Added Render Graph diagnostics: compile-time logging of active passes and tracked resources, per-pass logging when transient resources are released for aliasing, and a renderer-level startup log showing the number of configured passes [render_graph.zig], [vulkan_renderer.zig].
  - Implemented transient command buffer pools for short-lived operations: transient_pools on VulkanCommands, per-frame transient command pools and buffers, immediate-submit integration, and cleanup on shutdown [vulkan_types.zig], [vulkan_commands.zig], [vulkan_renderer.zig].
  - Render Graph now fully drives the frame: Depth Pre-pass and SSAO passes with explicit inputs/outputs, SSAO blurred image registration, and execution via `rg.execute` instead of manual depth/SSAO control flow [vulkan_renderer.zig], [vulkan_commands.zig].
  - Migrated Skybox and UI into Render Graph: skybox and UI pass callbacks, passes writing to BACKBUFFER with attachment layout, and removal of manual skybox/UI rendering from command recording [vulkan_renderer.zig], [vulkan_commands.zig].
  - Added Present pass and Mesh Shader prep into the Render Graph: Present pass transitions BACKBUFFER to `PRESENT_SRC_KHR` and removes the manual present barrier; Mesh Shader prep pass runs before rendering to update descriptor buffers [vulkan_renderer.zig], [vulkan_commands.zig].
  - General Render Graph improvements: automatic barrier generation around pass inputs/outputs, transient memory aliasing via per-pass lifetimes and pooling, subresource-range support for image barriers, and queue ownership transfers based on pass queue family with overrides [render_graph.zig].
  - Async Compute integration: compute queue family detection, per-frame compute transient pools and buffers, executing compute passes on a compute command buffer, timeline-synchronized graphics waiting on compute, and helpers to mark passes as graphics/compute with optional async toggles [vulkan_instance.zig], [vulkan_commands.zig], [render_graph.zig], [vulkan_renderer_frame.zig], [vulkan_types.zig], [core/config.zig].

- **Rendering / Mesh Shaders & Pipelines**
  - Simplified mesh-shader path handling by centralizing shader path formatting in a helper reused across initialization and runtime toggles.
  - Removed redundant post-process initialization during renderer creation to avoid double-init and keep the creation flow lean.

- **Core Systems & Roadmap Items**
  - Moved completed roadmap items from TODO.md:
    - ECS: Entity References fix (robust Hierarchy entity handling).
    - ECS: Multi-Component Views iterator.
    - ECS: System Parallelization with dependency graph.
    - ECS: Archetype Storage investigation complete; implemented core Archetype and Chunk structures.
    - ECS: Component Command Buffer (deferred structural changes, scheduler integration).
    - Assets: Thread Safety fix in gltf_loader with std.once.
    - NIF Loader: Improved return robustness and support for appending to existing lists.
    - Rendering: Ambient Occlusion (SSAO/HBAO).
    - Rendering Quality: Shadow improvements (PCF, CSM).
    - Rendering Quality: Post-Processing Stack (Bloom, ACES, Color Correction).
    - Optimization: Bindless Descriptors and pipeline caching to disk.
    - Debugging & Profiling: Tracy Profiler integration.
    - OS Integration: Async logging to background thread and high DPI scaling support.
