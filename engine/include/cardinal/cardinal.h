/**
 * @file cardinal.h
 * @brief Cardinal Engine Main Header
 * 
 * This is the main include file for the Cardinal Engine. Include this file
 * to access all core engine functionality including rendering, memory management,
 * asset loading, and window management.
 * 
 * @mainpage Cardinal Engine Documentation
 * 
 * Cardinal Engine is a modern 3D graphics engine built with Vulkan.
 * It provides a comprehensive set of tools for creating high-performance
 * 3D applications and games.
 * 
 * ## Key Features
 * - Vulkan-based rendering pipeline
 * - Advanced memory management system
 * - GLTF asset loading support
 * - Cross-platform window management
 * - PBR (Physically Based Rendering) materials
 * - Texture transform support
 * 
 * ## Getting Started
 * 
 * To use Cardinal Engine in your project:
 * 
 * ```c
 * #include <cardinal/cardinal.h>
 * 
 * int main() {
 *     // Initialize engine systems
 *     cardinal_memory_init(1024 * 1024); // 1MB linear allocator
 *     
 *     // Create window and renderer
 *     // ... your application code ...
 *     
 *     // Cleanup
 *     cardinal_memory_shutdown();
 *     return 0;
 * }
 * ```
 * 
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef CARDINAL_CARDINAL_H
#define CARDINAL_CARDINAL_H

#include "cardinal/core/window.h"      /**< Window management */
#include "cardinal/core/memory.h"      /**< Memory management system */
#include "cardinal/renderer/renderer.h" /**< Vulkan rendering pipeline */
#include "cardinal/assets/scene.h"     /**< Scene management */
#include "cardinal/assets/loader.h"    /**< Asset loading utilities */

#endif // CARDINAL_CARDINAL_H
