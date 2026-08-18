const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .windows,
            .abi = .gnu,
        },
    });

    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const version = blk: {
        const version_file = std.fs.cwd().readFileAlloc(
            b.allocator,
            "VERSION",
            1024,
        ) catch "0.0.0";
        break :blk std.mem.trim(u8, version_file, &std.ascii.whitespace);
    };

    const exe = b.addExecutable(.{
        .name = "eve-maj-preview",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .version = std.SemanticVersion.parse(version) catch .{ .major = 0, .minor = 0, .patch = 0 },
        .win32_manifest = null,
    });

    // Windows subsystem hides the console window; main.zig calls AllocConsole() itself when logLevel == .debug, so debug builds still get a console.
    exe.subsystem = .Windows;

    // Default Windows stack size is often too small.
    exe.stack_size = 16 * 1024 * 1024;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    exe.root_module.addOptions("build_options", options);

    exe.root_module.linkSystemLibrary("c", .{});
    exe.root_module.linkSystemLibrary("user32", .{});
    exe.root_module.linkSystemLibrary("gdi32", .{});
    exe.root_module.linkSystemLibrary("dwmapi", .{});
    exe.root_module.linkSystemLibrary("psapi", .{});
    exe.root_module.linkSystemLibrary("shell32", .{});
    exe.root_module.linkSystemLibrary("ole32", .{});
    exe.root_module.linkSystemLibrary("oleaut32", .{});
    exe.root_module.linkSystemLibrary("dbghelp", .{});

    exe.addWin32ResourceFile(.{
        .file = b.path("app.rc"),
    });

    const tray_icon = b.addInstallBinFile(b.path("icon.ico"), "icon.ico");
    exe.step.dependOn(&tray_icon.step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Add zig-webui dependency for configuration dialog
    const zig_webui = b.dependency("zig_webui", .{
        .target = target,
        .optimize = optimize,
        .enable_tls = false,
        .is_static = true,
    });

    const config_dialog = b.addExecutable(.{
        .name = "config",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config_dialog.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    config_dialog.subsystem = .Windows;

    // Resource file includes the app icon, so the taskbar shows the tray icon instead of the default exe icon.
    config_dialog.addWin32ResourceFile(.{
        .file = b.path("app.rc"),
    });

    config_dialog.root_module.addImport("webui", zig_webui.module("webui"));

    config_dialog.root_module.linkSystemLibrary("c", .{});
    config_dialog.root_module.linkSystemLibrary("user32", .{});
    config_dialog.root_module.linkSystemLibrary("gdi32", .{});
    config_dialog.root_module.linkSystemLibrary("shell32", .{});
    config_dialog.root_module.linkSystemLibrary("psapi", .{});

    config_dialog.root_module.addOptions("build_options", options);

    b.installArtifact(config_dialog);

    const config_dialog_run = b.addRunArtifact(config_dialog);
    config_dialog_run.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        config_dialog_run.addArgs(args);
    }

    const config_dialog_step = b.step("config", "Run the configuration dialog");
    config_dialog_step.dependOn(&config_dialog_run.step);

    const gamelog_viewer = b.addExecutable(.{
        .name = "gamelog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gamelog_viewer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    gamelog_viewer.subsystem = .Windows;

    // Resource file includes the app icon, so the taskbar shows the tray icon instead of the default exe icon.
    gamelog_viewer.addWin32ResourceFile(.{
        .file = b.path("app.rc"),
    });

    gamelog_viewer.root_module.addImport("webui", zig_webui.module("webui"));

    gamelog_viewer.root_module.linkSystemLibrary("c", .{});
    gamelog_viewer.root_module.linkSystemLibrary("user32", .{});
    gamelog_viewer.root_module.linkSystemLibrary("gdi32", .{});
    gamelog_viewer.root_module.linkSystemLibrary("shell32", .{});
    gamelog_viewer.root_module.linkSystemLibrary("psapi", .{});

    b.installArtifact(gamelog_viewer);

    const gamelog_viewer_run = b.addRunArtifact(gamelog_viewer);
    gamelog_viewer_run.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        gamelog_viewer_run.addArgs(args);
    }

    const gamelog_viewer_step = b.step("gamelog", "Run the gamelog viewer");
    gamelog_viewer_step.dependOn(&gamelog_viewer_run.step);
}
