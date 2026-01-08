const std = @import("std");
const log = @import("log.zig");

pub const CardinalEngineConfig = struct {
    // Engine/Window settings
    window_title: []const u8 = "Cardinal Engine",
    window_width: u32 = 1600,
    window_height: u32 = 900,
    window_resizable: bool = true,

    // Memory/System settings
    memory_size: usize = 4 * 1024 * 1024,
    ref_counting_buckets: u32 = 1009,
    async_worker_threads: u32 = 2,
    async_queue_size: u32 = 100,
    cache_size: u32 = 1000,

    // Paths
    assets_path: []const u8 = "assets",

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
                log.cardinal_log_info("Config file not found, using defaults", .{});
                return;
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 10);
        defer self.allocator.free(content);

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

        log.cardinal_log_info("Config loaded from {s}", .{self.config_path});
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

    pub fn setAssetsPath(self: *ConfigManager, new_path: []const u8) !void {
        if (!std.mem.eql(u8, self.config.assets_path, "assets")) {
            self.allocator.free(self.config.assets_path);
        }
        self.config.assets_path = try self.allocator.dupe(u8, new_path);
    }
};
