//! Engine test runner.

test {
    _ = @import("assets/scene_serializer.zig");
    _ = @import("assets/animation_sampling.zig");
    _ = @import("core/handle_manager.zig");
    _ = @import("core/events.zig");
    _ = @import("core/pool_allocator.zig");
}
