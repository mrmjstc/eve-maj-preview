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
const activation = @import("control/activation.zig");
const auto_minimize = @import("control/auto_minimize.zig");
const focus_mod = @import("control/focus.zig");
const restart_plan = @import("control/restart_plan.zig");
const thumbnail_input = @import("control/thumbnail_input.zig");
const set = @import("thumbnail/set.zig");
const overlay = @import("thumbnail/overlay.zig");
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
const history = @import("notifications/history.zig");
const intel_mod = @import("map/intel.zig");
const list_view = @import("panels/list_view.zig");
const map_panel_mod = @import("panels/map_panel.zig");
const panel_chrome = @import("panels/panel_chrome.zig");
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
const state_file = @import("diagnostics/state_file.zig");
const messages = @import("messages.zig");
const log = @import("log.zig");

const CharacterIds = character_ids_mod.CharacterIds;
const ThumbnailSet = set.ThumbnailSet;
const HotkeyManager = hotkeys.HotkeyManager;
const slog = log.Scoped("app");

/// Timed, not counted in ticks, so a slower scan interval doesn't stretch it.
const FORCED_SCAN_INTERVAL_MS: u64 = 1000;
/// With nothing to draw, the tick only keeps up with the forced scan.
const IDLE_TICK_INTERVAL_MS: win32.UINT = FORCED_SCAN_INTERVAL_MS;
const TRAVEL_CHECK_INTERVAL_MS: u64 = 2000;
const PROFILE_NAME_BUFFER_SIZE = 256;
/// What the panels ask of App, which they can't import.
pub const PANEL_HOST: panel_host.Host = .{ .thumbnail_set = currentThumbnailSet, .roster = currentRoster, .exclusions = currentExclusions, .run = runPanelRequest };
/// What the configuration window asks of App, which it can't import.
pub const DIALOG_HOST: dialog_host.Host = .{ .thumbnail_set = currentThumbnailSet, .notifier = currentNotifier, .timer_window = currentTimerWindow, .save = saveDialogSettings, .run = runDialogRequest };

/// What restartSubsystems' earlier steps hand to its later ones.
const Restart = struct {
    timer_hwnd: win32.HWND,
    /// The replacement store until install_profile takes it.
    pending: *?config.ProfileStore,
    global_draft: ?*config.GlobalConfig,
    /// Borrows Scout's windows, from rescan_windows on.
    eve_windows: []const scout_mod.EveWindow = &.{},
};

/// What the state file reads of the last renders and alert sounds; made only while it's on.
const Recorders = struct {
    overlays: overlay.DrawnRecorder,
    panel_texts: panel_chrome.TextRecorder,
    plays: alert_effects.PlayCounts = .{},
};

/// What main.zig loads from disk before building App.
pub const Loaded = struct {
    global_settings: config.GlobalConfig,
    character_ids: CharacterIds,
    store: config.ProfileStore,
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
    /// Synced from Scout each tick; kept across a thumbnail set rebuild and a profile switch.
    roster: roster_mod.Roster,
    /// Unique system and character colours; kept across a thumbnail set rebuild and a profile switch.
    auto_colors: auto_colors_mod.AutoColorStore,
    /// Kept across a Save or profile switch.
    exclusions: exclusions_mod.Exclusions,
    /// Kept across a thumbnail set rebuild, so a client still loading through a profile switch is still corrected.
    auto_move: auto_move_mod.AutoMoveVerifier,
    /// Kept across a thumbnail set rebuild.
    notifications: center.NotificationCenter = .{},
    /// The pins and reports the Map Panel, Intel Panel and thumbnails show; kept across a thumbnail set rebuild.
    intel: intel_mod.Intel = .{},
    /// Kept across a thumbnail set rebuild.
    map_panel: map_panel_mod.MapPanel,
    instance: win32.HINSTANCE,
    /// Kept across a thumbnail set rebuild, and reset when another profile is loaded.
    auto_minimizer: auto_minimize.AutoMinimizer,
    /// Each cycle command's position; reset whenever the hotkey manager is recreated, after a Save or profile switch.
    cycle: cycling.CycleState = .{},
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
    dialog: ?dialog_host.DialogHooks = null,
    pending_profile_buf: [PROFILE_NAME_BUFFER_SIZE]u8 = undefined,
    /// Borrows from pending_profile_buf.
    pending_profile: ?[]const u8 = null,
    last_forced_scan: win32.Ticks = .{},
    tick_interval_ms: win32.UINT = 0,
    last_travel_check: win32.Ticks = .{},
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
            .exclusions = .init(allocator),
            .auto_move = .init(allocator),
            .auto_minimizer = .init(allocator),
            .trackers = .init(allocator, io),
            .scout = .init(allocator),
            .roster = .init(allocator),
            .auto_colors = .init(allocator, io),
            .map_panel = .{ .host = PANEL_HOST },
            .state_report = .init(if (config.environMap()) |environ_map| environ_map.get(state_file.ENVIRONMENT_VARIABLE) else null),
        };
    }

    /// Everything main.zig doesn't set up itself, built by the restart plan from nothing running; once, before the message loop.
    pub fn start(self: *App, timer_hwnd: win32.HWND) !void {
        self.timer_hwnd = timer_hwnd;
        self.store.live.logSettings();
        if (self.state_report != null) self.startRecorders();
        self.notifications.start(self.panelContext(), PANEL_HOST, &self.intel.history);
        self.map_panel.start(self.panelContext(), &self.intel, &self.global_settings);
        self.scout.listenForEvents();
        self.focus.start();
        self.tray_icon = try tray.TrayIcon.init(self.allocator, timer_hwnd);
        try self.restartSubsystems(timer_hwnd, null, null);
        if (self.chatlog_monitor) |monitor| {
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
        self.auto_minimizer.deinit();
        self.cycle.deinit(self.allocator);
        self.auto_move.deinit();
        self.exclusions.deinit();
        self.auto_colors.deinit();
        self.roster.deinit();
        self.scout.deinit();
        self.map_panel.deinit(self.allocator);
        self.notifications.deinit(self.allocator);
        self.store.deinit();
        self.character_ids.deinit();
        self.global_settings.deinit();
        if (self.state_report) |*report| report.deinit(self.allocator);
        self.stopRecorders();
    }

    fn startRecorders(self: *App) void {
        const recorders = self.allocator.create(Recorders) catch |err| {
            slog.warn("Failed to start recording renders for the state file: {}", .{err});
            return;
        };
        recorders.* = .{ .overlays = .init(self.allocator), .panel_texts = .init(self.allocator) };
        self.recorders = recorders;
        overlay.setRecorder(&recorders.overlays);
        panel_chrome.setRecorder(&recorders.panel_texts);
        alert_effects.setPlayCounts(&recorders.plays);
    }

    fn stopRecorders(self: *App) void {
        const recorders = self.recorders orelse return;
        overlay.setRecorder(null);
        panel_chrome.setRecorder(null);
        alert_effects.setPlayCounts(null);
        recorders.overlays.deinit();
        recorders.panel_texts.deinit();
        self.allocator.destroy(recorders);
        self.recorders = null;
    }

    /// Shows alerts on the roster's clients, with or without a thumbnail set.
    pub fn notifier(self: *App) notifier_mod.Notifier {
        return .{ .allocator = self.allocator, .config = &self.store.live, .auto_colors = &self.auto_colors, .records = self.notifications.records(), .roster = &self.roster, .intel = &self.intel };
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
            .exclusions = &self.exclusions,
            .notified_queue = &self.notifications.notified_queue,
            .notifier = self.notifier(),
            .roster = &self.roster,
            .cycle = &self.cycle,
        };
    }

    /// After a client was focused by hand: every cycle continues from it.
    pub fn syncCyclesToFocused(self: *App, character_name: []const u8, hwnd: win32.HWND) void {
        if (!cycling.syncToFocusedCharacter(&self.commands(), character_name, hwnd)) return;
        if (self.hotkey_manager) |manager| manager.syncCharacterCursors(character_name);
    }

    pub fn panelContext(self: *App) panel_host.Context {
        return .{ .allocator = self.allocator, .store = &self.store, .auto_colors = &self.auto_colors, .instance = self.instance };
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
        try self.restartSubsystems(timer_hwnd, null, if (draft_copy) |*copy| copy else null);
        if (save.global_draft == null) return;

        try self.global_settings.save(self.io);
        applyGlobalSettings(&self.global_settings);
    }

    /// After a dialog edit to the live profile.
    fn onLiveProfileEdited(self: *App, layout: dialog_host.LiveLayout) void {
        self.roster.refreshConfig(&self.store.live, &self.auto_colors, .all);
        self.map_panel.sync(self.panelContext());
        self.notifications.sync(self.panelContext());
        const thumbnail_set = self.thumbnail_set orelse return;
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
        if (self.list_window) |*list_window| list_window.sync();
        thumbnail_set.refreshAllThumbnailConfigCaches();
        // Moved before redrawing, so a re-shown thumbnail doesn't flash in its old place.
        switch (layout) {
            .none => {},
            .spaces => thumbnail_set.reflowIfSpacesActive(),
            .all => thumbnail_set.repositionAllThumbnails(),
        }
        thumbnail_set.refreshAllThumbnailVisuals();
        if (self.list_window) |*list_window| list_window.redraw();
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
        self.syncRoster(scout_result.windows);
        self.followNewClients();
        if (self.roster.clients.items.len == 0) self.auto_colors.flush();
        self.clearLoggedOutExclusions(scout_result.name_changes.items);
        // The Characters tab marks who's logged in, which only a login, logout or closed client changes.
        if (scout_result.name_changes.items.len > 0 or scout_result.closed_windows.items.len > 0) {
            if (self.dialog) |dialog| dialog.redraw();
        }
        if (self.hotkey_manager) |manager| manager.syncFocusFilter(scout_result.windows);
        hook_bindings.logFailedPosts();
        focus_mod.afterActiveRefresh(self, scout_result.name_changes.items);

        self.roster.expireAlerts(win32.Ticks.now());
        const dragged_hwnd = if (self.thumbnail_set) |thumbnail_set| thumbnail_set.draggedSourceHwnd() else null;
        self.roster.refreshMinimized(dragged_hwnd);
        if (self.thumbnail_set) |thumbnail_set| {
            thumbnail_set.updateConnections(&self.intel.pins, tick_start.ms);
            thumbnail_set.update(scout_result.windows, scout_result.closed_windows.items, scout_result.name_changes.items);
            thumbnail_set.checkHoverZoom();
        }
        if (self.list_window) |*list_window| {
            list_window.render(&self.roster, list_view.viewOf(self.thumbnail_set)) catch |err| {
                slog.err("Failed to render list window: {}", .{err});
            };
        }
        self.auto_minimizer.check(&self.store.live, self.roster.clients.items, self.roster.active_hwnd, dragged_hwnd);

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
        self.map_panel.update(self.allocator, self.io, &self.store.live, presence);
        self.notifications.update(&self.store.live, presence, &self.intel.history);

        self.trackers.tick(&self.store.live, scout_result.windows, tick_start, self.tick_interval_ms, self.thumbnail_set, &self.notifier());

        if (schedule.isDue(tick_start.elapsedSince(self.last_travel_check), TRAVEL_CHECK_INTERVAL_MS, self.tick_interval_ms)) {
            self.last_travel_check = tick_start;
            travel_left_behind.check(&self.notifier(), &self.exclusions, tick_start);
        }

        const wanted_interval = self.tickIntervalFor(scout_result.windows.len);
        if (wanted_interval != self.tick_interval_ms) {
            if (self.timer_hwnd) |timer_hwnd| {
                if (self.setTickInterval(timer_hwnd, wanted_interval)) {
                    slog.debug("Tick interval now {} ms", .{wanted_interval});
                } else {
                    slog.warn("Failed to update the timer interval to {} ms, keeping {} ms", .{ wanted_interval, self.tick_interval_ms });
                }
            }
        }
        self.publishState();
    }

    fn publishState(self: *App) void {
        const report = if (self.state_report) |*report| report else return;
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const snapshot = self.stateSnapshot(arena_state.allocator()) catch |err| {
            slog.warn("Failed to gather the app state: {}", .{err});
            return;
        };
        report.publish(self.allocator, self.io, snapshot);
    }

    /// Borrows from App and `arena`, so publish it before either changes.
    fn stateSnapshot(self: *const App, arena: std.mem.Allocator) !state_file.Snapshot {
        const thumbnails: []const set.ThumbnailWindow = if (self.thumbnail_set) |thumbnail_set| thumbnail_set.thumbnails.items else &.{};
        const thumbnail_entries = try arena.alloc(state_file.Snapshot.Thumbnail, thumbnails.len);
        for (thumbnails, thumbnail_entries) |*thumbnail, *entry| entry.* = .{
            .character_name = thumbnail.character_name,
            .hwnd = @intFromPtr(thumbnail.hwnd),
            .source_hwnd = @intFromPtr(thumbnail.source_hwnd),
            .visibility = thumbnail.visibility_state,
            .is_hidden_by_character = thumbnail.cached_is_thumbnail_hidden,
            .group_badge = thumbnail.cached_group_badge_label,
            .overlay = if (self.recorders) |recorders| try overlaySnapshot(arena, thumbnail, &recorders.overlays) else null,
        };

        const hotkey_groups = self.store.live.hotkeyGroups.items;
        const groups = try arena.alloc(state_file.Snapshot.Group, hotkey_groups.len);
        for (hotkey_groups, groups) |*group, *entry| entry.* = .{ .name = group.name, .members = group.characters.items };

        const clients = try arena.alloc(state_file.Snapshot.Client, self.roster.clients.items.len);
        for (self.roster.clients.items, clients) |*client, *entry| {
            const active = client.notifications.items();
            const alerts = try arena.alloc(state_file.Snapshot.Alert, active.len);
            for (active, alerts) |*alert, *alert_entry| alert_entry.* = .{
                .notification_type = alert.notification_type,
                .text = alert.text,
                .shows_text = alert.shows_text,
                .shows_border = alert.shows_border,
                .flashes_border = alert.flashes_border,
                .border_color = alert.border_color_override,
                .text_color = alert.text_color_override,
            };
            entry.* = .{
                .character_name = client.character_name,
                .hwnd = @intFromPtr(client.hwnd),
                .system_name = client.system_name,
                .alerts = alerts,
                .incoming_dps = client.stats.incoming_dps,
                .outgoing_dps = client.stats.outgoing_dps,
                .mining_rate = client.stats.mining_rate,
                .mining_isk_rate = client.stats.mining_isk_rate,
                .bounty_isk_rate = client.stats.bounty_isk_rate,
            };
        }

        const play_counts: alert_effects.PlayCounts = if (self.recorders) |recorders| recorders.plays else .{};
        return .{
            .profile = self.store.live.profile_name,
            .active_hwnd = if (self.roster.active_hwnd) |hwnd| @intFromPtr(hwnd) else null,
            .are_hotkeys_suspended = if (self.hotkey_manager) |manager| manager.are_hotkeys_suspended else false,
            .excluded_characters = self.exclusions.names.items,
            .groups = groups,
            .thumbnails = thumbnail_entries,
            .clients = clients,
            .are_alerts_muted = alert_effects.isMuted(),
            .sounds_played = play_counts.sounds,
            .speeches_started = play_counts.speeches,
            .history = try historyEntries(arena, &self.notifications.history),
            .intel_history = try historyEntries(arena, &self.intel.history),
            .panels = try self.panelSnapshots(arena),
        };
    }

    fn panelSnapshots(self: *const App, arena: std.mem.Allocator) ![]const state_file.Snapshot.Panel {
        const recorders = self.recorders orelse return &.{};
        const text_recorder = &recorders.panel_texts;
        var panels: std.ArrayList(state_file.Snapshot.Panel) = .empty;
        if (self.list_window) |*window| try panels.append(arena, try panelSnapshot(arena, .client_list, window.panel.hwnd, text_recorder));
        if (self.notifications.panel.window) |*window| try panels.append(arena, try panelSnapshot(arena, .history, window.panel.hwnd, text_recorder));
        if (self.notifications.intel_panel.window) |*window| try panels.append(arena, try panelSnapshot(arena, .intel, window.panel.hwnd, text_recorder));
        if (self.map_panel.window) |*window| try panels.append(arena, try panelSnapshot(arena, .map, window.panel.hwnd, text_recorder));
        return panels.items;
    }

    /// Writes what only teardown would, for an exit that skips it: Windows ending the session, or a background thread outlasting the wait at exit.
    pub fn saveBeforeAbruptExit(self: *App) void {
        self.auto_colors.flush();
        log.flush();
    }

    /// Temporary; not saved to the profile.
    fn toggleAutoMinimize(self: *App) void {
        const is_enabled = self.auto_minimizer.toggle(&self.store.live);
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
        return self.roster.contains(foreground);
    }

    fn deliverChatlogFindings(self: *App, findings: *const chatlog.Findings) void {
        const now_ms = win32.Ticks.now().ms;
        for (findings.system_updates.items) |system_update| {
            const client = self.roster.byName(system_update.character_name) orelse {
                slog.debug("Dropped system update for '{s}': no window", .{system_update.character_name});
                continue;
            };
            self.roster.updateSystem(client.hwnd, system_update.system_name, system_update.event_timestamp, if (system_update.is_jump) now_ms else null) catch |err| {
                slog.err("Failed to update system name for '{s}': {}", .{ system_update.character_name, err });
            };
        }

        for (findings.notifications.items) |event| {
            const client = self.roster.byName(event.character_name) orelse {
                slog.debug("Dropped {s} notification for '{s}': no window", .{ @tagName(event.notification.notification_type), event.character_name });
                continue;
            };
            self.notifier().notify(client.hwnd, event.notification);
        }

        for (findings.intel_sightings.items) |sighting| {
            if (sighting.is_pinned) {
                const intel_settings = &self.store.live.intel;
                self.intel.pin(sighting.system, sighting.message, sighting.is_clear, .{ .shows_clear = intel_settings.showClear, .lifetime_ms = intel_settings.shrinkMs() }, now_ms);
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

    fn tickIntervalFor(self: *const App, window_count: usize) win32.UINT {
        const is_dialog_open = if (self.dialog) |dialog| dialog.is_open() else false;
        // Never idle under the end-to-end tests, which wait on the state file only a tick writes.
        if (window_count == 0 and !is_dialog_open and self.state_report == null) return IDLE_TICK_INTERVAL_MS;
        return self.store.saved.timer.scanIntervalMs;
    }

    /// Mirrors `windows` into the roster, and takes the foreground window as its active one.
    fn syncRoster(self: *App, windows: []const scout_mod.EveWindow) void {
        self.roster.sync(windows);
        self.roster.refreshConfig(&self.store.live, &self.auto_colors, .stale);
        self.roster.setActive(win32.GetForegroundWindow());
    }

    /// Replaces the running timer in place; false on failure.
    fn setTickInterval(self: *App, timer_hwnd: win32.HWND, interval_ms: win32.UINT) bool {
        if (win32.SetTimer(timer_hwnd, messages.TICK_TIMER_ID, interval_ms, null) == 0) return false;
        self.tick_interval_ms = interval_ms;
        return true;
    }

    fn createThumbnailSet(self: *App) !*ThumbnailSet {
        const new_set = try self.allocator.create(ThumbnailSet);
        errdefer self.allocator.destroy(new_set);
        new_set.* = try ThumbnailSet.init(self.allocator, .{
            .store = &self.store,
            .exclusions = &self.exclusions,
            .auto_colors = &self.auto_colors,
            .roster = &self.roster,
        }, .{
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

    fn buildThumbnailSet(self: *App, windows: []const scout_mod.EveWindow) !void {
        const new_set = try self.createThumbnailSet();
        new_set.populate(windows);
    }

    /// A hotkey registration failure is logged, not fatal.
    fn createHotkeyManager(self: *App, timer_hwnd: win32.HWND) !void {
        // Before anything can fail, so group cycling always matches the saved groups.
        self.cycle.reset(self.allocator, self.store.saved.hotkeyGroups.items.len);
        const manager = try self.allocator.create(HotkeyManager);
        manager.* = .init(self.allocator, .{
            .store = &self.store,
            .global_settings = &self.global_settings,
            .timer_hwnd = timer_hwnd,
        });
        self.hotkey_manager = manager;

        manager.registerHotkeys(timer_hwnd) catch |err| {
            slog.warn("Failed to register hotkeys, continuing without hotkey support: {}", .{err});
        };
        manager.syncFocusFilter(self.scout.getWindows());
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
                    const manager = self.hotkey_manager orelse {
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
        self.notifications.history.clear();
        self.intel.history.clear();
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
    fn createChatlogMonitor(self: *App) !*chatlog.ChatlogMonitor {
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
        // The set built from these windows reads their clients.
        self.syncRoster(self.scout.getWindows());
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
            self.notifier().notifyAll(.{ .notification_type = .ProfileSwitch, .target = config.profileDisplayName(self.store.live.profile_name) });
            if (self.global_settings.moveOnProfileSwitch) self.moveClientsToSavedPositions();
        }

        slog.info("=== Profile reload complete: {s} ===", .{new_profile_name});
    }

    /// Every EVE client to its saved window position, as on startup or a profile switch when the settings ask.
    fn moveClientsToSavedPositions(self: *App) void {
        for (self.scout.getWindows()) |eve_window| {
            if (eve_window.is_eve_client) self.auto_move.moveToSavedPosition(&self.store.live, eve_window.hwnd, eve_window.character_name);
        }
    }

    /// After the tick's sync: moves clients that joined or logged in to their saved positions, and starts new ones minimized, as the profile asks.
    fn followNewClients(self: *App) void {
        const live = &self.store.live;
        for (self.roster.clients.items) |*client| {
            if (!client.is_eve_client) continue;
            switch (client.last_sync) {
                .none => {},
                .joined => {
                    if (live.autoMovePosition.enabled) self.auto_move.moveToSavedPosition(live, client.hwnd, client.character_name);
                    if (live.autoMinimize.startMinimized) actions.minimizeNewClient(live, client.hwnd);
                },
                .logged_in => if (live.autoMovePosition.enabled) self.auto_move.moveToSavedPosition(live, client.hwnd, client.character_name),
            }
        }
        self.auto_move.verify(live);
    }

    /// Runs control/restart_plan.zig's steps, at startup and on a reload; takes ownership of `replacement`, which becomes the running store.
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

        var restart: Restart = .{ .timer_hwnd = timer_hwnd, .pending = &pending, .global_draft = global_draft };

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
                if (self.hotkey_manager == null) return;
                self.destroyHotkeyManager();
                slog.debug("Cleaned up hotkey manager", .{});
            },
            .teardown_thumbnail_set => self.destroyThumbnailSet(),
            .install_profile => {
                const store = restart.pending.* orelse return;
                self.store.deinit();
                self.store = store;
                restart.pending.* = null;
                self.roster.clearAlerts();
                self.roster.restartMinimizeDelays(win32.Ticks.now());
                // Not dumped as at startup: it stalled switches with the debug console open.
                slog.info("Loaded new config: {s}", .{self.store.saved.profile_name});
                self.map_panel.sync(self.panelContext());
                self.notifications.sync(self.panelContext());
            },
            .record_last_used_profile => self.global_settings.updateLastUsed(self.io, self.store.saved.profile_name) catch |err| {
                slog.warn("Failed to update global settings: {}", .{err});
            },
            .rescan_windows => restart.eve_windows = self.rescanWindows(),
            .refresh_roster_config => self.roster.refreshConfig(&self.store.live, &self.auto_colors, .all),
            .build_thumbnail_set => {
                self.buildThumbnailSet(restart.eve_windows) catch |err| {
                    slog.err("Failed to create thumbnail set: {}", .{err});
                    return err;
                };
                slog.debug("Built {} thumbnail(s)", .{restart.eve_windows.len});
            },
            .populate_thumbnail_set => if (self.thumbnail_set) |thumbnail_set| thumbnail_set.populate(restart.eve_windows),
            .clear_log_readings => {
                self.roster.clearLogReadings();
                slog.debug("Cleared what the logs last showed", .{});
            },
            .apply_monitor_settings => if (self.chatlog_monitor) |monitor| {
                monitor.applySettings(&self.global_settings.chatlog);
                slog.info("Kept chatlog monitoring without rescanning logs", .{});
            },
            .create_monitor => self.chatlog_monitor = self.createChatlogMonitor() catch |err| blk: {
                slog.err("Failed to initialize chatlog monitor: {}", .{err});
                break :blk null;
            },
            .setup_trackers => self.trackers.setup(&self.store.saved, self.chatlog_monitor),
            .apply_monitor_profile => if (self.chatlog_monitor) |monitor| monitor.applyProfile(&self.store.saved),
            .start_monitor => if (self.chatlog_monitor) |monitor| startChatlogWorker(monitor),
            .add_monitor_characters => if (self.chatlog_monitor) |monitor| {
                addChatlogCharacters(monitor, restart.eve_windows);
                slog.info("Started chatlog monitoring", .{});
            },
            .create_hotkey_manager => {
                self.createHotkeyManager(restart.timer_hwnd) catch |err| {
                    slog.err("Failed to create hotkey manager: {}", .{err});
                    return err;
                };
                slog.debug("Created hotkey manager", .{});
            },
            .set_tick_interval => {
                const new_interval = self.tickIntervalFor(restart.eve_windows.len);
                if (!self.setTickInterval(restart.timer_hwnd, new_interval)) {
                    // At startup there's no timer to keep, and without one nothing runs.
                    if (self.tick_interval_ms == 0) {
                        slog.err("Failed to create the tick timer", .{});
                        return error.SetTimerFailed;
                    }
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

/// The settings that reach outside the app: the log, the Run key and the protocol handler.
pub fn applyGlobalSettings(settings: *const config.GlobalConfig) void {
    log.setLevel(settings.logLevel);
    if (settings.logLevel == .debug) log.openDebugConsole() else log.closeDebugConsole();
    // Every launch too, since the Run value can be lost or point at a moved exe while the setting stays on.
    run_on_startup.apply(settings.runOnStartup);
    if (settings.autoRegisterProtocol) registry.ensureRegistered();
}

fn addChatlogCharacters(monitor: *chatlog.ChatlogMonitor, windows: []const scout_mod.EveWindow) void {
    for (windows) |eve_window| {
        if (!eve_window.is_eve_client) continue;
        monitor.addCharacter(eve_window.character_name) catch |err| {
            slog.err("Failed to add '{s}' to the chatlog monitor: {}", .{ eve_window.character_name, err });
        };
    }
}

/// Borrows from the thumbnail's render cache and `drawn_recorder`; null before its first render.
fn overlaySnapshot(arena: std.mem.Allocator, thumbnail: *const set.ThumbnailWindow, drawn_recorder: *const overlay.DrawnRecorder) !?state_file.Snapshot.Overlay {
    const settings = thumbnail.render_cache.settings orelse return null;
    const drawn = drawn_recorder.find(@intFromPtr(thumbnail.text_hwnd)) orelse return null;
    const drawn_texts = drawn.drawnTexts();
    const texts = try arena.alloc(state_file.Snapshot.Text, drawn_texts.len);
    for (drawn_texts, texts) |*drawn_text, *entry| entry.* = .{
        .element = @tagName(drawn_text.element),
        .text = drawn_text.text(),
        .box = snapshotBox(drawn_text.box),
        .color = drawn_text.color,
        .bg_color = drawn_text.bg_color,
    };
    return .{
        .width = settings.overlay_width,
        .height = settings.overlay_height,
        .text_alpha = settings.overlay_alpha,
        .shows_border = settings.show_border,
        .border_width = settings.border_width,
        .border_color = settings.border_color,
        .border_style = settings.border_style,
        .shows_exclusion = settings.show_exclusion_overlay,
        .exclusion_style = settings.exclusion_overlay_style,
        .exclusion_color = settings.exclusion_overlay_color,
        .texts = texts,
        .notifications = if (drawn.notifications) |box| snapshotBox(box) else null,
        .notifications_bg_color = drawn.notifications_bg_color,
        .notification_color = drawn.notification_color,
        .connection_map = if (drawn.connection_map) |box| snapshotBox(box) else null,
    };
}

fn snapshotBox(box: overlay.DrawnBox) state_file.Snapshot.Box {
    return .{ .left = box.left, .top = box.top, .width = box.width, .height = box.height };
}

/// Newest first, at most state_file.HISTORY_LIMIT; borrows from copies in `arena`.
fn historyEntries(arena: std.mem.Allocator, source: *const history.NotificationHistory) ![]state_file.Snapshot.HistoryEntry {
    const copies = source.snapshot(try arena.alloc(history.Entry, state_file.HISTORY_LIMIT));
    const entries = try arena.alloc(state_file.Snapshot.HistoryEntry, copies.len);
    for (copies, entries) |*recorded, *entry| {
        entry.* = .{ .notification_type = recorded.notification_type, .character_name = recorded.characterName(), .text = recorded.text() };
    }
    return entries;
}

/// Borrows from `text_recorder`; no texts before the panel's first recorded render.
fn panelSnapshot(arena: std.mem.Allocator, kind: state_file.Snapshot.PanelKind, hwnd: win32.HWND, text_recorder: *const panel_chrome.TextRecorder) !state_file.Snapshot.Panel {
    const record = text_recorder.find(@intFromPtr(hwnd)) orelse return .{ .kind = kind, .hwnd = @intFromPtr(hwnd), .texts = &.{} };
    const recorded = record.items();
    const texts = try arena.alloc(state_file.Snapshot.PanelText, recorded.len);
    for (recorded, texts) |*text, *entry| entry.* = .{ .text = text.text(), .left = text.left, .top = text.top, .color = text.color };
    return .{ .kind = kind, .hwnd = @intFromPtr(hwnd), .texts = texts };
}

fn startChatlogWorker(monitor: *chatlog.ChatlogMonitor) void {
    monitor.startWorkerThread() catch |err| {
        slog.warn("Failed to start chatlog worker thread: {}", .{err});
    };
}

/// For the panels; null outside the run.
fn currentRoster() ?*const roster_mod.Roster {
    const app = g_app orelse return null;
    return &app.roster;
}

/// For the configuration window's alert tests; null outside the run.
fn currentNotifier() ?notifier_mod.Notifier {
    const app = g_app orelse return null;
    return app.notifier();
}

/// For the panels; null outside the run.
fn currentExclusions() ?*const exclusions_mod.Exclusions {
    const app = g_app orelse return null;
    return &app.exclusions;
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
        .suspend_hotkeys_for_recording => if (app.hotkey_manager) |manager| manager.dialogSuspendHotkeys(),
        .resume_hotkeys_for_recording => {
            const manager = app.hotkey_manager orelse return;
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
        .show_system => |system| app.map_panel.showSystem(system),
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
