#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

// cgltf is header-only; include path supplied by CMake
#define CGLTF_IMPLEMENTATION
#include "cgltf.h"

#include "cardinal/assets/gltf_loader.h"
#include "cardinal/core/log.h"

static void compute_default_normal(float* nx, float* ny, float* nz) {
    // Fallback normal if none provided
    *nx = 0.0f; *ny = 1.0f; *nz = 0.0f;
}

bool cardinal_gltf_load_scene(const char* path, CardinalScene* out_scene) {
    if (!path || !out_scene) {
        LOG_ERROR("Invalid parameters: path=%p, out_scene=%p", (void*)path, (void*)out_scene);
        return false;
    }

    LOG_INFO("Starting GLTF scene loading: %s", path);
    memset(out_scene, 0, sizeof(*out_scene));

    cgltf_options options = {0};
    cgltf_data* data = NULL;

    LOG_DEBUG("Parsing GLTF file...");
    cgltf_result result = cgltf_parse_file(&options, path, &data);
    if (result != cgltf_result_success) {
        LOG_ERROR("cgltf_parse_file failed: %d for %s", (int)result, path);
        return false;
    }
    LOG_DEBUG("GLTF file parsed successfully");

    LOG_DEBUG("Loading GLTF buffers...");
    result = cgltf_load_buffers(&options, data, path);
    if (result != cgltf_result_success) {
        LOG_ERROR("cgltf_load_buffers failed: %d for %s", (int)result, path);
        cgltf_free(data);
        return false;
    }
    LOG_DEBUG("GLTF buffers loaded successfully");

    // Count total primitives as meshes for now
    LOG_DEBUG("Analyzing scene structure: %zu meshes found", (size_t)data->meshes_count);
    size_t mesh_count = 0;
    for (cgltf_size mi = 0; mi < data->meshes_count; ++mi) {
        const cgltf_mesh* m = &data->meshes[mi];
        mesh_count += (size_t)m->primitives_count;
        LOG_TRACE("Mesh %zu: %zu primitives", (size_t)mi, (size_t)m->primitives_count);
    }
    LOG_INFO("Total primitives to load: %zu", mesh_count);

    if (mesh_count == 0) {
        LOG_WARN("Scene contains no meshes, returning empty scene");
        cgltf_free(data);
        return true; // empty scene
    }

    LOG_DEBUG("Allocating memory for %zu meshes", mesh_count);
    CardinalMesh* meshes = (CardinalMesh*)calloc(mesh_count, sizeof(CardinalMesh));
    if (!meshes) {
        LOG_ERROR("Failed to allocate memory for %zu meshes", mesh_count);
        cgltf_free(data);
        return false;
    }

    LOG_DEBUG("Processing mesh data...");
    size_t mesh_write = 0;
    for (cgltf_size mi = 0; mi < data->meshes_count; ++mi) {
        const cgltf_mesh* m = &data->meshes[mi];
        LOG_DEBUG("Processing mesh %zu/%zu with %zu primitives", (size_t)mi + 1, (size_t)data->meshes_count, (size_t)m->primitives_count);
        
        for (cgltf_size pi = 0; pi < m->primitives_count; ++pi) {
            const cgltf_primitive* p = &m->primitives[pi];
            LOG_TRACE("Processing primitive %zu/%zu", (size_t)pi + 1, (size_t)m->primitives_count);

            // Determine vertex count from POSITION accessor
            const cgltf_accessor* pos_acc = NULL;
            const cgltf_accessor* nrm_acc = NULL;
            const cgltf_accessor* uv_acc = NULL;
            for (cgltf_size ai = 0; ai < p->attributes_count; ++ai) {
                const cgltf_attribute* a = &p->attributes[ai];
                if (a->type == cgltf_attribute_type_position) pos_acc = a->data;
                if (a->type == cgltf_attribute_type_normal) nrm_acc = a->data;
                if (a->type == cgltf_attribute_type_texcoord) uv_acc = a->data;
            }

            if (!pos_acc) {
                LOG_WARN("Skipping primitive %zu/%zu: no position data", (size_t)pi + 1, (size_t)m->primitives_count);
                continue;
            }
            cgltf_size vcount = pos_acc->count;
            LOG_TRACE("Primitive has %zu vertices, normals=%s, UVs=%s", 
                     (size_t)vcount, 
                     nrm_acc ? "yes" : "no", 
                     uv_acc ? "yes" : "no");

            CardinalVertex* vertices = (CardinalVertex*)calloc(vcount, sizeof(CardinalVertex));
            if (!vertices) {
                LOG_ERROR("Failed to allocate memory for %zu vertices", (size_t)vcount);
                continue;
            }
            LOG_TRACE("Allocated vertex buffer for %zu vertices", (size_t)vcount);

            // Read positions
            LOG_TRACE("Reading position data...");
            for (cgltf_size vi = 0; vi < vcount; ++vi) {
                cgltf_float v[3] = {0};
                cgltf_accessor_read_float(pos_acc, vi, v, 3);
                vertices[vi].px = (float)v[0];
                vertices[vi].py = (float)v[1];
                vertices[vi].pz = (float)v[2];
            }

            // Read normals
            if (nrm_acc) {
                LOG_TRACE("Reading normal data...");
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    cgltf_float v[3] = {0};
                    cgltf_accessor_read_float(nrm_acc, vi, v, 3);
                    vertices[vi].nx = (float)v[0];
                    vertices[vi].ny = (float)v[1];
                    vertices[vi].nz = (float)v[2];
                }
            } else {
                LOG_TRACE("Generating default normals...");
                float nx, ny, nz;
                compute_default_normal(&nx, &ny, &nz);
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    vertices[vi].nx = nx; vertices[vi].ny = ny; vertices[vi].nz = nz;
                }
            }

            // Read UVs
            if (uv_acc) {
                LOG_TRACE("Reading UV coordinate data...");
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    cgltf_float v[2] = {0};
                    cgltf_accessor_read_float(uv_acc, vi, v, 2);
                    vertices[vi].u = (float)v[0];
                    vertices[vi].v = (float)v[1];
                }
            } else {
                LOG_TRACE("Setting default UV coordinates...");
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    vertices[vi].u = 0.0f; vertices[vi].v = 0.0f;
                }
            }

            // Indices
            uint32_t* indices = NULL;
            uint32_t index_count = 0;
            if (p->indices) {
                index_count = (uint32_t)p->indices->count;
                LOG_TRACE("Reading %u indices...", index_count);
                indices = (uint32_t*)malloc(sizeof(uint32_t) * index_count);
                if (indices) {
                    for (cgltf_size ii = 0; ii < p->indices->count; ++ii) {
                        cgltf_uint idx = 0;
                        cgltf_accessor_read_uint(p->indices, ii, &idx, 1);
                        indices[ii] = (uint32_t)idx;
                    }
                    LOG_TRACE("Successfully read %u indices", index_count);
                } else {
                    LOG_ERROR("Failed to allocate memory for %u indices", index_count);
                    index_count = 0;
                }
            } else {
                // Generate a linear index buffer if the primitive is triangles and no indices given
                if (p->type == cgltf_primitive_type_triangles) {
                    index_count = (uint32_t)vcount;
                    LOG_TRACE("Generating linear index buffer with %u indices", index_count);
                    indices = (uint32_t*)malloc(sizeof(uint32_t) * index_count);
                    if (indices) {
                        for (uint32_t ii = 0; ii < index_count; ++ii) indices[ii] = ii;
                        LOG_TRACE("Generated linear index buffer successfully");
                    } else {
                        LOG_ERROR("Failed to allocate memory for generated %u indices", index_count);
                        index_count = 0;
                    }
                } else {
                    LOG_TRACE("No indices provided and primitive type is not triangles, using unindexed rendering");
                }
            }

            CardinalMesh* dst = &meshes[mesh_write++];
            dst->vertices = vertices;
            dst->vertex_count = (uint32_t)vcount;
            dst->indices = indices;
            dst->index_count = index_count;
            
            LOG_TRACE("Mesh %zu complete: %u vertices, %u indices", mesh_write, dst->vertex_count, dst->index_count);
        }
    }

    cgltf_free(data);
    LOG_DEBUG("GLTF data structures freed");

    out_scene->meshes = meshes;
    out_scene->mesh_count = (uint32_t)mesh_write; // Use actual written count
    
    LOG_INFO("GLTF scene loading completed successfully: %u meshes loaded from %s", out_scene->mesh_count, path);
    return true;
}
