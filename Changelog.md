# Changelog

## 2026.02

### Core Systems & Animation
- **Transform System**: Implement a dedicated system to handle hierarchy updates and dirty flags, ensuring world matrices are only recomputed when necessary.
- **Animation Optimization**: Cache last-used keyframe indices to optimize binary search in `animation.zig`.
- **ECS**: Entity References fix (robust Hierarchy entity handling).
- **ECS**: Multi-Component Views iterator.
- **ECS**: System Parallelization with dependency graph.
- **ECS**: Archetype Storage investigation complete; implemented core Archetype and Chunk structures.
- **ECS**: Component Command Buffer (deferred structural changes, scheduler integration).

### Asset Pipeline
- **NIF Loader**: Implement auto-generation of UVs for meshes with 0 UV sets (`nif_loader.zig`).
- **NIF Loader**: Optimize material allocation (shrink to fit) in `nif_loader.zig`.
- **NIF Loader**: Improved return robustness and support for appending to existing lists.
- **GLTF Loader**: Remove temporary debugging logs (`gltf_loader.zig`).
- **Texture Manager**: Ensure texture format is correctly updated from AssetManager when replacing placeholders (`vulkan_texture_manager.zig`).
- **Assets**: Thread Safety fix in gltf_loader with std.once.

### Rendering / Render Graph
- **SSAO**: Blur-to-PBR transition is now handled via the Render Graph using `RESOURCE_ID_SSAO_BLURRED`; manual blur-to-PBR image barrier was removed so cross-pass layout/access changes are fully declarative [vulkan_ssao.zig].
- **Shadow Maps**: Modeled as a Render Graph resource (`RESOURCE_ID_SHADOW_MAP`), produced by the Shadow Pass and consumed by the PBR Pass; manual layout transitions removed [vulkan_shadows.zig].
- **Full Driver**: Render Graph now fully drives the frame: Depth Pre-pass and SSAO passes with explicit inputs/outputs, SSAO blurred image registration, and execution via `rg.execute` instead of manual depth/SSAO control flow.
- **Skybox/UI**: Migrated Skybox and UI into Render Graph: skybox and UI pass callbacks, passes writing to BACKBUFFER with attachment layout.
- **Present Pass**: Added Present pass and Mesh Shader prep into the Render Graph: Present pass transitions BACKBUFFER to `PRESENT_SRC_KHR` and removes the manual present barrier.
- **Diagnostics**: Added Render Graph diagnostics: compile-time logging of active passes and tracked resources, per-pass logging when transient resources are released for aliasing.
- **Barriers**: General Render Graph improvements: automatic barrier generation around pass inputs/outputs, transient memory aliasing via per-pass lifetimes and pooling, subresource-range support for image barriers.
- **Refinements**: Tightened integration and removed remaining manual barriers.

### Rendering / Mesh Shaders & Pipelines
- **Pipeline Initialization**: Unified pipeline initialization logging and error handling across PBR, Skybox, SSAO, simple, mesh-shader, compute, and post-process helpers using a shared helper in the renderer bootstrap [vulkan_renderer.zig].
- **Mode Toggles**: Centralized UV/Wireframe mode recovery logic into a single helper invoked by `cardinal_renderer_set_rendering_mode` to recreate simple pipelines when needed [vulkan_renderer.zig].
- **Transient Pools**: Implemented transient command buffer pools for short-lived operations: transient_pools on VulkanCommands, per-frame transient command pools and buffers, immediate-submit integration.
- **Async Compute**: Async Compute integration: compute queue family detection, per-frame compute transient pools and buffers, executing compute passes on a compute command buffer.
- **Mesh Shader**: Simplified mesh-shader path handling by centralizing shader path formatting in a helper reused across initialization and runtime toggles.
- **Cleanup**: Removed redundant post-process initialization during renderer creation to avoid double-init and keep the creation flow lean.

### Rendering / Quality & Optimization
- **Property ID Hashing**: Replace string lookups in `MaterialSystem` with hashed IDs (or pre-baked offsets) for performance.
- **Frame Pacing**: Improve frame pacing logic in `vulkan_swapchain.zig` to handle VSync and different refresh rates more smoothly.
- **HDR Support**: Fully validate and calibrate HDR10 output (ST2084) on supported displays.
- **Ambient Occlusion**: SSAO/HBAO implementation.
- **Shadows**: Improvements (PCF, CSM).
- **Post-Processing**: Stack (Bloom, ACES, Color Correction).
- **Optimization**: Bindless Descriptors and pipeline caching to disk.

### Editor & Tools
- **Selection System**: Robust raycasting/picking system.
- **Gizmos**: Manipulation gizmos (Translate, Rotate, Scale) and debug drawing.
- **Debugging**: Tracy Profiler integration.

### OS Integration
- **Logging**: Async logging to background thread.
- **DPI**: High DPI scaling support.
