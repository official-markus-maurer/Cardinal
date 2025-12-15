const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Check for VULKAN_SDK
    const vulkan_sdk = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch null;

    // =========================================================================
    // GLFW (Static Library)
    // =========================================================================
    const glfw = b.addLibrary(.{
        .name = "glfw",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    
    glfw.linkLibC();
    glfw.addIncludePath(b.path("libs/glfw/include"));
    glfw.addIncludePath(b.path("libs/glfw/src")); // for internal headers
    
    glfw.root_module.addCMacro("_GLFW_WIN32", "");
    
    const glfw_sources = &[_][]const u8{
        "libs/glfw/src/context.c",
        "libs/glfw/src/init.c",
        "libs/glfw/src/input.c",
        "libs/glfw/src/monitor.c",
        "libs/glfw/src/platform.c",
        "libs/glfw/src/vulkan.c",
        "libs/glfw/src/window.c",
        "libs/glfw/src/win32_init.c",
        "libs/glfw/src/win32_joystick.c",
        "libs/glfw/src/win32_monitor.c",
        "libs/glfw/src/win32_time.c",
        "libs/glfw/src/win32_thread.c",
        "libs/glfw/src/win32_window.c",
        "libs/glfw/src/win32_module.c",
        "libs/glfw/src/wgl_context.c",
        "libs/glfw/src/egl_context.c",
        "libs/glfw/src/osmesa_context.c",
        "libs/glfw/src/null_init.c",
        "libs/glfw/src/null_monitor.c",
        "libs/glfw/src/null_window.c",
        "libs/glfw/src/null_joystick.c",
    };
    
    glfw.addCSourceFiles(.{
        .files = glfw_sources,
        .flags = &.{},
    });
    
    glfw.linkSystemLibrary("gdi32");
    glfw.linkSystemLibrary("user32");
    glfw.linkSystemLibrary("shell32");

    // =========================================================================
    // ImGui (Static Library)
    // =========================================================================
    const imgui = b.addLibrary(.{
        .name = "imgui",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    
    imgui.linkLibCpp();
    imgui.addIncludePath(b.path("libs/imgui"));
    imgui.addIncludePath(b.path("libs/imgui/backends"));
    imgui.addIncludePath(b.path("libs/glfw/include"));
    
    if (vulkan_sdk) |sdk| {
        imgui.addIncludePath(.{ .cwd_relative = b.fmt("{s}/Include", .{sdk}) });
    }

    const imgui_sources = &[_][]const u8{
        "libs/imgui/imgui.cpp",
        "libs/imgui/imgui_demo.cpp",
        "libs/imgui/imgui_draw.cpp",
        "libs/imgui/imgui_tables.cpp",
        "libs/imgui/imgui_widgets.cpp",
        "libs/imgui/backends/imgui_impl_glfw.cpp",
        "libs/imgui/backends/imgui_impl_vulkan.cpp",
    };
    
    imgui.addCSourceFiles(.{
        .files = imgui_sources,
        .flags = &.{"-std=c++20"},
    });
    
    imgui.root_module.addCMacro("IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "");
    imgui.root_module.addCMacro("IMGUI_ENABLE_DOCKING", "");

    // =========================================================================
    // Cardinal Engine (Static Library)
    // =========================================================================
    const engine = b.addLibrary(.{
        .name = "cardinal_engine",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    
    engine.linkLibC();
    engine.linkLibCpp(); 

    engine.addIncludePath(b.path("engine/include"));
    engine.addIncludePath(b.path("engine/src"));
    engine.addIncludePath(b.path("engine/src/renderer"));
    engine.addIncludePath(b.path("libs/cgltf"));
    engine.addIncludePath(b.path("libs/stb"));
    engine.addIncludePath(b.path("libs/spdlog/include"));
    engine.addIncludePath(b.path("libs/glfw/include"));
    
    if (vulkan_sdk) |sdk| {
        engine.addIncludePath(.{ .cwd_relative = b.fmt("{s}/Include", .{sdk}) });
    }

    engine.root_module.addCMacro("GLFW_INCLUDE_VULKAN", "");
    engine.root_module.addCMacro("VK_USE_PLATFORM_WIN32_KHR", "");
    engine.root_module.addCMacro("CARDINAL_ENGINE_INTERNAL", "");
    engine.root_module.addCMacro("CARDINAL_USE_SPDLOG", "1");
    engine.root_module.addCMacro("_CRT_SECURE_NO_WARNINGS", "");

    const engine_sources = &[_][]const u8{
        "engine/src/renderer/vulkan_renderer.c",
        "engine/src/renderer/vulkan_renderer_frame.c",
        "engine/src/renderer/vulkan_pipeline_manager.c",
        "engine/src/renderer/util/vulkan_descriptor_buffer_utils.c",
        "engine/src/renderer/util/vulkan_shader_utils.c",
        "engine/src/assets/stb_impl.c",
        "engine/src/assets/cgltf_impl.c",
    };

    engine.addCSourceFiles(.{
        .files = engine_sources,
        .flags = &.{"-std=c17"},
    });

    engine.root_module.root_source_file = b.path("engine/src/root.zig");

    engine.linkLibrary(glfw);
    if (vulkan_sdk) |sdk| {
        engine.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/Lib", .{sdk}) });
    }
    engine.linkSystemLibrary("vulkan-1");

    // =========================================================================
    // Client (Executable)
    // =========================================================================
    const client = b.addExecutable(.{
        .name = "CardinalClient",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    
    client.addCSourceFiles(.{
        .files = &.{"client/src/main.c"},
        .flags = &.{"-std=c17"},
    });
    
    client.addIncludePath(b.path("engine/include"));

    client.linkLibCpp();
    client.linkLibrary(engine);
    client.linkLibrary(glfw);
    if (vulkan_sdk) |sdk| {
        client.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/Lib", .{sdk}) });
        client.addIncludePath(.{ .cwd_relative = b.fmt("{s}/Include", .{sdk}) });
    }
    
    b.installArtifact(client);

    // =========================================================================
    // Editor (Executable)
    // =========================================================================
    const editor = b.addExecutable(.{
        .name = "CardinalEditor",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    
    editor.addCSourceFiles(.{
        .files = &.{"editor/src/main.c"},
        .flags = &.{"-std=c17"},
    });
    
    editor.addCSourceFiles(.{
        .files = &.{"editor/src/editor_layer.cpp"},
        .flags = &.{"-std=c++20"},
    });

    editor.addIncludePath(b.path("editor/include"));
    editor.addIncludePath(b.path("engine/include"));
    editor.addIncludePath(b.path("libs/imgui"));
    editor.addIncludePath(b.path("libs/imgui/backends"));
    editor.addIncludePath(b.path("libs/glfw/include"));
    
    editor.root_module.addCMacro("GLFW_INCLUDE_VULKAN", "");
    editor.root_module.addCMacro("IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "");
    editor.root_module.addCMacro("IMGUI_ENABLE_DOCKING", "");
    
    editor.linkLibCpp();
    editor.linkLibrary(engine);
    editor.linkLibrary(imgui);
    editor.linkLibrary(glfw);
    if (vulkan_sdk) |sdk| {
        editor.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/Lib", .{sdk}) });
        editor.addIncludePath(.{ .cwd_relative = b.fmt("{s}/Include", .{sdk}) });
    }
    
    b.installArtifact(editor);

    // =========================================================================
    // Run Steps
    // =========================================================================
    const run_client_cmd = b.addRunArtifact(client);
    run_client_cmd.step.dependOn(b.getInstallStep());
    const run_client_step = b.step("run-client", "Run the client application");
    run_client_step.dependOn(&run_client_cmd.step);

    const run_editor_cmd = b.addRunArtifact(editor);
    run_editor_cmd.step.dependOn(b.getInstallStep());
    const run_editor_step = b.step("run-editor", "Run the editor application");
    run_editor_step.dependOn(&run_editor_cmd.step);
}
