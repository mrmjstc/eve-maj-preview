//! Owns the thumbnail for every tracked EVE client: keeps the set in step with Scout, tracks focus and visibility, and renders them each tick.
const std = @import("std");
const win32 = @import("platform/win32.zig");
const gdi_overlay = @import("platform/gdi_overlay.zig");
const config_mod = @import("config.zig");
const types = @import("config/types.zig");
const main = @import("main.zig");
const scout = @import("clients/scout.zig");
const auto_minimize_mod = @import("clients/auto_minimize.zig");
const auto_move_mod = @import("clients/auto_move.zig");
const hotkeys = @import("hotkeys/manager.zig");
const exclusions = @import("hotkeys/exclusions.zig");
const thumbnail_drag = @import("drag/thumbnail.zig");
const drag_overlays = @import("drag/overlays.zig");
const placement = @import("layout/placement.zig");
const monitors = @import("layout/monitors.zig");
const state = @import("thumbnail/state.zig");
const window = @import("thumbnail/window.zig");
const arrange = @import("thumbnail/arrange.zig");
const overlay = @import("thumbnail/overlay.zig");
const font_cache_mod = @import("thumbnail/font_cache.zig");
const list_view = @import("thumbnail/list_view.zig");
const dispatch = @import("notifications/dispatch.zig");
const notification_history_mod = @import("notifications/history.zig");
const notified_queue_mod = @import("notifications/notified_queue.zig");
const history_panel_mod = @import("notifications/history_panel.zig");
const log = @import("log.zig");

const slog = log.scoped("painter");

pub const ThumbnailWindow = window.ThumbnailWindow;

/// Timer on main.zig's timer window, beside its tick timer (1), that auto-hides every thumbnail once no EVE window has had focus for hideDebounceMs.
pub const HIDE_DEBOUNCE_TIMER_ID: usize = 2;

/// Each thumbnail's last-known system name, copied before a reload tears Painter down so the new thumbnails can be seeded instead of starting blank.
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

    pub fn capture(self: *SystemNameSnapshot, painter: *const Painter) void {
        for (painter.thumbnails.items) |thumb| {
            if (thumb.system_name.len == 0) continue;
            const copy = self.allocator.dupe(u8, thumb.system_name) catch |err| {
                slog.warn("Failed to snapshot system name for reload: {}", .{err});
                continue;
            };
            self.names.put(thumb.source_hwnd, copy) catch |err| {
                slog.warn("Failed to record system name snapshot for reload: {}", .{err});
                self.allocator.free(copy);
            };
        }
    }

    pub fn get(self: *const SystemNameSnapshot, source_hwnd: win32.HWND) ?[]const u8 {
        return self.names.get(source_hwnd);
    }
};

pub const Painter = struct {
    allocator: std.mem.Allocator,
    /// Searched linearly: there are only ever a few dozen, and an index would go stale on every removal.
    thumbnails: std.ArrayList(ThumbnailWindow),
    instance: win32.HINSTANCE,
    /// Read-only, so every runtime change goes through `store` and reaches both the running and the saved copy.
    config: *const config_mod.Config,
    store: *config_mod.ProfileStore,
    focus_event_hook: ?win32.HANDLE = null,
    destroy_event_hook: ?win32.HANDLE = null,
    hide_timer_pending: bool = false,
    font_cache: font_cache_mod.FontCache,
    /// Non-null when viewMode == .ClientList; owns the compact list panel window.
    list_window: ?list_view.ListWindow = null,
    history_panel: history_panel_mod.HistoryPanel = .{},
    notified_queue: notified_queue_mod.NotifiedQueue = .{},
    auto_move: auto_move_mod.AutoMoveVerifier,
    /// Feeds history_panel.
    notification_history: notification_history_mod.NotificationHistory = .{},
    ghost_overlay: drag_overlays.GhostOverlay,
    /// Shared by dragging and region select.
    hint_box: gdi_overlay.HintBox = .{},
    /// Sole "who's focused" source of truth; write only via reconcileThumbnailStates.
    active_source_hwnd: ?win32.HWND = null,
    auto_minimize: auto_minimize_mod.AutoMinimizer,
    /// Unique system/character colours; lives as long as this Painter, which a profile reload recreates along with Config.
    auto_colors: config_mod.AutoColorStore,
    /// The mode the thumbnails were created for; a different one needs a new Painter (see main.onLiveProfileEdited).
    view_mode: types.ViewMode,

    pub const notify = dispatch.notify;
    pub const notifyAll = dispatch.notifyAll;
    pub const showTestNotification = dispatch.showTest;
    pub const dismissClickSuppressedNotifications = dispatch.dismissClickSuppressed;
    pub const updateNotifications = dispatch.expire;
    pub const refreshAllThumbnailVisuals = arrange.refreshVisuals;
    pub const repositionAllThumbnails = arrange.repositionAll;
    pub const resizeThumbnailIfNeeded = arrange.resizeIfNeeded;
    pub const reflowIfRegionFitActive = arrange.reflowIfRegionFitActive;
    pub const reflowIfThumbnailSpaceActive = arrange.reflowIfThumbnailSpaceActive;

    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore) !Painter {
        const instance = win32.GetModuleHandleA(null) orelse return error.GetModuleHandleFailed;
        const cfg = &store.live;

        var painter: Painter = .{
            .allocator = allocator,
            .thumbnails = .empty,
            .auto_minimize = .init(allocator),
            .auto_colors = .init(allocator),
            .auto_move = .init(allocator),
            .ghost_overlay = .init(allocator),
            .font_cache = .init(allocator),
            .instance = instance,
            .config = cfg,
            .store = store,
            .view_mode = cfg.display.viewMode,
        };

        try window.registerClasses(instance);

        painter.focus_event_hook = win32.setWinEventHook(win32.EVENT_SYSTEM_FOREGROUND, winEventProc);
        if (painter.focus_event_hook == null) slog.err("Failed to set up focus event hook", .{});
        // Own process only: windowDestroyProc acts on our overlay windows alone.
        painter.destroy_event_hook = win32.setWinEventHookForProcess(win32.EVENT_OBJECT_DESTROY, windowDestroyProc, win32.GetCurrentProcessId());
        if (painter.destroy_event_hook == null) slog.err("Failed to set up destroy event hook", .{});

        if (cfg.display.viewMode == .ClientList) {
            painter.list_window = list_view.ListWindow.init(allocator, store, instance) catch |err| blk: {
                slog.err("Failed to create list window: {}", .{err});
                break :blk null;
            };
        }

        painter.history_panel = history_panel_mod.HistoryPanel.init(allocator, store, instance);

        return painter;
    }

    pub fn deinit(self: *Painter) void {
        g_painter_ptr = null;
        // The timer outlives this Painter on the main window, and would otherwise hide the next one's thumbnails.
        self.cancelHideTimer();

        if (self.list_window) |*lw| {
            lw.deinit();
            self.list_window = null;
        }
        self.history_panel.deinit();
        self.font_cache.deinit();

        if (self.focus_event_hook) |hook| _ = win32.UnhookWinEvent(hook);
        if (self.destroy_event_hook) |hook| _ = win32.UnhookWinEvent(hook);

        self.ghost_overlay.deinit();
        self.hint_box.deinit();

        for (self.thumbnails.items) |thumbnail| self.destroyThumbnail(thumbnail);
        self.thumbnails.deinit(self.allocator);
        self.notified_queue.deinit(self.allocator);
        self.auto_move.deinit();
        self.auto_minimize.deinit();
        self.auto_colors.deinit();
    }

    pub fn layout(self: *const Painter) placement.Layout {
        return .{ .config = self.config, .thumbnails = self.thumbnails.items };
    }

    /// Single point for rendering any thumbnail overlay; skips the re-render when RenderSettings haven't changed.
    pub fn renderThumbnail(self: *Painter, thumbnail: *ThumbnailWindow) !void {
        // ClientList mode renders via ListWindow.render() instead.
        if (!thumbnail.win32_enabled) return;
        const settings = overlay.createRenderSettings(self.config, thumbnail, self.active_source_hwnd);

        if (thumbnail.render_cache.settings) |cached| {
            if (overlay.renderSettingsEqual(cached, settings)) return;
            if (overlay.renderSettingsOnlyVisibilityChanged(cached, settings)) {
                thumbnail.show(settings.show_thumbnail);
                thumbnail.render_cache.settings = settings;
                return;
            }
        }

        thumbnail.show(settings.show_thumbnail);
        if (settings.show_thumbnail) try overlay.renderThumbnailOverlay(&self.font_cache, thumbnail, settings, self.config);

        thumbnail.render_cache.settings = settings;
    }

    /// renderThumbnail, logging (not propagating) a failure with context folded into the message.
    pub fn renderThumbnailLogged(self: *Painter, thumbnail: *ThumbnailWindow, context: []const u8) void {
        self.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render thumbnail for '{s}' ({s}): {}", .{ thumbnail.character_name, context, err });
        };
    }

    fn destroyThumbnail(self: *Painter, thumbnail: ThumbnailWindow) void {
        if (thumbnail.win32_enabled) window.destroy(&thumbnail);
        self.freeThumbnailData(thumbnail);
    }

    /// Frees what every ThumbnailWindow owns regardless of mode: its strings and notification stack.
    fn freeThumbnailData(self: *Painter, thumbnail: ThumbnailWindow) void {
        self.allocator.free(thumbnail.character_name);
        self.allocator.free(thumbnail.system_name);
        self.allocator.free(thumbnail.cached_group_badge_label);
        thumbnail.notifications.deinit(self.allocator);
    }

    fn removeThumbnailAt(self: *Painter, index: usize) void {
        self.destroyThumbnail(self.thumbnails.orderedRemove(index));
        if (self.thumbnails.items.len == 0) self.auto_colors.flush();
    }

    pub fn hasThumbnail(self: *const Painter, source_hwnd: win32.HWND) bool {
        return self.indexOfSource(source_hwnd) != null;
    }

    /// Whether `source_hwnd` is a tracked EVE client, not a window filter's window.
    pub fn hasEveClient(self: *const Painter, source_hwnd: win32.HWND) bool {
        const index = self.indexOfSource(source_hwnd) orelse return false;
        return self.thumbnails.items[index].is_eve_client;
    }

    /// Returns whether a reflow is needed to refill the region.
    pub fn cleanupClosedThumbnails(self: *Painter, closed_windows: []const scout.ClosedWindow) bool {
        // By source_hwnd, not name: multiple windows can share a name (e.g. "EVE").
        var removed_any = false;
        for (closed_windows) |cw| {
            const index = self.indexOfSource(cw.hwnd) orelse continue;
            slog.info("Cleaning up closed thumbnail for {s}", .{self.thumbnails.items[index].character_name});
            self.removeThumbnailAt(index);
            removed_any = true;
        }
        return removed_any and placement.isRegionFitActive(&self.config.display);
    }

    fn indexOfSource(self: *const Painter, source_hwnd: win32.HWND) ?usize {
        for (self.thumbnails.items, 0..) |thumbnail, i| {
            if (thumbnail.source_hwnd == source_hwnd) return i;
        }
        return null;
    }

    /// Matches a thumbnail's own window or its text overlay, never a source EVE window.
    fn indexOfOverlay(self: *const Painter, hwnd: win32.HWND) ?usize {
        for (self.thumbnails.items, 0..) |thumbnail, i| {
            // Outside Thumbnails mode the handles are sentinels.
            if (thumbnail.win32_enabled and (thumbnail.hwnd == hwnd or thumbnail.text_hwnd == hwnd)) return i;
        }
        return null;
    }

    /// Don't keep the pointer across anything that adds or removes thumbnails.
    pub fn getThumbnailBySourceHwnd(self: *Painter, source_hwnd: win32.HWND) ?*ThumbnailWindow {
        return &self.thumbnails.items[self.indexOfSource(source_hwnd) orelse return null];
    }

    /// Don't keep the pointer across anything that adds or removes thumbnails.
    pub fn getThumbnailByOverlayHwnd(self: *Painter, hwnd: win32.HWND) ?*ThumbnailWindow {
        return &self.thumbnails.items[self.indexOfOverlay(hwnd) orelse return null];
    }

    /// After the character's group membership changed.
    pub fn refreshGroupBadge(self: *Painter, thumbnail: *ThumbnailWindow) void {
        const new_label = self.config.groupBadgeLabel(self.allocator, thumbnail.character_name) catch |err| {
            slog.err("Failed to build group badge label for '{s}': {}", .{ thumbnail.character_name, err });
            return;
        };
        self.allocator.free(thumbnail.cached_group_badge_label);
        thumbnail.cached_group_badge_label = new_label;
        thumbnail.render_cache.group_badge.dims = null;
    }

    /// Reconciles focus, then marks thumbnails dirty whose minimized state changed.
    pub fn updateThumbnailStates(self: *Painter) void {
        if (self.thumbnails.items.len == 0) return;

        self.reconcileThumbnailStates(win32.GetForegroundWindow());

        for (self.thumbnails.items) |*thumbnail| {
            if (thumbnail_drag.isDragging(thumbnail)) continue;

            const is_minimized = win32.isWindowIconic(thumbnail.source_hwnd);
            if (is_minimized != thumbnail.was_minimized) {
                thumbnail.was_minimized = is_minimized;
                thumbnail.needs_render = true;
            }
        }
    }

    /// Whether the thumbnails count as shown, for the toggle and the tray's checkmark; the first one speaks for all, and none counts as shown.
    pub fn thumbnailsShown(self: *const Painter) bool {
        if (self.thumbnails.items.len == 0) return true;
        return self.thumbnails.items[0].visibility_state == .visible;
    }

    /// The toggle-visibility hotkey and tray item; manual hiding persists through focus changes.
    pub fn toggleAllThumbnailsVisibility(self: *Painter) void {
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

    fn startHideTimer(self: *Painter) void {
        const timer_hwnd = main.g_timer_hwnd orelse return;
        if (win32.SetTimer(timer_hwnd, HIDE_DEBOUNCE_TIMER_ID, self.config.thumbnail.hideDebounceMs, null) == 0) {
            slog.err("Failed to start hide debounce timer", .{});
            return;
        }
        self.hide_timer_pending = true;
    }

    fn cancelHideTimer(self: *Painter) void {
        if (!self.hide_timer_pending) return;
        if (main.g_timer_hwnd) |timer_hwnd| _ = win32.KillTimer(timer_hwnd, HIDE_DEBOUNCE_TIMER_ID);
        self.hide_timer_pending = false;
    }

    /// The hide-debounce timer fired, so no EVE window has had focus for hideDebounceMs.
    pub fn autoHideAfterFocusLoss(self: *Painter) void {
        self.cancelHideTimer();
        slog.debug("Hide debounce timer fired", .{});

        // Checked again, since the setting or focus may have changed while the timer ran.
        const eve_has_focus = self.isEveWindowForeground();
        for (self.thumbnails.items) |*thumbnail| {
            if (self.applyAutoVisibility(thumbnail, eve_has_focus)) self.renderThumbnailLogged(thumbnail, "auto-hide");
        }
    }

    /// The auto-hide rule: hidden while "hide when no EVE window has focus" is on and none has.
    pub fn autoVisibility(self: *const Painter, eve_has_focus: bool) state.VisibilityState {
        return if (self.config.thumbnail.hideWhenNoEveFocus and !eve_has_focus) .hidden_automatic else .visible;
    }

    /// Moves a thumbnail between visible and auto-hidden by autoVisibility, leaving one hidden by hand alone; returns whether it changed.
    pub fn applyAutoVisibility(self: *const Painter, thumbnail: *ThumbnailWindow, eve_has_focus: bool) bool {
        if (thumbnail.visibility_state == .hidden_manual) return false;
        const target = self.autoVisibility(eve_has_focus);
        if (thumbnail.visibility_state == target) return false;
        thumbnail.setVisibility(target);
        return thumbnail.visibility_state == target;
    }

    /// Hides every visible thumbnail, adding the windows it hid to `hidden` so showThumbnails brings back only those, not ones already hidden.
    pub fn hideVisibleThumbnails(self: *Painter, allocator: std.mem.Allocator, hidden: *std.ArrayList(win32.HWND)) void {
        for (self.thumbnails.items) |*thumbnail| {
            if (!thumbnail.isVisible()) continue;
            thumbnail.setVisibility(.hidden_manual);
            // Refused while alerting or dragging.
            if (thumbnail.isVisible()) continue;
            hidden.append(allocator, thumbnail.hwnd) catch |err| {
                slog.err("Failed to remember a hidden thumbnail to show again: {}", .{err});
            };
            self.renderThumbnailLogged(thumbnail, "hide");
        }
    }

    pub fn showThumbnails(self: *Painter, hwnds: []const win32.HWND) void {
        for (hwnds) |hwnd| {
            const thumbnail = self.getThumbnailByOverlayHwnd(hwnd) orelse continue;
            thumbnail.setVisibility(.visible);
            self.renderThumbnailLogged(thumbnail, "show");
        }
    }

    /// Sole writer of active_source_hwnd, the single source of truth for who's focused; call instead of setting it directly.
    pub fn reconcileThumbnailStates(self: *Painter, should_be_active_hwnd: ?win32.HWND) void {
        const old_active = self.active_source_hwnd;
        self.active_source_hwnd = should_be_active_hwnd;
        const active_changed = old_active != should_be_active_hwnd;
        const any_eve_has_focus = if (should_be_active_hwnd) |hwnd| self.hasThumbnail(hwnd) else false;
        if (should_be_active_hwnd) |hwnd| self.auto_minimize.recordFocus(self, hwnd);

        for (self.thumbnails.items) |*thumbnail| {
            // Losing focus hides only after the debounce timer, so only regaining it applies here.
            if (any_eve_has_focus and self.applyAutoVisibility(thumbnail, true)) thumbnail.needs_render = true;

            if (active_changed and (thumbnail.source_hwnd == old_active or thumbnail.source_hwnd == should_be_active_hwnd)) {
                thumbnail.needs_render = true;
            }
        }
    }

    /// `hwnd`, a tracked client, took focus; returns false if focus has already moved on, since focus events can arrive late during rapid cycling.
    pub fn onClientFocused(self: *Painter, hwnd: win32.HWND) bool {
        self.cancelHideTimer();

        const current_foreground = win32.GetForegroundWindow();
        if (current_foreground != hwnd) {
            slog.debug("Ignoring stale focus change (target={*}, current foreground={*})", .{ hwnd, current_foreground });
            return false;
        }

        self.reconcileThumbnailStates(hwnd);
        if (self.getThumbnailBySourceHwnd(hwnd)) |thumbnail| {
            slog.debug("Tracked window focused: {s}", .{thumbnail.character_name});
            hotkeys.syncFocusedCharacter(thumbnail.character_name, hwnd);
        }
        return true;
    }

    pub fn isEveWindowForeground(self: *const Painter) bool {
        const foreground_hwnd = win32.GetForegroundWindow() orelse return false;
        return self.hasThumbnail(foreground_hwnd);
    }

    /// See ThumbnailWindow.system_name_event_ts and .travel for `event_ts` and `is_jump`.
    pub fn updateSystemNameByHwnd(self: *Painter, source_hwnd: win32.HWND, system_name: []const u8, event_ts: u64, is_jump: bool) !void {
        const thumbnail = self.getThumbnailBySourceHwnd(source_hwnd) orelse {
            slog.debug("No thumbnail for window 0x{x} to show system {s}", .{ @intFromPtr(source_hwnd), system_name });
            return;
        };

        if (event_ts != 0 and event_ts < thumbnail.system_name_event_ts) {
            slog.debug("Ignoring stale system update for {s}: {s} (event_ts={} < current={})", .{ thumbnail.character_name, system_name, event_ts, thumbnail.system_name_event_ts });
            return;
        }

        const new_name = try self.allocator.dupe(u8, system_name);
        self.allocator.free(thumbnail.system_name);

        thumbnail.system_name = new_name;
        thumbnail.system_name_event_ts = event_ts;
        thumbnail.cached_system_color = self.auto_colors.systemNameColor(self.config, system_name);
        thumbnail.render_cache.system_name.dims = null;
        slog.debug("System '{s}' color resolved to: 0x{X:0>6}", .{ system_name, thumbnail.cached_system_color & 0xFFFFFF });

        if (is_jump) thumbnail.travel.recordJump();

        thumbnail.needs_render = true;
        slog.debug("Updated system for {s}: {s}", .{ thumbnail.character_name, system_name });
    }

    /// Renders every thumbnail with needs_render set; past `max_immediate`, the rest stay dirty for the next tick.
    pub fn renderDirtyThumbnails(self: *Painter, max_immediate: ?usize) void {
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

    pub fn updateDpsForCharacter(self: *Painter, source_hwnd: win32.HWND, incoming_dps: ?f32, outgoing_dps: ?f32) void {
        const thumbnail = self.getThumbnailBySourceHwnd(source_hwnd) orelse return;
        if (thumbnail.stats.setDps(incoming_dps, outgoing_dps)) thumbnail.needs_render = true;
    }

    pub fn updateMiningForCharacter(self: *Painter, source_hwnd: win32.HWND, rate: ?f32, isk_rate: ?f32) void {
        const thumbnail = self.getThumbnailBySourceHwnd(source_hwnd) orelse return;
        if (thumbnail.stats.setMining(rate, isk_rate)) thumbnail.needs_render = true;
    }

    pub fn updateBountyForCharacter(self: *Painter, source_hwnd: win32.HWND, isk_rate: ?f32) void {
        const thumbnail = self.getThumbnailBySourceHwnd(source_hwnd) orelse return;
        if (thumbnail.stats.setBounty(isk_rate)) thumbnail.needs_render = true;
    }

    /// `has_vram` is false when VRAM sampling isn't available.
    pub fn updateResourceStatsForCharacter(self: *Painter, source_hwnd: win32.HWND, cpu_percent: f32, ram_mb: f32, vram_mb: f32, has_vram: bool) void {
        const thumbnail = self.getThumbnailBySourceHwnd(source_hwnd) orelse return;
        if (thumbnail.stats.setResources(cpu_percent, ram_mb, vram_mb, has_vram)) thumbnail.needs_render = true;
    }

    /// Reacts to Scout's name-change events (logins, logouts, renames); returns whether the layout needs a reflow.
    pub fn applyNameChanges(self: *Painter, name_changes: []const scout.NameChange) bool {
        var any_login = false;
        var any_logout = false;
        for (name_changes) |change| {
            const thumbnail = self.getThumbnailBySourceHwnd(change.hwnd) orelse continue;

            const was_generic = scout.isGenericCharacterName(change.old_name);
            const now_generic = scout.isGenericCharacterName(change.new_name);
            // An unconfigured "EVE" placeholder always sorts last, so either direction can change a thumbnail's RegionFit rank.
            if (was_generic and !now_generic) any_login = true;
            if (now_generic and !was_generic) any_logout = true;

            self.rename(thumbnail, change.new_name) catch |err| {
                slog.err("Failed to rename the thumbnail for '{s}': {}", .{ change.new_name, err });
                continue;
            };

            if (was_generic and !now_generic) self.onLogin(thumbnail);
            if (now_generic) self.onLogout(thumbnail);

            // Cycle cursors are keyed by name and a rename fires no focus event, so the focused window must re-sync under its new one.
            if (win32.GetForegroundWindow() == thumbnail.source_hwnd) {
                hotkeys.syncFocusedCharacter(thumbnail.character_name, thumbnail.source_hwnd);
            }

            self.renderThumbnailLogged(thumbnail, "name change");
            slog.info("Updated thumbnail for {s}", .{thumbnail.character_name});
        }

        // notLoggedInSpace is count-dependent, so crossing its boundary must reflow it regardless of regionFitReorderLoggedOut.
        if (placement.notLoggedInSpaceRectFromConfig(&self.config.display) != null and (any_login or any_logout)) return true;

        return placement.isRegionFitActive(&self.config.display) and (any_login or (any_logout and self.config.display.regionFitReorderLoggedOut));
    }

    /// Keeps the old name if copying fails.
    fn rename(self: *Painter, thumbnail: *ThumbnailWindow, name: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        self.allocator.free(thumbnail.character_name);
        thumbnail.character_name = name_copy;
        thumbnail.render_cache.character_name.dims = null;
        thumbnail.refreshConfigCache(self.config, &self.auto_colors);
        self.refreshGroupBadge(thumbnail);
    }

    /// The client went from the login screen to a character: move it to that character's spots and restore its exclusion.
    fn onLogin(self: *Painter, thumbnail: *ThumbnailWindow) void {
        const name = thumbnail.character_name;
        // RegionFit ignores the saved spot; applyNameChanges' reflow places it instead.
        if (thumbnail.win32_enabled and !placement.isRegionFitActive(&self.config.display)) {
            if (self.config.getCharacterPosition(name)) |saved_pos| {
                thumbnail.moveTo(saved_pos.x, saved_pos.y, null);
                self.resizeThumbnailIfNeeded(thumbnail, null);
                slog.info("Moved {s} thumbnail to saved position: ({}, {})", .{ name, saved_pos.x, saved_pos.y });
            } else {
                slog.debug("No saved thumbnail position for {s}, keeping current location", .{name});
            }
        }

        if (self.config.autoMovePosition.enabled) {
            self.auto_move.moveToSavedPosition(self.config, thumbnail.source_hwnd, name);
        }

        self.refreshExclusion(thumbnail);
    }

    /// Mirrors the character's cycle exclusion onto the thumbnail, which draws it; the only writer of is_excluded_from_cycle.
    pub fn refreshExclusion(self: *Painter, thumbnail: *ThumbnailWindow) void {
        _ = self;
        const is_excluded = exclusions.isExcluded(thumbnail.character_name);
        if (is_excluded == thumbnail.is_excluded_from_cycle) return;
        thumbnail.is_excluded_from_cycle = is_excluded;
        thumbnail.needs_render = true;
    }

    /// The client is back at the login screen: it has no system and its notifications no longer apply.
    /// Moving it into the not-logged-in space happens in applyNameChanges' reflow, which also resizes the others already there.
    fn onLogout(self: *Painter, thumbnail: *ThumbnailWindow) void {
        dispatch.clearAll(self, thumbnail);

        // Owned like any system name, since freeThumbnailData frees it.
        const empty_system = self.allocator.dupe(u8, "") catch |err| {
            slog.err("Failed to clear the system name for '{s}': {}", .{ thumbnail.character_name, err });
            return;
        };
        self.allocator.free(thumbnail.system_name);
        thumbnail.system_name = empty_system;
        thumbnail.cached_system_color = self.config.thumbnail.systemNameColor;
        thumbnail.render_cache.system_name.dims = null;
        slog.debug("Cleared system name for logged out client", .{});
    }

    pub const PopulateOptions = struct {
        /// Moves each new client window to its saved position (auto-move).
        move_to_saved: bool,
        /// Seeds each new thumbnail's system name, so a reload doesn't show them blank.
        system_names: ?*const SystemNameSnapshot = null,
    };

    /// Startup/reload: creates every window's thumbnail, then reflows once, since createThumbnail sizes each one against the count so far.
    pub fn populate(self: *Painter, eve_windows: []const scout.EveWindow, opts: PopulateOptions) void {
        if (self.addMissingThumbnails(eve_windows, opts) and arrange.hasCountDependentLayout(self)) self.repositionAllThumbnails();
    }

    /// Creates a thumbnail for each window not yet tracked, logging and skipping failures; returns whether any were created.
    fn addMissingThumbnails(self: *Painter, eve_windows: []const scout.EveWindow, opts: PopulateOptions) bool {
        var created_new = false;

        for (eve_windows) |eve_window| {
            if (self.hasThumbnail(eve_window.hwnd)) continue;

            const system_name = if (opts.system_names) |names| (names.get(eve_window.hwnd) orelse "") else "";
            self.createThumbnail(&eve_window, system_name) catch |err| {
                slog.err("Failed to create thumbnail for '{s}': {}", .{ eve_window.character_name, err });
                continue;
            };
            created_new = true;

            if (opts.move_to_saved and eve_window.is_eve_client) {
                self.auto_move.moveToSavedPosition(self.config, eve_window.hwnd, eve_window.character_name);
            }
        }

        return created_new;
    }

    pub fn update(self: *Painter, eve_windows: []const scout.EveWindow, closed_windows: []const scout.ClosedWindow, name_changes: []const scout.NameChange) !void {
        var needs_region_reflow = self.cleanupClosedThumbnails(closed_windows);
        self.updateThumbnailStates();
        self.auto_minimize.check(self);
        needs_region_reflow = self.applyNameChanges(name_changes) or needs_region_reflow;
        self.auto_move.verify(self.config);

        // createThumbnail seeds character_name from eve_window, so new thumbnails need no re-sync.
        const created_new = self.addMissingThumbnails(eve_windows, .{ .move_to_saved = self.config.autoMovePosition.enabled });
        needs_region_reflow = (created_new and arrange.hasCountDependentLayout(self)) or needs_region_reflow;

        // Coalesced into one reflow, since any combination of the three triggers above can fire in the same tick.
        if (needs_region_reflow) self.repositionAllThumbnails();

        self.renderDirtyThumbnails(null);

        if (self.list_window) |*lw| {
            lw.render(self.thumbnails.items, self.active_source_hwnd) catch |err| {
                slog.err("Failed to render list window: {}", .{err});
            };
        }

        self.history_panel.update(self, self.anyCharacterLoggedIn());
    }

    /// Whether any client is past the login screen.
    pub fn anyCharacterLoggedIn(self: *const Painter) bool {
        for (self.thumbnails.items) |thumbnail| {
            if (!scout.isGenericCharacterName(thumbnail.character_name)) return true;
        }
        return false;
    }

    /// Tray menu's checked state for "Show History Panel".
    pub fn isHistoryPanelVisible(self: *const Painter) bool {
        return self.history_panel.isVisible(self.config, self.anyCharacterLoggedIn());
    }

    /// Applies the panel settings only read when a panel is created, for a change made in the config dialog.
    pub fn syncPanels(self: *Painter) void {
        self.history_panel.sync(self.allocator, self.store, self.instance);
        if (self.list_window) |*list| list.sync();
    }

    /// Tray menu's "Show History Panel" item.
    pub fn toggleHistoryPanel(self: *Painter) void {
        self.history_panel.toggle(self.allocator, self.store, self.instance, self.anyCharacterLoggedIn());
    }

    const ThumbnailStrings = struct {
        character_name: []const u8,
        system_name: []const u8,
        group_badge_label: []const u8,
    };

    /// Dupes the three owned strings a ThumbnailWindow needs; on partial failure, whatever already succeeded is freed before the error propagates.
    fn dupeThumbnailStrings(self: *Painter, character_name: []const u8, system_name: []const u8) !ThumbnailStrings {
        const allocator = self.allocator;
        const char_name_copy = try allocator.dupe(u8, character_name);
        errdefer allocator.free(char_name_copy);
        const sys_name_copy = try allocator.dupe(u8, system_name);
        errdefer allocator.free(sys_name_copy);
        const group_badge_label_copy = try self.config.groupBadgeLabel(allocator, character_name);
        errdefer allocator.free(group_badge_label_copy);

        return .{
            .character_name = char_name_copy,
            .system_name = sys_name_copy,
            .group_badge_label = group_badge_label_copy,
        };
    }

    /// The data record both creation paths share; the caller supplies the window handles (sentinels outside Thumbnails mode) and owns the result's strings.
    fn newThumbnailRecord(self: *Painter, eve_window: *const scout.EveWindow, initial_system_name: []const u8, handles: window.Handles, win32_enabled: bool) !ThumbnailWindow {
        const strings = try self.dupeThumbnailStrings(eve_window.character_name, initial_system_name);
        var thumbnail = ThumbnailWindow{
            .hwnd = handles.hwnd,
            .text_hwnd = handles.text_hwnd,
            .thumbnail_id = handles.thumbnail_id,
            .source_hwnd = eve_window.hwnd,
            .is_eve_client = eve_window.is_eve_client,
            .character_name = strings.character_name,
            .system_name = strings.system_name,
            .cached_group_badge_label = strings.group_badge_label,
            .auto_minimize = .{ .inactive_since = win32.Ticks.now() },
            // The new client isn't tracked yet, so isEveWindowForeground alone would miss it.
            .visibility_state = self.autoVisibility(win32.GetForegroundWindow() == eve_window.hwnd or self.isEveWindowForeground()),
            .win32_enabled = win32_enabled,
        };
        thumbnail.refreshConfigCache(self.config, &self.auto_colors);
        self.refreshExclusion(&thumbnail);
        return thumbnail;
    }

    /// Reconciles focus afterwards, since the new client's window may already be the foreground one.
    fn addThumbnail(self: *Painter, thumbnail: ThumbnailWindow) !void {
        try self.thumbnails.append(self.allocator, thumbnail);

        const foreground_hwnd = win32.GetForegroundWindow();
        self.reconcileThumbnailStates(foreground_hwnd);
        if (foreground_hwnd == thumbnail.source_hwnd) hotkeys.syncFocusedCharacter(thumbnail.character_name, thumbnail.source_hwnd);
    }

    /// ClientList and Nothing modes only need a data record, not real Win32 windows.
    fn createTrackingOnlyEntry(self: *Painter, eve_window: *const scout.EveWindow, initial_system_name: []const u8) !void {
        // Never passed to Win32, since win32_enabled is false.
        const sentinel: win32.HWND = @ptrFromInt(1);
        const thumbnail = try self.newThumbnailRecord(eve_window, initial_system_name, .{ .hwnd = sentinel, .text_hwnd = sentinel, .thumbnail_id = sentinel }, false);
        errdefer self.freeThumbnailData(thumbnail);
        try self.addThumbnail(thumbnail);

        slog.info("Created tracking entry for {s} ({s} mode)", .{ eve_window.character_name, @tagName(self.config.display.viewMode) });
    }

    fn createThumbnail(self: *Painter, eve_window: *const scout.EveWindow, initial_system_name: []const u8) !void {
        if (self.config.display.viewMode != .Thumbnails) {
            return self.createTrackingOnlyEntry(eve_window, initial_system_name);
        }

        const name = eve_window.character_name;
        const total_count = self.thumbnails.items.len + 1;
        const monitor_placement = monitors.resolveMonitorPlacement(&self.config.display);
        const monitor_bounds = if (monitor_placement) |mp| mp.bounds else null;
        const scale = win32.dpiToScale(monitors.dpiForMonitor(if (monitor_placement) |mp| mp.monitor else null));
        const size = arrange.targetSize(self, name, total_count, null, scale);
        const pos = self.layout().calculateThumbnailPosition(name, size.width, size.height, self.thumbnails.items.len, total_count, monitor_bounds, scale);

        const handles = try window.create(self.allocator, self.instance, eve_window.hwnd, name, pos, size, self.config.getCharacterOpacity(name), self.config.interaction.clickThrough);
        errdefer window.destroyHandles(handles);

        var thumbnail = try self.newThumbnailRecord(eve_window, initial_system_name, handles, true);
        errdefer self.freeThumbnailData(thumbnail);
        try self.renderThumbnail(&thumbnail);
        errdefer thumbnail.render_cache.deinit();
        window.showText(handles, pos, size);

        try self.addThumbnail(thumbnail);

        slog.info("Created thumbnail for {s}", .{name});
    }

    /// Saves where the thumbnail with window `hwnd` now sits.
    pub fn saveThumbnailPosition(self: *Painter, hwnd: win32.HWND) void {
        const thumbnail = self.getThumbnailByOverlayHwnd(hwnd) orelse return;
        const entry = positionOf(thumbnail) orelse return;
        self.store.setCharacterPositions(&.{entry});
    }

    /// After a group drag: every thumbnail's position, in one profile write.
    pub fn saveAllThumbnailPositions(self: *Painter) void {
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

    fn positionOf(thumbnail: *const ThumbnailWindow) ?config_mod.ProfileStore.CharacterPosition {
        if (!thumbnail.win32_enabled) return null;
        var rect: win32.RECT = undefined;
        if (win32.GetWindowRect(thumbnail.hwnd, &rect) == 0) return null;
        return .{ .name = thumbnail.character_name, .pos = .{ .x = rect.left, .y = rect.top } };
    }
};

pub var g_painter_ptr: ?*Painter = null;

fn windowDestroyProc(_: win32.HANDLE, _: win32.DWORD, hwnd: win32.HWND, _: win32.LONG, _: win32.LONG, _: win32.DWORD, _: win32.DWORD) callconv(.c) void {
    const painter = g_painter_ptr orelse return;
    // Only our own windows: a source EVE window closing is Scout's to report (see cleanupClosedThumbnails).
    const index = painter.indexOfOverlay(hwnd) orelse return;
    slog.info("Window closed (event), removing thumbnail for {s}", .{painter.thumbnails.items[index].character_name});
    painter.removeThumbnailAt(index);
}

fn winEventProc(_: win32.HANDLE, _: win32.DWORD, hwnd: win32.HWND, _: win32.LONG, _: win32.LONG, _: win32.DWORD, _: win32.DWORD) callconv(.c) void {
    const painter = g_painter_ptr orelse return;

    if (painter.indexOfOverlay(hwnd) != null) {
        slog.debug("Thumbnail window got focus (ignoring): {*}", .{hwnd});
        return;
    }

    // A newly-foregrounded topmost window gets inserted above ours in the z-order band; push back unless it's shell UI allowed to stay on top.
    const ex_style = win32.GetWindowLongPtrA(hwnd, win32.GWL_EXSTYLE);
    if (ex_style & win32.WS_EX_TOPMOST != 0 and !win32.isExplorerOwned(hwnd)) {
        arrange.reassertTopmost(painter);
    }

    if (!painter.hasThumbnail(hwnd)) {
        if (!win32.isOwnProcessWindow(hwnd) and !win32.isDesktopShellWindow(hwnd)) {
            hotkeys.recordNonEveForeground(hwnd);
        }

        if (painter.config.thumbnail.hideWhenNoEveFocus) {
            slog.debug("Untracked window focused (hwnd={*}), starting {}ms debounce timer (hideWhenNoEveFocus=true)", .{ hwnd, painter.config.thumbnail.hideDebounceMs });
            painter.startHideTimer();
        } else {
            slog.debug("Untracked window focused (hwnd={*}), ignoring (hideWhenNoEveFocus=false)", .{hwnd});
        }
        return;
    }

    _ = painter.onClientFocused(hwnd);
}
