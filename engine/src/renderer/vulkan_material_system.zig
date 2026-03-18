//! Material layout and instance helpers.
//!
//! Provides a lightweight material system with JSON-driven layouts, per-instance parameter
//! storage (push constants), and a small C-ABI surface for tooling.
const std = @import("std");
const c = @import("vulkan_c.zig").c;
const types = @import("vulkan_types.zig");
const memory = @import("../core/memory.zig");
const log = @import("../core/log.zig");
const handles = @import("../core/handles.zig");

const material_log = log.ScopedLogger("MATERIAL_SYSTEM");

fn hash_string(str: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (str) |byte| {
        hash ^= byte;
        hash *%= 16777619;
    }
    return hash;
}

/// Material parameter value kinds supported by the runtime.
pub const MaterialPropertyType = enum {
    Float,
    Vec2,
    Vec3,
    Vec4,
    Int,
    UInt,
    Bool,
    Matrix4,
    Texture2D,
    TextureCube,
};

/// Describes a single named property in a material layout.
pub const MaterialPropertyDescriptor = struct {
    name: []const u8,
    type: MaterialPropertyType,
    /// Byte offset inside the instance data buffer.
    offset: u32,
    /// Descriptor binding for textures (if bound via descriptor sets).
    binding: u32 = 0,
    /// Size in bytes for validation when setting values.
    size: u32,
};

/// Declares the set of properties and binding metadata for a material.
pub const MaterialLayoutDescriptor = struct {
    name: []const u8,
    properties: []const MaterialPropertyDescriptor,
    push_constant_size: u32,
    /// Optional descriptor-set layout for texture/material bindings.
    descriptor_set_layout: c.VkDescriptorSetLayout,
    property_hashes: ?[]u32 = null,
};

/// One material instance bound to a pipeline and layout.
pub const MaterialInstance = struct {
    layout: *const MaterialLayoutDescriptor,
    /// CPU-side storage for push constants or small uniform blocks.
    data: []u8,
    textures: std.AutoHashMap(u32, handles.TextureHandle),

    /// Vulkan pipeline used by the instance (owned externally).
    pipeline: c.VkPipeline,
    /// Pipeline layout used for push constants and bindings (owned externally).
    pipeline_layout: c.VkPipelineLayout,
};

/// Stores registered layouts and creates/destroys material instances.
pub const MaterialSystem = struct {
    allocator: std.mem.Allocator,
    layouts: std.StringHashMap(MaterialLayoutDescriptor),

    /// Initializes an empty material system.
    pub fn init(allocator: std.mem.Allocator) MaterialSystem {
        return .{
            .allocator = allocator,
            .layouts = std.StringHashMap(MaterialLayoutDescriptor).init(allocator),
        };
    }

    /// Releases registered layout storage.
    pub fn deinit(self: *MaterialSystem) void {
        var it = self.layouts.iterator();
        while (it.next()) |entry| {
            // TODO: Track ownership for layout names, property arrays, and hash buffers.
            self.allocator.free(entry.value_ptr.properties);
            if (entry.value_ptr.property_hashes) |hashes| {
                self.allocator.free(hashes);
            }
        }
        self.layouts.deinit();
    }

    /// Registers a layout and precomputes property hashes for faster lookups.
    pub fn register_layout(self: *MaterialSystem, name: []const u8, descriptor: MaterialLayoutDescriptor) !void {
        const props_copy = try self.allocator.alloc(MaterialPropertyDescriptor, descriptor.properties.len);
        @memcpy(props_copy, descriptor.properties);

        var new_desc = descriptor;
        new_desc.properties = props_copy;
        if (descriptor.properties.len > 0) {
            const hashes = try self.allocator.alloc(u32, descriptor.properties.len);
            var i: usize = 0;
            while (i < descriptor.properties.len) : (i += 1) {
                hashes[i] = hash_string(descriptor.properties[i].name);
            }
            new_desc.property_hashes = hashes;
        } else {
            new_desc.property_hashes = null;
        }

        try self.layouts.put(name, new_desc);
        material_log.info("Registered material layout '{s}' with {d} properties", .{ name, descriptor.properties.len });
    }

    /// Allocates a new instance using a registered layout name.
    pub fn create_material_instance(self: *MaterialSystem, layout_name: []const u8, pipeline: c.VkPipeline, pipeline_layout: c.VkPipelineLayout) !*MaterialInstance {
        const layout = self.layouts.getPtr(layout_name) orelse {
            material_log.err("Layout '{s}' not found", .{layout_name});
            return error.LayoutNotFound;
        };

        const instance = try self.allocator.create(MaterialInstance);
        instance.layout = layout;
        instance.pipeline = pipeline;
        instance.pipeline_layout = pipeline_layout;
        instance.textures = std.AutoHashMap(u32, handles.TextureHandle).init(self.allocator);

        if (layout.push_constant_size > 0) {
            instance.data = try self.allocator.alloc(u8, layout.push_constant_size);
            @memset(instance.data, 0);
        } else {
            instance.data = &.{};
        }

        return instance;
    }

    /// Destroys an instance and its CPU-side storage.
    pub fn destroy_material_instance(self: *MaterialSystem, instance: *MaterialInstance) void {
        if (instance.data.len > 0) {
            self.allocator.free(instance.data);
        }
        instance.textures.deinit();
        self.allocator.destroy(instance);
    }
};

const MaterialPropertyJson = struct {
    name: []const u8,
    type: []const u8,
    offset: u32,
    size: u32,
    binding: ?u32 = null,
};

const MaterialLayoutJson = struct {
    name: []const u8,
    properties: []const MaterialPropertyJson,
    push_constant_size: u32,
};

fn find_property_index(layout: *const MaterialLayoutDescriptor, name: []const u8) ?usize {
    const hash = hash_string(name);
    if (layout.property_hashes) |hashes| {
        var i: usize = 0;
        while (i < hashes.len) : (i += 1) {
            if (hashes[i] == hash and std.mem.eql(u8, layout.properties[i].name, name)) {
                return i;
            }
        }
        return null;
    }
    for (layout.properties, 0..) |prop, i| {
        if (std.mem.eql(u8, prop.name, name)) return i;
    }
    return null;
}

fn parse_property_type(name: []const u8) !MaterialPropertyType {
    if (std.mem.eql(u8, name, "Float")) return .Float;
    if (std.mem.eql(u8, name, "Vec2")) return .Vec2;
    if (std.mem.eql(u8, name, "Vec3")) return .Vec3;
    if (std.mem.eql(u8, name, "Vec4")) return .Vec4;
    if (std.mem.eql(u8, name, "Int")) return .Int;
    if (std.mem.eql(u8, name, "UInt")) return .UInt;
    if (std.mem.eql(u8, name, "Bool")) return .Bool;
    if (std.mem.eql(u8, name, "Matrix4")) return .Matrix4;
    if (std.mem.eql(u8, name, "Texture2D")) return .Texture2D;
    if (std.mem.eql(u8, name, "TextureCube")) return .TextureCube;
    return error.InvalidPropertyType;
}

/// Loads a layout from a JSON file and registers it under its declared name.
pub fn register_layout_from_json(self: *MaterialSystem, path: []const u8, descriptor_set_layout: c.VkDescriptorSetLayout) !void {
    const allocator = self.allocator;
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(MaterialLayoutJson, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const value = parsed.value;
    const count = value.properties.len;
    const props = try allocator.alloc(MaterialPropertyDescriptor, count);
    defer allocator.free(props);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const src = value.properties[i];
        const ty = try parse_property_type(src.type);
        props[i] = .{
            .name = src.name,
            .type = ty,
            .offset = src.offset,
            .binding = src.binding orelse 0,
            .size = src.size,
        };
    }

    const name_copy = try allocator.dupe(u8, value.name);

    const descriptor = MaterialLayoutDescriptor{
        .name = name_copy,
        .properties = props,
        .push_constant_size = value.push_constant_size,
        .descriptor_set_layout = descriptor_set_layout,
        .property_hashes = null,
    };

    try self.register_layout(name_copy, descriptor);
}

/// Sets a POD property value by name into an instance data buffer.
pub fn set_property(instance: *MaterialInstance, name: []const u8, value: anytype) !void {
    const index = find_property_index(instance.layout, name) orelse return error.PropertyNotFound;
    const prop = instance.layout.properties[index];

    const value_size = @sizeOf(@TypeOf(value));
    if (value_size > prop.size) {
        material_log.err("Value size {d} exceeds property '{s}' size {d}", .{ value_size, name, prop.size });
        return error.InvalidSize;
    }

    const start: usize = @intCast(prop.offset);
    const end = start + value_size;
    if (end > instance.data.len) return error.InvalidOffset;

    const dest = instance.data[start..end];
    const src = std.mem.asBytes(&value);
    @memcpy(dest, src);
}

/// Sets a texture handle property by name.
pub fn set_texture(instance: *MaterialInstance, name: []const u8, texture: handles.TextureHandle) !void {
    const hash = hash_string(name);
    const index = find_property_index(instance.layout, name) orelse return error.PropertyNotFound;
    const prop = instance.layout.properties[index];
    if (prop.type != .Texture2D and prop.type != .TextureCube) {
        return error.InvalidType;
    }

    try instance.textures.put(hash, texture);

    const start: usize = @intCast(prop.offset);
    if (start >= instance.data.len) return error.InvalidOffset;
    if (prop.size < 4) return error.InvalidSize;

    if (prop.size >= 8) {
        const encoded: u64 = (@as(u64, texture.generation) << 32) | @as(u64, texture.index);
        const end = start + 8;
        if (end > instance.data.len) return error.InvalidOffset;
        @memcpy(instance.data[start..end], std.mem.asBytes(&encoded));
    } else {
        const encoded: u32 = texture.index;
        const end = start + 4;
        if (end > instance.data.len) return error.InvalidOffset;
        @memcpy(instance.data[start..end], std.mem.asBytes(&encoded));
    }
}

/// Pushes material parameters for the instance into a command buffer.
pub fn bind_material(cmd: c.VkCommandBuffer, instance: *MaterialInstance, stage_flags: c.VkShaderStageFlags) void {
    if (instance.data.len > 0) {
        c.vkCmdPushConstants(cmd, instance.pipeline_layout, stage_flags, 0, @intCast(instance.data.len), instance.data.ptr);
    }
}

/// C-ABI entrypoints for material instance creation and property updates.
pub export fn cardinal_material_system_create_instance(system: ?*anyopaque, layout_name: ?[*:0]const u8, pipeline: c.VkPipeline, pipeline_layout: c.VkPipelineLayout) callconv(.c) ?*MaterialInstance {
    if (system == null or layout_name == null) return null;
    const sys = @as(*MaterialSystem, @ptrCast(@alignCast(system)));
    const name = std.mem.span(layout_name.?);

    if (sys.create_material_instance(name, pipeline, pipeline_layout)) |instance| {
        return instance;
    } else |err| {
        material_log.err("Failed to create material instance: {s}", .{@errorName(err)});
        return null;
    }
}

pub export fn cardinal_material_system_destroy_instance(system: ?*anyopaque, instance: ?*MaterialInstance) callconv(.c) void {
    if (system == null or instance == null) return;
    const sys = @as(*MaterialSystem, @ptrCast(@alignCast(system)));
    sys.destroy_material_instance(instance.?);
}

pub export fn cardinal_material_instance_set_float(instance: ?*MaterialInstance, name: ?[*:0]const u8, value: f32) callconv(.c) bool {
    if (instance == null or name == null) return false;
    const n = std.mem.span(name.?);
    set_property(instance.?, n, value) catch return false;
    return true;
}

pub export fn cardinal_material_instance_set_vec3(instance: ?*MaterialInstance, name: ?[*:0]const u8, x: f32, y: f32, z: f32) callconv(.c) bool {
    if (instance == null or name == null) return false;
    const n = std.mem.span(name.?);
    const val = [3]f32{ x, y, z };
    set_property(instance.?, n, val) catch return false;
    return true;
}

pub export fn cardinal_material_instance_set_texture(instance: ?*MaterialInstance, name: ?[*:0]const u8, texture: handles.TextureHandle) callconv(.c) bool {
    if (instance == null or name == null) return false;
    const n = std.mem.span(name.?);
    set_texture(instance.?, n, texture) catch return false;
    return true;
}

pub export fn cardinal_material_instance_bind(cmd: c.VkCommandBuffer, instance: ?*MaterialInstance, stage_flags: c.VkShaderStageFlags) callconv(.c) void {
    if (instance) |inst| {
        bind_material(cmd, inst, stage_flags);
    }
}
