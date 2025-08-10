# Cardinal Editor Application
add_executable(CardinalEditor
    src/main.c
    src/editor_layer.cpp
)

# Fetch Dear ImGui directly
include(FetchContent)

FetchContent_Declare(
    imgui
    GIT_REPOSITORY https://github.com/ocornut/imgui.git
    GIT_TAG docking
)

FetchContent_MakeAvailable(imgui)

# Create ImGui library
add_library(imgui_lib STATIC
    ${imgui_SOURCE_DIR}/imgui.cpp
    ${imgui_SOURCE_DIR}/imgui_demo.cpp
    ${imgui_SOURCE_DIR}/imgui_draw.cpp
    ${imgui_SOURCE_DIR}/imgui_tables.cpp
    ${imgui_SOURCE_DIR}/imgui_widgets.cpp
    ${imgui_SOURCE_DIR}/backends/imgui_impl_vulkan.cpp
    ${imgui_SOURCE_DIR}/backends/imgui_impl_glfw.cpp
)

target_include_directories(imgui_lib PUBLIC 
    ${imgui_SOURCE_DIR}
    ${imgui_SOURCE_DIR}/backends
)

# Ensure imgui library uses same compile-time options as the app to avoid struct layout mismatch
# Keep these in PUBLIC so consumers inherit identical flags
target_compile_definitions(imgui_lib PUBLIC
    IMGUI_DISABLE_OBSOLETE_FUNCTIONS
    IMGUI_ENABLE_DOCKING
)

# Ensure includes for backends
get_target_property(VULKAN_INCLUDE_DIRS Vulkan::Vulkan INTERFACE_INCLUDE_DIRECTORIES)
if(VULKAN_INCLUDE_DIRS)
    target_include_directories(imgui_lib PUBLIC ${VULKAN_INCLUDE_DIRS})
endif()
get_target_property(GLFW_INCLUDE_DIRS glfw INTERFACE_INCLUDE_DIRECTORIES)
if(GLFW_INCLUDE_DIRS)
    target_include_directories(imgui_lib PUBLIC ${GLFW_INCLUDE_DIRS})
endif()

# Link editor
target_link_libraries(CardinalEditor PRIVATE cardinal_engine Vulkan::Vulkan glfw imgui_lib)

# Ensure the editor links C++ runtime
set_property(TARGET CardinalEditor PROPERTY LINKER_LANGUAGE CXX)

# Include dirs
target_include_directories(CardinalEditor PRIVATE 
    include
    ${imgui_SOURCE_DIR}
    ${imgui_SOURCE_DIR}/backends
)

# Definitions for ImGui usage (should match imgui_lib above)
target_compile_definitions(CardinalEditor PRIVATE
    GLFW_INCLUDE_VULKAN
    IMGUI_DISABLE_OBSOLETE_FUNCTIONS
    IMGUI_ENABLE_DOCKING
)

if(MSVC)
    target_compile_options(CardinalEditor PRIVATE /W4)
else()
    target_compile_options(CardinalEditor PRIVATE -Wall -Wextra -Wpedantic)
endif()