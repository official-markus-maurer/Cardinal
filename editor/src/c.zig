//! C imports for the editor.
//!
//! Centralizes third-party headers used by editor-only code.

/// Editor-facing C APIs (ImGui bridge, GLFW, Vulkan).
pub const c = @cImport({
    @cInclude("imgui_bridge.h");
    @cInclude("GLFW/glfw3.h");
    @cInclude("vulkan/vulkan.h");
});
