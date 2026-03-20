//! Asset handle registry.
//!
//! Stores assets in typed arenas addressed by stable handles (index + generation). This module
//! complements the ref-counting registry by providing lightweight handle-based lookup for engine
//! systems that prefer POD handles over string keys.
const std = @import("std");
const handles = @import("../core/handles.zig");
const handle_manager = @import("../core/handle_manager.zig");
const scene = @import("scene.zig");
const texture_loader = @import("texture_loader.zig");
const memory = @import("../core/memory.zig");
const log = @import("../core/log.zig");
const ref_counting = @import("../core/ref_counting.zig");

const asset_log = log.ScopedLogger("ASSET_MGR");

pub const AssetType = enum {
    /// Image data loaded from disk and uploaded by the renderer.
    Texture,
    /// Mesh geometry loaded from disk or generated at runtime.
    Mesh,
    /// Material parameter blocks and texture bindings.
    Material,
    /// Shader bytecode or source used by the renderer.
    Shader,
    /// Audio sample data.
    Sound,
};

/// Generic typed storage indexed by a handle manager.
fn AssetStorage(comptime T: type, comptime Handle: type) type {
    return struct {
        const Self = @This();
        const has_ref_resource = @hasField(T, "ref_resource");

        const Entry = struct {
            data: T,
            ref_count: u32,
            path: ?[]const u8,
        };

        entries: std.ArrayListUnmanaged(Entry),
        handle_manager: handle_manager.HandleManager,
        allocator: std.mem.Allocator,

        /// Initializes storage for `T` using `allocator`.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .entries = .{},
                .handle_manager = handle_manager.HandleManager.init(allocator),
                .allocator = allocator,
            };
        }

        /// Frees stored path strings and releases internal storage.
        pub fn deinit(self: *Self) void {
            for (self.entries.items) |*entry| {
                if (has_ref_resource) {
                    if (entry.data.ref_resource) |ref| {
                        var i: u32 = 0;
                        while (i < entry.ref_count) : (i += 1) {
                            ref_counting.cardinal_ref_release(ref);
                        }
                        entry.data.ref_resource = null;
                    }
                }
                if (entry.path) |p| {
                    self.allocator.free(p);
                }
            }
            self.entries.deinit(self.allocator);
            self.handle_manager.deinit();
        }

        pub const AddResult = struct {
            handle: Handle,
            stored_path: ?[]const u8,
        };

        /// Adds an entry and returns its new handle.
        pub fn add(self: *Self, data: T, path: ?[]const u8) !AddResult {
            var stored_path: ?[]const u8 = null;

            if (path) |p| {
                stored_path = try self.allocator.dupe(u8, p);
            }

            const allocation = try self.handle_manager.allocate();
            const index = allocation.index;
            const generation = allocation.generation;

            const new_entry: Entry = .{ .data = data, .ref_count = 1, .path = stored_path };

            if (index < self.entries.items.len) {
                self.entries.items[index] = new_entry;
            } else {
                try self.entries.append(self.allocator, new_entry);
            }

            return AddResult{
                .handle = Handle{ .index = index, .generation = generation },
                .stored_path = stored_path,
            };
        }

        /// Returns a mutable pointer to the entry for `handle` if valid.
        pub fn get(self: *Self, handle: Handle) ?*T {
            if (!self.handle_manager.is_valid(handle.index, handle.generation)) return null;
            if (handle.index >= self.entries.items.len) return null;
            return &self.entries.items[handle.index].data;
        }

        pub const ReleaseResult = struct {
            destroyed: bool,
            path: ?[]const u8,
            data: ?T,
        };

        /// Releases a reference to `handle` and returns whether it was destroyed.
        pub fn release(self: *Self, handle: Handle) ReleaseResult {
            if (!self.handle_manager.is_valid(handle.index, handle.generation)) return .{ .destroyed = false, .path = null, .data = null };
            if (handle.index >= self.entries.items.len) return .{ .destroyed = false, .path = null, .data = null };

            var entry = &self.entries.items[handle.index];
            if (entry.ref_count > 0) {
                entry.ref_count -= 1;
            }

            if (has_ref_resource) {
                if (entry.data.ref_resource) |ref| {
                    ref_counting.cardinal_ref_release(ref);
                }
            }

            if (entry.ref_count == 0) {
                const p = entry.path;
                var d = entry.data;
                entry.path = null;

                _ = self.handle_manager.free(handle.index, handle.generation);

                if (has_ref_resource) {
                    if (d.ref_resource != null) {
                        d.ref_resource = null;
                    }
                }

                return .{ .destroyed = true, .path = p, .data = d };
            }
            return .{ .destroyed = false, .path = null, .data = null };
        }

        /// Acquires a new reference to `handle` if valid.
        pub fn acquire(self: *Self, handle: Handle) void {
            if (!self.handle_manager.is_valid(handle.index, handle.generation)) return;
            if (handle.index >= self.entries.items.len) return;
            var entry = &self.entries.items[handle.index];
            entry.ref_count += 1;
            if (has_ref_resource) {
                if (entry.data.ref_resource) |ref| {
                    _ = @atomicRmw(u32, &ref.ref_count, .Add, 1, .seq_cst);
                }
            }
        }
    };
}

pub const AssetManager = struct {
    allocator: std.mem.Allocator,

    textures: AssetStorage(scene.CardinalTexture, handles.TextureHandle),
    meshes: AssetStorage(scene.CardinalMesh, handles.MeshHandle),
    materials: AssetStorage(scene.CardinalMaterial, handles.MaterialHandle),

    texture_path_map: std.StringHashMapUnmanaged(handles.TextureHandle),
    mesh_path_map: std.StringHashMapUnmanaged(handles.MeshHandle),
    material_path_map: std.StringHashMapUnmanaged(handles.MaterialHandle),

    /// Creates a new manager using `allocator` for all internal allocations.
    pub fn init(allocator: std.mem.Allocator) AssetManager {
        return .{
            .allocator = allocator,
            .textures = AssetStorage(scene.CardinalTexture, handles.TextureHandle).init(allocator),
            .meshes = AssetStorage(scene.CardinalMesh, handles.MeshHandle).init(allocator),
            .materials = AssetStorage(scene.CardinalMaterial, handles.MaterialHandle).init(allocator),
            .texture_path_map = .{},
            .mesh_path_map = .{},
            .material_path_map = .{},
        };
    }

    /// Releases all managed assets and internal lookup tables.
    pub fn deinit(self: *AssetManager) void {
        self.textures.deinit();
        self.meshes.deinit();
        self.materials.deinit();
        self.texture_path_map.deinit(self.allocator);
        self.mesh_path_map.deinit(self.allocator);
        self.material_path_map.deinit(self.allocator);
    }

    /// Loads a texture from `path`, returning a stable handle.
    pub fn loadTexture(self: *AssetManager, path: []const u8) !handles.TextureHandle {
        if (self.texture_path_map.get(path)) |handle| {
            self.textures.acquire(handle);
            return handle;
        }

        var texture = std.mem.zeroes(scene.CardinalTexture);
        const path_z = try self.allocator.dupeZ(u8, path);

        var temp_data = std.mem.zeroes(texture_loader.TextureData);
        const res = texture_loader.texture_load_with_ref_counting(@ptrCast(path_z), &temp_data);

        if (res == null) {
            self.allocator.free(path_z);
            return error.FailedToLoadTexture;
        }

        texture.data = temp_data.data;
        texture.width = temp_data.width;
        texture.height = temp_data.height;
        texture.channels = temp_data.channels;
        texture.is_hdr = temp_data.is_hdr;
        texture.ref_resource = res;
        texture.path = path_z;

        const add_res = try self.textures.add(texture, path);
        if (add_res.stored_path) |p| {
            try self.texture_path_map.put(self.allocator, p, add_res.handle);
        } else {
            try self.texture_path_map.put(self.allocator, path, add_res.handle);
        }

        asset_log.info("Loaded texture: {s} -> Handle({d}, {d})", .{ path, add_res.handle.index, add_res.handle.generation });
        return add_res.handle;
    }

    /// Returns a mutable texture pointer for `handle` if still valid.
    pub fn getTexture(self: *AssetManager, handle: handles.TextureHandle) ?*scene.CardinalTexture {
        return self.textures.get(handle);
    }

    /// Returns a texture by path if it has been loaded and not destroyed.
    pub fn findTexture(self: *AssetManager, path: []const u8) ?*scene.CardinalTexture {
        if (self.texture_path_map.get(path)) |handle| {
            return self.textures.get(handle);
        }
        return null;
    }

    /// Releases a texture handle reference and unloads it when the count hits zero.
    pub fn releaseTexture(self: *AssetManager, handle: handles.TextureHandle) void {
        const res = self.textures.release(handle);
        if (res.destroyed) {
            if (res.data) |tex| {
                if (tex.path) |p| {
                    self.allocator.free(std.mem.span(p));
                }
            }

            if (res.path) |p| {
                if (self.texture_path_map.fetchRemove(p)) |kv| {
                    self.allocator.free(kv.key);
                } else {
                    self.allocator.free(p);
                }
            }
        }
    }

    /// Adds a mesh and optionally registers it under `path` for handle reuse.
    pub fn addMesh(self: *AssetManager, mesh: scene.CardinalMesh, path: ?[]const u8) !handles.MeshHandle {
        if (path) |p| {
            if (self.mesh_path_map.get(p)) |handle| {
                self.meshes.acquire(handle);
                return handle;
            }
        }

        const add_res = try self.meshes.add(mesh, path);
        if (add_res.stored_path) |p| {
            try self.mesh_path_map.put(self.allocator, p, add_res.handle);
        } else if (path) |p| {
            try self.mesh_path_map.put(self.allocator, p, add_res.handle);
        }
        return add_res.handle;
    }

    /// Returns a mutable mesh pointer for `handle` if still valid.
    pub fn getMesh(self: *AssetManager, handle: handles.MeshHandle) ?*scene.CardinalMesh {
        return self.meshes.get(handle);
    }

    /// Returns a mesh by path if it has been added and not destroyed.
    pub fn findMesh(self: *AssetManager, path: []const u8) ?*scene.CardinalMesh {
        if (self.mesh_path_map.get(path)) |handle| {
            return self.meshes.get(handle);
        }
        return null;
    }

    /// Releases a mesh handle reference and removes its path mapping when destroyed.
    pub fn releaseMesh(self: *AssetManager, handle: handles.MeshHandle) void {
        const res = self.meshes.release(handle);
        if (res.destroyed) {
            if (res.path) |p| {
                if (self.mesh_path_map.fetchRemove(p)) |kv| {
                    self.allocator.free(kv.key);
                } else {
                    self.allocator.free(p);
                }
            }
        }
    }

    /// Adds a material and optionally registers it under `path` for handle reuse.
    pub fn addMaterial(self: *AssetManager, material: scene.CardinalMaterial, path: ?[]const u8) !handles.MaterialHandle {
        if (path) |p| {
            if (self.material_path_map.get(p)) |handle| {
                self.materials.acquire(handle);
                return handle;
            }
        }

        const add_res = try self.materials.add(material, path);
        if (add_res.stored_path) |p| {
            try self.material_path_map.put(self.allocator, p, add_res.handle);
        } else if (path) |p| {
            try self.material_path_map.put(self.allocator, p, add_res.handle);
        }
        return add_res.handle;
    }

    /// Returns a mutable material pointer for `handle` if still valid.
    pub fn getMaterial(self: *AssetManager, handle: handles.MaterialHandle) ?*scene.CardinalMaterial {
        return self.materials.get(handle);
    }

    /// Returns a material by path if it has been added and not destroyed.
    pub fn findMaterial(self: *AssetManager, path: []const u8) ?*scene.CardinalMaterial {
        if (self.material_path_map.get(path)) |handle| {
            return self.materials.get(handle);
        }
        return null;
    }

    /// Releases a material handle reference and removes its path mapping when destroyed.
    pub fn releaseMaterial(self: *AssetManager, handle: handles.MaterialHandle) void {
        const res = self.materials.release(handle);
        if (res.destroyed) {
            if (res.path) |p| {
                if (self.material_path_map.fetchRemove(p)) |kv| {
                    self.allocator.free(kv.key);
                } else {
                    self.allocator.free(p);
                }
            }
        }
    }
};

const Allocator = std.mem.Allocator;

fn cardinalAlloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self = @as(*memory.CardinalAllocator, @ptrCast(@alignCast(ctx)));
    const align_val = ptr_align.toByteUnits();
    const ptr = self.alloc(self, len, align_val);
    return @as(?[*]u8, @ptrCast(ptr));
}

/// TODO: Implement resize support for better interop with std containers.
fn cardinalResize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = buf;
    _ = buf_align;
    _ = new_len;
    _ = ret_addr;
    return false;
}

fn cardinalFree(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
    _ = buf_align;
    _ = ret_addr;
    const self = @as(*memory.CardinalAllocator, @ptrCast(@alignCast(ctx)));
    self.free(self, @ptrCast(buf.ptr));
}

/// TODO: Implement remap support for better interop with std containers.
fn cardinalRemap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = buf;
    _ = buf_align;
    _ = new_len;
    _ = ret_addr;
    return null;
}

const cardinal_vtable = Allocator.VTable{
    .alloc = cardinalAlloc,
    .resize = cardinalResize,
    .free = cardinalFree,
    .remap = cardinalRemap,
};

/// Wraps a `CardinalAllocator` as a `std.mem.Allocator`.
pub fn toStdAllocator(allocator: *memory.CardinalAllocator) Allocator {
    return .{
        .ptr = allocator,
        .vtable = &cardinal_vtable,
    };
}

/// Global singleton instance used by the engine-facing convenience API.
var g_asset_manager: AssetManager = undefined;
var g_initialized: bool = false;

/// Initializes the global asset manager using the `.ASSETS` allocator category.
pub fn init() !void {
    if (g_initialized) return;
    const allocator_ptr = memory.cardinal_get_allocator_for_category(.ASSETS);
    const allocator = toStdAllocator(allocator_ptr);
    g_asset_manager = AssetManager.init(allocator);
    g_initialized = true;
    asset_log.info("Asset Manager initialized", .{});
}

/// Shuts down and frees the global asset manager.
pub fn shutdown() void {
    if (!g_initialized) return;
    g_asset_manager.deinit();
    g_initialized = false;
}

/// Returns a pointer to the global asset manager (must be initialized first).
pub fn get() *AssetManager {
    return &g_asset_manager;
}
