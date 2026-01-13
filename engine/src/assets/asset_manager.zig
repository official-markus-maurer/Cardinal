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
    Texture,
    Mesh,
    Material,
    Shader,
    Sound,
};

// Generic storage for assets
fn AssetStorage(comptime T: type, comptime Handle: type) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            data: T,
            ref_count: u32,
            path: ?[]const u8,
        };

        entries: std.ArrayListUnmanaged(Entry),
        handle_manager: handle_manager.HandleManager,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .entries = .{},
                .handle_manager = handle_manager.HandleManager.init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Cleanup entries
            for (self.entries.items) |*entry| {
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

        pub fn add(self: *Self, data: T, path: ?[]const u8) !AddResult {
            var stored_path: ?[]const u8 = null;

            if (path) |p| {
                stored_path = try self.allocator.dupe(u8, p);
            }

            const allocation = try self.handle_manager.allocate();
            const index = allocation.index;
            const generation = allocation.generation;

            if (index < self.entries.items.len) {
                // Reuse existing slot
                self.entries.items[index] = .{
                    .data = data,
                    .ref_count = 1,
                    .path = stored_path,
                };
            } else {
                // Append new slot
                try self.entries.append(self.allocator, .{
                    .data = data,
                    .ref_count = 1,
                    .path = stored_path,
                });
            }

            return AddResult{
                .handle = Handle{ .index = index, .generation = generation },
                .stored_path = stored_path,
            };
        }

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

        pub fn release(self: *Self, handle: Handle) ReleaseResult {
            if (!self.handle_manager.is_valid(handle.index, handle.generation)) return .{ .destroyed = false, .path = null, .data = null };
            if (handle.index >= self.entries.items.len) return .{ .destroyed = false, .path = null, .data = null };
            
            var entry = &self.entries.items[handle.index];
            
            if (entry.ref_count > 0) {
                entry.ref_count -= 1;
            }

            if (entry.ref_count == 0) {
                // Detach path (ownership transfer to caller)
                const p = entry.path;
                const d = entry.data;
                entry.path = null;

                // Add to free list
                _ = self.handle_manager.free(handle.index, handle.generation);
                return .{ .destroyed = true, .path = p, .data = d };
            }
            return .{ .destroyed = false, .path = null, .data = null };
        }

        pub fn acquire(self: *Self, handle: Handle) void {
            if (!self.handle_manager.is_valid(handle.index, handle.generation)) return;
            if (handle.index >= self.entries.items.len) return;
            var entry = &self.entries.items[handle.index];
            entry.ref_count += 1;
        }
    };
}

pub const AssetManager = struct {
    allocator: std.mem.Allocator,

    textures: AssetStorage(scene.CardinalTexture, handles.TextureHandle),
    meshes: AssetStorage(scene.CardinalMesh, handles.MeshHandle),
    materials: AssetStorage(scene.CardinalMaterial, handles.MaterialHandle),

    // Map path to handle
    texture_path_map: std.StringHashMapUnmanaged(handles.TextureHandle),

    pub fn init(allocator: std.mem.Allocator) AssetManager {
        return .{
            .allocator = allocator,
            .textures = AssetStorage(scene.CardinalTexture, handles.TextureHandle).init(allocator),
            .meshes = AssetStorage(scene.CardinalMesh, handles.MeshHandle).init(allocator),
            .materials = AssetStorage(scene.CardinalMaterial, handles.MaterialHandle).init(allocator),
            .texture_path_map = .{},
        };
    }

    pub fn deinit(self: *AssetManager) void {
        self.textures.deinit();
        self.meshes.deinit();
        self.materials.deinit();
        self.texture_path_map.deinit(self.allocator);
    }

    pub fn loadTexture(self: *AssetManager, path: []const u8) !handles.TextureHandle {
        if (self.texture_path_map.get(path)) |handle| {
            self.textures.acquire(handle);
            return handle;
        }

        var texture = std.mem.zeroes(scene.CardinalTexture);
        const path_z = try self.allocator.dupeZ(u8, path);

        // Use the async ref-counted loading function
        var temp_data = std.mem.zeroes(texture_loader.TextureData);
        const res = texture_loader.texture_load_with_ref_counting(@ptrCast(path_z), &temp_data);

        if (res == null) {
            self.allocator.free(path_z);
            return error.FailedToLoadTexture;
        }

        // Copy initial data (placeholder or loaded)
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

    pub fn getTexture(self: *AssetManager, handle: handles.TextureHandle) ?*scene.CardinalTexture {
        return self.textures.get(handle);
    }

    pub fn findTexture(self: *AssetManager, path: []const u8) ?*scene.CardinalTexture {
        if (self.texture_path_map.get(path)) |handle| {
            return self.textures.get(handle);
        }
        return null;
    }

    pub fn releaseTexture(self: *AssetManager, handle: handles.TextureHandle) void {
        const res = self.textures.release(handle);
        if (res.destroyed) {
            if (res.data) |tex| {
                if (tex.path) |p| {
                    // Free the path allocated by dupeZ
                    self.allocator.free(std.mem.span(p));
                }
                if (tex.ref_resource) |ref| {
                    const r: *ref_counting.CardinalRefCountedResource = @ptrCast(@alignCast(ref));
                    _ = ref_counting.cardinal_ref_release(r);
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
};

const Allocator = std.mem.Allocator;

fn cardinalAlloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self = @as(*memory.CardinalAllocator, @ptrCast(@alignCast(ctx)));
    const align_val = ptr_align.toByteUnits();
    const ptr = self.alloc(self, len, align_val);
    return @as(?[*]u8, @ptrCast(ptr));
}

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

pub fn toStdAllocator(allocator: *memory.CardinalAllocator) Allocator {
    return .{
        .ptr = allocator,
        .vtable = &cardinal_vtable,
    };
}

// Global instance
var g_asset_manager: AssetManager = undefined;
var g_initialized: bool = false;

pub fn init() !void {
    if (g_initialized) return;
    const allocator_ptr = memory.cardinal_get_allocator_for_category(.ASSETS);
    const allocator = toStdAllocator(allocator_ptr);
    g_asset_manager = AssetManager.init(allocator);
    g_initialized = true;
    asset_log.info("Asset Manager initialized", .{});
}

pub fn shutdown() void {
    if (!g_initialized) return;
    g_asset_manager.deinit();
    g_initialized = false;
}

pub fn get() *AssetManager {
    return &g_asset_manager;
}
