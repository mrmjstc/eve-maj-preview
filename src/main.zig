//! Entry point: process setup, the single-instance check, loading and starting the App, and the hidden timer window whose messages drive it.
const std = @import("std");
const build_options = @import("build_options");
const win32 = @import("platform/win32.zig");
const gdi_overlay = @import("platform/gdi_overlay.zig");
const fonts = @import("platform/fonts.zig");
const focus_grant = @import("platform/focus_grant.zig");
const crash = @import("crash.zig");
const arguments = @import("arguments.zig");
const app_mod = @import("app.zig");
const config = @import("config.zig");
const focus = @import("control/focus.zig");
const character_ids_mod = @import("chatlog/character_ids.zig");
const keyboard_hook = @import("hotkeys/keyboard_hook.zig");
const hooks = @import("hotkeys/hooks.zig");
const hook_thread = @import("hotkeys/hook_thread.zig");
const tts = @import("notifications/tts.zig");
const sound = @import("notifications/sound.zig");
const ipc = @import("protocol/ipc.zig");
const run = @import("protocol/run.zig");
const url = @import("protocol/url.zig");
const update = @import("update.zig");
const knots_host = @import("dialog/knots/host.zig");
const lang = @import("lang/lang.zig");
const detached = @import("util/detached.zig");
const messages = @import("messages.zig");
const log = @import("log.zig");

const App = app_mod.App;
const CharacterIds = character_ids_mod.CharacterIds;
const slog = log.Scoped("main");

const INSTANCE_WAIT_ATTEMPTS = 100;
const INSTANCE_WAIT_INTERVAL_MS = 100;
/// Enough for a request finishing as the app exits, without holding exit up; past it, main ends the process rather than returning.
const DETACHED_EXIT_WAIT_MS = 2000;

/// Routes panics into eve-maj.log; Zig only looks for `panic` in the root source file.
pub const panic = std.debug.FullPanic(crash.handlePanic);

pub fn main(init: std.process.Init) void {
    // First, so it runs after every other defer.
    defer detached.exitIfAnyRunning();
    // Must precede any window/monitor API call, or Windows bitmap-stretches our windows on scaled monitors.
    _ = win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    // Before the crash handlers, which log.
    log.setIo(init.io);
    crash.install();
    defer log.deinitFile();

    mainImpl(init) catch |err| {
        slog.err("Failed to run EVE-Maj Preview: {}", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(trace);
        }
        std.process.exit(1);
    };
}

fn mainImpl(init: std.process.Init) !void {
    const allocator = init.gpa;
    tts.setup(init.io, allocator);
    sound.setup(init.io, allocator);
    config.setEnvironMap(init.environ_map);

    const is_in_executable_dir = setCwdToExecutableDir();
    config.migrateLegacyLayout(init.io);

    // toSlice's result spans several allocations, so it takes an arena.
    var args_arena: std.heap.ArenaAllocator = .init(allocator);
    defer args_arena.deinit();
    const parsed = arguments.parse(try init.minimal.args.toSlice(args_arena.allocator()));

    // Before the mutex check, so commands work even when another instance is already running.
    if (parsed.protocol_url) |protocol_url| {
        slog.info("Protocol handler invoked: {s}", .{protocol_url});
        return ipc.forwardToRunningInstance(protocol_url);
    }

    const instance_mutex = try claimSingleInstance(init.io) orelse return;
    defer _ = win32.CloseHandle(instance_mutex);

    if (parsed.invalid) |invalid| {
        switch (invalid) {
            .missing_profile_name => slog.err("Failed to parse arguments: --profile needs a profile name", .{}),
            .unknown => |arg| slog.err("Failed to parse arguments: unknown argument '{s}'", .{arg}),
        }
        return error.InvalidArguments;
    }

    slog.info("EVE-Maj Preview v{s}", .{build_options.version});
    // Elsewhere, the folders it would sweep might not be the app's.
    if (is_in_executable_dir) config.sweepTempFiles(init.io);

    fonts.loadBundled();

    const instance = win32.GetModuleHandleA(null) orelse return error.GetModuleHandleFailed;

    // Before the App, whose deinit unregisters the hotkey manager's hooks through this thread.
    hooks.setAllocator(allocator);
    hook_thread.start();
    defer {
        hooks.deinit();
        hook_thread.stop();
    }

    var app: App = .init(allocator, init.io, instance, try loadFromDisk(allocator, init.io, parsed.profile));
    // Registered before app.deinit, so callbacks lose the app only once it's torn down.
    app_mod.g_app = &app;
    defer app_mod.g_app = null;
    defer app.deinit();
    app.dialog = knots_host.init(app.dialogContext(), app_mod.DIALOG_HOST);
    defer knots_host.deinit();
    lang.init(allocator, app.global_settings.language);
    defer lang.deinit();
    defer update.g_update_status.deinit(init.io);
    // Before anything starts a thread, so it runs before the deinits of the state they use, even on a failed startup.
    defer waitForBackgroundThreads(&app, init.io);

    defer tts.shutdown();
    defer sound.shutdown();

    const timer_hwnd = try createTimerWindow();
    try app.start(timer_hwnd);
    focus_grant.install(timer_hwnd);
    defer focus_grant.uninstall();

    if (app.global_settings.disableUpdateChecks) slog.info("Update checks are disabled", .{}) else startUpdateCheck(allocator, init.io);

    if (parsed.should_open_config) knots_host.open();

    var msg: win32.MSG = undefined;
    while (win32.GetMessageA(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageA(&msg);
    }
}

/// Each after what it needs: the global settings before anything else logs, the last used profile before the profile; `profile_arg` is --profile's.
fn loadFromDisk(allocator: std.mem.Allocator, io: std.Io, profile_arg: ?[]const u8) !app_mod.Loaded {
    var global_settings: config.GlobalConfig = try .load(allocator, io);
    errdefer global_settings.deinit();
    app_mod.applyGlobalSettings(&global_settings);
    // Before the dump, so it shows any Log Monitoring a profile brings along.
    global_settings.finishLoading(io);
    global_settings.logSettings();
    var character_ids: CharacterIds = .load(allocator, io);
    errdefer character_ids.deinit();

    const last_used = global_settings.lastUsedProfile;
    const profile_name = profile_arg orelse if (last_used.len > 0) last_used else config.DEFAULT_PROFILE;
    const store: config.ProfileStore = try .init(try config.loadProfile(allocator, io, profile_name), io);
    return .{ .global_settings = global_settings, .character_ids = character_ids, .store = store };
}

/// The instance mutex, which the caller closes at exit; null when another instance runs, now asked to open its configuration window.
fn claimSingleInstance(io: std.Io) !?win32.HANDLE {
    const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Global\\EVE-Maj-Preview-SingleInstance");
    const instance_mutex = win32.CreateMutexW(null, win32.TRUE, mutex_name) orelse {
        slog.err("Failed to create instance mutex", .{});
        return error.CreateMutexFailed;
    };
    // Read straight after CreateMutexW, which sets it.
    if (win32.GetLastError() != win32.ERROR_ALREADY_EXISTS) return instance_mutex;
    _ = win32.CloseHandle(instance_mutex);

    const hwnd = waitForInstanceWindow(io) orelse {
        slog.info("Another instance of EVE-Maj Preview is already running", .{});
        return error.AlreadyRunning;
    };
    try ipc.send(hwnd, url.OPEN_CONFIG_URL);
    return null;
}

/// Polls because the other instance may hold the mutex but still be starting up, e.g. when the installer launches both at once.
fn waitForInstanceWindow(io: std.Io) ?win32.HWND {
    for (0..INSTANCE_WAIT_ATTEMPTS) |_| {
        if (ipc.findExistingInstance()) |hwnd| return hwnd;
        std.Io.sleep(io, .fromMilliseconds(INSTANCE_WAIT_INTERVAL_MS), .awake) catch |err| {
            slog.warn("Failed to wait for the running instance's window: {}", .{err});
            return null;
        };
    }
    return ipc.findExistingInstance();
}

/// The hidden window whose WM_TIMER drives the app; never shown, so its class's cursor never shows either.
fn createTimerWindow() !win32.HWND {
    const instance = win32.GetModuleHandleA(null) orelse return error.GetModuleHandleFailed;
    try gdi_overlay.registerWindowClass(instance, timerWindowProc, ipc.MAIN_WINDOW_CLASS, null);
    const hwnd = win32.CreateWindowExA(0, ipc.MAIN_WINDOW_CLASS, "EVE Timer Window", 0, 0, 0, 0, 0, null, null, instance, null) orelse return error.CreateWindowFailed;
    // An elevated instance otherwise never receives commands from an unelevated second launch or browser link.
    if (!win32.toBool(win32.ChangeWindowMessageFilterEx(hwnd, win32.WM_COPYDATA, win32.MSGFLT_ALLOW, null))) {
        slog.warn("Failed to let commands through to an elevated instance, so protocol links and second launches may not reach it: error {d}", .{win32.GetLastError()});
    }
    return hwnd;
}

/// Past the wait, ending the process is safer than tearing down what a thread still uses.
fn waitForBackgroundThreads(app: *App, io: std.Io) void {
    if (detached.waitForAll(io, DETACHED_EXIT_WAIT_MS)) return;
    app.saveBeforeAbruptExit();
    std.process.exit(0);
}

fn startUpdateCheck(allocator: std.mem.Allocator, io: std.Io) void {
    detached.spawn(update.checkForUpdatesBackground, .{ allocator, io }) catch |err| {
        slog.warn("Failed to start update check thread: {}", .{err});
    };
}

/// Run-key startup entries launch with an arbitrary working directory, not the exe's folder; false if it couldn't be changed.
fn setCwdToExecutableDir() bool {
    var executable_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_dir = win32.selfExecutableDirPath(&executable_dir_buf) catch |err| {
        slog.warn("Failed to resolve the executable directory: {}", .{err});
        return false;
    };

    var terminated_dir_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const terminated_dir = std.mem.printSentinel(&terminated_dir_buf, "{s}", .{executable_dir}, 0) catch |err| {
        slog.warn("Failed to null-terminate the executable directory path: {}", .{err});
        return false;
    };

    if (!win32.toBool(win32.SetCurrentDirectoryA(terminated_dir))) {
        slog.warn("Failed to set the working directory to '{s}': error {d}", .{ executable_dir, win32.GetLastError() });
        return false;
    }
    return true;
}

fn timerWindowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    const app = app_mod.g_app orelse return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
    switch (msg) {
        messages.WM_TRAYICON => {
            if (app.tray_icon) |*icon| icon.handleTrayMessage(lParam, app);
            return 0;
        },
        win32.WM_COMMAND => {
            if (app.tray_icon) |*icon| icon.handleMenuCommand(@truncate(wParam), app);
            return 0;
        },
        win32.WM_TIMER => {
            if (wParam == messages.TICK_TIMER_ID) {
                app.tick();
            } else if (wParam == messages.HIDE_DEBOUNCE_TIMER_ID) {
                focus.onHideTimer(app);
            }
            return 0;
        },
        win32.WM_HOTKEY => {
            // Any process can post here; an id out of range is none of ours.
            const id = std.math.cast(c_int, wParam) orelse return 0;
            if (!focus_grant.handleWmHotkey(id)) {
                if (app.hotkey_manager) |manager| app.runHotkeyOutcome(manager.handleHotkeyPress(id, lParam, &app.commands(), app.thumbnail_set));
            }
            return 0;
        },
        messages.WM_HOTKEYS_STATE_CHANGED => {
            if (app.hotkey_manager) |manager| {
                app.notifier().notifyAll(.{
                    .notification_type = .HotkeySuspend,
                    .state = if (manager.areHotkeysSuspended()) .suspended else .resumed,
                });
            }
            return 0;
        },
        messages.WM_SWITCH_PROFILE => {
            app.runPendingProfileSwitch();
            return 0;
        },
        win32.WM_COPYDATA => {
            run.handleCopyData(app, win32.lparamToPtr(win32.COPYDATASTRUCT, lParam));
            return 0;
        },
        messages.WM_WIN_KEY_CAPTURED => {
            keyboard_hook.onWinKeyCaptured(wParam);
            return 0;
        },
        messages.WM_KNOTS_COMMAND => {
            knots_host.onCommand(wParam);
            return 0;
        },
        win32.WM_ENDSESSION => {
            // Windows may end the process as soon as this returns, skipping teardown.
            if (wParam != win32.FALSE) {
                slog.info("Windows session ending, saving state", .{});
                app.saveBeforeAbruptExit();
            }
            return 0;
        },
        else => {
            if (app.tray_icon) |*icon| {
                if (icon.handleTaskbarCreated(msg)) return 0;
            }
            return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
        },
    }
}
