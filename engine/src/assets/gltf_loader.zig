const std = @import("std");
const scene = @import("scene.zig");
const texture_loader = @import("texture_loader.zig");
const material_ref_counting = @import("material_ref_counting.zig");
const ref_counting = @import("../core/ref_counting.zig");
const animation = @import("../core/animation.zig");
const transform_math = @import("../core/transform.zig");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const builtin = @import("builtin");
const handles = @import("../core/handles.zig");

const gltf_log = log.ScopedLogger("GLTF");

const c = @cImport({
    @cInclude("cgltf.h");
    @cInclude("string.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("time.h");
    @cInclude("vulkan/vulkan.h");
});

// Texture path cache
const TEXTURE_CACHE_SIZE = 256;
const TextureCacheEntry = struct {
    original_uri: [256]u8,
    resolved_path: [512]u8,
    valid: bool,
};

var g_texture_path_cache: [TEXTURE_CACHE_SIZE]TextureCacheEntry = undefined;
var g_cache_initialized: bool = false;

fn texture_cache_hash(uri: []const u8) usize {
    var hash: usize = 5381;
    for (uri) |char| {
        hash = ((hash << 5) +% hash) +% char;
    }
    return hash % TEXTURE_CACHE_SIZE;
}

fn init_texture_cache() void {
    if (!g_cache_initialized) {
        g_texture_path_cache = std.mem.zeroes(@TypeOf(g_texture_path_cache));
        g_cache_initialized = true;
        gltf_log.debug("Texture path cache initialized", .{});
    }
}

fn lookup_cached_path(original_uri: []const u8) ?[]const u8 {
    if (!g_cache_initialized) return null;

    const index = texture_cache_hash(original_uri);
    const entry = &g_texture_path_cache[index];

    if (entry.valid) {
        const cached_uri = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.original_uri)));
        if (std.mem.eql(u8, cached_uri, original_uri)) {
            const resolved = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.resolved_path)));
            gltf_log.debug("Cache hit for texture: {s} -> {s}", .{ original_uri, resolved });
            return resolved;
        }
    }
    return null;
}

fn cache_texture_path(original_uri: []const u8, resolved_path: []const u8) void {
    if (!g_cache_initialized) init_texture_cache();

    const index = texture_cache_hash(original_uri);
    const entry = &g_texture_path_cache[index];

    const uri_len = @min(original_uri.len, entry.original_uri.len - 1);
    @memcpy(entry.original_uri[0..uri_len], original_uri[0..uri_len]);
    entry.original_uri[uri_len] = 0;

    const path_len = @min(resolved_path.len, entry.resolved_path.len - 1);
    @memcpy(entry.resolved_path[0..path_len], resolved_path[0..path_len]);
    entry.resolved_path[path_len] = 0;

    entry.valid = true;
    gltf_log.debug("Cached texture path: {s} -> {s}", .{ original_uri, resolved_path });
}

fn try_texture_path(path: [:0]const u8, tex_data: *texture_loader.TextureData) ?*ref_counting.CardinalRefCountedResource {
    gltf_log.debug("Trying texture path: {s}", .{path});
    return texture_loader.texture_load_with_ref_counting(path.ptr, tex_data);
}

fn has_common_texture_pattern(uri: []const u8) bool {
    if (uri.len == 0) return false;
    if (uri[0] == '/' or std.mem.indexOf(u8, uri, "://") != null or (uri.len > 2 and uri[1] == ':')) {
        return true;
    }

    const patterns = [_][]const u8{ "diffuse", "albedo", "basecolor", "color", "normal", "bump", "height", "roughness", "metallic", "metalness", "specular", "ao", "ambient", "occlusion", "emission", "emissive" };

    var lower_uri_buf: [256]u8 = undefined;
    const len = @min(uri.len, 255);
    const lower_uri = std.ascii.lowerString(&lower_uri_buf, uri[0..len]);

    for (patterns) |p| {
        if (std.mem.indexOf(u8, lower_uri, p) != null) return true;
    }
    return false;
}

fn try_optimized_fallback_paths(original_uri: []const u8, base_path: []const u8, texture_path_buf: []u8, tex_data: *texture_loader.TextureData) ?*ref_counting.CardinalRefCountedResource {
    var filename_only = original_uri;
    if (std.mem.lastIndexOfScalar(u8, original_uri, '/')) |idx| {
        filename_only = original_uri[idx + 1 ..];
    } else if (std.mem.lastIndexOfScalar(u8, original_uri, '\\')) |idx| {
        filename_only = original_uri[idx + 1 ..];
    }

    var dir_end: ?usize = null;
    if (std.mem.lastIndexOfScalar(u8, base_path, '/')) |idx| {
        dir_end = idx;
    }
    if (std.mem.lastIndexOfScalar(u8, base_path, '\\')) |idx| {
        if (dir_end == null or idx > dir_end.?) dir_end = idx;
    }

    // 1. Relative to glTF file
    if (dir_end) |end| {
        const dir = base_path[0 .. end + 1];
        const path = std.fmt.bufPrintZ(texture_path_buf, "{s}{s}", .{ dir, original_uri }) catch return null;
        if (try_texture_path(path, tex_data)) |res| return res;

        if (!std.mem.eql(u8, filename_only, original_uri)) {
            const path2 = std.fmt.bufPrintZ(texture_path_buf, "{s}{s}", .{ dir, filename_only }) catch return null;
            if (try_texture_path(path2, tex_data)) |res| return res;
        }
    } else {
        const path = std.fmt.bufPrintZ(texture_path_buf, "{s}", .{original_uri}) catch return null;
        if (try_texture_path(path, tex_data)) |res| return res;
    }

    // 2. Common asset directories
    const common_dirs = [_][]const u8{ "assets/textures/", "assets/models/textures/", "textures/", "models/textures/" };

    for (common_dirs) |dir| {
        const path = std.fmt.bufPrintZ(texture_path_buf, "{s}{s}", .{ dir, filename_only }) catch continue;
        if (try_texture_path(path, tex_data)) |res| return res;
    }

    // 3. Parallel textures directory
    if (dir_end) |end| {
        const dir = base_path[0 .. end + 1];
        const path = std.fmt.bufPrintZ(texture_path_buf, "{s}../textures/{s}", .{ dir, filename_only }) catch return null;
        if (try_texture_path(path, tex_data)) |res| return res;
    }

    return null;
}

fn compute_default_normal(nx: *f32, ny: *f32, nz: *f32) void {
    nx.* = 0.0;
    ny.* = 1.0;
    nz.* = 0.0;
}

fn fallback_texture_destructor(resource: ?*anyopaque) callconv(.c) void {
    if (resource) |ptr| {
        c.free(ptr);
    }
}

fn create_fallback_texture(out_texture: *scene.CardinalTexture) bool {
    log.cardinal_log_error("DEBUG: create_fallback_texture (out_texture: {*})", .{out_texture});
    out_texture.width = 2;
    out_texture.height = 2;
    out_texture.channels = 4;

    const fallback_id = "[fallback]";
    if (ref_counting.cardinal_ref_acquire(fallback_id)) |ref| {
        out_texture.data = @ptrCast(ref.resource);
        out_texture.ref_resource = ref;
        log.cardinal_log_error("DEBUG: Acquired existing fallback texture (ref: {*})", .{ref});
    } else {
        const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
        const data = memory.cardinal_alloc(allocator, 16);
        if (data == null) return false;

        const pixels: [*]u8 = @ptrCast(data);
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            pixels[i * 4 + 0] = 255;
            pixels[i * 4 + 1] = 0;
            pixels[i * 4 + 2] = 255;
            pixels[i * 4 + 3] = 255;
        }

        if (ref_counting.cardinal_ref_create(fallback_id, data, 16, fallback_texture_destructor)) |ref| {
            out_texture.data = @ptrCast(data);
            out_texture.ref_resource = ref;
            log.cardinal_log_error("DEBUG: Created new fallback texture (ref: {*})", .{ref});
        } else {
            out_texture.data = @ptrCast(data);
            out_texture.ref_resource = null;
            log.cardinal_log_error("DEBUG: Failed to create ref for fallback texture", .{});
        }
    }

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    const path_ptr = memory.cardinal_alloc(allocator, fallback_id.len + 1);
    if (path_ptr) |ptr| {
        const slice = @as([*]u8, @ptrCast(ptr))[0 .. fallback_id.len + 1];
        @memcpy(slice[0..fallback_id.len], fallback_id);
        slice[fallback_id.len] = 0;
        out_texture.path = @ptrCast(ptr);
    }

    return true;
}

fn load_texture_with_fallback(original_uri: [*:0]const u8, base_path: [*:0]const u8, out_texture: *scene.CardinalTexture) bool {
    const uri = std.mem.span(original_uri);
    const base = std.mem.span(base_path);
    
    log.cardinal_log_debug("Loading texture '{s}'", .{uri});

    if (uri.len == 0) {
        log.cardinal_log_warn("Empty texture URI provided, using fallback", .{});
        return create_fallback_texture(out_texture);
    }

    if (lookup_cached_path(uri)) |cached_path| {
        log.cardinal_log_debug("Found cached path '{s}'", .{cached_path});
        var tex_data: texture_loader.TextureData = undefined;
        // Need null terminated cached_path
        var cached_path_z: [512]u8 = undefined;
        @memcpy(cached_path_z[0..cached_path.len], cached_path);
        cached_path_z[cached_path.len] = 0;

        if (texture_loader.texture_load_with_ref_counting(&cached_path_z, &tex_data)) |ref| {
            out_texture.data = tex_data.data;
            out_texture.width = tex_data.width;
            out_texture.height = tex_data.height;
            out_texture.channels = tex_data.channels;

            const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
            const path_ptr = memory.cardinal_alloc(allocator, cached_path.len + 1);
            if (path_ptr) |ptr| {
                @memcpy(@as([*]u8, @ptrCast(ptr))[0..cached_path.len], cached_path);
                @as([*]u8, @ptrCast(ptr))[cached_path.len] = 0;
                out_texture.path = @ptrCast(ptr);
            }
            out_texture.ref_resource = ref;
            log.cardinal_log_debug("Loaded texture from cache: {s}", .{cached_path});
            return true;
        }
        log.cardinal_log_warn("Failed to load cached path '{s}'", .{cached_path});
    }

    var texture_path_buf: [512]u8 = undefined;
    var tex_data: texture_loader.TextureData = undefined;
    var ref_resource: ?*ref_counting.CardinalRefCountedResource = null;

    // Absolute path check
    if (uri[0] == '/' or std.mem.indexOf(u8, uri, "://") != null or (uri.len > 2 and uri[1] == ':')) {
        log.cardinal_log_debug("Trying absolute path '{s}'", .{uri});
        ref_resource = try_texture_path(std.mem.span(original_uri), &tex_data);
        if (ref_resource != null) {
            cache_texture_path(uri, uri);
            const path = std.fmt.bufPrintZ(&texture_path_buf, "{s}", .{uri}) catch unreachable;
            // Success logic duplicated below, maybe use a label block
            out_texture.data = tex_data.data;
            out_texture.width = tex_data.width;
            out_texture.height = tex_data.height;
            out_texture.channels = tex_data.channels;
            const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
            const path_ptr = memory.cardinal_alloc(allocator, path.len + 1);
            if (path_ptr) |ptr| {
                @memcpy(@as([*]u8, @ptrCast(ptr))[0..path.len], path);
                @as([*]u8, @ptrCast(ptr))[path.len] = 0;
                out_texture.path = @ptrCast(ptr);
            }
            out_texture.ref_resource = ref_resource;
            log.cardinal_log_debug("Loaded texture absolute: {s}", .{uri});
            return true;
        }
        log.cardinal_log_debug("Failed absolute path '{s}'", .{uri});
        log.cardinal_log_warn("Failed to load texture '{s}', using fallback", .{uri});
        return create_fallback_texture(out_texture);
    }

    // Try relative path (base_path + uri)
    if (base.len > 0) {
        // base is the path to the GLTF file, so we need to strip the filename
        var dir: []const u8 = base;
        var dir_end: ?usize = null;
        if (std.mem.lastIndexOfScalar(u8, base, '/')) |idx| {
            dir_end = idx;
        }
        if (std.mem.lastIndexOfScalar(u8, base, '\\')) |idx| {
            if (dir_end == null or idx > dir_end.?) dir_end = idx;
        }

        if (dir_end) |end| {
            dir = base[0..end];
        } else {
            // No separator found, implies file is in CWD or base is just filename
            dir = ".";
        }

        var separator: []const u8 = "";
        // Check if dir needs a separator (if it's not empty and doesn't end in separator)
        if (dir.len > 0 and dir[dir.len - 1] != '/' and dir[dir.len - 1] != '\\') {
            separator = "/";
        }

        const path = std.fmt.bufPrintZ(&texture_path_buf, "{s}{s}{s}", .{dir, separator, uri}) catch null;
        if (path) |p| {
             log.cardinal_log_debug("Trying relative path '{s}'", .{p});
             ref_resource = try_texture_path(p, &tex_data);
             if (ref_resource != null) {
                cache_texture_path(uri, p);
                out_texture.data = tex_data.data;
                out_texture.width = tex_data.width;
                out_texture.height = tex_data.height;
                out_texture.channels = tex_data.channels;
                const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
                const path_ptr = memory.cardinal_alloc(allocator, p.len + 1);
                if (path_ptr) |ptr| {
                    @memcpy(@as([*]u8, @ptrCast(ptr))[0..p.len], p);
                    @as([*]u8, @ptrCast(ptr))[p.len] = 0;
                    out_texture.path = @ptrCast(ptr);
                }
                out_texture.ref_resource = ref_resource;
                log.cardinal_log_info("DEBUG: Successfully loaded texture relative: {s} (ref: {*} at {*}, data: {*})", .{p, ref_resource, &out_texture.ref_resource, out_texture.data});
                return true;
             }
             log.cardinal_log_warn("DEBUG: Failed relative path '{s}'", .{p});
        }
    }

    // Try optimized fallback paths
    log.cardinal_log_warn("DEBUG: Trying fallback paths for '{s}'", .{uri});
    ref_resource = try_optimized_fallback_paths(uri, base, &texture_path_buf, &tex_data);
    if (ref_resource) |res| {
        const path = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&texture_path_buf)), 0);
        cache_texture_path(uri, path);
        out_texture.data = tex_data.data;
        out_texture.width = tex_data.width;
        out_texture.height = tex_data.height;
        out_texture.channels = tex_data.channels;
        const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
        const path_ptr = memory.cardinal_alloc(allocator, path.len + 1);
        if (path_ptr) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..path.len], path);
            @as([*]u8, @ptrCast(ptr))[path.len] = 0;
            out_texture.path = @ptrCast(ptr);
        }
        out_texture.ref_resource = res;
        log.cardinal_log_error("DEBUG: Loaded texture fallback: {s} (ref: {*} at {*}, data: {*})", .{ path, res, &out_texture.ref_resource, out_texture.data });
        return true;
    }
    
    log.cardinal_log_error("DEBUG: Failed all fallback paths for '{s}'", .{uri});

    // Fallback to create_fallback_texture if no paths match
    log.cardinal_log_warn("Failed to load texture '{s}' from all paths, using fallback", .{uri});
    return create_fallback_texture(out_texture);
}

fn extract_texture_transform(texture_view: *const c.cgltf_texture_view, out_transform: *scene.CardinalTextureTransform) void {
    out_transform.offset[0] = 0.0;
    out_transform.offset[1] = 0.0;
    out_transform.scale[0] = 1.0;
    out_transform.scale[1] = 1.0;
    out_transform.rotation = 0.0;

    if (texture_view.has_transform != 0) {
        const transform = &texture_view.transform;
        out_transform.offset[0] = transform.offset[0];
        out_transform.offset[1] = transform.offset[1];
        out_transform.scale[0] = transform.scale[0];
        out_transform.scale[1] = transform.scale[1];
        out_transform.rotation = transform.rotation;
        log.cardinal_log_debug("Texture transform: offset=({d:.3},{d:.3}), scale=({d:.3},{d:.3}), rotation={d:.3}", .{ out_transform.offset[0], out_transform.offset[1], out_transform.scale[0], out_transform.scale[1], out_transform.rotation });
    }
}

fn convert_sampler(gltf_sampler: ?*const c.cgltf_sampler, out_sampler: *scene.CardinalSampler) void {
    if (gltf_sampler == null) {
        log.cardinal_log_debug("Sampler is NULL, defaulting to CLAMP_TO_EDGE", .{});
        // Default to CLAMP_TO_EDGE instead of REPEAT to prevent tiling artifacts
        // on models that don't explicitly define samplers.
        out_sampler.wrap_s = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        out_sampler.wrap_t = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        out_sampler.min_filter = c.VK_FILTER_LINEAR;
        out_sampler.mag_filter = c.VK_FILTER_LINEAR;
        return;
    }
    const s = gltf_sampler.?;
    log.cardinal_log_debug("Sampler defined: wrapS={d}, wrapT={d}", .{s.wrap_s, s.wrap_t});

    if (s.wrap_s == 33071 or s.wrap_s == 33069 or s.wrap_s == 10496) {
        out_sampler.wrap_s = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    } else if (s.wrap_s == 33648) {
        out_sampler.wrap_s = c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT;
    } else {
        out_sampler.wrap_s = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    }

    if (s.wrap_t == 33071 or s.wrap_t == 33069 or s.wrap_t == 10496) {
        out_sampler.wrap_t = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    } else if (s.wrap_t == 33648) {
        out_sampler.wrap_t = c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT;
    } else {
        out_sampler.wrap_t = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
    }

    if (s.min_filter == 9728 or s.min_filter == 9984 or s.min_filter == 9986) {
        out_sampler.min_filter = c.VK_FILTER_NEAREST;
    } else {
        out_sampler.min_filter = c.VK_FILTER_LINEAR;
    }

    if (s.mag_filter == 9728) {
        out_sampler.mag_filter = c.VK_FILTER_NEAREST;
    } else {
        out_sampler.mag_filter = c.VK_FILTER_LINEAR;
    }
}

fn load_texture_from_gltf(data: *const c.cgltf_data, img_idx: usize, base_path: [*:0]const u8, out_texture: *scene.CardinalTexture) bool {
    if (img_idx >= data.images_count or data.images == null) {
        log.cardinal_log_error("Invalid image index {d}", .{img_idx});
        return false;
    }

    const img = &data.images[img_idx];
    if (img.uri != null) {
        return load_texture_with_fallback(img.uri, base_path, out_texture);
    } else {
        log.cardinal_log_warn("Embedded textures not supported yet, using fallback", .{});
        return create_fallback_texture(out_texture);
    }
}

fn process_node(data: *const c.cgltf_data, node: *const c.cgltf_node, parent_transform: ?*const [16]f32, meshes: [*]scene.CardinalMesh, total_mesh_count: usize) void {
    var local_transform: [16]f32 = undefined;

    if (node.has_matrix != 0) {
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            local_transform[i] = @floatCast(node.matrix[i]);
        }
    } else {
        const translation = if (node.has_translation != 0) &node.translation else null;
        const rotation = if (node.has_rotation != 0) &node.rotation else null;
        const scale = if (node.has_scale != 0) &node.scale else null;

        // Convert to f32 arrays
        var t: [3]f32 = undefined;
        var r: [4]f32 = undefined;
        var s: [3]f32 = undefined;

        var t_ptr: ?*const [3]f32 = null;
        var r_ptr: ?*const [4]f32 = null;
        var s_ptr: ?*const [3]f32 = null;

        if (translation) |src| {
            t[0] = @floatCast(src[0]);
            t[1] = @floatCast(src[1]);
            t[2] = @floatCast(src[2]);
            t_ptr = &t;
        }
        if (rotation) |src| {
            r[0] = @floatCast(src[0]);
            r[1] = @floatCast(src[1]);
            r[2] = @floatCast(src[2]);
            r[3] = @floatCast(src[3]);
            r_ptr = &r;
        }
        if (scale) |src| {
            s[0] = @floatCast(src[0]);
            s[1] = @floatCast(src[1]);
            s[2] = @floatCast(src[2]);
            s_ptr = &s;
        }

        transform_math.cardinal_matrix_from_trs(t_ptr, r_ptr, s_ptr, &local_transform);
    }

    var world_transform: [16]f32 = undefined;
    if (parent_transform) |pt| {
        transform_math.cardinal_matrix_multiply(pt, &local_transform, &world_transform);
    } else {
        @memcpy(&world_transform, &local_transform);
    }

    if (node.mesh) |mesh| {
        const mesh_index = (@intFromPtr(mesh) - @intFromPtr(data.meshes)) / @sizeOf(c.cgltf_mesh);

        var cardinal_mesh_index: usize = 0;
        var mi: usize = 0;
        while (mi < mesh_index) : (mi += 1) {
            cardinal_mesh_index += data.meshes[mi].primitives_count;
        }

        var pi: usize = 0;
        while (pi < mesh.*.primitives_count) : (pi += 1) {
            if (cardinal_mesh_index + pi < total_mesh_count) {
                @memcpy(&meshes[cardinal_mesh_index + pi].transform, &world_transform);
            }
        }
    }

    var ci: usize = 0;
    while (ci < node.children_count) : (ci += 1) {
        process_node(data, node.children[ci], &world_transform, meshes, total_mesh_count);
    }
}

fn build_scene_node(data: *const c.cgltf_data, gltf_node: *const c.cgltf_node, meshes: [*]scene.CardinalMesh, total_mesh_count: usize, all_nodes: ?[*]?*scene.CardinalSceneNode, mesh_primitive_offsets: ?[*]u32) ?*scene.CardinalSceneNode {
    const node_name = if (gltf_node.name) |n| std.mem.span(n) else "Unnamed Node";
    const scene_node = scene.cardinal_scene_node_create(node_name);
    if (scene_node == null) {
        log.cardinal_log_error("Failed to create scene node", .{});
        return null;
    }
    const node = scene_node.?;

    if (all_nodes != null and data.nodes != null) {
        const index = (@intFromPtr(gltf_node) - @intFromPtr(data.nodes)) / @sizeOf(c.cgltf_node);
        if (index < data.nodes_count) {
            all_nodes.?[index] = node;
        }
    }

    var local_transform: [16]f32 = undefined;
    if (gltf_node.has_matrix != 0) {
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            local_transform[i] = @floatCast(gltf_node.matrix[i]);
        }
    } else {
        var t: [3]f32 = .{ 0, 0, 0 };
        var r: [4]f32 = .{ 0, 0, 0, 1 };
        var s: [3]f32 = .{ 1, 1, 1 };

        if (gltf_node.has_translation != 0) {
            t[0] = @floatCast(gltf_node.translation[0]);
            t[1] = @floatCast(gltf_node.translation[1]);
            t[2] = @floatCast(gltf_node.translation[2]);
        }
        if (gltf_node.has_rotation != 0) {
            r[0] = @floatCast(gltf_node.rotation[0]);
            r[1] = @floatCast(gltf_node.rotation[1]);
            r[2] = @floatCast(gltf_node.rotation[2]);
            r[3] = @floatCast(gltf_node.rotation[3]);
        }
        if (gltf_node.has_scale != 0) {
            s[0] = @floatCast(gltf_node.scale[0]);
            s[1] = @floatCast(gltf_node.scale[1]);
            s[2] = @floatCast(gltf_node.scale[2]);
        }
        transform_math.cardinal_matrix_from_trs(&t, &r, &s, &local_transform);
    }
    scene.cardinal_scene_node_set_local_transform(node, &local_transform);

    if (gltf_node.mesh) |m| {
        const mesh_idx = (@intFromPtr(m) - @intFromPtr(data.meshes)) / @sizeOf(c.cgltf_mesh);
        const primitive_count = m.*.primitives_count;

        if (primitive_count > 0) {
            const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
            const indices_ptr = memory.cardinal_alloc(allocator, primitive_count * @sizeOf(u32));
            if (indices_ptr == null) {
                log.cardinal_log_error("Failed to allocate mesh indices", .{});
                return node;
            }
            node.mesh_indices = @ptrCast(@alignCast(indices_ptr));
        }

        var start_index: u32 = 0;
        if (mesh_primitive_offsets) |offsets| {
            start_index = offsets[mesh_idx];
        } else {
            var mi: usize = 0;
            while (mi < mesh_idx) : (mi += 1) {
                start_index += @intCast(data.meshes[mi].primitives_count);
            }
        }

        var pi: usize = 0;
        while (pi < primitive_count) : (pi += 1) {
            if (start_index + pi < total_mesh_count) {
                node.mesh_indices.?[node.mesh_count] = start_index + @as(u32, @intCast(pi));
                node.mesh_count += 1;
            }
        }
    }

    var ci: usize = 0;
    while (ci < gltf_node.children_count) : (ci += 1) {
        const child = build_scene_node(data, gltf_node.children[ci], meshes, total_mesh_count, all_nodes, mesh_primitive_offsets);
        if (child) |c_node| {
            _ = scene.cardinal_scene_node_add_child(node, c_node);
        }
    }

    return node;
}

fn load_skins_from_gltf(data: *const c.cgltf_data, out_skins: *?[*]animation.CardinalSkin, out_skin_count: *u32) bool {
    out_skins.* = null;
    out_skin_count.* = 0;

    if (data.skins_count == 0) return true;

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    const skins_ptr = memory.cardinal_calloc(allocator, data.skins_count, @sizeOf(animation.CardinalSkin));
    if (skins_ptr == null) {
        log.cardinal_log_error("Failed to allocate memory for skins", .{});
        return false;
    }
    const skins: [*]animation.CardinalSkin = @ptrCast(@alignCast(skins_ptr));

    var i: usize = 0;
    while (i < data.skins_count) : (i += 1) {
        const gltf_skin = &data.skins[i];
        const skin = &skins[i];

        if (gltf_skin.name) |name| {
            const name_len = c.strlen(name) + 1;
            const name_ptr = memory.cardinal_alloc(allocator, name_len);
            skin.name = @ptrCast(name_ptr);
            if (skin.name) |ptr| {
                _ = c.strcpy(ptr, name);
            }
        } else {
            var buf: [32]u8 = undefined;
            const name = std.fmt.bufPrintZ(&buf, "Skin_{d}", .{i}) catch "Skin";
            const name_ptr = memory.cardinal_alloc(allocator, name.len + 1);
            skin.name = @ptrCast(name_ptr);
            if (skin.name) |ptr| {
                _ = c.strcpy(ptr, name);
            }
        }

        skin.bone_count = @intCast(gltf_skin.joints_count);
        if (skin.bone_count > 0) {
            const bones_ptr = memory.cardinal_calloc(allocator, skin.bone_count, @sizeOf(animation.CardinalBone));
            skin.bones = @ptrCast(@alignCast(bones_ptr));
            if (skin.bones == null) {
                log.cardinal_log_error("Failed to allocate memory for skin bones", .{});
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    animation.cardinal_skin_destroy(&skins[j]);
                }
                memory.cardinal_free(allocator, skins_ptr);
                return false;
            }

            var j: usize = 0;
            while (j < gltf_skin.joints_count) : (j += 1) {
                const joint_node_idx = (@intFromPtr(gltf_skin.joints[j]) - @intFromPtr(data.nodes)) / @sizeOf(c.cgltf_node);
                skin.bones.?[j].node_index = @intCast(joint_node_idx);
                skin.bones.?[j].parent_index = std.math.maxInt(u32);

                const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
                @memcpy(&skin.bones.?[j].inverse_bind_matrix, &identity);
                @memcpy(&skin.bones.?[j].current_matrix, &identity);
            }
        }

        if (gltf_skin.inverse_bind_matrices) |accessor| {
            if (accessor.*.type == c.cgltf_type_mat4 and accessor.*.component_type == c.cgltf_component_type_r_32f) {
                var j: usize = 0;
                while (j < skin.bone_count) : (j += 1) {
                    _ = c.cgltf_accessor_read_float(accessor, j, &skin.bones.?[j].inverse_bind_matrix[0], 16);
                }
            }
        }
    }

    out_skins.* = skins;
    out_skin_count.* = @intCast(data.skins_count);
    log.cardinal_log_info("Loaded {d} skins from GLTF", .{out_skin_count.*});
    return true;
}

fn load_animations_from_gltf(data: *const c.cgltf_data, anim_system: *animation.CardinalAnimationSystem) bool {
    if (data.animations_count == 0) return true;

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);

    var i: usize = 0;
    while (i < data.animations_count) : (i += 1) {
        const gltf_anim = &data.animations[i];
        var anim: animation.CardinalAnimation = std.mem.zeroes(animation.CardinalAnimation);

        if (gltf_anim.name) |name| {
            const name_len = c.strlen(name) + 1;
            const name_ptr = memory.cardinal_alloc(allocator, name_len);
            anim.name = @ptrCast(name_ptr);
            if (anim.name) |ptr| {
                _ = c.strcpy(ptr, name);
            }
        } else {
            var buf: [32]u8 = undefined;
            const name = std.fmt.bufPrintZ(&buf, "Animation_{d}", .{i}) catch "Animation";
            const name_ptr = memory.cardinal_alloc(allocator, name.len + 1);
            anim.name = @ptrCast(name_ptr);
            if (anim.name) |ptr| {
                _ = c.strcpy(ptr, name);
            }
        }

        anim.sampler_count = @intCast(gltf_anim.samplers_count);
        if (anim.sampler_count > 0) {
            const samplers_ptr = memory.cardinal_calloc(allocator, anim.sampler_count, @sizeOf(animation.CardinalAnimationSampler));
            if (samplers_ptr == null) continue;
            anim.samplers = @ptrCast(@alignCast(samplers_ptr));

            var s: usize = 0;
            while (s < gltf_anim.samplers_count) : (s += 1) {
                const gltf_sampler = &gltf_anim.samplers[s];
                const sampler = &anim.samplers.?[s];

                switch (gltf_sampler.interpolation) {
                    c.cgltf_interpolation_type_linear => sampler.interpolation = .LINEAR,
                    c.cgltf_interpolation_type_step => sampler.interpolation = .STEP,
                    c.cgltf_interpolation_type_cubic_spline => sampler.interpolation = .CUBICSPLINE,
                    else => sampler.interpolation = .LINEAR,
                }

                if (gltf_sampler.input) |acc| {
                    if (acc.*.component_type == c.cgltf_component_type_r_32f) {
                        sampler.input_count = @intCast(acc.*.count);
                        sampler.input = @ptrCast(@alignCast(memory.cardinal_alloc(allocator, sampler.input_count * @sizeOf(f32))));
                        if (sampler.input) |ptr| {
                            _ = c.cgltf_accessor_read_float(acc, 0, ptr, sampler.input_count);
                        }
                    }
                }

                if (gltf_sampler.output) |acc| {
                    if (acc.*.component_type == c.cgltf_component_type_r_32f) {
                        sampler.output_count = @intCast(acc.*.count);
                        var comp_count: usize = 1;
                        switch (acc.*.type) {
                            c.cgltf_type_scalar => comp_count = 1,
                            c.cgltf_type_vec3 => comp_count = 3,
                            c.cgltf_type_vec4 => comp_count = 4,
                            else => comp_count = 1,
                        }

                        sampler.output = @ptrCast(@alignCast(memory.cardinal_alloc(allocator, sampler.output_count * comp_count * @sizeOf(f32))));
                        if (sampler.output) |ptr| {
                            _ = c.cgltf_accessor_read_float(acc, 0, ptr, sampler.output_count * comp_count);
                        }
                    }
                }
            }
        }

        anim.channel_count = @intCast(gltf_anim.channels_count);
        if (anim.channel_count > 0) {
            const channels_ptr = memory.cardinal_calloc(allocator, anim.channel_count, @sizeOf(animation.CardinalAnimationChannel));
            if (channels_ptr == null) {
                if (anim.samplers) |samplers| {
                    var s: usize = 0;
                    while (s < anim.sampler_count) : (s += 1) {
                        if (samplers[s].input) |p| memory.cardinal_free(allocator, p);
                        if (samplers[s].output) |p| memory.cardinal_free(allocator, p);
                    }
                    memory.cardinal_free(allocator, anim.samplers);
                }
                continue;
            }
            anim.channels = @ptrCast(@alignCast(channels_ptr));

            var c_idx: usize = 0;
            while (c_idx < gltf_anim.channels_count) : (c_idx += 1) {
                const gltf_channel = &gltf_anim.channels[c_idx];
                const channel = &anim.channels.?[c_idx];

                channel.sampler_index = @intCast((@intFromPtr(gltf_channel.sampler) - @intFromPtr(gltf_anim.samplers)) / @sizeOf(c.cgltf_animation_sampler));
                channel.target.node_index = @intCast((@intFromPtr(gltf_channel.target_node) - @intFromPtr(data.nodes)) / @sizeOf(c.cgltf_node));

                switch (gltf_channel.target_path) {
                    c.cgltf_animation_path_type_translation => channel.target.path = .TRANSLATION,
                    c.cgltf_animation_path_type_rotation => channel.target.path = .ROTATION,
                    c.cgltf_animation_path_type_scale => channel.target.path = .SCALE,
                    c.cgltf_animation_path_type_weights => channel.target.path = .WEIGHTS,
                    else => channel.target.path = .TRANSLATION,
                }
            }
        }

        anim.duration = 0.0;
        if (anim.samplers) |samplers| {
            var s: usize = 0;
            while (s < anim.sampler_count) : (s += 1) {
                if (samplers[s].input != null and samplers[s].input_count > 0) {
                    const max_time = samplers[s].input.?[samplers[s].input_count - 1];
                    if (max_time > anim.duration) anim.duration = max_time;
                }
            }
        }

        _ = animation.cardinal_animation_system_add_animation(anim_system, &anim);

        // Animation system makes copies, so we can free our temporary buffers
        if (anim.samplers) |samplers| {
            var s: usize = 0;
            while (s < anim.sampler_count) : (s += 1) {
                if (samplers[s].input) |p| memory.cardinal_free(allocator, p);
                if (samplers[s].output) |p| memory.cardinal_free(allocator, p);
            }
            memory.cardinal_free(allocator, anim.samplers);
        }
        if (anim.channels) |channels| {
            memory.cardinal_free(allocator, channels);
        }
        if (anim.name) |n| memory.cardinal_free(allocator, n);
    }

    log.cardinal_log_info("Loaded {d} animations from GLTF", .{data.animations_count});
    return true;
}

fn load_lights_from_gltf(data: *const c.cgltf_data, out_lights: *?[*]scene.CardinalLight, out_light_count: *u32) bool {
    out_lights.* = null;
    out_light_count.* = 0;

    if (data.lights_count == 0) return true;

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    const lights_ptr = memory.cardinal_calloc(allocator, data.lights_count, @sizeOf(scene.CardinalLight));
    if (lights_ptr == null) {
        log.cardinal_log_error("Failed to allocate memory for lights", .{});
        return false;
    }
    const lights: [*]scene.CardinalLight = @ptrCast(@alignCast(lights_ptr));

    var i: usize = 0;
    while (i < data.lights_count) : (i += 1) {
        const gltf_light = &data.lights[i];
        const light = &lights[i];

        light.color[0] = gltf_light.color[0];
        light.color[1] = gltf_light.color[1];
        light.color[2] = gltf_light.color[2];
        light.intensity = gltf_light.intensity;
        light.range = gltf_light.range;
        light.inner_cone_angle = gltf_light.spot_inner_cone_angle;
        light.outer_cone_angle = gltf_light.spot_outer_cone_angle;
        light.node_index = std.math.maxInt(u32); // Will be set later

        switch (gltf_light.type) {
            c.cgltf_light_type_directional => light.type = .DIRECTIONAL,
            c.cgltf_light_type_point => light.type = .POINT,
            c.cgltf_light_type_spot => light.type = .SPOT,
            else => light.type = .POINT, // Fallback
        }
    }

    out_lights.* = lights;
    out_light_count.* = @intCast(data.lights_count);
    log.cardinal_log_info("Loaded {d} lights from GLTF", .{out_light_count.*});
    return true;
}

pub export fn cardinal_gltf_load_scene(path: [*:0]const u8, out_scene: *scene.CardinalScene) callconv(.c) bool {
    log.cardinal_log_info("Starting GLTF scene loading: {s}", .{path});
    @memset(@as([*]u8, @ptrCast(out_scene))[0..@sizeOf(scene.CardinalScene)], 0);

    var options: c.cgltf_options = std.mem.zeroes(c.cgltf_options);
    var data: ?*c.cgltf_data = null;

    const result = c.cgltf_parse_file(&options, path, &data);
    if (result != c.cgltf_result_success) {
        log.cardinal_log_error("cgltf_parse_file failed: {d} for {s}", .{ result, path });
        return false;
    }

    const load_result = c.cgltf_load_buffers(&options, data, path);
    if (load_result != c.cgltf_result_success) {
        log.cardinal_log_error("cgltf_load_buffers failed: {d} for {s}", .{ load_result, path });
        c.cgltf_free(data);
        return false;
    }

    const d = data.?;

    // Load textures
    const num_textures = if (d.textures_count > 0) d.textures_count else d.images_count;
    var textures: ?[*]scene.CardinalTexture = null;
    var texture_count: u32 = 0;

    if (num_textures > 0) {
        const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
        const textures_ptr = memory.cardinal_calloc(allocator, num_textures, @sizeOf(scene.CardinalTexture));
        if (textures_ptr == null) {
            log.cardinal_log_error("Failed to allocate textures", .{});
            c.cgltf_free(data);
            return false;
        }
        textures = @ptrCast(@alignCast(textures_ptr));

        if (d.textures_count > 0) {
            var i: usize = 0;
            while (i < d.textures_count) : (i += 1) {
                const tex = &d.textures[i];
                var success = false;

                if (tex.image != null) {
                    const img_idx = (@intFromPtr(tex.image) - @intFromPtr(d.images)) / @sizeOf(c.cgltf_image);
                    if (load_texture_from_gltf(d, img_idx, path, &textures.?[texture_count])) {
                        success = true;
                    }
                } else {
                    success = create_fallback_texture(&textures.?[texture_count]);
                }

                if (success) {
                    convert_sampler(tex.sampler, &textures.?[texture_count].sampler);
                    texture_count += 1;
                }
            }
        } else {
            var i: usize = 0;
            while (i < d.images_count) : (i += 1) {
                if (load_texture_from_gltf(d, i, path, &textures.?[texture_count])) {
                    convert_sampler(null, &textures.?[texture_count].sampler);
                    texture_count += 1;
                }
            }
        }
    }

    // Load materials
    var materials: ?[*]scene.CardinalMaterial = null;
    var material_count: u32 = 0;

    if (d.materials_count > 0) {
        const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
        const materials_ptr = memory.cardinal_calloc(allocator, d.materials_count, @sizeOf(scene.CardinalMaterial));
        if (materials_ptr == null) {
            log.cardinal_log_error("Failed to allocate materials", .{});
            // Cleanup textures
            if (textures) |texs| {
                var i: usize = 0;
                while (i < texture_count) : (i += 1) {
                    // ref_resource is handled by ref_counting system
                    if (texs[i].path) |p| memory.cardinal_free(allocator, @ptrCast(p));
                }
                memory.cardinal_free(allocator, textures);
            }
            c.cgltf_free(data);
            return false;
        }
        materials = @ptrCast(@alignCast(materials_ptr));

        var i: usize = 0;
        while (i < d.materials_count) : (i += 1) {
            const mat = &d.materials[i];
            const card_mat = &materials.?[material_count];

            card_mat.albedo_texture = handles.TextureHandle.INVALID;
            card_mat.normal_texture = handles.TextureHandle.INVALID;
            card_mat.metallic_roughness_texture = handles.TextureHandle.INVALID;
            card_mat.ao_texture = handles.TextureHandle.INVALID;
            card_mat.emissive_texture = handles.TextureHandle.INVALID;

            card_mat.albedo_factor = .{ 1, 1, 1 };
            card_mat.metallic_factor = 0.0;
            card_mat.roughness_factor = 0.5;
            card_mat.emissive_factor = .{ 0, 0, 0 };
            card_mat.normal_scale = 1.0;
            card_mat.ao_strength = 1.0;

            card_mat.alpha_mode = .OPAQUE;
            card_mat.alpha_cutoff = 0.5;
            card_mat.double_sided = (mat.double_sided != 0);

            if (mat.alpha_mode == c.cgltf_alpha_mode_mask) {
                card_mat.alpha_mode = .MASK;
                card_mat.alpha_cutoff = mat.alpha_cutoff;
            } else if (mat.alpha_mode == c.cgltf_alpha_mode_blend) {
                card_mat.alpha_mode = .BLEND;
            }

            if (mat.name) |name| {
                const name_slice = std.mem.span(name);
                
                // Log material name and mode for debugging
                log.cardinal_log_debug("Material '{s}': alpha_mode={any}", .{name_slice, card_mat.alpha_mode});
            }

            const identity = scene.CardinalTextureTransform{ .offset = .{ 0, 0 }, .scale = .{ 1, 1 }, .rotation = 0 };
            card_mat.albedo_transform = identity;
            card_mat.normal_transform = identity;
            card_mat.metallic_roughness_transform = identity;
            card_mat.ao_transform = identity;
            card_mat.emissive_transform = identity;

            if (mat.has_pbr_metallic_roughness != 0) {
                const pbr = &mat.pbr_metallic_roughness;
                card_mat.albedo_factor[0] = pbr.base_color_factor[0];
                card_mat.albedo_factor[1] = pbr.base_color_factor[1];
                card_mat.albedo_factor[2] = pbr.base_color_factor[2];
                card_mat.metallic_factor = pbr.metallic_factor;
                card_mat.roughness_factor = pbr.roughness_factor;

                if (pbr.base_color_texture.texture != null) {
                    var tex_idx: u32 = 0;
                    if (d.textures_count > 0) {
                        tex_idx = @intCast((@intFromPtr(pbr.base_color_texture.texture) - @intFromPtr(d.textures)) / @sizeOf(c.cgltf_texture));
                    } else {
                        tex_idx = @intCast((@intFromPtr(pbr.base_color_texture.texture.*.image) - @intFromPtr(d.images)) / @sizeOf(c.cgltf_image));
                    }
                    if (tex_idx < texture_count) card_mat.albedo_texture = .{ .index = tex_idx, .generation = 1 };
                    card_mat.uv_indices[0] = @intCast(pbr.base_color_texture.texcoord);
                    extract_texture_transform(&pbr.base_color_texture, &card_mat.albedo_transform);
                }

                if (pbr.metallic_roughness_texture.texture != null) {
                    var tex_idx: u32 = 0;
                    if (d.textures_count > 0) {
                        tex_idx = @intCast((@intFromPtr(pbr.metallic_roughness_texture.texture) - @intFromPtr(d.textures)) / @sizeOf(c.cgltf_texture));
                    } else {
                        tex_idx = @intCast((@intFromPtr(pbr.metallic_roughness_texture.texture.*.image) - @intFromPtr(d.images)) / @sizeOf(c.cgltf_image));
                    }
                    if (tex_idx < texture_count) card_mat.metallic_roughness_texture = .{ .index = tex_idx, .generation = 1 };
                    card_mat.uv_indices[2] = @intCast(pbr.metallic_roughness_texture.texcoord);
                    extract_texture_transform(&pbr.metallic_roughness_texture, &card_mat.metallic_roughness_transform);
                }
            }

            if (mat.normal_texture.texture != null) {
                var tex_idx: u32 = 0;
                if (d.textures_count > 0) {
                    tex_idx = @intCast((@intFromPtr(mat.normal_texture.texture) - @intFromPtr(d.textures)) / @sizeOf(c.cgltf_texture));
                } else {
                    tex_idx = @intCast((@intFromPtr(mat.normal_texture.texture.*.image) - @intFromPtr(d.images)) / @sizeOf(c.cgltf_image));
                }
                if (tex_idx < texture_count) card_mat.normal_texture = .{ .index = tex_idx, .generation = 1 };
                card_mat.uv_indices[1] = @intCast(mat.normal_texture.texcoord);
                card_mat.normal_scale = mat.normal_texture.scale;
                extract_texture_transform(&mat.normal_texture, &card_mat.normal_transform);
            }

            if (mat.occlusion_texture.texture != null) {
                var tex_idx: u32 = 0;
                if (d.textures_count > 0) {
                    tex_idx = @intCast((@intFromPtr(mat.occlusion_texture.texture) - @intFromPtr(d.textures)) / @sizeOf(c.cgltf_texture));
                } else {
                    tex_idx = @intCast((@intFromPtr(mat.occlusion_texture.texture.*.image) - @intFromPtr(d.images)) / @sizeOf(c.cgltf_image));
                }
                if (tex_idx < texture_count) card_mat.ao_texture = .{ .index = tex_idx, .generation = 1 };
                card_mat.uv_indices[3] = @intCast(mat.occlusion_texture.texcoord);
                card_mat.ao_strength = mat.occlusion_texture.scale;
                extract_texture_transform(&mat.occlusion_texture, &card_mat.ao_transform);
            }

            if (mat.emissive_texture.texture != null) {
                var tex_idx: u32 = 0;
                if (d.textures_count > 0) {
                    tex_idx = @intCast((@intFromPtr(mat.emissive_texture.texture) - @intFromPtr(d.textures)) / @sizeOf(c.cgltf_texture));
                } else {
                    tex_idx = @intCast((@intFromPtr(mat.emissive_texture.texture.*.image) - @intFromPtr(d.images)) / @sizeOf(c.cgltf_image));
                }
                if (tex_idx < texture_count) card_mat.emissive_texture = .{ .index = tex_idx, .generation = 1 };
                card_mat.uv_indices[4] = @intCast(mat.emissive_texture.texcoord);
                extract_texture_transform(&mat.emissive_texture, &card_mat.emissive_transform);
            }

            if (mat.emissive_factor[0] > 0 or mat.emissive_factor[1] > 0 or mat.emissive_factor[2] > 0) {
                card_mat.emissive_factor[0] = mat.emissive_factor[0];
                card_mat.emissive_factor[1] = mat.emissive_factor[1];
                card_mat.emissive_factor[2] = mat.emissive_factor[2];
            }

            var temp_material: scene.CardinalMaterial = undefined;
            const material_ref = material_ref_counting.cardinal_material_load_with_ref_counting(card_mat, &temp_material);
            if (material_ref) |ref| {
                card_mat.* = temp_material;
                card_mat.ref_resource = ref;
            } else {
                card_mat.ref_resource = null;
            }
            material_count += 1;
        }
    }

    // Count meshes
    var mesh_count: usize = 0;
    var mi: usize = 0;
    while (mi < d.meshes_count) : (mi += 1) {
        mesh_count += d.meshes[mi].primitives_count;
    }

    if (mesh_count == 0) {
        c.cgltf_free(data);
        return true;
    }

    const allocator = memory.cardinal_get_allocator_for_category(.ASSETS);
    const meshes_ptr = memory.cardinal_calloc(allocator, mesh_count, @sizeOf(scene.CardinalMesh));
    if (meshes_ptr == null) {
        log.cardinal_log_error("Failed to allocate meshes", .{});
        c.cgltf_free(data);
        return false;
    }
    const meshes_safe: [*]scene.CardinalMesh = @ptrCast(@alignCast(meshes_ptr));

    var mesh_write: usize = 0;
    mi = 0;
    while (mi < d.meshes_count) : (mi += 1) {
        const m = &d.meshes[mi];

        var pi: usize = 0;
        while (pi < m.primitives_count) : (pi += 1) {
            const p = &m.primitives[pi];

            // Check for Draco compression
            if (p.has_draco_mesh_compression != 0) {
                log.cardinal_log_warn("Draco compression detected for primitive {d}. Draco is not yet supported; mesh may be incomplete.", .{pi});
            }

            // Attributes
            var pos_acc: ?*const c.cgltf_accessor = null;
            var nrm_acc: ?*const c.cgltf_accessor = null;
            var uv0_acc: ?*const c.cgltf_accessor = null;
            var uv1_acc: ?*const c.cgltf_accessor = null;
            var joints_acc: ?*const c.cgltf_accessor = null;
            var weights_acc: ?*const c.cgltf_accessor = null;

            var ai: usize = 0;
            while (ai < p.attributes_count) : (ai += 1) {
                const a = &p.attributes[ai];
                switch (a.type) {
                    c.cgltf_attribute_type_position => pos_acc = a.data,
                    c.cgltf_attribute_type_normal => nrm_acc = a.data,
                    c.cgltf_attribute_type_texcoord => {
                        if (a.index == 0) uv0_acc = a.data;
                        if (a.index == 1) uv1_acc = a.data;
                    },
                    c.cgltf_attribute_type_joints => joints_acc = a.data,
                    c.cgltf_attribute_type_weights => weights_acc = a.data,
                    else => {},
                }
            }

            if (pos_acc == null) continue;
            const vcount = pos_acc.?.count;

            const vertices_ptr = memory.cardinal_calloc(allocator, vcount, @sizeOf(scene.CardinalVertex));
            const vertices = @as([*]scene.CardinalVertex, @ptrCast(@alignCast(vertices_ptr)));

            var vi: usize = 0;
            while (vi < vcount) : (vi += 1) {
                var v: [3]f32 = .{ 0, 0, 0 };
                // Check return value for robust sparse accessor handling
                if (c.cgltf_accessor_read_float(pos_acc, vi, &v[0], 3) == 0) {
                    log.cardinal_log_warn("Failed to read position for vertex {d}", .{vi});
                }
                vertices[vi].px = v[0];
                vertices[vi].py = v[1];
                vertices[vi].pz = v[2];

                if (nrm_acc) |acc| {
                    if (c.cgltf_accessor_read_float(acc, vi, &v[0], 3) == 0) {
                         // Default normal if missing/failed
                         v = .{ 0, 1, 0 };
                    }
                    vertices[vi].nx = v[0];
                    vertices[vi].ny = v[1];
                    vertices[vi].nz = v[2];
                } else {
                    vertices[vi].nx = 0;
                    vertices[vi].ny = 1;
                    vertices[vi].nz = 0;
                }

                if (uv0_acc) |acc| {
                    var uv: [2]f32 = .{ 0, 0 };
                    _ = c.cgltf_accessor_read_float(acc, vi, &uv[0], 2);
                    vertices[vi].u = uv[0];
                    vertices[vi].v = uv[1];
                }

                if (uv1_acc) |acc| {
                    var uv: [2]f32 = .{ 0, 0 };
                    _ = c.cgltf_accessor_read_float(acc, vi, &uv[0], 2);
                    vertices[vi].u1 = uv[0];
                    vertices[vi].v1 = uv[1];
                }

                if (joints_acc) |acc| {
                    var j: [4]u32 = .{ 0, 0, 0, 0 };
                    _ = c.cgltf_accessor_read_uint(acc, vi, &j[0], 4);
                    vertices[vi].bone_indices = j;
                }

                if (weights_acc) |acc| {
                    var w: [4]f32 = .{ 0, 0, 0, 0 };
                    _ = c.cgltf_accessor_read_float(acc, vi, &w[0], 4);
                    vertices[vi].bone_weights = w;
                }
            }

            // Load Morph Targets
            var morph_targets: ?[*]scene.CardinalMorphTarget = null;
            const morph_target_count = p.targets_count;

            if (morph_target_count > 0) {
                const mt_ptr = memory.cardinal_calloc(allocator, morph_target_count, @sizeOf(scene.CardinalMorphTarget));
                if (mt_ptr != null) {
                    morph_targets = @ptrCast(@alignCast(mt_ptr));
                    var ti: usize = 0;
                    while (ti < morph_target_count) : (ti += 1) {
                        const target = &p.targets[ti];
                        const mt = &morph_targets.?[ti];

                        var tai: usize = 0;
                        while (tai < target.attributes_count) : (tai += 1) {
                            const ta = &target.attributes[tai];
                            const count = ta.data.*.count;

                            if (count != vcount) {
                                log.cardinal_log_warn("Morph target attribute count mismatch: {d} vs {d}", .{count, vcount});
                                continue;
                            }

                            const data_size = count * 3 * @sizeOf(f32);
                            const data_ptr = memory.cardinal_alloc(allocator, data_size);
                            if (data_ptr == null) continue;
                            const float_ptr = @as([*]f32, @ptrCast(@alignCast(data_ptr)));

                            // Read all floats
                            var k: usize = 0;
                            while (k < count) : (k += 1) {
                                _ = c.cgltf_accessor_read_float(ta.data, k, &float_ptr[k * 3], 3);
                            }

                            switch (ta.type) {
                                c.cgltf_attribute_type_position => mt.positions = float_ptr,
                                c.cgltf_attribute_type_normal => mt.normals = float_ptr,
                                c.cgltf_attribute_type_tangent => mt.tangents = float_ptr,
                                else => memory.cardinal_free(allocator, data_ptr),
                            }
                        }
                    }
                    log.cardinal_log_info("Loaded {d} morph targets for primitive", .{morph_target_count});
                }
            }

            var indices: ?[*]u32 = null;
            var index_count: u32 = 0;

            if (p.indices) |ind_acc| {
                index_count = @intCast(ind_acc.*.count);
                const indices_ptr = memory.cardinal_alloc(allocator, index_count * @sizeOf(u32));
                indices = @ptrCast(@alignCast(indices_ptr));
                var ii: usize = 0;
                while (ii < index_count) : (ii += 1) {
                    var idx: u32 = 0;
                    _ = c.cgltf_accessor_read_uint(ind_acc, ii, &idx, 1);
                    indices.?[ii] = idx;
                }
            } else if (p.type == c.cgltf_primitive_type_triangles) {
                index_count = @intCast(vcount);
                const indices_ptr = memory.cardinal_alloc(allocator, index_count * @sizeOf(u32));
                indices = @ptrCast(@alignCast(indices_ptr));
                var ii: usize = 0;
                while (ii < index_count) : (ii += 1) {
                    indices.?[ii] = @intCast(ii);
                }
            }

            const dst = &meshes_safe[mesh_write];
            mesh_write += 1;
            dst.vertices = vertices;
            dst.vertex_count = @intCast(vcount);
            dst.indices = indices;
            dst.index_count = index_count;
            dst.morph_targets = morph_targets;
            dst.morph_target_count = @intCast(morph_target_count);

            if (p.material) |mat| {
                const mat_idx = (@intFromPtr(mat) - @intFromPtr(d.materials)) / @sizeOf(c.cgltf_material);
                if (mat_idx < material_count) {
                    dst.material_index = @intCast(mat_idx);
                    
                    // Debug logging for material and UVs
                    const has_uv1 = (uv1_acc != null);
                    const mat_def = &d.materials[mat_idx];
                    const tex_coord = if (mat_def.pbr_metallic_roughness.base_color_texture.texture != null) 
                        mat_def.pbr_metallic_roughness.base_color_texture.texcoord 
                    else 0;
                    
                    if (has_uv1 or tex_coord > 0) {
                        const mat_name = if (mat_def.name) |n| std.mem.span(n) else "unnamed";
                        log.cardinal_log_info("Primitive {d}: Material {d} ({s}), Has UV1: {any}, BaseColor TexCoord: {d}", .{pi, mat_idx, mat_name, has_uv1, tex_coord});
                    } else {
                        const mat_name = if (mat_def.name) |n| std.mem.span(n) else "unnamed";
                        log.cardinal_log_info("Primitive {d}: Material {d} ({s})", .{pi, mat_idx, mat_name});
                    }
                } else {
                    dst.material_index = std.math.maxInt(u32);
                }
            } else {
                dst.material_index = std.math.maxInt(u32);
            }

            dst.transform = std.mem.zeroes([16]f32);
            dst.transform[0] = 1;
            dst.transform[5] = 1;
            dst.transform[10] = 1;
            dst.transform[15] = 1;
            dst.visible = true;
        }
    }

    // Build hierarchy
    const mesh_primitive_offsets = @as([*]u32, @ptrCast(@alignCast(memory.cardinal_alloc(allocator, d.meshes_count * @sizeOf(u32)))));
    var current_offset: u32 = 0;
    mi = 0;
    while (mi < d.meshes_count) : (mi += 1) {
        mesh_primitive_offsets[mi] = current_offset;
        current_offset += @intCast(d.meshes[mi].primitives_count);
    }

    var root_nodes: ?[*]?*scene.CardinalSceneNode = null;
    var root_node_count: u32 = 0;

    if (d.nodes_count > 0) {
        out_scene.all_node_count = @intCast(d.nodes_count);
        const all_nodes_ptr = memory.cardinal_calloc(allocator, out_scene.all_node_count, @sizeOf(?*scene.CardinalSceneNode));
        out_scene.all_nodes = @ptrCast(@alignCast(all_nodes_ptr));
    }

    if (d.scene != null and d.scene.*.nodes_count > 0) {
        const scn = d.scene.*;
        root_node_count = @intCast(scn.nodes_count);
        const root_nodes_ptr = memory.cardinal_calloc(allocator, root_node_count, @sizeOf(?*scene.CardinalSceneNode));
        root_nodes = @ptrCast(@alignCast(root_nodes_ptr));
        var ni: usize = 0;
        while (ni < scn.nodes_count) : (ni += 1) {
            root_nodes.?[ni] = build_scene_node(d, scn.nodes[ni], meshes_safe, mesh_count, out_scene.all_nodes, mesh_primitive_offsets);
        }
    } else if (d.nodes_count > 0) {
        root_node_count = @intCast(d.nodes_count);
        const root_nodes_ptr = memory.cardinal_calloc(allocator, root_node_count, @sizeOf(?*scene.CardinalSceneNode));
        root_nodes = @ptrCast(@alignCast(root_nodes_ptr));
        var ni: usize = 0;
        while (ni < d.nodes_count) : (ni += 1) {
            root_nodes.?[ni] = build_scene_node(d, @ptrCast(&d.nodes[ni]), meshes_safe, mesh_count, out_scene.all_nodes, mesh_primitive_offsets);
        }
    }

    memory.cardinal_free(allocator, mesh_primitive_offsets);

    // Update transforms
    if (root_nodes) |roots| {
        var i: usize = 0;
        while (i < root_node_count) : (i += 1) {
            if (roots[i]) |root| {
                scene.cardinal_scene_node_update_transforms(root, null);
            }
        }
    }

    // Backward compatibility mesh transforms (fallback)
    if (d.scene != null and d.scene.*.nodes_count > 0) {
        var ni: usize = 0;
        while (ni < d.scene.*.nodes_count) : (ni += 1) {
            process_node(d, d.scene.*.nodes[ni], null, meshes_safe, mesh_count);
        }
    } else if (d.nodes_count > 0) {
        var ni: usize = 0;
        while (ni < d.nodes_count) : (ni += 1) {
            process_node(d, @ptrCast(&d.nodes[ni]), null, meshes_safe, mesh_count);
        }
    }

    // Animation System
    const max_animations: u32 = if (d.animations_count > 0) @intCast(d.animations_count) else 10;
    const max_skins: u32 = if (d.skins_count > 0) @intCast(d.skins_count) else 10;
    out_scene.animation_system = @ptrCast(animation.cardinal_animation_system_create(max_animations, max_skins));

    // Load Skins
    var skins: ?[*]animation.CardinalSkin = null;
    var skin_count: u32 = 0;
    if (!load_skins_from_gltf(d, &skins, &skin_count)) {
        log.cardinal_log_error("Failed to load skins", .{});
    }
    // Cast to opaque pointer for scene storage
    out_scene.skins = @ptrCast(skins);
    out_scene.skin_count = skin_count;

    // Map meshes to skins
    if (d.skins_count > 0 and root_nodes != null) {
        // Iterating all_nodes is much better
        if (out_scene.all_nodes) |all| {
            var ni: usize = 0;
            while (ni < out_scene.all_node_count) : (ni += 1) {
                if (all[ni]) |node| {
                    const gltf_node = &d.nodes[ni];
                    if (gltf_node.skin != null) {
                        const skin_idx = (@intFromPtr(gltf_node.skin) - @intFromPtr(d.skins)) / @sizeOf(c.cgltf_skin);
                        node.skin_index = @intCast(skin_idx);

                        if (skin_idx < skin_count) {
                            const skin = &skins.?[skin_idx];
                            // Add meshes to skin
                            if (node.mesh_count > 0) {
                                const new_count = skin.mesh_count + node.mesh_count;
                                const new_indices = memory.cardinal_realloc(allocator, skin.mesh_indices, new_count * @sizeOf(u32));
                                if (new_indices != null) {
                                    skin.mesh_indices = @ptrCast(@alignCast(new_indices));
                                    var m: usize = 0;
                                    while (m < node.mesh_count) : (m += 1) {
                                        skin.mesh_indices.?[skin.mesh_count + m] = node.mesh_indices.?[m];
                                    }
                                    skin.mesh_count = new_count;
                                }
                            }
                        }
                    } else {
                        node.skin_index = std.math.maxInt(u32);
                    }
                }
            }
        }
    }

    // Load Animations
    if (out_scene.animation_system) |sys| {
        if (!load_animations_from_gltf(d, @ptrCast(@alignCast(sys)))) {
            log.cardinal_log_error("Failed to load animations", .{});
        }
    }

    // Mark bone nodes
    var s: usize = 0;
    while (s < skin_count) : (s += 1) {
        const skin = &skins.?[s];
        var j: usize = 0;
        while (j < skin.bone_count) : (j += 1) {
            const joint_node_index = skin.bones.?[j].node_index;
            if (joint_node_index < out_scene.all_node_count) {
                if (out_scene.all_nodes.?[joint_node_index]) |node| {
                    node.is_bone = true;
                    node.bone_index = @intCast(j);
                    node.skin_index = @intCast(s);
                }
            }
        }
    }

    // Load Lights
    var lights: ?[*]scene.CardinalLight = null;
    var light_count: u32 = 0;
    if (!load_lights_from_gltf(d, &lights, &light_count)) {
        log.cardinal_log_error("Failed to load lights", .{});
    }
    out_scene.lights = lights;
    out_scene.light_count = light_count;

    // Map lights to nodes
    if (d.lights_count > 0 and out_scene.all_nodes != null) {
        var ni: usize = 0;
        while (ni < out_scene.all_node_count) : (ni += 1) {
            if (out_scene.all_nodes.?[ni]) |node| {
                const gltf_node = &d.nodes[ni];
                if (gltf_node.light != null) {
                    const light_idx = (@intFromPtr(gltf_node.light) - @intFromPtr(d.lights)) / @sizeOf(c.cgltf_light);
                    node.light_index = @intCast(light_idx);
                    if (light_idx < light_count) {
                        lights.?[light_idx].node_index = @intCast(ni);
                    }
                }
            }
        }
    }

    c.cgltf_free(data);

    out_scene.meshes = meshes_safe;
    out_scene.mesh_count = @intCast(mesh_write);
    out_scene.materials = materials;
    out_scene.material_count = material_count;
    out_scene.textures = textures;
    out_scene.texture_count = texture_count;
    out_scene.root_nodes = root_nodes;
    out_scene.root_node_count = root_node_count;
    out_scene.lights = lights;
    out_scene.light_count = light_count;

    return true;
}
