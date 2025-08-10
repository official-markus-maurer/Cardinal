cmake_minimum_required(VERSION 3.28)
project(Cardinal VERSION 1.0.0 LANGUAGES C CXX)

# Set C standard to C23 (newest C spec)
set(CMAKE_C_STANDARD 23)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

# Set C++ standard for ImGui backends
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Export compile commands for tooling
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Build configuration
set(CMAKE_CONFIGURATION_TYPES "Debug;Release;RelWithDebInfo" CACHE STRING "" FORCE)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Debug" CACHE STRING "Choose the type of build." FORCE)
endif()

# Compiler flags
if(MSVC)
    add_compile_options(/W4 /permissive-)
    add_compile_definitions(_CRT_SECURE_NO_WARNINGS)
else()
    add_compile_options(-Wall -Wextra -Wpedantic)
endif()

# Include FetchContent for dependency management
include(FetchContent)

# Find Vulkan
find_package(Vulkan REQUIRED COMPONENTS glslc)

# Fetch GLFW
FetchContent_Declare(
    glfw
    GIT_REPOSITORY https://github.com/glfw/glfw.git
    GIT_TAG 3.4
)

# Configure GLFW options
set(GLFW_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(GLFW_INSTALL OFF CACHE BOOL "" FORCE)
set(GLFW_VULKAN_STATIC OFF CACHE BOOL "" FORCE)

# Make dependencies available
FetchContent_MakeAvailable(glfw)

# Engine library
add_subdirectory(engine)

# Editor application
add_subdirectory(editor)

# Client application
add_subdirectory(client)

# Copy compile_commands.json to root for language servers
if(CMAKE_EXPORT_COMPILE_COMMANDS)
    add_custom_target(copy_compile_commands ALL
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_BINARY_DIR}/compile_commands.json
        ${CMAKE_SOURCE_DIR}/compile_commands.json
        DEPENDS ${CMAKE_BINARY_DIR}/compile_commands.json
    )
endif()