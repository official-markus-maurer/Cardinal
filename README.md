# Cardinal Engine

**Cardinal Engine** is a modern, high-performance game engine written in **Zig**, designed for robustness, extensibility, and modern rendering features. It leverages **Vulkan** for rendering and **ImGui** for its editor interface, providing a powerful environment for 3D application development.

> **Note**: This project has migrated from a pure C codebase to Zig to take advantage of its build system, comptime features, and safety.

## Key Features

### Core Architecture
- **Zig-based**: Built with Zig 0.15+ for modern systems programming, utilizing comptime and safety features.
- **Job System**: Multithreaded job system with dependency management and priority queues.
- **Memory Management**: Custom allocators (Linear, Pool, Tracking) for performance-critical systems.
- **ECS-ready**: Transitioning towards a Sparse-Set Entity Component System (ECS).

### Rendering (Vulkan)
- **Modern Vulkan Backend**: Utilizes Dynamic Rendering, Synchronization 2, and Timeline Semaphores.
- **PBR Pipeline**: Physically Based Rendering with Image-Based Lighting (IBL) support.
- **Mesh Shaders**: Support for modern GPU pipelines (where available).
- **Bindless Resources**: Bindless texture support via `VK_EXT_descriptor_buffer`.
- **Render Graph**: Frame graph architecture for automatic resource barrier management.

### Editor & Tools
- **Integrated Editor**: Built with **ImGui** (Docking enabled).
- **Asset Management**: Unified asset system for Textures, Meshes, and Materials.
- **Scene Hierarchy**: Tree-based scene graph with Inspector support.
- **Gizmos**: Visual manipulation tools for scene objects.

### Dependencies
The engine manages its C/C++ dependencies directly via `build.zig`:
- **GLFW**: Windowing and Input.
- **ImGui**: Immediate Mode GUI.
- **cgltf**: glTF 2.0 asset loading.
- **stb_image**: Image loading.
- **tinyexr**: HDR image loading.
- **Vulkan SDK**: Required for rendering.

## Getting Started

### Prerequisites
- **Zig Compiler**: Version 0.15.2 or later.
- **Vulkan SDK**: Latest version installed and `VULKAN_SDK` environment variable set.
- **Git**: For cloning the repository.

### Build & Run

1.  **Clone the repository**
    ```bash
    git clone https://github.com/yourusername/Cardinal.git
    cd Cardinal
    ```

2.  **Run the Editor**
    ```bash
    zig build run-editor
    ```

3.  **Run the Client (Game)**
    ```bash
    zig build run-client
    ```

### Project Structure
```
Cardinal/
├── engine/           # Core Engine Code (Zig)
│   ├── src/
│   │   ├── core/     # Memory, Jobs, Math, Logging
│   │   ├── renderer/ # Vulkan Backend, Pipelines, Render Graph
│   │   ├── assets/   # Asset Manager, Loaders
│   │   └── rhi/      # Render Hardware Interface
├── editor/           # Editor Application (Zig + ImGui)
├── client/           # Runtime Game Application
├── libs/             # Third-party C/C++ libraries (GLFW, ImGui, etc.)
└── assets/           # Shaders, Textures, Models
```

## Roadmap
See [TODO.md](TODO.md) for the detailed technical roadmap, including:
- Render Graph 2.0 (Transient Resources, Async Compute)
- Data-Driven Pipelines
- Physics & Audio Integration
- Scripting Layer (Lua/C#)

## Contributing
Contributions are welcome! Please read the roadmap and open an issue or PR for any improvements.