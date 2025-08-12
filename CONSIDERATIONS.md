*SPDLOG*
- Add a CMake option to toggle spdlog (e.g., CARDINAL_USE_SPDLOG=ON/OFF) for consumers who want a pure-C link without C++ runtime.
- Use rotating_file_sink or daily_file_sink for better log management.
- Enable spdlog async mode for even lower overhead on hot paths.
- Integrate VK_EXT_debug_utils so Vulkan validation layer messages are forwarded through the logger.
- Expose a runtime hook to add/remove sinks or change patterns.