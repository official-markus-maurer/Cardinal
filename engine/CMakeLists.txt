# Cardinal Engine Library
add_library(cardinal_engine STATIC)

# Bring in FetchContent (top-level may have included it already, but include is idempotent)
include(FetchContent)

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

# Fetch spdlog for advanced logging (header-only)
FetchContent_Declare(
    spdlog
    GIT_REPOSITORY https://github.com/gabime/spdlog.git
    GIT_TAG v1.15.3
)
FetchContent_MakeAvailable(spdlog)
# Suppress specific Clang warning from spdlog internals on Windows
if(TARGET spdlog)
    if(WIN32 AND CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        target_compile_options(spdlog PRIVATE -Wno-language-extension-token)
    endif()
endif()

# Suppress warnings from cgltf on Windows
if(WIN32 AND TARGET cgltf)
    target_compile_definitions(cgltf INTERFACE _CRT_SECURE_NO_WARNINGS)
endif()

# Engine source files (minimal)
target_sources(cardinal_engine PRIVATE
    src/core/log.c
    src/core/window.c
    src/renderer/vulkan_renderer.c
    src/renderer/vulkan_instance.c
    src/renderer/vulkan_swapchain.c
    src/renderer/vulkan_pipeline.c
    src/renderer/vulkan_commands.c
    src/renderer/vulkan_pbr.c
    src/assets/scene.c
    src/assets/gltf_loader.c
    src/assets/loader.c
    src/assets/texture_loader.c
)
# Compile log.c as C++ to enable spdlog backend
set_source_files_properties(src/core/log.c PROPERTIES LANGUAGE CXX)

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
    # stb header-only include directory (contains stb_image.h)
    ${stb_SOURCE_DIR}
    PRIVATE
    src
)

# Suppress deprecation warnings from cgltf library on Windows
if(WIN32)
    target_compile_definitions(cardinal_engine PRIVATE _CRT_SECURE_NO_WARNINGS)
    # Also suppress specific clang warnings for cgltf
    if(CMAKE_C_COMPILER_ID MATCHES "Clang")
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
    spdlog::spdlog_header_only
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