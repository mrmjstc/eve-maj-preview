const std = @import("std");
const win32 = @import("win32.zig");
const scout = @import("scout.zig");
const painter = @import("painter.zig");
const input = @import("input.zig");
const config_mod = @import("config.zig");
const hotkeys = @import("hotkeys.zig");
const mouse_hook = @import("mouse_hook.zig");
const chatlog = @import("chatlog.zig");
const activity_mod = @import("activity_tracker.zig");
const tts = @import("tts.zig");
const tray = @import("tray.zig");
const protocol = @import("protocol.zig");
const update = @import("update.zig");
const log = @import("log.zig");
const slog = log.scoped("main");
const build_options = @import("build_options");

const LPARAM = win32.LPARAM;
const WPARAM = win32.WPARAM;
const HWND = win32.HWND;
const UINT = win32.UINT;
const LRESULT = win32.LRESULT;

const TIMER_ID: usize = 1;
const TIMER_CLASS_NAME = "EVE_TIMER_CLASS";

var g_allocator: std.mem.Allocator = undefined;
var g_scout: ?*scout.Scout = null;
var g_painter: ?*painter.Painter = null;
var g_hotkey_manager: ?*hotkeys.HotkeyManager = null;
var g_chatlog_monitor: ?*chatlog.ChatlogMonitor = null;
var g_combat_tracker: ?*activity_mod.CombatTracker = null;
var g_mining_tracker: ?*activity_mod.MiningTracker = null;
var g_bounty_tracker: ?*activity_mod.BountyTracker = null;
pub var g_config: config_mod.Config = undefined;
var g_global_settings: config_mod.GlobalSettings = undefined;
var g_tray_icon: ?tray.TrayIcon = null;
var g_update_checker: ?update.UpdateChecker = null;
// Exported for other modules (mainly input.zig) to reach these without threading them through every call.
pub var g_timer_hwnd: ?win32.HWND = null;
pub var g_config_ptr: ?*config_mod.Config = null;
pub var g_scout_ptr: ?*scout.Scout = null;

// Scan throttling: only run expensive EnumWindows every N ticks
var g_scan_tick_counter: u32 = 0;
// 20 ticks at 50ms/tick is roughly 1 second between scans.
const SCAN_INTERVAL_TICKS: u32 = 20;

// Throttles how often each activity stat is pushed to painter.
var g_last_dps_update_ms: i64 = 0;
var g_last_mining_update_ms: i64 = 0;
var g_last_bounty_update_ms: i64 = 0;

// Reused across timer ticks to avoid a per-tick alloc; borrowed slices only, no ownership.
var g_chatlog_char_names: std.ArrayList([]const u8) = .empty;
var g_chatlog_logged_out_names: std.ArrayList([]const u8) = .empty;

fn timerWindowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_TRAYICON => {
            if (g_tray_icon) |*icon| {
                // Safety check: only access g_config if it's been initialized (g_config_ptr is set after initialization)
                const profile_name = if (g_config_ptr) |cfg| cfg.profile_name else "";
                const cfg = g_config_ptr orelse &g_config;
                icon.handleTrayMessage(lParam, profile_name, cfg, g_hotkey_manager, g_painter);
            }
            return 0;
        },
        win32.WM_COMMAND => {
            const command_id = @as(u16, @truncate(wParam));
            const cfg = g_config_ptr orelse &g_config;
            if (tray.TrayIcon.handleMenuCommand(command_id, cfg, g_allocator, g_hotkey_manager)) {
                return 0;
            }
            return 0;
        },
        win32.WM_TIMER => {
            if (wParam == TIMER_ID) {
                onTimerTick();
            }
            return 0;
        },
        win32.WM_HOTKEY => {
            if (g_hotkey_manager) |manager| {
                manager.handleHotkeyPress(@intCast(wParam), lParam);
            }
            return 0;
        },
        win32.WM_HOTKEYS_STATE_CHANGED => {
            if (g_tray_icon) |*icon| {
                if (g_hotkey_manager) |manager| {
                    if (manager.areHotkeysSuspended()) {
                        icon.showBalloon("EVE-Maj Preview", "Hotkeys suspended", win32.NIIF_WARNING);
                    } else {
                        icon.showBalloon("EVE-Maj Preview", "Hotkeys resumed", win32.NIIF_INFO);
                    }
                }
            }
            return 0;
        },
        win32.WM_TOGGLE_VISIBILITY => {
            if (g_painter) |painter_ptr| {
                painter_ptr.toggleAllThumbnailsVisibility();
            }
            return 0;
        },
        win32.WM_SWITCH_PROFILE => {
            if (tray.TrayIcon.takePendingProfileName()) |new_profile| {
                slog.info("Switching to profile: {s}", .{new_profile});
                reloadWithProfile(new_profile) catch |err| {
                    slog.err("Failed to switch profile to {s}: {}", .{ new_profile, err });
                };
            }
            return 0;
        },
        win32.WM_COPYDATA => {
            const cds = @as(*const win32.COPYDATASTRUCT, @ptrFromInt(@as(usize, @bitCast(lParam))));

            switch (cds.dwData) {
                win32.PROTOCOL_SWITCH_CHARACTER => {
                    if (cds.lpData) |data_ptr| {
                        const char_name = @as([*]const u8, @ptrCast(data_ptr))[0..cds.cbData];
                        slog.info("Protocol handler: switch to character: {s}", .{char_name});
                        if (g_scout) |scout_ptr| {
                            if (scout_ptr.getHwndByName(char_name)) |target_hwnd| {
                                input.handleThumbnailClick(target_hwnd);
                            } else {
                                slog.warn("Character '{s}' not found", .{char_name});
                            }
                        }
                    }
                },
                win32.PROTOCOL_SWITCH_PROFILE => {
                    if (cds.lpData) |data_ptr| {
                        const profile_name = @as([*]const u8, @ptrCast(data_ptr))[0..cds.cbData];
                        slog.info("Protocol handler: switch to profile: {s}", .{profile_name});
                        reloadWithProfile(profile_name) catch |err| {
                            slog.err("Failed to switch profile to {s}: {}", .{ profile_name, err });
                        };
                    }
                },
                win32.PROTOCOL_PREVIEW_THUMBNAIL => {
                    if (cds.lpData) |data_ptr| {
                        const json_data = @as([*]const u8, @ptrCast(data_ptr))[0..cds.cbData];
                        applyThumbnailPreview(json_data) catch |err| {
                            slog.err("Failed to apply thumbnail preview: {}", .{err});
                        };
                    }
                },
                win32.PROTOCOL_REVERT_PREVIEW => revertThumbnailPreview(),
                win32.PROTOCOL_DIALOG_SUSPEND_HOTKEYS => {
                    if (g_hotkey_manager) |manager| {
                        manager.dialogSuspendHotkeys(hwnd);
                    }
                },
                win32.PROTOCOL_DIALOG_RESUME_HOTKEYS => {
                    if (g_hotkey_manager) |manager| {
                        manager.dialogResumeHotkeys(hwnd);
                    }
                },
                else => {},
            }
            return 0;
        },
        win32.WM_PROTOCOL_HOTKEY => {
            // wParam identifies which hotkey action the protocol handler requested
            const action = std.meta.intToEnum(protocol.HotkeyAction, wParam) catch {
                slog.warn("Unknown protocol hotkey action: {}", .{wParam});
                return 0;
            };
            slog.info("Protocol handler: {s}", .{@tagName(action)});
            if (g_hotkey_manager) |manager| {
                switch (action) {
                    .minimize_all => manager.handleMinimizeAllRequest(),
                    .close_all => manager.handleCloseAllRequest(),
                    .toggle_visibility => manager.handleToggleVisibilityRequest(),
                    .next_profile => manager.handleNextProfileRequest(),
                    .previous_profile => manager.handlePreviousProfileRequest(),
                    .toggle_exclusion => manager.handleToggleExclusionRequest(),
                    .next_excluded => manager.handleNextExcludedRequest(),
                    .previous_excluded => manager.handlePreviousExcludedRequest(),
                    .suspend_hotkeys => manager.handleSuspendHotkeysRequest(),
                    .toggle_auto_minimize => manager.handleToggleAutoMinimizeRequest(),
                    .cycle_notified => manager.handleCycleNotifiedRequest(),
                    .previous_notified => manager.handlePreviousNotifiedRequest(),
                    .next_all_clients => manager.handleCycleAllClientsRequest(true),
                    .previous_all_clients => manager.handleCycleAllClientsRequest(false),
                    .next_not_logged_in => manager.handleCycleNotLoggedInRequest(true),
                    .previous_not_logged_in => manager.handleCycleNotLoggedInRequest(false),
                    .move_to_saved_positions => manager.handleMoveToSavedPositionsRequest(),
                }
            }
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}

/// Runs one WM_TIMER tick: scan for EVE windows, then push the results through
/// the painter, chatlog monitor, and combat/mining trackers.
fn onTimerTick() void {
    g_scan_tick_counter += 1;
    const force_scan = (g_scan_tick_counter >= SCAN_INTERVAL_TICKS);
    if (force_scan) {
        g_scan_tick_counter = 0;
    }

    const scout_ptr = g_scout orelse return;
    var scout_result = scout_ptr.update(force_scan) catch |err| {
        slog.err("Failed to update Scout: {}", .{err});
        return;
    };
    defer scout_result.deinit(g_allocator);

    if (g_painter) |painter_ptr| {
        painter_ptr.update(scout_result.windows, scout_result.closed_windows.items, scout_result.name_changes.items) catch |err| {
            slog.err("Failed to update Painter: {}", .{err});
        };

        painter_ptr.updateNotifications();
    }

    if (g_chatlog_monitor) |monitor| {
        g_chatlog_char_names.clearRetainingCapacity();
        g_chatlog_logged_out_names.clearRetainingCapacity();

        for (scout_result.windows) |eve_window| {
            g_chatlog_char_names.append(g_allocator, eve_window.character_name) catch |err| {
                slog.warn("Failed to track {s} for chatlog update: {}", .{ eve_window.character_name, err });
                continue;
            };
        }

        for (scout_result.name_changes.items) |change| {
            if (scout.isGenericCharacterName(change.new_name) and !scout.isGenericCharacterName(change.old_name)) {
                g_chatlog_logged_out_names.append(g_allocator, change.old_name) catch |err| {
                    slog.warn("Failed to track logged-out name {s} for chatlog update: {}", .{ change.old_name, err });
                    continue;
                };
            }
        }

        monitor.update(g_chatlog_char_names.items, scout_result.closed_windows.items, g_chatlog_logged_out_names.items) catch |err| {
            slog.err("Failed to update Chatlog Monitor: {}", .{err});
        };
    }

    const now_ms = std.time.milliTimestamp();

    if (g_combat_tracker) |tracker| {
        const interval_ms: i64 = @intCast(g_config.combat.update_interval_ms);
        updateThrottledTracker(
            activity_mod.CombatTracker,
            pushDpsUpdate,
            tracker,
            now_ms,
            &g_last_dps_update_ms,
            interval_ms,
            scout_result.windows,
        );
    }

    if (g_mining_tracker) |tracker| {
        const interval_ms: i64 = @intCast(g_config.mining.update_interval_ms);
        updateThrottledTracker(
            activity_mod.MiningTracker,
            pushMiningUpdate,
            tracker,
            now_ms,
            &g_last_mining_update_ms,
            interval_ms,
            scout_result.windows,
        );
    }

    if (g_bounty_tracker) |tracker| {
        const interval_ms: i64 = @intCast(g_config.bounty.update_interval_ms);
        updateThrottledTracker(
            activity_mod.BountyTracker,
            pushBountyUpdate,
            tracker,
            now_ms,
            &g_last_bounty_update_ms,
            interval_ms,
            scout_result.windows,
        );
    }
}

/// Shared throttle/dispatch loop for the combat/mining/bounty trackers: refreshes every tick, pushes values into the painter (and flushes dirty overlays) once per `interval_ms`.
fn updateThrottledTracker(
    comptime T: type,
    comptime perWindow: fn (*T, *painter.Painter, scout.EveWindow, i64) void,
    tracker: *T,
    now_ms: i64,
    last_update_ms: *i64,
    interval_ms: i64,
    windows: []const scout.EveWindow,
) void {
    _ = tracker.refreshAll(now_ms);
    if (now_ms - last_update_ms.* < interval_ms) return;
    last_update_ms.* = now_ms;

    const painter_ptr = g_painter orelse return;
    for (windows) |eve_window| {
        perWindow(tracker, painter_ptr, eve_window, now_ms);
    }
    painter_ptr.processDirtyDpsOverlays();
}

fn pushDpsUpdate(tracker: *activity_mod.CombatTracker, painter_ptr: *painter.Painter, eve_window: scout.EveWindow, now_ms: i64) void {
    const dps = tracker.getDps(eve_window.character_name);

    painter_ptr.updateDpsForCharacter(eve_window.hwnd, dps.incoming, dps.outgoing);

    if (tracker.checkDamageAlert(eve_window.character_name, now_ms)) {
        painter_ptr.showNotification(eve_window.hwnd, "Taking damage", .TakingDamage) catch |err| {
            slog.warn("Failed to show taking-damage notification: {}", .{err});
        };
    }
}

fn pushMiningUpdate(tracker: *activity_mod.MiningTracker, painter_ptr: *painter.Painter, eve_window: scout.EveWindow, now_ms: i64) void {
    const rate = tracker.getRate(eve_window.character_name);
    const isk_rate = tracker.getIskRate(eve_window.character_name);

    painter_ptr.updateMiningForCharacter(eve_window.hwnd, rate, isk_rate);

    const alert_window_ms: i64 = @as(i64, g_config.mining.idle_alert_window_seconds) * std.time.ms_per_s;
    if (tracker.checkIdleAlert(eve_window.character_name, now_ms, alert_window_ms, g_config.mining.idle_alert_threshold)) {
        painter_ptr.showNotification(eve_window.hwnd, "Laser idle", .MiningIdle) catch |err| {
            slog.warn("Failed to show mining idle notification: {}", .{err});
        };
    }

    const stopped_window_ms: i64 = @as(i64, g_config.mining.stopped_alert_window_seconds) * std.time.ms_per_s;
    if (tracker.checkStoppedAlert(eve_window.character_name, now_ms, stopped_window_ms)) {
        painter_ptr.showNotification(eve_window.hwnd, "Mining stopped", .MiningStopped) catch |err| {
            slog.warn("Failed to show mining stopped notification: {}", .{err});
        };
    }
}

fn pushBountyUpdate(tracker: *activity_mod.BountyTracker, painter_ptr: *painter.Painter, eve_window: scout.EveWindow, now_ms: i64) void {
    _ = now_ms;
    const isk_rate = tracker.getIskRate(eve_window.character_name);

    painter_ptr.updateBountyForCharacter(eve_window.hwnd, isk_rate);
}

fn createTracker(comptime T: type, allocator: std.mem.Allocator, window_seconds: u32) !*T {
    const ptr = try allocator.create(T);
    ptr.* = T.init(allocator, window_seconds);
    return ptr;
}

fn consoleCtrlHandler(ctrl_type: win32.DWORD) callconv(.c) win32.BOOL {
    switch (ctrl_type) {
        win32.CTRL_C_EVENT, win32.CTRL_BREAK_EVENT, win32.CTRL_CLOSE_EVENT, win32.CTRL_LOGOFF_EVENT, win32.CTRL_SHUTDOWN_EVENT => {
            log.flush();
        },
        else => {},
    }
    // Never claim to have handled it: this only flushes, the OS's default behavior for the event (e.g. terminating the process) still applies.
    return win32.FALSE;
}

/// Gets the panic message into eve-maj.log - Zig's default handler only writes to
/// stderr, which is invisible in this Windows-subsystem build outside logLevel=debug.
pub const panic = std.debug.FullPanic(handlePanic);

fn handlePanic(msg: []const u8, ret_addr: ?usize) noreturn {
    log.writeCrashLine("PANIC: {s}", .{msg});
    std.debug.defaultPanic(msg, ret_addr);
}

// Overwritten on every crash - only the latest is kept, so a crash loop can't fill the disk.
const MINIDUMP_FILE_NAME = std.unicode.utf8ToUtf16LeStringLiteral("eve-maj-crash.dmp");

// dbghelp.dll (MiniDumpWriteDump) isn't thread-safe; this flag serializes writes and resets after each attempt so a later crash can still dump.
var dump_write_in_progress = std.atomic.Value(bool).init(false);

fn writeMinidump(info: *win32.EXCEPTION_POINTERS) void {
    if (dump_write_in_progress.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    defer dump_write_in_progress.store(false, .release);

    const file = win32.CreateFileW(MINIDUMP_FILE_NAME, win32.GENERIC_WRITE, win32.FILE_SHARE_READ, null, win32.CREATE_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL, null);
    if (file == win32.INVALID_HANDLE_VALUE) return;
    defer _ = win32.CloseHandle(file);

    var exc_info = win32.MINIDUMP_EXCEPTION_INFORMATION{
        .ThreadId = win32.GetCurrentThreadId(),
        .ExceptionPointers = info,
        .ClientPointers = win32.FALSE,
    };
    const ok = win32.MiniDumpWriteDump(win32.GetCurrentProcess(), win32.GetCurrentProcessId(), file, win32.MiniDumpNormal, &exc_info, null, null);
    if (ok == win32.FALSE) {
        log.writeCrashLine("MiniDumpWriteDump failed, GetLastError=0x{x}", .{win32.GetLastError()});
    }
}

// Runs before Zig's segfault handler rewrites OS faults into an indistinguishable @breakpoint(); logs only the fault types Zig treats specially, passing everything else through silently.
fn firstChanceExceptionHandler(info: *win32.EXCEPTION_POINTERS) callconv(.c) win32.LONG {
    const rec = info.ExceptionRecord orelse return win32.EXCEPTION_CONTINUE_SEARCH;
    switch (rec.ExceptionCode) {
        win32.EXCEPTION_ACCESS_VIOLATION, win32.EXCEPTION_ILLEGAL_INSTRUCTION, win32.EXCEPTION_DATATYPE_MISALIGNMENT, win32.EXCEPTION_STACK_OVERFLOW => {},
        else => return win32.EXCEPTION_CONTINUE_SEARCH,
    }

    const base: usize = if (win32.GetModuleHandleA(null)) |h| @intFromPtr(h) else 0;
    const addr: usize = if (rec.ExceptionAddress) |a| @intFromPtr(a) else 0;
    if (rec.ExceptionCode == win32.EXCEPTION_ACCESS_VIOLATION and rec.NumberParameters >= 2) {
        const is_write = rec.ExceptionInformation[0] == 1;
        const fault_addr = rec.ExceptionInformation[1];
        log.writeCrashLine("First-chance access violation ({s}) at address 0x{x}, code address 0x{x} (module base 0x{x}, RVA 0x{x})", .{ if (is_write) "write" else "read", fault_addr, addr, base, addr -% base });
    } else {
        log.writeCrashLine("First-chance exception 0x{x} at address 0x{x} (module base 0x{x}, RVA 0x{x})", .{ rec.ExceptionCode, addr, base, addr -% base });
    }
    return win32.EXCEPTION_CONTINUE_SEARCH;
}

// Last handler in the chain, after Zig's own panic/segfault handling already ran (if any); returns EXCEPTION_CONTINUE_SEARCH so Windows' normal handling still runs after.
fn unhandledExceptionFilter(info: *win32.EXCEPTION_POINTERS) callconv(.c) win32.LONG {
    const base: usize = if (win32.GetModuleHandleA(null)) |h| @intFromPtr(h) else 0;
    if (info.ExceptionRecord) |rec| {
        const addr: usize = if (rec.ExceptionAddress) |a| @intFromPtr(a) else 0;
        // Wrapping sub: a wild jump could fault below the module base and this handler must not itself panic on overflow.
        log.writeCrashLine("Unhandled exception 0x{x} at address 0x{x} (module base 0x{x}, RVA 0x{x})", .{ rec.ExceptionCode, addr, base, addr -% base });
    } else {
        log.writeCrashLine("Unhandled exception (no exception record), module base 0x{x}", .{base});
    }
    writeMinidump(info);
    return win32.EXCEPTION_CONTINUE_SEARCH;
}

pub fn main() void {
    _ = win32.AddVectoredExceptionHandler(1, firstChanceExceptionHandler);
    _ = win32.SetUnhandledExceptionFilter(unhandledExceptionFilter);
    defer log.deinitFile();

    mainImpl() catch |err| {
        slog.err("Fatal error: {}", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        std.process.exit(1);
    };
}

fn mainImpl() !void {
    // Handle protocol invocation before the mutex check, so commands work even when another instance is already running.
    var gpa_early = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_early.deinit();
    const early_allocator = gpa_early.allocator();

    const protocol_url = try protocol.checkCommandLine(early_allocator);
    defer if (protocol_url) |url| early_allocator.free(url);

    if (protocol_url) |url| {
        slog.info("Protocol handler invoked: {s}", .{url});

        if (protocol.findExistingInstance(TIMER_CLASS_NAME)) |existing_hwnd| {
            const cmd = protocol.parseUrl(url, early_allocator) catch |err| {
                slog.err("Failed to parse protocol URL: {}", .{err});
                return err;
            };
            defer switch (cmd) {
                .Switch => |s| early_allocator.free(s),
                .Profile => |p| early_allocator.free(p),
                else => {},
            };

            protocol.sendCommandToInstance(existing_hwnd, cmd);

            slog.info("Protocol command sent successfully", .{});
            return;
        } else {
            slog.warn("No existing instance found, protocol command ignored", .{});
            return error.NoExistingInstance;
        }
    }

    const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Global\\EVE-Maj-Preview-SingleInstance");
    const instance_mutex = win32.CreateMutexW(null, win32.TRUE, mutex_name);

    if (instance_mutex == null) {
        slog.err("Failed to create instance mutex", .{});
        return error.MutexCreationFailed;
    }
    defer _ = win32.CloseHandle(instance_mutex.?);

    const last_error = win32.GetLastError();
    if (last_error == win32.ERROR_ALREADY_EXISTS) {
        slog.info("Another instance of EVE-Maj Preview is already running", .{});
        return error.AlreadyRunning;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    g_allocator = gpa.allocator();
    defer g_chatlog_char_names.deinit(g_allocator);
    defer g_chatlog_logged_out_names.deinit(g_allocator);

    slog.info("EVE-Maj Preview v{s}", .{build_options.version});

    g_global_settings = try config_mod.GlobalSettings.load(g_allocator);
    defer g_global_settings.deinit();
    log.setLevel(g_global_settings.logLevel);
    g_global_settings.logSettings();

    var profile_name: []const u8 = if (g_global_settings.lastUsedProfile.len > 0)
        g_global_settings.lastUsedProfile
    else
        config_mod.DEFAULT_PROFILE;

    const args2 = try std.process.argsAlloc(g_allocator);
    defer std.process.argsFree(g_allocator, args2);

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

    g_config = try config_mod.Config.loadProfile(g_allocator, profile_name);
    defer g_config.deinit();

    // Not profile_name: loadProfile() may have fallen back to default, and this heals global settings to match.
    try g_global_settings.updateLastUsed(g_config.profile_name);

    g_config.logSettings();

    if (g_config.autoRegisterProtocol) {
        if (!protocol.isRegistered()) {
            slog.info("Protocol handler not registered, attempting auto-registration...", .{});
            const success = protocol.register(g_allocator) catch |err| blk: {
                slog.warn("Failed to auto-register protocol handler: {}", .{err});
                slog.warn("You may need to run as administrator or manually register using register-protocol.reg", .{});
                break :blk false;
            };
            if (success) {
                slog.info("Protocol handler successfully registered", .{});
            } else {
                slog.warn("Protocol handler registration returned false", .{});
            }
        } else {
            slog.debug("Protocol handler already registered", .{});
        }
    }

    defer tts.shutdown();

    // Allocate console in debug mode (Windows GUI subsystem doesn't create one by default)
    if (g_global_settings.logLevel == .debug) {
        _ = win32.AllocConsole();
        // Closing the console window kills the process before any `defer` can run, so flush buffered log lines from here instead of relying on shutdown cleanup.
        _ = win32.SetConsoleCtrlHandler(consoleCtrlHandler, win32.TRUE);
    }

    g_scout = try g_allocator.create(scout.Scout);
    {
        errdefer g_allocator.destroy(g_scout.?);
        g_scout.?.* = try scout.Scout.init(g_allocator, &g_config);
    }
    g_scout.?.setGlobalInstance();
    g_scout_ptr = g_scout;
    defer {
        g_scout.?.deinit();
        g_allocator.destroy(g_scout.?);
        g_scout_ptr = null;
    }

    g_painter = try g_allocator.create(painter.Painter);
    {
        errdefer g_allocator.destroy(g_painter.?);
        g_painter.?.* = try painter.Painter.init(g_allocator, &g_config);
    }
    painter.g_painter_ptr = g_painter;
    input.g_painter_ptr = g_painter;

    // Export config for direct access by input module
    g_config_ptr = &g_config;

    defer {
        g_painter.?.deinit();
        g_allocator.destroy(g_painter.?);
        g_config_ptr = null;
    }

    if (g_config.chatlog.enabled) {
        g_chatlog_monitor = try chatlog.ChatlogMonitor.init(
            g_allocator,
            g_config.chatlog.chatlogDir,
            g_config.chatlog.gamelogDir,
            g_painter.?,
            g_scout.?,
            &g_global_settings,
            g_config.chatlog.idlePollThreshold,
            g_config.chatlog.maxPollMultiplier,
            g_config.chatlog.pollIntervalMs,
        );
    } else {
        slog.info("Chatlog monitoring disabled", .{});
    }

    if (g_config.combat.enabled) {
        g_combat_tracker = try createTracker(activity_mod.CombatTracker, g_allocator, g_config.combat.window_seconds);

        if (g_chatlog_monitor) |monitor| {
            monitor.combat_tracker = g_combat_tracker.?;
        }

        slog.debug("Combat DPS tracking enabled ({d}s window)", .{g_config.combat.window_seconds});
    }

    defer {
        if (g_combat_tracker) |tracker| {
            tracker.deinit();
            g_allocator.destroy(tracker);
            g_combat_tracker = null;
        }
    }

    if (g_config.mining.enabled) {
        g_mining_tracker = try createTracker(activity_mod.MiningTracker, g_allocator, g_config.mining.window_seconds);

        if (g_chatlog_monitor) |monitor| {
            monitor.mining_tracker = g_mining_tracker.?;
        }

        slog.debug("Mining rate tracking enabled ({d}s window)", .{g_config.mining.window_seconds});
    }

    defer {
        if (g_mining_tracker) |tracker| {
            tracker.deinit();
            g_allocator.destroy(tracker);
            g_mining_tracker = null;
        }
    }

    if (g_config.bounty.enabled) {
        g_bounty_tracker = try createTracker(activity_mod.BountyTracker, g_allocator, g_config.bounty.window_seconds);

        if (g_chatlog_monitor) |monitor| {
            monitor.bounty_tracker = g_bounty_tracker.?;
        }

        slog.debug("Bounty rate tracking enabled ({d}s window)", .{g_config.bounty.window_seconds});
    }

    defer {
        if (g_bounty_tracker) |tracker| {
            tracker.deinit();
            g_allocator.destroy(tracker);
            g_bounty_tracker = null;
        }
    }

    // Registered after the tracker defers so it runs first (LIFO): the worker thread must stop before combat/mining trackers are freed, since it may be mid-iteration reading them.
    defer {
        if (g_chatlog_monitor) |monitor| {
            monitor.deinit();
            g_allocator.destroy(monitor);
        }
    }

    // Start the worker thread only now that combat/mining trackers are wired in, so it never observes combat_tracker/mining_tracker as null when they should be set.
    if (g_chatlog_monitor) |monitor| {
        if (g_config.chatlog.useThreading) {
            try monitor.startWorkerThread();
        }
        slog.debug("Chatlog monitoring enabled (threading: {})", .{g_config.chatlog.useThreading});
    }

    const instance = win32.GetModuleHandleA(null) orelse return error.GetModuleHandleFailed;

    const wc = win32.WNDCLASSEXA{
        .cbSize = @sizeOf(win32.WNDCLASSEXA),
        .style = 0,
        .lpfnWndProc = timerWindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = TIMER_CLASS_NAME,
        .hIconSm = null,
    };

    if (win32.RegisterClassExA(&wc) == 0) {
        return error.RegisterClassFailed;
    }

    const timer_hwnd = win32.CreateWindowExA(
        0,
        TIMER_CLASS_NAME,
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

    try g_scout.?.scanForEveWindows();

    // Create thumbnail windows for each EVE client (fast - no I/O blocking)
    const eve_windows = g_scout.?.getWindows();
    for (eve_windows) |*eve_window| {
        try g_painter.?.createThumbnail(eve_window, "");
    }

    // Register with chatlog monitor after thumbnails are visible (deferred I/O)
    if (g_chatlog_monitor) |monitor| {
        for (eve_windows) |eve_window| {
            monitor.addCharacter(eve_window.character_name) catch |err| {
                slog.err("Failed to add {s} to chatlog monitor: {}", .{ eve_window.character_name, err });
            };
        }
    }

    g_hotkey_manager = try g_allocator.create(hotkeys.HotkeyManager);
    {
        errdefer g_allocator.destroy(g_hotkey_manager.?);
        g_hotkey_manager.?.* = try hotkeys.HotkeyManager.init(g_allocator, &g_config, &g_global_settings, g_scout.?, g_painter.?);
    }
    painter.g_hotkey_manager_ptr = g_hotkey_manager;
    defer {
        if (g_hotkey_manager) |manager| {
            manager.unregisterAll(timer_hwnd);
            manager.deinit();
            g_allocator.destroy(manager);
        }
        painter.g_hotkey_manager_ptr = null;
        mouse_hook.deinit();
        input.deinitHotkeyTracking();
    }

    g_hotkey_manager.?.registerHotkeys(timer_hwnd) catch |err| {
        slog.warn("Failed to register hotkeys: {} - continuing without hotkey support", .{err});
    };

    const TIMER_INTERVAL: win32.UINT = g_config.timer.scanIntervalMs;
    const timer_id = win32.SetTimer(timer_hwnd, TIMER_ID, TIMER_INTERVAL, null);
    if (timer_id == 0) {
        slog.err("Failed to create timer", .{});
        return error.SetTimerFailed;
    }
    defer _ = win32.KillTimer(timer_hwnd, TIMER_ID);

    var msg: win32.MSG = undefined;
    while (win32.GetMessageA(&msg, null, 0, 0) != 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageA(&msg);
    }
}

/// Completely reinitializes all subsystems with a newly loaded profile's configuration.
fn reloadWithProfile(new_profile_name: []const u8) !void {
    slog.info("=== Starting profile reload: {s} ===", .{new_profile_name});

    const timer_hwnd = g_timer_hwnd orelse return error.NoTimerWindow;

    // Loaded up front so we can decide below whether chatlog monitoring needs a rebuild.
    const new_config = config_mod.Config.loadProfile(g_allocator, new_profile_name) catch |err| blk: {
        slog.err("Failed to load new profile, reverting to default", .{});
        break :blk config_mod.Config.load(g_allocator) catch {
            // Original profile-load error, not the fallback's.
            return err;
        };
    };

    const keep_chatlog_monitor = g_chatlog_monitor != null and
        g_config.chatlog.enabled == new_config.chatlog.enabled and
        g_config.chatlog.useThreading == new_config.chatlog.useThreading and
        std.mem.eql(u8, g_config.chatlog.chatlogDir, new_config.chatlog.chatlogDir) and
        std.mem.eql(u8, g_config.chatlog.gamelogDir, new_config.chatlog.gamelogDir);

    if (g_hotkey_manager) |manager| {
        manager.unregisterAll(timer_hwnd);
        slog.debug("Unregistered hotkeys", .{});
    }

    if (keep_chatlog_monitor) {
        // Pause (not destroy) so the worker thread can't race the pointer swaps below.
        g_chatlog_monitor.?.stopWorkerThread();
        slog.debug("Paused chatlog monitor for reload (scan state preserved)", .{});
    } else if (g_chatlog_monitor) |monitor| {
        monitor.deinit();
        g_allocator.destroy(monitor);
        g_chatlog_monitor = null;
        slog.debug("Cleaned up chatlog monitor", .{});
    }

    // Must run after chatlog monitor teardown.
    if (g_combat_tracker) |tracker| {
        tracker.deinit();
        g_allocator.destroy(tracker);
        g_combat_tracker = null;
        slog.debug("Cleaned up combat tracker", .{});
    }

    // Must run after chatlog monitor teardown.
    if (g_mining_tracker) |tracker| {
        tracker.deinit();
        g_allocator.destroy(tracker);
        g_mining_tracker = null;
        slog.debug("Cleaned up mining tracker", .{});
    }

    // Must run after chatlog monitor teardown.
    if (g_bounty_tracker) |tracker| {
        tracker.deinit();
        g_allocator.destroy(tracker);
        g_bounty_tracker = null;
        slog.debug("Cleaned up bounty tracker", .{});
    }

    if (g_hotkey_manager) |manager| {
        manager.deinit();
        g_allocator.destroy(manager);
        g_hotkey_manager = null;
        painter.g_hotkey_manager_ptr = null;
        slog.debug("Cleaned up hotkey manager", .{});
    }

    // Snapshot last-known system names before the painter tears down thumbnails, so new ones can be seeded instead of going blank; keyed by source_hwnd, stable across teardown/recreate.
    var last_known_systems = std.AutoHashMap(win32.HWND, []const u8).init(g_allocator);
    defer {
        var it = last_known_systems.valueIterator();
        while (it.next()) |v| g_allocator.free(v.*);
        last_known_systems.deinit();
    }
    if (g_painter) |painter_ptr| {
        for (painter_ptr.thumbnails.items) |thumb| {
            if (thumb.system_name.len > 0) {
                const copy = g_allocator.dupe(u8, thumb.system_name) catch continue;
                last_known_systems.put(thumb.source_hwnd, copy) catch g_allocator.free(copy);
            }
        }
    }

    if (g_painter) |painter_ptr| {
        painter_ptr.deinit();
        g_allocator.destroy(painter_ptr);
        g_painter = null;
        painter.g_painter_ptr = null;
        input.g_painter_ptr = null;
        g_config_ptr = null;
        slog.debug("Cleaned up painter", .{});
    }

    g_config.deinit();
    slog.debug("Cleaned up old config", .{});

    g_config = new_config;

    slog.info("Loaded new config: {s}", .{new_profile_name});
    g_config.logSettings();

    // Picks up hotkey/profile-switch/log-level edits made via the config dialog while running, since g_global_settings is otherwise only loaded once at startup.
    if (config_mod.GlobalSettings.load(g_allocator)) |reloaded| {
        g_global_settings.deinit();
        g_global_settings = reloaded;
        log.setLevel(g_global_settings.logLevel);
        slog.debug("Reloaded global settings from disk", .{});
        g_global_settings.logSettings();
    } else |err| {
        slog.warn("Failed to reload global settings: {}", .{err});
    }

    g_global_settings.updateLastUsed(new_profile_name) catch |err| {
        slog.warn("Failed to update global settings: {}", .{err});
    };

    g_painter = g_allocator.create(painter.Painter) catch |err| {
        slog.err("Failed to create painter: {}", .{err});
        return err;
    };
    g_painter.?.* = painter.Painter.init(g_allocator, &g_config) catch |err| {
        g_allocator.destroy(g_painter.?);
        g_painter = null;
        slog.err("Failed to initialize painter: {}", .{err});
        return err;
    };
    painter.g_painter_ptr = g_painter;
    input.g_painter_ptr = g_painter;
    g_config_ptr = &g_config;
    slog.debug("Reinitialized painter", .{});

    // Repoint a preserved chatlog monitor at the new painter (its old target is now freed).
    if (g_chatlog_monitor) |monitor| {
        monitor.painter = g_painter.?;
    }

    if (g_scout) |scout_ptr| {
        scan_blk: {
            scout_ptr.scanForEveWindows() catch |err| {
                slog.err("Failed to scan for EVE windows: {}", .{err});
                break :scan_blk;
            };
            scout_ptr.pruneNonMatchingWindows();

            const eve_windows = scout_ptr.getWindows();
            for (eve_windows) |eve_window| {
                // Only if monitoring stays on to refresh it, or a stale name would freeze on screen forever.
                const initial_system_name = if (g_config.chatlog.enabled) (last_known_systems.get(eve_window.hwnd) orelse "") else "";
                g_painter.?.createThumbnail(&eve_window, initial_system_name) catch |err| {
                    slog.err("Failed to create thumbnail for {s}: {}", .{ eve_window.character_name, err });
                };
            }
            slog.debug("Recreated {} thumbnail(s)", .{eve_windows.len});

            if (keep_chatlog_monitor) {
                if (g_chatlog_monitor) |monitor| {
                    monitor.idle_poll_threshold = g_config.chatlog.idlePollThreshold;
                    monitor.max_poll_multiplier = g_config.chatlog.maxPollMultiplier;
                    monitor.poll_interval_ms = g_config.chatlog.pollIntervalMs;
                }
                slog.debug("Applied reload settings to paused chatlog monitor", .{});
            } else if (g_config.chatlog.enabled) {
                chatlog_blk: {
                    g_chatlog_monitor = chatlog.ChatlogMonitor.init(
                        g_allocator,
                        g_config.chatlog.chatlogDir,
                        g_config.chatlog.gamelogDir,
                        g_painter.?,
                        scout_ptr,
                        &g_global_settings,
                        g_config.chatlog.idlePollThreshold,
                        g_config.chatlog.maxPollMultiplier,
                        g_config.chatlog.pollIntervalMs,
                    ) catch |err| {
                        slog.warn("Failed to initialize chatlog monitor: {}", .{err});
                        g_chatlog_monitor = null;
                        break :chatlog_blk;
                    };

                    if (g_chatlog_monitor) |monitor| {
                        // Start the worker thread before adding characters, so addCharacter() queues work instead of blocking the message loop with log I/O.
                        if (g_config.chatlog.useThreading) {
                            monitor.startWorkerThread() catch |err| {
                                slog.warn("Failed to start chatlog worker thread: {}", .{err});
                            };
                        }

                        for (eve_windows) |eve_window| {
                            monitor.addCharacter(eve_window.character_name) catch |err| {
                                slog.err("Failed to add {s} to chatlog monitor: {}", .{ eve_window.character_name, err });
                            };
                        }
                    }
                    slog.info("Reinitialized chatlog monitoring (threading: {})", .{g_config.chatlog.useThreading});
                }
            } else {
                slog.info("Chatlog monitoring disabled in new profile", .{});
            }
        }

        if (g_config.combat.enabled) {
            if (createTracker(activity_mod.CombatTracker, g_allocator, g_config.combat.window_seconds)) |tracker_ptr| {
                g_combat_tracker = tracker_ptr;

                if (g_chatlog_monitor) |monitor| {
                    monitor.combat_tracker = tracker_ptr;
                }

                slog.debug("Combat DPS tracking enabled ({d}s window)", .{g_config.combat.window_seconds});
            } else |err| {
                slog.err("Failed to create combat tracker: {}", .{err});
                g_combat_tracker = null;
                if (g_chatlog_monitor) |monitor| monitor.combat_tracker = null;
            }
        } else {
            if (g_chatlog_monitor) |monitor| monitor.combat_tracker = null;
            slog.debug("Combat DPS tracking disabled in new profile", .{});
        }

        if (g_config.mining.enabled) {
            if (createTracker(activity_mod.MiningTracker, g_allocator, g_config.mining.window_seconds)) |tracker_ptr| {
                g_mining_tracker = tracker_ptr;

                if (g_chatlog_monitor) |monitor| {
                    monitor.mining_tracker = tracker_ptr;
                }

                slog.debug("Mining rate tracking enabled ({d}s window)", .{g_config.mining.window_seconds});
            } else |err| {
                slog.err("Failed to create mining tracker: {}", .{err});
                g_mining_tracker = null;
                if (g_chatlog_monitor) |monitor| monitor.mining_tracker = null;
            }
        } else {
            if (g_chatlog_monitor) |monitor| monitor.mining_tracker = null;
            slog.debug("Mining rate tracking disabled in new profile", .{});
        }

        if (g_config.bounty.enabled) {
            if (createTracker(activity_mod.BountyTracker, g_allocator, g_config.bounty.window_seconds)) |tracker_ptr| {
                g_bounty_tracker = tracker_ptr;

                if (g_chatlog_monitor) |monitor| {
                    monitor.bounty_tracker = tracker_ptr;
                }

                slog.debug("Bounty rate tracking enabled ({d}s window)", .{g_config.bounty.window_seconds});
            } else |err| {
                slog.err("Failed to create bounty tracker: {}", .{err});
                g_bounty_tracker = null;
                if (g_chatlog_monitor) |monitor| monitor.bounty_tracker = null;
            }
        } else {
            if (g_chatlog_monitor) |monitor| monitor.bounty_tracker = null;
            slog.debug("Bounty rate tracking disabled in new profile", .{});
        }

        // Resume the paused worker only now that combat/mining trackers above are repointed (or nulled) - resuming any earlier risks it processing a queued event against trackers just destroyed.
        if (keep_chatlog_monitor) {
            if (g_chatlog_monitor) |monitor| {
                if (g_config.chatlog.useThreading) {
                    monitor.startWorkerThread() catch |err| {
                        slog.warn("Failed to resume chatlog worker thread: {}", .{err});
                    };
                }
            }
            slog.info("Resumed chatlog monitoring without rescanning logs (threading: {})", .{g_config.chatlog.useThreading});
        }
    }

    g_hotkey_manager = g_allocator.create(hotkeys.HotkeyManager) catch |err| {
        slog.err("Failed to create hotkey manager: {}", .{err});
        return err;
    };
    g_hotkey_manager.?.* = hotkeys.HotkeyManager.init(
        g_allocator,
        &g_config,
        &g_global_settings,
        g_scout.?,
        g_painter.?,
    ) catch |err| {
        g_allocator.destroy(g_hotkey_manager.?);
        g_hotkey_manager = null;
        slog.err("Failed to initialize hotkey manager: {}", .{err});
        return err;
    };
    painter.g_hotkey_manager_ptr = g_hotkey_manager;

    g_hotkey_manager.?.registerHotkeys(timer_hwnd) catch |err| {
        slog.warn("Failed to register hotkeys: {}", .{err});
    };
    slog.debug("Reinitialized hotkey manager", .{});

    const new_interval = g_config.timer.scanIntervalMs;
    _ = win32.SetTimer(timer_hwnd, TIMER_ID, new_interval, null);
    slog.debug("Updated timer interval to {} ms", .{new_interval});

    slog.info("=== Profile reload complete: {s} ===", .{new_profile_name});
}

/// Merges a live-preview patch (changed fields only) into the running config, repaints, and repositions thumbnails; unlike reloadWithProfile() it never touches hotkeys/chatlog/identity, so it's cheap enough to run on every keystroke/slider drag in the dialog.
fn applyThumbnailPreview(json_data: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, g_allocator, json_data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJsonFormat;
    const obj = parsed.value.object;

    try config_mod.Config.parseJsonThumbnailConfig(&g_config.thumbnail, obj, g_allocator);
    g_config.thumbnail.validate();

    // System color overrides live outside ThumbnailConfig (a top-level Config field), so they ride along in the same patch object instead of going through parseJsonThumbnailConfig.
    if (obj.get("systemColors")) |colors_val| {
        if (colors_val == .array) {
            g_config.replaceSystemColorsFromJson(g_allocator, colors_val.array.items) catch |err| {
                slog.err("Failed to apply system color overrides preview: {}", .{err});
            };
        }
    }

    // List View's own opacity/font settings live in DisplayConfig, not ThumbnailConfig - parsed separately from a nested "display" object in the same patch.
    // startX/startY are deliberately never sent here, since they can be live-dragged in the running app.
    var layout_changed = false;
    if (obj.get("display")) |display_val| {
        if (display_val == .object) {
            config_mod.Config.parseJsonDisplayConfig(&g_config.display, display_val.object, g_allocator) catch |err| {
                slog.err("Failed to apply display preview: {}", .{err});
            };
            g_config.display.validate();
            layout_changed = true;
        }
    }

    // Matched by character name against the running character list.
    if (obj.get("characterOverrides")) |overrides_val| {
        if (overrides_val == .array) {
            g_config.applyCharacterOverridesFromJson(g_allocator, overrides_val.array.items) catch |err| {
                slog.err("Failed to apply character overrides preview: {}", .{err});
            };
        }
    }

    if (g_painter) |painter_ptr| {
        painter_ptr.refreshAllThumbnailVisuals();
        if (layout_changed) painter_ptr.repositionAllThumbnails();
    }
}

/// Discards live-previewed appearance and layout changes by reloading that section from disk, repainting, and repositioning; sent when the config dialog closes, a no-op if Save was already clicked.
fn revertThumbnailPreview() void {
    g_config.reloadThumbnailConfigFromDisk(g_allocator) catch |err| {
        slog.err("Failed to revert thumbnail preview: {}", .{err});
        return;
    };

    if (g_painter) |painter_ptr| {
        painter_ptr.refreshAllThumbnailVisuals();
        painter_ptr.repositionAllThumbnails();
    }
}
