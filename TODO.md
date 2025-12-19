# Cardinal Engine Improvements

This document outlines areas for improvement, refactoring, and future extensions for the Cardinal Engine.

## 1. Engine Core & Architecture

### Memory Management
- [x] **Standardize Allocators**: Move away from raw `malloc`/`free` in C++-interop code (e.g., `vulkan_pbr.zig`, `vulkan_renderer.zig`). Use Zig's allocator interface passed down from `Core`.
- [x] **Allocator Stats**: Add a debug overlay to show memory usage per category (Renderer, Assets, Scripting, etc.).
- [x] **Pool Allocators**: Implement pool allocators for frequent small objects (e.g., `SceneNode`, `CommandBuffers`).

### Logging
- [ ] **Structured Logging**: Improve the logging system to support structured data (JSON) for external tools.
- [ ] **Log Categories**: Define clear categories (Render, Asset, Input, System) to filter logs effectively in the Editor.

### Async Systems
- [x] **Task Dependencies**: `CardinalAsyncTask` currently links via `next` pointer, but true dependency graph support (Task A waits for Task B) would be beneficial.
- [x] **Job System**: Migrated `CardinalAsyncLoader` to a more generic Job System (`job_system.zig`).

## 2. Rendering (Vulkan)

### Abstraction & Safety
- [x] **Vulkan Wrappers**: Reduce raw C-style Vulkan calls in high-level logic. Create safe Zig wrappers for `VkDevice`, `VkQueue`, `VkCommandBuffer`.
- [x] **Handle Safety**: Use typed handles (e.g., `TextureHandle`, `MeshHandle`) instead of raw pointers to avoid use-after-free and dangling pointers.
- [x] **Descriptor Management**: The manual descriptor binding in `vulkan_pbr.zig` is fragile. Implement a reflection-based or data-driven descriptor set layout system.

### Features
- [x] **Bindless Textures**: The code hints at descriptor indexing (`descriptorCount = 5000` in `vulkan_pbr.zig`), but fully utilizing bindless resources would simplify material management.
- [ ] **Render Graph**: Move from hardcoded pipeline steps to a Frame Graph / Render Graph to handle complex dependencies (Shadows -> GBuffer -> Lighting -> PostFX).
- [ ] **Shader Hot-Reloading**: Implement file watchers to reload shaders at runtime without restarting the editor.

### Performance
- [x] **VMA Integration**: Replace custom `vulkan_allocator.zig` logic with Vulkan Memory Allocator (VMA) library for production-grade memory management.
- [ ] **Pipeline Caching**: Save/Load `VkPipelineCache` to disk to speed up startup times.

## 3. Asset Management

### glTF Loader
- [ ] **Robustness**: The current `gltf_loader.zig` (inferred) likely handles basics. Ensure support for:
    - Sparse accessors.
    - Morph targets.
    - Multiple UV sets.
    - Draco compression (extension).
- [ ] **Streaming**: Implement texture streaming to load low-res mips first, then high-res.

### Scene System
- [ ] **ECS Migration**: The current `CardinalSceneNode` hierarchy is an Object-Oriented approach. Migrating to an Entity Component System (ECS) (like `Zig-ECS` or custom) would improve performance and flexibility for game logic.
- [ ] **Scene Serialization**: Implement saving scenes to a custom binary format or JSON, not just importing glTF.

## 4. Editor

### Architecture
- [x] **Componentization**: Refactor `editor_layer.zig` (currently monolithic) into separate systems/panels:
    - `panels/scene_hierarchy.zig`
    - `panels/inspector.zig`
    - `panels/content_browser.zig`
    - `systems/input.zig`
    - `systems/camera_controller.zig`
- [ ] **Command Pattern**: Implement an `EditorCommand` system for Undo/Redo support.

### Usability
- [ ] **Gizmos**: Add translation/rotation/scale gizmos in the viewport (using `ImGuizmo` or custom).
- [ ] **Grid & Axes**: Render a reference grid and coordinate axes.
- [ ] **Asset Preview**: Generate thumbnails for assets in the browser.

## 5. Platform & Input

### Input
- [ ] **Input Action System**: Abstract raw keys (`GLFW_KEY_W`) into Actions (`MoveForward`). This allows remapping and gamepad support.
- [ ] **Gamepad Support**: Add GLFW gamepad state polling.

### Windowing
- [ ] **High DPI**: Verify High DPI support on Windows/Linux/macOS.
- [ ] **Multiple Windows**: Support separating Editor panels into native OS windows (ImGui Viewports).

## 6. Build System

- [ ] **Zig Build**: Ensure `build.zig` supports:
    - Shader compilation (glslc/dxc) as a build step.
    - Asset copying/processing.
    - Cross-compilation setup.

## 7. Math

- [x] **Math Library**: Consolidate math types. Currently using arrays `[16]f32`. Create/Use a struct-based library (e.g., `zmath` or internal structs) with methods (`vec3.add()`, `mat4.mul()`) for better readability.
