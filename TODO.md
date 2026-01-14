# Cardinal Engine Roadmap

This document outlines the roadmap for the Cardinal Engine, focusing on robustness, extensibility, and future feature implementation.

## 1. Core Architecture (Robustness & Extensibility)

### Memory Management
- [ ] **Fiber-based Job System (Long-term)**:
    - Switch to a **Fiber-based** architecture (Naughty Dog / GDC 2015 style).
    - Enable finer-grained concurrency.
    - Avoid blocking worker threads during dependency waits.
- [ ] **Concurrency Safety**: Replace volatile flags with `std.atomic.Value` in `vulkan_texture_manager.zig` to ensure thread safety across architectures.

## 2. Data & Assets

### Asset System
- [ ] **Asset Database**: Implement a metadata system (`.meta` files) to store import settings and GUIDs for assets, decoupling file paths from asset identity.
- [ ] **Texture Loading**: Support HDR texture loading directly from memory in `texture_loader.zig`.
- [ ] **Thread Safety**: Fix double-checked locking in `gltf_loader.zig` (texture cache) using `std.once`.
- [ ] **Hot-Reloading**: Generic hot-reloading support for all asset types.
- [ ] **Shader Compilation**: Integrate runtime shader compilation (e.g., shaderc or slang) to compile `.glsl` to `.spv` on the fly.

### Scene System
- [ ] **ECS Architecture**: Design and implement a Sparse-Set based Entity Component System (ECS) to replace the current Object-Oriented hierarchy.
    - *Components*: Transform, MeshRenderer, Light, Camera, Script.
    - *Systems*: RenderSystem, PhysicsSystem, ScriptSystem.
- [ ] **Scene Serialization**: Robust save/load system using a schema-based format (JSON/Binary) that supports versioning.

## 3. Rendering (Vulkan)
- [ ] **IBL**: Implement Environment Maps, Irradiance Maps, and Prefiltered Specular maps.
- [ ] **Ambient Occlusion**: SSAO or HBAO.

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
- [ ] **Transform Editing**: Support full TRS (Translate, Rotate, Scale) editing in `inspector.zig` instead of simplified uniform scale.
- [ ] **Multiple Windows**: Support for detaching editor panels (ImGui Viewports).
- [ ] **Grid & Axes**: Visual reference guides.

## 6. Platform & Input

### Input System
- [ ] **Gamepad Support**: Full gamepad polling and vibration support.

### OS Integration
- [ ] **Cross-Platform Build**: Abstract platform-specific sources in `build.zig` to support Linux and macOS.
- [ ] **High DPI**: Proper scaling support for high-resolution displays.
- [ ] **File System**: Abstract file system operations to support virtual paths (`asset://textures/logo.png`).
