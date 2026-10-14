//! Entry point: process setup, the single-instance check, building the App in dependency order, and the hidden timer window whose messages drive it.
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
const scout = @import("clients/scout.zig");
const activation = @import("control/activation.zig");
const focus = @import("control/focus.zig");
const chatlog = @import("chatlog.zig");
const mouse_hook = @import("hotkeys/mouse_hook.zig");
const keyboard_hook = @import("hotkeys/keyboard_hook.zig");
const tts = @import("notifications/tts.zig");
const sound = @import("notifications/sound.zig");
const tray = @import("tray.zig");
const protocol = @import("protocol.zig");
const update = @import("update.zig");
const knots_host = @import("dialog/knots/host.zig");
const run_on_startup = @import("dialog/run_on_startup.zig");
const lang = @import("lang/lang.zig");
const log = @import("log.zig");

const App = app_mod.App;
const slog = log.Scoped("main");

const INSTANCE_WAIT_ATTEMPTS = 100;
const INSTANCE_WAIT_INTERVAL_MS = 100;

/// Routes panics into eve-maj.log; Zig only looks for `panic` in the root source file.
pub const panic = std.debug.FullPanic(crash.handlePanic);

pub fn main(init: std.process.Init) void {
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
    tts.setIo(init.io);
    sound.setIo(init.io);
    config.setEnvironMap(init.environ_map);

    var app: App = .init(allocator, init.io);
    // Registered first, so callbacks lose the app only once everything below is torn down.
    app_mod.g_app = &app;
    defer app_mod.g_app = null;
    knots_host.init(&app);
    defer knots_host.deinit();

    setCwdToExecutableDir();
    config.migrateLegacyLayout(init.io);

    // toSlice's result references several internal allocations, so it requires an arena rather than a plain allocator.
    var args_arena = std.heap.ArenaAllocator.init(allocator);
    defer args_arena.deinit();
    const parsed = arguments.parse(try init.minimal.args.toSlice(args_arena.allocator()));

    // Before the mutex check, so commands work even when another instance is already running.
    if (parsed.protocol_url) |url| {
        slog.info("Protocol handler invoked: {s}", .{url});
        return protocol.forwardToRunningInstance(url, allocator);
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

    fonts.loadBundled();

    app.global_settings = try config.GlobalConfig.load(allocator, init.io);
    defer app.global_settings.deinit();
    // Before the chatlog monitor, whose shutdown defer then runs first.
    app.character_ids = .load(allocator, init.io);
    defer app.character_ids.deinit();
    log.setLevel(app.global_settings.logLevel);
    app.global_settings.logSettings();
    // Every launch, since the Run value can be lost or point at a moved exe while the setting stays on.
    if (app.global_settings.runOnStartup) run_on_startup.apply(true);
    lang.init(allocator, app.global_settings.language);
    defer lang.deinit();

    const last_used = app.global_settings.lastUsedProfile;
    const profile_name = parsed.profile orelse if (last_used.len > 0) last_used else config.DEFAULT_PROFILE;
    app.store = try config.ProfileStore.init(try config.loadProfile(allocator, init.io, profile_name), init.io);
    defer app.store.deinit();

    // Not profile_name: loadProfile() may have fallen back to default, and this heals global settings to match.
    try app.global_settings.updateLastUsed(init.io, app.store.live.profile_name);

    app.store.live.logSettings();

    app.instance = win32.GetModuleHandleA(null) orelse return error.GetModuleHandleFailed;
    app.notifications.start(allocator, &app.store, app.instance);
    defer app.notifications.deinit(allocator);

    if (app.global_settings.autoRegisterProtocol) protocol.ensureRegistered(allocator);

    defer tts.shutdown();
    defer sound.shutdown();

    if (app.global_settings.logLevel == .debug) log.openDebugConsole();

    app.scout = scout.Scout.init(allocator, &app.store.saved);
    app.scout.listenForEvents();
    defer app.scout.deinit();

    // Before the thumbnail set, whose thumbnails read them as they're created.
    defer app.exclusions.deinit();
    defer app.auto_minimizer.deinit();

    const thumbnail_set = try app.createThumbnailSet();
    defer app.destroyThumbnailSet();

    if (app.store.live.chatlog.enabled) {
        app.chatlog_monitor = try app.createChatlogMonitor();
    } else {
        slog.info("Chatlog monitoring disabled", .{});
    }

    app.trackers.setup(&app.store.saved, app.chatlog_monitor);
    defer app.trackers.deinit();

    // Registered after the trackers' defer so it runs first (LIFO): the worker thread must stop before the trackers are freed, since it may be mid-iteration reading them.
    defer app.destroyChatlogMonitor();

    // Only now that the trackers are wired in, so the worker never observes them as null when they should be set.
    if (app.chatlog_monitor) |monitor| startChatlogMonitoring(monitor, app.store.live.characters.items);

    const timer_hwnd = try createTimerWindow();
    defer _ = win32.DestroyWindow(timer_hwnd);
    app.timer_hwnd = timer_hwnd;

    app.focus.start();
    defer app.focus.deinit(timer_hwnd);

    app.tray_icon = try tray.TrayIcon.init(allocator, timer_hwnd);
    defer if (app.tray_icon) |*icon| icon.deinit();

    app.update_checker = update.UpdateChecker.init(allocator, init.io);
    defer if (app.update_checker) |*checker| checker.deinit();
    if (app.global_settings.disableUpdateChecks) slog.info("Update checks are disabled", .{}) else startUpdateCheck(allocator, init.io);

    try app.scout.scanForEveWindows();

    // Thumbnails first, since they need no I/O; the chatlog monitor's slower log discovery follows.
    const eve_windows = app.scout.getWindows();
    thumbnail_set.populate(eve_windows, .{ .should_move_to_saved = app.store.live.autoMovePosition.moveOnStartup });

    if (app.chatlog_monitor) |monitor| app_mod.addChatlogCharacters(monitor, eve_windows);

    try app.createHotkeyManager(timer_hwnd);
    focus_grant.install(timer_hwnd);
    defer {
        app.destroyHotkeyManager();
        mouse_hook.deinit();
        keyboard_hook.deinit();
        focus_grant.uninstall();
    }

    if (!app.setTickInterval(timer_hwnd, app.tickIntervalFor(eve_windows.len))) {
        slog.err("Failed to create timer", .{});
        return error.SetTimerFailed;
    }
    defer _ = win32.KillTimer(timer_hwnd, app_mod.TICK_TIMER_ID);

    if (parsed.should_open_config) knots_host.open();

    var msg: win32.MSG = undefined;
    while (win32.GetMessageA(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageA(&msg);
    }
}

/// The instance mutex, for the caller to close at exit; null when another instance is running, which has been asked to open its configuration window instead.
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
    protocol.sendCommandToInstance(hwnd, .{ .open_config = {} });
    return null;
}

/// Polls because the other instance may hold the mutex but still be starting up, e.g. when the installer launches both at once.
fn waitForInstanceWindow(io: std.Io) ?win32.HWND {
    for (0..INSTANCE_WAIT_ATTEMPTS) |_| {
        if (protocol.findExistingInstance()) |hwnd| return hwnd;
        std.Io.sleep(io, .fromMilliseconds(INSTANCE_WAIT_INTERVAL_MS), .awake) catch |err| {
            slog.warn("Failed to wait for the running instance's window: {}", .{err});
            return null;
        };
    }
    return protocol.findExistingInstance();
}

/// The hidden window whose WM_TIMER drives the app; never shown, so its class's cursor never shows either.
fn createTimerWindow() !win32.HWND {
    const instance = win32.GetModuleHandleA(null) orelse return error.GetModuleHandleFailed;
    try gdi_overlay.registerWindowClass(instance, timerWindowProc, protocol.MAIN_WINDOW_CLASS, null);
    return win32.CreateWindowExA(0, protocol.MAIN_WINDOW_CLASS, "EVE Timer Window", 0, 0, 0, 0, 0, null, null, instance, null) orelse error.CreateWindowFailed;
}

fn startChatlogMonitoring(monitor: *chatlog.ChatlogMonitor, characters: []const config.CharacterConfig) void {
    app_mod.startChatlogWorker(monitor);
    slog.debug("Chatlog monitoring enabled", .{});
    for (characters) |character_config| {
        monitor.resolveCharacterId(character_config.name) catch |err| {
            slog.warn("Failed to queue ID backfill for '{s}': {}", .{ character_config.name, err });
        };
    }
}

fn startUpdateCheck(allocator: std.mem.Allocator, io: std.Io) void {
    const update_thread = std.Thread.spawn(.{}, update.UpdateChecker.checkForUpdatesBackground, .{ allocator, io }) catch |err| {
        slog.warn("Failed to start update check thread: {}", .{err});
        return;
    };
    update_thread.detach();
}

/// Run-key startup entries launch with an arbitrary working directory, not the exe's folder.
fn setCwdToExecutableDir() void {
    var executable_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_dir = win32.selfExecutableDirPath(&executable_dir_buf) catch |err| {
        slog.warn("Failed to resolve the executable directory: {}", .{err});
        return;
    };

    var dir_z_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const executable_dir_z = std.mem.printSentinel(&dir_z_buf, "{s}", .{executable_dir}, 0) catch |err| {
        slog.warn("Failed to null-terminate the executable directory path: {}", .{err});
        return;
    };

    if (!win32.toBool(win32.SetCurrentDirectoryA(executable_dir_z))) {
        slog.warn("Failed to set the working directory to '{s}': error {d}", .{ executable_dir, win32.GetLastError() });
    }
}

fn timerWindowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    const app = app_mod.g_app orelse return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
    switch (msg) {
        win32.WM_TRAYICON => {
            if (app.tray_icon) |*icon| icon.handleTrayMessage(lParam, app);
            return 0;
        },
        win32.WM_COMMAND => {
            if (app.tray_icon) |*icon| icon.handleMenuCommand(@truncate(wParam), app);
            return 0;
        },
        win32.WM_TIMER => {
            if (wParam == app_mod.TICK_TIMER_ID) {
                app.tick();
            } else if (wParam == focus.HIDE_DEBOUNCE_TIMER_ID) {
                focus.onHideTimer(app);
            }
            return 0;
        },
        win32.WM_HOTKEY => {
            const id: c_int = @intCast(wParam);
            if (!focus_grant.handleWmHotkey(id)) {
                if (app.hotkey_manager) |manager| manager.handleHotkeyPress(id, lParam);
            }
            return 0;
        },
        win32.WM_HOTKEYS_STATE_CHANGED => {
            if (app.thumbnail_set) |thumbnail_set| {
                if (app.hotkey_manager) |manager| {
                    thumbnail_set.notifyAll(.{ .notification_type = .HotkeySuspend, .state = if (manager.areHotkeysSuspended()) .suspended else .resumed });
                }
            }
            return 0;
        },
        win32.WM_SWITCH_PROFILE => {
            app.runPendingProfileSwitch();
            return 0;
        },
        win32.WM_COPYDATA => {
            const copy_data = win32.lparamToPtr(win32.COPYDATASTRUCT, lParam);
            const payload = protocol.copyDataBytes(copy_data);

            switch (copy_data.dwData) {
                win32.PROTOCOL_SWITCH_CHARACTER => if (payload) |character_name| {
                    slog.info("Protocol handler: switch to character: {s}", .{character_name});
                    if (app.scout.getHwndByName(character_name)) |target_hwnd| {
                        activation.activate(app, target_hwnd);
                    } else {
                        slog.warn("Failed to switch to character '{s}': not running", .{character_name});
                    }
                },
                win32.PROTOCOL_SWITCH_PROFILE => if (payload) |profile_name| {
                    slog.info("Protocol handler: switch to profile: {s}", .{profile_name});
                    app.switchProfile(profile_name);
                },
                win32.PROTOCOL_OPEN_CONFIG => knots_host.open(),
                else => {},
            }
            return 0;
        },
        win32.WM_KNOTS_COMMAND => {
            knots_host.onCommand(wParam, lParam);
            return 0;
        },
        win32.WM_PROTOCOL_HOTKEY => {
            const action = std.enums.fromInt(protocol.GlobalAction, wParam) orelse {
                slog.warn("Failed to run protocol hotkey: unknown action {}", .{wParam});
                return 0;
            };
            slog.info("Protocol handler: {s}", .{@tagName(action)});
            if (app.hotkey_manager) |manager| manager.runGlobalAction(action);
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}
