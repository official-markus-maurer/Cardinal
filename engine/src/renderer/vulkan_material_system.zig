const std = @import("std");
const c = @import("vulkan_c.zig").c;
const types = @import("vulkan_types.zig");
const memory = @import("../core/memory.zig");
const log = @import("../core/log.zig");
const vk_pso = @import("vulkan_pso.zig");
const handles = @import("../core/handles.zig");

const material_log = log.ScopedLogger("MATERIAL_SYSTEM");

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

pub const MaterialPropertyDescriptor = struct {
    name: []const u8,
    type: MaterialPropertyType,
    offset: u32, // Byte offset in push constants or UBO
    binding: u32 = 0, // Descriptor binding for textures
    size: u32, // Size in bytes
};

pub const MaterialLayoutDescriptor = struct {
    name: []const u8,
    properties: []const MaterialPropertyDescriptor,
    push_constant_size: u32,
    descriptor_set_layout: c.VkDescriptorSetLayout, // Optional: if using descriptor sets for material data
};

pub const MaterialInstance = struct {
    layout: *const MaterialLayoutDescriptor,
    data: []u8, // CPU-side storage for uniform data (push constants)
    textures: std.StringHashMap(handles.TextureHandle), // Texture bindings by property name
    
    // Runtime data
    pipeline: c.VkPipeline,
    pipeline_layout: c.VkPipelineLayout,
};

pub const MaterialSystem = struct {
    allocator: std.mem.Allocator,
    layouts: std.StringHashMap(MaterialLayoutDescriptor),
    
    pub fn init(allocator: std.mem.Allocator) MaterialSystem {
        return .{
            .allocator = allocator,
            .layouts = std.StringHashMap(MaterialLayoutDescriptor).init(allocator),
        };
    }

    pub fn deinit(self: *MaterialSystem) void {
        var it = self.layouts.iterator();
        while (it.next()) |entry| {
            // Free property arrays if we owned them
            // In a real system we'd manage memory ownership more carefully
            self.allocator.free(entry.value_ptr.properties);
        }
        self.layouts.deinit();
    }

    pub fn register_layout(self: *MaterialSystem, name: []const u8, descriptor: MaterialLayoutDescriptor) !void {
        // Create deep copy of descriptor to own the memory
        const props_copy = try self.allocator.alloc(MaterialPropertyDescriptor, descriptor.properties.len);
        @memcpy(props_copy, descriptor.properties);
        
        var new_desc = descriptor;
        new_desc.properties = props_copy;
        
        try self.layouts.put(name, new_desc);
        material_log.info("Registered material layout '{s}' with {d} properties", .{name, descriptor.properties.len});
    }

    pub fn create_material_instance(self: *MaterialSystem, layout_name: []const u8, pipeline: c.VkPipeline, pipeline_layout: c.VkPipelineLayout) !*MaterialInstance {
        const layout = self.layouts.getPtr(layout_name) orelse {
            material_log.err("Layout '{s}' not found", .{layout_name});
            return error.LayoutNotFound;
        };

        const instance = try self.allocator.create(MaterialInstance);
        instance.layout = layout;
        instance.pipeline = pipeline;
        instance.pipeline_layout = pipeline_layout;
        instance.textures = std.StringHashMap(handles.TextureHandle).init(self.allocator);
        
        if (layout.push_constant_size > 0) {
            instance.data = try self.allocator.alloc(u8, layout.push_constant_size);
            @memset(instance.data, 0);
        } else {
            instance.data = &.{};
        }

        return instance;
    }

    pub fn destroy_material_instance(self: *MaterialSystem, instance: *MaterialInstance) void {
        if (instance.data.len > 0) {
            self.allocator.free(instance.data);
        }
        instance.textures.deinit();
        self.allocator.destroy(instance);
    }
};

// Helper to set property values
pub fn set_property(instance: *MaterialInstance, name: []const u8, value: anytype) !void {
    // Find property in layout
    for (instance.layout.properties) |prop| {
        if (std.mem.eql(u8, prop.name, name)) {
            // Check type and size
            const value_size = @sizeOf(@TypeOf(value));
            if (value_size > prop.size) {
                 material_log.err("Value size {d} exceeds property '{s}' size {d}", .{value_size, name, prop.size});
                 return error.InvalidSize;
            }

            // Copy data
            const dest = instance.data[prop.offset .. prop.offset + value_size];
            const src = std.mem.asBytes(&value);
            @memcpy(dest, src);
            return;
        }
    }
    return error.PropertyNotFound;
}

pub fn set_texture(instance: *MaterialInstance, name: []const u8, texture: handles.TextureHandle) !void {
    // Verify property exists and is a texture
    for (instance.layout.properties) |prop| {
        if (std.mem.eql(u8, prop.name, name)) {
            if (prop.type != .Texture2D and prop.type != .TextureCube) {
                return error.InvalidType;
            }
            try instance.textures.put(name, texture);
            return;
        }
    }
    return error.PropertyNotFound;
}

// Helper to bind material for rendering
pub fn bind_material(cmd: c.VkCommandBuffer, instance: *MaterialInstance, stage_flags: c.VkShaderStageFlags) void {
    // Push constants
    if (instance.data.len > 0) {
        c.vkCmdPushConstants(cmd, instance.pipeline_layout, stage_flags, 0, @intCast(instance.data.len), instance.data.ptr);
    }
    
    // Descriptor sets for textures would be handled here or via bindless system
    // For now we assume bindless indices are passed via push constants
}

// --- C API Exports ---

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
    const val = [3]f32{x, y, z};
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
