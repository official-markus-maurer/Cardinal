const std = @import("std");
const handles = @import("../core/handles.zig");
const scene = @import("scene.zig");
const texture_loader = @import("texture_loader.zig");
const memory = @import("../core/memory.zig");
const log = @import("../core/log.zig");

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
            generation: u32,
            ref_count: u32,
            path: ?[]const u8,
        };

        entries: std.ArrayListUnmanaged(Entry),
        free_indices: std.ArrayListUnmanaged(u32),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .entries = .{},
                .free_indices = .{},
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
            self.free_indices.deinit(self.allocator);
        }
        
        pub fn add(self: *Self, data: T, path: ?[]const u8) !Handle {
            var index: u32 = 0;
            var generation: u32 = 1;
            
            if (self.free_indices.items.len > 0) {
                index = self.free_indices.pop();
                generation = self.entries.items[index].generation + 1;
                // Avoid 0 generation
                if (generation == 0) generation = 1;
                
                self.entries.items[index] = .{
                    .data = data,
                    .generation = generation,
                    .ref_count = 1,
                    .path = if (path) |p| try self.allocator.dupe(u8, p) else null,
                };
            } else {
                index = @intCast(self.entries.items.len);
                try self.entries.append(self.allocator, .{
                    .data = data,
                    .generation = generation,
                    .ref_count = 1,
                    .path = if (path) |p| try self.allocator.dupe(u8, p) else null,
                });
            }
            
            return Handle{ .index = index, .generation = generation };
        }

        pub fn get(self: *Self, handle: Handle) ?*T {
            if (handle.index >= self.entries.items.len) return null;
            const entry = &self.entries.items[handle.index];
            if (entry.generation != handle.generation) return null;
            return &entry.data;
        }

        pub fn release(self: *Self, handle: Handle) bool {
            if (handle.index >= self.entries.items.len) return false;
            var entry = &self.entries.items[handle.index];
            if (entry.generation != handle.generation) return false;
            
            if (entry.ref_count > 0) {
                entry.ref_count -= 1;
            }
            
            if (entry.ref_count == 0) {
                // Free path
                if (entry.path) |p| {
                    self.allocator.free(p);
                    entry.path = null;
                }
                
                // Add to free list
                self.free_indices.append(self.allocator, handle.index) catch {};
                return true; // Resource destroyed
            }
            return false;
        }
        
        pub fn acquire(self: *Self, handle: Handle) void {
             if (handle.index >= self.entries.items.len) return;
             var entry = &self.entries.items[handle.index];
             if (entry.generation != handle.generation) return;
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
        
        // Use the existing C-based loading function
        if (!texture_loader.texture_load_from_file(@ptrCast(path_z), @ptrCast(&texture))) {
            self.allocator.free(path_z);
            return error.FailedToLoadTexture;
        }
        
        texture.path = path_z;
        
        const handle = try self.textures.add(texture, path);
        try self.texture_path_map.put(self.allocator, path, handle);
        
        asset_log.info("Loaded texture: {s} -> Handle({d}, {d})", .{path, handle.index, handle.generation});
        return handle;
    }
    
    pub fn getTexture(self: *AssetManager, handle: handles.TextureHandle) ?*scene.CardinalTexture {
        return self.textures.get(handle);
    }
    
    pub fn releaseTexture(self: *AssetManager, handle: handles.TextureHandle) void {
        if (self.textures.release(handle)) {
             // TODO: Remove from path map.
             // Currently the path string is freed by AssetStorage so we can't easily lookup the key to remove it.
             // Need a way to retrieve the path before deletion or store a reverse mapping.
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
    _ = ctx; _ = buf; _ = buf_align; _ = new_len; _ = ret_addr;
    return false;
}

fn cardinalFree(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
    _ = buf_align; _ = ret_addr;
    const self = @as(*memory.CardinalAllocator, @ptrCast(@alignCast(ctx)));
    self.free(self, @ptrCast(buf.ptr));
}

fn cardinalRemap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx; _ = buf; _ = buf_align; _ = new_len; _ = ret_addr;
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
