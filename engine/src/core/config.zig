const std = @import("std");
const log = @import("log.zig");

pub const EngineConfig = struct {
    assets_path: []const u8 = "assets",

    // JSON serialization requires pointers for slices if we want to manage memory
    // But for simple config we can use a fixed buffer or duplicate on load.
};

// Simple JSON wrapper
pub const ConfigManager = struct {
    allocator: std.mem.Allocator,
    config: EngineConfig,
    config_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) ConfigManager {
        return .{
            .allocator = allocator,
            .config = .{},
            .config_path = allocator.dupe(u8, path) catch "cardinal_config.json",
        };
    }

    pub fn deinit(self: *ConfigManager) void {
        self.allocator.free(self.config_path);
        // assets_path might be allocated if loaded from JSON
        if (!std.mem.eql(u8, self.config.assets_path, "assets")) {
            self.allocator.free(self.config.assets_path);
        }
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
            assets_path: ?[]const u8 = null,
        };

        const parsed = try std.json.parseFromSlice(ParsedConfig, self.allocator, content, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (parsed.value.assets_path) |path| {
            // Free old path if it wasn't default
            if (!std.mem.eql(u8, self.config.assets_path, "assets")) {
                self.allocator.free(self.config.assets_path);
            }
            self.config.assets_path = try self.allocator.dupe(u8, path);
        }

        log.cardinal_log_info("Config loaded: assets_path={s}", .{self.config.assets_path});
    }

    pub fn save(self: *ConfigManager) !void {
        const file = try std.fs.cwd().createFile(self.config_path, .{});
        defer file.close();

        const Options = struct {
            assets_path: []const u8,
        };

        const options = Options{
            .assets_path = self.config.assets_path,
        };

        // In recent Zig versions, File.writer() might not exist or work differently.
        // We can use std.io.bufferedWriter which wraps any writer-like struct?
        // Or just use file.writeAll if we serialize to string first.
        // But to keep it simple and use json.fmt:

        // If file.writer() requires a buffer, let's provide one?
        // But standard file writer shouldn't require one unless it's buffered.
        // Let's use generic writer if possible.
        // Or just create a buffered writer around the file handle?

        // Let's try to just write to file directly using writeAll after allocPrint?
        // No, we want to stream.

        // Let's use stringify to an ArrayListUnmanaged then write to file.
        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(self.allocator);

        try list.writer(self.allocator).print("{f}", .{std.json.fmt(options, .{ .whitespace = .indent_4 })});
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
