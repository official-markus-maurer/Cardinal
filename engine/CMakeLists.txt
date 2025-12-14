cmake_minimum_required(VERSION 3.16)
project(CardinalEngine)

# Find required packages
find_package(Vulkan REQUIRED)

# Cardinal Engine Library
add_library(cardinal_engine STATIC)

# Bring in FetchContent (top-level may have included it already, but include is idempotent)
include(FetchContent)

# Option: enable Vulkan validation layers in any build (can override via -DCARDINAL_ENABLE_VK_VALIDATION=ON)
option(CARDINAL_ENABLE_VK_VALIDATION "Enable Vulkan validation layers and debug utils" OFF)

# Option: enable spdlog for advanced logging (can override via -DCARDINAL_USE_SPDLOG=OFF for pure-C builds)
option(CARDINAL_USE_SPDLOG "Enable spdlog for advanced logging features" ON)

# Fetch cgltf (header-only)
FetchContent_Declare(
    cgltf
    GIT_REPOSITORY https://github.com/jkuhlmann/cgltf.git
    GIT_TAG v1.15
)
FetchContent_MakeAvailable(cgltf)

# Fetch stb (header-only)
FetchContent_Declare(
    stb
    GIT_REPOSITORY https://github.com/nothings/stb.git
    GIT_TAG master
)
FetchContent_MakeAvailable(stb)

# Fetch GLFW for window management
FetchContent_Declare(
    glfw
    GIT_REPOSITORY https://github.com/glfw/glfw.git
    GIT_TAG 3.4
)
set(GLFW_BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(glfw)

# Conditionally fetch spdlog for advanced logging (header-only)
if(CARDINAL_USE_SPDLOG)
    FetchContent_Declare(
        spdlog
        GIT_REPOSITORY https://github.com/gabime/spdlog.git
        GIT_TAG v1.16.0
    )
    FetchContent_MakeAvailable(spdlog)
    # Suppress specific Clang warning from spdlog internals on Windows
    if(TARGET spdlog)
        if(WIN32 AND CMAKE_CXX_COMPILER_ID MATCHES "Clang")
            target_compile_options(spdlog PRIVATE -Wno-language-extension-token)
        endif()
    endif()
endif()

# Suppress warnings from cgltf on Windows
if(WIN32 AND TARGET cgltf)
    target_compile_definitions(cgltf INTERFACE _CRT_SECURE_NO_WARNINGS)
    if(CMAKE_C_COMPILER_ID MATCHES "Clang")
        target_compile_options(cgltf INTERFACE -Wno-language-extension-token)
    endif()
endif()

# Engine source files (minimal)
target_sources(cardinal_engine PRIVATE
    src/core/log.c
    src/core/window.c
    src/core/memory.c
    src/core/resource_state.c
    src/core/transform.c
    src/core/animation.c
    src/renderer/vulkan_renderer.c
    src/renderer/vulkan_renderer_frame.c
    src/renderer/vulkan_instance.c
    src/renderer/vulkan_swapchain.c
    src/renderer/vulkan_pipeline.c
    src/renderer/vulkan_commands.c
    src/renderer/vulkan_mt.c
    src/renderer/vulkan_barrier_validation.c
    src/renderer/vulkan_pbr.c
    src/renderer/vulkan_simple_pipelines.c
    src/renderer/vulkan_mesh_shader.c
    src/renderer/vulkan_compute.c
    src/renderer/vulkan_descriptor_indexing.c
    src/renderer/vulkan_allocator.c
    src/renderer/vulkan_buffer_manager.c
    src/renderer/vulkan_descriptor_manager.c
    src/renderer/vulkan_swapchain_manager.c
    src/renderer/vulkan_pipeline_manager.c
    src/renderer/vulkan_resource_manager.c
    src/renderer/vulkan_sync_manager.c
    src/renderer/vulkan_timeline_debug.c
    src/renderer/vulkan_timeline_pool.c
    src/renderer/vulkan_texture_manager.c
    src/renderer/vulkan_utils.c
    src/renderer/vulkan_maintenance8_sync.c
    src/renderer/util/vulkan_buffer_utils.c
    src/renderer/util/vulkan_descriptor_utils.c
    src/renderer/util/vulkan_descriptor_buffer_utils.c
    src/renderer/util/vulkan_shader_utils.c
    src/renderer/util/vulkan_texture_utils.c
    src/assets/scene.c
    src/assets/gltf_loader.c
    src/assets/loader.c
    src/assets/texture_loader.c
    src/assets/mesh_loader.c
    src/assets/material_loader.c
    src/assets/model_manager.c
    src/core/ref_counting.c
    src/assets/material_ref_counting.c
    src/core/async_loader.c
)
# log.cpp is now properly a C++ file for spdlog backend

# Public headers
target_sources(cardinal_engine PUBLIC
    FILE_SET HEADERS
    BASE_DIRS include
    FILES
    include/cardinal/core/window.h
    include/cardinal/core/memory.h
    include/cardinal/core/async_loader.h
    include/cardinal/core/transform.h
    include/cardinal/core/animation.h
    include/cardinal/renderer/renderer.h
    include/cardinal/renderer/vulkan_utils.h
    include/cardinal/cardinal.h
    include/cardinal/assets/scene.h
    include/cardinal/assets/gltf_loader.h
    include/cardinal/assets/loader.h
    include/cardinal/assets/texture_loader.h
    include/cardinal/assets/mesh_loader.h
    include/cardinal/assets/material_loader.h
    include/cardinal/assets/model_manager.h
)

# Include directories
target_include_directories(cardinal_engine
    PUBLIC
    include
    # cgltf header-only include directory
    ${cgltf_SOURCE_DIR}
    # stb header-only include directory (contains stb_image.h)
    ${stb_SOURCE_DIR}
    PRIVATE
    src
)

# Suppress deprecation warnings from cgltf library on Windows
if(WIN32)
    target_compile_definitions(cardinal_engine PRIVATE _CRT_SECURE_NO_WARNINGS)
    # Also suppress specific clang warnings for cgltf and spdlog
    if(CMAKE_C_COMPILER_ID MATCHES "Clang" OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        target_compile_options(cardinal_engine PRIVATE 
            -Wno-deprecated-declarations
            -Wno-language-extension-token
        )
    endif()
endif()

# Link dependencies
target_link_libraries(cardinal_engine
    PUBLIC
    Vulkan::Vulkan
    glfw
)

# Conditionally link spdlog
if(CARDINAL_USE_SPDLOG)
    target_link_libraries(cardinal_engine PUBLIC spdlog::spdlog_header_only)
    target_compile_definitions(cardinal_engine PRIVATE CARDINAL_USE_SPDLOG=1)
endif()

# Compile definitions
target_compile_definitions(cardinal_engine
    PUBLIC
    GLFW_INCLUDE_VULKAN
    VK_USE_PLATFORM_WIN32_KHR
    PRIVATE
    CARDINAL_ENGINE_INTERNAL
)

# Propagate validation toggle when enabled
if(CARDINAL_ENABLE_VK_VALIDATION)
    target_compile_definitions(cardinal_engine PRIVATE CARDINAL_ENABLE_VK_VALIDATION=1)
endif()

# Compiler-specific options
if(MSVC)
    target_compile_options(cardinal_engine PRIVATE /W4 /experimental:c11atomics)
else()
    target_compile_options(cardinal_engine PRIVATE -Wall -Wextra -Wpedantic)
endif()


