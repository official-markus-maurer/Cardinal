# Cardinal Vulkan Game Engine

A minimalistic Vulkan game engine written in pure C23, designed with a clean separation between an editor and client applications.

## Features

- **Pure C23**: Uses the latest C standard for modern language features
- **Vulkan Renderer**: Hardware-accelerated graphics using Vulkan API
- **GLFW Windowing**: Cross-platform window management
- **Editor/Client Split**: Separate applications for development and runtime
- **ImGui Editor**: Integrated editor using Dear ImGui with Vulkan backend
- **CMake Build System**: Modern dependency management with FetchContent

## Architecture

```
Cardinal/
├── engine/          # Core engine library (static)
│   ├── include/     # Public headers
│   └── src/         # Engine implementation
├── editor/          # Editor application
│   └── src/         # Editor-specific code
├── client/          # Client/runtime application
│   └── src/         # Client-specific code
└── CMakeLists.txt   # Root build configuration
```

### Engine Core

- **Window Management**: GLFW-based window creation and event handling
- **Vulkan Renderer**: Complete Vulkan implementation with:
  - Instance and device creation
  - Surface management via GLFW
  - Swapchain setup
  - Command buffer recording
  - PBR (Physically Based Rendering) pipeline
  - Scene rendering with mesh support
- **Asset Loading**: glTF 2.0 scene loading with cgltf
- **Scene Management**: Hierarchical scene graph with materials and textures

## Build Requirements

- **CMake 3.28+**
- **Vulkan SDK** (for headers and validation layers)
- **C23-compatible compiler**:
  - MSVC 2022 (17.0+)
  - GCC 13+ with `-std=c2x`
  - Clang 15+ with `-std=c2x`

## Building

```bash
# Configure
cmake -B build -S .

# Build
cmake --build build --config Debug

# Or for Release
cmake --build build --config Release
```

### Build Outputs

- `build/engine/libcardinal_engine.a` - Core engine library
- `build/client/CardinalClient.exe` - Runtime application
- `build/editor/CardinalEditor.exe` - Editor application

## Usage

### Client Application

The client demonstrates basic engine usage:

```c
#include <cardinal/cardinal.h>
#include <cardinal/assets/loader.h>

int main(void) {
    // Create window
    CardinalWindowConfig config = {
        .title = "My Game",
        .width = 1024,
        .height = 768,
        .resizable = true
    };
    CardinalWindow* window = cardinal_window_create(&config);
    
    // Create renderer
    CardinalRenderer* renderer = cardinal_renderer_create(window);
    
    // Load and upload scene (optional)
    CardinalScene scene;
    if (cardinal_scene_load("assets/models/scene.gltf", &scene)) {
        cardinal_renderer_upload_scene(renderer, &scene);
        
        // Enable PBR rendering
        cardinal_renderer_enable_pbr(renderer, true);
        
        // Set up camera and lighting
        CardinalCamera camera = {
            .position = {0.0f, 0.0f, 5.0f},
            .target = {0.0f, 0.0f, 0.0f},
            .up = {0.0f, 1.0f, 0.0f},
            .fov = 45.0f,
            .aspect = 1024.0f / 768.0f,
            .near_plane = 0.1f,
            .far_plane = 100.0f
        };
        cardinal_renderer_set_camera(renderer, &camera);
        
        CardinalLight light = {
            .direction = {-0.5f, -1.0f, -0.3f},
            .color = {1.0f, 1.0f, 1.0f},
            .intensity = 3.0f,
            .ambient = {0.1f, 0.1f, 0.1f}
        };
        cardinal_renderer_set_lighting(renderer, &light);
    }
    
    // Main loop
    while (!cardinal_window_should_close(window)) {
        cardinal_window_poll(window);
        cardinal_renderer_draw_frame(renderer);
    }
    
    // Cleanup
    if (scene.mesh_count > 0) {
        cardinal_scene_destroy(&scene);
    }
    cardinal_renderer_destroy(renderer);
    cardinal_window_destroy(window);
    return 0;
}
```

### Editor Application

Provides a comprehensive development environment with:

- **Scene Graph Panel**: Hierarchical view of loaded scenes
- **Asset Browser**: File system navigation and glTF asset loading
- **PBR Settings Panel**: Real-time camera and lighting controls
- **ImGui Integration**: Dockable interface with modern UI
- **Live Scene Loading**: Dynamic glTF/GLB file loading and rendering

## Dependencies

All dependencies are managed via CMake FetchContent:

- **GLFW 3.4**: Window management and input
- **Vulkan Headers**: Via system Vulkan SDK
- **Dear ImGui**: UI framework with Vulkan backend (editor only)
- **cgltf 1.13**: Header-only glTF 2.0 parser for asset loading

## Platform Support

- **Windows**: Primary development platform
- **Linux**: Planned
- **macOS**: Planned (via MoltenVK)

## Development

### Code Style

- C23 standard compliance
- Explicit struct initialization
- Consistent naming with `cardinal_` prefix
- Minimal dependencies
- Clear separation of concerns

### Project Goals

1. **Minimalism**: Keep the codebase small and focused
2. **Performance**: Leverage Vulkan for optimal graphics performance
3. **Modularity**: Clean separation between engine, editor, and client
4. **Modern C**: Utilize C23 features for better code quality

## License

MIT License - See LICENSE file for details.

## Contributing

Contributions welcome! Please follow the existing code style and ensure all changes maintain C23 compatibility.