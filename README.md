# Cardinal Vulkan Game Engine

A minimalistic Vulkan game engine written in pure C23, designed with a clean separation between an editor and client applications.

## Features

- **Pure C23**: Uses the latest C standard for modern language features
- **Vulkan Renderer**: Hardware-accelerated graphics using Vulkan API
- **GLFW Windowing**: Cross-platform window management
- **Editor/Client Split**: Separate applications for development and runtime
- **ImGui Editor**: Future-ready editor using Dear ImGui through cimgui
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
- **Vulkan Renderer**: Minimal Vulkan implementation with:
  - Instance and device creation
  - Surface management via GLFW
  - Swapchain setup
  - Command buffer recording
  - Basic clear-color rendering

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
    CardinalRenderer renderer;
    cardinal_renderer_create(&renderer, window);
    
    // Main loop
    while (!cardinal_window_should_close(window)) {
        cardinal_window_poll(window);
        cardinal_renderer_draw_frame(&renderer);
    }
    
    // Cleanup
    cardinal_renderer_destroy(&renderer);
    cardinal_window_destroy(window);
    return 0;
}
```

### Editor Application

Currently provides the same basic functionality as the client. Future versions will include:

- Scene editing
- Asset management
- Visual scripting
- Debugging tools

## Dependencies

All dependencies are managed via CMake FetchContent:

- **GLFW 3.4**: Window management and input
- **Vulkan Headers**: Via system Vulkan SDK
- **cimgui**: C bindings for Dear ImGui (editor only)
- **Dear ImGui**: UI framework backends (editor only)

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