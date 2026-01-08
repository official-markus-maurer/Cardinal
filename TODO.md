# Cardinal Engine Roadmap

This document outlines the roadmap for the Cardinal Engine, focusing on robustness, extensibility, and future feature implementation.

## 1. Core Architecture (Robustness & Extensibility)

### Memory Management
- [ ] **Fiber-based Job System (Long-term)**:
    - Switch to a **Fiber-based** architecture (Naughty Dog / GDC 2015 style).
    - Enable finer-grained concurrency.
    - Avoid blocking worker threads during dependency waits.

### Math Library (Optimization)
- [ ] **Missing Types**: Implement `Mat3` (for normal matrices) and `Ray` structs.
- [ ] **Missing Operations**: Implement `Mat4`, `Quat` (quaternions), `lerp`, `slerp`, `reflect` in `math.zig`.

### Code Cleanup & Refactoring
- [ ] **Synchronization**:
    - [ ] Handle `vkDeviceWaitIdle` failures gracefully in `vulkan_sync_manager.zig` (currently ignored during reset).
    - [ ] Externalize hardcoded timeline semaphore constants (e.g., `1000000` limit) to a config or constant definition.
- [ ] **Job System**:
    - [ ] Add **Error Propagation**: Allow jobs to return errors and handle them in the completion queue/callback.
- [ ] **Renderer Configuration**:
    - [ ] Move hardcoded values (e.g., PBR clear color `0.05, 0.05, 0.08`) to a `RendererConfig` struct.
    - [ ] Externalize hardcoded asset paths (e.g., `"assets/pipelines/*.json"`, `"assets/shaders"`) found in `vulkan_pbr.zig` and others.
    - [ ] Move Shadow constants (`SHADOW_MAP_SIZE`, `SHADOW_CASCADE_COUNT`, `lambda`, clips) from `vulkan_shadows.zig` to configuration.
- [ ] **Code Deduplication**:
    - [ ] Consolidate `get_current_thread_id` (found in `vulkan_commands.zig` and `texture_loader.zig`) into a shared `core/platform.zig` helper.
    - [ ] Consolidate platform-specific time logic (found in `vulkan_swapchain.zig` and likely others) into `core/platform.zig`.
- [ ] **Engine Core**:
    - [ ] Implement **Delta Time** calculation in `CardinalEngine.update` and pass it to subsystems (`engine.zig`). Currently, the engine lacks a standardized time step.
    - [x] Externalize `CardinalEngineConfig` defaults (resolution, threads) to a config file.
    - [x] Verify Matrix Multiplication Order: Ensure `math.zig` and `transform.zig` consistently use column-major (or row-major) order to avoid subtle bugs.
    - [x] **Event System Optimization**: `events.zig` currently allocates (clones listener list) on every event publish to avoid deadlocks. Optimize this (e.g., small stack buffer, copy-on-write).
    - [ ] **Module System**: Add explicit dependency management or validation to `module.zig` (currently relies on manual registration order).
    - [ ] **Reference Counting**: Add weak reference support or cycle detection to `ref_counting.zig` to prevent leaks from circular dependencies.
    - [ ] **Handle System**: Implement a generic `HandleManager` to centralize safe handle generation (index + generation) instead of ad-hoc logic per resource type.
- [ ] **Vulkan Optimization**:
    - [ ] Verify `CardinalLight` and `CardinalCamera` struct alignment for UBO compatibility (std140).
    - [ ] **Pipeline Cache**: Implement persistence (save/load `VkPipelineCache` to disk) to improve startup times (`vulkan_pipeline.zig`/`vulkan_pso.zig`).
- [ ] **Texture Loader**:
    - [ ] Verify and address "not yet ported" C header dependencies.

## 2. Data & Assets

### Asset System
- [ ] **Asset Database**: Implement a metadata system (`.meta` files) to store import settings and GUIDs for assets, decoupling file paths from asset identity.
- [ ] **Hot-Reloading**: Generic hot-reloading support for all asset types.
- [ ] **Shader Compilation**: Integrate runtime shader compilation (e.g., shaderc or slang) to compile `.glsl` to `.spv` on the fly.

### Scene System
- [ ] **ECS Architecture**: Design and implement a Sparse-Set based Entity Component System (ECS) to replace the current Object-Oriented hierarchy.
    - *Components*: Transform, MeshRenderer, Light, Camera, Script.
    - *Systems*: RenderSystem, PhysicsSystem, ScriptSystem.
- [ ] **Scene Serialization**: Robust save/load system using a schema-based format (JSON/Binary) that supports versioning.

## 3. Rendering (Vulkan)

### Core Architecture
- [ ] **Pipeline Caching**: Implement `VkPipelineCache` serialization.

### Lighting & Materials
- [ ] **IBL**: Implement Environment Maps, Irradiance Maps, and Prefiltered Specular maps.
- [ ] **Advanced Shadows**: Cascade Shadow Maps (CSM) refinement and Soft Shadows (PCF/PCSS).
- [ ] **Emissive Strength**: Support `KHR_materials_emissive_strength`.
- [ ] **Ambient Occlusion**: SSAO or HBAO.

### Post-Processing
- [ ] **Render Graph Integration**: Implement post-processing effects as `RenderPass` nodes.
- [ ] **Effects**: Bloom, Tone Mapping (ACES/Filmic), Gamma Correction, Chromatic Aberration.

### Optimization
- [ ] **GPU Culling**: Implement GPU-driven frustum and occlusion culling using Mesh Shaders or Compute Shaders.

### Debugging
- [ ] **Timeline Debug Config**: Make `VULKAN_TIMELINE_DEBUG_MAX_EVENTS` configurable or dynamic (`vulkan_timeline_types.zig`).

## 4. Gameplay & Systems (New)

### Physics
- [ ] **Physics Engine**: Integrate a physics middleware (e.g., **Jolt Physics** or **PhysX**).
    - Rigid Body Dynamics
    - Character Controllers
    - Collision Events

### Animation
- [ ] **State Machines**: Implement Animation Blend Trees / State Machines for character logic.
- [ ] **Compression**: Implement animation compression (e.g., ACL) to reduce memory footprint.

### Scripting
- [ ] **Scripting Language**: Integrate a scripting layer (e.g., **Lua**, **C#**, or **Wren**) to allow gameplay logic without recompiling the engine.

### Audio
- [ ] **Audio Engine**: Integrate an audio library (e.g., **miniaudio** or **FMOD**).
    - 3D Spatialization
    - Audio Mixers / Channels

### User Interface
- [ ] **Runtime UI**: Implement a lightweight runtime UI system (e.g., **RmlUi** or custom mesh-based UI) for HUDs and Menus (separate from ImGui editor tools).

## 5. Editor & Tools

### Editor Core
- [ ] **Command Pattern**: Implement Undo/Redo system for all editor actions.
- [ ] **Selection System**: Robust raycasting/picking system.
- [ ] **Gizmos**: Manipulation gizmos (Translate, Rotate, Scale) and debug drawing.

### UI/UX
- [ ] **Asset Browser**: Thumbnail generation and drag-and-drop support.
- [ ] **Inspector**: Generic reflection-based property editing for components.
- [ ] **Multiple Windows**: Support for detaching editor panels (ImGui Viewports).
- [ ] **Grid & Axes**: Visual reference guides.

## 6. Platform & Input

### Input System
- [ ] **Gamepad Support**: Full gamepad polling and vibration support.

### OS Integration
- [ ] **High DPI**: Proper scaling support for high-resolution displays.
- [ ] **File System**: Abstract file system operations to support virtual paths (`asset://textures/logo.png`).
