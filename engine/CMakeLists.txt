# Cardinal Engine Library
add_library(cardinal_engine STATIC)

# Bring in FetchContent (top-level may have included it already, but include is idempotent)
include(FetchContent)

# Fetch cgltf (header-only)
FetchContent_Declare(
    cgltf
    GIT_REPOSITORY https://github.com/jkuhlmann/cgltf.git
    GIT_TAG v1.13
)
FetchContent_MakeAvailable(cgltf)

# Engine source files (minimal)
target_sources(cardinal_engine PRIVATE
    src/core/log.c
    src/core/window.c
    src/renderer/vulkan_renderer.c
    src/renderer/vulkan_instance.c
    src/renderer/vulkan_swapchain.c
    src/renderer/vulkan_pipeline.c
    src/renderer/vulkan_commands.c
    src/assets/scene.c
    src/assets/gltf_loader.c
    src/assets/loader.c
)

# Public headers
target_sources(cardinal_engine PUBLIC
    FILE_SET HEADERS
    BASE_DIRS include
    FILES
    include/cardinal/core/window.h
    include/cardinal/renderer/renderer.h
    include/cardinal/cardinal.h
    include/cardinal/assets/scene.h
    include/cardinal/assets/gltf_loader.h
    include/cardinal/assets/loader.h
)

# Include directories
target_include_directories(cardinal_engine
    PUBLIC
    include
    # cgltf header-only include directory
    ${cgltf_SOURCE_DIR}
    PRIVATE
    src
)

# Link dependencies
target_link_libraries(cardinal_engine
    PUBLIC
    Vulkan::Vulkan
    glfw
)

# Compile definitions
target_compile_definitions(cardinal_engine
    PUBLIC
    GLFW_INCLUDE_VULKAN
    VK_USE_PLATFORM_WIN32_KHR
    PRIVATE
    CARDINAL_ENGINE_INTERNAL
)

# Compiler-specific options
if(MSVC)
    target_compile_options(cardinal_engine PRIVATE /W4)
else()
    target_compile_options(cardinal_engine PRIVATE -Wall -Wextra -Wpedantic)
endif()