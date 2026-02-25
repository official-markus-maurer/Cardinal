const std = @import("std");

pub const ProjectConfig = struct {
    name: []const u8 = "Untitled Project",
    version: []const u8 = "0.1.0",
    assets_dir: []const u8 = "assets",
};

pub const Project = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,
    config: ProjectConfig,
    config_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) !Project {
        const root_dupe = try allocator.dupe(u8, root_path);
        const config_path = try std.fs.path.join(allocator, &[_][]const u8{ root_dupe, "cardinal.project" });

        return .{
            .allocator = allocator,
            .root_path = root_dupe,
            .config = .{},
            .config_path = config_path,
        };
    }

    pub fn deinit(self: *Project) void {
        self.allocator.free(self.root_path);
        self.allocator.free(self.config_path);
        // We own the strings in config if they were allocated/duped during load.
        // For simplicity in this v1, we rely on the fact that we dupe them on load.
        // However, defaults are string literals. We need to be careful.
        // A better approach for strings in structs is to always own them or use a dedicated arena.
        // For now, let's assume if they are not the defaults, they are allocated.
        if (!std.mem.eql(u8, self.config.name, "Untitled Project")) self.allocator.free(self.config.name);
        if (!std.mem.eql(u8, self.config.version, "0.1.0")) self.allocator.free(self.config.version);
        if (!std.mem.eql(u8, self.config.assets_dir, "assets")) self.allocator.free(self.config.assets_dir);
    }

    pub fn load(self: *Project) !void {
        const file = std.fs.openFileAbsolute(self.config_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // If no config exists, create a default one
                try self.save();
                return;
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 10);
        defer self.allocator.free(content);

        const ParsedConfig = struct {
            name: ?[]const u8 = null,
            version: ?[]const u8 = null,
            assets_dir: ?[]const u8 = null,
        };

        const parsed = try std.json.parseFromSlice(ParsedConfig, self.allocator, content, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (parsed.value.name) |val| {
            if (!std.mem.eql(u8, self.config.name, "Untitled Project")) self.allocator.free(self.config.name);
            self.config.name = try self.allocator.dupe(u8, val);
        }
        if (parsed.value.version) |val| {
            if (!std.mem.eql(u8, self.config.version, "0.1.0")) self.allocator.free(self.config.version);
            self.config.version = try self.allocator.dupe(u8, val);
        }
        if (parsed.value.assets_dir) |val| {
            if (!std.mem.eql(u8, self.config.assets_dir, "assets")) self.allocator.free(self.config.assets_dir);
            self.config.assets_dir = try self.allocator.dupe(u8, val);
        }
    }

    pub fn save(self: *Project) !void {
        const file = try std.fs.createFileAbsolute(self.config_path, .{});
        defer file.close();

        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(self.allocator);

        try list.writer(self.allocator).print("{f}", .{std.json.fmt(self.config, .{ .whitespace = .indent_4 })});
        try file.writeAll(list.items);
    }
    
    pub fn getAssetsPath(self: *Project) ![]const u8 {
        return std.fs.path.join(self.allocator, &[_][]const u8{ self.root_path, self.config.assets_dir });
    }
};
