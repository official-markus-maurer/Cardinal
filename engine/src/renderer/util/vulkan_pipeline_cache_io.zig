//! Pipeline cache file helpers.
//!
//! Loads and saves `VkPipelineCache` blobs with a small checksum header and device validation.

const std = @import("std");

const c = @import("../vulkan_c.zig").c;
const vfs = @import("../../core/vfs.zig");

/// Cache file header magic ("CARD").
const CACHE_FILE_MAGIC: u32 = 0x43415244;
/// Cache file format version.
const CACHE_FILE_VERSION: u32 = 1;

/// File header written before the raw pipeline cache blob.
const CacheFileHeader = extern struct {
    magic: u32,
    version: u32,
    data_size: u64,
    checksum: u64,
};

/// Validates the cache blob against the current physical device.
fn validate_pipeline_cache_blob(physical_device: c.VkPhysicalDevice, blob: []const u8) bool {
    if (blob.len < @sizeOf(c.VkPipelineCacheHeaderVersionOne)) return false;
    const header: *const c.VkPipelineCacheHeaderVersionOne = @ptrCast(@alignCast(blob.ptr));
    if (header.headerVersion != c.VK_PIPELINE_CACHE_HEADER_VERSION_ONE) return false;

    var props: c.VkPhysicalDeviceProperties = undefined;
    c.vkGetPhysicalDeviceProperties(physical_device, &props);
    if (header.vendorID != props.vendorID) return false;
    if (header.deviceID != props.deviceID) return false;
    return std.mem.eql(u8, header.pipelineCacheUUID[0..c.VK_UUID_SIZE], props.pipelineCacheUUID[0..c.VK_UUID_SIZE]);
}

/// Loads pipeline cache seed data from disk, returning an owned blob to pass into `VkPipelineCacheCreateInfo`.
pub fn load_seed_data(allocator: std.mem.Allocator, physical_device: c.VkPhysicalDevice, cache_file_path: []const u8) ?[]u8 {
    var bytes = vfs.read_file_alloc(allocator, cache_file_path) catch return null;
    if (bytes.len == 0) {
        allocator.free(bytes);
        return null;
    }

    if (bytes.len >= @sizeOf(CacheFileHeader)) {
        const header: *const CacheFileHeader = @ptrCast(@alignCast(bytes.ptr));
        if (header.magic == CACHE_FILE_MAGIC and header.version == CACHE_FILE_VERSION and header.data_size > 0) {
            if (@as(u64, @intCast(bytes.len)) == @sizeOf(CacheFileHeader) + header.data_size and header.data_size <= std.math.maxInt(usize)) {
                const data_slice = bytes[@sizeOf(CacheFileHeader)..];
                const checksum = std.hash.Wyhash.hash(0, data_slice);
                if (checksum == header.checksum and validate_pipeline_cache_blob(physical_device, data_slice)) {
                    const out = allocator.dupe(u8, data_slice) catch {
                        allocator.free(bytes);
                        return null;
                    };
                    allocator.free(bytes);
                    return out;
                }
            }
        }
    }

    if (!validate_pipeline_cache_blob(physical_device, bytes)) {
        allocator.free(bytes);
        return null;
    }

    return bytes;
}

/// Saves `cache` to disk in the cache file format.
pub fn save_cache_file(allocator: std.mem.Allocator, device: c.VkDevice, cache: c.VkPipelineCache, cache_file_path: []const u8) void {
    var cache_size: usize = 0;
    if (c.vkGetPipelineCacheData(device, cache, &cache_size, null) != c.VK_SUCCESS or cache_size == 0) return;

    const data = allocator.alloc(u8, cache_size) catch return;
    defer allocator.free(data);
    if (c.vkGetPipelineCacheData(device, cache, &cache_size, data.ptr) != c.VK_SUCCESS) return;

    const checksum = std.hash.Wyhash.hash(0, data[0..cache_size]);
    const header = CacheFileHeader{
        .magic = CACHE_FILE_MAGIC,
        .version = CACHE_FILE_VERSION,
        .data_size = cache_size,
        .checksum = checksum,
    };
    vfs.write_file_parts(cache_file_path, std.mem.asBytes(&header), data[0..cache_size]) catch return;
}
