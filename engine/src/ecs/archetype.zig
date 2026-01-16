const std = @import("std");
const entity_pkg = @import("entity.zig");

const Entity = entity_pkg.Entity;

// A unique identifier for a set of components (Archetype)
// For simplicity, we can use a hash of sorted component type IDs.
pub const ArchetypeId = u64;

pub const ComponentTypeId = u64;

pub const Chunk = struct {
    // Capacity could be dynamic or fixed. 
    // For cache locality, fixed size (e.g. 16KB) is common, 
    // but simplified implementation might use ArrayLists.
    // Let's use SoA (Structure of Arrays) via type-erased ArrayLists.
    
    // Map ComponentTypeID -> []u8 (raw bytes)
    // We need to know the size of each component to index correctly.
    components: std.AutoHashMapUnmanaged(ComponentTypeId, []u8),
    count: usize,
    capacity: usize,
    
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) Chunk {
        return .{
            .components = .{},
            .count = 0,
            .capacity = capacity,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Chunk) void {
        var it = self.components.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.components.deinit(self.allocator);
    }

    pub fn ensure_capacity(self: *Chunk, types: []const ComponentTypeId, sizes: []const usize) !void {
        for (types, sizes) |id, size| {
            const entry = try self.components.getOrPut(self.allocator, id);
            if (!entry.found_existing) {
                // Allocate initial capacity
                entry.value_ptr.* = try self.allocator.alloc(u8, size * self.capacity);
            }
        }
    }
};

pub const Archetype = struct {
    id: ArchetypeId,
    types: []const ComponentTypeId, // Sorted
    type_sizes: []const usize,      // Parallel array
    type_alignments: []const u16,   // Parallel array
    
    chunks: std.ArrayListUnmanaged(Chunk),
    
    // Edges for graph traversal (add/remove component)
    // ComponentID -> ArchetypeID
    edges: std.AutoHashMapUnmanaged(ComponentTypeId, ArchetypeId),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: ArchetypeId, types: []const ComponentTypeId, sizes: []const usize, alignments: []const u16) !Archetype {
        const types_copy = try allocator.dupe(ComponentTypeId, types);
        const sizes_copy = try allocator.dupe(usize, sizes);
        const alignments_copy = try allocator.dupe(u16, alignments);

        return .{
            .id = id,
            .types = types_copy,
            .type_sizes = sizes_copy,
            .type_alignments = alignments_copy,
            .chunks = .{},
            .edges = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Archetype) void {
        self.allocator.free(self.types);
        self.allocator.free(self.type_sizes);
        self.allocator.free(self.type_alignments);
        
        for (self.chunks.items) |*chunk| {
            chunk.deinit();
        }
        self.chunks.deinit(self.allocator);
        self.edges.deinit(self.allocator);
    }
    
    pub fn get_chunk_for_new_entity(self: *Archetype) !struct { chunk: *Chunk, chunk_index: usize, row_index: usize } {
        // Find a chunk with space
        for (self.chunks.items, 0..) |*chunk, i| {
            if (chunk.count < chunk.capacity) {
                return .{ .chunk = chunk, .chunk_index = i, .row_index = chunk.count };
            }
        }
        
        // Create new chunk
        var new_chunk = Chunk.init(self.allocator, 1024); // Default capacity
        try new_chunk.ensure_capacity(self.types, self.type_sizes);
        try self.chunks.append(self.allocator, new_chunk);
        
        const chunk_index = self.chunks.items.len - 1;
        const chunk = &self.chunks.items[chunk_index];
        return .{ .chunk = chunk, .chunk_index = chunk_index, .row_index = 0 };
    }
};

pub const ArchetypeStorage = struct {
    archetypes: std.AutoHashMapUnmanaged(ArchetypeId, *Archetype),
    entity_index: std.AutoHashMapUnmanaged(Entity, EntityRecord),
    
    allocator: std.mem.Allocator,

    const EntityRecord = struct {
        archetype: *Archetype,
        chunk_index: usize,
        row_index: usize,
    };

    pub fn init(allocator: std.mem.Allocator) ArchetypeStorage {
        return .{
            .archetypes = .{},
            .entity_index = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ArchetypeStorage) void {
        var it = self.archetypes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.archetypes.deinit(self.allocator);
        self.entity_index.deinit(self.allocator);
    }

    // Helper to calculate Archetype ID from sorted types
    pub fn calculate_id(types: []const ComponentTypeId) ArchetypeId {
        var hasher = std.hash.Wyhash.init(0);
        for (types) |t| {
            hasher.update(std.mem.asBytes(&t));
        }
        return hasher.final();
    }

    pub fn get_or_create_archetype(self: *ArchetypeStorage, types: []const ComponentTypeId, sizes: []const usize, alignments: []const u16) !*Archetype {
        const id = calculate_id(types);
        if (self.archetypes.get(id)) |arch| {
            return arch;
        }

        const arch = try self.allocator.create(Archetype);
        arch.* = try Archetype.init(self.allocator, id, types, sizes, alignments);
        try self.archetypes.put(self.allocator, id, arch);
        return arch;
    }
};
