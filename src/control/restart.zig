//! Brings App's subsystems up at startup and rebuilds them on a reload, by running restart_plan.zig's steps.
const win32 = @import("../platform/win32.zig");
const app_mod = @import("../app.zig");
const config = @import("../config.zig");
const scout = @import("../clients/scout.zig");
const hotkeys = @import("../hotkeys/manager.zig");
const chatlog = @import("../chatlog.zig");
const restart_plan = @import("restart_plan.zig");
const log = @import("../log.zig");

const App = app_mod.App;
const HotkeyManager = hotkeys.HotkeyManager;
const slog = log.Scoped("restart");

/// What run's earlier steps hand to its later ones.
const Restart = struct {
    timer_hwnd: win32.HWND,
    /// The replacement store until install_profile takes it.
    pending: *?config.ProfileStore,
    global_draft: ?*config.GlobalConfig,
    /// Borrows Scout's windows, from rescan_windows on.
    eve_windows: []const scout.EveWindow = &.{},
};

/// Takes ownership of `replacement`, which becomes the running store.
pub fn run(app: *App, timer_hwnd: win32.HWND, replacement: ?config.ProfileStore, global_draft: ?*config.GlobalConfig) !void {
    var pending = replacement;
    errdefer if (pending) |*store| store.deinit();
    // Shared by every profile, so a Save's global draft holds what comes next.
    const next_chatlog = if (global_draft) |draft| &draft.chatlog else &app.global_settings.chatlog;

    const plan: restart_plan.Plan = .init(.{
        .is_profile_replaced = pending != null,
        .has_thumbnail_set = app.rebuilt.thumbnail_set != null,
        .has_monitor = app.rebuilt.chatlog_monitor != null,
        .is_monitor_on_next_folders = if (app.rebuilt.chatlog_monitor) |monitor| monitor.runsWith(next_chatlog) else false,
        .is_chatlog_enabled_next = next_chatlog.enabled,
        .has_global_draft = global_draft != null,
    });
    if (!next_chatlog.enabled) slog.info("Chatlog monitoring disabled", .{});

    var restart: Restart = .{ .timer_hwnd = timer_hwnd, .pending = &pending, .global_draft = global_draft };

    for (plan.steps(), 0..) |step, index| {
        runStep(app, step, &restart) catch |err| {
            const recovery = plan.recovery(index);
            for (recovery.steps()) |recovery_step| {
                runStep(app, recovery_step, &restart) catch |recovery_err| {
                    slog.err("Failed to recover from the failed reload ({s}): {}", .{ @tagName(recovery_step), recovery_err });
                };
            }
            return err;
        };
    }
}

/// Logs its own failures.
fn runStep(app: *App, step: restart_plan.Step, restart: *Restart) !void {
    switch (step) {
        .pause_monitor => {
            const monitor = app.rebuilt.chatlog_monitor orelse return;
            monitor.stopWorkerThread();
            slog.debug("Paused chatlog monitor for reload (scan state preserved)", .{});
        },
        .destroy_monitor => {
            app.destroyChatlogMonitor();
            slog.debug("Cleaned up chatlog monitor", .{});
        },
        .adopt_global_draft => if (restart.global_draft) |draft| app.global_settings.adopt(draft),
        .destroy_hotkey_manager => {
            if (app.rebuilt.hotkey_manager == null) return;
            app.destroyHotkeyManager();
            slog.debug("Cleaned up hotkey manager", .{});
        },
        .teardown_thumbnail_set => app.destroyThumbnailSet(),
        .install_profile => {
            const store = restart.pending.* orelse return;
            app.store.deinit();
            app.store = store;
            restart.pending.* = null;
            app.persistent.roster.clearAlerts();
            app.persistent.roster.restartMinimizeDelays(win32.Ticks.now());
            // Not dumped as at startup: it stalled switches with the debug console open.
            slog.info("Loaded new config: {s}", .{app.store.saved.profile_name});
            app.persistent.map_panel.sync(app.panelContext());
            app.persistent.notifications.sync(app.panelContext());
        },
        .record_last_used_profile => app.global_settings.updateLastUsed(app.io, app.store.saved.profile_name) catch |err| {
            slog.warn("Failed to update global settings: {}", .{err});
        },
        .rescan_windows => restart.eve_windows = rescanWindows(app),
        .refresh_roster_config => app.persistent.roster.refreshConfig(&app.store.live, &app.persistent.auto_colors, .all),
        .build_thumbnail_set => {
            app.buildThumbnailSet(restart.eve_windows) catch |err| {
                slog.err("Failed to create thumbnail set: {}", .{err});
                return err;
            };
            slog.debug("Built {} thumbnail(s)", .{restart.eve_windows.len});
        },
        .populate_thumbnail_set => if (app.rebuilt.thumbnail_set) |thumbnail_set| thumbnail_set.populate(restart.eve_windows),
        .clear_log_readings => {
            app.persistent.roster.clearLogReadings();
            slog.debug("Cleared what the logs last showed", .{});
        },
        .apply_monitor_settings => if (app.rebuilt.chatlog_monitor) |monitor| {
            monitor.applySettings(&app.global_settings.chatlog);
            slog.info("Kept chatlog monitoring without rescanning logs", .{});
        },
        // Created with its worker thread stopped, so the trackers can be wired in before it runs.
        .create_monitor => app.rebuilt.chatlog_monitor = chatlog.ChatlogMonitor.init(app.allocator, app.io, &app.global_settings.chatlog, &app.global_settings, &app.character_ids) catch |err| blk: {
            slog.err("Failed to initialize chatlog monitor: {}", .{err});
            break :blk null;
        },
        .setup_trackers => app.trackers.setup(&app.store.saved, app.rebuilt.chatlog_monitor),
        .apply_monitor_profile => if (app.rebuilt.chatlog_monitor) |monitor| monitor.applyProfile(&app.store.saved),
        .start_monitor => if (app.rebuilt.chatlog_monitor) |monitor| startChatlogWorker(monitor),
        .add_monitor_characters => if (app.rebuilt.chatlog_monitor) |monitor| {
            addChatlogCharacters(monitor, restart.eve_windows);
            slog.info("Started chatlog monitoring", .{});
        },
        .create_hotkey_manager => {
            createHotkeyManager(app, restart.timer_hwnd) catch |err| {
                slog.err("Failed to create hotkey manager: {}", .{err});
                return err;
            };
            slog.debug("Created hotkey manager", .{});
        },
        .set_tick_interval => {
            const new_interval = app.tickIntervalFor(restart.eve_windows.len);
            if (!app.setTickInterval(restart.timer_hwnd, new_interval)) {
                // At startup there's no timer to keep, and without one nothing runs.
                if (app.tick_interval_ms == 0) {
                    slog.err("Failed to create the tick timer", .{});
                    return error.SetTimerFailed;
                }
                slog.warn("Failed to update the timer interval to {} ms, keeping {} ms", .{ new_interval, app.tick_interval_ms });
                return;
            }
            slog.debug("Updated timer interval to {} ms", .{new_interval});
        },
    }
}

/// Applies the new profile's window filters; a failed scan keeps the tracked windows.
fn rescanWindows(app: *App) []const scout.EveWindow {
    app.scout.scanForEveWindows(app.store.saved.windowFilters.items) catch |err| {
        slog.err("Failed to scan for EVE windows: {}", .{err});
    };
    app.scout.pruneNonMatchingWindows(app.store.saved.windowFilters.items);
    // The set built from these windows reads their clients.
    app.syncRoster(app.scout.getWindows());
    return app.scout.getWindows();
}

/// A hotkey registration failure is logged, not fatal.
fn createHotkeyManager(app: *App, timer_hwnd: win32.HWND) !void {
    // Before anything can fail, so group cycling always matches the saved groups.
    app.cycle.reset(app.allocator, app.store.saved.hotkeyGroups.items.len);
    const manager = try app.allocator.create(HotkeyManager);
    manager.* = .init(app.allocator, .{
        .store = &app.store,
        .global_settings = &app.global_settings,
        .timer_hwnd = timer_hwnd,
    });
    app.rebuilt.hotkey_manager = manager;

    manager.registerHotkeys(timer_hwnd) catch |err| {
        slog.warn("Failed to register hotkeys, continuing without hotkey support: {}", .{err});
    };
    manager.syncFocusFilter(app.scout.getWindows());
}

fn addChatlogCharacters(monitor: *chatlog.ChatlogMonitor, windows: []const scout.EveWindow) void {
    for (windows) |eve_window| {
        if (!eve_window.is_eve_client) continue;
        monitor.addCharacter(eve_window.character_name) catch |err| {
            slog.err("Failed to add '{s}' to the chatlog monitor: {}", .{ eve_window.character_name, err });
        };
    }
}

fn startChatlogWorker(monitor: *chatlog.ChatlogMonitor) void {
    monitor.startWorkerThread() catch |err| {
        slog.warn("Failed to start chatlog worker thread: {}", .{err});
    };
}
