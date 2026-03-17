# Cardinal Engine Roadmap

This document outlines the roadmap for the Cardinal Engine, focusing on robustness, extensibility, and future feature implementation.

## 1. Core Architecture (Robustness & Extensibility)

### ECS (Entity Component System)
- [ ] **Camera System**: Implement "main" camera tag or flag in `systems.zig` (L52).

### Core Systems
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

#### Terrain System (Scene Graph + Editor Tooling)

**Implementation Checklist**
- [x] Add `Terrain3D` node type and `Terrain` ECS component.
- [x] Add Terrain editor panel and Create Terrain action.
- [x] Add sculpt MVP (vertex displacement + upload on stroke end).
- [x] Optimize sculpt/paint brushes to edit only affected vertices.
- [x] Add sculpt brush modes (raise/lower/flatten/smooth).
- [x] Add paint tool MVP (vertex color / splat preview).
- [x] Add stroke-based undo/redo for terrain edits.
- [x] Switch terrain edits to CPU heightmap + splatmap source-of-truth.
- [x] Upload heightmap + splatmap as GPU textures with sub-updates.
- [x] Add terrain material blending (multi-layer PBR via splatmap).
- [ ] Add chunked terrain + LOD (CDLOD/clipmaps).

**Data Model**
- **Scene graph/ECS**
  - Add `NodeType.Terrain3D` and a `components.Terrain` component attached to an entity.
  - `components.Terrain` stores high-level parameters (world size, resolution) and links to render backing resources (height/splat/normal textures, mesh range or model id).
- **Terrain representation**
  - Render as a regular grid mesh (static topology) displaced by a height texture.
  - Use a splat/alphamap texture for blending surface layers (up to 4 channels per map).
  - Optional derived normal map for correct lighting.

**Rendering Integration**
- **Phase 1 (MVP)**
  - Generate a grid mesh and render it using existing PBR pipeline/materials.
  - Feed the terrain mesh into the existing `combined_scene` flow so picking/selection works.
- **Phase 2 (Terrain shader)**
  - Add a terrain-specific material layout that binds height/splat/normal textures and blends up to 4 PBR layers.
- **Phase 3 (LOD)**
  - Implement CDLOD or Geometry Clipmaps and render terrain in chunks/patches.
  - Consider compute/mesh-shader driven traversal/culling.

**Editor Tooling (Terrain Panel)**
- **Creation**
  - Create terrain at selection or at root with configurable size/resolution.
  - Automatically adds required ECS components and render backing assets/resources.
- **Sculpting tools**
  - Raise/Lower/Flatten/Smooth brushes with radius/strength and falloff.
  - Efficient updates via region updates to the height texture (avoid full scene reupload).
- **Texture painting tools**
  - Paint splatmap channels per layer with optional normalization.
  - Layer assignment UI (Grass/Dirt/Rock/etc) and brush preview.

**Picking + Brush Placement**
- Use camera ray casting to position the brush on terrain (world hit point -> terrain-local UV -> texel coords).
- Keep brush interactions single-step undoable (stroke-based).

**Undo/Redo + Persistence**
- Undo stores only affected texel regions (height/splat rectangles) per stroke, not full maps.
- Scene serialization stores terrain parameters + external asset references; large textures live as separate files.

**Performance Targets**
- Interactive edits should update only dirty tiles/regions per frame.
- Avoid rebuilding/reuploading the entire scene for every brush tick; prefer texture sub-updates or compute edits.

### Asset System
- [ ] **Asset Database**: Implement a metadata system (`.meta` files) to store import settings and GUIDs for assets, decoupling file paths from asset identity.
- [ ] **Binary Asset Format**: Implement offline conversion of textures/meshes to binary formats (e.g., KTX2, custom mesh format) for faster loading.
- [ ] **Asset Streaming**: Implement a streaming system for large assets (textures/meshes) to load chunks on demand.
- [ ] **Texture Loading**: Support HDR texture loading directly from memory in `texture_loader.zig`.
- [ ] **Hot-Reloading**: Generic hot-reloading support for all asset types.
- [ ] **Shader Compilation**: Integrate runtime shader compilation (e.g., shaderc or slang) to compile `.glsl` to `.spv` on the fly.

## 3. Rendering (Vulkan)
- [ ] **IBL**: Implement Environment Maps, Irradiance Maps, and Prefiltered Specular maps.

### Materials & Shaders
- [ ] **Shader Graph**: (Long-term) Node-based shader editor.

### Rendering Quality
- [ ] **Anti-Aliasing**: Implement MSAA (Multisample Anti-Aliasing) or TAA (Temporal Anti-Aliasing).

### Optimization
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
- [x] **File Dialogs**: Implement file dialogs for Save/Open scene

### Editor Core
- [x] **Project Management**: Implement "Project" concept (folder-based) to allow switching between different projects with isolated assets/configs.
- [ ] **Command Pattern**: Implement Undo/Redo system for all editor actions.

### UI/UX
- [ ] **Asset Browser**: Thumbnail generation and drag-and-drop support.
- [ ] **Inspector**: Generic reflection-based property editing for components.
- [x] **Transform Editing**: Support full TRS (Translate, Rotate, Scale) editing in `inspector.zig`.
- [ ] **Multiple Windows**: Support for detaching editor panels (ImGui Viewports).
- [ ] **Grid & Axes**: Visual reference guides.

### Scene Graph & Inspector (Next)
- [ ] **Undo/Redo (Hierarchy)**: Add undoable Create/Rename/Delete/Reparent operations in Scene Graph.
- [ ] **Drag-Drop Reparenting**: Reparent entities by dragging onto another entity in Scene Graph.
- [ ] **Sibling Reordering**: Support drag reorder among siblings + stable ordering persistence.
- [ ] **Multi-Select**: Support multi-select and batch operations (delete, visibility, component add/remove).
- [ ] **Search & Filter**: Add fast search (name/type) with filter chips (Meshes/Lights/Cameras/etc).
- [ ] **Inspector Undo Coverage**: Add undo for Light and Camera field edits (not just add/remove).
- [ ] **Resource Pickers**: Mesh/material pickers in MeshRenderer (names + asset drag-drop), not raw indices.
- [ ] **Copy/Paste Components**: Copy component data between entities; duplicate entity/subtree.
- [ ] **Component Grouping**: Reorder components, pin favorites, and collapse/expand all.
- [ ] **Transform UX**: Local/world toggle, reset buttons, numeric input + copy/paste TRS fields.
- [ ] **Hierarchy Integrity**: Prevent cycles and enforce invariants (child_count, sibling links) on edits.
- [x] **Deletion Cleanup**: Clear mesh ownership maps + transform overrides when entities are destroyed.
- [x] **Large Scene Performance**: Virtualize Scene Graph rendering (ImGui clipper) for thousands of nodes.
- [x] **Focus & Selection Polish**: Keep selection visible across filters; add “Frame in Scene View”.
- [x] **Selection X-Ray Highlight**: Render selected entity subtree visible through geometry (overlay/outline).
- [x] **Scene Serialization IDs**: Move hierarchy serialization from entity index to stable IDs/UUIDs.

## 7. Quality Assurance

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
- [x] **Cross-Platform Build**: Abstract platform-specific linking (Windows/Linux/macOS) in `build.zig`.
- [ ] **Virtual File System (VFS)**: Abstract file system operations to support archives (Zip/Pak) and virtual paths (`asset://`).
- [ ] **Crash Reporting**: Implement a crash handler to save stack traces and minidumps on failure.
