//! The running app: owns every long-lived subsystem, rebuilds them on a profile switch or Save, and runs each tick.
const std = @import("std");
const win32 = @import("platform/win32.zig");
const run_on_startup = @import("platform/run_on_startup.zig");
const config = @import("config.zig");
const scout_mod = @import("clients/scout.zig");
const roster_mod = @import("clients/roster.zig");
const auto_colors_mod = @import("clients/auto_colors.zig");
const exclusions_mod = @import("clients/exclusions.zig");
const auto_move_mod = @import("clients/auto_move.zig");
const actions = @import("clients/actions.zig");
const taskbar = @import("clients/taskbar.zig");
const activation = @import("control/activation.zig");
const auto_minimize = @import("control/auto_minimize.zig");
const focus_mod = @import("control/focus.zig");
const restart = @import("control/restart.zig");
const thumbnail_input = @import("control/thumbnail_input.zig");
const set = @import("thumbnail/set.zig");
const hotkeys = @import("hotkeys/manager.zig");
const commands_mod = @import("hotkeys/commands.zig");
const cycling = @import("hotkeys/cycling.zig");
const membership = @import("hotkeys/membership.zig");
const hook_bindings = @import("hotkeys/hook_bindings.zig");
const launch = @import("hotkeys/launch.zig");
const profile_switch = @import("hotkeys/profile_switch.zig");
const center = @import("notifications/center.zig");
const alert_effects = @import("notifications/alert_effects.zig");
const notifier_mod = @import("notifications/notifier.zig");
const intel_mod = @import("map/intel.zig");
const list_view = @import("panels/list_view.zig");
const map_panel_mod = @import("panels/map_panel.zig");
const panel_host = @import("panels/panel_host.zig");
const panel_look = @import("panels/panel_look.zig");
const chatlog = @import("chatlog.zig");
const character_ids_mod = @import("chatlog/character_ids.zig");
const runtime = @import("activity/runtime.zig");
const travel_left_behind = @import("travel/left_behind.zig");
const tray = @import("tray.zig");
const dialog_host = @import("dialog/dialog_host.zig");
const registry = @import("protocol/registry.zig");
const schedule = @import("util/schedule.zig");
const app_state = @import("diagnostics/app_state.zig");
const state_file = @import("diagnostics/state_file.zig");
const messages = @import("messages.zig");
const log = @import("log.zig");

const CharacterIds = character_ids_mod.CharacterIds;
const ThumbnailSet = set.ThumbnailSet;
const HotkeyManager = hotkeys.HotkeyManager;
const Recorders = app_state.Recorders;
const slog = log.Scoped("app");

/// Timed, not counted in ticks, so a slower scan interval doesn't stretch it.
const FORCED_SCAN_INTERVAL_MS: u64 = 1000;
/// With nothing to draw, the tick only keeps up with the forced scan.
const IDLE_TICK_INTERVAL_MS: win32.UINT = FORCED_SCAN_INTERVAL_MS;
const TRAVEL_CHECK_INTERVAL_MS: u64 = 2000;
const PROFILE_NAME_BUFFER_SIZE = 256;
/// What the panels ask of App, which they can't import.
pub const PANEL_HOST: panel_host.Host = .{
    .thumbnail_set = currentThumbnailSet,
    .roster = currentRoster,
    .exclusions = currentExclusions,
    .run = runPanelRequest,
};
/// What the configuration window asks of App, which it can't import.
pub const DIALOG_HOST: dialog_host.Host = .{
    .thumbnail_set = currentThumbnailSet,
    .notifier = currentNotifier,
    .timer_window = currentTimerWindow,
    .save = saveDialogSettings,
    .run = runDialogRequest,
};

/// What main.zig loads from disk before building App.
pub const Loaded = struct {
    global_settings: config.GlobalConfig,
    character_ids: CharacterIds,
    store: config.ProfileStore,
};

/// App's parts that outlive a thumbnail set rebuild, a Save and a profile switch.
pub const Persistent = struct {
    /// Synced from Scout each tick.
    roster: roster_mod.Roster,
    /// Unique system and character colours.
    auto_colors: auto_colors_mod.AutoColorStore,
    exclusions: exclusions_mod.Exclusions,
    /// So a client still loading through a profile switch is still corrected.
    auto_move: auto_move_mod.AutoMoveVerifier,
    notifications: center.NotificationCenter = .{},
    /// The pins and reports the Map Panel, Intel Panel and thumbnails show.
    intel: intel_mod.Intel = .{},
    map_panel: map_panel_mod.MapPanel,
    /// Reset when another profile is loaded.
    auto_minimizer: auto_minimize.AutoMinimizer,
};

/// App's parts control/restart.zig rebuilds, so never cached elsewhere: read them from here each time.
pub const Rebuilt = struct {
    thumbnail_set: ?*ThumbnailSet = null,
    /// Built and torn down with `thumbnail_set`; non-null only while the view mode shows the client list.
    list_window: ?list_view.ListWindow = null,
    hotkey_manager: ?*HotkeyManager = null,
    /// Rebuilt only when a reload changes the log folders.
    chatlog_monitor: ?*chatlog.ChatlogMonitor = null,
};

/// start brings its subsystems up and deinit tears them down; main thread only.
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: config.ProfileStore,
    global_settings: config.GlobalConfig,
    character_ids: CharacterIds,
    /// Its WinEvent hooks find it once start calls listenForEvents, after which App mustn't move.
    scout: scout_mod.Scout,
    persistent: Persistent,
    rebuilt: Rebuilt = .{},
    instance: win32.HINSTANCE,
    /// Each cycle command's position; reset whenever the hotkey manager is recreated, after a Save or profile switch.
    cycle: cycling.CycleState = .{},
    focus: focus_mod.FocusTracker = .{},
    trackers: runtime.Trackers,
    /// The hidden window whose WM_TIMER drives the tick; others post to it.
    timer_hwnd: ?win32.HWND = null,
    tray_icon: ?tray.TrayIcon = null,
    /// Null until the dialog has started.
    dialog: ?dialog_host.DialogHooks = null,
    pending_profile_buf: [PROFILE_NAME_BUFFER_SIZE]u8 = undefined,
    /// Borrows from pending_profile_buf.
    pending_profile: ?[]const u8 = null,
    last_forced_scan: win32.Ticks = .{},
    tick_interval_ms: win32.UINT = 0,
    last_travel_check: win32.Ticks = .{},
    /// The ThumbnailSet.placementHash the open dialog was last redrawn for.
    thumbnail_placement_hash: u64 = 0,
    /// What every client was last marked for the taskbar; null until the first tick and after Explorer restarts, which forgets the marks.
    taskbar_marks: ?bool = null,
    /// Null unless the end-to-end tests asked for it.
    state_report: ?state_file.StateFile = null,
    /// Owned; null unless state_report is set.
    recorders: ?*Recorders = null,

    /// Takes ownership of `loaded`, which deinit frees.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, instance: win32.HINSTANCE, loaded: Loaded) App {
        return .{
            .allocator = allocator,
            .io = io,
            .instance = instance,
            .store = loaded.store,
            .global_settings = loaded.global_settings,
            .character_ids = loaded.character_ids,
            .persistent = .{
                .roster = .init(allocator),
                .auto_colors = .init(allocator, io),
                .exclusions = .init(allocator),
                .auto_move = .init(allocator),
                .map_panel = .{ .host = PANEL_HOST },
                .auto_minimizer = .init(allocator),
            },
            .trackers = .init(allocator, io),
            .scout = .init(allocator),
            .state_report = .init(if (config.environMap()) |environ_map| environ_map.get(state_file.ENVIRONMENT_VARIABLE) else null),
        };
    }

    /// Everything main.zig doesn't set up itself, built by the restart plan from nothing running; once, before the message loop.
    pub fn start(self: *App, timer_hwnd: win32.HWND) !void {
        self.timer_hwnd = timer_hwnd;
        self.store.live.logSettings();
        if (self.state_report != null) self.startRecorders();
        self.persistent.notifications.start(self.panelContext(), PANEL_HOST, &self.persistent.intel.history);
        self.persistent.map_panel.start(self.panelContext(), &self.persistent.intel, &self.global_settings);
        self.scout.listenForEvents();
        self.focus.start();
        self.tray_icon = try tray.TrayIcon.init(self.allocator, timer_hwnd);
        try restart.run(self, timer_hwnd, null, null);
        if (self.rebuilt.chatlog_monitor) |monitor| {
            for (self.store.live.characters.items) |character_config| {
                monitor.resolveCharacterId(character_config.name) catch |err| {
                    slog.warn("Failed to queue ID backfill for '{s}': {}", .{ character_config.name, err });
                };
            }
        }
        // Only the tick's syncs move and minimize clients that joined, so these, already running, stay put unless asked.
        if (self.store.live.autoMovePosition.moveOnStartup) self.moveClientsToSavedPositions();
    }

    /// Safe after a startup that failed partway, but only once background threads have finished.
    pub fn deinit(self: *App) void {
        // Each part goes before what it borrows.
        if (self.timer_hwnd) |timer_hwnd| _ = win32.KillTimer(timer_hwnd, messages.TICK_TIMER_ID);
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
        self.persistent.auto_minimizer.deinit();
        self.cycle.deinit(self.allocator);
        self.persistent.auto_move.deinit();
        self.persistent.exclusions.deinit();
        self.persistent.auto_colors.deinit();
        // Explorer would otherwise keep hiding the taskbar behind clients after the app has gone.
        if (self.taskbar_marks == true) taskbar.markClients(self.persistent.roster.clients.items, .all, false);
        self.persistent.roster.deinit();
        self.scout.deinit();
        self.persistent.map_panel.deinit(self.allocator);
        self.persistent.notifications.deinit(self.allocator);
        self.store.deinit();
        self.character_ids.deinit();
        self.global_settings.deinit();
        if (self.state_report) |*report| report.deinit(self.allocator);
        self.stopRecorders();
    }

    fn startRecorders(self: *App) void {
        self.recorders = Recorders.create(self.allocator) catch |err| {
            slog.warn("Failed to start recording renders for the state file: {}", .{err});
            return;
        };
    }

    fn stopRecorders(self: *App) void {
        const recorders = self.recorders orelse return;
        self.recorders = null;
        recorders.destroy(self.allocator);
    }

    /// Shows alerts on the roster's clients, with or without a thumbnail set.
    pub fn notifier(self: *App) notifier_mod.Notifier {
        return .{
            .allocator = self.allocator,
            .config = &self.store.live,
            .auto_colors = &self.persistent.auto_colors,
            .records = self.persistent.notifications.records(),
            .roster = &self.persistent.roster,
            .intel = &self.persistent.intel,
        };
    }

    /// What every user command, from a hotkey, the tray or a protocol link, runs through; needs no hotkey manager.
    pub fn commands(self: *App) commands_mod.Commands {
        return .{
            .allocator = self.allocator,
            .config = &self.store.saved,
            .store = &self.store,
            .global_settings = &self.global_settings,
            .live_global = if (self.dialog) |dialog| dialog.live_global() else &self.global_settings,
            .scout = &self.scout,
            .exclusions = &self.persistent.exclusions,
            .notified_queue = &self.persistent.notifications.notified_queue,
            .notifier = self.notifier(),
            .roster = &self.persistent.roster,
            .cycle = &self.cycle,
        };
    }

    /// After a client was focused by hand: every cycle continues from it.
    pub fn syncCyclesToFocused(self: *App, character_name: []const u8, hwnd: win32.HWND) void {
        if (!cycling.syncToFocusedCharacter(&self.commands(), character_name, hwnd)) return;
        if (self.rebuilt.hotkey_manager) |manager| manager.syncCharacterCursors(character_name);
    }

    pub fn panelContext(self: *App) panel_host.Context {
        return .{ .allocator = self.allocator, .store = &self.store, .auto_colors = &self.persistent.auto_colors, .instance = self.instance };
    }

    pub fn dialogContext(self: *App) dialog_host.Context {
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .store = &self.store,
            .global_settings = &self.global_settings,
            .scout = &self.scout,
            .character_ids = &self.character_ids,
        };
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
        if (!win32.toBool(win32.PostMessageA(timer_hwnd, messages.WM_SWITCH_PROFILE, 0, 0))) {
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

    /// The configuration window's Save; see dialog_host.Host.save.
    fn saveSettings(self: *App, save: dialog_host.Save) !void {
        if (save.is_profile_dirty) try self.store.commit();
        if (!save.is_profile_dirty and save.global_draft == null) return;
        const timer_hwnd = self.timer_hwnd orelse return error.MissingTimerWindow;
        // Adopting swaps in the replaced values, which a restart failing after it would otherwise leave in the window's draft.
        var draft_copy: ?config.GlobalConfig = if (save.global_draft) |draft| try draft.clone(self.allocator) else null;
        defer if (draft_copy) |*copy| copy.deinit();
        try restart.run(self, timer_hwnd, null, if (draft_copy) |*copy| copy else null);
        if (save.global_draft == null) return;

        try self.global_settings.save(self.io);
        applyGlobalSettings(&self.global_settings);
    }

    /// After a dialog edit to the live profile.
    fn onLiveProfileEdited(self: *App, layout: dialog_host.LiveLayout) void {
        self.persistent.roster.refreshConfig(&self.store.live, &self.persistent.auto_colors, .all);
        self.persistent.map_panel.sync(self.panelContext());
        self.persistent.notifications.sync(self.panelContext());
        const thumbnail_set = self.rebuilt.thumbnail_set orelse return;
        // A view mode builds different windows, so it needs a new thumbnail set rather than a restyle.
        if (thumbnail_set.view_mode != self.store.live.display.viewMode) {
            self.destroyThumbnailSet();
            self.buildThumbnailSet(self.scout.getWindows()) catch |err| {
                slog.err("Failed to rebuild thumbnails for view mode {s}: {}", .{ @tagName(self.store.live.display.viewMode), err });
                return;
            };
            slog.info("Rebuilt thumbnails for view mode {s}", .{@tagName(self.store.live.display.viewMode)});
            return;
        }
        if (self.rebuilt.list_window) |*list_window| list_window.sync();
        thumbnail_set.refreshAllThumbnailConfigCaches();
        // Moved before redrawing, so a re-shown thumbnail doesn't flash in its old place.
        switch (layout) {
            .none => {},
            .spaces => thumbnail_set.reflowIfSpacesActive(),
            .all => thumbnail_set.repositionAllThumbnails(),
        }
        thumbnail_set.refreshAllThumbnailVisuals();
        if (self.rebuilt.list_window) |*list_window| list_window.redraw();
    }

    pub fn tick(self: *App) void {
        log.flushConsole();
        const tick_start = win32.Ticks.now();
        const should_force_scan = schedule.nextTickWouldBeLate(tick_start.elapsedSince(self.last_forced_scan), FORCED_SCAN_INTERVAL_MS, self.tick_interval_ms);
        if (should_force_scan) self.last_forced_scan = tick_start;
        if (self.tray_icon) |*icon| icon.retryIfMissing(tick_start);
        // Checked each tick rather than on Save, so an alert still playing then can finish first.
        if (should_force_scan) alert_effects.releaseUnused(&self.store.live);

        var scout_result = self.scout.update(should_force_scan, self.store.saved.windowFilters.items);
        defer scout_result.deinit(self.allocator);
        self.discoverWindows(&scout_result);
        self.updateThumbnails(&scout_result, tick_start);
        self.ingestLogs(&scout_result);
        self.updatePanels(scout_result.windows, tick_start);
        self.scheduleNextTick(scout_result.windows.len);
        self.publishState();
    }

    /// First, since every later phase reads the roster it syncs.
    fn discoverWindows(self: *App, scout_result: *const scout_mod.UpdateResult) void {
        self.syncRoster(scout_result.windows);
        self.followNewClients();
        self.syncTaskbarMarks();
        if (self.persistent.roster.clients.items.len == 0) self.persistent.auto_colors.flush();
        self.clearLoggedOutExclusions(scout_result.name_changes.items);
        // The Characters tab marks who's logged in, which only a login, logout or closed client changes.
        if (scout_result.name_changes.items.len > 0 or scout_result.closed_windows.items.len > 0) {
            if (self.dialog) |dialog| dialog.redraw();
        }
        if (self.rebuilt.hotkey_manager) |manager| manager.syncFocusFilter(scout_result.windows);
        hook_bindings.logFailedPosts();
        focus_mod.afterActiveRefresh(self, scout_result.name_changes.items);
    }

    /// After discoverWindows; the thumbnails, the client list and auto-minimize.
    fn updateThumbnails(self: *App, scout_result: *const scout_mod.UpdateResult, tick_start: win32.Ticks) void {
        self.persistent.roster.expireAlerts(win32.Ticks.now());
        const dragged_hwnd = if (self.rebuilt.thumbnail_set) |thumbnail_set| thumbnail_set.draggedSourceHwnd() else null;
        self.persistent.roster.refreshMinimized(dragged_hwnd);
        if (self.rebuilt.thumbnail_set) |thumbnail_set| {
            thumbnail_set.updateConnections(&self.persistent.intel.pins, tick_start.ms);
            thumbnail_set.update(scout_result.windows, scout_result.closed_windows.items, scout_result.name_changes.items);
            thumbnail_set.checkHoverZoom();
            self.redrawDialogIfThumbnailsMoved(thumbnail_set);
        }
        if (self.rebuilt.list_window) |*list_window| {
            list_window.render(&self.persistent.roster, list_view.viewOf(self.rebuilt.thumbnail_set)) catch |err| {
                slog.err("Failed to render list window: {}", .{err});
            };
        }
        self.persistent.auto_minimizer.check(&self.store.live, self.persistent.roster.clients.items, self.persistent.roster.active_hwnd, dragged_hwnd);
    }

    /// Delivers what the chatlog worker found since the last tick.
    fn ingestLogs(self: *App, scout_result: *const scout_mod.UpdateResult) void {
        const monitor = self.rebuilt.chatlog_monitor orelse return;
        monitor.update(scout_result) catch |err| {
            slog.err("Failed to update Chatlog Monitor: {}", .{err});
        };
        var findings = monitor.drain();
        defer findings.deinit(self.allocator);
        self.deliverChatlogFindings(&findings);
    }

    /// After ingestLogs, so the panels list its alerts this tick; also the trackers and Travel Mode.
    fn updatePanels(self: *App, windows: []const scout_mod.EveWindow, tick_start: win32.Ticks) void {
        const presence = self.panelPresence();
        self.persistent.map_panel.update(self.allocator, self.io, &self.store.live, presence);
        self.persistent.notifications.update(&self.store.live, presence, &self.persistent.intel.history);

        self.trackers.tick(&self.store.live, windows, tick_start, self.tick_interval_ms, self.rebuilt.thumbnail_set, &self.notifier());

        if (schedule.isDue(tick_start.elapsedSince(self.last_travel_check), TRAVEL_CHECK_INTERVAL_MS, self.tick_interval_ms)) {
            self.last_travel_check = tick_start;
            travel_left_behind.check(&self.notifier(), &self.persistent.exclusions, tick_start);
        }
    }

    /// Last before publishing, since the trackers read the interval this tick ran at.
    fn scheduleNextTick(self: *App, window_count: usize) void {
        const wanted_interval = self.tickIntervalFor(window_count);
        if (wanted_interval == self.tick_interval_ms) return;
        const timer_hwnd = self.timer_hwnd orelse return;
        if (self.setTickInterval(timer_hwnd, wanted_interval)) {
            slog.debug("Tick interval now {} ms", .{wanted_interval});
        } else {
            slog.warn("Failed to update the timer interval to {} ms, keeping {} ms", .{ wanted_interval, self.tick_interval_ms });
        }
    }

    fn publishState(self: *App) void {
        const report = if (self.state_report) |*report| report else return;
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const snapshot = app_state.capture(arena_state.allocator(), self.stateSources()) catch |err| {
            slog.warn("Failed to gather the app state: {}", .{err});
            return;
        };
        report.publish(self.allocator, self.io, snapshot);
    }

    /// Borrows from App, so publish it before App changes.
    fn stateSources(self: *const App) app_state.Sources {
        return .{
            .profile_name = self.store.live.profile_name,
            .active_hwnd = self.persistent.roster.active_hwnd,
            .are_hotkeys_suspended = if (self.rebuilt.hotkey_manager) |manager| manager.are_hotkeys_suspended else false,
            .excluded_characters = self.persistent.exclusions.names.items,
            .hotkey_groups = self.store.live.hotkeyGroups.items,
            .thumbnails = if (self.rebuilt.thumbnail_set) |thumbnail_set| thumbnail_set.thumbnails.items else &.{},
            .clients = self.persistent.roster.clients.items,
            .history = &self.persistent.notifications.history,
            .intel_history = &self.persistent.intel.history,
            .panel_hwnds = .init(.{
                .client_list = if (self.rebuilt.list_window) |*window| window.panel.hwnd else null,
                .history = if (self.persistent.notifications.panel.window) |*window| window.panel.hwnd else null,
                .intel = if (self.persistent.notifications.intel_panel.window) |*window| window.panel.hwnd else null,
                .map = if (self.persistent.map_panel.window) |*window| window.panel.hwnd else null,
            }),
            .recorders = self.recorders,
        };
    }

    /// Writes what only teardown would, for an exit that skips it: Windows ending the session, or a background thread outlasting the wait at exit.
    pub fn saveBeforeAbruptExit(self: *App) void {
        self.persistent.auto_colors.flush();
        log.flush();
    }

    /// Temporary; not saved to the profile.
    fn toggleAutoMinimize(self: *App) void {
        const is_enabled = self.persistent.auto_minimizer.toggle(&self.store.live);
        self.notifier().notifyAll(.{ .notification_type = .AutoMinimizeToggle, .state = if (is_enabled) .on else .off });
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
        self.persistent.notifications.panel.toggle(self.panelContext(), scout_mod.anyCharacterLoggedIn(self.scout.getWindows()));
    }

    fn toggleMapPanel(self: *App) void {
        self.persistent.map_panel.toggle(self.panelContext(), scout_mod.anyCharacterLoggedIn(self.scout.getWindows()));
    }

    fn toggleIntelPanel(self: *App) void {
        const presence = self.panelPresence();
        self.persistent.notifications.intel_panel.toggle(self.panelContext(), presence, self.persistent.map_panel.isVisible(&self.store.live, presence.any_character_logged_in));
    }

    pub fn isIntelPanelVisible(self: *const App) bool {
        const presence = self.panelPresence();
        return self.persistent.notifications.intel_panel.isVisible(&self.store.live, presence, self.persistent.map_panel.isVisible(&self.store.live, presence.any_character_logged_in));
    }

    fn panelPresence(self: *const App) panel_look.Presence {
        return .{ .any_character_logged_in = scout_mod.anyCharacterLoggedIn(self.scout.getWindows()), .is_eve_focused = self.isEveFocused() };
    }

    /// For the panels' auto-hide; our own windows count, so the config dialog doesn't hide a panel being edited.
    fn isEveFocused(self: *const App) bool {
        const foreground = win32.GetForegroundWindow() orelse return false;
        if (win32.isOwnProcessWindow(foreground)) return true;
        return self.persistent.roster.contains(foreground);
    }

    fn deliverChatlogFindings(self: *App, findings: *const chatlog.Findings) void {
        const now_ms = win32.Ticks.now().ms;
        for (findings.system_updates.items) |system_update| {
            const client = self.persistent.roster.byName(system_update.character_name) orelse {
                slog.debug("Dropped system update for '{s}': no window", .{system_update.character_name});
                continue;
            };
            self.persistent.roster.updateSystem(client.hwnd, system_update.system_name, system_update.event_timestamp, if (system_update.is_jump) now_ms else null) catch |err| {
                slog.err("Failed to update system name for '{s}': {}", .{ system_update.character_name, err });
            };
        }

        for (findings.notifications.items) |event| {
            const client = self.persistent.roster.byName(event.character_name) orelse {
                slog.debug("Dropped {s} notification for '{s}': no window", .{ @tagName(event.notification.notification_type), event.character_name });
                continue;
            };
            self.notifier().notify(client.hwnd, event.notification);
        }

        for (findings.intel_sightings.items) |sighting| {
            if (sighting.is_pinned) {
                const intel_settings = &self.store.live.intel;
                self.persistent.intel.pin(sighting.system, sighting.message, sighting.is_clear, .{
                    .shows_clear = intel_settings.showClear,
                    .lifetime_ms = intel_settings.shrinkMs(),
                }, now_ms);
            }
            if (sighting.is_message_first) {
                self.notifier().listIntel(sighting.system, sighting.message, sighting.is_clear);
            }
        }

        const now_seconds = std.Io.Timestamp.now(self.io, .real).toSeconds();
        for (findings.session_starts.items) |session_start| {
            const hwnd = self.scout.getHwndByName(session_start.character_name) orelse {
                slog.debug("Dropped session start for '{s}': no window", .{session_start.character_name});
                continue;
            };
            // The roster takes the backdated time from Scout on its next sync.
            _ = self.scout.backdateLogin(hwnd, session_start.started_at, now_seconds);
        }
    }

    fn clearLoggedOutExclusions(self: *App, name_changes: []const scout_mod.NameChange) void {
        if (!self.store.live.exclusion.logoutClearsExclusion) return;
        for (name_changes) |change| {
            if (scout_mod.isGenericCharacterName(change.new_name) and !scout_mod.isGenericCharacterName(change.old_name)) {
                membership.clearLoggedOutExclusion(&self.commands(), change.old_name);
            }
        }
    }

    /// The Placement tab's map shows where thumbnails are, which the dialog doesn't see change.
    fn redrawDialogIfThumbnailsMoved(self: *App, thumbnail_set: *const ThumbnailSet) void {
        const dialog = self.dialog orelse return;
        if (!dialog.is_open()) return;
        const hash = thumbnail_set.placementHash();
        if (hash == self.thumbnail_placement_hash) return;
        self.thumbnail_placement_hash = hash;
        dialog.redraw();
    }

    pub fn tickIntervalFor(self: *const App, window_count: usize) win32.UINT {
        const is_dialog_open = if (self.dialog) |dialog| dialog.is_open() else false;
        // Never idle under the end-to-end tests, which wait on the state file only a tick writes.
        if (window_count == 0 and !is_dialog_open and self.state_report == null) return IDLE_TICK_INTERVAL_MS;
        return self.store.saved.timer.scanIntervalMs;
    }

    /// Mirrors `windows` into the roster, and takes the foreground window as its active one.
    pub fn syncRoster(self: *App, windows: []const scout_mod.EveWindow) void {
        self.persistent.roster.sync(windows);
        self.persistent.roster.refreshConfig(&self.store.live, &self.persistent.auto_colors, .stale);
        self.persistent.roster.setActive(win32.GetForegroundWindow());
    }

    /// Replaces the running timer in place; false on failure.
    pub fn setTickInterval(self: *App, timer_hwnd: win32.HWND, interval_ms: win32.UINT) bool {
        if (win32.SetTimer(timer_hwnd, messages.TICK_TIMER_ID, interval_ms, null) == 0) return false;
        self.tick_interval_ms = interval_ms;
        return true;
    }

    fn createThumbnailSet(self: *App) !*ThumbnailSet {
        const new_set = try self.allocator.create(ThumbnailSet);
        errdefer self.allocator.destroy(new_set);
        new_set.* = try ThumbnailSet.init(self.allocator, .{
            .store = &self.store,
            .exclusions = &self.persistent.exclusions,
            .auto_colors = &self.persistent.auto_colors,
            .roster = &self.persistent.roster,
        }, .{
            .window_procedures = .{ .thumbnail = thumbnail_input.windowProc, .text = thumbnail_input.textWindowProc },
            .destroy_hook = thumbnail_input.windowDestroyProc,
        });
        self.rebuilt.thumbnail_set = new_set;
        if (new_set.view_mode.showsClientList()) self.createListWindow();
        return new_set;
    }

    fn createListWindow(self: *App) void {
        self.rebuilt.list_window = list_view.ListWindow.init(self.panelContext(), PANEL_HOST, .{
            .press = thumbnail_input.press,
            .release = thumbnail_input.release,
            .apply_hover_cursor = thumbnail_input.applyHoverCursor,
        }) catch |err| {
            slog.err("Failed to create list window: {}", .{err});
            return;
        };
        const list_window = &self.rebuilt.list_window.?;
        list_window.panel.attachOwner(list_window) catch |err| {
            slog.err("Failed to link the list window to its list: {}", .{err});
            list_window.deinit();
            self.rebuilt.list_window = null;
        };
    }

    pub fn destroyThumbnailSet(self: *App) void {
        if (self.rebuilt.list_window) |*list_window| {
            list_window.deinit();
            self.rebuilt.list_window = null;
        }
        const old_set = self.rebuilt.thumbnail_set orelse return;
        self.rebuilt.thumbnail_set = null;
        old_set.deinit();
        self.allocator.destroy(old_set);
    }

    pub fn buildThumbnailSet(self: *App, windows: []const scout_mod.EveWindow) !void {
        const new_set = try self.createThumbnailSet();
        new_set.populate(windows);
    }

    /// What a command left for App, run once it has returned.
    pub fn runHotkeyOutcome(self: *App, outcome: commands_mod.Outcome) void {
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
                .clear_notification_history => self.clearNotificationHistories(),
                .toggle_map_panel => self.toggleMapPanel(),
                .toggle_intel_panel => self.toggleIntelPanel(),
                .return_to_last_app => launch.returnToLastApp(&self.focus.last_non_eve_foreground),
                .suspend_hotkeys => {
                    const manager = self.rebuilt.hotkey_manager orelse {
                        slog.warn("Failed to suspend or resume hotkeys: the hotkey manager is being rebuilt", .{});
                        return;
                    };
                    manager.toggleSuspend();
                },
                .exit => requestExit(),
            },
        }
    }

    /// The History Panel's list and the Intel Panel's.
    fn clearNotificationHistories(self: *App) void {
        self.persistent.notifications.history.clear();
        self.persistent.intel.history.clear();
    }

    fn cycleProfile(self: *App, is_forward: bool) void {
        const target_profile = profile_switch.cycleTarget(self.allocator, self.io, self.store.saved.profile_name, is_forward) orelse return;
        defer self.allocator.free(target_profile);
        self.requestProfileSwitch(target_profile);
    }

    pub fn destroyHotkeyManager(self: *App) void {
        const manager = self.rebuilt.hotkey_manager orelse return;
        self.rebuilt.hotkey_manager = null;
        manager.deinit();
        self.allocator.destroy(manager);
    }

    pub fn destroyChatlogMonitor(self: *App) void {
        const monitor = self.rebuilt.chatlog_monitor orelse return;
        self.rebuilt.chatlog_monitor = null;
        monitor.deinit();
        self.allocator.destroy(monitor);
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
        if (profile_changed) self.persistent.auto_minimizer.reset();
        try restart.run(self, timer_hwnd, new_store, null);

        if (profile_changed) {
            self.notifier().notifyAll(.{ .notification_type = .ProfileSwitch, .target = config.profileDisplayName(self.store.live.profile_name) });
            if (self.global_settings.moveOnProfileSwitch) self.moveClientsToSavedPositions();
        }

        slog.info("=== Profile reload complete: {s} ===", .{new_profile_name});
    }

    /// Every EVE client to its saved window position, as on startup or a profile switch when the settings ask.
    fn moveClientsToSavedPositions(self: *App) void {
        for (self.scout.getWindows()) |eve_window| {
            if (eve_window.is_eve_client) self.persistent.auto_move.moveToSavedPosition(&self.store.live, eve_window.hwnd, eve_window.character_name);
        }
    }

    /// After the tick's sync: moves clients that joined or logged in to their saved positions, and starts new ones minimized, as the profile asks.
    fn followNewClients(self: *App) void {
        const live = &self.store.live;
        for (self.persistent.roster.clients.items) |*client| {
            if (!client.is_eve_client) continue;
            switch (client.last_sync) {
                .none => {},
                .joined => {
                    if (live.autoMovePosition.enabled) self.persistent.auto_move.moveToSavedPosition(live, client.hwnd, client.character_name);
                    if (live.autoMinimize.startMinimized) actions.minimizeNewClient(live, client.hwnd);
                },
                .logged_in => if (live.autoMovePosition.enabled) self.persistent.auto_move.moveToSavedPosition(live, client.hwnd, client.character_name),
            }
        }
        self.persistent.auto_move.verify(live);
    }

    /// After the tick's sync: marks every client when the setting changed or Explorer restarted, else only those that joined.
    fn syncTaskbarMarks(self: *App) void {
        const should_hide = self.store.live.interaction.hideTaskbarOverClients;
        if (self.taskbar_marks == should_hide) {
            if (should_hide) taskbar.markClients(self.persistent.roster.clients.items, .joined, true);
            return;
        }
        // With nothing marked yet, unmarking would have nothing to undo.
        if (self.taskbar_marks != null or should_hide) taskbar.markClients(self.persistent.roster.clients.items, .all, should_hide);
        self.taskbar_marks = should_hide;
    }
};

/// For Win32 callbacks, which get no context of ours; null outside the run.
pub var g_app: ?*App = null;

/// For Win32 callbacks; null outside the run and while a rebuild failed.
pub fn currentThumbnailSet() ?*ThumbnailSet {
    const app = g_app orelse return null;
    return app.rebuilt.thumbnail_set;
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

/// The settings that reach outside the app: the log, the Run key and the protocol handler.
pub fn applyGlobalSettings(settings: *const config.GlobalConfig) void {
    log.setLevel(settings.logLevel);
    if (settings.logLevel == .debug) log.openDebugConsole() else log.closeDebugConsole();
    // Every launch too, since the Run value can be lost or point at a moved exe while the setting stays on.
    run_on_startup.apply(settings.runOnStartup);
    if (settings.autoRegisterProtocol) registry.ensureRegistered();
}

/// For the panels; null outside the run.
fn currentRoster() ?*const roster_mod.Roster {
    const app = g_app orelse return null;
    return &app.persistent.roster;
}

/// For the configuration window's alert tests; null outside the run.
fn currentNotifier() ?notifier_mod.Notifier {
    const app = g_app orelse return null;
    return app.notifier();
}

/// For the panels; null outside the run.
fn currentExclusions() ?*const exclusions_mod.Exclusions {
    const app = g_app orelse return null;
    return &app.persistent.exclusions;
}

fn currentTimerWindow() ?win32.HWND {
    const app = g_app orelse return null;
    return app.timer_hwnd;
}

fn saveDialogSettings(save: dialog_host.Save) !void {
    const app = g_app orelse return error.MissingApp;
    try app.saveSettings(save);
}

/// For the configuration window, which reaches App only through DIALOG_HOST.
fn runDialogRequest(request: dialog_host.Request) void {
    const app = g_app orelse return;
    switch (request) {
        .live_profile_edited => |layout| app.onLiveProfileEdited(layout),
        .switch_profile => |profile_name| app.switchProfile(profile_name),
        .suspend_hotkeys_for_recording => if (app.rebuilt.hotkey_manager) |manager| manager.dialogSuspendHotkeys(),
        .resume_hotkeys_for_recording => {
            const manager = app.rebuilt.hotkey_manager orelse return;
            const timer_hwnd = app.timer_hwnd orelse return;
            manager.dialogResumeHotkeys(timer_hwnd);
        },
    }
}

/// For panel windows, which reach App only through PANEL_HOST.
fn runPanelRequest(request: panel_host.Request) void {
    const app = g_app orelse return;
    switch (request) {
        .activate => |hwnd| activation.activate(app, hwnd),
        .show_system => |system| app.persistent.map_panel.showSystem(system),
        .suspend_hotkeys => if (app.rebuilt.hotkey_manager) |manager| manager.typingSuspendHotkeys(),
        .resume_hotkeys => {
            const manager = app.rebuilt.hotkey_manager orelse return;
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
