//! ECS system scheduler with job-based parallel execution.
//!
//! Systems declare read/write component sets; the scheduler builds dependencies to ensure
//! correct ordering and flushes each system's command buffer after execution.
const std = @import("std");
const registry_pkg = @import("registry.zig");
const system_pkg = @import("system.zig");
const command_buffer_pkg = @import("command_buffer.zig");
const job_system = @import("../core/job_system.zig");
const log = @import("../core/log.zig");

const sched_log = log.ScopedLogger("ECS_SCHEDULER");

/// Schedules systems, builds component access dependencies, and executes via the job system.
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    registry: *registry_pkg.Registry,
    systems: std.ArrayListUnmanaged(system_pkg.System),

    /// Per-system job contexts stored in a stable list for the duration of a frame.
    contexts: std.ArrayListUnmanaged(SystemContext),

    /// Per-system command buffers (one per scheduled system).
    command_buffers: std.ArrayListUnmanaged(command_buffer_pkg.CommandBuffer),

    last_writer: std.AutoHashMapUnmanaged(u64, *job_system.Job) = .{},
    last_readers: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(*job_system.Job)) = .{},
    frame_jobs: std.ArrayListUnmanaged(*job_system.Job) = .{},

    /// Context passed to job execution for one system.
    pub const SystemContext = struct {
        system: system_pkg.System,
        registry: *registry_pkg.Registry,
        ecb: *command_buffer_pkg.CommandBuffer,
        delta_time: f32,
    };

    /// Creates an empty scheduler bound to a registry.
    pub fn init(allocator: std.mem.Allocator, registry: *registry_pkg.Registry) Scheduler {
        return .{
            .allocator = allocator,
            .registry = registry,
            .systems = .{},
            .contexts = .{},
            .command_buffers = .{},
            .last_writer = .{},
            .last_readers = .{},
            .frame_jobs = .{},
        };
    }

    /// Releases system lists and command buffers.
    pub fn deinit(self: *Scheduler) void {
        self.last_writer.deinit(self.allocator);

        var it = self.last_readers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.last_readers.deinit(self.allocator);

        self.frame_jobs.deinit(self.allocator);

        self.systems.deinit(self.allocator);
        self.contexts.deinit(self.allocator);

        for (self.command_buffers.items) |*ecb| {
            ecb.deinit();
        }
        self.command_buffers.deinit(self.allocator);
    }

    /// Adds a system descriptor to the schedule.
    pub fn add(self: *Scheduler, system: system_pkg.System) !void {
        try self.systems.append(self.allocator, system);
        std.sort.pdq(system_pkg.System, self.systems.items, {}, struct {
            fn less_than(_: void, lhs: system_pkg.System, rhs: system_pkg.System) bool {
                if (lhs.priority != rhs.priority) return lhs.priority < rhs.priority;
                return std.mem.lessThan(u8, lhs.name, rhs.name);
            }
        }.less_than);
    }

    fn system_job_wrapper(data: ?*anyopaque) callconv(.c) i32 {
        const ctx = @as(*SystemContext, @ptrCast(@alignCast(data)));
        ctx.system.update(ctx.registry, ctx.ecb, ctx.delta_time);
        return 0;
    }

    /// Executes all scheduled systems for a frame.
    pub fn run(self: *Scheduler, delta_time: f32) !void {
        self.contexts.clearRetainingCapacity();
        self.frame_jobs.clearRetainingCapacity();

        self.last_writer.clearRetainingCapacity();
        var it = self.last_readers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.clearRetainingCapacity();
        }

        try self.contexts.ensureTotalCapacity(self.allocator, self.systems.items.len);

        if (self.command_buffers.items.len < self.systems.items.len) {
            const needed = self.systems.items.len - self.command_buffers.items.len;
            try self.command_buffers.ensureUnusedCapacity(self.allocator, needed);
            var i: usize = 0;
            while (i < needed) : (i += 1) {
                self.command_buffers.appendAssumeCapacity(command_buffer_pkg.CommandBuffer.init(self.allocator));
            }
        }

        for (self.systems.items, 0..) |sys, i| {
            const ctx = self.contexts.addOneAssumeCapacity();
            ctx.* = .{
                .system = sys,
                .registry = self.registry,
                .ecb = &self.command_buffers.items[i],
                .delta_time = delta_time,
            };

            const job = job_system.create_job(system_job_wrapper, ctx, .NORMAL).?;
            job.push_to_completed_queue = false;
            try self.frame_jobs.append(self.allocator, job);

            for (sys.reads) |type_id| {
                if (self.last_writer.get(type_id)) |writer| {
                    _ = job_system.add_dependency(job, writer);
                }

                const result = try self.last_readers.getOrPut(self.allocator, type_id);
                if (!result.found_existing) {
                    result.value_ptr.* = .{};
                }
                try result.value_ptr.append(self.allocator, job);
            }

            for (sys.writes) |type_id| {
                if (self.last_writer.get(type_id)) |writer| {
                    _ = job_system.add_dependency(job, writer);
                }

                if (self.last_readers.get(type_id)) |readers| {
                    for (readers.items) |reader| {
                        if (reader != job) {
                            _ = job_system.add_dependency(job, reader);
                        }
                    }
                }

                try self.last_writer.put(self.allocator, type_id, job);

                if (self.last_readers.getPtr(type_id)) |readers| {
                    readers.clearRetainingCapacity();
                }
            }
        }

        for (self.frame_jobs.items) |job| {
            while (!job_system.submit_job(job)) {
                std.Thread.yield() catch {};
            }
        }

        job_system.wait_for_jobs(self.frame_jobs.items);

        for (self.command_buffers.items[0..self.systems.items.len]) |*ecb| {
            ecb.flush(self.registry) catch |err| {
                sched_log.err("Failed to flush command buffer: {}", .{err});
            };
        }

        for (self.frame_jobs.items) |job| {
            job_system.free_job(job);
        }
    }
};

test "Scheduler Dependency Graph (writer before reader)" {
    const allocator = std.testing.allocator;

    const memory = @import("../core/memory.zig");
    memory.cardinal_memory_init(1024 * 1024);
    defer memory.cardinal_memory_shutdown();

    const job_config = job_system.JobSystemConfig{
        .worker_thread_count = 2,
        .max_queue_size = 100,
        .enable_priority_queue = true,
    };
    if (!job_system.init(&job_config)) return error.JobSystemInitFailed;
    defer job_system.shutdown();

    var registry = registry_pkg.Registry.init(allocator);
    defer registry.deinit();

    var scheduler = Scheduler.init(allocator, &registry);
    defer scheduler.deinit();

    const CompA = struct { val: u32 };
    const CompB = struct { val: u32 };
    _ = CompB;

    const SysA = struct {
        fn update(reg: *registry_pkg.Registry, ecb: *command_buffer_pkg.CommandBuffer, dt: f32) void {
            _ = reg;
            _ = ecb;
            _ = dt;
        }
    };
    const SysB = struct {
        fn update(reg: *registry_pkg.Registry, ecb: *command_buffer_pkg.CommandBuffer, dt: f32) void {
            _ = reg;
            _ = ecb;
            _ = dt;
        }
    };

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
