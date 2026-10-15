//! Owns the thumbnail for every tracked EVE client: keeps the set in step with Scout, shows which is focused and which are hidden, and renders them each tick.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const config_mod = @import("../config.zig");
const types = @import("../config/types.zig");
const scout = @import("../clients/scout.zig");
const actions = @import("../clients/actions.zig");
const auto_move_mod = @import("../clients/auto_move.zig");
const exclusions_mod = @import("../clients/exclusions.zig");
const drag_overlays = @import("../drag/overlays.zig");
const placement = @import("../layout/placement.zig");
const spaces = @import("../layout/spaces.zig");
const monitors = @import("../layout/monitors.zig");
const state = @import("state.zig");
const input = @import("input.zig");
const window = @import("window.zig");
const arrange = @import("arrange.zig");
const list_view = @import("list_view.zig");
const renderer_mod = @import("renderer.zig");
const center = @import("../notifications/center.zig");
const dispatch = @import("../notifications/dispatch.zig");
const notification_mod = @import("../notifications/notification.zig");
const log = @import("../log.zig");

const slog = log.Scoped("thumbnail_set");

pub const ThumbnailWindow = window.ThumbnailWindow;

/// Copied before a reload so the new thumbnails start with their system names.
pub const SystemNameSnapshot = struct {
    allocator: std.mem.Allocator,
    /// Keyed by source_hwnd, which stays stable across the thumbnails' teardown and recreation.
    names: std.AutoHashMap(win32.HWND, []const u8),

    pub fn init(allocator: std.mem.Allocator) SystemNameSnapshot {
        return .{ .allocator = allocator, .names = .init(allocator) };
    }

    pub fn deinit(self: *SystemNameSnapshot) void {
        var it = self.names.valueIterator();
        while (it.next()) |name| self.allocator.free(name.*);
        self.names.deinit();
    }

    pub fn capture(self: *SystemNameSnapshot, thumbnail_set: *const ThumbnailSet) void {
        for (thumbnail_set.thumbnails.items) |thumbnail| {
            if (thumbnail.system_name.len == 0) continue;
            const copy = self.allocator.dupe(u8, thumbnail.system_name) catch |err| {
                slog.warn("Failed to snapshot system name for reload: {}", .{err});
                continue;
            };
            self.names.put(thumbnail.source_hwnd, copy) catch |err| {
                slog.warn("Failed to record system name snapshot for reload: {}", .{err});
                self.allocator.free(copy);
            };
        }
    }

    pub fn get(self: *const SystemNameSnapshot, source_hwnd: win32.HWND) ?[]const u8 {
        return self.names.get(source_hwnd);
    }
};

pub const ThumbnailSet = struct {
    allocator: std.mem.Allocator,
    /// Searched linearly: there are only ever a few dozen.
    thumbnails: std.ArrayList(ThumbnailWindow),
    instance: win32.HINSTANCE,
    /// Read-only: runtime changes go through `store`, reaching the running and saved copies.
    config: *const config_mod.Config,
    store: *config_mod.ProfileStore,
    /// Borrowed from App, which keeps it across a thumbnail set rebuild.
    exclusions: *const exclusions_mod.Exclusions,
    /// Borrowed from App, which keeps it across a thumbnail set rebuild.
    notifications: *center.NotificationCenter,
    destroy_event_hook: ?win32.HANDLE = null,
    renderer: renderer_mod.Renderer,
    /// Non-null only in ClientList mode.
    list_window: ?list_view.ListWindow = null,
    auto_move: auto_move_mod.AutoMoveVerifier,
    ghost_overlay: drag_overlays.GhostOverlay,
    /// Shared by dragging and region select.
    hint_box: gdi_overlay.HintBox = .{},
    /// Sole "who's focused" source of truth; write only via reconcileThumbnailStates.
    active_source_hwnd: ?win32.HWND = null,
    /// Unique system and character colours.
    auto_colors: config_mod.AutoColorStore,
    /// A different mode needs a new ThumbnailSet (see App.onLiveProfileEdited).
    view_mode: types.ViewMode,

    pub const refreshAllThumbnailConfigCaches = arrange.refreshConfigCaches;
    pub const refreshAllThumbnailVisuals = arrange.refreshVisuals;
    pub const repositionAllThumbnails = arrange.repositionAll;
    pub const resizeThumbnailIfNeeded = arrange.resizeIfNeeded;
    pub const reflowIfSpacesActive = arrange.reflowIfSpacesActive;

    pub const PopulateOptions = struct {
        should_move_to_saved: bool,
        /// False at startup/reload so clients already running stay put.
        should_minimize_new: bool = false,
        /// Seeds each new thumbnail's system name, so a reload doesn't show them blank.
        system_names: ?*const SystemNameSnapshot = null,
    };

    const ThumbnailStrings = struct {
        character_name: []const u8,
        system_name: []const u8,
        group_badge_label: []const u8,
    };

    /// Borrows `store`, `exclusions` and `notifications`, which must outlive the thumbnail set.
    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore, exclusions: *const exclusions_mod.Exclusions, notifications: *center.NotificationCenter) !ThumbnailSet {
        const instance = win32.GetModuleHandleA(null) orelse return error.GetModuleHandleFailed;
        const config = &store.live;

        var thumbnail_set: ThumbnailSet = .{
            .allocator = allocator,
            .thumbnails = .empty,
            .auto_colors = .init(allocator, store.io),
            .auto_move = .init(allocator),
            .ghost_overlay = .init(allocator),
            .renderer = .init(allocator),
            .instance = instance,
            .config = config,
            .store = store,
            .exclusions = exclusions,
            .notifications = notifications,
            .view_mode = config.display.viewMode,
        };

        try window.registerClasses(instance);

        // Own process only: removeDestroyedOverlay acts on our overlay windows alone.
        thumbnail_set.destroy_event_hook = win32.setWinEventHookForProcess(win32.EVENT_OBJECT_DESTROY, input.windowDestroyProc, win32.GetCurrentProcessId());
        if (thumbnail_set.destroy_event_hook == null) slog.err("Failed to set up destroy event hook", .{});

        if (config.display.viewMode == .ClientList) {
            thumbnail_set.list_window = list_view.ListWindow.init(allocator, store, instance) catch |err| blk: {
                slog.err("Failed to create list window: {}", .{err});
                break :blk null;
            };
        }

        return thumbnail_set;
    }

    pub fn deinit(self: *ThumbnailSet) void {
        if (self.list_window) |*list_window| {
            list_window.deinit();
            self.list_window = null;
        }

        if (self.destroy_event_hook) |hook| _ = win32.UnhookWinEvent(hook);

        self.ghost_overlay.deinit();
        self.hint_box.deinit();
        self.renderer.deinit();

        for (self.thumbnails.items) |thumbnail| self.destroyThumbnail(thumbnail);
        self.thumbnails.deinit(self.allocator);
        self.auto_move.deinit();
        self.auto_colors.deinit();
    }

    /// Subject to that type's notification settings.
    pub fn notify(self: *ThumbnailSet, source_hwnd: win32.HWND, notification: notification_mod.Notification) void {
        const thumbnail = self.getThumbnailBySourceHwnd(source_hwnd) orelse {
            slog.debug("Window 0x{x} not found for notification update (thumbnail may not exist yet)", .{@intFromPtr(source_hwnd)});
            return;
        };
        dispatch.notify(self.dispatchContext(), thumbnail, notification);
    }

    /// For a global user action: kept out of history, and its sound and speech play once.
    pub fn notifyAll(self: *ThumbnailSet, notification: notification_mod.Notification) void {
        dispatch.notifyAll(self.dispatchContext(), self.thumbnails.items, notification);
    }

    pub fn showTestNotification(self: *ThumbnailSet, notification_type: notification_mod.NotificationType, type_config: config_mod.NotificationTypeConfig) !void {
        try dispatch.showTest(self.dispatchContext(), self.thumbnails.items, notification_type, type_config);
    }

    /// Returns whether anything was removed.
    pub fn dismissClickSuppressedNotifications(self: *const ThumbnailSet, thumbnail: *ThumbnailWindow) bool {
        return dispatch.dismissClickSuppressed(self.allocator, thumbnail);
    }

    /// Clears expired notifications; call every tick.
    pub fn updateNotifications(self: *ThumbnailSet) void {
        dispatch.expire(self.allocator, self.thumbnails.items);
    }

    /// Hides the hover zoom once the cursor has left its thumbnail.
    pub fn checkHoverZoom(self: *ThumbnailSet) void {
        self.renderer.hover_zoom.check(self.config, self.thumbnails.items);
    }

    pub fn layout(self: *const ThumbnailSet) placement.Layout {
        return .{ .config = self.config, .thumbnails = self.thumbnails.items };
    }

    pub fn renderThumbnail(self: *ThumbnailSet, thumbnail: *ThumbnailWindow) !void {
        try self.renderer.render(self.config, thumbnail, self.active_source_hwnd);
    }

    /// Logs a failure, with `context` in the message, instead of propagating it.
    pub fn renderThumbnailLogged(self: *ThumbnailSet, thumbnail: *ThumbnailWindow, context: []const u8) void {
        self.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render thumbnail for '{s}' ({s}): {}", .{ thumbnail.character_name, context, err });
        };
    }

    pub fn hasThumbnail(self: *const ThumbnailSet, source_hwnd: win32.HWND) bool {
        return self.indexOfSource(source_hwnd) != null;
    }

    /// Whether `source_hwnd` is a tracked EVE client, not a window filter's window.
    pub fn hasEveClient(self: *const ThumbnailSet, source_hwnd: win32.HWND) bool {
        const index = self.indexOfSource(source_hwnd) orelse return false;
        return self.thumbnails.items[index].is_eve_client;
    }

    /// Returns whether a reflow is needed to refill the spaces.
    fn cleanupClosedThumbnails(self: *ThumbnailSet, closed_windows: []const scout.ClosedWindow) bool {
        // By source_hwnd, not name: multiple windows can share a name (e.g. "EVE").
        var removed_any = false;
        for (closed_windows) |closed| {
            const index = self.indexOfSource(closed.hwnd) orelse continue;
            slog.info("Cleaning up closed thumbnail for {s}", .{self.thumbnails.items[index].character_name});
            self.removeThumbnailAt(index);
            removed_any = true;
        }
        return removed_any and spaces.anyActive(self.config);
    }

    /// Our own windows only; a source window closing is Scout's to report.
    pub fn removeDestroyedOverlay(self: *ThumbnailSet, hwnd: win32.HWND) void {
        const index = self.indexOfOverlay(hwnd) orelse return;
        slog.info("Window closed (event), removing thumbnail for {s}", .{self.thumbnails.items[index].character_name});
        self.removeThumbnailAt(index);
    }

    /// Don't keep the pointer across anything that adds or removes thumbnails.
    pub fn getThumbnailBySourceHwnd(self: *ThumbnailSet, source_hwnd: win32.HWND) ?*ThumbnailWindow {
        return &self.thumbnails.items[self.indexOfSource(source_hwnd) orelse return null];
    }

    /// Don't keep the pointer across anything that adds or removes thumbnails.
    pub fn getThumbnailByOverlayHwnd(self: *ThumbnailSet, hwnd: win32.HWND) ?*ThumbnailWindow {
        return &self.thumbnails.items[self.indexOfOverlay(hwnd) orelse return null];
    }

    /// Polled on demand, since a hotkey press carries no window of its own.
    pub fn thumbnailUnderCursor(self: *ThumbnailSet) ?*ThumbnailWindow {
        var cursor: win32.POINT = undefined;
        if (!win32.toBool(win32.GetCursorPos(&cursor))) return null;

        const hwnd_at_cursor = win32.WindowFromPoint(cursor) orelse return null;
        const source_hwnd = win32.GetPropA(hwnd_at_cursor, window.SOURCE_HWND_PROP) orelse return null;
        return self.getThumbnailBySourceHwnd(source_hwnd);
    }

    /// After the character's group membership changed.
    pub fn refreshGroupBadge(self: *ThumbnailSet, thumbnail: *ThumbnailWindow) void {
        const new_label = self.config.groupBadgeLabel(self.allocator, thumbnail.character_name) catch |err| {
            slog.err("Failed to build group badge label for '{s}': {}", .{ thumbnail.character_name, err });
            return;
        };
        thumbnail.replaceText(self.allocator, .group_badge_label, new_label);
    }

    /// Reconciles focus, then marks thumbnails dirty whose minimized state changed.
    fn updateThumbnailStates(self: *ThumbnailSet) void {
        if (self.thumbnails.items.len == 0) return;

        self.reconcileThumbnailStates(win32.GetForegroundWindow());

        const now = win32.Ticks.now();
        for (self.thumbnails.items) |*thumbnail| {
            if (thumbnail.is_dragged) continue;

            if (thumbnail.render_cache.settings) |cached| {
                if (cached.show_session_timer and cached.session_minutes != (thumbnail.sessionMinutes(now) orelse 0)) thumbnail.needs_render = true;
            }

            const is_minimized = win32.isWindowIconic(thumbnail.source_hwnd);
            if (is_minimized != thumbnail.was_minimized) {
                thumbnail.was_minimized = is_minimized;
                thumbnail.needs_render = true;
            }
        }
    }

    /// The first one speaks for all; with none, they count as shown.
    pub fn thumbnailsShown(self: *const ThumbnailSet) bool {
        if (self.thumbnails.items.len == 0) return true;
        return self.thumbnails.items[0].visibility_state == .visible;
    }

    /// Manual hiding persists through focus changes.
    pub fn toggleAllThumbnailsVisibility(self: *ThumbnailSet) void {
        if (self.thumbnails.items.len == 0) {
            slog.debug("No thumbnails to toggle visibility", .{});
            return;
        }

        const new_visibility: state.VisibilityState = if (self.thumbnailsShown()) .hidden_manual else .visible;
        slog.info("Toggling all thumbnails visibility: {}", .{new_visibility});

        for (self.thumbnails.items) |*thumbnail| {
            thumbnail.setVisibility(new_visibility);
            self.renderThumbnailLogged(thumbnail, "visibility toggle");
        }
    }

    /// The hide-debounce timer fired, so no EVE window has had focus for hideDebounceMs.
    pub fn autoHideAfterFocusLoss(self: *ThumbnailSet) void {
        slog.debug("Hide debounce timer fired", .{});

        // Checked again, since the setting or focus may have changed while the timer ran.
        const eve_has_focus = self.isEveWindowForeground();
        for (self.thumbnails.items) |*thumbnail| {
            if (self.applyAutoVisibility(thumbnail, eve_has_focus)) self.renderThumbnailLogged(thumbnail, "auto-hide");
        }
    }

    fn focusHide(self: *const ThumbnailSet, eve_has_focus: bool) state.FocusHide {
        return .{ .is_enabled = self.config.shownAutoHide().is_enabled, .is_eve_focused = eve_has_focus };
    }

    /// Returns whether it changed.
    pub fn applyAutoVisibility(self: *const ThumbnailSet, thumbnail: *ThumbnailWindow, eve_has_focus: bool) bool {
        const target = thumbnail.visibility_state.afterAutoHide(self.focusHide(eve_has_focus));
        if (thumbnail.visibility_state == target) return false;
        thumbnail.setVisibility(target);
        return true;
    }

    /// Records the ones it hid in `hidden`, so showThumbnails restores only those.
    pub fn hideVisibleThumbnails(self: *ThumbnailSet, allocator: std.mem.Allocator, hidden: *std.ArrayList(win32.HWND)) void {
        for (self.thumbnails.items) |*thumbnail| {
            if (!thumbnail.isVisible()) continue;
            thumbnail.setVisibility(.hidden_manual);
            hidden.append(allocator, thumbnail.hwnd) catch |err| {
                slog.err("Failed to remember a hidden thumbnail to show again: {}", .{err});
            };
            self.renderThumbnailLogged(thumbnail, "hide");
        }
    }

    pub fn showThumbnails(self: *ThumbnailSet, hwnds: []const win32.HWND) void {
        for (hwnds) |hwnd| {
            const thumbnail = self.getThumbnailByOverlayHwnd(hwnd) orelse continue;
            thumbnail.setVisibility(.visible);
            self.renderThumbnailLogged(thumbnail, "show");
        }
    }

    /// Sole writer of active_source_hwnd; call instead of setting it directly.
    pub fn reconcileThumbnailStates(self: *ThumbnailSet, should_be_active_hwnd: ?win32.HWND) void {
        const old_active = self.active_source_hwnd;
        self.active_source_hwnd = should_be_active_hwnd;
        const active_changed = old_active != should_be_active_hwnd;
        const any_eve_has_focus = if (should_be_active_hwnd) |hwnd| self.hasThumbnail(hwnd) else false;

        for (self.thumbnails.items) |*thumbnail| {
            // Losing focus hides only after the debounce timer, so only regaining it applies here.
            if (any_eve_has_focus and self.applyAutoVisibility(thumbnail, true)) thumbnail.needs_render = true;

            if (active_changed and (thumbnail.source_hwnd == old_active or thumbnail.source_hwnd == should_be_active_hwnd)) {
                thumbnail.needs_render = true;
            }
        }
    }

    pub fn isEveWindowForeground(self: *const ThumbnailSet) bool {
        const foreground_hwnd = win32.GetForegroundWindow() orelse return false;
        return self.hasThumbnail(foreground_hwnd);
    }

    /// See ThumbnailWindow.system_name_event_timestamp and .travel for `event_timestamp` and `is_jump`.
    pub fn updateSystemNameByHwnd(self: *ThumbnailSet, source_hwnd: win32.HWND, system_name: []const u8, event_timestamp: u64, is_jump: bool) !void {
        const thumbnail = self.getThumbnailBySourceHwnd(source_hwnd) orelse {
            slog.debug("No thumbnail for window 0x{x} to show system {s}", .{ @intFromPtr(source_hwnd), system_name });
            return;
        };

        if (event_timestamp != 0 and event_timestamp < thumbnail.system_name_event_timestamp) {
            slog.debug("Ignoring stale system update for {s}: {s} (event_timestamp={} < current={})", .{ thumbnail.character_name, system_name, event_timestamp, thumbnail.system_name_event_timestamp });
            return;
        }

        thumbnail.replaceText(self.allocator, .system_name, try self.allocator.dupe(u8, system_name));
        thumbnail.system_name_event_timestamp = event_timestamp;
        thumbnail.cached_system_color = self.auto_colors.systemNameColor(self.config, system_name);
        slog.debug("System '{s}' color resolved to: 0x{X:0>6}", .{ system_name, thumbnail.cached_system_color & 0xFFFFFF });

        if (is_jump) thumbnail.travel.recordJump();

        thumbnail.needs_render = true;
        slog.debug("Updated system for {s}: {s}", .{ thumbnail.character_name, system_name });
    }

    /// Past `max_immediate`, the rest stay dirty for the next tick.
    pub fn renderDirtyThumbnails(self: *ThumbnailSet, max_immediate: ?usize) void {
        var rendered: usize = 0;
        for (self.thumbnails.items) |*thumbnail| {
            if (!thumbnail.needs_render) continue;

            if (max_immediate) |cap| {
                if (rendered >= cap) continue;
            }

            self.renderThumbnailLogged(thumbnail, "dirty thumbnail");
            thumbnail.needs_render = false;
            rendered += 1;
        }
    }

    /// `setter` is an ActivityStats setter; redraws if anything shown changed.
    pub fn updateStats(self: *ThumbnailSet, source_hwnd: win32.HWND, comptime setter: anytype, args: anytype) void {
        const thumbnail = self.getThumbnailBySourceHwnd(source_hwnd) orelse return;
        if (@call(.auto, setter, .{&thumbnail.stats} ++ args)) thumbnail.needs_render = true;
    }

    /// After Scout backdated the client's login from its gamelog.
    pub fn setSessionStart(self: *ThumbnailSet, source_hwnd: win32.HWND, started: win32.Ticks) void {
        const thumbnail = self.getThumbnailBySourceHwnd(source_hwnd) orelse return;
        thumbnail.session_start = started;
        thumbnail.needs_render = true;
    }

    /// Logins, logouts and renames; returns whether the layout needs a reflow.
    fn applyNameChanges(self: *ThumbnailSet, name_changes: []const scout.NameChange) bool {
        var any_login = false;
        var any_logout = false;
        for (name_changes) |change| {
            const thumbnail = self.getThumbnailBySourceHwnd(change.hwnd) orelse continue;

            const was_generic = scout.isGenericCharacterName(change.old_name);
            const is_now_generic = scout.isGenericCharacterName(change.new_name);
            // Either direction can move a thumbnail to another space, or change its rank in one.
            if (was_generic and !is_now_generic) any_login = true;
            if (is_now_generic and !was_generic) any_logout = true;

            self.rename(thumbnail, change.new_name) catch |err| {
                slog.err("Failed to rename the thumbnail for '{s}': {}", .{ change.new_name, err });
                continue;
            };
            thumbnail.session_start = change.logged_in_at;

            if (was_generic and !is_now_generic) self.onLogin(thumbnail);
            if (is_now_generic) self.onLogout(thumbnail);

            self.renderThumbnailLogged(thumbnail, "name change");
            slog.info("Updated thumbnail for {s}", .{thumbnail.character_name});
        }

        if (!spaces.anyActive(self.config)) return false;
        return any_login or any_logout;
    }

    /// The only writer of is_excluded_from_cycle.
    pub fn refreshExclusion(self: *ThumbnailSet, thumbnail: *ThumbnailWindow) void {
        const is_excluded = self.exclusions.contains(thumbnail.character_name);
        if (is_excluded == thumbnail.is_excluded_from_cycle) return;
        thumbnail.is_excluded_from_cycle = is_excluded;
        thumbnail.needs_render = true;
    }

    /// Once log monitoring is off, so stale log readings don't stay on screen.
    pub fn clearLogReadings(self: *ThumbnailSet) void {
        for (self.thumbnails.items) |*thumbnail| {
            if (thumbnail.system_name.len > 0) self.clearSystemName(thumbnail);
            if (thumbnail.stats.clearLogReadings()) thumbnail.needs_render = true;
            dispatch.clearLogDriven(self.allocator, thumbnail);
        }
        slog.debug("Cleared what the logs last showed", .{});
    }

    /// Reflows once at the end, since createThumbnail sizes each against the count so far.
    pub fn populate(self: *ThumbnailSet, eve_windows: []const scout.EveWindow, options: PopulateOptions) void {
        if (self.addMissingThumbnails(eve_windows, options) and arrange.hasCountDependentLayout(self)) self.repositionAllThumbnails();
    }

    pub fn update(self: *ThumbnailSet, eve_windows: []const scout.EveWindow, closed_windows: []const scout.ClosedWindow, name_changes: []const scout.NameChange) void {
        var needs_region_reflow = self.cleanupClosedThumbnails(closed_windows);
        self.updateThumbnailStates();
        needs_region_reflow = self.applyNameChanges(name_changes) or needs_region_reflow;
        self.auto_move.verify(self.config);

        // createThumbnail seeds character_name from eve_window, so new thumbnails need no re-sync.
        const created_new = self.addMissingThumbnails(eve_windows, .{
            .should_move_to_saved = self.config.autoMovePosition.enabled,
            .should_minimize_new = self.config.autoMinimize.startMinimized,
        });
        needs_region_reflow = (created_new and arrange.hasCountDependentLayout(self)) or needs_region_reflow;

        // One reflow for all three triggers above.
        if (needs_region_reflow) self.repositionAllThumbnails();

        self.renderDirtyThumbnails(null);

        if (self.list_window) |*list_window| {
            list_window.render(self.thumbnails.items, self.active_source_hwnd) catch |err| {
                slog.err("Failed to render list window: {}", .{err});
            };
        }
    }

    /// Applies list view settings read only at creation, after a dialog change.
    pub fn syncListWindow(self: *ThumbnailSet) void {
        if (self.list_window) |*list| list.sync();
    }

    pub fn saveThumbnailPosition(self: *ThumbnailSet, hwnd: win32.HWND) void {
        const thumbnail = self.getThumbnailByOverlayHwnd(hwnd) orelse return;
        const entry = positionOf(thumbnail) orelse return;
        self.store.setCharacterPositions(&.{entry});
    }

    /// After a group drag: every thumbnail's position, in one profile write.
    pub fn saveAllThumbnailPositions(self: *ThumbnailSet) void {
        var entries: std.ArrayList(config_mod.ProfileStore.CharacterPosition) = .empty;
        defer entries.deinit(self.allocator);
        for (self.thumbnails.items) |*thumbnail| {
            const entry = positionOf(thumbnail) orelse continue;
            entries.append(self.allocator, entry) catch |err| {
                slog.err("Failed to collect thumbnail positions to save: {}", .{err});
                return;
            };
        }
        self.store.setCharacterPositions(entries.items);
    }

    fn dispatchContext(self: *const ThumbnailSet) dispatch.Context {
        return .{ .allocator = self.allocator, .config = self.config, .center = self.notifications, .active_source_hwnd = self.active_source_hwnd };
    }

    fn destroyThumbnail(self: *ThumbnailSet, thumbnail: ThumbnailWindow) void {
        if (thumbnail.is_win32_enabled) window.destroy(&thumbnail);
        self.freeThumbnailData(thumbnail);
    }

    /// Frees what it owns in every mode: its strings and notification stack.
    fn freeThumbnailData(self: *ThumbnailSet, thumbnail: ThumbnailWindow) void {
        self.allocator.free(thumbnail.character_name);
        self.allocator.free(thumbnail.system_name);
        self.allocator.free(thumbnail.cached_group_badge_label);
        thumbnail.notifications.deinit(self.allocator);
    }

    fn removeThumbnailAt(self: *ThumbnailSet, index: usize) void {
        self.destroyThumbnail(self.thumbnails.orderedRemove(index));
        if (self.thumbnails.items.len == 0) self.auto_colors.flush();
    }

    fn indexOfSource(self: *const ThumbnailSet, source_hwnd: win32.HWND) ?usize {
        for (self.thumbnails.items, 0..) |thumbnail, i| {
            if (thumbnail.source_hwnd == source_hwnd) return i;
        }
        return null;
    }

    /// Matches a thumbnail's own window or its text overlay, never a source EVE window.
    fn indexOfOverlay(self: *const ThumbnailSet, hwnd: win32.HWND) ?usize {
        for (self.thumbnails.items, 0..) |thumbnail, i| {
            // Outside Thumbnails mode the handles are sentinels.
            if (thumbnail.is_win32_enabled and (thumbnail.hwnd == hwnd or thumbnail.text_hwnd == hwnd)) return i;
        }
        return null;
    }

    /// Keeps the old name if copying fails.
    fn rename(self: *ThumbnailSet, thumbnail: *ThumbnailWindow, name: []const u8) !void {
        thumbnail.replaceText(self.allocator, .character_name, try self.allocator.dupe(u8, name));
        thumbnail.refreshConfigCache(self.config, &self.auto_colors);
        self.refreshGroupBadge(thumbnail);
    }

    /// The client went from the login screen to a character.
    fn onLogin(self: *ThumbnailSet, thumbnail: *ThumbnailWindow) void {
        const name = thumbnail.character_name;
        // A space ignores the saved spot; applyNameChanges' reflow places it instead.
        if (thumbnail.is_win32_enabled and spaces.spaceFor(self.config, name) == null) {
            if (self.config.getCharacterPosition(name)) |saved_position| {
                thumbnail.moveTo(saved_position.x, saved_position.y, null);
                self.resizeThumbnailIfNeeded(thumbnail, null);
                slog.info("Moved {s} thumbnail to saved position: ({}, {})", .{ name, saved_position.x, saved_position.y });
            } else {
                slog.debug("No saved thumbnail position for {s}, keeping current location", .{name});
            }
        }

        if (self.config.autoMovePosition.enabled) {
            self.auto_move.moveToSavedPosition(self.config, thumbnail.source_hwnd, name);
        }

        self.refreshExclusion(thumbnail);
    }

    /// Back at the login screen; applyNameChanges' reflow moves it.
    fn onLogout(self: *ThumbnailSet, thumbnail: *ThumbnailWindow) void {
        dispatch.clearAll(self.allocator, thumbnail);
        self.refreshExclusion(thumbnail);
        self.clearSystemName(thumbnail);
        slog.debug("Cleared system name for logged out client", .{});
    }

    fn clearSystemName(self: *ThumbnailSet, thumbnail: *ThumbnailWindow) void {
        // Owned like any system name, since freeThumbnailData frees it.
        const empty_system = self.allocator.dupe(u8, "") catch |err| {
            slog.err("Failed to clear the system name for '{s}': {}", .{ thumbnail.character_name, err });
            return;
        };
        thumbnail.replaceText(self.allocator, .system_name, empty_system);
        thumbnail.cached_system_color = self.config.shownColors().system_name_color;
        thumbnail.needs_render = true;
    }

    /// Logs and skips failures; returns whether any were created.
    fn addMissingThumbnails(self: *ThumbnailSet, eve_windows: []const scout.EveWindow, options: PopulateOptions) bool {
        var created_new = false;

        for (eve_windows) |eve_window| {
            if (self.hasThumbnail(eve_window.hwnd)) continue;

            const system_name = if (options.system_names) |names| (names.get(eve_window.hwnd) orelse "") else "";
            self.createThumbnail(&eve_window, system_name) catch |err| {
                slog.err("Failed to create thumbnail for '{s}': {}", .{ eve_window.character_name, err });
                continue;
            };
            created_new = true;

            if (options.should_move_to_saved and eve_window.is_eve_client) {
                self.auto_move.moveToSavedPosition(self.config, eve_window.hwnd, eve_window.character_name);
            }
            if (options.should_minimize_new and eve_window.is_eve_client) {
                actions.minimizeNewClient(self.config, eve_window.hwnd);
            }
        }

        return created_new;
    }

    fn dupeThumbnailStrings(self: *const ThumbnailSet, character_name: []const u8, system_name: []const u8) !ThumbnailStrings {
        const allocator = self.allocator;
        const character_name_copy = try allocator.dupe(u8, character_name);
        errdefer allocator.free(character_name_copy);
        const system_name_copy = try allocator.dupe(u8, system_name);
        errdefer allocator.free(system_name_copy);
        const group_badge_label_copy = try self.config.groupBadgeLabel(allocator, character_name);
        errdefer allocator.free(group_badge_label_copy);

        return .{
            .character_name = character_name_copy,
            .system_name = system_name_copy,
            .group_badge_label = group_badge_label_copy,
        };
    }

    /// Shared by both creation paths; the caller supplies the handles and owns the result's strings.
    fn newThumbnailRecord(self: *ThumbnailSet, eve_window: *const scout.EveWindow, initial_system_name: []const u8, handles: window.Handles, is_win32_enabled: bool) !ThumbnailWindow {
        const strings = try self.dupeThumbnailStrings(eve_window.character_name, initial_system_name);
        var thumbnail: ThumbnailWindow = .{
            .hwnd = handles.hwnd,
            .text_hwnd = handles.text_hwnd,
            .thumbnail_id = handles.thumbnail_id,
            .source_hwnd = eve_window.hwnd,
            .is_eve_client = eve_window.is_eve_client,
            .session_start = eve_window.logged_in_at,
            .character_name = strings.character_name,
            .system_name = strings.system_name,
            .cached_group_badge_label = strings.group_badge_label,
            .auto_minimize = .{ .inactive_since = win32.Ticks.now() },
            // The new client isn't tracked yet, so isEveWindowForeground alone would miss it.
            .visibility_state = state.VisibilityState.visible.afterAutoHide(self.focusHide(win32.GetForegroundWindow() == eve_window.hwnd or self.isEveWindowForeground())),
            .is_win32_enabled = is_win32_enabled,
        };
        thumbnail.refreshConfigCache(self.config, &self.auto_colors);
        self.refreshExclusion(&thumbnail);
        return thumbnail;
    }

    /// Reconciles focus afterwards, since the new client's window may already be the foreground one.
    fn addThumbnail(self: *ThumbnailSet, thumbnail: ThumbnailWindow) !void {
        try self.thumbnails.append(self.allocator, thumbnail);
        self.reconcileThumbnailStates(win32.GetForegroundWindow());
    }

    /// ClientList and Nothing modes only need a data record, not real Win32 windows.
    fn createTrackingOnlyEntry(self: *ThumbnailSet, eve_window: *const scout.EveWindow, initial_system_name: []const u8) !void {
        // Never passed to Win32, since is_win32_enabled is false.
        const sentinel: win32.HWND = @ptrFromInt(1);
        const thumbnail = try self.newThumbnailRecord(eve_window, initial_system_name, .{ .hwnd = sentinel, .text_hwnd = sentinel, .thumbnail_id = sentinel }, false);
        errdefer self.freeThumbnailData(thumbnail);
        try self.addThumbnail(thumbnail);

        slog.info("Created tracking entry for {s} ({s} mode)", .{ eve_window.character_name, @tagName(self.config.display.viewMode) });
    }

    fn createThumbnail(self: *ThumbnailSet, eve_window: *const scout.EveWindow, initial_system_name: []const u8) !void {
        if (self.config.display.viewMode != .Thumbnails) {
            return self.createTrackingOnlyEntry(eve_window, initial_system_name);
        }

        const name = eve_window.character_name;
        const monitor_placement = monitors.resolveMonitorPlacement(&self.config.display);
        const monitor_bounds = if (monitor_placement) |mp| mp.bounds else null;
        const scale = win32.dpiToScale(monitors.dpiForMonitor(if (monitor_placement) |mp| mp.monitor else null));
        const place = arrange.newPlace(self, name, monitor_bounds, scale);
        const position = place.position;
        const size = place.size;

        const handles = try window.create(self.allocator, self.instance, eve_window.hwnd, name, .{
            .position = position,
            .size = size,
            .opacity = self.config.getCharacterOpacity(name),
            .is_click_through = self.config.interaction.clickThrough,
        });
        errdefer window.destroyHandles(handles);

        var thumbnail = try self.newThumbnailRecord(eve_window, initial_system_name, handles, true);
        errdefer self.freeThumbnailData(thumbnail);
        try self.renderThumbnail(&thumbnail);
        errdefer thumbnail.render_cache.deinit();
        const is_shown = if (thumbnail.render_cache.settings) |settings| settings.show_thumbnail else false;
        if (is_shown) window.showText(handles, position, size);

        try self.addThumbnail(thumbnail);

        slog.info("Created thumbnail for {s}", .{name});
    }

    fn positionOf(thumbnail: *const ThumbnailWindow) ?config_mod.ProfileStore.CharacterPosition {
        if (!thumbnail.is_win32_enabled) return null;
        var rect: win32.RECT = undefined;
        if (!win32.toBool(win32.GetWindowRect(thumbnail.hwnd, &rect))) return null;
        return .{ .name = thumbnail.character_name, .position = .{ .x = rect.left, .y = rect.top } };
    }
};
