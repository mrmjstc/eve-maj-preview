const std = @import("std");
const win32 = @import("platform/win32.zig");
const gdi_overlay = @import("platform/gdi_overlay.zig");
const scout = @import("clients/scout.zig");
const painter = @import("painter.zig");
const focus_grant = @import("platform/focus_grant.zig");
const activation = @import("clients/activation.zig");
const config_mod = @import("config.zig");
const notification_mod = @import("notifications/notification.zig");
const hotkeys = @import("hotkeys/manager.zig");
const mouse_hook = @import("hotkeys/mouse_hook.zig");
const keyboard_hook = @import("hotkeys/keyboard_hook.zig");
const chatlog = @import("chatlog.zig");
const CharacterIds = @import("chatlog/character_ids.zig").CharacterIds;
const activity = @import("activity/runtime.zig");
const tts = @import("notifications/tts.zig");
const sound = @import("notifications/sound.zig");
const travel_left_behind = @import("travel/left_behind.zig");
const tray = @import("tray.zig");
const protocol = @import("protocol.zig");
const update = @import("update.zig");
const paste_upload = @import("hotkeys/paste_upload.zig");
const fonts = @import("platform/fonts.zig");
const crash = @import("crash.zig");
const log = @import("log.zig");
const slog = log.scoped("main");
const build_options = @import("build_options");
const dialog_host = @import("dialog/host.zig");
const dialog_rpc = @import("dialog/rpc.zig");
const dialog_events = @import("dialog/events.zig");

const TIMER_ID: usize = 1;

var g_allocator: std.mem.Allocator = undefined;
var g_io: std.Io = undefined;
var g_chatlog_monitor: ?*chatlog.ChatlogMonitor = null;
var g_trackers: activity.Trackers = undefined;
// Public for the configuration window, which edits them in this process.
pub var g_store: config_mod.ProfileStore = undefined;
pub var g_global_settings: config_mod.GlobalConfig = undefined;
pub var g_character_ids: CharacterIds = undefined;
var g_tray_icon: ?tray.TrayIcon = null;
var g_update_checker: ?update.UpdateChecker = null;
// Exported for other modules to reach these without threading them through every call.
pub var g_timer_hwnd: ?win32.HWND = null;

// Scan throttling: only run expensive EnumWindows every N ticks
var g_scan_tick_counter: u32 = 0;
// 20 ticks at 50ms/tick is roughly 1 second between scans.
const SCAN_INTERVAL_TICKS: u32 = 20;

var g_last_travel_check_ms: win32.Ticks = .{};
const TRAVEL_CHECK_INTERVAL_MS: u64 = 2000;

fn timerWindowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_TRAYICON => {
            if (g_tray_icon) |*icon| {
                icon.handleTrayMessage(lParam, &g_store.live);
            }
            return 0;
        },
        win32.WM_COMMAND => {
            const command_id = @as(u16, @truncate(wParam));
            _ = tray.TrayIcon.handleMenuCommand(command_id, &g_store);
            return 0;
        },
        win32.WM_TIMER => {
            if (wParam == TIMER_ID) {
                onTimerTick();
            } else if (wParam == painter.HIDE_DEBOUNCE_TIMER_ID) {
                if (painter.g_painter_ptr) |painter_ptr| painter_ptr.autoHideAfterFocusLoss();
            }
            return 0;
        },
        win32.WM_HOTKEY => {
            const id: c_int = @intCast(wParam);
            if (!focus_grant.handleWmHotkey(id)) {
                if (hotkeys.g_hotkey_manager_ptr) |manager| {
                    manager.handleHotkeyPress(id, lParam);
                }
            }
            return 0;
        },
        win32.WM_HOTKEYS_STATE_CHANGED => {
            if (painter.g_painter_ptr) |painter_ptr| {
                if (hotkeys.g_hotkey_manager_ptr) |manager| {
                    painter_ptr.notifyAll(.{ .ntype = .HotkeySuspend, .state = if (manager.areHotkeysSuspended()) .suspended else .resumed });
                }
            }
            return 0;
        },
        win32.WM_TOGGLE_VISIBILITY => {
            if (painter.g_painter_ptr) |painter_ptr| {
                painter_ptr.toggleAllThumbnailsVisibility();
            }
            return 0;
        },
        win32.WM_SWITCH_PROFILE => {
            if (tray.TrayIcon.takePendingProfileName()) |new_profile| {
                slog.info("Switching to profile: {s}", .{new_profile});
                switchProfile(new_profile);
            }
            return 0;
        },
        win32.WM_COPYDATA => {
            const cds = win32.lparamToPtr(win32.COPYDATASTRUCT, lParam);
            const payload = protocol.copyDataBytes(cds);

            switch (cds.dwData) {
                win32.PROTOCOL_SWITCH_CHARACTER => if (payload) |char_name| {
                    slog.info("Protocol handler: switch to character: {s}", .{char_name});
                    if (scout.g_scout_ptr) |scout_ptr| {
                        if (scout_ptr.getHwndByName(char_name)) |target_hwnd| {
                            activation.activate(target_hwnd);
                        } else {
                            slog.warn("Character '{s}' not found", .{char_name});
                        }
                    }
                },
                win32.PROTOCOL_SWITCH_PROFILE => if (payload) |profile_name| {
                    slog.info("Protocol handler: switch to profile: {s}", .{profile_name});
                    switchProfile(profile_name);
                },
                win32.PROTOCOL_OPEN_CONFIG => dialog_host.open(),
                else => {},
            }
            return 0;
        },
        win32.WM_DIALOG_RPC => {
            dialog_rpc.runOnMainThread(lParam);
            return 0;
        },
        win32.WM_DIALOG_MOVED => {
            dialog_host.onMoved(lParam);
            return 0;
        },
        win32.WM_PROTOCOL_HOTKEY => {
            // wParam identifies which hotkey action the protocol handler requested
            const action = std.enums.fromInt(protocol.GlobalAction, wParam) orelse {
                slog.warn("Unknown protocol hotkey action: {}", .{wParam});
                return 0;
            };
            slog.info("Protocol handler: {s}", .{@tagName(action)});
            if (hotkeys.g_hotkey_manager_ptr) |manager| manager.runGlobalAction(action);
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}

/// Runs one WM_TIMER tick: scan for EVE windows, then push the results through
/// the painter, chatlog monitor, and activity trackers.
fn onTimerTick() void {
    g_scan_tick_counter += 1;
    const force_scan = (g_scan_tick_counter >= SCAN_INTERVAL_TICKS);
    if (force_scan) {
        g_scan_tick_counter = 0;
    }

    const scout_ptr = scout.g_scout_ptr orelse return;
    var scout_result = scout_ptr.update(force_scan) catch |err| {
        slog.err("Failed to update Scout: {}", .{err});
        return;
    };
    defer scout_result.deinit(g_allocator);

    if (painter.g_painter_ptr) |painter_ptr| {
        painter_ptr.update(scout_result.windows, scout_result.closed_windows.items, scout_result.name_changes.items) catch |err| {
            slog.err("Failed to update Painter: {}", .{err});
        };

        painter_ptr.updateNotifications();
    }

    if (g_chatlog_monitor) |monitor| {
        monitor.update(&scout_result) catch |err| {
            slog.err("Failed to update Chatlog Monitor: {}", .{err});
        };
    }

    const now = win32.Ticks.now();
    // Unwrapped to i64 since activity/tracker.zig's windows still do plain i64 arithmetic.
    g_trackers.tick(&g_store.live, scout_result.windows, @intCast(now.ms));

    if (painter.g_painter_ptr) |painter_ptr| {
        if (now.elapsedSince(g_last_travel_check_ms) >= TRAVEL_CHECK_INTERVAL_MS) {
            g_last_travel_check_ms = now;
            travel_left_behind.check(painter_ptr, now);
        }
    }

    dialog_host.tick();
}

/// Routes panics into eve-maj.log; Zig only looks for `panic` in the root source file.
pub const panic = std.debug.FullPanic(crash.handlePanic);

pub fn main(init: std.process.Init) void {
    // Must precede any window/monitor API call, or Windows bitmap-stretches our windows on scaled monitors.
    _ = win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    crash.install();
    defer log.deinitFile();

    mainImpl(init) catch |err| {
        slog.err("Fatal error: {}", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(trace);
        }
        std.process.exit(1);
    };
}

fn hasArgument(process_args: std.process.Args, flag: []const u8) !bool {
    // toSlice's result references several internal allocations, so it requires an arena rather than a plain allocator.
    var arena = std.heap.ArenaAllocator.init(g_allocator);
    defer arena.deinit();
    for (try process_args.toSlice(arena.allocator())) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

/// Run-key startup entries launch with an arbitrary working directory, not the exe's folder.
fn setCwdToExeDir() void {
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = win32.selfExeDirPath(&exe_dir_buf) catch |err| {
        slog.warn("Failed to resolve exe directory: {}", .{err});
        return;
    };

    var dir_z_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const exe_dir_z = std.fmt.bufPrintZ(&dir_z_buf, "{s}", .{exe_dir}) catch |err| {
        slog.warn("Failed to null-terminate exe directory path: {}", .{err});
        return;
    };

    _ = win32.SetCurrentDirectoryA(exe_dir_z);
}

fn mainImpl(init: std.process.Init) !void {
    g_io = init.io;
    log.setIo(g_io);
    tts.setIo(g_io);
    sound.setIo(g_io);
    update.setIo(g_io);
    paste_upload.setIo(g_io);
    config_mod.setIo(g_io);
    config_mod.setEnvironMap(init.environ_map);
    g_allocator = init.gpa;
    dialog_host.init(g_allocator);
    g_trackers = .{ .allocator = g_allocator, .io = g_io };

    setCwdToExeDir();

    // Handle protocol invocation before the mutex check, so commands work even when another instance is already running.
    const protocol_url = try protocol.checkCommandLine(init.minimal.args, g_allocator);
    defer if (protocol_url) |url| g_allocator.free(url);

    if (protocol_url) |url| {
        slog.info("Protocol handler invoked: {s}", .{url});
        return protocol.forwardToRunningInstance(url, g_allocator);
    }

    // Read before the mutex, since GetLastError must be checked right after creating it.
    const open_config = try hasArgument(init.minimal.args, "--config");

    const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Global\\EVE-Maj-Preview-SingleInstance");
    const instance_mutex = win32.CreateMutexW(null, win32.TRUE, mutex_name);

    if (instance_mutex == null) {
        slog.err("Failed to create instance mutex", .{});
        return error.MutexCreationFailed;
    }
    defer _ = win32.CloseHandle(instance_mutex.?);

    const last_error = win32.GetLastError();
    if (last_error == win32.ERROR_ALREADY_EXISTS) {
        if (open_config) {
            if (protocol.findExistingInstance()) |hwnd| {
                protocol.sendCommandToInstance(hwnd, .{ .OpenConfig = {} });
                return;
            }
        }
        slog.info("Another instance of EVE-Maj Preview is already running", .{});
        return error.AlreadyRunning;
    }

    slog.info("EVE-Maj Preview v{s}", .{build_options.version});

    fonts.loadBundled();

    g_global_settings = try config_mod.GlobalConfig.load(g_allocator);
    defer g_global_settings.deinit();
    // Before the chatlog monitor, whose shutdown defer then runs first.
    g_character_ids = .load(g_allocator);
    defer g_character_ids.deinit();
    log.setLevel(g_global_settings.logLevel);
    g_global_settings.logSettings();

    var profile_name: []const u8 = if (g_global_settings.lastUsedProfile.len > 0)
        g_global_settings.lastUsedProfile
    else
        config_mod.DEFAULT_PROFILE;

    // toSlice's result references several internal allocations, so it requires an arena rather than a plain allocator.
    var args_arena = std.heap.ArenaAllocator.init(g_allocator);
    defer args_arena.deinit();
    const args2 = try init.minimal.args.toSlice(args_arena.allocator());

    var j: usize = 1;
    while (j < args2.len) : (j += 1) {
        if (std.mem.eql(u8, args2[j], "--profile") or std.mem.eql(u8, args2[j], "-p")) {
            if (j + 1 < args2.len) {
                profile_name = args2[j + 1];
                j += 1;
            } else {
                slog.err("--profile requires a profile name", .{});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, args2[j], "--config")) {
            // Handled before the instance check above.
        } else if (std.mem.eql(u8, args2[j], "--protocol")) {
            // Skip protocol arg (already handled above)
            if (j + 1 < args2.len) {
                j += 1;
            }
        } else {
            slog.err("Unknown argument: {s}", .{args2[j]});
            return error.InvalidArguments;
        }
    }

    g_store = try config_mod.ProfileStore.init(try config_mod.loadProfile(g_allocator, profile_name));
    defer g_store.deinit();

    // Not profile_name: loadProfile() may have fallen back to default, and this heals global settings to match.
    try g_global_settings.updateLastUsed(g_store.live.profile_name);

    g_store.live.logSettings();

    if (g_global_settings.autoRegisterProtocol) protocol.ensureRegistered(g_allocator);

    defer tts.shutdown();
    defer sound.shutdown();

    if (g_global_settings.logLevel == .debug) log.openDebugConsole();

    const scout_ptr = try g_allocator.create(scout.Scout);
    scout_ptr.* = scout.Scout.init(g_allocator, &g_store.saved);
    scout_ptr.setGlobalInstance();
    defer {
        scout_ptr.deinit();
        g_allocator.destroy(scout_ptr);
    }

    const painter_ptr = try createPainter();
    defer destroyPainter();

    if (g_store.live.chatlog.enabled) {
        g_chatlog_monitor = try createChatlogMonitor();
    } else {
        slog.info("Chatlog monitoring disabled", .{});
    }

    g_trackers.setup(&g_store.saved, g_chatlog_monitor);
    defer g_trackers.deinit();

    // Registered after the trackers' defer so it runs first (LIFO): the worker thread must stop before the trackers are freed, since it may be mid-iteration reading them.
    defer destroyChatlogMonitor();

    if (g_chatlog_monitor) |monitor| {
        // Started only now that the trackers are wired in, so it never observes them as null when they should be set.
        startChatlogWorker(monitor);
        slog.debug("Chatlog monitoring enabled (threading: {})", .{g_store.live.chatlog.useThreading});

        for (g_store.live.characters.items) |char_config| {
            monitor.resolveCharacterId(char_config.name) catch |err| {
                slog.warn("Failed to queue ID backfill for {s}: {}", .{ char_config.name, err });
            };
        }
    }

    const instance = win32.GetModuleHandleA(null) orelse return error.GetModuleHandleFailed;

    // Never shown (0x0, no ShowWindow), so the class's cursor is never actually displayed.
    try gdi_overlay.registerWindowClass(instance, timerWindowProc, protocol.MAIN_WINDOW_CLASS, null);

    const timer_hwnd = win32.CreateWindowExA(
        0,
        protocol.MAIN_WINDOW_CLASS,
        "EVE Timer Window",
        0,
        0,
        0,
        0,
        0,
        null,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    defer _ = win32.DestroyWindow(timer_hwnd);

    g_timer_hwnd = timer_hwnd;
    defer dialog_host.shutdown();

    g_tray_icon = try tray.TrayIcon.init(g_allocator, timer_hwnd);
    defer if (g_tray_icon) |*icon| icon.deinit();

    g_update_checker = update.UpdateChecker.init(g_allocator);
    defer if (g_update_checker) |*checker| checker.deinit();

    if (!g_global_settings.disableUpdateChecks) {
        if (std.Thread.spawn(.{}, update.UpdateChecker.checkForUpdatesBackground, .{g_allocator})) |update_thread| {
            update_thread.detach();
        } else |err| {
            slog.warn("Failed to start update check thread: {}", .{err});
        }
    } else {
        slog.info("Update checks are disabled", .{});
    }

    try scout_ptr.scanForEveWindows();

    // Create thumbnail windows for each EVE client (fast - no I/O blocking)
    const eve_windows = scout_ptr.getWindows();
    painter_ptr.populate(eve_windows, .{ .move_to_saved = g_store.live.autoMovePosition.moveOnStartup });

    // Register with chatlog monitor after thumbnails are visible (deferred I/O)
    if (g_chatlog_monitor) |monitor| addChatlogCharacters(monitor, eve_windows);

    try createHotkeyManager(timer_hwnd);
    focus_grant.install(timer_hwnd);
    defer {
        destroyHotkeyManager();
        mouse_hook.deinit();
        keyboard_hook.deinit();
        focus_grant.uninstall();
    }

    const TIMER_INTERVAL: win32.UINT = g_store.live.timer.scanIntervalMs;
    const timer_id = win32.SetTimer(timer_hwnd, TIMER_ID, TIMER_INTERVAL, null);
    if (timer_id == 0) {
        slog.err("Failed to create timer", .{});
        return error.SetTimerFailed;
    }
    defer _ = win32.KillTimer(timer_hwnd, TIMER_ID);

    if (open_config) dialog_host.open();

    var msg: win32.MSG = undefined;
    while (win32.GetMessageA(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageA(&msg);
    }
}

/// Publishes the painter through painter.g_painter_ptr, which is also how main.zig reaches it.
fn createPainter() !*painter.Painter {
    const new_painter = try g_allocator.create(painter.Painter);
    errdefer g_allocator.destroy(new_painter);
    new_painter.* = try painter.Painter.init(g_allocator, &g_store);
    painter.g_painter_ptr = new_painter;
    return new_painter;
}

fn destroyPainter() void {
    const old_painter = painter.g_painter_ptr orelse return;
    painter.g_painter_ptr = null;
    old_painter.deinit();
    g_allocator.destroy(old_painter);
}

/// Publishes the manager through hotkeys.g_hotkey_manager_ptr, which is also how main.zig reaches it, then registers its hotkeys; a registration failure is logged, not fatal.
fn createHotkeyManager(timer_hwnd: win32.HWND) !void {
    const manager = try g_allocator.create(hotkeys.HotkeyManager);
    errdefer g_allocator.destroy(manager);
    manager.* = try hotkeys.HotkeyManager.init(g_allocator, &g_store.saved, &g_global_settings, scout.g_scout_ptr.?, painter.g_painter_ptr.?);
    hotkeys.g_hotkey_manager_ptr = manager;

    manager.registerHotkeys(timer_hwnd) catch |err| {
        slog.warn("Failed to register hotkeys: {} - continuing without hotkey support", .{err});
    };
}

fn destroyHotkeyManager() void {
    const manager = hotkeys.g_hotkey_manager_ptr orelse return;
    hotkeys.g_hotkey_manager_ptr = null;
    manager.deinit();
    g_allocator.destroy(manager);
}

/// Created with its worker thread stopped, so the trackers can be wired in before it runs.
fn createChatlogMonitor() !*chatlog.ChatlogMonitor {
    return chatlog.ChatlogMonitor.init(g_allocator, g_io, &g_store.saved.chatlog, &g_global_settings, &g_character_ids);
}

fn destroyChatlogMonitor() void {
    const monitor = g_chatlog_monitor orelse return;
    g_chatlog_monitor = null;
    monitor.deinit();
    g_allocator.destroy(monitor);
}

/// Without threading, the monitor does its log I/O inline on the main thread's tick instead.
fn startChatlogWorker(monitor: *chatlog.ChatlogMonitor) void {
    if (!g_store.saved.chatlog.useThreading) return;
    monitor.startWorkerThread() catch |err| {
        slog.warn("Failed to start chatlog worker thread: {}", .{err});
    };
}

fn addChatlogCharacters(monitor: *chatlog.ChatlogMonitor, windows: []const scout.EveWindow) void {
    for (windows) |eve_window| {
        monitor.addCharacter(eve_window.character_name) catch |err| {
            slog.err("Failed to add {s} to chatlog monitor: {}", .{ eve_window.character_name, err });
        };
    }
}

pub fn switchProfile(profile_name: []const u8) void {
    reloadWithProfile(profile_name, null) catch |err| {
        slog.err("Failed to switch profile to {s}: {}", .{ profile_name, err });
    };
}

/// After the config dialog saved `profile_name` from a draft; `global_draft`, if given, becomes the running global settings too.
pub fn switchToSavedProfile(profile_name: []const u8, global_draft: ?*config_mod.GlobalConfig) !void {
    try reloadWithProfile(profile_name, global_draft);
}

/// Picks up windows the new profile's filters match and drops those they no longer do; a failed scan keeps the already-tracked windows.
fn rescanWindows() []const scout.EveWindow {
    const scout_ptr = scout.g_scout_ptr orelse return &.{};
    scout_ptr.scanForEveWindows() catch |err| {
        slog.err("Failed to scan for EVE windows: {}", .{err});
    };
    scout_ptr.pruneNonMatchingWindows();
    return scout_ptr.getWindows();
}

fn reloadWithProfile(new_profile_name: []const u8, global_draft: ?*config_mod.GlobalConfig) !void {
    slog.info("=== Starting profile reload: {s} ===", .{new_profile_name});

    const timer_hwnd = g_timer_hwnd orelse return error.NoTimerWindow;

    const loaded = config_mod.loadProfile(g_allocator, new_profile_name) catch |err| blk: {
        slog.err("Failed to load new profile, reverting to default", .{});
        break :blk config_mod.loadProfile(g_allocator, config_mod.DEFAULT_PROFILE) catch {
            // Original profile-load error, not the fallback's.
            return err;
        };
    };
    // Built before anything is torn down, so a failure here leaves the running profile intact.
    const new_store = config_mod.ProfileStore.init(loaded) catch |err| {
        slog.err("Failed to set up profile '{s}': {}", .{ new_profile_name, err });
        return err;
    };

    const profile_changed = !std.mem.eql(u8, g_store.live.profile_name, new_store.live.profile_name);
    try restartSubsystems(timer_hwnd, new_store, global_draft);

    if (profile_changed) {
        const name = g_store.live.profile_name;
        const display_name = if (std.mem.endsWith(u8, name, ".json")) name[0 .. name.len - ".json".len] else name;
        if (painter.g_painter_ptr) |painter_ptr| painter_ptr.notifyAll(.{ .ntype = .ProfileSwitch, .target = display_name });
    }

    dialog_events.profileSwitched(g_store.live.profile_name);
    slog.info("=== Profile reload complete: {s} ===", .{new_profile_name});
}

/// After the config dialog saves the running profile or global settings: the parts that only read them at setup (hotkeys, chatlog, timer, window filters) start over.
/// `global_draft`, if given, becomes the running global settings (see GlobalConfig.adopt), leaving it holding the replaced values.
pub fn applySavedSettings(global_draft: ?*config_mod.GlobalConfig) !void {
    const timer_hwnd = g_timer_hwnd orelse return error.NoTimerWindow;
    try restartSubsystems(timer_hwnd, null, global_draft);
}

/// Tears down and rebuilds everything set up from the profile; `replacement`, owned from here on, becomes the running store.
fn restartSubsystems(timer_hwnd: win32.HWND, replacement: ?config_mod.ProfileStore, global_draft: ?*config_mod.GlobalConfig) !void {
    var pending = replacement;
    errdefer if (pending) |*store| store.deinit();
    const next: *const config_mod.Config = if (pending) |*store| &store.saved else &g_store.saved;

    const keep_chatlog_monitor = if (g_chatlog_monitor) |monitor| monitor.runsWith(&next.chatlog) else false;

    if (keep_chatlog_monitor) {
        // Pause (not destroy) so the worker thread can't race the tracker swap below.
        g_chatlog_monitor.?.stopWorkerThread();
        slog.debug("Paused chatlog monitor for reload (scan state preserved)", .{});
    } else if (g_chatlog_monitor != null) {
        destroyChatlogMonitor();
        slog.debug("Cleaned up chatlog monitor", .{});
    }

    // Both must run after the chatlog worker is stopped above, since it reads the trackers and the ore prices.
    g_trackers.releaseForReload();
    if (global_draft) |draft| g_global_settings.adopt(draft);

    destroyHotkeyManager();
    slog.debug("Cleaned up hotkey manager", .{});

    var last_known_systems = painter.SystemNameSnapshot.init(g_allocator);
    defer last_known_systems.deinit();
    if (painter.g_painter_ptr) |painter_ptr| last_known_systems.capture(painter_ptr);

    destroyPainter();
    slog.debug("Cleaned up painter", .{});

    if (pending) |store| {
        g_store.deinit();
        g_store = store;
        pending = null;
        slog.info("Loaded new config: {s}", .{g_store.saved.profile_name});
        g_store.saved.logSettings();
    }

    g_global_settings.updateLastUsed(g_store.saved.profile_name) catch |err| {
        slog.warn("Failed to update global settings: {}", .{err});
    };

    const new_painter = createPainter() catch |err| {
        slog.err("Failed to create painter: {}", .{err});
        return err;
    };
    slog.debug("Reinitialized painter", .{});

    const eve_windows = rescanWindows();
    new_painter.populate(eve_windows, .{
        // Clients are already where the user put them; only startup and new arrivals auto-move.
        .move_to_saved = false,
        // Only seeded if monitoring stays on to refresh it, or a stale name would freeze on screen forever.
        .system_names = if (g_store.saved.chatlog.enabled) &last_known_systems else null,
    });
    slog.debug("Recreated {} thumbnail(s)", .{eve_windows.len});

    if (keep_chatlog_monitor) {
        g_chatlog_monitor.?.applySettings(&g_store.saved.chatlog);
        slog.debug("Applied reload settings to paused chatlog monitor", .{});
    } else if (g_store.saved.chatlog.enabled) {
        g_chatlog_monitor = createChatlogMonitor() catch |err| blk: {
            slog.warn("Failed to initialize chatlog monitor: {}", .{err});
            break :blk null;
        };
    } else {
        slog.info("Chatlog monitoring disabled in new profile", .{});
    }

    // Wired while the worker is stopped (paused above, or not started yet), so it never reads a tracker mid-swap.
    g_trackers.setup(&g_store.saved, g_chatlog_monitor);

    if (g_chatlog_monitor) |monitor| {
        // Started before adding characters, so addCharacter() queues work instead of blocking the message loop with log I/O.
        startChatlogWorker(monitor);
        if (keep_chatlog_monitor) {
            slog.info("Resumed chatlog monitoring without rescanning logs (threading: {})", .{g_store.saved.chatlog.useThreading});
        } else {
            addChatlogCharacters(monitor, eve_windows);
            slog.info("Reinitialized chatlog monitoring (threading: {})", .{g_store.saved.chatlog.useThreading});
        }
    }

    createHotkeyManager(timer_hwnd) catch |err| {
        slog.err("Failed to create hotkey manager: {}", .{err});
        return err;
    };
    slog.debug("Reinitialized hotkey manager", .{});

    const new_interval = g_store.saved.timer.scanIntervalMs;
    _ = win32.SetTimer(timer_hwnd, TIMER_ID, new_interval, null);
    slog.debug("Updated timer interval to {} ms", .{new_interval});
}

/// The config dialog changed the running profile's unsaved `live` copy; `layout` when thumbnails may need to move as well as repaint.
pub fn onLiveProfileEdited(layout: bool) void {
    const painter_ptr = painter.g_painter_ptr orelse return;
    painter_ptr.refreshAllThumbnailVisuals();
    if (layout) painter_ptr.repositionAllThumbnails();
}

/// Resumes hotkeys in case it closed mid-recording.
pub fn onDialogClosed() void {
    if (hotkeys.g_hotkey_manager_ptr) |manager| {
        if (g_timer_hwnd) |timer| manager.dialogResumeHotkeys(timer);
    }
}
