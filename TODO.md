# Cardinal Engine Roadmap

This document outlines the roadmap for the Cardinal Engine, focusing on robustness, extensibility, and future feature implementation.

## 1. Core Architecture (Robustness & Extensibility)

### ECS (Entity Component System)
- [ ] **Camera System**: Implement "main" camera tag or flag in `systems.zig` (L52).

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
- [ ] **Command Pool Expansion**: Handle thread command pool exhaustion dynamically instead of failing (`vulkan_mt.zig` L472).

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
- [ ] **Hot-Reloading**: Generic hot-reloading support for all asset types.
- [ ] **Shader Compilation**: Integrate runtime shader compilation (e.g., shaderc or slang) to compile `.glsl` to `.spv` on the fly.
- [ ] **NIF Loader**: Implement auto-generation of UVs for meshes with 0 UV sets (`nif_loader.zig` L584).
- [ ] **NIF Loader**: Optimize material allocation (shrink to fit) in `nif_loader.zig` (L1164).
- [ ] **GLTF Loader**: Remove temporary debugging logs (`gltf_loader.zig` L1030).
- [ ] **Texture Manager**: Ensure texture format is correctly updated from AssetManager when replacing placeholders (`vulkan_texture_manager.zig` L575).

## 3. Rendering (Vulkan)
- [ ] **IBL**: Implement Environment Maps, Irradiance Maps, and Prefiltered Specular maps.

### Materials & Shaders
- [ ] **Property ID Hashing**: Replace string lookups in `MaterialSystem` with hashed IDs (or pre-baked offsets) for performance.
- [ ] **Data-Driven Materials**: Support loading material layouts and shader variations from JSON/Asset files.
- [ ] **Shader Graph**: (Long-term) Node-based shader editor.

### Rendering Quality
- [ ] **Anti-Aliasing**: Implement MSAA (Multisample Anti-Aliasing) or TAA (Temporal Anti-Aliasing).

### Swapchain & Presentation
- [ ] **Frame Pacing**: Improve frame pacing logic in `vulkan_swapchain.zig` to handle VSync and different refresh rates more smoothly.
- [ ] **HDR Support**: Fully validate and calibrate HDR10 output (ST2084) on supported displays.

### Optimization
- [x] **Render Graph**: Fully drive the rendering loop via the Render Graph, removing hardcoded pass callbacks.
- [ ] **Render Graph Refinements**: Tighten integration and remove remaining manual barriers.
    - `engine/src/renderer/render_graph.zig`: Refine transient image/buffer aliasing heuristics (pooling policy and reuse conditions).
    - `engine/src/renderer/vulkan_mesh_shader.zig`: When adding a dedicated mesh shader render pass, wire it into the Render Graph with `RESOURCE_ID_SHADOW_MAP` and other relevant inputs so shadow sampling is fully tracked.
- [ ] **Pipeline Creation Consistency**: Unify pipeline init log messages and error paths using small helpers to reduce duplication across PBR, Skybox, SSAO, and simple pipelines.
- [ ] **Mode Toggles Cleanup**: Wrap UV/Wireframe recovery logic into a single function to avoid repeated recreation sequences and reduce conditional clutter in `cardinal_renderer_set_rendering_mode`.
- [ ] **GPU-Driven Rendering**: Implement GPU-driven frustum/occlusion culling and scene traversal (Mesh Shaders / Compute Shaders).

### Debugging & Profiling
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
- [ ] **File Dialogs**: Implement file dialogs for Save/Open scene in `editor_layer.zig` (L114, L119).

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

### Validation & Cleanup
- [ ] **Vulkan Object Lifetime**: Fix validation errors reporting live VkCommandBuffer/VkBuffer/VkImage/VkDeviceMemory at vkDestroyDevice shutdown (ensure all GPU resources are destroyed before device teardown).


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
- [ ] **Virtual File System (VFS)**: Abstract file system operations to support archives (Zip/Pak) and virtual paths (`asset://`).
- [ ] **Crash Reporting**: Implement a crash handler to save stack traces and minidumps on failure.
