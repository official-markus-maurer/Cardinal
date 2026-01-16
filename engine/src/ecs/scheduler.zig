const std = @import("std");
const registry_pkg = @import("registry.zig");
const system_pkg = @import("system.zig");
const command_buffer_pkg = @import("command_buffer.zig");
const job_system = @import("../core/job_system.zig");
const log = @import("../core/log.zig");

const sched_log = log.ScopedLogger("ECS_SCHEDULER");

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    registry: *registry_pkg.Registry,
    systems: std.ArrayListUnmanaged(system_pkg.System),

    // Contexts for running jobs
    // We need these to persist during the frame
    contexts: std.ArrayListUnmanaged(SystemContext),

    // Command buffers for systems (one per context)
    command_buffers: std.ArrayListUnmanaged(command_buffer_pkg.CommandBuffer),

    pub const SystemContext = struct {
        system: system_pkg.System,
        registry: *registry_pkg.Registry,
        ecb: *command_buffer_pkg.CommandBuffer,
        delta_time: f32,
    };

    pub fn init(allocator: std.mem.Allocator, registry: *registry_pkg.Registry) Scheduler {
        return .{
            .allocator = allocator,
            .registry = registry,
            .systems = .{},
            .contexts = .{},
            .command_buffers = .{},
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.systems.deinit(self.allocator);
        self.contexts.deinit(self.allocator);

        for (self.command_buffers.items) |*ecb| {
            ecb.deinit();
        }
        self.command_buffers.deinit(self.allocator);
    }

    pub fn add(self: *Scheduler, system: system_pkg.System) !void {
        try self.systems.append(self.allocator, system);
    }

    fn system_job_wrapper(data: ?*anyopaque) callconv(.c) i32 {
        const ctx = @as(*SystemContext, @ptrCast(@alignCast(data)));
        ctx.system.update(ctx.registry, ctx.ecb, ctx.delta_time);
        return 0;
    }

    pub fn run(self: *Scheduler, delta_time: f32) !void {
        // Clear previous contexts
        self.contexts.clearRetainingCapacity();

        var last_writer = std.AutoHashMapUnmanaged(u64, *job_system.Job){};
        defer last_writer.deinit(self.allocator);
        var last_readers = std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(*job_system.Job)){};
        defer {
            var it = last_readers.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            last_readers.deinit(self.allocator);
        }

        var frame_jobs = std.ArrayListUnmanaged(*job_system.Job){};
        defer frame_jobs.deinit(self.allocator);

        // Ensure stable pointers for contexts
        try self.contexts.ensureTotalCapacity(self.allocator, self.systems.items.len);

        // Ensure command buffers
        if (self.command_buffers.items.len < self.systems.items.len) {
            const needed = self.systems.items.len - self.command_buffers.items.len;
            try self.command_buffers.ensureUnusedCapacity(self.allocator, needed);
            var i: usize = 0;
            while (i < needed) : (i += 1) {
                self.command_buffers.appendAssumeCapacity(command_buffer_pkg.CommandBuffer.init(self.allocator));
            }
        }

        for (self.systems.items, 0..) |sys, i| {
            // Allocate context in our stable list
            // We use addOneAssumeCapacity because we reserved enough space
            const ctx = self.contexts.addOneAssumeCapacity();
            ctx.* = .{
                .system = sys,
                .registry = self.registry,
                .ecb = &self.command_buffers.items[i],
                .delta_time = delta_time,
            };

            const job = job_system.create_job(system_job_wrapper, ctx, .NORMAL).?;
            job.push_to_completed_queue = false;
            try frame_jobs.append(self.allocator, job);

            // Calculate dependencies

            // 1. Reads
            for (sys.reads) |type_id| {
                // Must wait for last writer
                if (last_writer.get(type_id)) |writer| {
                    _ = job_system.add_dependency(job, writer);
                }

                // Add self to readers
                const result = try last_readers.getOrPut(self.allocator, type_id);
                if (!result.found_existing) {
                    result.value_ptr.* = .{};
                }
                try result.value_ptr.append(self.allocator, job);
            }

            // 2. Writes
            for (sys.writes) |type_id| {
                // Must wait for last writer
                if (last_writer.get(type_id)) |writer| {
                    _ = job_system.add_dependency(job, writer);
                }

                // Must wait for ALL previous readers
                if (last_readers.get(type_id)) |readers| {
                    for (readers.items) |reader| {
                        if (reader != job) {
                            _ = job_system.add_dependency(job, reader);
                        }
                    }
                }

                // Update last writer to self
                try last_writer.put(self.allocator, type_id, job);

                // Clear readers for this type, as they are now superseded by this writer
                if (last_readers.getPtr(type_id)) |readers| {
                    readers.clearRetainingCapacity();
                }
            }
        }

        // Submit all jobs
        for (frame_jobs.items) |job| {
            while (!job_system.submit_job(job)) {
                // Queue full, wait a bit
                std.Thread.yield() catch {};
            }
        }

        // Wait for all jobs to complete
        // This is a simple implementation. In a real engine, we might do other work here.
        var all_done = false;
        while (!all_done) {
            all_done = true;
            for (frame_jobs.items) |job| {
                if (job.status != .COMPLETED and job.status != .FAILED) {
                    all_done = false;
                    break;
                }
            }
            if (!all_done) {
                std.Thread.yield() catch {};
            }
        }

        // Flush command buffers
        for (self.command_buffers.items) |*ecb| {
            ecb.flush(self.registry) catch |err| {
                sched_log.err("Failed to flush command buffer: {}", .{err});
            };
        }

        // Cleanup jobs
        for (frame_jobs.items) |job| {
            job_system.free_job(job);
        }
    }
};

test "Scheduler Dependency Graph" {
    const allocator = std.testing.allocator;

    // Initialize Memory System (Required for JobSystem)
    const memory = @import("../core/memory.zig");
    memory.cardinal_memory_init(1024 * 1024); // 1MB
    defer memory.cardinal_memory_shutdown();

    // Initialize Job System
    const job_config = job_system.JobSystemConfig{
        .worker_thread_count = 2,
        .max_queue_size = 100,
        .enable_priority_queue = true,
    };
    if (!job_system.init(&job_config)) return error.JobSystemInitFailed;
    defer job_system.shutdown();

    // Initialize Registry
    var registry = registry_pkg.Registry.init(allocator);
    defer registry.deinit();

    var scheduler = Scheduler.init(allocator, &registry);
    defer scheduler.deinit();

    // Define dummy systems
    const CompA = struct { val: u32 };
    const CompB = struct { val: u32 };
    _ = CompB; // Fix unused

    const SysA = struct {
        fn update(reg: *registry_pkg.Registry, ecb: *command_buffer_pkg.CommandBuffer, dt: f32) void {
            _ = reg;
            _ = ecb;
            _ = dt;
            // std.debug.print("SysA\n", .{});
        }
    };
    const SysB = struct {
        fn update(reg: *registry_pkg.Registry, ecb: *command_buffer_pkg.CommandBuffer, dt: f32) void {
            _ = reg;
            _ = ecb;
            _ = dt;
            // std.debug.print("SysB\n", .{});
        }
    };

    // SysA writes CompA
    // SysB reads CompA
    // Expect dependency A -> B

    try scheduler.add(system_pkg.System{
        .name = "SysA",
        .update = SysA.update,
        .writes = &.{registry_pkg.Registry.get_type_id(CompA)},
    });

    try scheduler.add(system_pkg.System{
        .name = "SysB",
        .update = SysB.update,
        .reads = &.{registry_pkg.Registry.get_type_id(CompA)},
    });

    try scheduler.run(0.16);
}
