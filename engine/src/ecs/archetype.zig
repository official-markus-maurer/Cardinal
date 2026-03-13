//! Archetype-based ECS storage.
//!
//! Provides an experimental archetype/chunk storage model as an alternative to sparse sets.
//! This is not currently integrated with `Registry` and is primarily a prototype.
//!
//! TODO: Either integrate this with `Registry` or move it into a separate experimental package.
const std = @import("std");
const entity_pkg = @import("entity.zig");

const Entity = entity_pkg.Entity;

/// Unique identifier for an archetype (hash of sorted component type IDs).
pub const ArchetypeId = u64;

/// Component type identifier used by the archetype storage.
pub const ComponentTypeId = u64;

/// Chunk of entities for a specific archetype, storing components in SoA form.
pub const Chunk = struct {
    /// Raw component storage keyed by component type ID.
    components: std.AutoHashMapUnmanaged(ComponentTypeId, []u8),
    /// Number of live rows in the chunk.
    count: usize,
    /// Maximum rows the chunk can store before growing/allocating another chunk.
    capacity: usize,

    allocator: std.mem.Allocator,

    /// TODO: Consider a fixed byte-size chunk (e.g. 16KiB) for better locality.
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
                entry.value_ptr.* = try self.allocator.alloc(u8, size * self.capacity);
            }
        }
    }
};

/// Archetype definition and its chunk list.
pub const Archetype = struct {
    id: ArchetypeId,
    /// Sorted component type IDs defining the archetype signature.
    types: []const ComponentTypeId,
    /// Parallel array of component sizes (in bytes).
    type_sizes: []const usize,
    /// Parallel array of component alignments (in bytes).
    type_alignments: []const u16,

    chunks: std.ArrayListUnmanaged(Chunk),

    /// Transition edges for adding/removing a component: `ComponentTypeId -> ArchetypeId`.
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
        for (self.chunks.items, 0..) |*chunk, i| {
            if (chunk.count < chunk.capacity) {
                return .{ .chunk = chunk, .chunk_index = i, .row_index = chunk.count };
            }
        }

        const default_chunk_capacity = 1024;
        var new_chunk = Chunk.init(self.allocator, default_chunk_capacity);
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

    /// Computes an `ArchetypeId` from an already-sorted list of component type IDs.
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
