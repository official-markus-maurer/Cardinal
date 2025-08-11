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

static int read_accessor_float3(const cgltf_accessor* acc, float* out, size_t max_count) {
    // Reads up to max_count vec3s from accessor into out (contiguous floats)
    if (!acc) return 0;
    cgltf_size count = acc->count;
    if (count > (cgltf_size)max_count) count = (cgltf_size)max_count;
    for (cgltf_size i = 0; i < count; ++i) {
        cgltf_float v[4] = {0};
        cgltf_size n = cgltf_accessor_read_float(acc, i, v, 4);
        if (n < 3) return (int)i;
        out[i * 3 + 0] = (float)v[0];
        out[i * 3 + 1] = (float)v[1];
        out[i * 3 + 2] = (float)v[2];
    }
    return (int)count;
}

static int read_accessor_float2(const cgltf_accessor* acc, float* out, size_t max_count) {
    if (!acc) return 0;
    cgltf_size count = acc->count;
    if (count > (cgltf_size)max_count) count = (cgltf_size)max_count;
    for (cgltf_size i = 0; i < count; ++i) {
        cgltf_float v[4] = {0};
        cgltf_size n = cgltf_accessor_read_float(acc, i, v, 4);
        if (n < 2) return (int)i;
        out[i * 2 + 0] = (float)v[0];
        out[i * 2 + 1] = (float)v[1];
    }
    return (int)count;
}

static int read_indices_u32(const cgltf_accessor* acc, uint32_t* out, size_t max_count) {
    if (!acc) return 0;
    cgltf_size count = acc->count;
    if (count > (cgltf_size)max_count) count = (cgltf_size)max_count;
    for (cgltf_size i = 0; i < count; ++i) {
        cgltf_uint v = 0;
        cgltf_size n = cgltf_accessor_read_uint(acc, i, &v, 1);
        if (n < 1) return (int)i;
        out[i] = (uint32_t)v;
    }
    return (int)count;
}

bool cardinal_gltf_load_scene(const char* path, CardinalScene* out_scene) {
    if (!path || !out_scene) return false;

    memset(out_scene, 0, sizeof(*out_scene));

    cgltf_options options = {0};
    cgltf_data* data = NULL;

    cgltf_result result = cgltf_parse_file(&options, path, &data);
    if (result != cgltf_result_success) {
        LOG_ERROR("cgltf_parse_file failed: %d for %s", (int)result, path);
        return false;
    }

    result = cgltf_load_buffers(&options, data, path);
    if (result != cgltf_result_success) {
        LOG_ERROR("cgltf_load_buffers failed: %d for %s", (int)result, path);
        cgltf_free(data);
        return false;
    }

    // Count total primitives as meshes for now
    size_t mesh_count = 0;
    for (cgltf_size mi = 0; mi < data->meshes_count; ++mi) {
        const cgltf_mesh* m = &data->meshes[mi];
        mesh_count += (size_t)m->primitives_count;
    }

    if (mesh_count == 0) {
        cgltf_free(data);
        return true; // empty scene
    }

    CardinalMesh* meshes = (CardinalMesh*)calloc(mesh_count, sizeof(CardinalMesh));
    if (!meshes) {
        cgltf_free(data);
        return false;
    }

    size_t mesh_write = 0;
    for (cgltf_size mi = 0; mi < data->meshes_count; ++mi) {
        const cgltf_mesh* m = &data->meshes[mi];
        for (cgltf_size pi = 0; pi < m->primitives_count; ++pi) {
            const cgltf_primitive* p = &m->primitives[pi];

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
                // Skip primitives without positions
                continue;
            }
            cgltf_size vcount = pos_acc->count;

            CardinalVertex* vertices = (CardinalVertex*)calloc(vcount, sizeof(CardinalVertex));
            if (!vertices) continue;

            // Read positions
            for (cgltf_size vi = 0; vi < vcount; ++vi) {
                cgltf_float v[3] = {0};
                cgltf_accessor_read_float(pos_acc, vi, v, 3);
                vertices[vi].px = (float)v[0];
                vertices[vi].py = (float)v[1];
                vertices[vi].pz = (float)v[2];
            }

            // Read normals
            if (nrm_acc) {
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    cgltf_float v[3] = {0};
                    cgltf_accessor_read_float(nrm_acc, vi, v, 3);
                    vertices[vi].nx = (float)v[0];
                    vertices[vi].ny = (float)v[1];
                    vertices[vi].nz = (float)v[2];
                }
            } else {
                float nx, ny, nz;
                compute_default_normal(&nx, &ny, &nz);
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    vertices[vi].nx = nx; vertices[vi].ny = ny; vertices[vi].nz = nz;
                }
            }

            // Read UVs
            if (uv_acc) {
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    cgltf_float v[2] = {0};
                    cgltf_accessor_read_float(uv_acc, vi, v, 2);
                    vertices[vi].u = (float)v[0];
                    vertices[vi].v = (float)v[1];
                }
            } else {
                for (cgltf_size vi = 0; vi < vcount; ++vi) {
                    vertices[vi].u = 0.0f; vertices[vi].v = 0.0f;
                }
            }

            // Indices
            uint32_t* indices = NULL;
            uint32_t index_count = 0;
            if (p->indices) {
                index_count = (uint32_t)p->indices->count;
                indices = (uint32_t*)malloc(sizeof(uint32_t) * index_count);
                if (indices) {
                    for (cgltf_size ii = 0; ii < p->indices->count; ++ii) {
                        cgltf_uint idx = 0;
                        cgltf_accessor_read_uint(p->indices, ii, &idx, 1);
                        indices[ii] = (uint32_t)idx;
                    }
                }
            } else {
                // Generate a linear index buffer if the primitive is triangles and no indices given
                if (p->type == cgltf_primitive_type_triangles) {
                    index_count = (uint32_t)vcount;
                    indices = (uint32_t*)malloc(sizeof(uint32_t) * index_count);
                    if (indices) {
                        for (uint32_t ii = 0; ii < index_count; ++ii) indices[ii] = ii;
                    }
                }
            }

            CardinalMesh* dst = &meshes[mesh_write++];
            dst->vertices = vertices;
            dst->vertex_count = (uint32_t)vcount;
            dst->indices = indices;
            dst->index_count = index_count;
        }
    }

    cgltf_free(data);

    out_scene->meshes = meshes;
    out_scene->mesh_count = (uint32_t)mesh_count;
    return true;
}