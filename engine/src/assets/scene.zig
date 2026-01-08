const std = @import("std");
const ref_counting = @import("../core/ref_counting.zig");
const memory = @import("../core/memory.zig");
const log = @import("../core/log.zig");
const transform_math = @import("../core/transform.zig");
const pool_alloc = @import("../core/pool_allocator.zig");
const handles = @import("../core/handles.zig");
const animation = @import("../core/animation.zig");

// --- Global Pool for Scene Nodes ---
var g_node_pool: ?pool_alloc.PoolAllocator(CardinalSceneNode) = null;
var g_pool_init_mutex: std.Thread.Mutex = .{};

fn get_node_pool() *pool_alloc.PoolAllocator(CardinalSceneNode) {
    if (g_node_pool) |*p| return p;

    g_pool_init_mutex.lock();
    defer g_pool_init_mutex.unlock();

    if (g_node_pool == null) {
        const allocator = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
        g_node_pool = pool_alloc.PoolAllocator(CardinalSceneNode).init(allocator);
    }
    return &g_node_pool.?;
}

// --- Common Enums ---

const g_identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

pub const CardinalSamplerWrap = enum(c_int) {
    REPEAT = 0,
    CLAMP_TO_EDGE = 1,
    MIRRORED_REPEAT = 2,
};

pub const CardinalSamplerFilter = enum(c_int) {
    NEAREST = 0,
    LINEAR = 1,
};

pub const CardinalAlphaMode = enum(c_int) {
    OPAQUE = 0,
    MASK = 1,
    BLEND = 2,
};

pub const CardinalLightType = enum(c_int) {
    DIRECTIONAL = 0,
    POINT = 1,
    SPOT = 2,
};

// --- Struct Definitions ---

pub const CardinalVertex = extern struct {
    px: f32,
    py: f32,
    pz: f32,
    nx: f32,
    ny: f32,
    nz: f32,
    u: f32,
    v: f32,
    u1: f32,
    v1: f32,
    bone_weights: [4]f32,
    bone_indices: [4]u32,
};

pub const CardinalTextureTransform = extern struct {
    offset: [2]f32,
    scale: [2]f32,
    rotation: f32,
};

pub const CardinalSampler = extern struct {
    mag_filter: c_int,
    min_filter: c_int,
    wrap_s: c_int,
    wrap_t: c_int,
};

pub const CardinalMaterial = extern struct {
    albedo_texture: handles.TextureHandle,
    normal_texture: handles.TextureHandle,
    metallic_roughness_texture: handles.TextureHandle,
    ao_texture: handles.TextureHandle,
    emissive_texture: handles.TextureHandle,

    albedo_factor: [3]f32,
    metallic_factor: f32,
    roughness_factor: f32,
    emissive_factor: [3]f32,
    normal_scale: f32,
    ao_strength: f32,

    alpha_mode: CardinalAlphaMode,
    alpha_cutoff: f32,
    double_sided: bool,
    uv_indices: [5]u8, // Albedo, Normal, MR, AO, Emissive

    albedo_transform: CardinalTextureTransform,
    normal_transform: CardinalTextureTransform,
    metallic_roughness_transform: CardinalTextureTransform,
    ao_transform: CardinalTextureTransform,
    emissive_transform: CardinalTextureTransform,
};

pub const CardinalLight = extern struct {
    color: [3]f32,
    intensity: f32,
    type: CardinalLightType,
    range: f32,
    inner_cone_angle: f32,
    outer_cone_angle: f32,
    node_index: u32, // Index of the node this light is attached to (for transform)
    _padding: u32,
};

pub const CardinalTexture = extern struct {
    data: ?[*]u8,
    width: u32,
    height: u32,
    channels: u32,
    sampler: CardinalSampler,
    path: ?[*:0]u8,
    ref_resource: ?*ref_counting.CardinalRefCountedResource,
    is_hdr: bool,
};

pub const CardinalMorphTarget = extern struct {
    positions: ?[*]f32, // vec3 * vertex_count
    normals: ?[*]f32, // vec3 * vertex_count
    tangents: ?[*]f32, // vec3 * vertex_count
};

pub const CardinalMesh = extern struct {
    vertices: ?[*]CardinalVertex,
    vertex_count: u32,
    indices: ?[*]u32,
    index_count: u32,
    material_index: u32,
    transform: [16]f32,
    visible: bool,
    morph_targets: ?[*]CardinalMorphTarget,
    morph_target_count: u32,
};

pub const CardinalSceneNode = extern struct {
    name: ?[*:0]u8,
    local_transform: [16]f32,
    world_transform: [16]f32,
    world_transform_dirty: bool,

    mesh_indices: ?[*]u32,
    mesh_count: u32,

    parent: ?*CardinalSceneNode,
    children: ?[*]?*CardinalSceneNode,
    child_count: u32,
    child_capacity: u32,

    is_bone: bool,
    bone_index: u32,
    skin_index: u32,

    light_index: i32, // -1 if no light
};

// Forward declaration for AnimationSystem and Skin (opaque for now)
pub const CardinalAnimationSystem = opaque {};
pub const CardinalSkin = opaque {};

pub const CardinalScene = extern struct {
    meshes: ?[*]CardinalMesh,
    mesh_count: u32,

    materials: ?[*]CardinalMaterial,
    material_count: u32,

    textures: ?[*]CardinalTexture,
    texture_count: u32,

    lights: ?[*]CardinalLight,
    light_count: u32,

    root_nodes: ?[*]?*CardinalSceneNode,
    root_node_count: u32,

    all_nodes: ?[*]?*CardinalSceneNode,
    all_node_count: u32,

    animation_system: ?*CardinalAnimationSystem,
    skins: ?*anyopaque,
    skin_count: u32,
};

// --- Functions ---

pub export fn cardinal_scene_node_create(name: ?[*:0]const u8) ?*CardinalSceneNode {
    const pool = get_node_pool();
    const node = pool.create() catch return null;
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    node.* = std.mem.zeroes(CardinalSceneNode);

    // Identity matrix
    const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    @memcpy(&node.local_transform, &identity);
    @memcpy(&node.world_transform, &identity);
    node.world_transform_dirty = false;
    node.light_index = -1;

    if (name) |n| {
        const len = std.mem.len(n);
        const name_ptr = memory.cardinal_alloc(allocator, len + 1);
        if (name_ptr) |np| {
            const name_slice = @as([*]u8, @ptrCast(np))[0 .. len + 1];
            @memcpy(name_slice[0..len], std.mem.span(n));
            name_slice[len] = 0;
            node.name = @ptrCast(np);
        }
    }

    return node;
}

pub export fn cardinal_scene_node_destroy(node: ?*CardinalSceneNode) void {
    if (node == null) return;
    const n = node.?;
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    // Destroy children
    if (n.children) |children| {
        var i: u32 = 0;
        while (i < n.child_count) : (i += 1) {
            cardinal_scene_node_destroy(children[i]);
        }
        memory.cardinal_free(allocator, @ptrCast(children));
    }

    if (n.mesh_indices) |indices| {
        memory.cardinal_free(allocator, @ptrCast(indices));
    }

    if (n.name) |name| {
        memory.cardinal_free(allocator, @ptrCast(name));
    }

    get_node_pool().destroy(n);
}

pub export fn cardinal_scene_node_add_child(parent: ?*CardinalSceneNode, child: ?*CardinalSceneNode) bool {
    if (parent == null or child == null) return false;
    const p = parent.?;
    const c = child.?;

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    if (p.child_count >= p.child_capacity) {
        const new_cap = if (p.child_capacity == 0) 4 else p.child_capacity * 2;
        const new_size = new_cap * @sizeOf(?*CardinalSceneNode);

        const new_ptr = memory.cardinal_alloc(allocator, new_size);
        if (new_ptr == null) return false;

        const new_children: [*]?*CardinalSceneNode = @ptrCast(@alignCast(new_ptr));

        if (p.children) |old_children| {
            @memcpy(new_children[0..p.child_count], old_children[0..p.child_count]);
            memory.cardinal_free(allocator, @ptrCast(old_children));
        }

        p.children = new_children;
        p.child_capacity = new_cap;
    }

    if (p.children) |children| {
        children[p.child_count] = c;
        p.child_count += 1;
        c.parent = p;
        c.world_transform_dirty = true;
        return true;
    }

    return false;
}

pub export fn cardinal_scene_node_remove_from_parent(child: ?*CardinalSceneNode) bool {
    if (child == null) return false;
    const c = child.?;
    if (c.parent == null) return false;

    const p = c.parent.?;
    if (p.children) |children| {
        var i: u32 = 0;
        var found = false;
        while (i < p.child_count) : (i += 1) {
            if (children[i] == c) {
                found = true;
                // Shift remaining
                var j = i;
                while (j < p.child_count - 1) : (j += 1) {
                    children[j] = children[j + 1];
                }
                break;
            }
        }

        if (found) {
            p.child_count -= 1;
            c.parent = null;
            return true;
        }
    }

    return false;
}

pub export fn cardinal_scene_node_find_by_name(root: ?*CardinalSceneNode, name: ?[*:0]const u8) ?*CardinalSceneNode {
    if (root == null or name == null) return null;
    const r = root.?;
    const n = std.mem.span(name.?);

    if (r.name) |node_name| {
        if (std.mem.eql(u8, std.mem.span(node_name), n)) {
            return r;
        }
    }

    if (r.children) |children| {
        var i: u32 = 0;
        while (i < r.child_count) : (i += 1) {
            if (cardinal_scene_node_find_by_name(children[i], name)) |found| {
                return found;
            }
        }
    }

    return null;
}

// Matrix multiplication helper
// Using transform_math for consistency

pub export fn cardinal_scene_node_update_transforms(node: ?*CardinalSceneNode, parent_world_transform: ?*const [16]f32) void {
    if (node == null) return;
    const n = node.?;

    if (parent_world_transform) |pwt| {
        transform_math.cardinal_matrix_multiply(&n.local_transform, pwt, &n.world_transform);
    } else {
        n.world_transform = n.local_transform;
    }
    n.world_transform_dirty = false;

    if (n.children) |children| {
        var i: u32 = 0;
        while (i < n.child_count) : (i += 1) {
            cardinal_scene_node_update_transforms(children[i], &n.world_transform);
        }
    }
}

pub export fn cardinal_scene_node_set_local_transform(node: ?*CardinalSceneNode, transform: ?*const [16]f32) void {
    if (node == null or transform == null) return;
    const n = node.?;
    @memcpy(&n.local_transform, transform.?);
    n.world_transform_dirty = true;
}

pub export fn cardinal_scene_node_get_world_transform(node: ?*CardinalSceneNode) *const [16]f32 {
    if (node == null) {
        return &g_identity;
    }
    return &node.?.world_transform;
}

pub export fn cardinal_scene_destroy(scene: ?*CardinalScene) void {
    if (scene == null) return;
    const s = scene.?;
    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    // Destroy meshes
    if (s.meshes) |meshes| {
        var i: u32 = 0;
        while (i < s.mesh_count) : (i += 1) {
            const m = &meshes[i];
            if (m.vertices) |v| memory.cardinal_free(allocator, @ptrCast(v));
            if (m.indices) |idx| memory.cardinal_free(allocator, @ptrCast(idx));
        }
        memory.cardinal_free(allocator, @ptrCast(meshes));
    }

    // Destroy materials
    if (s.materials) |mats| {
        memory.cardinal_free(allocator, @ptrCast(mats));
    }

    // Destroy textures
    if (s.textures) |texs| {
        var i: u32 = 0;
        while (i < s.texture_count) : (i += 1) {
            if (texs[i].ref_resource) |r| ref_counting.cardinal_ref_release(r);
            if (texs[i].path) |p| memory.cardinal_free(allocator, @ptrCast(p));
        }
        memory.cardinal_free(allocator, @ptrCast(texs));
    }

    // Destroy nodes
    if (s.root_nodes) |nodes| {
        var i: u32 = 0;
        while (i < s.root_node_count) : (i += 1) {
            cardinal_scene_node_destroy(nodes[i]);
        }
        memory.cardinal_free(allocator, @ptrCast(nodes));
    }

    if (s.all_nodes) |nodes| memory.cardinal_free(allocator, @ptrCast(nodes));

    // Destroy lights
    if (s.lights) |lights| {
        memory.cardinal_free(allocator, @ptrCast(lights));
    }

    // Destroy skins
    if (s.skins) |skins_opaque| {
        const skins: [*]animation.CardinalSkin = @ptrCast(@alignCast(skins_opaque));
        var i: u32 = 0;
        while (i < s.skin_count) : (i += 1) {
            animation.cardinal_skin_destroy(&skins[i]);
        }
        memory.cardinal_free(allocator, @ptrCast(skins));
    }

    // Destroy animation system
    if (s.animation_system) |sys| {
        animation.cardinal_animation_system_destroy(@ptrCast(@alignCast(sys)));
    }

    s.mesh_count = 0;
    s.material_count = 0;
    s.texture_count = 0;
    s.root_node_count = 0;
    s.light_count = 0;
    s.skin_count = 0;
    s.animation_system = null;
    s.skins = null;
}
