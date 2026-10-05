//! Entry point: startup and shutdown, the hidden timer window whose tick drives everything, and profile reloads.
const std = @import("std");
const build_options = @import("build_options");
const win32 = @import("platform/win32.zig");
const gdi_overlay = @import("platform/gdi_overlay.zig");
const fonts = @import("platform/fonts.zig");
const focus_grant = @import("platform/focus_grant.zig");
const crash = @import("crash.zig");
const config = @import("config.zig");
const scout = @import("clients/scout.zig");
const activation = @import("clients/activation.zig");
const painter = @import("painter.zig");
const hotkeys = @import("hotkeys/manager.zig");
const exclusions = @import("hotkeys/exclusions.zig");
const mouse_hook = @import("hotkeys/mouse_hook.zig");
const keyboard_hook = @import("hotkeys/keyboard_hook.zig");
const paste_upload = @import("hotkeys/paste_upload.zig");
const chatlog = @import("chatlog.zig");
const CharacterIds = @import("chatlog/character_ids.zig").CharacterIds;
const activity = @import("activity/runtime.zig");
const tts = @import("notifications/tts.zig");
const sound = @import("notifications/sound.zig");
const travel_left_behind = @import("travel/left_behind.zig");
const tray = @import("tray.zig");
const protocol = @import("protocol.zig");
const update = @import("update.zig");
const dialog_host = @import("dialog/host.zig");
const dialog_rpc = @import("dialog/rpc.zig");
const dialog_events = @import("dialog/events.zig");
const schedule = @import("util/schedule.zig");
const log = @import("log.zig");

const slog = log.scoped("main");

const TIMER_ID: usize = 1;
/// Timed rather than counted in ticks, so a slower scan interval doesn't stretch it; each scan is a full EnumWindows.
const FORCED_SCAN_INTERVAL_MS: u64 = 1000;
/// With no window tracked and the configuration window closed there's nothing to draw, so the tick only keeps up with the scan.
const IDLE_TICK_INTERVAL_MS: win32.UINT = FORCED_SCAN_INTERVAL_MS;
const TRAVEL_CHECK_INTERVAL_MS: u64 = 2000;
const PROFILE_NAME_BUF = 256;

/// How far a live profile edit moves thumbnails: `region_fit` reflows only an active RegionFit, `thumbnail_spaces` also the not-logged-in space, `all` repositions every thumbnail.
pub const LiveLayout = enum { none, region_fit, thumbnail_spaces, all };

var g_allocator: std.mem.Allocator = undefined;
var g_io: std.Io = undefined;
var g_chatlog_monitor: ?*chatlog.ChatlogMonitor = null;
var g_trackers: activity.Trackers = undefined;

// Public for the configuration window, which edits them in this process.
pub var g_store: config.ProfileStore = undefined;
pub var g_global_settings: config.GlobalConfig = undefined;
pub var g_character_ids: CharacterIds = undefined;

var g_tray_icon: ?tray.TrayIcon = null;
var g_update_checker: ?update.UpdateChecker = null;

/// Public so other modules can post to it without having it passed through every call.
pub var g_timer_hwnd: ?win32.HWND = null;

var g_pending_profile_buf: [PROFILE_NAME_BUF]u8 = undefined;
var g_pending_profile: ?[]const u8 = null;

var g_last_forced_scan: win32.Ticks = .{};
var g_tick_interval_ms: win32.UINT = 0;
var g_last_travel_check_ms: win32.Ticks = .{};

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
        slog.err("Fatal error: {}", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpErrorReturnTrace(trace);
        }
        std.process.exit(1);
    };
}

/// Switches on the next message-loop turn rather than inside the tray menu or hotkey handler asking, which the switch would tear down under it.
/// Keeps its own copy of `profile_name`, so the caller's may be freed straight away.
pub fn requestProfileSwitch(profile_name: []const u8) void {
    if (profile_name.len > g_pending_profile_buf.len) {
        slog.err("Failed to switch to profile '{s}': name too long", .{profile_name});
        return;
    }
    const timer_hwnd = g_timer_hwnd orelse {
        slog.err("Failed to switch profile: the timer window isn't ready", .{});
        return;
    };
    @memcpy(g_pending_profile_buf[0..profile_name.len], profile_name);
    g_pending_profile = g_pending_profile_buf[0..profile_name.len];
    _ = win32.PostMessageA(timer_hwnd, win32.WM_SWITCH_PROFILE, 0, 0);
}

pub fn switchProfile(profile_name: []const u8) void {
    reloadWithProfile(profile_name, null) catch |err| {
        slog.err("Failed to switch to profile '{s}': {}", .{ profile_name, err });
    };
}

/// After the config dialog saved `profile_name` from a draft; `global_draft`, if given, becomes the running global settings too.
pub fn switchToSavedProfile(profile_name: []const u8, global_draft: ?*config.GlobalConfig) !void {
    try reloadWithProfile(profile_name, global_draft);
}

/// After the config dialog saves the running profile or global settings: the parts that only read them at setup (hotkeys, chatlog, timer, window filters) start over.
/// `global_draft`, if given, becomes the running global settings (see GlobalConfig.adopt), leaving it holding the replaced values.
pub fn applySavedSettings(global_draft: ?*config.GlobalConfig) !void {
    const timer_hwnd = g_timer_hwnd orelse return error.MissingTimerWindow;
    try restartSubsystems(timer_hwnd, null, global_draft);
}

/// The config dialog changed the running profile's unsaved `live` copy; `layout` says whether thumbnails may need to move as well as repaint.
pub fn onLiveProfileEdited(layout: LiveLayout) void {
    const painter_ptr = painter.g_painter_ptr orelse return;
    // A view mode builds different windows, so it needs a new painter rather than a restyle.
    if (painter_ptr.view_mode != g_store.live.display.viewMode) {
        var system_names = teardownPainter();
        defer system_names.deinit();
        const windows: []const scout.EveWindow = if (scout.g_scout_ptr) |scout_ptr| scout_ptr.getWindows() else &.{};
        buildPainter(windows, &system_names) catch |err| {
            slog.err("Failed to rebuild thumbnails for view mode {s}: {}", .{ @tagName(g_store.live.display.viewMode), err });
            // It pointed at the painter just destroyed; hotkeys return with the next reload or Save.
            destroyHotkeyManager();
            return;
        };
        slog.info("Rebuilt thumbnails for view mode {s}", .{@tagName(g_store.live.display.viewMode)});
        return;
    }
    painter_ptr.syncPanels();
    painter_ptr.refreshAllThumbnailVisuals();
    switch (layout) {
        .none => {},
        .region_fit => painter_ptr.reflowIfRegionFitActive(),
        .thumbnail_spaces => painter_ptr.reflowIfThumbnailSpaceActive(),
        .all => painter_ptr.repositionAllThumbnails(),
    }
}

/// Resumes hotkeys in case it closed mid-recording.
pub fn onDialogClosed() void {
    if (hotkeys.g_hotkey_manager_ptr) |manager| {
        if (g_timer_hwnd) |timer| manager.dialogResumeHotkeys(timer);
    }
}

fn mainImpl(init: std.process.Init) !void {
    g_io = init.io;
    tts.setIo(g_io);
    sound.setIo(g_io);
    update.setIo(g_io);
    paste_upload.setIo(g_io);
    config.setIo(g_io);
    config.setEnvironMap(init.environ_map);
    g_allocator = init.gpa;
    dialog_host.init(g_allocator, g_io);
    g_trackers = .{ .allocator = g_allocator, .io = g_io };

    setCwdToExeDir();
    config.migrateLegacyLayout();

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
                protocol.sendCommandToInstance(hwnd, .{ .open_config = {} });
                return;
            }
        }
        slog.info("Another instance of EVE-Maj Preview is already running", .{});
        return error.AlreadyRunning;
    }

    slog.info("EVE-Maj Preview v{s}", .{build_options.version});

    fonts.loadBundled();

    g_global_settings = try config.GlobalConfig.load(g_allocator);
    defer g_global_settings.deinit();
    // Before the chatlog monitor, whose shutdown defer then runs first.
    g_character_ids = .load(g_allocator);
    defer g_character_ids.deinit();
    log.setLevel(g_global_settings.logLevel);
    g_global_settings.logSettings();

    var profile_name: []const u8 = if (g_global_settings.lastUsedProfile.len > 0)
        g_global_settings.lastUsedProfile
    else
        config.DEFAULT_PROFILE;

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
                slog.err("Failed to parse arguments: --profile needs a profile name", .{});
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
            slog.err("Failed to parse arguments: unknown argument '{s}'", .{args2[j]});
            return error.InvalidArguments;
        }
    }

    g_store = try config.ProfileStore.init(try config.loadProfile(g_allocator, profile_name));
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

    // Before the painter, whose thumbnails read it as they're created.
    var exclusion_list = exclusions.Exclusions.init(g_allocator);
    exclusion_list.setGlobalInstance();
    defer exclusion_list.deinit();

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
        slog.debug("Chatlog monitoring enabled", .{});

        for (g_store.live.characters.items) |char_config| {
            monitor.resolveCharacterId(char_config.name) catch |err| {
                slog.warn("Failed to queue ID backfill for '{s}': {}", .{ char_config.name, err });
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

    // Thumbnails first, since they need no I/O; the chatlog monitor's slower log discovery follows.
    const eve_windows = scout_ptr.getWindows();
    painter_ptr.populate(eve_windows, .{ .move_to_saved = g_store.live.autoMovePosition.moveOnStartup });

    if (g_chatlog_monitor) |monitor| addChatlogCharacters(monitor, eve_windows);

    try createHotkeyManager(timer_hwnd);
    focus_grant.install(timer_hwnd);
    defer {
        destroyHotkeyManager();
        mouse_hook.deinit();
        keyboard_hook.deinit();
        focus_grant.uninstall();
    }

    if (!setTickInterval(timer_hwnd, tickIntervalFor(eve_windows.len))) {
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

fn timerWindowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_TRAYICON => {
            if (g_tray_icon) |*icon| {
                icon.handleTrayMessage(lParam, &g_store.live);
            }
            return 0;
        },
        win32.WM_COMMAND => {
            if (g_tray_icon) |*icon| icon.handleMenuCommand(@truncate(wParam), &g_store);
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
        win32.WM_SWITCH_PROFILE => {
            const pending = g_pending_profile orelse return 0;
            g_pending_profile = null;
            // Copied out, so a switch requested while this one runs can't overwrite the name in use.
            var name_buf: [PROFILE_NAME_BUF]u8 = undefined;
            const name = name_buf[0..pending.len];
            @memcpy(name, pending);
            slog.info("Switching to profile: {s}", .{name});
            switchProfile(name);
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
                            slog.warn("Failed to switch to character '{s}': not running", .{char_name});
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
            const action = std.enums.fromInt(protocol.GlobalAction, wParam) orelse {
                slog.warn("Failed to run protocol hotkey: unknown action {}", .{wParam});
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
    const tick_start = win32.Ticks.now();
    const force_scan = schedule.nextTickWouldBeLate(@intCast(tick_start.elapsedSince(g_last_forced_scan)), FORCED_SCAN_INTERVAL_MS, g_tick_interval_ms);
    if (force_scan) g_last_forced_scan = tick_start;

    const scout_ptr = scout.g_scout_ptr orelse return;
    var scout_result = scout_ptr.update(force_scan);
    defer scout_result.deinit(g_allocator);

    if (painter.g_painter_ptr) |painter_ptr| {
        painter_ptr.update(scout_result.windows, scout_result.closed_windows.items, scout_result.name_changes.items) catch |err| {
            slog.err("Failed to update Painter: {}", .{err});
        };

        painter_ptr.updateNotifications();
        painter_ptr.checkHoverZoom();
    }

    if (g_chatlog_monitor) |monitor| {
        monitor.update(&scout_result) catch |err| {
            slog.err("Failed to update Chatlog Monitor: {}", .{err});
        };
    }

    // Unwrapped to i64 since activity/tracker.zig's windows still do plain i64 arithmetic.
    g_trackers.tick(&g_store.live, scout_result.windows, @intCast(tick_start.ms), g_tick_interval_ms);

    if (painter.g_painter_ptr) |painter_ptr| {
        if (schedule.isDue(@intCast(tick_start.elapsedSince(g_last_travel_check_ms)), TRAVEL_CHECK_INTERVAL_MS, g_tick_interval_ms)) {
            g_last_travel_check_ms = tick_start;
            travel_left_behind.check(painter_ptr, tick_start);
        }
    }

    dialog_host.tick();

    const wanted_interval = tickIntervalFor(scout_result.windows.len);
    if (wanted_interval != g_tick_interval_ms) {
        if (g_timer_hwnd) |timer_hwnd| {
            if (setTickInterval(timer_hwnd, wanted_interval)) slog.debug("Tick interval now {} ms", .{wanted_interval});
        }
    }
}

/// The configured scan interval, or IDLE_TICK_INTERVAL_MS while there's nothing to draw.
fn tickIntervalFor(window_count: usize) win32.UINT {
    if (window_count == 0 and !dialog_host.isOpen()) return IDLE_TICK_INTERVAL_MS;
    return g_store.saved.timer.scanIntervalMs;
}

/// SetTimer replaces the running tick timer in place; false if it couldn't be set.
fn setTickInterval(timer_hwnd: win32.HWND, interval_ms: win32.UINT) bool {
    if (win32.SetTimer(timer_hwnd, TIMER_ID, interval_ms, null) == 0) return false;
    g_tick_interval_ms = interval_ms;
    return true;
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

/// Keeps each client's last-known system name for buildPainter to seed the new painter with; the caller frees it.
fn teardownPainter() painter.SystemNameSnapshot {
    var system_names = painter.SystemNameSnapshot.init(g_allocator);
    if (painter.g_painter_ptr) |old_painter| system_names.capture(old_painter);
    destroyPainter();
    return system_names;
}

/// Also repoints the hotkey manager, the one other holder of the painter's pointer.
fn buildPainter(windows: []const scout.EveWindow, system_names: *const painter.SystemNameSnapshot) !void {
    const new_painter = try createPainter();
    if (hotkeys.g_hotkey_manager_ptr) |manager| manager.painter = new_painter;
    new_painter.populate(windows, .{
        // Clients are already where the user put them; only startup and new arrivals auto-move.
        .move_to_saved = false,
        // Only seeded if monitoring stays on to refresh it, or a stale name would freeze on screen forever.
        .system_names = if (g_store.saved.chatlog.enabled) system_names else null,
    });
}

/// Publishes the manager through hotkeys.g_hotkey_manager_ptr, which is also how main.zig reaches it, then registers its hotkeys; a registration failure is logged, not fatal.
fn createHotkeyManager(timer_hwnd: win32.HWND) !void {
    const scout_ptr = scout.g_scout_ptr orelse {
        slog.err("Failed to create the hotkey manager: Scout isn't ready", .{});
        return error.MissingScout;
    };
    const painter_ptr = painter.g_painter_ptr orelse {
        slog.err("Failed to create the hotkey manager: Painter isn't ready", .{});
        return error.MissingPainter;
    };
    const exclusion_list = exclusions.g_exclusions_ptr orelse {
        slog.err("Failed to create the hotkey manager: the exclusion list isn't ready", .{});
        return error.MissingExclusions;
    };
    const manager = try g_allocator.create(hotkeys.HotkeyManager);
    errdefer g_allocator.destroy(manager);
    manager.* = try hotkeys.HotkeyManager.init(g_allocator, &g_store, &g_global_settings, scout_ptr, painter_ptr, exclusion_list);
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

fn startChatlogWorker(monitor: *chatlog.ChatlogMonitor) void {
    monitor.startWorkerThread() catch |err| {
        slog.warn("Failed to start chatlog worker thread: {}", .{err});
    };
}

fn addChatlogCharacters(monitor: *chatlog.ChatlogMonitor, windows: []const scout.EveWindow) void {
    for (windows) |eve_window| {
        if (!eve_window.is_eve_client) continue;
        monitor.addCharacter(eve_window.character_name) catch |err| {
            slog.err("Failed to add '{s}' to the chatlog monitor: {}", .{ eve_window.character_name, err });
        };
    }
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

fn reloadWithProfile(new_profile_name: []const u8, global_draft: ?*config.GlobalConfig) !void {
    slog.info("=== Starting profile reload: {s} ===", .{new_profile_name});

    const timer_hwnd = g_timer_hwnd orelse return error.MissingTimerWindow;

    const loaded = config.loadProfile(g_allocator, new_profile_name) catch |err| blk: {
        slog.err("Failed to load profile '{s}', reverting to the default: {}", .{ new_profile_name, err });
        break :blk config.loadProfile(g_allocator, config.DEFAULT_PROFILE) catch {
            // Original profile-load error, not the fallback's.
            return err;
        };
    };
    // Built before anything is torn down, so a failure here leaves the running profile intact.
    const new_store = config.ProfileStore.init(loaded) catch |err| {
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

/// Tears down and rebuilds everything set up from the profile; `replacement`, owned from here on, becomes the running store.
fn restartSubsystems(timer_hwnd: win32.HWND, replacement: ?config.ProfileStore, global_draft: ?*config.GlobalConfig) !void {
    var pending = replacement;
    errdefer if (pending) |*store| store.deinit();
    const next: *const config.Config = if (pending) |*store| &store.saved else &g_store.saved;

    const keep_chatlog_monitor = if (g_chatlog_monitor) |monitor| monitor.runsWith(&next.chatlog) else false;
    // A Save keeps the painter: the dialog already previewed what was saved, so rebuilding would only flash every window.
    const rebuild_painter = pending != null or painter.g_painter_ptr == null;

    if (keep_chatlog_monitor) {
        // Pause (not destroy) so the worker thread can't race the tracker swap below.
        g_chatlog_monitor.?.stopWorkerThread();
        slog.debug("Paused chatlog monitor for reload (scan state preserved)", .{});
    } else if (g_chatlog_monitor != null) {
        destroyChatlogMonitor();
        slog.debug("Cleaned up chatlog monitor", .{});
    }

    // After the chatlog worker is stopped above, since it reads the ore prices.
    if (global_draft) |draft| g_global_settings.adopt(draft);

    destroyHotkeyManager();
    slog.debug("Cleaned up hotkey manager", .{});

    var system_names = if (rebuild_painter) teardownPainter() else painter.SystemNameSnapshot.init(g_allocator);
    defer system_names.deinit();

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

    // Windows the new filters drop are reported closed, and leave the painter and chatlog on the next tick.
    const eve_windows = rescanWindows();
    if (rebuild_painter) {
        buildPainter(eve_windows, &system_names) catch |err| {
            slog.err("Failed to create painter: {}", .{err});
            return err;
        };
        slog.debug("Recreated {} thumbnail(s)", .{eve_windows.len});
    } else {
        const painter_ptr = painter.g_painter_ptr.?;
        // Windows the new filters admit.
        painter_ptr.populate(eve_windows, .{ .move_to_saved = false });
    }

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
        startChatlogWorker(monitor);
        if (keep_chatlog_monitor) {
            slog.info("Resumed chatlog monitoring without rescanning logs", .{});
        } else {
            addChatlogCharacters(monitor, eve_windows);
            slog.info("Reinitialized chatlog monitoring", .{});
        }
    }

    createHotkeyManager(timer_hwnd) catch |err| {
        slog.err("Failed to create hotkey manager: {}", .{err});
        return err;
    };
    slog.debug("Reinitialized hotkey manager", .{});

    const new_interval = tickIntervalFor(eve_windows.len);
    _ = setTickInterval(timer_hwnd, new_interval);
    slog.debug("Updated timer interval to {} ms", .{new_interval});
}
