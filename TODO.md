# Cardinal Engine Roadmap

This document outlines the roadmap for the Cardinal Engine, focusing on robustness, extensibility, and future feature implementation.

## 1. Core Architecture (Robustness & Extensibility)

### Memory Management
- [x] **Dynamic Memory Tracking**: Replace the fixed-size allocation table (`MAX_ALLOCS`) with a dynamic hash map to support unlimited tracking in debug mode.
- [x] **Memory Arenas/Zones**: Implement memory arenas (linear allocators) for subsystems (e.g., "Level Heap", "Frame Heap") to improve cache locality and reduce fragmentation.
- [x] **Leak Detection**: Enhance the leak detector to provide stack traces for leaked allocations.

### System Architecture
- [x] **Event Bus**: Implement a publish/subscribe event system to decouple subsystems (e.g., Input triggers an Event, which the PlayerController consumes).
- [x] **Module System**: Define a clear lifecycle (Init, Update, Shutdown) for all engine subsystems to ensure correct startup/shutdown order.
- [x] **Error Handling**: Standardize error handling across the engine (unify Zig error sets and C-style return codes where boundary crossing happens).

### Math Library (Optimization)
- [x] **SIMD Implementation**: Rewrite `Vec3`, `Vec4`, `Quat` using Zig's `@Vector(4, f32)` to leverage hardware intrinsics (SSE/AVX/NEON).
- [x] **Matrix Optimization**: Optimize `Mat4` multiplication to use SIMD or unrolled loops, replacing the current slow scalar loops.
- [ ] **Missing Types**: Implement `Mat3` (for normal matrices) and `Ray` structs.

### Logging & Diagnostics
- [x] **Log Categories**: Implement granular logging channels (e.g., `[RENDER]`, `[ASSET]`, `[PHYSICS]`, `[SCRIPT]`) to allow filtering.
- [x] **Log Sinks**: Create an interface for log outputs to support multiple targets simultaneously (Console, File, Editor Panel, Network).
- [x] **Structured Logging**: Support structured data (JSON) for easy parsing by external tools.

## 2. Data & Assets

### Asset System
- [x] **Unified Asset Manager**: Create a central system to manage all asset types (Textures, Meshes, Shaders, Sounds) with consistent reference counting and handle-based access.
- [ ] **Asset Database**: Implement a metadata system (`.meta` files) to store import settings and GUIDs for assets, decoupling file paths from asset identity.
- [ ] **Hot-Reloading**: Generic hot-reloading support for all asset types, not just shaders.

### Scene System
- [ ] **ECS Architecture**: Design and implement a Sparse-Set based Entity Component System (ECS) to replace the current Object-Oriented hierarchy.
    - *Components*: Transform, MeshRenderer, Light, Camera, Script.
    - *Systems*: RenderSystem, PhysicsSystem, ScriptSystem.
- [ ] **Scene Serialization**: Robust save/load system using a schema-based format (JSON/Binary) that supports versioning.

## 3. Rendering (Vulkan)

### Architecture
- [x] **RHI (Render Hardware Interface)**: Abstract raw Vulkan calls behind a high-level API (`CommandList`, `Texture`, `Buffer`) to simplify renderer code and potentially support other backends in the future.
- [x] **Frame Graph / Render Graph**: Implement a dependency graph for render passes to automatically manage barriers and resource transitions.
    - *Current State*: `RenderGraph` is just a list of function pointers. It needs to track resource usage (READ/WRITE) to insert barriers automatically.
- [x] *Task*: Define inputs/outputs for automatic barriers in `RenderGraph` (`vulkan_renderer.zig`). Currently PBR pass handles its own transitions.

### Features
- [ ] **Shader Hot-Reloading**: Watch shader files and recompile/reload pipelines at runtime.
- [x] **Pipeline Caching**: Save/Load `VkPipelineCache` to disk.
- [x] **Shadow Mapping**: Cascaded Shadow Maps (CSM) for directional lights, Cube Maps for point lights.
- [ ] **IBL (Image-Based Lighting)**: Environment Maps, Irradiance Maps, Prefiltered Specular.
- [ ] **Post-Processing**: Bloom, Tone Mapping (ACES/Filmic), Gamma Correction.
- [ ] **Ambient Occlusion**: SSAO or HBAO.
- [ ] **Emissive Strength**: Support `KHR_materials_emissive_strength`.

## 4. Editor & Tools

### Editor Core
- [ ] **Command Pattern**: Implement Undo/Redo system for all editor actions.
- [ ] **Selection System**: Robust raycasting/picking system for selecting entities in the viewport.
- [ ] **Gizmos**: Manipulation gizmos (Translate, Rotate, Scale) and debug drawing (Lines, Boxes, Spheres).

### UI/UX
- [ ] **Asset Browser**: Thumbnail generation and drag-and-drop support.
- [ ] **Inspector**: Generic reflection-based property editing for components.
- [ ] **Multiple Windows**: Support for detaching editor panels (ImGui Viewports).
- [ ] **Grid & Axes**: Visual reference guides in the viewport.

## 5. Platform & Input

### Input System
- [x] **Core Input Integration**: Move input polling from the Editor layer (`editor/systems/input.zig`) to the Engine core (`engine/core/input.zig`).
    - *Current Issue*: The Engine has no native input handling; the Editor manually polls GLFW.
- [x] **Window Callbacks**: Update `CardinalWindow` to support Key, MouseButton, and CursorPos callbacks.
- [x] **Input Action Mapping**: Abstract physical keys to logical actions (`MoveForward`, `Jump`) with remapping support.
- [ ] **Gamepad Support**: Full gamepad polling and vibration support.
- [x] **Input Layers**: Support for input context stacks (e.g., UI takes input over Game).

### OS Integration
- [ ] **High DPI**: Proper scaling support for high-resolution displays.
- [ ] **File System**: Abstract file system operations to support virtual paths (`asset://textures/logo.png`).

## 6. Build & CI
- [ ] **Zig Build**: Polish `build.zig` for cross-compilation and asset processing steps.
- [ ] **Tests**: Add unit tests for core systems (Math, Memory, Containers).
