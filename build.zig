const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .windows,
            .abi = .gnu,
        },
    });

    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .fast });

    b.dependOnFileContents(b.path("VERSION"));
    const version = blk: {
        const version_file = std.Io.Dir.cwd().readFileAlloc(
            b.graph.io,
            "VERSION",
            b.allocator,
            .limited(1024),
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
    exe.subsystem = .windows;

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
    exe.root_module.linkSystemLibrary("pdh", .{});
    exe.root_module.linkSystemLibrary("shell32", .{});
    exe.root_module.linkSystemLibrary("ole32", .{});
    exe.root_module.linkSystemLibrary("oleaut32", .{});
    exe.root_module.linkSystemLibrary("dbghelp", .{});
    exe.root_module.linkSystemLibrary("shcore", .{});
    exe.root_module.linkSystemLibrary("winmm", .{});
    exe.root_module.linkSystemLibrary("mfplat", .{});
    exe.root_module.linkSystemLibrary("mfreadwrite", .{});

    exe.root_module.addWin32ResourceFile(.{
        .file = b.path("app.rc"),
    });

    // The configuration window is a WebView2 page hosted in this process, via webview/webview (deps/webview) and src/platform/webview_shim.cpp.
    exe.root_module.addIncludePath(b.path("deps/webview/include"));
    exe.root_module.addIncludePath(b.path("deps/webview/compat"));
    exe.root_module.addCSourceFiles(.{
        .files = &.{ "deps/webview/src/webview.cc", "src/platform/webview_shim.cpp" },
        .flags = &.{ "-std=c++17", "-DWEBVIEW_STATIC" },
    });
    exe.root_module.link_libcpp = true;
    exe.root_module.linkSystemLibrary("shlwapi", .{});
    exe.root_module.linkSystemLibrary("version", .{});
    exe.root_module.linkSystemLibrary("advapi32", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const config_run = b.addRunArtifact(exe);
    config_run.addArg("--config");
    config_run.step.dependOn(b.getInstallStep());

    const config_step = b.step("config", "Run the app with the configuration window open");
    config_step.dependOn(&config_run.step);

    // Debug, for the safety checks the release build's default optimize mode leaves out.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    const test_step = b.step("test", "Run the unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
