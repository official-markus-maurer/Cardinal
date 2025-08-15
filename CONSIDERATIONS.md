# Considerations

## TODO Items Sorted by Severity 
- Add UV & Wireframe rendering mode.

### **CRITICAL** - Stability & Correctness Issues
- **Memory Leak in Dynamic Allocator**: MSVC version uses `_aligned_free()` for all pointers, even those allocated with `malloc()` (memory.c:90-96). This causes undefined behavior and potential crashes.
- **Missing Memory Size Tracking**: Tracked allocator cannot accurately update stats on `free()` calls because it doesn't know the allocation size (memory.c:151-156). This leads to inaccurate memory statistics.
- **Vulkan Resource Management**: Fix temporary culling disable in renderer (vulkan_pbr.c:816, vulkan_pipeline.c:299)
- **Error Handling**: Ensure all resources properly cleaned up to prevent leaks (vulkan_renderer.c:195)
- **Thread Safety**: Ensure thread-safe destruction across the codebase (window.c:126, vulkan_commands.c:97, vulkan_pipeline.c:397, log.c:141)
- **Error Recovery**: Add error checking for degenerate cases and improve error handling (vulkan_renderer.c:281, editor_layer.cpp:319, gltf_loader.c:292)
- **Resource Validation**: Add checks for valid resource handles before destruction (vulkan_pipeline.c:145)
- **Potential Double-Free**: Multiple locations allocate and free arrays without proper null checks, risking double-free errors (vulkan_pbr.c:795-797, vulkan_commands.c:128-132)

### **HIGH** - Performance & Memory Issues  
- **Memory Management**: Cache memory properties for performance (vulkan_pbr.c:14, 23)
- **Async Loading**: Implement asynchronous loading to prevent UI blocking (assets/loader.c:43, texture_loader.c:69, editor_layer.cpp:89, vulkan_pbr.c:84, 99)
- **Buffer Optimization**: Optimize buffer uploads using staging buffers and transfers (vulkan_renderer.c:492)
- **Synchronization**: Optimize synchronization to reduce CPU-GPU stalls (vulkan_renderer.c:80)
- **Reference Counting**: Implement reference counting for shared resources (vulkan_renderer.c:177, texture_loader.c:68, 76, gltf_loader.c:97)
- **Memory Allocators**: Add support for Vulkan memory allocator extensions (vulkan_pbr.c:961, 969)
- **Memory Tracking**: Implement header-based tracked allocations so frees update stats precisely (engine/src/core/memory.c, engine/include/cardinal/core/memory.h)
- **Allocator Adoption**: Sweep the codebase to replace malloc/calloc/realloc/free with category-tagged allocators/macros, starting with assets and renderer paths (engine/src/assets/*, engine/src/renderer/*)
- **Diagnostics**: Add a quick logger function to dump memory stats to the console at runtime

### **MEDIUM** - Features & Functionality
- **Multi-threading**: Add support for multi-threaded command buffer allocation (vulkan_commands.c:14)
- **Secondary Command Buffers**: Implement secondary command buffers for better parallelism (vulkan_commands.c:126, vulkan_renderer.c:456)
- **Shader Caching**: Implement shader caching to avoid repeated loading (vulkan_pipeline.c:17, vulkan_pbr.c:620, 628)
- **Pipeline Caching**: Implement pipeline caching for faster recreation (vulkan_pipeline.c:169)
- **Multiple Render Passes**: Support multiple render passes for advanced rendering techniques (vulkan_pipeline.c:168)
- **Scene Hierarchy**: Support scene hierarchy and node transformations (scene.c:11, editor_layer.cpp:413)
- **Asset Management**: Add asset import, preview thumbnails, and management features (editor_layer.cpp:446, 447)

### **MEDIUM-LOW** - Quality of Life & Usability
- **Command Line**: Implement advanced command-line parsing and configuration files (client/main.c:27, 28, editor/main.c:15)
- **UI Improvements**: Add customizable themes, better accessibility, and configurable key bindings (editor_layer.cpp:119, 120, 220)
- **Input Handling**: Improve input system with gamepad support and smooth controls (editor_layer.cpp:222, 221, window.c:89)
- **Asset Browser**: Support subdirectories, file icons, search and filtering (editor_layer.cpp:132, 133, 134)
- **Drag & Drop**: Implement drag-and-drop for hierarchy and scene manipulation (editor_layer.cpp:411, 448)
- **Progress Reporting**: Add progress reporting during loading operations (editor_layer.cpp:90)

### **LOW** - Nice-to-Have Extensions
- **Advanced Rendering**: Implement multi-pass rendering, instanced rendering, IBL (vulkan_pbr.c:1084, 1085, 1152)
- **Format Support**: Add support for more file formats (loader.c:42, texture_loader.c:26, gltf_loader.c:86)
- **Ray Tracing**: Investigate ray tracing extensions for advanced rendering (vulkan_renderer.c:36)
- **Multiple Cameras**: Support multiple cameras/viewports (vulkan_renderer.c:316)
- **Animation Support**: Support glTF animations, skins, and nodes hierarchy (gltf_loader.c:251, 291)
- **Cross-platform**: Add macOS compatibility and cross-platform improvements (vulkan_instance.h:14, editor/main.c:31)
- **HDR Support**: Add support for HDR formats and variable refresh rates (vulkan_swapchain.c:15, 31)
- **Documentation**: Document ImGui setup and Vulkan integration details (editor_layer.h:21)

---

## Current Implementation Notes

*SPDLOG*
- Add a CMake option to toggle spdlog (e.g., CARDINAL_USE_SPDLOG=ON/OFF) for consumers who want a pure-C link without C++ runtime.
- Use rotating_file_sink or daily_file_sink for better log management.
- Enable spdlog async mode for even lower overhead on hot paths.
- Expose a runtime hook to add/remove sinks or change patterns.

*Other*
- Create a Clang.Tidy format that enforces clean code.