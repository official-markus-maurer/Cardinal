//! Archetype-based ECS storage.
//!
//! Provides an archetype/chunk storage model as an alternative to sparse sets.
const std = @import("std");
const entity_pkg = @import("entity.zig");

const Entity = entity_pkg.Entity;

pub const ArchetypeId = u64;
pub const ComponentTypeId = u64;

pub const Chunk = struct {
    components: std.AutoHashMapUnmanaged(ComponentTypeId, []u8),
    count: usize,
    capacity: usize,
    allocator: std.mem.Allocator,
    storage: []u8,

    const default_chunk_bytes: usize = 16 * 1024;

    pub fn init(allocator: std.mem.Allocator, types: []const ComponentTypeId, sizes: []const usize, alignments: []const u16) !Chunk {
        const cap = compute_capacity(default_chunk_bytes, sizes, alignments);
        const required = bytes_needed_for_capacity(cap, sizes, alignments);
        const bytes = @max(default_chunk_bytes, required);

        var storage = try allocator.alloc(u8, bytes);
        @memset(storage, 0);

        var chunk = Chunk{
            .components = .{},
            .count = 0,
            .capacity = cap,
            .allocator = allocator,
            .storage = storage,
        };

        var offset: usize = 0;
        for (types, sizes, alignments) |id, size, alignment_u16| {
            const alignment: usize = if (alignment_u16 == 0) 1 else @as(usize, alignment_u16);
            offset = std.mem.alignForward(usize, offset, alignment);
            const slice_len = size * cap;
            if (offset + slice_len > storage.len) return error.OutOfMemory;
            const slice = storage[offset .. offset + slice_len];
            offset += slice_len;

            const entry = try chunk.components.getOrPut(allocator, id);
            entry.value_ptr.* = slice;
        }

        return chunk;
    }

    pub fn deinit(self: *Chunk) void {
        self.components.deinit(self.allocator);
        self.allocator.free(self.storage);
    }

    fn bytes_needed_for_capacity(capacity: usize, sizes: []const usize, alignments: []const u16) usize {
        var offset: usize = 0;
        for (sizes, alignments) |size, alignment_u16| {
            const alignment: usize = if (alignment_u16 == 0) 1 else @as(usize, alignment_u16);
            offset = std.mem.alignForward(usize, offset, alignment);
            offset += size * capacity;
        }
        return offset;
    }

    fn compute_capacity(chunk_bytes: usize, sizes: []const usize, alignments: []const u16) usize {
        if (sizes.len == 0) return 0;

        if (bytes_needed_for_capacity(1, sizes, alignments) > chunk_bytes) return 1;

        var bytes_per_entity: usize = 0;
        for (sizes) |s| bytes_per_entity += s;
        if (bytes_per_entity == 0) return 1;

        var low: usize = 1;
        var high: usize = @max(@as(usize, 1), chunk_bytes / bytes_per_entity);

        while (low < high) {
            const mid = (low + high + 1) / 2;
            if (bytes_needed_for_capacity(mid, sizes, alignments) <= chunk_bytes) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        return low;
    }
};

pub const Archetype = struct {
    id: ArchetypeId,
    types: []const ComponentTypeId,
    type_sizes: []const usize,
    type_alignments: []const u16,
    chunks: std.ArrayListUnmanaged(Chunk),
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

        const new_chunk = try Chunk.init(self.allocator, self.types, self.type_sizes, self.type_alignments);
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
