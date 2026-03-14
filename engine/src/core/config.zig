//! Runtime configuration types and JSON persistence.
//!
//! `CardinalEngineConfig` holds defaults used for first-run config generation. `ConfigManager`
//! loads and saves `cardinal_config.json`, merging missing fields while keeping unknown fields.
const std = @import("std");
const log = @import("log.zig");
const cfg_log = log.ScopedLogger("CONFIG");
const vk_types = @import("../renderer/vulkan_types.zig");
const c = @import("../renderer/vulkan_c.zig").c;

/// Default runtime configuration for the engine and renderer.
pub const CardinalEngineConfig = struct {
    /// Window title shown by the platform window manager.
    window_title: []const u8 = "Cardinal Engine",
    /// Initial window width in pixels.
    window_width: u32 = 1920,
    /// Initial window height in pixels.
    window_height: u32 = 1080,
    /// Whether the window can be resized by the user.
    window_resizable: bool = true,

    /// Total memory budget passed to the engine memory system.
    memory_size: usize = 4 * 1024 * 1024,
    /// Number of hash buckets for the ref-counting registry.
    ref_counting_buckets: u32 = 1009,
    /// Worker thread count used by the async loader.
    async_worker_threads: u32 = 2,
    /// Max number of queued async tasks.
    async_queue_size: u32 = 100,
    /// Max entries for internal caches (textures/meshes).
    cache_size: u32 = 1000,

    /// Default assets directory path.
    assets_path: []const u8 = "assets",
    recent_projects: []const [:0]u8 = &[_][:0]u8{},

    /// Renderer configuration (paths and feature toggles).
    renderer: vk_types.RendererConfig = .{
        .shader_dir = "assets/shaders".* ++ .{0} ** (64 - "assets/shaders".len),
        .pipeline_dir = "assets/pipelines".* ++ .{0} ** (64 - "assets/pipelines".len),
        .texture_dir = "assets/textures".* ++ .{0} ** (64 - "assets/textures".len),
        .model_dir = "assets/models".* ++ .{0} ** (64 - "assets/models".len),
        .present_mode = c.VK_PRESENT_MODE_FIFO_KHR,
    },
};

/// Loads and saves a config file, owning any heap-duplicated string fields.
pub const ConfigManager = struct {
    allocator: std.mem.Allocator,
    config: CardinalEngineConfig,
    config_path: []const u8,
    config_path_owned: bool,
    window_title_owned: bool,
    assets_path_owned: bool,
    recent_projects_owned: bool,

    /// Creates a manager for `path`, seeding it with `initial_config`.
    pub fn init(allocator: std.mem.Allocator, path: []const u8, initial_config: CardinalEngineConfig) ConfigManager {
        var cfg = initial_config;

        var config_path_owned = true;
        const config_path = allocator.dupe(u8, path) catch blk: {
            config_path_owned = false;
            break :blk "cardinal_config.json";
        };

        var window_title_owned = true;
        cfg.window_title = allocator.dupe(u8, initial_config.window_title) catch blk: {
            window_title_owned = false;
            break :blk initial_config.window_title;
        };

        var assets_path_owned = true;
        cfg.assets_path = allocator.dupe(u8, initial_config.assets_path) catch blk: {
            assets_path_owned = false;
            break :blk initial_config.assets_path;
        };

        var recent_projects_owned = false;
        if (allocator.alloc([:0]u8, initial_config.recent_projects.len) catch null) |alloc_recent| {
            recent_projects_owned = true;
            var recent_projects = alloc_recent;

            var filled: usize = 0;
            for (initial_config.recent_projects, 0..) |p, i| {
                const dup = allocator.dupeZ(u8, p) catch {
                    for (recent_projects[0..filled]) |owned_p| {
                        allocator.free(owned_p[0 .. owned_p.len + 1]);
                    }
                    allocator.free(recent_projects);
                    recent_projects_owned = false;
                    break;
                };
                recent_projects[i] = dup;
                filled += 1;
            }

            if (recent_projects_owned) {
                cfg.recent_projects = recent_projects;
            } else {
                cfg.recent_projects = initial_config.recent_projects;
            }
        } else {
            cfg.recent_projects = initial_config.recent_projects;
        }

        return .{
            .allocator = allocator,
            .config = cfg,
            .config_path = config_path,
            .config_path_owned = config_path_owned,
            .window_title_owned = window_title_owned,
            .assets_path_owned = assets_path_owned,
            .recent_projects_owned = recent_projects_owned,
        };
    }

    /// Releases owned resources for the manager.
    pub fn deinit(self: *ConfigManager) void {
        if (self.recent_projects_owned) {
            for (self.config.recent_projects) |p| {
                self.allocator.free(p[0 .. p.len + 1]);
            }
            self.allocator.free(self.config.recent_projects);
            self.recent_projects_owned = false;
        }

        if (self.assets_path_owned) {
            self.allocator.free(self.config.assets_path);
            self.assets_path_owned = false;
        }

        if (self.window_title_owned) {
            self.allocator.free(self.config.window_title);
            self.window_title_owned = false;
        }

        if (self.config_path_owned) {
            self.allocator.free(self.config_path);
            self.config_path_owned = false;
        }
    }

    /// Loads config from disk, keeping defaults for missing/unknown fields.
    ///
    /// This does not automatically write merged results back to disk to avoid rewriting JSON.
    pub fn load(self: *ConfigManager) !void {
        const file = std.fs.cwd().openFile(self.config_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                cfg_log.info("Config file not found, creating with defaults", .{});
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
            present_mode: ?c.VkPresentModeKHR = null,
            max_lights: ?u32 = null,
            max_frames_in_flight: ?u32 = null,
            timeline_max_ahead: ?u64 = null,
            enable_async_compute: ?bool = null,
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
            recent_projects: ?[]const []const u8 = null,
            renderer: ?ParsedRendererConfig = null,
        };

        const parsed = try std.json.parseFromSlice(ParsedConfig, self.allocator, content, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (parsed.value.window_title) |val| {
            if (self.window_title_owned) self.allocator.free(self.config.window_title);
            self.config.window_title = try self.allocator.dupe(u8, val);
            self.window_title_owned = true;
        }
        if (parsed.value.window_width) |val| self.config.window_width = val;
        if (parsed.value.window_height) |val| self.config.window_height = val;
        if (parsed.value.window_resizable) |val| self.config.window_resizable = val;
        if (parsed.value.memory_size) |val| self.config.memory_size = val;
        if (parsed.value.ref_counting_buckets) |val| self.config.ref_counting_buckets = val;
        if (parsed.value.async_worker_threads) |val| self.config.async_worker_threads = val;
        if (parsed.value.async_queue_size) |val| self.config.async_queue_size = val;
        if (parsed.value.cache_size) |val| self.config.cache_size = val;
        if (parsed.value.assets_path) |val| {
            if (self.assets_path_owned) self.allocator.free(self.config.assets_path);
            self.config.assets_path = try self.allocator.dupe(u8, val);
            self.assets_path_owned = true;
        }
        if (parsed.value.recent_projects) |val| {
            if (self.recent_projects_owned) {
                for (self.config.recent_projects) |p| {
                    self.allocator.free(p[0 .. p.len + 1]);
                }
                self.allocator.free(self.config.recent_projects);
                self.recent_projects_owned = false;
            }
            var new_list = try self.allocator.alloc([:0]u8, val.len);
            var filled: usize = 0;
            errdefer {
                for (new_list[0..filled]) |p| {
                    self.allocator.free(p[0 .. p.len + 1]);
                }
                self.allocator.free(new_list);
            }
            for (val, 0..) |path, i| {
                new_list[i] = try self.allocator.dupeZ(u8, path);
                filled += 1;
            }
            self.config.recent_projects = new_list;
            self.recent_projects_owned = true;
        }

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
            if (r.present_mode) |v| self.config.renderer.present_mode = v;
            if (r.max_lights) |v| self.config.renderer.max_lights = v;
            if (r.max_frames_in_flight) |v| self.config.renderer.max_frames_in_flight = v;
            if (r.timeline_max_ahead) |v| self.config.renderer.timeline_max_ahead = v;
            if (r.enable_async_compute) |v| self.config.renderer.enable_async_compute = v;

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
    }

    /// Helper for serialization to handle `[N]u8` config fields as slices.
    const SerializableRendererConfig = struct {
        pbr_clear_color: [4]f32,
        pbr_ambient_color: [4]f32,
        pbr_default_light_direction: [4]f32,
        pbr_default_light_color: [4]f32,
        shadow_map_format: c.VkFormat,
        shadow_cascade_count: u32,
        shadow_map_size: u32,
        shadow_split_lambda: f32,
        shadow_near_clip: f32,
        shadow_far_clip: f32,
        prefer_hdr: bool,
        present_mode: c.VkPresentModeKHR,
        max_lights: u32,
        max_frames_in_flight: u32,
        timeline_max_ahead: u64,
        enable_async_compute: bool,
        shader_dir: []const u8,
        pipeline_dir: []const u8,
        texture_dir: []const u8,
        model_dir: []const u8,

        pub fn from(cfg: vk_types.RendererConfig) SerializableRendererConfig {
            return .{
                .pbr_clear_color = cfg.pbr_clear_color,
                .pbr_ambient_color = cfg.pbr_ambient_color,
                .pbr_default_light_direction = cfg.pbr_default_light_direction,
                .pbr_default_light_color = cfg.pbr_default_light_color,
                .shadow_map_format = cfg.shadow_map_format,
                .shadow_cascade_count = cfg.shadow_cascade_count,
                .shadow_map_size = cfg.shadow_map_size,
                .shadow_split_lambda = cfg.shadow_split_lambda,
                .shadow_near_clip = cfg.shadow_near_clip,
                .shadow_far_clip = cfg.shadow_far_clip,
                .prefer_hdr = cfg.prefer_hdr,
                .present_mode = cfg.present_mode,
                .max_lights = cfg.max_lights,
                .max_frames_in_flight = cfg.max_frames_in_flight,
                .timeline_max_ahead = cfg.timeline_max_ahead,
                .enable_async_compute = cfg.enable_async_compute,
                .shader_dir = std.mem.sliceTo(&cfg.shader_dir, 0),
                .pipeline_dir = std.mem.sliceTo(&cfg.pipeline_dir, 0),
                .texture_dir = std.mem.sliceTo(&cfg.texture_dir, 0),
                .model_dir = std.mem.sliceTo(&cfg.model_dir, 0),
            };
        }
    };

    const SerializableConfig = struct {
        window_title: []const u8,
        window_width: u32,
        window_height: u32,
        window_resizable: bool,
        memory_size: usize,
        ref_counting_buckets: u32,
        async_worker_threads: u32,
        async_queue_size: u32,
        cache_size: u32,
        assets_path: []const u8,
        recent_projects: []const [:0]u8,
        renderer: SerializableRendererConfig,

        pub fn from(cfg: CardinalEngineConfig) SerializableConfig {
            return .{
                .window_title = cfg.window_title,
                .window_width = cfg.window_width,
                .window_height = cfg.window_height,
                .window_resizable = cfg.window_resizable,
                .memory_size = cfg.memory_size,
                .ref_counting_buckets = cfg.ref_counting_buckets,
                .async_worker_threads = cfg.async_worker_threads,
                .async_queue_size = cfg.async_queue_size,
                .cache_size = cfg.cache_size,
                .assets_path = cfg.assets_path,
                .recent_projects = cfg.recent_projects,
                .renderer = SerializableRendererConfig.from(cfg.renderer),
            };
        }
    };

    /// Saves the current config to `config_path`, preserving existing JSON structure when possible.
    pub fn save(self: *ConfigManager) !void {
        const file = std.fs.cwd().openFile(self.config_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return self.save_new();
            }
            return err;
        };
        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch {
            file.close();
            return self.save_new();
        };
        file.close();
        defer self.allocator.free(content);

        return self.save_merged(content);
    }

    /// Writes a fresh config file from defaults/current settings.
    fn save_new(self: *ConfigManager) !void {
        const file = try std.fs.cwd().createFile(self.config_path, .{});
        defer file.close();

        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(self.allocator);

        const serializable = SerializableConfig.from(self.config);

        try list.writer(self.allocator).print("{f}", .{std.json.fmt(serializable, .{ .whitespace = .indent_4 })});
        try file.writeAll(list.items);

        log.cardinal_log_info("Config saved (new) to {s}", .{self.config_path});
    }

    /// Merges missing config fields into the existing JSON and writes it back to disk.
    fn save_merged(self: *ConfigManager, original_content: []const u8) !void {
        var tree = try std.json.parseFromSlice(std.json.Value, self.allocator, original_content, .{});
        defer tree.deinit();

        if (tree.value != .object) {
            try self.save_new();
            return;
        }

        const serializable = SerializableConfig.from(self.config);
        try merge_struct_into_value(self.allocator, &tree.value, serializable);

        const file = try std.fs.cwd().createFile(self.config_path, .{});
        defer file.close();

        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(self.allocator);

        try list.writer(self.allocator).print("{f}", .{std.json.fmt(tree.value, .{ .whitespace = .indent_4 })});
        try file.writeAll(list.items);

        cfg_log.info("Config saved (merged) to {s}", .{self.config_path});
    }

    /// Recursively adds missing fields from `struct_val` into `value` (object-only).
    fn merge_struct_into_value(allocator: std.mem.Allocator, value: *std.json.Value, struct_val: anytype) !void {
        const T = @TypeOf(struct_val);
        const type_info = @typeInfo(T);

        if (type_info != .@"struct") return;
        if (value.* != .object) return;

        inline for (type_info.@"struct".fields) |field| {
            const field_name = field.name;
            const field_val = @field(struct_val, field.name);
            const FieldType = field.type;

            if (value.object.get(field_name)) |_| {
                if (@typeInfo(FieldType) == .@"struct") {
                    if (value.object.getPtr(field_name)) |ptr| {
                        try merge_struct_into_value(allocator, ptr, field_val);
                    }
                }
            } else {
                try add_missing_field(allocator, value, field_name, field_val);
            }
        }
    }

    /// Adds `name` to `object` when missing, converting `val` into a JSON value.
    fn add_missing_field(allocator: std.mem.Allocator, object: *std.json.Value, name: []const u8, val: anytype) !void {
        const T = @TypeOf(val);
        var json_val: std.json.Value = undefined;

        switch (@typeInfo(T)) {
            .bool => json_val = .{ .bool = val },
            .int, .comptime_int => json_val = .{ .integer = @intCast(val) },
            .float, .comptime_float => json_val = .{ .float = @floatCast(val) },
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    const dup = try allocator.dupe(u8, val);
                    json_val = .{ .string = dup };
                } else if (ptr.size == .slice and @typeInfo(ptr.child) == .pointer) {
                    const child_ptr = @typeInfo(ptr.child).pointer;
                    if (child_ptr.size == .slice and child_ptr.child == u8) {
                        var list = std.array_list.Managed(std.json.Value).init(allocator);
                        errdefer list.deinit();

                        for (val) |item| {
                            const dup = try allocator.dupe(u8, item);
                            try list.append(.{ .string = dup });
                        }

                        json_val = .{ .array = list };
                    } else {
                        return;
                    }
                } else if (ptr.size == .one and @typeInfo(ptr.child) == .array) {
                    const slice = val[0..];
                    if (@typeInfo(ptr.child).array.child == u8) {
                        const dup = try allocator.dupe(u8, slice);
                        json_val = .{ .string = dup };
                    } else {
                        return;
                    }
                } else {
                    return;
                }
            },
            .array => |arr| {
                if (arr.child == u8) {
                    const dup = try allocator.dupe(u8, &val);
                    json_val = .{ .string = dup };
                } else {
                    var list = std.array_list.Managed(std.json.Value).init(allocator);
                    errdefer list.deinit();
                    for (val) |item| {
                        try list.append(try create_simple_value(allocator, item));
                    }
                    json_val = .{ .array = list };
                }
            },
            .@"struct" => {
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
            else => return,
        }

        const key_dup = try allocator.dupe(u8, name);
        try object.object.put(key_dup, json_val);
    }

    /// Creates a JSON value from a primitive element (used for numeric arrays).
    fn create_simple_value(allocator: std.mem.Allocator, val: anytype) !std.json.Value {
        _ = allocator;
        const T = @TypeOf(val);
        switch (@typeInfo(T)) {
            .bool => return .{ .bool = val },
            .int, .comptime_int => return .{ .integer = @intCast(val) },
            .float, .comptime_float => return .{ .float = @floatCast(val) },
            else => return .{ .null = {} },
        }
    }

    pub fn setAssetsPath(self: *ConfigManager, new_path: []const u8) !void {
        if (self.assets_path_owned) self.allocator.free(self.config.assets_path);
        self.config.assets_path = try self.allocator.dupe(u8, new_path);
        self.assets_path_owned = true;
    }

    pub fn addRecentProject(self: *ConfigManager, path: []const u8) !void {
        const max: usize = 10;
        const old_list = self.config.recent_projects;

        var existing_index: ?usize = null;
        for (old_list, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, path)) {
                existing_index = i;
                break;
            }
        }

        if (existing_index != null and existing_index.? == 0) return;

        const extra: usize = if (existing_index == null) 1 else 0;
        const final_len = @min(old_list.len + extra, max);

        if (!self.recent_projects_owned) {
            var new_list = try self.allocator.alloc([:0]u8, final_len);
            var filled: usize = 0;
            errdefer {
                for (new_list[0..filled]) |p| self.allocator.free(p[0 .. p.len + 1]);
                self.allocator.free(new_list);
            }

            new_list[0] = try self.allocator.dupeZ(u8, path);
            filled = 1;

            var out_i: usize = 1;
            for (old_list) |entry| {
                if (out_i >= final_len) break;
                if (std.mem.eql(u8, entry, path)) continue;
                new_list[out_i] = try self.allocator.dupeZ(u8, entry);
                out_i += 1;
                filled += 1;
            }

            self.config.recent_projects = new_list;
            self.recent_projects_owned = true;
            return;
        }

        var new_list = try self.allocator.alloc([:0]u8, final_len);
        var first_allocated = false;
        errdefer {
            if (first_allocated) self.allocator.free(new_list[0][0 .. new_list[0].len + 1]);
            self.allocator.free(new_list);
        }

        if (existing_index) |idx| {
            new_list[0] = old_list[idx];
        } else {
            new_list[0] = try self.allocator.dupeZ(u8, path);
            first_allocated = true;
        }

        var out_i: usize = 1;
        for (old_list, 0..) |entry, idx| {
            if (out_i >= final_len) break;
            if (existing_index != null and idx == existing_index.?) continue;
            new_list[out_i] = entry;
            out_i += 1;
        }

        for (old_list) |entry| {
            var used = false;
            for (new_list) |kept| {
                if (kept.ptr == entry.ptr and kept.len == entry.len) {
                    used = true;
                    break;
                }
            }
            if (!used) self.allocator.free(entry[0 .. entry.len + 1]);
        }
        self.allocator.free(old_list);

        self.config.recent_projects = new_list;
        self.recent_projects_owned = true;
    }
};

test "ConfigManager recent_projects ownership" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mgr = ConfigManager.init(allocator, "cardinal_config.json", .{});
    defer mgr.deinit();

    try mgr.addRecentProject("C:/Projects/A");
    try mgr.addRecentProject("C:/Projects/B");
    try mgr.addRecentProject("C:/Projects/A");
}
