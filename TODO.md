# Cardinal Engine Roadmap

This document outlines the roadmap for the Cardinal Engine, focusing on robustness, extensibility, and future feature implementation.

## 1. Core Architecture (Robustness & Extensibility)

### ECS (Entity Component System)
- [x] **Entity References**: Fix `Hierarchy` component storing `u32` indices instead of full `Entity` (index + generation) to prevent ABA problems.
- [x] **Multi-Component Views**: Implement `view<A, B>()` iterator to efficiently iterate entities with multiple specific components.
- [x] **System Parallelization**: Build a dependency graph for systems to allow parallel execution of non-conflicting systems.
- [x] **Archetype Storage**: Investigate moving from Sparse Sets to Archetypes for better cache locality when iterating components together.
    - *Investigation Complete*: Implemented core `Archetype` and `Chunk` structures in `engine/src/ecs/archetype.zig`. Ready for gradual migration.
- [x] **Component Command Buffer**: Defer structural changes (add/remove components) to the end of the frame to allow safe parallel system execution.
    - Implemented `CommandBuffer` struct in `engine/src/ecs/command_buffer.zig`.
    - Integrated with `Scheduler` to provide thread-local command buffers to systems.
    - Updated `SystemFn` signature to accept `*CommandBuffer`.
    - Flushed command buffers at the end of the frame in `Scheduler.run()`.

### Core Systems
- [ ] **Transform System**: Implement a dedicated system to handle hierarchy updates and dirty flags, ensuring world matrices are only recomputed when necessary.
- [ ] **Animation Optimization**: Cache last-used keyframe indices to optimize binary search in `animation.zig`.
- [ ] **Animation Blending**: Implement animation cross-fading and masking (e.g., separate upper/lower body animations).
- [ ] **Math Library**: Add missing geometric primitives (AABB, OBB, Frustum, Plane) and intersection tests.

### Memory & Concurrency
- [ ] **Lock-Free Job System**: Replace mutex/condition variable queue with a lock-free work-stealing queue.
- [ ] **Allocator Improvements**: Investigate high-performance scalable allocators (rpmalloc/mimalloc).
- [ ] **SIMD Math**: Ensure Quaternions and Matrices fully utilize `@Vector` SIMD.
- [ ] **Fiber-based Job System (Long-term)**:
    - Switch to a **Fiber-based** architecture (Naughty Dog / GDC 2015 style).
    - Enable finer-grained concurrency.
    - Avoid blocking worker threads during dependency waits.

## 2. Data & Assets

### World Management
- [ ] **Spatial Partitioning**: Implement an Octree or BVH (Bounding Volume Hierarchy) for efficient scene queries and culling.
- [ ] **Level Streaming**: Implement a system to load/unload grid-based world chunks asynchronously.
- [ ] **Terrain System**: Implement heightmap-based terrain with LOD (CDLOD or Geometry Clipmaps).

### Asset System
- [ ] **Asset Database**: Implement a metadata system (`.meta` files) to store import settings and GUIDs for assets, decoupling file paths from asset identity.
- [ ] **Binary Asset Format**: Implement offline conversion of textures/meshes to binary formats (e.g., KTX2, custom mesh format) for faster loading.
- [ ] **Asset Streaming**: Implement a streaming system for large assets (textures/meshes) to load chunks on demand.
- [ ] **Texture Loading**: Support HDR texture loading directly from memory in `texture_loader.zig`.
- [x] **Thread Safety**: Fix double-checked locking in `gltf_loader.zig` (texture cache) using `std.once`.
- [ ] **Hot-Reloading**: Generic hot-reloading support for all asset types.
- [ ] **Shader Compilation**: Integrate runtime shader compilation (e.g., shaderc or slang) to compile `.glsl` to `.spv` on the fly.

## 3. Rendering (Vulkan)
- [ ] **IBL**: Implement Environment Maps, Irradiance Maps, and Prefiltered Specular maps.
- [ ] **Ambient Occlusion**: SSAO or HBAO.

### Materials & Shaders
- [ ] **Property ID Hashing**: Replace string lookups in `MaterialSystem` with hashed IDs (or pre-baked offsets) for performance.
- [ ] **Data-Driven Materials**: Support loading material layouts and shader variations from JSON/Asset files.
- [ ] **Shader Graph**: (Long-term) Node-based shader editor.

### Rendering Quality
- [ ] **Anti-Aliasing**: Implement MSAA (Multisample Anti-Aliasing) or TAA (Temporal Anti-Aliasing).
- [x] **Shadow Improvements**: Implement PCF (Percentage Closer Filtering) for softer shadows and CSM (Cascaded Shadow Maps) for better large-scale shadows.
- [x] **Post-Processing Stack**: Add support for Bloom, Tone Mapping (ACES), and Color Correction.

### Swapchain & Presentation
- [ ] **Frame Pacing**: Improve frame pacing logic in `vulkan_swapchain.zig` to handle VSync and different refresh rates more smoothly.
- [ ] **HDR Support**: Fully validate and calibrate HDR10 output (ST2084) on supported displays.

### Optimization
- [x] **Bindless Descriptors**: Implement "Bindless" resource binding to reduce descriptor set overhead.
- [x] **Pipeline Caching**: Save and load `VkPipelineCache` to disk to speed up startup.
- [ ] **Transient Command Buffers**: Use separate pools for short-lived command buffers.
- [ ] **Render Graph**: Fully drive the rendering loop via the Render Graph, removing hardcoded pass callbacks.
    - Automatic Barrier Generation.
    - Memory Aliasing (reuse memory for non-overlapping transient resources).
- [ ] **GPU-Driven Rendering**: Implement GPU-driven frustum/occlusion culling and scene traversal (Mesh Shaders / Compute Shaders).

### Debugging & Profiling
- [ ] **Profiler Integration**: Integrate **Tracy Profiler** for real-time CPU/GPU performance analysis.
- [ ] **Timeline Debug Config**: Make `VULKAN_TIMELINE_DEBUG_MAX_EVENTS` configurable or dynamic (`vulkan_timeline_types.zig`).

### Networking
- [ ] **Socket Abstraction**: Implement a cross-platform TCP/UDP socket layer.

## 4. Gameplay & Systems

### Physics
- [ ] **Physics Engine**: Integrate a physics middleware (e.g., **Jolt Physics** or **PhysX**).
    - Rigid Body Dynamics
    - Character Controllers
    - Collision Events

### Scripting
- [ ] **Native Hot-Reload**: Implement DLL/Shared Object hot-reloading for C/Zig gameplay code.
- [ ] **Scripting Language**: Integrate a scripting layer (e.g., **Lua**, **C#**, or **Wren**) to allow gameplay logic without recompiling the engine.

### Audio
- [ ] **Audio Engine**: Integrate an audio library (e.g., **miniaudio** or **FMOD**).
    - 3D Spatialization (HRTF).
    - Audio Mixers / Channels (BGM, SFX, Voice).
    - Audio Streaming for large files (music).

### User Interface
- [ ] **Runtime UI**: Implement a lightweight runtime UI system (e.g., **RmlUi** or custom mesh-based UI) for HUDs and Menus (separate from ImGui editor tools).

## 5. Editor & Tools

### Editor Features
- [ ] **Scene State Serialization**: Save/Restore full editor state (camera position, selected entity, open panels) to `editor.ini` or similar.
- [ ] **Game View**: Separate "Game" view from "Scene" view to preview the camera's perspective.
- [ ] **Console Panel**: Interactive console for logging and executing commands/scripts.

### Editor Core
- [ ] **Project Management**: Implement "Project" concept (folder-based) to allow switching between different projects with isolated assets/configs.
- [ ] **Command Pattern**: Implement Undo/Redo system for all editor actions.
- [ ] **Selection System**: Robust raycasting/picking system.
- [ ] **Gizmos**: Manipulation gizmos (Translate, Rotate, Scale) and debug drawing.

### UI/UX
- [ ] **Asset Browser**: Thumbnail generation and drag-and-drop support.
- [ ] **Inspector**: Generic reflection-based property editing for components.
- [ ] **Transform Editing**: Support full TRS (Translate, Rotate, Scale) editing in `inspector.zig` instead of simplified uniform scale.
- [ ] **Multiple Windows**: Support for detaching editor panels (ImGui Viewports).
- [ ] **Grid & Axes**: Visual reference guides.

## 7. Quality Assurance

### Testing
- [ ] **Test Runner**: Improve `build.zig` to support running subsets of tests and generating coverage reports.
- [ ] **Integration Tests**: Add headless engine tests to verify scene loading and basic system updates without a window.
- [ ] **Graphics Tests**: Implement screenshot comparison tests to catch regression in rendering.

### Documentation
- [ ] **Auto-Docs**: Set up a documentation generator (like `zig-autodoc`) to build API docs from source comments.
- [ ] **Architecture Overview**: Create high-level diagrams of the engine structure.

## 9. Polish & Accessibility

### Localization
- [ ] **Text Localization**: Implement a key-value based localization system (e.g., CSV/JSON) for multi-language support.
- [ ] **Font Fallbacks**: Support font merging/fallbacks for CJK and emoji characters.

### Accessibility
- [ ] **UI Scaling**: Implement DPI-aware UI scaling and user-configurable scale factor.
- [ ] **Input Remapping**: Allow users to rebind keys and controller inputs at runtime.

## 8. Platform & Input
- [ ] **Input Buffering**: Implement an event queue to capture sub-frame inputs (prevent missing fast key presses).
- [ ] **Text Input**: Add support for character input events (for UI text fields).
- [ ] **Gamepad Support**: Full gamepad polling and vibration support.

### OS Integration
- [ ] **Cross-Platform Build**: Abstract platform-specific linking (Windows/Linux/macOS) in `build.zig`.
- [ ] **Async Logging**: Move log formatting and writing to a background thread to reduce main thread overhead.
- [ ] **High DPI**: Proper scaling support for high-resolution displays.
- [ ] **Virtual File System (VFS)**: Abstract file system operations to support archives (Zip/Pak) and virtual paths (`asset://`).
- [ ] **Crash Reporting**: Implement a crash handler to save stack traces and minidumps on failure.
