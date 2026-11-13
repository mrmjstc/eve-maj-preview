//! The running app: owns every long-lived subsystem, rebuilds them on a profile switch or Save, and runs each tick.
const std = @import("std");
const win32 = @import("platform/win32.zig");
const config = @import("config.zig");
const scout_mod = @import("clients/scout.zig");
const exclusions_mod = @import("clients/exclusions.zig");
const activation = @import("control/activation.zig");
const auto_minimize = @import("control/auto_minimize.zig");
const focus_mod = @import("control/focus.zig");
const restart_plan = @import("control/restart_plan.zig");
const thumbnail_input = @import("control/thumbnail_input.zig");
const set = @import("thumbnail/set.zig");
const hotkeys = @import("hotkeys/manager.zig");
const hook_bindings = @import("hotkeys/hook_bindings.zig");
const launch = @import("hotkeys/launch.zig");
const profile_switch = @import("hotkeys/profile_switch.zig");
const center = @import("notifications/center.zig");
const list_view = @import("panels/list_view.zig");
const map_panel_mod = @import("panels/map_panel.zig");
const panel_host = @import("panels/panel_host.zig");
const panel_look = @import("panels/panel_look.zig");
const chatlog = @import("chatlog.zig");
const character_ids_mod = @import("chatlog/character_ids.zig");
const runtime = @import("activity/runtime.zig");
const travel_left_behind = @import("travel/left_behind.zig");
const tray = @import("tray.zig");
const schedule = @import("util/schedule.zig");
const log = @import("log.zig");

const CharacterIds = character_ids_mod.CharacterIds;
const ThumbnailSet = set.ThumbnailSet;
const HotkeyManager = hotkeys.HotkeyManager;
const slog = log.Scoped("app");

/// Shares the timer window with focus.zig's HIDE_DEBOUNCE_TIMER_ID.
pub const TICK_TIMER_ID: usize = 1;
/// Timed, not counted in ticks, so a slower scan interval doesn't stretch it.
const FORCED_SCAN_INTERVAL_MS: u64 = 1000;
/// With nothing to draw, the tick only keeps up with the forced scan.
const IDLE_TICK_INTERVAL_MS: win32.UINT = FORCED_SCAN_INTERVAL_MS;
const TRAVEL_CHECK_INTERVAL_MS: u64 = 2000;
const PROFILE_NAME_BUFFER_SIZE = 256;
/// What the panels ask of App, which they can't import.
pub const PANEL_HOST: panel_host.Host = .{ .thumbnail_set = currentThumbnailSet, .run = runPanelRequest };

/// How far a live profile edit moves thumbnails; `spaces` reflows only active spaces.
pub const LiveLayout = enum { none, spaces, all };

/// What App asks of the config dialog, which sits above it and so can't be imported; the dialog fills it in as it starts.
pub const DialogHooks = struct {
    /// Draws a frame soon, for a change made outside one.
    redraw: *const fn () void,
    is_open: *const fn () bool,
    /// Returns whether the exit waits for the dialog to close, which then posts the quit itself.
    close_for_exit: *const fn () bool,
    /// The global settings as the dialog is editing them, else the saved ones.
    live_global: *const fn () *const config.GlobalConfig,
    /// Opens the dialog, or brings it forward, on `page`'s tab.
    open_at: *const fn (page: panel_host.SettingsPage) void,
};

/// What restartSubsystems' earlier steps hand to its later ones.
const Restart = struct {
    timer_hwnd: win32.HWND,
    /// The replacement store until install_profile takes it.
    pending: *?config.ProfileStore,
    global_draft: ?*config.GlobalConfig,
    /// Owned; restartSubsystems frees it.
    system_names: set.SystemNameSnapshot,
    /// Borrows Scout's windows, from rescan_windows on.
    eve_windows: []const scout_mod.EveWindow = &.{},
};

/// What main.zig loads from disk before building App.
pub const Loaded = struct {
    global_settings: config.GlobalConfig,
    character_ids: CharacterIds,
    store: config.ProfileStore,
};

/// main.zig starts its subsystems in dependency order, and deinit tears them down; main thread only.
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: config.ProfileStore,
    global_settings: config.GlobalConfig,
    character_ids: CharacterIds,
    /// Its WinEvent hooks find it once main.zig calls listenForEvents, after which App mustn't move.
    scout: scout_mod.Scout,
    /// Kept across a Save or profile switch.
    exclusions: exclusions_mod.Exclusions,
    /// Kept across a thumbnail set rebuild.
    notifications: center.NotificationCenter = .{},
    /// Kept across a thumbnail set rebuild.
    map_panel: map_panel_mod.MapPanel,
    instance: win32.HINSTANCE,
    /// Kept across a thumbnail set rebuild, and reset when another profile is loaded.
    auto_minimizer: auto_minimize.AutoMinimizer,
    focus: focus_mod.FocusTracker = .{},
    trackers: runtime.Trackers,
    /// Rebuilt on reload, so never cached elsewhere: read it from here each time.
    thumbnail_set: ?*ThumbnailSet = null,
    /// Built and torn down with `thumbnail_set`; non-null only while the view mode shows the client list.
    list_window: ?list_view.ListWindow = null,
    /// Rebuilt like `thumbnail_set`, and read from here the same way.
    hotkey_manager: ?*HotkeyManager = null,
    /// Rebuilt when a reload changes the log folders.
    chatlog_monitor: ?*chatlog.ChatlogMonitor = null,
    /// The hidden window whose WM_TIMER drives the tick; others post to it.
    timer_hwnd: ?win32.HWND = null,
    tray_icon: ?tray.TrayIcon = null,
    /// Null until the dialog has started.
    dialog: ?DialogHooks = null,
    pending_profile_buf: [PROFILE_NAME_BUFFER_SIZE]u8 = undefined,
    /// Borrows from pending_profile_buf.
    pending_profile: ?[]const u8 = null,
    last_forced_scan: win32.Ticks = .{},
    tick_interval_ms: win32.UINT = 0,
    last_travel_check: win32.Ticks = .{},

    /// Takes ownership of `loaded`, which deinit frees.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, instance: win32.HINSTANCE, loaded: Loaded) App {
        return .{
            .allocator = allocator,
            .io = io,
            .instance = instance,
            .store = loaded.store,
            .global_settings = loaded.global_settings,
            .character_ids = loaded.character_ids,
            .exclusions = .init(allocator),
            .auto_minimizer = .init(allocator),
            .trackers = .init(allocator, io),
            .scout = .init(allocator),
            .map_panel = .{ .host = PANEL_HOST },
        };
    }

    /// Each part goes before what it borrows; safe after a startup that failed partway, and only once background threads have finished.
    pub fn deinit(self: *App) void {
        if (self.timer_hwnd) |timer_hwnd| _ = win32.KillTimer(timer_hwnd, TICK_TIMER_ID);
        self.destroyHotkeyManager();
        if (self.tray_icon) |*icon| icon.deinit();
        self.tray_icon = null;
        // Before the timer window, which its hide timer runs on.
        self.focus.deinit(self.timer_hwnd);
        if (self.timer_hwnd) |timer_hwnd| _ = win32.DestroyWindow(timer_hwnd);
        self.timer_hwnd = null;
        // Before the trackers, which its worker thread writes to.
        self.destroyChatlogMonitor();
        self.trackers.deinit();
        self.destroyThumbnailSet();
        self.auto_minimizer.deinit();
        self.exclusions.deinit();
        self.scout.deinit();
        self.map_panel.deinit(self.allocator);
        self.notifications.deinit(self.allocator);
        self.store.deinit();
        self.character_ids.deinit();
        self.global_settings.deinit();
    }

    pub fn panelContext(self: *App) panel_host.Context {
        return .{ .allocator = self.allocator, .store = &self.store, .instance = self.instance };
    }

    /// Deferred to the next message-loop turn, since the switch would tear down the caller; copies `profile_name`.
    pub fn requestProfileSwitch(self: *App, profile_name: []const u8) void {
        if (profile_name.len > self.pending_profile_buf.len) {
            slog.err("Failed to switch to profile '{s}': name too long", .{profile_name});
            return;
        }
        const timer_hwnd = self.timer_hwnd orelse {
            slog.err("Failed to switch profile: the timer window isn't ready", .{});
            return;
        };
        @memcpy(self.pending_profile_buf[0..profile_name.len], profile_name);
        self.pending_profile = self.pending_profile_buf[0..profile_name.len];
        if (!win32.toBool(win32.PostMessageA(timer_hwnd, win32.WM_SWITCH_PROFILE, 0, 0))) {
            slog.err("Failed to switch to profile '{s}': the switch couldn't be queued", .{profile_name});
            self.pending_profile = null;
        }
    }

    pub fn runPendingProfileSwitch(self: *App) void {
        const pending = self.pending_profile orelse return;
        self.pending_profile = null;
        // Copied out, so a switch requested while this one runs can't overwrite the name in use.
        var name_buf: [PROFILE_NAME_BUFFER_SIZE]u8 = undefined;
        const name = name_buf[0..pending.len];
        @memcpy(name, pending);
        slog.info("Switching to profile: {s}", .{name});
        self.switchProfile(name);
    }

    pub fn switchProfile(self: *App, profile_name: []const u8) void {
        self.reloadWithProfile(profile_name) catch |err| {
            slog.err("Failed to switch to profile '{s}': {}", .{ profile_name, err });
        };
    }

    /// After a Save, restarts what reads settings only at setup; adopts `global_draft`, leaving it holding the replaced values.
    pub fn applySavedSettings(self: *App, global_draft: ?*config.GlobalConfig) !void {
        const timer_hwnd = self.timer_hwnd orelse return error.MissingTimerWindow;
        try self.restartSubsystems(timer_hwnd, null, global_draft);
    }

    /// After a dialog edit to the live profile.
    pub fn onLiveProfileEdited(self: *App, layout: LiveLayout) void {
        self.map_panel.sync(self.panelContext());
        self.notifications.sync(self.panelContext());
        const thumbnail_set = self.thumbnail_set orelse return;
        // A view mode builds different windows, so it needs a new thumbnail set rather than a restyle.
        if (thumbnail_set.view_mode != self.store.live.display.viewMode) {
            var system_names = self.teardownThumbnailSet();
            defer system_names.deinit();
            self.buildThumbnailSet(self.scout.getWindows(), &system_names) catch |err| {
                slog.err("Failed to rebuild thumbnails for view mode {s}: {}", .{ @tagName(self.store.live.display.viewMode), err });
                return;
            };
            slog.info("Rebuilt thumbnails for view mode {s}", .{@tagName(self.store.live.display.viewMode)});
            return;
        }
        if (self.list_window) |*list_window| list_window.sync();
        thumbnail_set.refreshAllThumbnailConfigCaches();
        // Moved before redrawing, so a re-shown thumbnail doesn't flash in its old place.
        switch (layout) {
            .none => {},
            .spaces => thumbnail_set.reflowIfSpacesActive(),
            .all => thumbnail_set.repositionAllThumbnails(),
        }
        thumbnail_set.refreshAllThumbnailVisuals();
    }

    pub fn tick(self: *App) void {
        log.flushConsole();
        const tick_start = win32.Ticks.now();
        const should_force_scan = schedule.nextTickWouldBeLate(tick_start.elapsedSince(self.last_forced_scan), FORCED_SCAN_INTERVAL_MS, self.tick_interval_ms);
        if (should_force_scan) self.last_forced_scan = tick_start;
        if (self.tray_icon) |*icon| icon.retryIfMissing(tick_start);

        var scout_result = self.scout.update(should_force_scan, self.store.saved.windowFilters.items);
        defer scout_result.deinit(self.allocator);
        self.clearLoggedOutExclusions(scout_result.name_changes.items);
        // The Characters tab marks who's logged in, which only a login, logout or closed client changes.
        if (scout_result.name_changes.items.len > 0 or scout_result.closed_windows.items.len > 0) {
            if (self.dialog) |dialog| dialog.redraw();
        }
        if (self.hotkey_manager) |manager| manager.syncFocusFilter(scout_result.windows);
        hook_bindings.logFailedPosts();

        if (self.thumbnail_set) |thumbnail_set| {
            thumbnail_set.updateConnections(&self.map_panel.pins, tick_start.ms);
            thumbnail_set.update(scout_result.windows, scout_result.closed_windows.items, scout_result.name_changes.items);
            if (self.list_window) |*list_window| {
                list_window.render(thumbnail_set.thumbnails.items, thumbnail_set.active_source_hwnd) catch |err| {
                    slog.err("Failed to render list window: {}", .{err});
                };
            }
            focus_mod.afterThumbnailSetUpdate(self, thumbnail_set, scout_result.name_changes.items);
            self.auto_minimizer.check(thumbnail_set.config, thumbnail_set.thumbnails.items, thumbnail_set.active_source_hwnd);

            thumbnail_set.updateNotifications();
            thumbnail_set.checkHoverZoom();
        }

        if (self.chatlog_monitor) |monitor| {
            monitor.update(&scout_result) catch |err| {
                slog.err("Failed to update Chatlog Monitor: {}", .{err});
            };
            var findings = monitor.drain();
            defer findings.deinit(self.allocator);
            self.deliverChatlogFindings(&findings);
        }
        // After the chatlog's alerts are delivered, so the panel lists them this tick.
        const presence = self.panelPresence();
        self.map_panel.update(self.allocator, self.io, &self.store.live, presence, self.thumbnail_set);
        self.notifications.update(&self.store.live, presence);

        self.trackers.tick(&self.store.live, scout_result.windows, tick_start, self.tick_interval_ms, self.thumbnail_set);

        if (self.thumbnail_set) |thumbnail_set| {
            if (schedule.isDue(tick_start.elapsedSince(self.last_travel_check), TRAVEL_CHECK_INTERVAL_MS, self.tick_interval_ms)) {
                self.last_travel_check = tick_start;
                travel_left_behind.check(thumbnail_set, &self.exclusions, tick_start);
            }
        }

        const wanted_interval = self.tickIntervalFor(scout_result.windows.len);
        if (wanted_interval != self.tick_interval_ms) {
            if (self.timer_hwnd) |timer_hwnd| {
                if (self.setTickInterval(timer_hwnd, wanted_interval)) slog.debug("Tick interval now {} ms", .{wanted_interval});
            }
        }
    }

    /// Writes what only teardown would, for an exit that skips it: Windows ending the session, or a background thread outlasting the wait at exit.
    pub fn saveBeforeAbruptExit(self: *const App) void {
        if (self.thumbnail_set) |thumbnail_set| thumbnail_set.auto_colors.flush();
        log.flush();
    }

    /// Temporary; not saved to the profile.
    fn toggleAutoMinimize(self: *App) void {
        const thumbnail_set = self.thumbnail_set orelse {
            slog.err("Failed to toggle auto-minimize: the thumbnail set isn't ready", .{});
            return;
        };
        const is_enabled = self.auto_minimizer.toggle(thumbnail_set.config);
        thumbnail_set.notifyAll(.{ .notification_type = .AutoMinimizeToggle, .state = if (is_enabled) .on else .off });
    }

    fn toggleDragging(self: *App) void {
        const is_enabled = !self.store.live.interaction.enableDragging;
        self.store.update(.{ .interaction = .{ .enableDragging = is_enabled } });
        slog.info("Thumbnail dragging toggled: {s}", .{if (is_enabled) "enabled" else "disabled"});
    }

    fn toggleTravelMode(self: *App) void {
        const is_enabled = !self.store.live.travel.enabled;
        self.store.update(.{ .travel = .{ .enabled = is_enabled } });
        slog.info("Travel Mode toggled: {s}", .{if (is_enabled) "enabled" else "disabled"});
    }

    fn toggleNotificationHistory(self: *App) void {
        self.notifications.panel.toggle(self.panelContext(), scout_mod.anyCharacterLoggedIn(self.scout.getWindows()));
    }

    fn toggleMapPanel(self: *App) void {
        self.map_panel.toggle(self.panelContext(), scout_mod.anyCharacterLoggedIn(self.scout.getWindows()));
    }

    fn toggleIntelPanel(self: *App) void {
        const presence = self.panelPresence();
        self.notifications.intel_panel.toggle(self.panelContext(), presence, self.map_panel.isVisible(&self.store.live, presence.any_character_logged_in));
    }

    pub fn isIntelPanelVisible(self: *const App) bool {
        const presence = self.panelPresence();
        return self.notifications.intel_panel.isVisible(&self.store.live, presence, self.map_panel.isVisible(&self.store.live, presence.any_character_logged_in));
    }

    fn panelPresence(self: *const App) panel_look.Presence {
        return .{ .any_character_logged_in = scout_mod.anyCharacterLoggedIn(self.scout.getWindows()), .is_eve_focused = self.isEveFocused() };
    }

    /// For the panels' auto-hide; our own windows count, so the config dialog doesn't hide a panel being edited.
    fn isEveFocused(self: *const App) bool {
        const foreground = win32.GetForegroundWindow() orelse return false;
        if (win32.isOwnProcessWindow(foreground)) return true;
        const thumbnail_set = self.thumbnail_set orelse return false;
        return thumbnail_set.hasThumbnail(foreground);
    }

    fn deliverChatlogFindings(self: *App, findings: *const chatlog.Findings) void {
        const thumbnail_set = self.thumbnail_set;
        const shown_count = findings.system_updates.items.len + findings.notifications.items.len;
        if (thumbnail_set == null and shown_count > 0) slog.warn("Failed to deliver {} chatlog event(s): the thumbnail set isn't ready", .{shown_count});

        if (thumbnail_set) |active_set| {
            for (findings.system_updates.items) |system_update| {
                const hwnd = self.scout.getHwndByName(system_update.character_name) orelse {
                    slog.debug("Dropped system update for '{s}': no window", .{system_update.character_name});
                    continue;
                };
                active_set.updateSystemNameByHwnd(hwnd, system_update.system_name, system_update.event_timestamp, system_update.is_jump) catch |err| {
                    slog.err("Failed to update system name for '{s}': {}", .{ system_update.character_name, err });
                };
            }
            for (findings.notifications.items) |event| {
                const hwnd = self.scout.getHwndByName(event.character_name) orelse {
                    slog.debug("Dropped {s} notification for '{s}': no window", .{ @tagName(event.notification.notification_type), event.character_name });
                    continue;
                };
                active_set.notify(hwnd, event.notification);
            }
        }

        const now_ms = win32.Ticks.now().ms;
        for (findings.intel_sightings.items) |sighting| {
            if (sighting.is_pinned) {
                if (!sighting.is_clear) {
                    self.map_panel.pins.add(sighting.system, sighting.message, now_ms);
                } else if (self.store.live.mapPanel.intelShowClear) {
                    self.map_panel.pins.markClear(sighting.system, sighting.message, self.store.live.mapPanel.intelShrinkMs(), now_ms);
                }
            }
            if (sighting.is_message_first) {
                if (self.thumbnail_set) |active_set| active_set.listIntel(sighting.system, sighting.message, sighting.is_clear);
            }
        }

        const now_seconds = std.Io.Timestamp.now(self.io, .real).toSeconds();
        for (findings.session_starts.items) |start| {
            const hwnd = self.scout.getHwndByName(start.character_name) orelse {
                slog.debug("Dropped session start for '{s}': no window", .{start.character_name});
                continue;
            };
            const logged_in_at = self.scout.backdateLogin(hwnd, start.started_at, now_seconds) orelse continue;
            // Without a thumbnail set nothing is lost: the next one takes the backdated time from Scout.
            if (thumbnail_set) |active_set| active_set.setSessionStart(hwnd, logged_in_at);
        }
    }

    fn clearLoggedOutExclusions(self: *const App, name_changes: []const scout_mod.NameChange) void {
        if (!self.store.live.exclusion.logoutClearsExclusion) return;
        const manager = self.hotkey_manager orelse return;
        for (name_changes) |change| {
            if (scout_mod.isGenericCharacterName(change.new_name) and !scout_mod.isGenericCharacterName(change.old_name)) {
                manager.clearLoggedOutExclusion(change.old_name);
            }
        }
    }

    pub fn tickIntervalFor(self: *const App, window_count: usize) win32.UINT {
        const is_dialog_open = if (self.dialog) |dialog| dialog.is_open() else false;
        if (window_count == 0 and !is_dialog_open) return IDLE_TICK_INTERVAL_MS;
        return self.store.saved.timer.scanIntervalMs;
    }

    /// Replaces the running timer in place; false on failure.
    pub fn setTickInterval(self: *App, timer_hwnd: win32.HWND, interval_ms: win32.UINT) bool {
        if (win32.SetTimer(timer_hwnd, TICK_TIMER_ID, interval_ms, null) == 0) return false;
        self.tick_interval_ms = interval_ms;
        return true;
    }

    pub fn createThumbnailSet(self: *App) !*ThumbnailSet {
        const new_set = try self.allocator.create(ThumbnailSet);
        errdefer self.allocator.destroy(new_set);
        new_set.* = try ThumbnailSet.init(self.allocator, &self.store, &self.exclusions, self.notifications.records(), .{
            .window_procedures = .{ .thumbnail = thumbnail_input.windowProc, .text = thumbnail_input.textWindowProc },
            .destroy_hook = thumbnail_input.windowDestroyProc,
        });
        self.thumbnail_set = new_set;
        if (new_set.view_mode.showsClientList()) self.createListWindow();
        return new_set;
    }

    fn createListWindow(self: *App) void {
        self.list_window = list_view.ListWindow.init(self.panelContext(), PANEL_HOST, .{
            .press = thumbnail_input.press,
            .release = thumbnail_input.release,
            .apply_hover_cursor = thumbnail_input.applyHoverCursor,
        }) catch |err| {
            slog.err("Failed to create list window: {}", .{err});
            return;
        };
        const list_window = &self.list_window.?;
        list_window.panel.attachOwner(list_window) catch |err| {
            slog.err("Failed to link the list window to its list: {}", .{err});
            list_window.deinit();
            self.list_window = null;
        };
    }

    fn destroyThumbnailSet(self: *App) void {
        if (self.list_window) |*list_window| {
            list_window.deinit();
            self.list_window = null;
        }
        const old_set = self.thumbnail_set orelse return;
        self.thumbnail_set = null;
        old_set.deinit();
        self.allocator.destroy(old_set);
    }

    /// The caller deinits the returned snapshot.
    fn teardownThumbnailSet(self: *App) set.SystemNameSnapshot {
        var system_names = set.SystemNameSnapshot.init(self.allocator);
        if (self.thumbnail_set) |old_set| system_names.capture(old_set);
        self.destroyThumbnailSet();
        return system_names;
    }

    fn buildThumbnailSet(self: *App, windows: []const scout_mod.EveWindow, system_names: *const set.SystemNameSnapshot) !void {
        const new_set = try self.createThumbnailSet();
        new_set.populate(windows, .{
            // Clients are already where the user put them; only startup and new arrivals auto-move.
            .should_move_to_saved = false,
            // Only while monitoring stays on, or a stale name would never update.
            .system_names = if (self.global_settings.chatlog.enabled) system_names else null,
        });
    }

    /// A hotkey registration failure is logged, not fatal.
    pub fn createHotkeyManager(self: *App, timer_hwnd: win32.HWND) !void {
        const dialog = self.dialog orelse return error.MissingDialogHooks;
        const manager = try self.allocator.create(HotkeyManager);
        errdefer self.allocator.destroy(manager);
        manager.* = try HotkeyManager.init(self.allocator, .{
            .store = &self.store,
            .global_settings = &self.global_settings,
            .live_global = dialog.live_global,
            .scout = &self.scout,
            .exclusions = &self.exclusions,
            .notified_queue = &self.notifications.notified_queue,
            .timer_hwnd = timer_hwnd,
        });
        self.hotkey_manager = manager;

        manager.registerHotkeys(timer_hwnd) catch |err| {
            slog.warn("Failed to register hotkeys, continuing without hotkey support: {}", .{err});
        };
        manager.syncFocusFilter(self.scout.getWindows());
    }

    /// What a hotkey or one of its actions left for App, run once the manager has returned.
    pub fn runHotkeyOutcome(self: *App, outcome: hotkeys.Outcome) void {
        switch (outcome) {
            .none => {},
            .activate => |hwnd| activation.activate(self, hwnd),
            .switch_profile => |profile_name| self.requestProfileSwitch(profile_name),
            .app => |command| switch (command) {
                .next_profile => self.cycleProfile(true),
                .previous_profile => self.cycleProfile(false),
                .toggle_auto_minimize => self.toggleAutoMinimize(),
                .toggle_dragging => self.toggleDragging(),
                .toggle_travel_mode => self.toggleTravelMode(),
                .toggle_notification_history => self.toggleNotificationHistory(),
                .clear_notification_history => self.notifications.clearHistories(),
                .toggle_map_panel => self.toggleMapPanel(),
                .toggle_intel_panel => self.toggleIntelPanel(),
                .return_to_last_app => launch.returnToLastApp(&self.focus.last_non_eve_foreground),
                .exit => requestExit(),
            },
        }
    }

    fn cycleProfile(self: *App, is_forward: bool) void {
        const target_profile = profile_switch.cycleTarget(self.allocator, self.io, self.store.saved.profile_name, is_forward) orelse return;
        defer self.allocator.free(target_profile);
        self.requestProfileSwitch(target_profile);
    }

    fn destroyHotkeyManager(self: *App) void {
        const manager = self.hotkey_manager orelse return;
        self.hotkey_manager = null;
        manager.deinit();
        self.allocator.destroy(manager);
    }

    /// Created with its worker thread stopped, so the trackers can be wired in before it runs.
    pub fn createChatlogMonitor(self: *App) !*chatlog.ChatlogMonitor {
        return chatlog.ChatlogMonitor.init(self.allocator, self.io, &self.global_settings.chatlog, &self.global_settings, &self.character_ids);
    }

    fn destroyChatlogMonitor(self: *App) void {
        const monitor = self.chatlog_monitor orelse return;
        self.chatlog_monitor = null;
        monitor.deinit();
        self.allocator.destroy(monitor);
    }

    /// Applies the new profile's window filters; a failed scan keeps the tracked windows.
    fn rescanWindows(self: *App) []const scout_mod.EveWindow {
        self.scout.scanForEveWindows(self.store.saved.windowFilters.items) catch |err| {
            slog.err("Failed to scan for EVE windows: {}", .{err});
        };
        self.scout.pruneNonMatchingWindows(self.store.saved.windowFilters.items);
        return self.scout.getWindows();
    }

    fn reloadWithProfile(self: *App, new_profile_name: []const u8) !void {
        slog.info("=== Starting profile reload: {s} ===", .{new_profile_name});

        const timer_hwnd = self.timer_hwnd orelse return error.MissingTimerWindow;

        const loaded = config.loadProfile(self.allocator, self.io, new_profile_name) catch |err| blk: {
            slog.err("Failed to load profile '{s}', reverting to the default: {}", .{ new_profile_name, err });
            break :blk config.loadProfile(self.allocator, self.io, config.DEFAULT_PROFILE) catch |fallback_err| {
                slog.err("Failed to load the default profile: {}", .{fallback_err});
                // Original profile-load error, not the fallback's.
                return err;
            };
        };
        // Built before anything is torn down, so a failure here leaves the running profile intact.
        const new_store = config.ProfileStore.init(loaded, self.io) catch |err| {
            slog.err("Failed to set up profile '{s}': {}", .{ new_profile_name, err });
            return err;
        };

        const profile_changed = !std.mem.eql(u8, self.store.live.profile_name, new_store.live.profile_name);
        // Before the restart, whose new thumbnail set records the focused client again.
        if (profile_changed) self.auto_minimizer.reset();
        try self.restartSubsystems(timer_hwnd, new_store, null);

        if (profile_changed) {
            if (self.thumbnail_set) |thumbnail_set| {
                thumbnail_set.notifyAll(.{ .notification_type = .ProfileSwitch, .target = config.profileDisplayName(self.store.live.profile_name) });
                if (self.global_settings.moveOnProfileSwitch) self.moveClientsToSavedPositions(thumbnail_set);
            }
        }

        slog.info("=== Profile reload complete: {s} ===", .{new_profile_name});
    }

    fn moveClientsToSavedPositions(self: *const App, thumbnail_set: *ThumbnailSet) void {
        for (self.scout.getWindows()) |eve_window| {
            if (eve_window.is_eve_client) thumbnail_set.auto_move.moveToSavedPosition(thumbnail_set.config, eve_window.hwnd, eve_window.character_name);
        }
    }

    /// Runs control/restart_plan.zig's steps; takes ownership of `replacement`, which becomes the running store.
    fn restartSubsystems(self: *App, timer_hwnd: win32.HWND, replacement: ?config.ProfileStore, global_draft: ?*config.GlobalConfig) !void {
        var pending = replacement;
        errdefer if (pending) |*store| store.deinit();
        // Shared by every profile, so a Save's global draft holds what comes next.
        const next_chatlog = if (global_draft) |draft| &draft.chatlog else &self.global_settings.chatlog;

        const plan: restart_plan.Plan = .init(.{
            .is_profile_replaced = pending != null,
            .has_thumbnail_set = self.thumbnail_set != null,
            .has_monitor = self.chatlog_monitor != null,
            .is_monitor_on_next_folders = if (self.chatlog_monitor) |monitor| monitor.runsWith(next_chatlog) else false,
            .is_chatlog_enabled_next = next_chatlog.enabled,
            .has_global_draft = global_draft != null,
        });
        if (!next_chatlog.enabled) slog.info("Chatlog monitoring disabled", .{});

        var restart: Restart = .{ .timer_hwnd = timer_hwnd, .pending = &pending, .global_draft = global_draft, .system_names = .init(self.allocator) };
        defer restart.system_names.deinit();

        for (plan.steps(), 0..) |step, index| {
            self.runRestartStep(step, &restart) catch |err| {
                const recovery = plan.recovery(index);
                for (recovery.steps()) |recovery_step| {
                    self.runRestartStep(recovery_step, &restart) catch |recovery_err| {
                        slog.err("Failed to recover from the failed reload ({s}): {}", .{ @tagName(recovery_step), recovery_err });
                    };
                }
                return err;
            };
        }
    }

    /// Logs its own failures.
    fn runRestartStep(self: *App, step: restart_plan.Step, restart: *Restart) !void {
        switch (step) {
            .pause_monitor => {
                const monitor = self.chatlog_monitor orelse return;
                monitor.stopWorkerThread();
                slog.debug("Paused chatlog monitor for reload (scan state preserved)", .{});
            },
            .destroy_monitor => {
                self.destroyChatlogMonitor();
                slog.debug("Cleaned up chatlog monitor", .{});
            },
            .adopt_global_draft => if (restart.global_draft) |draft| self.global_settings.adopt(draft),
            .destroy_hotkey_manager => {
                self.destroyHotkeyManager();
                slog.debug("Cleaned up hotkey manager", .{});
            },
            .teardown_thumbnail_set => {
                restart.system_names.deinit();
                restart.system_names = self.teardownThumbnailSet();
            },
            .install_profile => {
                const store = restart.pending.* orelse return;
                self.store.deinit();
                self.store = store;
                restart.pending.* = null;
                // Not dumped as at startup: it stalled switches with the debug console open.
                slog.info("Loaded new config: {s}", .{self.store.saved.profile_name});
                self.map_panel.sync(self.panelContext());
                self.notifications.sync(self.panelContext());
            },
            .record_last_used_profile => self.global_settings.updateLastUsed(self.io, self.store.saved.profile_name) catch |err| {
                slog.warn("Failed to update global settings: {}", .{err});
            },
            .rescan_windows => restart.eve_windows = self.rescanWindows(),
            .build_thumbnail_set => {
                self.buildThumbnailSet(restart.eve_windows, &restart.system_names) catch |err| {
                    slog.err("Failed to create thumbnail set: {}", .{err});
                    return err;
                };
                slog.debug("Recreated {} thumbnail(s)", .{restart.eve_windows.len});
            },
            .populate_thumbnail_set => if (self.thumbnail_set) |thumbnail_set| thumbnail_set.populate(restart.eve_windows, .{ .should_move_to_saved = false }),
            .clear_log_readings => if (self.thumbnail_set) |thumbnail_set| thumbnail_set.clearLogReadings(),
            .apply_monitor_settings => if (self.chatlog_monitor) |monitor| {
                monitor.applySettings(&self.global_settings.chatlog);
                slog.info("Kept chatlog monitoring without rescanning logs", .{});
            },
            .create_monitor => self.chatlog_monitor = self.createChatlogMonitor() catch |err| blk: {
                slog.err("Failed to initialize chatlog monitor: {}", .{err});
                break :blk null;
            },
            .setup_trackers => self.trackers.setup(&self.store.saved, self.chatlog_monitor),
            .start_monitor => if (self.chatlog_monitor) |monitor| startChatlogWorker(monitor),
            .add_monitor_characters => if (self.chatlog_monitor) |monitor| {
                addChatlogCharacters(monitor, restart.eve_windows);
                slog.info("Reinitialized chatlog monitoring", .{});
            },
            .create_hotkey_manager => {
                self.createHotkeyManager(restart.timer_hwnd) catch |err| {
                    slog.err("Failed to create hotkey manager: {}", .{err});
                    return err;
                };
                slog.debug("Reinitialized hotkey manager", .{});
            },
            .set_tick_interval => {
                const new_interval = self.tickIntervalFor(restart.eve_windows.len);
                if (!self.setTickInterval(restart.timer_hwnd, new_interval)) {
                    slog.warn("Failed to update the timer interval to {} ms, keeping {} ms", .{ new_interval, self.tick_interval_ms });
                    return;
                }
                slog.debug("Updated timer interval to {} ms", .{new_interval});
            },
        }
    }
};

/// For Win32 callbacks, which get no context of ours; null outside the run.
pub var g_app: ?*App = null;

/// For Win32 callbacks; null outside the run and while a rebuild failed.
pub fn currentThumbnailSet() ?*ThumbnailSet {
    const app = g_app orelse return null;
    return app.thumbnail_set;
}

/// Quits the message loop, after the configuration window has closed if it's open.
pub fn requestExit() void {
    if (g_app) |app| {
        if (app.dialog) |dialog| {
            if (dialog.close_for_exit()) return;
        }
    }
    win32.PostQuitMessage(0);
}

pub fn addChatlogCharacters(monitor: *chatlog.ChatlogMonitor, windows: []const scout_mod.EveWindow) void {
    for (windows) |eve_window| {
        if (!eve_window.is_eve_client) continue;
        monitor.addCharacter(eve_window.character_name) catch |err| {
            slog.err("Failed to add '{s}' to the chatlog monitor: {}", .{ eve_window.character_name, err });
        };
    }
}

pub fn startChatlogWorker(monitor: *chatlog.ChatlogMonitor) void {
    monitor.startWorkerThread() catch |err| {
        slog.warn("Failed to start chatlog worker thread: {}", .{err});
    };
}

/// For panel windows, which reach App only through PANEL_HOST.
fn runPanelRequest(request: panel_host.Request) void {
    const app = g_app orelse return;
    switch (request) {
        .activate => |hwnd| activation.activate(app, hwnd),
        .show_system => |system| app.map_panel.showSystem(system, app.thumbnail_set),
        .suspend_hotkeys => if (app.hotkey_manager) |manager| manager.typingSuspendHotkeys(),
        .resume_hotkeys => {
            const manager = app.hotkey_manager orelse return;
            const timer_hwnd = app.timer_hwnd orelse return;
            manager.typingResumeHotkeys(timer_hwnd);
        },
        .open_settings => |page| {
            const dialog = app.dialog orelse {
                slog.err("Failed to open the settings: the configuration window hasn't started", .{});
                return;
            };
            dialog.open_at(page);
        },
    }
}
