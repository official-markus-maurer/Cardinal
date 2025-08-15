/**
 * @file loader.h
 * @brief Asset loading utilities for Cardinal Engine
 * 
 * This module provides high-level asset loading functionality that automatically
 * detects file formats and delegates to appropriate specialized loaders. Currently
 * supports glTF 2.0 format (.gltf and .glb files) with plans for additional formats.
 * 
 * The loader handles:
 * - Automatic format detection based on file extension
 * - Memory management for loaded assets
 * - Texture loading and processing
 * - Material property extraction
 * - Mesh data conversion to engine format
 * 
 * @author Markus Maurer
 * @version 1.0
 */

#ifndef CARDINAL_ASSETS_LOADER_H
#define CARDINAL_ASSETS_LOADER_H

#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#include "cardinal/assets/scene.h"

/**
 * @brief Load a 3D scene from file
 * 
 * Automatically detects the file format based on the file extension and
 * loads the scene using the appropriate loader. The loaded scene data is
 * converted to Cardinal Engine's internal format for efficient rendering.
 * 
 * Currently supported formats:
 * - glTF 2.0 (.gltf) - Text-based glTF files
 * - glTF Binary (.glb) - Binary glTF files
 * 
 * The function handles:
 * - Mesh geometry loading and conversion
 * - Material property extraction (PBR parameters)
 * - Texture loading with automatic format detection
 * - Scene hierarchy and transformations
 * - Texture coordinate transformations (KHR_texture_transform)
 * 
 * @param filepath Path to the scene file to load
 * @param out_scene Pointer to scene structure to populate with loaded data
 * @return true if the scene was loaded successfully, false on error
 * 
 * @note The caller is responsible for calling cardinal_scene_destroy() on
 *       the loaded scene when it's no longer needed
 * @note Textures are loaded with vertical flipping to match Vulkan's coordinate system
 * 
 * @see cardinal_scene_destroy()
 */
bool cardinal_scene_load(const char* filepath, CardinalScene* out_scene);

#ifdef __cplusplus
}
#endif

#endif // CARDINAL_ASSETS_LOADER_H
