//! Owns the thumbnail for every tracked EVE client: keeps the set in step with Scout, tracks focus and visibility, and renders them each tick.
const std = @import("std");
const win32 = @import("platform/win32.zig");
const gdi_overlay = @import("platform/gdi_overlay.zig");
const thumbnail_drag = @import("drag/thumbnail.zig");
const config_mod = @import("config.zig");
const state_mod = @import("state.zig");
const notification_history_mod = @import("notifications/history.zig");
const notified_queue_mod = @import("notifications/notified_queue.zig");
const dispatch = @import("notifications/dispatch.zig");
const auto_minimize_mod = @import("clients/auto_minimize.zig");
const auto_move_mod = @import("clients/auto_move.zig");
const hotkeys_mod = @import("hotkeys/manager.zig");
const drag_overlays_mod = @import("drag/overlays.zig");
const scout_mod = @import("clients/scout.zig");
const list_view = @import("list_view.zig");
const history_panel_mod = @import("notifications/history_panel.zig");
const window_mod = @import("thumbnail/window.zig");
const arrange = @import("thumbnail/arrange.zig");
const overlay_mod = @import("thumbnail/overlay.zig");
const font_cache_mod = @import("thumbnail/font_cache.zig");
const placement_mod = @import("layout/placement.zig");
const monitors_mod = @import("layout/monitors.zig");
const log = @import("log.zig");
const slog = log.scoped("painter");

pub const ThumbnailWindow = window_mod.ThumbnailWindow;

/// Timer on the first thumbnail window that auto-hides every thumbnail once no EVE window has had focus for hideDebounceMs.
pub const HIDE_DEBOUNCE_TIMER_ID: usize = 1;

pub var g_painter_ptr: ?*Painter = null;

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
    thumbnails: std.ArrayList(ThumbnailWindow),
    // source_hwnd → index, for O(1) lookups.
    hwnd_to_thumbnail_index: std.AutoHashMap(win32.HWND, usize),
    // thumbnail.hwnd → index, for O(1) lookups.
    thumbnail_hwnd_to_index: std.AutoHashMap(win32.HWND, usize),
    // thumbnail.text_hwnd → index, for O(1) lookups.
    text_hwnd_to_index: std.AutoHashMap(win32.HWND, usize),
    last_hwnd_index_rebuild: win32.Ticks = .{},
    instance: win32.HINSTANCE,
    /// Read-only, so every runtime change goes through `store` and reaches both the running and the saved copy.
    config: *const config_mod.Config,
    store: *config_mod.ProfileStore,
    focus_event_hook: ?win32.HANDLE = null,
    destroy_event_hook: ?win32.HANDLE = null,
    hide_debounce_timer_hwnd: ?win32.HWND = null,
    font_cache: font_cache_mod.FontCache,
    /// Non-null when viewMode == .ClientList; owns the compact list panel window.
    list_window: ?list_view.ListWindow = null,
    history_panel: history_panel_mod.HistoryPanel = .{},
    notified_queue: notified_queue_mod.NotifiedQueue = .{},
    /// Thumbnails hideThumbnailsForRegionSelect hid, so restoreThumbnailsAfterRegionSelect only re-shows exactly those (not ones already manually hidden beforehand).
    region_select_hidden_hwnds: std.ArrayList(win32.HWND) = .empty,
    auto_move: auto_move_mod.AutoMoveVerifier,
    /// Feeds history_panel.
    notification_history: notification_history_mod.NotificationHistory = .{},
    ghost_overlay: drag_overlays_mod.GhostOverlay,
    /// Shared by dragging and region select.
    hint_box: gdi_overlay.HintBox = .{},
    /// Sole "who's focused" source of truth; write only via reconcileThumbnailStates.
    active_source_hwnd: ?win32.HWND = null,
    auto_minimize: auto_minimize_mod.AutoMinimizer,
    /// Unique system/character colours; lives as long as this Painter, which a profile reload recreates along with Config.
    auto_colors: config_mod.AutoColorStore,

    pub const notify = dispatch.notify;
    pub const notifyAll = dispatch.notifyAll;
    pub const showTestNotification = dispatch.showTest;
    pub const dismissClickSuppressedNotifications = dispatch.dismissClickSuppressed;
    pub const updateNotifications = dispatch.expire;
    pub const refreshAllThumbnailVisuals = arrange.refreshVisuals;
    pub const repositionAllThumbnails = arrange.repositionAll;
    pub const resizeThumbnailIfNeeded = arrange.resizeIfNeeded;
    pub const reflowIfRegionFitActive = arrange.reflowIfRegionFitActive;

    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore) !Painter {
        const instance = win32.GetModuleHandleA(null) orelse return error.GetModuleHandleFailed;
        const cfg = &store.live;

        var painter: Painter = .{
            .allocator = allocator,
            .thumbnails = .empty,
            .hwnd_to_thumbnail_index = std.AutoHashMap(win32.HWND, usize).init(allocator),
            .auto_minimize = .init(allocator),
            .auto_colors = .init(allocator),
            .auto_move = .init(allocator),
            .ghost_overlay = .init(allocator),
            .thumbnail_hwnd_to_index = std.AutoHashMap(win32.HWND, usize).init(allocator),
            .text_hwnd_to_index = std.AutoHashMap(win32.HWND, usize).init(allocator),
            .font_cache = .init(allocator),
            .instance = instance,
            .config = cfg,
            .store = store,
        };

        try window_mod.registerClasses(instance);

        painter.focus_event_hook = win32.setWinEventHook(win32.EVENT_SYSTEM_FOREGROUND, winEventProc);

        if (painter.focus_event_hook == null) {
            slog.err("Failed to set up focus event hook", .{});
        }

        painter.destroy_event_hook = win32.setWinEventHook(win32.EVENT_OBJECT_DESTROY, windowDestroyProc);

        if (painter.destroy_event_hook == null) {
            slog.err("Failed to set up destroy event hook", .{});
        }

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

        // Destroy list window first (before unhooking events)
        if (self.list_window) |*lw| {
            lw.deinit();
            self.list_window = null;
        }

        self.history_panel.deinit();

        self.font_cache.deinit();

        if (self.focus_event_hook) |hook| {
            _ = win32.UnhookWinEvent(hook);
        }
        if (self.destroy_event_hook) |hook| {
            _ = win32.UnhookWinEvent(hook);
        }

        self.ghost_overlay.deinit();
        self.hint_box.deinit();

        for (self.thumbnails.items) |thumbnail| {
            self.destroyThumbnail(thumbnail);
        }
        self.thumbnails.deinit(self.allocator);
        self.notified_queue.deinit(self.allocator);
        self.region_select_hidden_hwnds.deinit(self.allocator);
        self.auto_move.deinit();
        self.hwnd_to_thumbnail_index.deinit();
        self.auto_minimize.deinit();
        self.thumbnail_hwnd_to_index.deinit();
        self.text_hwnd_to_index.deinit();
        self.auto_colors.deinit();
    }

    pub fn layout(self: *const Painter) placement_mod.Layout {
        return .{ .config = self.config, .thumbnails = self.thumbnails.items };
    }

    /// Single point for rendering any thumbnail overlay; skips the re-render when RenderSettings haven't changed.
    pub fn renderThumbnail(self: *Painter, thumbnail: *ThumbnailWindow) !void {
        // ClientList mode renders via ListWindow.render() instead; Nothing mode renders nothing
        if (!thumbnail.win32_enabled) return;
        const settings = overlay_mod.createRenderSettings(self.config, thumbnail, self.active_source_hwnd);

        if (thumbnail.render_cache.settings) |cached| {
            if (overlay_mod.renderSettingsEqual(cached, settings)) {
                return;
            }

            // Only visibility changed? Just show/hide windows without re-rendering
            if (overlay_mod.renderSettingsOnlyVisibilityChanged(cached, settings)) {
                thumbnail.show(settings.show_thumbnail);
                thumbnail.render_cache.settings = settings;
                return;
            }
        }

        thumbnail.show(settings.show_thumbnail);
        if (settings.show_thumbnail) try overlay_mod.renderThumbnailOverlay(&self.font_cache, thumbnail, settings, self.config);

        thumbnail.render_cache.settings = settings;
    }

    /// renderThumbnail, logging (not propagating) a failure with context folded into the message.
    pub fn renderThumbnailLogged(self: *Painter, thumbnail: *ThumbnailWindow, context: []const u8) void {
        self.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render thumbnail for {s} ({s}): {}", .{ thumbnail.character_name, context, err });
        };
    }

    fn destroyThumbnail(self: *Painter, thumbnail: ThumbnailWindow) void {
        if (thumbnail.win32_enabled) window_mod.destroy(&thumbnail);
        self.freeThumbnailData(thumbnail);
    }

    /// Frees what every ThumbnailWindow owns regardless of mode: its strings and notification stack.
    fn freeThumbnailData(self: *Painter, thumbnail: ThumbnailWindow) void {
        self.allocator.free(thumbnail.title);
        self.allocator.free(thumbnail.character_name);
        self.allocator.free(thumbnail.system_name);
        self.allocator.free(thumbnail.cached_group_badge_label);
        thumbnail.notifications.deinit(self.allocator);
    }

    /// Drops the thumbnail at `index` from the list and lookup maps and destroys it. Later entries' indices shift, so callers run finishRemovals once they're done.
    fn removeThumbnailAt(self: *Painter, index: usize) void {
        const thumbnail = self.thumbnails.orderedRemove(index);
        _ = self.hwnd_to_thumbnail_index.remove(thumbnail.source_hwnd);
        _ = self.thumbnail_hwnd_to_index.remove(thumbnail.hwnd);
        _ = self.text_hwnd_to_index.remove(thumbnail.text_hwnd);
        self.destroyThumbnail(thumbnail);
    }

    fn finishRemovals(self: *Painter) void {
        self.rebuildHwndIndex(false);
        if (self.thumbnails.items.len == 0) self.auto_colors.flush();
    }

    pub fn hasThumbnail(self: *const Painter, source_hwnd: win32.HWND) bool {
        return self.hwnd_to_thumbnail_index.contains(source_hwnd);
    }

    /// Remove thumbnails whose source / related windows are gone (defensive cleanup)
    pub fn cleanupClosedThumbnails(self: *Painter, closed_windows: []const scout_mod.ClosedWindow) bool {
        // By source_hwnd, not name: multiple windows can share a name (e.g. "EVE").
        var removed_any = false;
        for (closed_windows) |cw| {
            var i: usize = 0;
            while (i < self.thumbnails.items.len) {
                const thumbnail = self.thumbnails.items[i];
                if (thumbnail.source_hwnd == cw.hwnd) {
                    slog.info("Cleaning up closed thumbnail for {s}", .{thumbnail.character_name});
                    self.removeThumbnailAt(i);
                    removed_any = true;
                    break;
                }
                i += 1;
            }
        }

        if (removed_any) self.finishRemovals();

        // A logout must reflow the survivors to refill the region.
        return removed_any and placement_mod.isRegionFitActive(&self.config.display);
    }

    /// Rebuilds all HWND → index mappings; call after removing thumbnails to keep indices consistent. `force` bypasses the rate limit when the caller needs a correct index immediately.
    fn rebuildHwndIndex(self: *Painter, force: bool) void {
        const now = win32.Ticks.now();
        if (!force and now.elapsedSince(self.last_hwnd_index_rebuild) < 100) {
            slog.debug("Skipping HWND index rebuild (rate limited: {}ms since last rebuild)", .{now.elapsedSince(self.last_hwnd_index_rebuild)});
            return;
        }

        self.last_hwnd_index_rebuild = now;
        slog.debug("Rebuilding HWND index for {} thumbnails...", .{self.thumbnails.items.len});

        self.hwnd_to_thumbnail_index.clearRetainingCapacity();
        self.thumbnail_hwnd_to_index.clearRetainingCapacity();
        self.text_hwnd_to_index.clearRetainingCapacity();
        for (self.thumbnails.items, 0..) |*thumbnail, index| {
            self.hwnd_to_thumbnail_index.put(thumbnail.source_hwnd, index) catch |err| {
                slog.err("Failed to rebuild HWND index for {s}: {}", .{ thumbnail.character_name, err });
            };
            // Thumbnail / text window HWNDs only exist in Thumbnails view mode
            if (thumbnail.win32_enabled) {
                self.thumbnail_hwnd_to_index.put(thumbnail.hwnd, index) catch |err| {
                    slog.err("Failed to rebuild thumbnail HWND index for {s}: {}", .{ thumbnail.character_name, err });
                };
                self.text_hwnd_to_index.put(thumbnail.text_hwnd, index) catch |err| {
                    slog.err("Failed to rebuild text HWND index for {s}: {}", .{ thumbnail.character_name, err });
                };
            }
        }
    }

    /// Resolves hwnd to its thumbnails[] index; only matches Painter's own thumbnail/text windows, since a source EVE window closing is Scout's call (closed_windows -> cleanupClosedThumbnails).
    fn resolveThumbnailIndexForDestroy(self: *Painter, hwnd: win32.HWND) ?usize {
        const raw_index = self.thumbnail_hwnd_to_index.get(hwnd) orelse
            self.text_hwnd_to_index.get(hwnd) orelse return null;

        if (raw_index < self.thumbnails.items.len) {
            const candidate = self.thumbnails.items[raw_index];
            if (candidate.hwnd == hwnd or candidate.text_hwnd == hwnd) {
                return raw_index;
            }
        }

        self.rebuildHwndIndex(true);
        const retry_index = self.thumbnail_hwnd_to_index.get(hwnd) orelse
            self.text_hwnd_to_index.get(hwnd) orelse return null;
        if (retry_index >= self.thumbnails.items.len) return null;

        const candidate = self.thumbnails.items[retry_index];
        if (candidate.hwnd == hwnd or candidate.text_hwnd == hwnd) {
            return retry_index;
        }
        return null;
    }

    /// Gets a thumbnail by source EVE window HWND with O(1) lookup; rebuilds the index and retries once if the entry is stale.
    pub fn getThumbnailBySourceHwnd(self: *Painter, source_hwnd: win32.HWND) ?*ThumbnailWindow {
        const index = self.hwnd_to_thumbnail_index.get(source_hwnd) orelse return null;

        if (index < self.thumbnails.items.len) {
            const thumbnail = &self.thumbnails.items[index];
            if (thumbnail.source_hwnd == source_hwnd) {
                return thumbnail;
            }
        }

        slog.warn("HWND index mismatch for 0x{x} at index {}. Rebuilding index...", .{ @intFromPtr(source_hwnd), index });

        // Force past the rate limit: a mismatch means the map is stale right now, not just due for its next routine rebuild.
        self.rebuildHwndIndex(true);
        const retry_index = self.hwnd_to_thumbnail_index.get(source_hwnd) orelse return null;
        if (retry_index >= self.thumbnails.items.len) return null;

        const thumbnail = &self.thumbnails.items[retry_index];
        if (thumbnail.source_hwnd == source_hwnd) return thumbnail;
        return null;
    }

    /// Resolved fresh each call so a cached pointer can't dangle across a reallocation.
    pub fn getThumbnailByOverlayHwnd(self: *Painter, hwnd: win32.HWND) ?*ThumbnailWindow {
        const index = self.thumbnail_hwnd_to_index.get(hwnd) orelse self.text_hwnd_to_index.get(hwnd) orelse return null;
        if (index >= self.thumbnails.items.len) return null;
        const thumbnail = &self.thumbnails.items[index];
        if (thumbnail.hwnd == hwnd or thumbnail.text_hwnd == hwnd) return thumbnail;
        return null;
    }

    /// Comma-joined names of the badge-enabled groups `character_name` belongs to; "" when none.
    fn buildGroupBadgeLabel(self: *Painter, character_name: []const u8) ![]const u8 {
        var label_buf = std.ArrayList(u8).empty;
        defer label_buf.deinit(self.allocator);

        for (self.config.hotkeyGroups.items, 0..) |*group, index| {
            if (!group.showBadge) continue;

            var is_member = false;
            for (group.characters.items) |char_name| {
                if (std.mem.eql(u8, char_name, character_name)) {
                    is_member = true;
                    break;
                }
            }
            if (!is_member) continue;

            if (label_buf.items.len > 0) {
                try label_buf.appendSlice(self.allocator, ", ");
            }
            if (group.name.len > 0) {
                try label_buf.appendSlice(self.allocator, group.name);
            } else {
                var index_buf: [20]u8 = undefined;
                const index_str = try std.fmt.bufPrint(&index_buf, "{}", .{index + 1});
                try label_buf.appendSlice(self.allocator, index_str);
            }
        }

        return self.allocator.dupe(u8, label_buf.items);
    }

    /// Recompute and cache a thumbnail's group badge label after its membership changed.
    pub fn refreshGroupBadge(self: *Painter, thumbnail: *ThumbnailWindow) void {
        const new_label = self.buildGroupBadgeLabel(thumbnail.character_name) catch |err| {
            slog.err("Failed to build group badge label for {s}: {}", .{ thumbnail.character_name, err });
            return;
        };
        self.allocator.free(thumbnail.cached_group_badge_label);
        thumbnail.cached_group_badge_label = new_label;
        thumbnail.render_cache.group_badge.dims = null;
    }

    /// Reconciles focus, then marks thumbnails dirty whose minimized state changed; call periodically from the timer.
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

    /// Toggle all thumbnails between hidden and visible, preserving active/inactive state (hotkey action).
    pub fn toggleAllThumbnailsVisibility(self: *Painter) void {
        if (self.thumbnails.items.len == 0) {
            slog.debug("No thumbnails to toggle visibility", .{});
            return;
        }

        const first_vis = self.thumbnails.items[0].visibility_state;
        const new_visibility: state_mod.VisibilityState = if (first_vis == .Visible)
            .HiddenManual
        else
            .Visible;

        slog.info("Toggling all thumbnails visibility: {}", .{new_visibility});

        // Toggle all thumbnails (manual hiding persists through focus changes)
        for (self.thumbnails.items) |*thumbnail| {
            thumbnail.setVisibility(new_visibility);

            self.renderThumbnailLogged(thumbnail, "visibility toggle");
        }
    }

    /// The hide-debounce timer fired on `timer_hwnd`: no EVE window has focus, so auto-hide every visible thumbnail (re-shown once EVE regains focus).
    pub fn autoHideAfterFocusLoss(self: *Painter, timer_hwnd: win32.HWND) void {
        _ = win32.KillTimer(timer_hwnd, HIDE_DEBOUNCE_TIMER_ID);
        self.hide_debounce_timer_hwnd = null;
        slog.debug("Hide debounce timer fired, hiding all thumbnails", .{});

        for (self.thumbnails.items) |*thumbnail| {
            if (thumbnail.visibility_state != .Visible) continue;
            thumbnail.setVisibility(.HiddenAutomatic);
            self.renderThumbnailLogged(thumbnail, "auto-hide");
        }
    }

    /// Hides every currently-visible thumbnail so it doesn't obscure the "Start Region Selection" overlay.
    pub fn hideThumbnailsForRegionSelect(self: *Painter) void {
        self.region_select_hidden_hwnds.clearRetainingCapacity();
        for (self.thumbnails.items) |*thumbnail| {
            if (!thumbnail.isVisible()) continue;
            thumbnail.setVisibility(.HiddenManual);
            if (thumbnail.isVisible()) continue; // setVisibility silently refused (alerting/dragging) - nothing to restore later.
            self.region_select_hidden_hwnds.append(self.allocator, thumbnail.hwnd) catch |err| {
                slog.err("Failed to record thumbnail for region-select restore: {}", .{err});
            };
            self.renderThumbnailLogged(thumbnail, "region select hide");
        }
    }

    /// Restores visibility for thumbnails hideThumbnailsForRegionSelect hid.
    pub fn restoreThumbnailsAfterRegionSelect(self: *Painter) void {
        for (self.region_select_hidden_hwnds.items) |hwnd| {
            const thumbnail = self.getThumbnailByOverlayHwnd(hwnd) orelse continue;
            thumbnail.setVisibility(.Visible);
            self.renderThumbnailLogged(thumbnail, "region select restore");
        }
        self.region_select_hidden_hwnds.clearRetainingCapacity();
    }

    /// Sole writer of active_source_hwnd, the single source of truth for who's focused; call instead of setting it directly.
    pub fn reconcileThumbnailStates(self: *Painter, should_be_active_hwnd: ?win32.HWND) void {
        const old_active = self.active_source_hwnd;
        self.active_source_hwnd = should_be_active_hwnd;
        const active_changed = old_active != should_be_active_hwnd;
        const any_eve_has_focus = if (should_be_active_hwnd) |hwnd| self.hasThumbnail(hwnd) else false;
        if (any_eve_has_focus) self.auto_minimize.recordFocus(should_be_active_hwnd.?);

        for (self.thumbnails.items) |*thumbnail| {
            // Unhide automatically-hidden thumbnails when EVE gains focus; manual hiding persists until the user toggles visibility.
            if (thumbnail.visibility_state == .HiddenAutomatic and any_eve_has_focus) {
                thumbnail.setVisibility(.Visible);
                thumbnail.needs_render = true;
            }

            if (active_changed and (thumbnail.source_hwnd == old_active or thumbnail.source_hwnd == should_be_active_hwnd)) {
                thumbnail.needs_render = true;
            }
        }
    }

    pub fn isEveWindowForeground(self: *const Painter) bool {
        const foreground_hwnd = win32.GetForegroundWindow() orelse return false;
        return self.hasThumbnail(foreground_hwnd);
    }

    /// Updates system name for a character using HWND (O(1) lookup); see ThumbnailWindow.system_name_event_ts and .travel for `event_ts`/`is_jump`.
    pub fn updateSystemNameByHwnd(self: *Painter, source_hwnd: win32.HWND, system_name: []const u8, event_ts: u64, is_jump: bool) !void {
        const thumbnail = self.getThumbnailBySourceHwnd(source_hwnd) orelse blk: {
            // Window not found on first attempt - defensively rebuild HWND index and retry
            slog.debug("Window 0x{x} not found for system update, rebuilding HWND index...", .{@intFromPtr(source_hwnd)});
            self.rebuildHwndIndex(true);

            if (self.getThumbnailBySourceHwnd(source_hwnd)) |thumb| {
                slog.info("Successfully found window 0x{x} after index rebuild for {s}", .{ @intFromPtr(source_hwnd), thumb.character_name });
                break :blk thumb;
            }

            slog.warn("Window 0x{x} not found even after index rebuild (thumbnail may not exist)", .{@intFromPtr(source_hwnd)});
            slog.debug("Currently tracking {} thumbnails:", .{self.thumbnails.items.len});
            for (self.thumbnails.items) |*thumb| {
                slog.debug("  - {s}: source_hwnd=0x{x}", .{ thumb.character_name, @intFromPtr(thumb.source_hwnd) });
            }
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

    /// Renders every thumbnail with needs_render set. If max_immediate is given and more thumbnails
    /// than that are dirty, renders only up to the cap now and leaves the rest dirty for the timer.
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
    pub fn applyNameChanges(self: *Painter, name_changes: []const scout_mod.NameChange, eve_windows: []const scout_mod.EveWindow) bool {
        var any_login = false;
        var any_logout = false;
        for (name_changes) |change| {
            const thumbnail = self.getThumbnailBySourceHwnd(change.hwnd) orelse continue;

            const was_generic = scout_mod.isGenericCharacterName(change.old_name);
            const now_generic = scout_mod.isGenericCharacterName(change.new_name);
            // An unconfigured "EVE" placeholder always sorts last, so either direction can change a thumbnail's RegionFit rank.
            if (was_generic and !now_generic) any_login = true;
            if (now_generic and !was_generic) any_logout = true;

            var title: []const u8 = change.new_name;
            for (eve_windows) |w| {
                if (w.hwnd == change.hwnd) {
                    title = w.title;
                    break;
                }
            }
            self.rename(thumbnail, change.new_name, title) catch |err| {
                slog.err("Failed to rename the thumbnail for {s}: {}", .{ change.new_name, err });
                continue;
            };

            if (was_generic and !now_generic) self.onLogin(thumbnail);
            if (now_generic) self.onLogout(thumbnail);

            // Cycle cursors are keyed by name and a rename fires no focus event, so the focused window must re-sync under its new one.
            if (win32.GetForegroundWindow() == thumbnail.source_hwnd) {
                hotkeys_mod.syncFocusedCharacter(thumbnail.character_name, thumbnail.source_hwnd);
            }

            self.renderThumbnailLogged(thumbnail, "name change");
            slog.info("Updated thumbnail for {s}", .{thumbnail.character_name});
        }

        // notLoggedInSpace is count-dependent, so crossing its boundary must reflow it regardless of regionFitReorderLoggedOut.
        if (placement_mod.notLoggedInSpaceRectFromConfig(&self.config.display) != null and (any_login or any_logout)) return true;

        return placement_mod.isRegionFitActive(&self.config.display) and (any_login or (any_logout and self.config.display.regionFitReorderLoggedOut));
    }

    /// Takes `name` and `title`, keeping the old ones if copying fails.
    fn rename(self: *Painter, thumbnail: *ThumbnailWindow, name: []const u8, title: []const u8) !void {
        const title_copy = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_copy);
        const name_copy = try self.allocator.dupe(u8, name);

        self.allocator.free(thumbnail.title);
        self.allocator.free(thumbnail.character_name);
        thumbnail.title = title_copy;
        thumbnail.character_name = name_copy;
        thumbnail.render_cache.character_name.dims = null;
        thumbnail.refreshConfigCache(self.config, &self.auto_colors);
        self.refreshGroupBadge(thumbnail);
    }

    /// The client went from the login screen to a character: move it to that character's spots and restore its exclusion.
    fn onLogin(self: *Painter, thumbnail: *ThumbnailWindow) void {
        const name = thumbnail.character_name;
        // RegionFit ignores the saved spot; applyNameChanges' reflow places it instead.
        if (thumbnail.win32_enabled and !placement_mod.isRegionFitActive(&self.config.display)) {
            if (self.config.getCharacterPosition(name)) |saved_pos| {
                _ = win32.SetWindowPos(thumbnail.hwnd, win32.HWND_NOTOPMOST, saved_pos.x, saved_pos.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
                _ = win32.SetWindowPos(thumbnail.text_hwnd, win32.HWND_TOPMOST, saved_pos.x, saved_pos.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
                self.resizeThumbnailIfNeeded(thumbnail, null);
                slog.info("Moved {s} thumbnail to saved position: ({}, {})", .{ name, saved_pos.x, saved_pos.y });
            } else {
                slog.debug("No saved thumbnail position for {s}, keeping current location", .{name});
            }
        }

        if (self.config.autoMovePosition.enabled) {
            self.auto_move.moveToSavedPosition(self.config, thumbnail.source_hwnd, name);
        }

        const is_excluded = hotkeys_mod.isExcludedFromCycle(name);
        if (is_excluded != thumbnail.is_excluded_from_cycle) {
            thumbnail.is_excluded_from_cycle = is_excluded;
            if (is_excluded) slog.info("Restored exclusion state for {s}", .{name});
        }
    }

    /// The client is back at the login screen: it has no system and its notifications no longer apply.
    /// Moving it into the not-logged-in space happens in applyNameChanges' reflow, which also resizes the others already there.
    fn onLogout(self: *Painter, thumbnail: *ThumbnailWindow) void {
        dispatch.clearAll(self, thumbnail);

        // Owned like any system name, since freeThumbnailData frees it.
        const empty_system = self.allocator.dupe(u8, "") catch |err| {
            slog.err("Failed to clear the system name for {s}: {}", .{ thumbnail.character_name, err });
            return;
        };
        self.allocator.free(thumbnail.system_name);
        thumbnail.system_name = empty_system;
        thumbnail.cached_system_color = self.config.thumbnail.systemNameColor;
        thumbnail.render_cache.system_name.dims = null;
        slog.debug("Cleared system name for logged out client", .{});
    }

    /// Syncs thumbnail title text against Scout's latest scan, independent of character-name changes.
    fn syncThumbnailTitles(self: *Painter, eve_windows: []const scout_mod.EveWindow) void {
        for (eve_windows) |eve_window| {
            const thumbnail = self.getThumbnailBySourceHwnd(eve_window.hwnd) orelse continue;
            if (std.mem.eql(u8, thumbnail.title, eve_window.title)) continue;

            const new_title_dup = self.allocator.dupe(u8, eve_window.title) catch {
                slog.err("Failed to allocate title for {s}", .{eve_window.character_name});
                continue;
            };
            self.allocator.free(thumbnail.title);
            thumbnail.title = new_title_dup;
        }
    }

    pub const PopulateOptions = struct {
        /// Moves each new client window to its saved position (auto-move).
        move_to_saved: bool,
        /// Seeds each new thumbnail's system name, so a reload doesn't show them blank.
        system_names: ?*const SystemNameSnapshot = null,
    };

    /// Startup/reload: creates every window's thumbnail, then reflows once, since createThumbnail sizes each one against the count so far.
    pub fn populate(self: *Painter, eve_windows: []const scout_mod.EveWindow, opts: PopulateOptions) void {
        if (self.addMissingThumbnails(eve_windows, opts) and arrange.hasCountDependentLayout(self)) self.repositionAllThumbnails();
    }

    /// Creates a thumbnail for each window not yet tracked, logging and skipping failures; returns whether any were created.
    fn addMissingThumbnails(self: *Painter, eve_windows: []const scout_mod.EveWindow, opts: PopulateOptions) bool {
        var created_new = false;

        for (eve_windows) |eve_window| {
            if (self.hasThumbnail(eve_window.hwnd)) continue;

            const system_name = if (opts.system_names) |names| (names.get(eve_window.hwnd) orelse "") else "";
            self.createThumbnail(&eve_window, system_name) catch |err| {
                slog.err("Failed to create thumbnail for {s}: {}", .{ eve_window.character_name, err });
                continue;
            };
            created_new = true;

            if (opts.move_to_saved) {
                self.auto_move.moveToSavedPosition(self.config, eve_window.hwnd, eve_window.character_name);
            }
        }

        return created_new;
    }

    /// Main update cycle - performs all Painter operations for a single tick
    pub fn update(self: *Painter, eve_windows: []const scout_mod.EveWindow, closed_windows: []const scout_mod.ClosedWindow, name_changes: []const scout_mod.NameChange) !void {
        var needs_region_reflow = self.cleanupClosedThumbnails(closed_windows);
        self.updateThumbnailStates();
        self.auto_minimize.check(self);
        needs_region_reflow = self.applyNameChanges(name_changes, eve_windows) or needs_region_reflow;
        self.auto_move.verify(self.config);
        self.syncThumbnailTitles(eve_windows);

        // createThumbnail seeds title/character_name from eve_window, so new thumbnails need no re-sync.
        const created_new = self.addMissingThumbnails(eve_windows, .{ .move_to_saved = self.config.autoMovePosition.enabled });
        needs_region_reflow = (created_new and arrange.hasCountDependentLayout(self)) or needs_region_reflow;

        // Coalesced into one reflow, since any combination of the three triggers above can fire in the same tick.
        if (needs_region_reflow) self.repositionAllThumbnails();

        // Thumbnail-mode only — ClientList has no Win32 windows to redraw here.
        self.renderDirtyThumbnails(null);

        if (self.list_window) |*lw| {
            lw.render(self.thumbnails.items, self.active_source_hwnd) catch |err| {
                slog.err("Failed to render list window: {}", .{err});
            };
        }

        self.history_panel.update(self, self.anyCharacterLoggedIn());
    }

    /// True when at least one tracked EVE client currently has a real (non-generic) character name, i.e. is logged in.
    pub fn anyCharacterLoggedIn(self: *const Painter) bool {
        for (self.thumbnails.items) |thumbnail| {
            if (!scout_mod.isGenericCharacterName(thumbnail.character_name)) return true;
        }
        return false;
    }

    /// Tray menu's checked state for "Show History Panel".
    pub fn isHistoryPanelVisible(self: *const Painter) bool {
        return self.history_panel.isVisible(self.config, self.anyCharacterLoggedIn());
    }

    /// Tray menu's "Show History Panel" item.
    pub fn toggleHistoryPanel(self: *Painter) void {
        self.history_panel.toggle(self.allocator, self.store, self.instance, self.anyCharacterLoggedIn());
    }

    fn determineInitialVisibility(
        self: *const Painter,
        source_hwnd: win32.HWND,
    ) state_mod.VisibilityState {
        // source_hwnd isn't tracked yet, so isEveWindowForeground alone would miss it.
        const any_eve_has_focus = win32.GetForegroundWindow() == source_hwnd or self.isEveWindowForeground();

        return if (self.config.thumbnail.hideWhenNoEveFocus and !any_eve_has_focus)
            .HiddenAutomatic
        else
            .Visible;
    }

    const ThumbnailStrings = struct {
        title: []const u8,
        character_name: []const u8,
        system_name: []const u8,
        group_badge_label: []const u8,
    };

    /// Dupes the four owned strings a ThumbnailWindow needs; on partial failure, whatever already succeeded is freed before the error propagates.
    fn dupeThumbnailStrings(self: *Painter, title: []const u8, character_name: []const u8, system_name: []const u8) !ThumbnailStrings {
        const allocator = self.allocator;
        const title_copy = try allocator.dupe(u8, title);
        errdefer allocator.free(title_copy);
        const char_name_copy = try allocator.dupe(u8, character_name);
        errdefer allocator.free(char_name_copy);
        const sys_name_copy = try allocator.dupe(u8, system_name);
        errdefer allocator.free(sys_name_copy);
        const group_badge_label_copy = try self.buildGroupBadgeLabel(character_name);
        errdefer allocator.free(group_badge_label_copy);

        return .{
            .title = title_copy,
            .character_name = char_name_copy,
            .system_name = sys_name_copy,
            .group_badge_label = group_badge_label_copy,
        };
    }

    /// The data record both creation paths share; the caller supplies the window handles (sentinels outside Thumbnails mode) and owns the result's strings.
    fn newThumbnailRecord(self: *Painter, eve_window: *const scout_mod.EveWindow, initial_system_name: []const u8, handles: window_mod.Handles, win32_enabled: bool) !ThumbnailWindow {
        const strings = try self.dupeThumbnailStrings(eve_window.title, eve_window.character_name, initial_system_name);
        var thumbnail = ThumbnailWindow{
            .hwnd = handles.hwnd,
            .text_hwnd = handles.text_hwnd,
            .thumbnail_id = handles.thumbnail_id,
            .source_hwnd = eve_window.hwnd,
            .title = strings.title,
            .character_name = strings.character_name,
            .system_name = strings.system_name,
            .cached_group_badge_label = strings.group_badge_label,
            .auto_minimize = .{ .inactive_since = win32.Ticks.now() },
            .visibility_state = self.determineInitialVisibility(eve_window.hwnd),
            .is_excluded_from_cycle = hotkeys_mod.isExcludedFromCycle(eve_window.character_name),
            .win32_enabled = win32_enabled,
        };
        thumbnail.refreshConfigCache(self.config, &self.auto_colors);
        return thumbnail;
    }

    /// Appends and indexes a fully built thumbnail, then reconciles focus since its window may already be the foreground one.
    fn addThumbnail(self: *Painter, thumbnail: ThumbnailWindow) !void {
        try self.thumbnails.append(self.allocator, thumbnail);
        // Keeps a failed put() below from leaving a freed/destroyed entry behind in the list.
        errdefer _ = self.thumbnails.pop();
        const new_index = self.thumbnails.items.len - 1;
        try self.hwnd_to_thumbnail_index.put(thumbnail.source_hwnd, new_index);
        // Thumbnail / text window HWNDs only exist in Thumbnails view mode.
        if (thumbnail.win32_enabled) {
            try self.thumbnail_hwnd_to_index.put(thumbnail.hwnd, new_index);
            try self.text_hwnd_to_index.put(thumbnail.text_hwnd, new_index);
        }

        const foreground_hwnd = win32.GetForegroundWindow();
        self.reconcileThumbnailStates(foreground_hwnd);
        if (foreground_hwnd == thumbnail.source_hwnd) hotkeys_mod.syncFocusedCharacter(thumbnail.character_name, thumbnail.source_hwnd);
    }

    /// ClientList and Nothing modes only need a data record, not real Win32 windows.
    fn createTrackingOnlyEntry(self: *Painter, eve_window: *const scout_mod.EveWindow, initial_system_name: []const u8) !void {
        // Sentinel HWND, never passed to Win32 APIs since win32_enabled is false.
        const sentinel: win32.HWND = @ptrFromInt(1);
        const thumbnail = try self.newThumbnailRecord(eve_window, initial_system_name, .{ .hwnd = sentinel, .text_hwnd = sentinel, .thumbnail_id = sentinel }, false);
        errdefer self.freeThumbnailData(thumbnail);
        try self.addThumbnail(thumbnail);

        slog.info("Created tracking entry for {s} ({s} mode)", .{ eve_window.character_name, @tagName(self.config.display.viewMode) });
    }

    fn createThumbnail(self: *Painter, eve_window: *const scout_mod.EveWindow, initial_system_name: []const u8) !void {
        if (self.config.display.viewMode != .Thumbnails) {
            return self.createTrackingOnlyEntry(eve_window, initial_system_name);
        }

        const name = eve_window.character_name;
        const total_count = self.thumbnails.items.len + 1;
        const monitor_placement = monitors_mod.resolveMonitorPlacement(&self.config.display);
        const monitor_bounds = if (monitor_placement) |mp| mp.bounds else null;
        const scale = win32.dpiToScale(monitors_mod.dpiForMonitor(if (monitor_placement) |mp| mp.monitor else null));
        const size = arrange.targetSize(self, name, total_count, null, scale);
        const pos = self.layout().calculateThumbnailPosition(name, size.width, size.height, self.thumbnails.items.len, total_count, monitor_bounds, scale);

        const handles = try window_mod.create(self.allocator, self.instance, eve_window.hwnd, name, pos, size, self.config.getCharacterOpacity(name), self.config.interaction.clickThrough);
        errdefer window_mod.destroyHandles(handles);

        var thumbnail = try self.newThumbnailRecord(eve_window, initial_system_name, handles, true);
        errdefer self.freeThumbnailData(thumbnail);
        try self.renderThumbnail(&thumbnail);
        errdefer thumbnail.render_cache.deinit();
        window_mod.showText(handles, pos, size);

        try self.addThumbnail(thumbnail);

        slog.info("Created thumbnail for {s}", .{name});
    }

    pub fn saveThumbnailPosition(self: *Painter, hwnd: win32.HWND) void {
        if (!win32.isWindow(hwnd)) return;

        const thumbnail = self.getThumbnailByOverlayHwnd(hwnd) orelse return;

        var rect: win32.RECT = undefined;
        _ = win32.GetWindowRect(hwnd, &rect);

        self.store.setCharacterPosition(thumbnail.character_name, .{ .x = rect.left, .y = rect.top });
    }
};

fn windowDestroyProc(_: win32.HANDLE, _: win32.DWORD, hwnd: win32.HWND, _: win32.LONG, _: win32.LONG, _: win32.DWORD, _: win32.DWORD) callconv(.c) void {
    const painter = g_painter_ptr orelse return;

    const index = painter.resolveThumbnailIndexForDestroy(hwnd) orelse return;

    slog.info("Window closed (event), removing thumbnail for {s}", .{painter.thumbnails.items[index].character_name});
    painter.removeThumbnailAt(index);
    painter.finishRemovals();
}

fn winEventProc(_: win32.HANDLE, _: win32.DWORD, hwnd: win32.HWND, _: win32.LONG, _: win32.LONG, _: win32.DWORD, _: win32.DWORD) callconv(.c) void {
    const painter = g_painter_ptr orelse return;

    // O(1) lookup: Check if it's one of our thumbnail windows (early exit - most common case)
    if (painter.thumbnail_hwnd_to_index.contains(hwnd) or painter.text_hwnd_to_index.contains(hwnd)) {
        slog.debug("Thumbnail window got focus (ignoring): {*}", .{hwnd});
        return;
    }

    // A newly-foregrounded topmost window gets inserted above ours in the z-order band; push back unless it's shell UI allowed to stay on top.
    const ex_style = win32.GetWindowLongPtrA(hwnd, win32.GWL_EXSTYLE);
    if (ex_style & win32.WS_EX_TOPMOST != 0 and !win32.isExplorerOwned(hwnd)) {
        arrange.reassertTopmost(painter);
    }

    const is_eve_window = painter.hasThumbnail(hwnd);

    if (!is_eve_window) {
        if (!win32.isOwnProcessWindow(hwnd) and !win32.isDesktopShellWindow(hwnd)) {
            hotkeys_mod.recordNonEveForeground(hwnd);
        }

        if (painter.config.thumbnail.hideWhenNoEveFocus) {
            slog.debug("Untracked window focused (hwnd={*}), starting {}ms debounce timer (hideWhenNoEveFocus=true)", .{ hwnd, painter.config.thumbnail.hideDebounceMs });
            // Only use thumbnail HWNDs in thumbnail mode (list mode has no valid thumbnail HWNDs)
            if (painter.thumbnails.items.len > 0 and painter.thumbnails.items[0].win32_enabled) {
                const timer_hwnd = painter.thumbnails.items[0].hwnd;
                if (win32.SetTimer(timer_hwnd, HIDE_DEBOUNCE_TIMER_ID, painter.config.thumbnail.hideDebounceMs, null) != 0) {
                    painter.hide_debounce_timer_hwnd = timer_hwnd;
                } else {
                    slog.err("Failed to start hide debounce timer", .{});
                }
            }
        } else {
            slog.debug("Untracked window focused (hwnd={*}), ignoring (hideWhenNoEveFocus=false)", .{hwnd});
        }
        return;
    }

    // Cancel any pending hide timer since an EVE window now has focus
    if (painter.hide_debounce_timer_hwnd) |timer_hwnd| {
        _ = win32.KillTimer(timer_hwnd, HIDE_DEBOUNCE_TIMER_ID);
        painter.hide_debounce_timer_hwnd = null;
        slog.debug("Cancelled hide debounce timer (tracked window focused)", .{});
    }

    // WINEVENT_OUTOFCONTEXT delivery can lag well behind the actual focus change; during rapid
    // cycling a stale event can arrive after focus has already moved on again, so drop it rather
    // than reconciling the active border back to a target that's no longer current.
    const current_foreground = win32.GetForegroundWindow();
    if (current_foreground != hwnd) {
        slog.debug("Ignoring stale focus event (event hwnd={*}, current foreground={*})", .{ hwnd, current_foreground });
        return;
    }

    painter.reconcileThumbnailStates(hwnd);

    if (painter.getThumbnailBySourceHwnd(hwnd)) |thumbnail| {
        slog.debug("Tracked window focused: {s}", .{thumbnail.character_name});
        hotkeys_mod.syncFocusedCharacter(thumbnail.character_name, hwnd);
    }
}
