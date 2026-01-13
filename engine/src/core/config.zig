const std = @import("std");
const log = @import("log.zig");
const vk_types = @import("../renderer/vulkan_types.zig");
const c = @import("../renderer/vulkan_c.zig").c;

pub const CardinalEngineConfig = struct {
    // Engine/Window settings
    window_title: []const u8 = "Cardinal Engine",
    window_width: u32 = 1920,
    window_height: u32 = 1080,
    window_resizable: bool = true,

    // Memory/System settings
    memory_size: usize = 4 * 1024 * 1024,
    ref_counting_buckets: u32 = 1009,
    async_worker_threads: u32 = 2,
    async_queue_size: u32 = 100,
    cache_size: u32 = 1000,

    // Paths
    assets_path: []const u8 = "assets",

    // Renderer settings
    renderer: vk_types.RendererConfig = .{
        .shader_dir = "assets/shaders".* ++ .{0} ** (64 - "assets/shaders".len),
        .pipeline_dir = "assets/pipelines".* ++ .{0} ** (64 - "assets/pipelines".len),
        .texture_dir = "assets/textures".* ++ .{0} ** (64 - "assets/textures".len),
        .model_dir = "assets/models".* ++ .{0} ** (64 - "assets/models".len),
    },

    // Helper to ensure title is null-terminated if needed, though usually handled by duplication
};

// Simple JSON wrapper
pub const ConfigManager = struct {
    allocator: std.mem.Allocator,
    config: CardinalEngineConfig,
    config_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, initial_config: CardinalEngineConfig) ConfigManager {
        return .{
            .allocator = allocator,
            .config = initial_config,
            .config_path = allocator.dupe(u8, path) catch "cardinal_config.json",
        };
    }

    pub fn deinit(self: *ConfigManager) void {
        self.allocator.free(self.config_path);
    }

    pub fn load(self: *ConfigManager) !void {
        const file = std.fs.cwd().openFile(self.config_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                log.cardinal_log_info("Config file not found, creating with defaults", .{});
                try self.save();
                return;
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 10);
        defer self.allocator.free(content);

        const ParsedRendererConfig = struct {
            pbr_clear_color: ?[4]f32 = null,
            pbr_ambient_color: ?[4]f32 = null,
            pbr_default_light_direction: ?[4]f32 = null,
            pbr_default_light_color: ?[4]f32 = null,
            shadow_map_format: ?c.VkFormat = null,
            shadow_cascade_count: ?u32 = null,
            shadow_map_size: ?u32 = null,
            shadow_split_lambda: ?f32 = null,
            shadow_near_clip: ?f32 = null,
            shadow_far_clip: ?f32 = null,
            prefer_hdr: ?bool = null,
            max_lights: ?u32 = null,
            max_frames_in_flight: ?u32 = null,
            timeline_max_ahead: ?u64 = null,
            shader_dir: ?[]const u8 = null,
            pipeline_dir: ?[]const u8 = null,
            texture_dir: ?[]const u8 = null,
            model_dir: ?[]const u8 = null,
        };

        const ParsedConfig = struct {
            window_title: ?[]const u8 = null,
            window_width: ?u32 = null,
            window_height: ?u32 = null,
            window_resizable: ?bool = null,
            memory_size: ?usize = null,
            ref_counting_buckets: ?u32 = null,
            async_worker_threads: ?u32 = null,
            async_queue_size: ?u32 = null,
            cache_size: ?u32 = null,
            assets_path: ?[]const u8 = null,
            renderer: ?ParsedRendererConfig = null,
        };

        const parsed = try std.json.parseFromSlice(ParsedConfig, self.allocator, content, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (parsed.value.window_title) |val| self.config.window_title = try self.allocator.dupe(u8, val);
        if (parsed.value.window_width) |val| self.config.window_width = val;
        if (parsed.value.window_height) |val| self.config.window_height = val;
        if (parsed.value.window_resizable) |val| self.config.window_resizable = val;
        if (parsed.value.memory_size) |val| self.config.memory_size = val;
        if (parsed.value.ref_counting_buckets) |val| self.config.ref_counting_buckets = val;
        if (parsed.value.async_worker_threads) |val| self.config.async_worker_threads = val;
        if (parsed.value.async_queue_size) |val| self.config.async_queue_size = val;
        if (parsed.value.cache_size) |val| self.config.cache_size = val;
        if (parsed.value.assets_path) |val| self.config.assets_path = try self.allocator.dupe(u8, val);

        if (parsed.value.renderer) |r| {
            if (r.pbr_clear_color) |v| self.config.renderer.pbr_clear_color = v;
            if (r.pbr_ambient_color) |v| self.config.renderer.pbr_ambient_color = v;
            if (r.pbr_default_light_direction) |v| self.config.renderer.pbr_default_light_direction = v;
            if (r.pbr_default_light_color) |v| self.config.renderer.pbr_default_light_color = v;
            if (r.shadow_map_format) |v| self.config.renderer.shadow_map_format = v;
            if (r.shadow_cascade_count) |v| self.config.renderer.shadow_cascade_count = v;
            if (r.shadow_map_size) |v| self.config.renderer.shadow_map_size = v;
            if (r.shadow_split_lambda) |v| self.config.renderer.shadow_split_lambda = v;
            if (r.shadow_near_clip) |v| self.config.renderer.shadow_near_clip = v;
            if (r.shadow_far_clip) |v| self.config.renderer.shadow_far_clip = v;
            if (r.prefer_hdr) |v| self.config.renderer.prefer_hdr = v;
            if (r.max_lights) |v| self.config.renderer.max_lights = v;
            if (r.max_frames_in_flight) |v| self.config.renderer.max_frames_in_flight = v;
            if (r.timeline_max_ahead) |v| self.config.renderer.timeline_max_ahead = v;

            if (r.shader_dir) |v| {
                @memset(&self.config.renderer.shader_dir, 0);
                const len = @min(v.len, 63);
                @memcpy(self.config.renderer.shader_dir[0..len], v[0..len]);
            }
            if (r.pipeline_dir) |v| {
                @memset(&self.config.renderer.pipeline_dir, 0);
                const len = @min(v.len, 63);
                @memcpy(self.config.renderer.pipeline_dir[0..len], v[0..len]);
            }
            if (r.texture_dir) |v| {
                @memset(&self.config.renderer.texture_dir, 0);
                const len = @min(v.len, 63);
                @memcpy(self.config.renderer.texture_dir[0..len], v[0..len]);
            }
            if (r.model_dir) |v| {
                @memset(&self.config.renderer.model_dir, 0);
                const len = @min(v.len, 63);
                @memcpy(self.config.renderer.model_dir[0..len], v[0..len]);
            }
        }

        log.cardinal_log_info("Config loaded from {s}", .{self.config_path});

        // Save back to ensure new fields are populated, while preserving unknown fields
        try self.save_merged(content);
    }

    pub fn save(self: *ConfigManager) !void {
        const file = try std.fs.cwd().createFile(self.config_path, .{});
        defer file.close();
        // Use stringify
        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(self.allocator);

        try list.writer(self.allocator).print("{f}", .{std.json.fmt(self.config, .{ .whitespace = .indent_4 })});
        try file.writeAll(list.items);

        log.cardinal_log_info("Config saved to {s}", .{self.config_path});
    }

    fn save_merged(self: *ConfigManager, original_content: []const u8) !void {
        // Parse original content into a ValueTree to preserve structure/comments
        var tree = try std.json.parseFromSlice(std.json.Value, self.allocator, original_content, .{});
        defer tree.deinit();

        if (tree.value != .object) {
            // If not an object, just overwrite
            try self.save();
            return;
        }

        // Merge current config into the tree
        try merge_struct_into_value(self.allocator, &tree.value, self.config);

        // Save the merged tree
        const file = try std.fs.cwd().createFile(self.config_path, .{});
        defer file.close();

        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(self.allocator);

        try list.writer(self.allocator).print("{f}", .{std.json.fmt(tree.value, .{ .whitespace = .indent_4 })});
        try file.writeAll(list.items);

        log.cardinal_log_info("Config saved (merged) to {s}", .{self.config_path});
    }

    fn merge_struct_into_value(allocator: std.mem.Allocator, value: *std.json.Value, struct_val: anytype) !void {
        const T = @TypeOf(struct_val);
        const type_info = @typeInfo(T);

        if (type_info != .@"struct") return;
        if (value.* != .object) return;

        inline for (type_info.@"struct".fields) |field| {
            const field_name = field.name;
            const field_val = @field(struct_val, field.name);
            const FieldType = field.type;

            // Check if field exists
            if (value.object.get(field_name)) |_| {
                // Recursively merge if both are objects/structs
                if (@typeInfo(FieldType) == .@"struct") {
                    // We need a pointer to the existing value to modify it
                    if (value.object.getPtr(field_name)) |ptr| {
                        try merge_struct_into_value(allocator, ptr, field_val);
                    }
                }
            } else {
                // Field missing, add it
                // We need to convert the field value to a std.json.Value
                // This implies full serialization of the field value to Value
                // For simplicity, we can just let std.json.fmt handle it if we could,
                // but we need to insert into the map.

                // Construct a json string for just this field
                // var temp_list = std.ArrayList(u8).init(allocator);
                // defer temp_list.deinit();
                // try std.json.stringify(field_val, .{}, temp_list.writer());

                // Parse it back into a Value
                // Note: we are abandoning this complex parse path for manual add_missing_field below.

                try add_missing_field(allocator, value, field_name, field_val);
            }
        }
    }

    fn add_missing_field(allocator: std.mem.Allocator, object: *std.json.Value, name: []const u8, val: anytype) !void {
        const T = @TypeOf(val);
        var json_val: std.json.Value = undefined;

        switch (@typeInfo(T)) {
            .bool => json_val = .{ .bool = val },
            .int, .comptime_int => json_val = .{ .integer = @intCast(val) },
            .float, .comptime_float => json_val = .{ .float = @floatCast(val) },
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    // String
                    const dup = try allocator.dupe(u8, val);
                    json_val = .{ .string = dup };
                } else if (ptr.size == .one and @typeInfo(ptr.child) == .array) {
                    // Pointer to array (string literal often comes as *const [N:0]u8)
                    const slice = val[0..];
                    if (@typeInfo(ptr.child).array.child == u8) {
                        const dup = try allocator.dupe(u8, slice);
                        json_val = .{ .string = dup };
                    } else {
                        // Other array pointer
                        return; // Skip complex types for now to avoid crashes
                    }
                } else {
                    return; // Skip other pointers
                }
            },
            .array => |arr| {
                if (arr.child == u8) {
                    const dup = try allocator.dupe(u8, &val);
                    json_val = .{ .string = dup };
                } else {
                    // Handle numeric arrays (e.g. colors)
                    var list = std.array_list.Managed(std.json.Value).init(allocator);
                    errdefer list.deinit();
                    for (val) |item| {
                        try list.append(try create_simple_value(allocator, item));
                    }
                    json_val = .{ .array = list };
                }
            },
            .@"struct" => {
                // Create empty object and recurse
                var map = std.json.ObjectMap.init(allocator);
                errdefer map.deinit();
                var obj_val = std.json.Value{ .object = map };
                try merge_struct_into_value(allocator, &obj_val, val);
                json_val = obj_val;
            },
            .optional => {
                if (val) |v| {
                    try add_missing_field(allocator, object, name, v);
                }
                return;
            },
            else => return, // Skip unsupported
        }

        const key_dup = try allocator.dupe(u8, name);
        try object.object.put(key_dup, json_val);
    }

    fn create_simple_value(allocator: std.mem.Allocator, val: anytype) !std.json.Value {
        _ = allocator; // Unused for simple values
        const T = @TypeOf(val);
        switch (@typeInfo(T)) {
            .bool => return .{ .bool = val },
            .int, .comptime_int => return .{ .integer = @intCast(val) },
            .float, .comptime_float => return .{ .float = @floatCast(val) },
            else => return .{ .null = {} },
        }
    }

    pub fn setAssetsPath(self: *ConfigManager, new_path: []const u8) !void {
        if (!std.mem.eql(u8, self.config.assets_path, "assets")) {
            self.allocator.free(self.config.assets_path);
        }
        self.config.assets_path = try self.allocator.dupe(u8, new_path);
    }
};
