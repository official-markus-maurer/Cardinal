//! KFM (Gamebryo) scene loader.
//!
//! KFM files primarily reference a NIF plus optional KF animation entries. This loader resolves
//! the referenced NIF path relative to the KFM and then merges any listed KF files.
//!
//! TODO: Replace heuristic parsing with a schema-driven reader once the KFM format is finalized.
const std = @import("std");
const scene = @import("scene.zig");
const log = @import("../core/log.zig");
const memory = @import("../core/memory.zig");
const nif_loader = @import("nif_loader.zig");

const kfm_log = log.ScopedLogger("KFM");

/// Loads a KFM scene by loading its referenced NIF and merging any referenced KF animations.
pub export fn cardinal_kfm_load_scene(path: [*:0]const u8, out_scene: *scene.CardinalScene) callconv(.c) bool {
    kfm_log.warn("Loading KFM scene: {s}", .{path});

    const file = std.fs.cwd().openFileZ(path, .{}) catch |err| {
        kfm_log.err("Failed to open KFM file: {s}", .{@errorName(err)});
        return false;
    };
    defer file.close();

    const size = file.getEndPos() catch 0;
    if (size == 0) return false;

    const allocator = memory.cardinal_get_allocator_for_category(.ENGINE).as_allocator();
    const buffer = allocator.alloc(u8, size) catch return false;
    defer allocator.free(buffer);

    _ = file.readAll(buffer) catch return false;

    var reader = nif_loader.NifReader.init(allocator, buffer);
    defer reader.deinit();

    const header_str = reader.read_string_lf() catch return false;
    defer allocator.free(header_str);

    kfm_log.warn("KFM Header: {s}", .{header_str});

    if (reader.pos < reader.buffer.len) {
        _ = reader.read(u8) catch return false;
    }

    const nif_path_rel = reader.read_sized_string() catch return false;
    defer allocator.free(nif_path_rel);

    kfm_log.warn("KFM references NIF: {s}", .{nif_path_rel});

    const kfm_dir = std.fs.path.dirname(std.mem.span(path)) orelse ".";

    var clean_nif_path = nif_path_rel;
    if (std.mem.startsWith(u8, clean_nif_path, ".\\")) {
        clean_nif_path = clean_nif_path[2..];
    }

    const full_nif_path = std.fs.path.joinZ(allocator, &.{ kfm_dir, clean_nif_path }) catch return false;
    defer allocator.free(full_nif_path);

    kfm_log.warn("Resolved NIF path: {s}", .{full_nif_path});

    if (!nif_loader.cardinal_nif_load_scene(full_nif_path, out_scene)) {
        return false;
    }

    const master_path = reader.read_sized_string() catch null;
    if (master_path) |mp| {
        kfm_log.warn("KFM Master Path: {s}", .{mp});
        allocator.free(mp);
    }

    _ = reader.read(u32) catch 0;

    const num_anims = reader.read(u32) catch 0;
    kfm_log.warn("KFM Num Animations: {d}", .{num_anims});

    if (num_anims > 0 and num_anims < 1000) {
        var i: u32 = 0;
        while (i < num_anims) : (i += 1) {
            const anim_id = reader.read(u32) catch break;
            const anim_name = reader.read_sized_string() catch break;
            const anim_path = reader.read_sized_string() catch break;

            defer allocator.free(anim_name);
            defer allocator.free(anim_path);

            kfm_log.warn("KFM Animation {d}: ID={d}, Name={s}, Path={s}", .{ i, anim_id, anim_name, anim_path });

            if (anim_path.len > 0) {
                var clean_anim_path = anim_path;
                if (std.mem.startsWith(u8, clean_anim_path, ".\\")) {
                    clean_anim_path = clean_anim_path[2..];
                }

                if (std.ascii.endsWithIgnoreCase(clean_anim_path, ".kf")) {
                    const full_kf_path = std.fs.path.joinZ(allocator, &.{ kfm_dir, clean_anim_path }) catch continue;
                    defer allocator.free(full_kf_path);

                    if (!nif_loader.cardinal_nif_merge_kf(full_kf_path, out_scene)) {
                        kfm_log.err("Failed to merge KF animation: {s}", .{full_kf_path});
                    }
                }
            }
        }
    }

    return true;
}

test "kfm load then destroy" {
    memory.cardinal_memory_init(1024 * 1024 * 128);
    defer memory.cardinal_memory_shutdown();

    log.cardinal_log_init_with_level(.WARN);
    defer log.cardinal_log_shutdown();

    const ref_counting = @import("../core/ref_counting.zig");
    _ = ref_counting.cardinal_ref_counting_init(1009);
    defer ref_counting.cardinal_ref_counting_shutdown();

    var scn: scene.CardinalScene = std.mem.zeroes(scene.CardinalScene);
    const path_z = try std.fmt.allocPrintZ(std.testing.allocator, "{s}", .{"assets/models/decorate/f001.kfm"});
    defer std.testing.allocator.free(path_z);

    try std.testing.expect(cardinal_kfm_load_scene(path_z.ptr, &scn));
    scene.cardinal_scene_destroy(&scn);
}
