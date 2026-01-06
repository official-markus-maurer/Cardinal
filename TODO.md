# Cardinal Engine Roadmap

This document outlines the roadmap for the Cardinal Engine, focusing on robustness, extensibility, and future feature implementation.

## 1. Core Architecture (Robustness & Extensibility)

### Memory Management
- [ ] **Stack Allocator**: Implement a double-ended stack allocator for efficient frame-temporary memory (replacing general heap allocations for temporary data).
- [ ] **Job System Optimization**: 
    - Implement a **Pool Allocator** for `Job` structs to avoid `malloc` overhead per job.
    - Remove the hard limit of 8 dependents per job.
    - (Long-term) Switch to a **Fiber-based** job system (Naughty Dog / GDC 2015 style) for finer-grained concurrency and to avoid blocking worker threads.

### Math Library (Optimization)
- [ ] **Missing Types**: Implement `Mat3` (for normal matrices) and `Ray` structs.

## 2. Data & Assets

### Asset System
- [ ] **Asset Database**: Implement a metadata system (`.meta` files) to store import settings and GUIDs for assets, decoupling file paths from asset identity.
- [ ] **Bug Fix**: Fix `releaseTexture` in `asset_manager.zig` not removing entries from `texture_path_map` (dangling key issue).
- [ ] **Async Loading**: Implement a proper `Promise` or `Handle` state system for async loading, allowing the engine to query if an asset is `Loading`, `Ready`, or `Failed`.
- [ ] **Hot-Reloading**: Generic hot-reloading support for all asset types.
- [ ] **Shader Compilation**: Integrate runtime shader compilation (e.g., shaderc or slang) to compile `.glsl` to `.spv` on the fly.

### Scene System
- [ ] **ECS Architecture**: Design and implement a Sparse-Set based Entity Component System (ECS) to replace the current Object-Oriented hierarchy.
    - *Components*: Transform, MeshRenderer, Light, Camera, Script.
    - *Systems*: RenderSystem, PhysicsSystem, ScriptSystem.
- [ ] **Scene Serialization**: Robust save/load system using a schema-based format (JSON/Binary) that supports versioning.

## 3. Rendering (Vulkan)

### Core Architecture
- [x] **Render Graph 2.0**: Enhance `RenderGraph` to support:
    - **Transient Resources**: Automatically allocate/free attachments (images/buffers) that are only needed for a single frame.
    - **Graph Culling**: Automatically prune passes that do not contribute to the backbuffer.
    - **Async Compute**: Support queue ownership transfers for parallel compute execution.
- [x] **Data-Driven Pipelines**: Replace hardcoded pipeline setup (`vulkan_pbr.zig`, etc.) with a data-driven approach where Pipeline State Objects (PSOs) are loaded from asset files.
- [ ] **Pipeline Caching**: Implement `VkPipelineCache` serialization.
- [ ] **Bindless Architecture**: Standardize on the existing `VK_EXT_descriptor_buffer` implementation in `vulkan_descriptor_manager.zig`.

### Lighting & Materials
- [x] **Material System**: Decouple materials from specific pipelines. Create a generic material system.
- [ ] **IBL**: Implement Environment Maps, Irradiance Maps, and Prefiltered Specular maps.
- [ ] **Advanced Shadows**: Cascade Shadow Maps (CSM) refinement and Soft Shadows (PCF/PCSS).
- [ ] **Emissive Strength**: Support `KHR_materials_emissive_strength`.
- [ ] **Ambient Occlusion**: SSAO or HBAO.

### Post-Processing
- [ ] **Render Graph Integration**: Implement post-processing effects as `RenderPass` nodes.
- [ ] **Effects**: Bloom, Tone Mapping (ACES/Filmic), Gamma Correction, Chromatic Aberration.

### Optimization
- [ ] **GPU Culling**: Implement GPU-driven frustum and occlusion culling using Mesh Shaders or Compute Shaders.

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
