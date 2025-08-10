# Cardinal Editor Application
add_executable(CardinalEditor
    src/main.c
    src/editor_layer.c
)

# Fetch cimgui specifically for editor
include(FetchContent)

FetchContent_Declare(
    cimgui
    GIT_REPOSITORY https://github.com/cimgui/cimgui.git
    GIT_TAG master
)

set(IMGUI_STATIC ON CACHE BOOL "" FORCE)
set(IMGUI_FREETYPE OFF CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(cimgui)

# Create an object library for backends compiled as C++ (use the same imgui as used by cimgui to avoid ABI mismatch)
add_library(imgui_backends OBJECT
    ${cimgui_SOURCE_DIR}/imgui/backends/imgui_impl_vulkan.cpp
    ${cimgui_SOURCE_DIR}/imgui/backends/imgui_impl_glfw.cpp
)

# Ensure includes for backends
get_target_property(VULKAN_INCLUDE_DIRS Vulkan::Vulkan INTERFACE_INCLUDE_DIRECTORIES)
if(VULKAN_INCLUDE_DIRS)
    target_include_directories(imgui_backends PUBLIC ${VULKAN_INCLUDE_DIRS})
endif()
get_target_property(GLFW_INCLUDE_DIRS glfw INTERFACE_INCLUDE_DIRECTORIES)
if(GLFW_INCLUDE_DIRS)
    target_include_directories(imgui_backends PUBLIC ${GLFW_INCLUDE_DIRS})
endif()

target_include_directories(imgui_backends PUBLIC ${cimgui_SOURCE_DIR}/imgui ${cimgui_SOURCE_DIR}/imgui/backends)

# Link editor
target_link_libraries(CardinalEditor PRIVATE cardinal_engine Vulkan::Vulkan glfw cimgui $<TARGET_OBJECTS:imgui_backends>)

# Ensure the editor links C++ runtime when consuming C++ objects
set_property(TARGET CardinalEditor PROPERTY LINKER_LANGUAGE CXX)

target_include_directories(CardinalEditor PRIVATE ${cimgui_SOURCE_DIR} ${cimgui_SOURCE_DIR}/imgui ${cimgui_SOURCE_DIR}/imgui/backends)

target_compile_definitions(CardinalEditor PRIVATE
    CIMGUI_DEFINE_ENUMS_AND_STRUCTS
    GLFW_INCLUDE_VULKAN
    IMGUI_DISABLE_OBSOLETE_FUNCTIONS
)

if(MSVC)
    target_compile_options(CardinalEditor PRIVATE /W4)
else()
    target_compile_options(CardinalEditor PRIVATE -Wall -Wextra -Wpedantic)
endif()