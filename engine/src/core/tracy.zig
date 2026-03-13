//! Tracy profiling integration.
//!
//! Exposes minimal wrappers around Tracy's C API. When Tracy is disabled at build time, all
//! functions compile to no-ops.
//!
//! TODO: Add scoped allocator tags for long-lived allocations when Tracy is enabled.
const std = @import("std");
const build_options = @import("build_options");

pub const c = @cImport({
    if (build_options.enable_tracy) {
        @cDefine("TRACY_ENABLE", "1");
    }
    @cInclude("tracy/TracyC.h");
});

pub const enabled = build_options.enable_tracy;

/// A scoped Tracy zone (RAII-style `end`).
pub const Zone = if (enabled) struct {
    ctx: c.TracyCZoneCtx,

    /// Ends the zone.
    pub fn end(self: Zone) void {
        c.___tracy_emit_zone_end(self.ctx);
    }
} else struct {
    /// Ends the zone (no-op when Tracy is disabled).
    pub fn end(_: Zone) void {}
};

/// Creates a named zone with unknown file/function metadata.
pub fn zone(comptime name: [:0]const u8) Zone {
    if (!enabled) return .{};

    const S = struct {
        var loc: c.___tracy_source_location_data = undefined;
        var initialized: bool = false;
    };

    if (!S.initialized) {
        S.loc.name = name.ptr;
        S.loc.function = "unknown";
        S.loc.file = "unknown";
        S.loc.line = 0;
        S.loc.color = 0;
        S.initialized = true;
    }

    return Zone{ .ctx = c.___tracy_emit_zone_begin(&S.loc, 1) };
}

/// Creates a zone using compile-time source location metadata.
pub fn zoneS(comptime src: std.builtin.SourceLocation, comptime name: ?[:0]const u8) Zone {
    if (!enabled) return .{};

    const S = struct {
        var loc: c.___tracy_source_location_data = undefined;
        var initialized: bool = false;
        const file = src.file ++ "\x00";
        const func = src.fn_name ++ "\x00";
    };

    if (!S.initialized) {
        S.loc.name = if (name) |n| n.ptr else null;
        S.loc.function = S.func.ptr;
        S.loc.file = S.file.ptr;
        S.loc.line = src.line;
        S.loc.color = 0;
        S.initialized = true;
    }

    return Zone{ .ctx = c.___tracy_emit_zone_begin(&S.loc, 1) };
}

/// Emits a global frame marker.
pub fn frameMark() void {
    if (enabled) {
        c.___tracy_emit_frame_mark(null);
    }
}

/// Emits a frame marker tagged with `name`.
pub fn frameMarkNamed(name: [:0]const u8) void {
    if (enabled) {
        c.___tracy_emit_frame_mark(name.ptr);
    }
}
