# Cardinal Engine Library
add_library(cardinal_engine STATIC)

# Engine source files (minimal)
target_sources(cardinal_engine PRIVATE
    src/core/window.c
    src/renderer/vulkan_renderer.c
)

# Public headers
target_sources(cardinal_engine PUBLIC
    FILE_SET HEADERS
    BASE_DIRS include
    FILES
    include/cardinal/core/window.h
    include/cardinal/renderer/renderer.h
    include/cardinal/cardinal.h
)

# Include directories
target_include_directories(cardinal_engine
    PUBLIC
    include
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