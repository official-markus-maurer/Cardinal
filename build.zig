const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Check for VULKAN_SDK
    const vulkan_sdk = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch null;

    const enable_tracy = b.option(bool, "enable_tracy", "Enable Tracy Profiler") orelse true;

    // =========================================================================
    // Tracy (Static Library)
    // =========================================================================
    const tracy = b.addLibrary(.{
        .name = "tracy",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });

    tracy.linkLibCpp();
    tracy.addIncludePath(b.path("libs/tracy/public"));

    if (enable_tracy) {
        tracy.root_module.addCMacro("TRACY_ENABLE", "");
        tracy.root_module.addCMacro("TRACY_NO_SYSTEM_TRACING", "");
        tracy.addCSourceFile(.{
            .file = b.path("libs/tracy/public/TracyClient.cpp"),
            .flags = &.{ "-DTRACY_ENABLE", "-DTRACY_NO_SYSTEM_TRACING", "-fno-sanitize=undefined" },
        });

        if (target.result.os.tag == .windows) {
            tracy.linkSystemLibrary("ws2_32");
            tracy.linkSystemLibrary("dbghelp");
            tracy.linkSystemLibrary("user32");
            tracy.linkSystemLibrary("secur32");
            tracy.linkSystemLibrary("advapi32");
        }
    }

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

    engine.addIncludePath(b.path("engine/src"));
    engine.addIncludePath(b.path("engine/src/renderer"));
    engine.addIncludePath(b.path("libs/cgltf"));
    engine.addIncludePath(b.path("libs/stb"));
    engine.addIncludePath(b.path("libs/tinyexr"));
    engine.addIncludePath(b.path("libs/tinyexr/deps/miniz"));
    engine.addIncludePath(b.path("libs/glfw/include"));
    engine.addIncludePath(b.path("libs/tracy/public"));

    if (vulkan_sdk) |sdk| {
        engine.addIncludePath(.{ .cwd_relative = b.fmt("{s}/Include", .{sdk}) });
    }

    engine.root_module.addCMacro("GLFW_INCLUDE_VULKAN", "");
    engine.root_module.addCMacro("VK_USE_PLATFORM_WIN32_KHR", "");
    engine.root_module.addCMacro("CARDINAL_ENGINE_INTERNAL", "");
    engine.root_module.addCMacro("_CRT_SECURE_NO_WARNINGS", "");

    const options = b.addOptions();
    options.addOption(bool, "enable_tracy", enable_tracy);
    engine.root_module.addOptions("build_options", options);

    if (enable_tracy) {
        engine.root_module.addCMacro("TRACY_ENABLE", "");
    }

    // Generate C implementation files
    const gen_c_files = b.addWriteFiles();

    const stb_impl_c = gen_c_files.add("stb_impl.c",
        \\#define STB_IMAGE_IMPLEMENTATION
        \\#define STBI_NO_PSD
        \\#define STBI_NO_PIC
        \\#define STBI_NO_PNM
        \\#define STBI_NO_GIF
        \\#define STBI_NO_TGA
        \\#include <stdlib.h>
        \\#include "stb_image.h"
    );

    const cgltf_impl_c = gen_c_files.add("cgltf_impl.c",
        \\#define CGLTF_IMPLEMENTATION
        \\#include "cgltf.h"
    );

    const tinyexr_impl_cpp = gen_c_files.add("tinyexr_impl.cc",
        \\#define TINYEXR_IMPLEMENTATION
        \\#include "tinyexr.h"
    );

    // Compile stb_image implementation
    engine.addCSourceFile(.{
        .file = stb_impl_c,
        .flags = &.{"-std=c17"},
    });

    // Compile cgltf implementation
    engine.addCSourceFile(.{
        .file = cgltf_impl_c,
        .flags = &.{"-std=c17"},
    });

    // Compile tinyexr implementation
    engine.addCSourceFile(.{
        .file = tinyexr_impl_cpp,
        .flags = &.{ "-std=c++14", "-fno-sanitize=undefined" },
    });

    // Compile miniz
    engine.addCSourceFile(.{
        .file = b.path("libs/tinyexr/deps/miniz/miniz.c"),
        .flags = &.{"-std=c11"},
    });

    // Compile VMA implementation
    engine.addCSourceFile(.{
        .file = b.path("engine/src/renderer/vma_implementation.cpp"),
        .flags = &.{"-std=c++20"},
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
            .root_source_file = b.path("client/src/main.zig"),
        }),
    });

    client.addIncludePath(b.path("libs/cgltf"));
    client.addIncludePath(b.path("libs/stb"));

    client.linkLibCpp();
    client.linkLibrary(tracy);
    // client.linkLibrary(engine); // Use module import instead to avoid duplicate symbols
    client.linkLibrary(glfw);
    if (vulkan_sdk) |sdk| {
        client.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/Lib", .{sdk}) });
        client.addIncludePath(.{ .cwd_relative = b.fmt("{s}/Include", .{sdk}) });
    }
    client.linkSystemLibrary("vulkan-1"); // Link Vulkan directly

    client.root_module.addImport("cardinal_engine", engine.root_module);
    // client.addCSourceFiles(.{
    //     .files = engine_sources,
    //     .flags = &.{"-std=c17"},
    // });

    b.installArtifact(client);

    // =========================================================================
    // Editor (Executable)
    // =========================================================================
    const editor = b.addExecutable(.{
        .name = "CardinalEditor",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("editor/src/main.zig"),
        }),
    });

    editor.root_module.addImport("cardinal_engine", engine.root_module);

    editor.addCSourceFiles(.{
        .files = &.{"editor/src/imgui_bridge.cpp"},
        .flags = &.{"-std=c++20"},
    });

    editor.addIncludePath(b.path("editor/include"));
    editor.addIncludePath(b.path("libs/cgltf"));
    editor.addIncludePath(b.path("libs/stb"));
    editor.addIncludePath(b.path("libs/imgui"));
    editor.addIncludePath(b.path("libs/imgui/backends"));
    editor.addIncludePath(b.path("libs/glfw/include"));
    editor.addIncludePath(b.path("libs/tracy/public"));

    editor.root_module.addCMacro("GLFW_INCLUDE_VULKAN", "");
    editor.root_module.addCMacro("IMGUI_DISABLE_OBSOLETE_FUNCTIONS", "");
    editor.root_module.addCMacro("IMGUI_ENABLE_DOCKING", "");

    if (enable_tracy) {
        editor.root_module.addCMacro("TRACY_ENABLE", "");
    }

    editor.linkLibCpp();
    editor.linkLibrary(tracy);
    // editor.linkLibrary(engine); // Use module import instead to avoid duplicate symbols
    editor.linkLibrary(imgui);
    editor.linkLibrary(glfw);
    if (vulkan_sdk) |sdk| {
        editor.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/Lib", .{sdk}) });
        editor.addIncludePath(.{ .cwd_relative = b.fmt("{s}/Include", .{sdk}) });
    }
    editor.linkSystemLibrary("vulkan-1"); // Link Vulkan directly

    // editor.addCSourceFiles(.{
    //     .files = engine_sources,
    //     .flags = &.{"-std=c17"},
    // });

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
