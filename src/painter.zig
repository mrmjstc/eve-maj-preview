const std = @import("std");
const win32 = @import("platform/win32.zig");
const input = @import("input.zig");
const activation = @import("clients/activation.zig");
const thumbnail_drag = @import("drag/thumbnail.zig");
const config_mod = @import("config.zig");
const state_mod = @import("state.zig");
const notification_mod = @import("notifications/notification.zig");
const notification_history_mod = @import("notifications/history.zig");
const notification_stack_mod = @import("notifications/stack.zig");
const notified_queue_mod = @import("notifications/notified_queue.zig");
const auto_minimize_mod = @import("clients/auto_minimize.zig");
const auto_move_mod = @import("clients/auto_move.zig");
const travel_left_behind = @import("travel/left_behind.zig");
const hotkeys_mod = @import("hotkeys/manager.zig");
const drag_overlays_mod = @import("drag/overlays.zig");
const scout_mod = @import("clients/scout.zig");
const list_view = @import("list_view.zig");
const history_panel_mod = @import("notifications/history_panel.zig");
const gdi_overlay = @import("platform/gdi_overlay.zig");
const region_select = @import("region_select.zig");
const protocol = @import("protocol.zig");
const log = @import("log.zig");
const slog = log.scoped("painter");
const alert_effects = @import("notifications/alert_effects.zig");
const overlay_mod = @import("thumbnail/overlay.zig");
const font_cache_mod = @import("thumbnail/font_cache.zig");
const placement_mod = @import("layout/placement.zig");
const monitors_mod = @import("layout/monitors.zig");

const WINDOW_CLASS_NAME = "EVE_THUMBNAIL_CLASS";
const TEXT_WINDOW_CLASS_NAME = "EVE_TEXT_OVERLAY_CLASS";
/// Timer on the first thumbnail window that auto-hides every thumbnail once no EVE window has had focus for hideDebounceMs.
pub const HIDE_DEBOUNCE_TIMER_ID: usize = 1;

const ThumbnailState = state_mod.ThumbnailState;

const TEST_NOTIFICATION_PERMANENT_FALLBACK_MS: u32 = 5000;

const NOTIFICATION_TEXT_MAX: usize = 128;

pub const ThumbnailWindow = struct {
    hwnd: win32.HWND,
    // Layered window used for both the text overlay and the border.
    text_hwnd: win32.HWND,
    thumbnail_id: win32.HTHUMBNAIL,
    source_hwnd: win32.HWND,
    title: []const u8,
    character_name: []const u8,
    system_name: []const u8,
    // In-game timestamp of the event that set system_name (YYYYMMDD*1000000+HHMMSS); 0 = untimestamped source (e.g. live tailing), which always applies.
    system_name_event_ts: u64 = 0,
    travel: travel_left_behind.LeftBehindState = .{},
    notifications: notification_stack_mod.NotificationStack = .{},
    last_click_time: win32.Ticks = .{},
    is_excluded_from_cycle: bool = false,
    needs_render: bool = false,
    win32_enabled: bool = true,

    // Null means not enough span yet to trust a rate (see activity/tracker.zig).
    last_incoming_dps: ?f32 = null,
    last_outgoing_dps: ?f32 = null,
    last_mining_rate: ?f32 = null,
    last_mining_isk_rate: ?f32 = null,
    last_bounty_isk_rate: ?f32 = null,
    last_cpu_percent: f32 = 0.0,
    last_ram_mb: f32 = 0.0,
    last_vram_mb: f32 = 0.0,

    // False until the tracker's first push actually arrives; distinguishes "never heard from the tracker yet" (show nothing) from a genuine null rate the tracker reported (show "??"), since both look identical as `null` otherwise.
    has_dps_data: bool = false,
    has_mining_data: bool = false,
    has_bounty_data: bool = false,
    // has_vram_data is separate: VRAM can stay unavailable (no PDH support, no matching GPU instance) even once CPU/RAM are known.
    has_resource_data: bool = false,
    has_vram_data: bool = false,

    render_cache: overlay_mod.RenderCache = .{},

    visibility_state: state_mod.VisibilityState = .Visible,
    /// Set while a Test Notification has force-shown a hidden thumbnail; restored once its notifications clear.
    test_restore_visibility: ?state_mod.VisibilityState = null,
    auto_minimize: auto_minimize_mod.AutoMinimizeState,
    /// Edge-detector so a minimize/restore with no accompanying focus change still marks this dirty for repaint.
    was_minimized: bool = false,

    // Config-derived per-character values, set only by refreshConfigCache: resolved on character_name change or (re)creation rather than every tick (list_view.zig hashes these every ~50ms per thumbnail, createRenderSettings reads them per dirty thumbnail).
    cached_system_color: u32 = 0,
    // Auto-generated per-character name color; null when "Unique Character Name Colors" is disabled, and callers fall back to their own default.
    cached_character_color: ?u32 = null,
    cached_display_name: []const u8 = "",
    cached_border_colors: ?config_mod.CharacterBorderColorsConfig = null,
    cached_excluded_from_minimize: bool = false,
    cached_hide_thumbnail: bool = false,
    cached_thumbnail_size: ?config_mod.CharacterThumbnailSizeConfig = null,
    cached_opacity: u8 = 255,
    // Owned, comma-joined label of the badge-enabled groups this character is in ("1, 3"); "" = none.
    cached_group_badge_label: []const u8,

    /// Re-resolves every config-derived cached_* field (except the owned group badge label) for the current character_name/system_name.
    pub fn refreshConfigCache(self: *ThumbnailWindow, config: *const config_mod.Config, auto_colors: *config_mod.AutoColorStore) void {
        self.cached_system_color = if (self.system_name.len > 0) auto_colors.systemNameColor(config, self.system_name) else config.thumbnail.systemNameColor;
        self.cached_character_color = auto_colors.characterNameColor(config, self.character_name);
        self.cached_display_name = config.getDisplayName(self.character_name);
        self.cached_border_colors = auto_colors.characterBorderColors(config, self.character_name);
        self.cached_excluded_from_minimize = config.isExcludedFromMinimize(self.character_name);
        self.cached_hide_thumbnail = config.isThumbnailHidden(self.character_name);
        self.cached_thumbnail_size = config.getCharacterSize(self.character_name);
        self.cached_opacity = config.getCharacterOpacity(self.character_name);
    }

    /// Whether this thumbnail's source_hwnd is the live "who's focused" pointer.
    pub fn isFocused(self: *const ThumbnailWindow, active_source_hwnd: ?win32.HWND) bool {
        return self.source_hwnd == active_source_hwnd;
    }

    /// The single canonical "what should this render/style as" computation. The returned ThumbnailState
    /// is used purely as a style-lookup key (config.zig's getStateConfig) - never stored back onto the thumbnail.
    pub fn effectiveRenderState(self: *const ThumbnailWindow, active_source_hwnd: ?win32.HWND) ThumbnailState {
        if (thumbnail_drag.isDragging(self)) return .Dragging;
        if (!self.notifications.isEmpty()) return .Alert;
        if (self.isFocused(active_source_hwnd)) return .Active;
        if (win32.isWindowIconic(self.source_hwnd)) return .Minimized;
        return .Inactive;
    }

    /// Sets visibility state, silently failing via tryTransitionVisibility if invalid.
    pub fn setVisibility(self: *ThumbnailWindow, new_visibility: state_mod.VisibilityState) void {
        const blocks_hiding = !self.notifications.isEmpty() or thumbnail_drag.isDragging(self);
        if (new_visibility != .Visible and blocks_hiding) {
            slog.warn("Cannot hide {s} while alerting/dragging", .{self.character_name});
            return;
        }

        const transitioned_visibility = state_mod.tryTransitionVisibility(
            self.visibility_state,
            new_visibility,
            self.character_name,
        );

        self.visibility_state = transitioned_visibility;
    }

    pub fn isVisible(self: *const ThumbnailWindow) bool {
        return self.visibility_state.isVisible();
    }
};

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

// Global so registration persists across Painter instances, not just one.
var g_window_class_registered: bool = false;

pub const Painter = struct {
    allocator: std.mem.Allocator,
    thumbnails: std.ArrayList(ThumbnailWindow),
    hwnd_to_thumbnail_index: std.AutoHashMap(win32.HWND, usize),
    // thumbnail.hwnd → index, for O(1) lookups.
    thumbnail_hwnd_to_index: std.AutoHashMap(win32.HWND, usize),
    // thumbnail.text_hwnd → index, for O(1) lookups.
    text_hwnd_to_index: std.AutoHashMap(win32.HWND, usize),
    last_hwnd_index_rebuild: win32.Ticks = .{},
    instance: win32.HINSTANCE,
    config: *config_mod.Config,
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
    hint_box: gdi_overlay.HintBox = .{},
    /// Sole "who's focused" source of truth; write only via reconcileThumbnailStates.
    active_source_hwnd: ?win32.HWND = null,
    auto_minimize: auto_minimize_mod.AutoMinimizer,
    /// Unique system/character colours; lives as long as this Painter, which a profile reload recreates along with Config.
    auto_colors: config_mod.AutoColorStore,

    pub fn init(allocator: std.mem.Allocator, cfg: *config_mod.Config) !Painter {
        const instance = win32.GetModuleHandleA(null) orelse return error.GetModuleHandleFailed;

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
        };

        try painter.registerWindowClass();

        painter.focus_event_hook = win32.setWinEventHook(win32.EVENT_SYSTEM_FOREGROUND, winEventProc);

        if (painter.focus_event_hook == null) {
            slog.err("Failed to set up focus event hook", .{});
        }

        painter.destroy_event_hook = win32.setWinEventHook(win32.EVENT_OBJECT_DESTROY, windowDestroyProc);

        if (painter.destroy_event_hook == null) {
            slog.err("Failed to set up destroy event hook", .{});
        }

        if (cfg.display.viewMode == .ClientList) {
            painter.list_window = list_view.ListWindow.init(allocator, cfg, instance) catch |err| blk: {
                slog.err("Failed to create list window: {}", .{err});
                break :blk null;
            };
        }

        painter.history_panel = history_panel_mod.HistoryPanel.init(allocator, cfg, instance);

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
            self.destroyThumbnailResources(thumbnail);
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
                showThumbnailWindows(thumbnail, settings.show_thumbnail);
                thumbnail.render_cache.settings = settings;
                return;
            }
        }

        showThumbnailWindows(thumbnail, settings.show_thumbnail);
        if (settings.show_thumbnail) try overlay_mod.renderThumbnailOverlay(&self.font_cache, thumbnail, settings, self.config);

        thumbnail.render_cache.settings = settings;
    }

    /// renderThumbnail, logging (not propagating) a failure with context folded into the message.
    fn renderThumbnailLogged(self: *Painter, thumbnail: *ThumbnailWindow, context: []const u8) void {
        self.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render thumbnail for {s} ({s}): {}", .{ thumbnail.character_name, context, err });
        };
    }

    /// Destroys all resources for a single thumbnail; child windows and the DWM thumbnail must go before the parent window.
    fn destroyThumbnailResources(self: *Painter, thumbnail: ThumbnailWindow) void {
        if (thumbnail.win32_enabled) {
            // GDI resources must be freed before window destruction.
            thumbnail.render_cache.deinit();

            _ = win32.DestroyWindow(thumbnail.text_hwnd);
            _ = win32.DwmUnregisterThumbnail(thumbnail.thumbnail_id);
            _ = win32.DestroyWindow(thumbnail.hwnd);
        }

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
        self.destroyThumbnailResources(thumbnail);
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

    /// Shows `n` on one client's thumbnail, subject to that type's notification settings.
    pub fn notify(self: *Painter, source_hwnd: win32.HWND, n: notification_mod.Notification) void {
        const thumbnail = self.getThumbnailBySourceHwnd(source_hwnd) orelse {
            slog.debug("Window 0x{x} not found for notification update (thumbnail may not exist yet)", .{@intFromPtr(source_hwnd)});
            return;
        };
        var text_buf: [NOTIFICATION_TEXT_MAX]u8 = undefined;
        const text = self.renderText(n, &text_buf);
        const queued = self.queueNotification(thumbnail, text, n.ntype, true) catch |err| {
            slog.err("Failed to show {s} notification for {s}: {}", .{ @tagName(n.ntype), thumbnail.character_name, err });
            return;
        };
        if (!queued) return;

        const spoken_name: ?[]const u8 = if (self.config.thumbnail.notifications.tts_speak_character_name and thumbnail.character_name.len > 0)
            (if (self.config.thumbnail.notifications.tts_use_display_name) thumbnail.cached_display_name else thumbnail.character_name)
        else
            null;
        alert_effects.play(&self.config.thumbnail.notifications, self.config.thumbnail.notifications.getTypeConfig(n.ntype), text, spoken_name);
    }

    /// The single place a notification becomes text; the returned slice may point into `buf`.
    fn renderText(self: *const Painter, n: notification_mod.Notification, buf: *[NOTIFICATION_TEXT_MAX]u8) []const u8 {
        _ = self;
        return notification_mod.defaultText(n, buf);
    }

    /// Applies the type's enable/mute/suppress/throttle rules and queues the notification; false if it was filtered out.
    fn queueNotification(self: *Painter, thumbnail: *ThumbnailWindow, notification_text: []const u8, notification_type: notification_mod.NotificationType, record_history: bool) !bool {
        if (!self.config.thumbnail.notifications.enabled) return false;
        if (self.config.isNotificationMuted(thumbnail.character_name)) return false;

        const type_config = self.config.thumbnail.notifications.getTypeConfig(notification_type);

        if (!type_config.enabled) return false;

        const is_focused = thumbnail.isFocused(self.active_source_hwnd);
        if (type_config.suppress_when_focused and is_focused) {
            return false;
        }

        const now = win32.Ticks.now();

        if (type_config.suppress_when_clicked) {
            if (now.elapsedSince(thumbnail.last_click_time) < self.config.thumbnail.notifications.suppress_click_duration_ms) {
                return false;
            }
        }

        if (thumbnail.notifications.isThrottled(notification_type, type_config.throttle_ms, now)) return false;
        thumbnail.notifications.markShown(notification_type, now);

        self.pushNotification(thumbnail, .fromConfig(try self.allocator.dupe(u8, notification_text), notification_type, type_config, now, type_config.duration_ms));

        // Game events feed the "cycle to recently notified" queue; feedback on the user's own action must not.
        if (!notification_mod.isUserAction(notification_type)) self.notified_queue.track(self.allocator, thumbnail.character_name);
        if (record_history) self.notification_history.push(thumbnail.source_hwnd, thumbnail.character_name, notification_text, notification_type, thumbnail.cached_character_color);

        slog.debug("Queued notification for {s}: [{s}] {s} (border_color_override: {?})", .{ thumbnail.character_name, @tagName(notification_type), notification_text, type_config.border_color });
        return true;
    }

    /// Shows `n` on every thumbnail for a global user action; kept out of history, and sound/speech play once rather than per thumbnail.
    pub fn notifyAll(self: *Painter, n: notification_mod.Notification) void {
        var text_buf: [NOTIFICATION_TEXT_MAX]u8 = undefined;
        const text = self.renderText(n, &text_buf);

        var shown = false;
        for (self.thumbnails.items) |*thumbnail| {
            const queued = self.queueNotification(thumbnail, text, n.ntype, false) catch |err| {
                slog.err("Failed to show {s} notification for {s}: {}", .{ @tagName(n.ntype), thumbnail.character_name, err });
                continue;
            };
            shown = shown or queued;
        }
        if (shown) alert_effects.play(&self.config.thumbnail.notifications, self.config.thumbnail.notifications.getTypeConfig(n.ntype), text, null);
    }

    /// Config dialog's "Test Notification": shows `notification_type` with sample fields, bypasses every suppression, force-shows hidden thumbnails for its duration, and skips history/cycle tracking; alerts play once rather than per thumbnail.
    pub fn showTestNotification(
        self: *Painter,
        notification_type: notification_mod.NotificationType,
        type_config: config_mod.NotificationTypeConfig,
    ) !void {
        var text_buf: [NOTIFICATION_TEXT_MAX]u8 = undefined;
        const notification_text = self.renderText(notification_mod.sample(notification_type), &text_buf);
        const now = win32.Ticks.now();
        // A permanent (0) duration would never clear a test.
        const duration_ms = if (type_config.duration_ms == 0) TEST_NOTIFICATION_PERMANENT_FALLBACK_MS else type_config.duration_ms;

        for (self.thumbnails.items) |*thumbnail| {
            self.pushNotification(thumbnail, .fromConfig(try self.allocator.dupe(u8, notification_text), notification_type, type_config, now, duration_ms));

            // The alert blocks re-hiding, so the thumbnail stays up until updateNotifications() restores it.
            if (!thumbnail.isVisible()) {
                if (thumbnail.test_restore_visibility == null) thumbnail.test_restore_visibility = thumbnail.visibility_state;
                thumbnail.setVisibility(.Visible);
                self.renderThumbnailLogged(thumbnail, "test notification show");
            }
        }

        alert_effects.play(&self.config.thumbnail.notifications, type_config, notification_text, null);
    }

    /// Puts a thumbnail that a Test Notification force-showed back to its prior visibility.
    fn restoreVisibilityAfterTest(self: *Painter, thumbnail: *ThumbnailWindow) void {
        const prior = thumbnail.test_restore_visibility orelse return;
        thumbnail.test_restore_visibility = null;

        // Focus or the setting may have changed during the test, in which case auto-hiding no longer applies.
        const restored: state_mod.VisibilityState = switch (prior) {
            .HiddenAutomatic => if (self.config.thumbnail.hideWhenNoEveFocus and !self.isEveWindowForeground()) .HiddenAutomatic else .Visible,
            else => prior,
        };
        thumbnail.setVisibility(restored);
        self.renderThumbnailLogged(thumbnail, "test notification restore");
    }

    fn isEveWindowForeground(self: *const Painter) bool {
        const foreground_hwnd = win32.GetForegroundWindow() orelse return false;
        return self.hasThumbnail(foreground_hwnd);
    }

    fn pushNotification(self: *Painter, thumbnail: *ThumbnailWindow, entry: notification_stack_mod.ActiveNotification) void {
        thumbnail.notifications.push(self.allocator, entry);
        thumbnail.needs_render = true;
    }

    /// Removes click-dismissable notifications (clients/activation.zig's activate); returns whether anything was removed.
    pub fn dismissClickSuppressedNotifications(self: *Painter, thumbnail: *ThumbnailWindow) bool {
        const removed_any = thumbnail.notifications.dismissClickSuppressed(self.allocator);
        if (removed_any) thumbnail.needs_render = true;
        return removed_any;
    }

    /// Re-applies opacity and forces a redraw (and resize if needed) of every thumbnail from the current config, unconditionally (ignoring needs_render) for main.zig's config-dialog live preview.
    pub fn refreshAllThumbnailVisuals(self: *Painter) void {
        // Re-evaluate focus against the current foreground window here so a live-preview toggle of hideWhenNoEveFocus reacts immediately instead of waiting for the next focus-change WinEvent.
        const any_eve_has_focus = self.isEveWindowForeground();

        const cfg = &self.config.display;
        // region/grid are invariant across every thumbnail this pass; compute once instead of per-thumbnail (see repositionAllThumbnails).
        const region_fit_grid: ?placement_mod.RegionFitGrid = if (placement_mod.isRegionFitActive(cfg)) blk: {
            const region = placement_mod.regionRectFromConfig(cfg).?;
            break :blk placement_mod.calculateRegionFitGrid(region, self.layout().regionFitGridCount(), cfg.spacing, cfg.spacing, self.layout().regionFitAspectRatio(), self.layout().regionFitMaxCellSize(region));
        } else null;

        for (self.thumbnails.items) |*thumbnail| {
            // Must run for every thumbnail, not just win32_enabled ones: list_view.zig reads these cache fields directly.
            thumbnail.refreshConfigCache(self.config, &self.auto_colors);
            self.refreshGroupBadge(thumbnail);
            // RenderSettings' equality check only compares character_name, so it can miss a change to one of the resolved fields above, and a display-name-only edit doesn't touch the font that otherwise triggers re-measurement; this only runs on debounced (~120ms) preview edits.
            thumbnail.render_cache.invalidate();

            if (!thumbnail.win32_enabled) continue;

            if (self.config.thumbnail.hideWhenNoEveFocus and !any_eve_has_focus) {
                if (thumbnail.visibility_state == .Visible) thumbnail.setVisibility(.HiddenAutomatic);
            } else if (thumbnail.visibility_state == .HiddenAutomatic) {
                thumbnail.setVisibility(.Visible);
            }

            // thumbnailOpacity is otherwise only applied once, at window creation time.
            _ = win32.SetLayeredWindowAttributes(thumbnail.hwnd, 0, thumbnail.cached_opacity, win32.LWA_ALPHA);
            win32.setClickThroughStyle(thumbnail.hwnd, self.config.interaction.clickThrough);
            win32.setClickThroughStyle(thumbnail.text_hwnd, self.config.interaction.clickThrough);
            self.resizeThumbnailIfNeeded(thumbnail, region_fit_grid);
            self.renderThumbnailLogged(thumbnail, "visuals refresh");
        }
    }

    /// Re-applies every thumbnail's on-screen position from the current display config, for config-dialog live preview; never touches startX/startY since those can be live-dragged in the running app.
    /// Starts a batched DeferWindowPos sized for every win32_enabled thumbnail (2 windows each: hwnd + text_hwnd); null if there's nothing to move or BeginDeferWindowPos itself fails.
    fn beginDeferForEnabledThumbnails(self: *const Painter) ?win32.HDWP {
        var window_count: c_int = 0;
        for (self.thumbnails.items) |thumbnail| {
            if (thumbnail.win32_enabled) window_count += 2;
        }
        if (window_count == 0) return null;
        return win32.BeginDeferWindowPos(window_count);
    }

    pub fn repositionAllThumbnails(self: *Painter) void {
        var hdwp = self.beginDeferForEnabledThumbnails() orelse return;
        const cfg = &self.config.display;
        const monitor_placement = monitors_mod.resolveMonitorPlacement(cfg);
        const monitor_bounds = if (monitor_placement) |mp| mp.bounds else null;
        const scale = dpiToScale(monitors_mod.dpiForMonitor(if (monitor_placement) |mp| mp.monitor else null));
        const region_fit_active = placement_mod.isRegionFitActive(cfg);
        const not_logged_in_space = placement_mod.notLoggedInSpaceRectFromConfig(cfg);
        const total_count = self.thumbnails.items.len;

        // RegionFit fills in configured-order rank, not raw array position; notLoggedInSpace carves its placeholders out of that rank and count entirely.
        const display_order: ?placement_mod.RegionFitDisplayOrder = if (region_fit_active)
            self.layout().computeRegionFitDisplayOrder(self.allocator, not_logged_in_space != null) catch |err| blk: {
                slog.warn("Failed to compute RegionFit display order: {}", .{err});
                break :blk null;
            }
        else
            null;
        defer if (display_order) |order| self.allocator.free(order.ranks);

        // region/grid are invariant across every thumbnail this pass, so compute them once instead of per-thumbnail (isRegionFitActive guarantees regionRectFromConfig succeeds).
        const region_fit: ?struct { region: win32.RECT, grid: placement_mod.RegionFitGrid } = if (region_fit_active) blk: {
            const region = placement_mod.regionRectFromConfig(cfg).?;
            const grid_count = if (display_order) |order| order.count else total_count;
            break :blk .{ .region = region, .grid = placement_mod.calculateRegionFitGrid(region, grid_count, cfg.spacing, cfg.spacing, self.layout().regionFitAspectRatio(), self.layout().regionFitMaxCellSize(region)) };
        } else null;

        // Own auto-fit grid for not-logged-in placeholders, invariant across the pass just like RegionFit's.
        const not_logged_in: ?struct { space: win32.RECT, grid: placement_mod.RegionFitGrid } = if (not_logged_in_space) |space|
            .{ .space = space, .grid = self.layout().notLoggedInSpaceGrid(space, self.layout().notLoggedInSpaceCount()) }
        else
            null;

        for (self.thumbnails.items, 0..) |thumbnail, index| {
            if (!thumbnail.win32_enabled) continue;
            const carved_out = not_logged_in_space != null and scout_mod.isGenericCharacterName(thumbnail.character_name);

            if (region_fit) |rf| {
                if (!carved_out) {
                    const position_index = if (display_order) |order| order.ranks[index] else index;
                    const pos = placement_mod.regionFitPositionForGrid(rf.region, rf.grid, position_index, cfg.regionFitDirection, cfg.spacing);
                    // DeferWindowPos alone won't update the DWM thumbnail's own destination rect.
                    hdwp = win32.DeferWindowPos(hdwp, thumbnail.hwnd, win32.HWND_NOTOPMOST, pos.x, pos.y, rf.grid.cell_width, rf.grid.cell_height, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE) orelse return;
                    hdwp = win32.DeferWindowPos(hdwp, thumbnail.text_hwnd, win32.HWND_TOPMOST, pos.x, pos.y, rf.grid.cell_width, rf.grid.cell_height, win32.SWP_NOACTIVATE) orelse return;
                    const props = makeThumbnailProps(rf.grid.cell_width, rf.grid.cell_height, win32.DWM_TNP_RECTDESTINATION);
                    _ = win32.DwmUpdateThumbnailProperties(thumbnail.thumbnail_id, &props);
                    continue;
                }
            }

            if (carved_out) {
                const nl = not_logged_in.?;
                const rank = self.layout().notLoggedInIndex(index);
                const pos = placement_mod.regionFitPositionForGrid(nl.space, nl.grid, rank, cfg.regionFitDirection, cfg.notLoggedInSpaceSpacing);
                // May still be sized from a previous RegionFit grid cell, so resize explicitly.
                hdwp = win32.DeferWindowPos(hdwp, thumbnail.hwnd, win32.HWND_NOTOPMOST, pos.x, pos.y, nl.grid.cell_width, nl.grid.cell_height, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE) orelse return;
                hdwp = win32.DeferWindowPos(hdwp, thumbnail.text_hwnd, win32.HWND_TOPMOST, pos.x, pos.y, nl.grid.cell_width, nl.grid.cell_height, win32.SWP_NOACTIVATE) orelse return;
                const props = makeThumbnailProps(nl.grid.cell_width, nl.grid.cell_height, win32.DWM_TNP_RECTDESTINATION);
                _ = win32.DwmUpdateThumbnailProperties(thumbnail.thumbnail_id, &props);
                continue;
            }

            // Plain Custom mode: RegionFit is off and this thumbnail isn't a carved-out placeholder either.
            const thumb_size = self.layout().getThumbnailSize(thumbnail.character_name, total_count, null);
            const width = scalePixels(thumb_size.width, scale);
            const height = scalePixels(thumb_size.height, scale);
            const pos = self.layout().calculateThumbnailPosition(thumbnail.character_name, width, height, index, total_count, monitor_bounds, scale);
            hdwp = win32.DeferWindowPos(hdwp, thumbnail.hwnd, win32.HWND_NOTOPMOST, pos.x, pos.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE) orelse return;
            hdwp = win32.DeferWindowPos(hdwp, thumbnail.text_hwnd, win32.HWND_TOPMOST, pos.x, pos.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOACTIVATE) orelse return;
        }
        _ = win32.EndDeferWindowPos(hdwp);

        if (region_fit_active or not_logged_in != null) {
            // Avoids a one-tick delay before the border catches up to the new cell size.
            for (self.thumbnails.items) |*thumbnail| {
                if (!thumbnail.win32_enabled) continue;
                thumbnail.render_cache.settings = null;
                self.renderThumbnailLogged(thumbnail, "region fit resize");
            }
        }
    }

    /// Resizes a thumbnail's window and DWM rect to the DPI-scaled configured size if changed; text_hwnd resizes separately via UpdateLayeredWindow.
    /// Pass precomputed_grid when called for every thumbnail in a batch (see getThumbnailSize).
    pub fn resizeThumbnailIfNeeded(self: *Painter, thumbnail: *ThumbnailWindow, precomputed_grid: ?placement_mod.RegionFitGrid) void {
        const cfg = &self.config.display;
        const size = self.layout().getThumbnailSize(thumbnail.character_name, self.thumbnails.items.len, precomputed_grid);
        // Grid-fit sizes (RegionFit's or notLoggedInSpace's) are already absolute physical pixels; only the plain default/per-character size needs DPI scaling.
        const target_width, const target_height = if (placement_mod.isRegionFitActive(cfg) or placement_mod.isCarvedOutOfRegionFit(cfg, thumbnail.character_name))
            .{ size.width, size.height }
        else blk: {
            const scale = dpiToScale(monitors_mod.getWindowDpi(thumbnail.hwnd));
            break :blk .{ scalePixels(size.width, scale), scalePixels(size.height, scale) };
        };

        var current_rect: win32.RECT = undefined;
        if (win32.GetClientRect(thumbnail.hwnd, &current_rect) == 0) return;
        const current_width: i32 = @intCast(current_rect.right);
        const current_height: i32 = @intCast(current_rect.bottom);
        if (current_width == target_width and current_height == target_height) return;

        // HWND_NOTOPMOST, not HWND_TOP (a zero-valued sentinel the non-allowzero HWND type can't represent); SWP_NOZORDER makes the value irrelevant anyway.
        _ = win32.SetWindowPos(thumbnail.hwnd, win32.HWND_NOTOPMOST, 0, 0, target_width, target_height, win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);

        const props = makeThumbnailProps(target_width, target_height, win32.DWM_TNP_RECTDESTINATION);
        _ = win32.DwmUpdateThumbnailProperties(thumbnail.thumbnail_id, &props);
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

    /// Re-asserts HWND_TOPMOST z-order for all thumbnail/text windows when another app's topmost window steals it from us.
    fn reassertTopmost(self: *Painter) void {
        // Batched via DeferWindowPos/EndDeferWindowPos so DWM applies the whole z-order change atomically, instead of compositing each intermediate SetWindowPos and flashing thumbnails.
        var hdwp = self.beginDeferForEnabledThumbnails() orelse return;
        for (self.thumbnails.items) |thumbnail| {
            if (!thumbnail.win32_enabled) continue;
            hdwp = win32.DeferWindowPos(hdwp, thumbnail.hwnd, win32.HWND_TOPMOST, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE) orelse return;
            hdwp = win32.DeferWindowPos(hdwp, thumbnail.text_hwnd, win32.HWND_TOPMOST, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE) orelse return;
        }
        _ = win32.EndDeferWindowPos(hdwp);
    }

    /// Updates DPS values for a character's overlay.
    pub fn updateDpsForCharacter(self: *Painter, source_hwnd: win32.HWND, incoming_dps: ?f32, outgoing_dps: ?f32) void {
        if (self.getThumbnailBySourceHwnd(source_hwnd)) |thumbnail| {
            const first_update = !thumbnail.has_dps_data;
            thumbnail.has_dps_data = true;
            if (first_update or thumbnail.last_incoming_dps != incoming_dps or thumbnail.last_outgoing_dps != outgoing_dps) {
                thumbnail.last_incoming_dps = incoming_dps;
                thumbnail.last_outgoing_dps = outgoing_dps;
                thumbnail.needs_render = true;
            }
        }
    }

    /// Updates mining rate (and its ISK/sec twin) for a character's overlay.
    pub fn updateMiningForCharacter(self: *Painter, source_hwnd: win32.HWND, rate: ?f32, isk_rate: ?f32) void {
        if (self.getThumbnailBySourceHwnd(source_hwnd)) |thumbnail| {
            const first_update = !thumbnail.has_mining_data;
            thumbnail.has_mining_data = true;
            if (first_update or thumbnail.last_mining_rate != rate or thumbnail.last_mining_isk_rate != isk_rate) {
                thumbnail.last_mining_rate = rate;
                thumbnail.last_mining_isk_rate = isk_rate;
                thumbnail.needs_render = true;
            }
        }
    }

    /// Updates the bounty ISK/sec rate for a character's overlay.
    pub fn updateBountyForCharacter(self: *Painter, source_hwnd: win32.HWND, isk_rate: ?f32) void {
        if (self.getThumbnailBySourceHwnd(source_hwnd)) |thumbnail| {
            const first_update = !thumbnail.has_bounty_data;
            thumbnail.has_bounty_data = true;
            if (first_update or thumbnail.last_bounty_isk_rate != isk_rate) {
                thumbnail.last_bounty_isk_rate = isk_rate;
                thumbnail.needs_render = true;
            }
        }
    }

    /// Updates per-process CPU%/RAM/VRAM for a character's overlay; `has_vram` is false when VRAM sampling isn't available.
    pub fn updateResourceStatsForCharacter(self: *Painter, source_hwnd: win32.HWND, cpu_percent: f32, ram_mb: f32, vram_mb: f32, has_vram: bool) void {
        if (self.getThumbnailBySourceHwnd(source_hwnd)) |thumbnail| {
            const first_update = !thumbnail.has_resource_data;
            thumbnail.has_resource_data = true;
            if (first_update or
                thumbnail.last_cpu_percent != cpu_percent or
                thumbnail.last_ram_mb != ram_mb or
                thumbnail.last_vram_mb != vram_mb or
                thumbnail.has_vram_data != has_vram)
            {
                thumbnail.last_cpu_percent = cpu_percent;
                thumbnail.last_ram_mb = ram_mb;
                thumbnail.last_vram_mb = vram_mb;
                thumbnail.has_vram_data = has_vram;
                thumbnail.needs_render = true;
            }
        }
    }

    /// Unconditionally clears the entire notification stack (e.g. on character logout), same as a full natural expiry.
    fn clearAllNotifications(self: *Painter, thumbnail: *ThumbnailWindow) void {
        if (thumbnail.notifications.clear(self.allocator)) thumbnail.needs_render = true;
    }

    /// Clear expired notifications (call from update loop)
    pub fn updateNotifications(self: *Painter) void {
        const now = win32.Ticks.now();
        for (self.thumbnails.items) |*thumbnail| {
            if (thumbnail.notifications.expire(self.allocator, now)) thumbnail.needs_render = true;

            if (thumbnail.test_restore_visibility != null and thumbnail.notifications.isEmpty()) {
                self.restoreVisibilityAfterTest(thumbnail);
            }

            // Force a render each tick so the newest entry's alternating on/off flash phases actually paint.
            if (thumbnail.notifications.newest()) |notif| {
                if (notif.isFlashing(now)) thumbnail.needs_render = true;
            }
        }
    }

    /// Reacts to Scout's name-change events: syncs the affected thumbnail's name/title and runs the associated side effects (position restore, system-name clear, exclusion restore).
    pub fn applyNameChanges(self: *Painter, name_changes: []const scout_mod.NameChange, eve_windows: []const scout_mod.EveWindow) bool {
        var any_login_rank_change = false;
        var any_logout_rank_change = false;
        for (name_changes) |change| {
            const thumbnail = self.getThumbnailBySourceHwnd(change.hwnd) orelse continue;

            const was_generic = scout_mod.isGenericCharacterName(change.old_name);
            const now_generic = scout_mod.isGenericCharacterName(change.new_name);
            const now_specific = !now_generic;
            // An unconfigured "EVE" placeholder always sorts last, so either direction can change a thumbnail's RegionFit rank.
            if (was_generic and now_specific) any_login_rank_change = true;
            if (now_generic and !was_generic) any_logout_rank_change = true;

            var new_title: []const u8 = change.new_name;
            for (eve_windows) |w| {
                if (w.hwnd == change.hwnd) {
                    new_title = w.title;
                    break;
                }
            }

            const new_title_dup = self.allocator.dupe(u8, new_title) catch {
                slog.err("Failed to allocate title for {s}", .{change.new_name});
                continue;
            };
            const new_char_dup = self.allocator.dupe(u8, change.new_name) catch {
                self.allocator.free(new_title_dup);
                slog.err("Failed to allocate character name for {s}", .{change.new_name});
                continue;
            };

            self.allocator.free(thumbnail.title);
            self.allocator.free(thumbnail.character_name);
            thumbnail.title = new_title_dup;
            thumbnail.character_name = new_char_dup;
            thumbnail.render_cache.character_name.dims = null;
            thumbnail.refreshConfigCache(self.config, &self.auto_colors);
            self.refreshGroupBadge(thumbnail);

            // If character logged in (changed from "EVE" to actual name), move the thumbnail box to its remembered spot
            if (was_generic and now_specific) {
                // RegionFit ignores the saved spot; the reflow below places it correctly instead.
                if (thumbnail.win32_enabled and !placement_mod.isRegionFitActive(&self.config.display)) {
                    if (self.config.getCharacterPosition(change.new_name)) |saved_pos| {
                        _ = win32.SetWindowPos(thumbnail.hwnd, win32.HWND_NOTOPMOST, saved_pos.x, saved_pos.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
                        _ = win32.SetWindowPos(thumbnail.text_hwnd, win32.HWND_TOPMOST, saved_pos.x, saved_pos.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
                        self.resizeThumbnailIfNeeded(thumbnail, null);
                        slog.info("Moved {s} thumbnail to saved position: ({}, {})", .{ change.new_name, saved_pos.x, saved_pos.y });
                    } else {
                        slog.debug("No saved thumbnail position for {s}, keeping current location", .{change.new_name});
                    }
                }

                // Auto-move-on-login setting: same action as the hotkey, but for the real EVE client window
                if (self.config.autoMovePosition.enabled) {
                    self.auto_move.moveToSavedPosition(self.config, thumbnail.source_hwnd, change.new_name);
                }
            }

            // If character logged out (title is just "EVE"), clear system name
            if (!now_specific) {
                // Allocate empty string first to prevent use-after-free
                const empty_system = self.allocator.dupe(u8, "") catch {
                    slog.err("Failed to allocate empty system name for {s}", .{change.new_name});
                    // Keep old system name on allocation failure
                    continue;
                };
                self.allocator.free(thumbnail.system_name);
                thumbnail.system_name = empty_system;
                thumbnail.cached_system_color = self.config.thumbnail.systemNameColor;
                thumbnail.render_cache.system_name.dims = null;
                slog.debug("Cleared system name for logged out client", .{});

                self.clearAllNotifications(thumbnail);

                // Moving this placeholder into the not-logged-in space happens via the forced reflow below, which also resizes everyone else already there.
            }

            // Update exclusion state when character name becomes known (e.g., "EVE" -> "Probe Enthusiast")
            if (was_generic and now_specific) {
                const is_excluded = hotkeys_mod.isExcludedFromCycle(change.new_name);
                if (is_excluded != thumbnail.is_excluded_from_cycle) {
                    thumbnail.is_excluded_from_cycle = is_excluded;
                    if (is_excluded) slog.info("Restored exclusion state for {s}", .{change.new_name});
                }
            }

            // Cycle cursors are keyed by name and a rename fires no focus event, so the focused window must re-sync under its new one.
            if (win32.GetForegroundWindow() == thumbnail.source_hwnd) {
                hotkeys_mod.syncFocusedCharacter(thumbnail.character_name, thumbnail.source_hwnd);
            }

            self.renderThumbnailLogged(thumbnail, "name change");

            slog.info("Updated thumbnail for {s}", .{thumbnail.character_name});
        }

        const region_fit_active = placement_mod.isRegionFitActive(&self.config.display);
        const not_logged_in_space_active = placement_mod.notLoggedInSpaceRectFromConfig(&self.config.display) != null;

        // notLoggedInSpace is count-dependent, so crossing its boundary must reflow it regardless of regionFitReorderLoggedOut.
        if (not_logged_in_space_active and (any_login_rank_change or any_logout_rank_change)) return true;

        return region_fit_active and (any_login_rank_change or (any_logout_rank_change and self.config.display.regionFitReorderLoggedOut));
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

    /// Synchronizes thumbnails with Scout's window list, creating thumbnails for new windows; returns true if any were created.
    pub const PopulateOptions = struct {
        /// Moves each new client window to its saved position (auto-move).
        move_to_saved: bool,
        /// Seeds each new thumbnail's system name, so a reload doesn't show them blank.
        system_names: ?*const SystemNameSnapshot = null,
    };

    /// Startup/reload: creates every window's thumbnail, then reflows once, since createThumbnail sizes each one against the count so far.
    pub fn populate(self: *Painter, eve_windows: []const scout_mod.EveWindow, opts: PopulateOptions) void {
        if (self.addMissingThumbnails(eve_windows, opts) and self.hasCountDependentLayout()) self.repositionAllThumbnails();
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

    /// RegionFit and the not-logged-in space size every cell from the thumbnail count, so any arrival reflows them all.
    fn hasCountDependentLayout(self: *const Painter) bool {
        return placement_mod.isRegionFitActive(&self.config.display) or placement_mod.notLoggedInSpaceRectFromConfig(&self.config.display) != null;
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
        needs_region_reflow = (created_new and self.hasCountDependentLayout()) or needs_region_reflow;

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
        self.history_panel.toggle(self.allocator, self.config, self.instance, self.anyCharacterLoggedIn());
    }

    fn registerWindowClass(self: *Painter) !void {
        if (g_window_class_registered) return;

        // Black, not white COLOR_WINDOW: shows through whenever DWM has no live thumbnail frame to composite.
        const thumbnail_bg_brush = win32.CreateSolidBrush(0x00000000) orelse return error.CreateBrushFailed;

        gdi_overlay.registerWindowClass(self.instance, input.windowProc, WINDOW_CLASS_NAME, thumbnail_bg_brush) catch return error.RegisterClassFailed;

        // No background brush for a layered window.
        gdi_overlay.registerWindowClass(self.instance, input.textWindowProc, TEXT_WINDOW_CLASS_NAME, null) catch return error.RegisterTextClassFailed;

        drag_overlays_mod.registerWindowClass(self.instance) catch return error.RegisterGhostClassFailed;
        gdi_overlay.registerHintBoxClass(self.instance) catch return error.RegisterHintBoxClassFailed;

        region_select.registerWindowClass(self.instance) catch return error.RegisterRegionSelectClassFailed;
        region_select.setOnFinishedCallback(regionSelectFinishedCallback);
        g_window_class_registered = true;
    }

    /// Starts the "Start Region Selection" drag-to-select overlay; the result reaches the config dialog asynchronously via protocol.publishRegionSelectResult.
    pub fn startRegionSelect(self: *Painter, request: protocol.RegionSelectRequest) void {
        if (request.hide_thumbnails) self.hideThumbnailsForRegionSelect();
        const cursor = monitors_mod.cursorMonitorBounds();
        const text_color = self.config.thumbnail.characterNameColor | 0xFF000000;
        const label_font = self.font_cache.characterNameFont(&self.config.thumbnail, monitors_mod.dpiForMonitor(cursor.monitor)) catch |err| blk: {
            slog.err("Failed to get font for region-select label: {}", .{err});
            break :blk null;
        };
        region_select.start(self.instance, self.config.accentColor, .{
            .font = label_font,
            .color = text_color,
        }, request.edit_region, request.labels);
        if (label_font) |font| {
            const line1 = protocol.labelText(if (request.edit_region != null) &request.labels.hint_edit else &request.labels.hint_new);
            self.hint_box.show(self.instance, font, text_color, line1, protocol.labelText(&request.labels.hint_confirm), cursor.bounds);
        }
    }

    /// Reflows every thumbnail's RegionFit grid slot after a rank/count change (bulk create loops, group membership); no-op outside RegionFit.
    pub fn reflowIfRegionFitActive(self: *Painter) void {
        if (placement_mod.isRegionFitActive(&self.config.display)) self.repositionAllThumbnails();
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
    fn newThumbnailRecord(self: *Painter, eve_window: *const scout_mod.EveWindow, initial_system_name: []const u8, hwnd: win32.HWND, text_hwnd: win32.HWND, thumbnail_id: win32.HTHUMBNAIL, win32_enabled: bool) !ThumbnailWindow {
        const strings = try self.dupeThumbnailStrings(eve_window.title, eve_window.character_name, initial_system_name);
        var thumbnail = ThumbnailWindow{
            .hwnd = hwnd,
            .text_hwnd = text_hwnd,
            .thumbnail_id = thumbnail_id,
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
        const thumbnail = try self.newThumbnailRecord(eve_window, initial_system_name, sentinel, sentinel, sentinel, false);
        errdefer self.freeThumbnailData(thumbnail);
        try self.addThumbnail(thumbnail);

        slog.info("Created tracking entry for {s} ({s} mode)", .{ eve_window.character_name, @tagName(self.config.display.viewMode) });
    }

    fn createThumbnail(self: *Painter, eve_window: *const scout_mod.EveWindow, initial_system_name: []const u8) !void {
        if (self.config.display.viewMode != .Thumbnails) {
            return self.createTrackingOnlyEntry(eve_window, initial_system_name);
        }

        // Thumbnail mode: full Win32/DWM path.
        const char_name_z = try self.allocator.dupeZ(u8, eve_window.character_name);
        defer self.allocator.free(char_name_z);

        const cfg = &self.config.display;
        const total_count = self.thumbnails.items.len + 1;
        const size = self.layout().getThumbnailSize(eve_window.character_name, total_count, null);
        const monitor_placement = monitors_mod.resolveMonitorPlacement(cfg);
        const monitor_bounds = if (monitor_placement) |mp| mp.bounds else null;
        const scale = dpiToScale(monitors_mod.dpiForMonitor(if (monitor_placement) |mp| mp.monitor else null));
        // Grid-fit sizes (RegionFit's or notLoggedInSpace's) are already absolute physical pixels; only the plain default/per-character size needs DPI scaling.
        const thumb_width, const thumb_height = if (placement_mod.isRegionFitActive(cfg) or placement_mod.isCarvedOutOfRegionFit(cfg, eve_window.character_name))
            .{ size.width, size.height }
        else
            .{ scalePixels(size.width, scale), scalePixels(size.height, scale) };
        const pos = self.layout().calculateThumbnailPosition(eve_window.character_name, thumb_width, thumb_height, self.thumbnails.items.len, total_count, monitor_bounds, scale);

        // Needed on both windows since text_hwnd, being topmost, is the one that actually receives mouse messages.
        const click_through_ex: win32.DWORD = if (self.config.interaction.clickThrough) win32.WS_EX_TRANSPARENT else 0;

        // Create thumbnail window (borderless, layered for transparency)
        const hwnd = win32.CreateWindowExA(
            win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW | win32.WS_EX_LAYERED | win32.WS_EX_NOACTIVATE | click_through_ex,
            WINDOW_CLASS_NAME,
            char_name_z.ptr,
            win32.WS_POPUP | win32.WS_VISIBLE,
            pos.x,
            pos.y,
            thumb_width,
            thumb_height,
            null,
            null,
            self.instance,
            null,
        ) orelse return error.CreateWindowFailed;
        errdefer _ = win32.DestroyWindow(hwnd);

        _ = win32.SetLayeredWindowAttributes(hwnd, 0, self.config.getCharacterOpacity(eve_window.character_name), win32.LWA_ALPHA);

        var thumbnail_id: win32.HTHUMBNAIL = undefined;
        const hr = win32.DwmRegisterThumbnail(hwnd, eve_window.hwnd, &thumbnail_id);
        if (hr != 0) return error.DwmRegisterThumbnailFailed;
        errdefer _ = win32.DwmUnregisterThumbnail(thumbnail_id);

        // Update thumbnail properties - fill entire window
        var client_rect: win32.RECT = undefined;
        _ = win32.GetClientRect(hwnd, &client_rect);

        const props = makeThumbnailProps(client_rect.right, client_rect.bottom, win32.DWM_TNP_VISIBLE | win32.DWM_TNP_RECTDESTINATION | win32.DWM_TNP_SOURCECLIENTAREAONLY);

        const update_hr = win32.DwmUpdateThumbnailProperties(thumbnail_id, &props);
        if (update_hr != 0) return error.DwmUpdateThumbnailPropertiesFailed;

        _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
        _ = win32.UpdateWindow(hwnd);

        // Covers the full thumbnail, not just a top bar.
        const text_hwnd = win32.CreateWindowExA(
            win32.WS_EX_LAYERED | win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW | win32.WS_EX_NOACTIVATE | click_through_ex,
            TEXT_WINDOW_CLASS_NAME,
            char_name_z.ptr,
            win32.WS_POPUP,
            pos.x,
            pos.y,
            thumb_width,
            thumb_height,
            null,
            null,
            self.instance,
            null,
        ) orelse return error.CreateTextWindowFailed;
        errdefer _ = win32.DestroyWindow(text_hwnd);

        var thumbnail = try self.newThumbnailRecord(eve_window, initial_system_name, hwnd, text_hwnd, thumbnail_id, true);
        errdefer self.freeThumbnailData(thumbnail);
        try self.renderThumbnail(&thumbnail);

        // Store source window handle for click-to-focus
        _ = win32.SetPropA(hwnd, "SOURCE_HWND", eve_window.hwnd);
        _ = win32.SetPropA(text_hwnd, "SOURCE_HWND", eve_window.hwnd);

        _ = win32.SetWindowLongPtrA(hwnd, win32.GWLP_USERDATA, win32.hwndToUserData(text_hwnd));

        // For reverse lookup during drag.
        _ = win32.SetWindowLongPtrA(text_hwnd, win32.GWLP_USERDATA, win32.hwndToUserData(hwnd));

        _ = win32.SetWindowPos(text_hwnd, win32.HWND_TOPMOST, pos.x, pos.y, thumb_width, thumb_height, win32.SWP_NOACTIVATE);
        _ = win32.ShowWindow(text_hwnd, win32.SW_SHOW);
        _ = win32.UpdateWindow(text_hwnd);

        try self.addThumbnail(thumbnail);

        slog.info("Created thumbnail for {s}", .{eve_window.character_name});
    }

    pub fn saveThumbnailPosition(self: *Painter, hwnd: win32.HWND) void {
        if (!win32.isWindow(hwnd)) return;

        const thumbnail = self.getThumbnailByOverlayHwnd(hwnd) orelse return;

        var rect: win32.RECT = undefined;
        _ = win32.GetWindowRect(hwnd, &rect);

        const pos = config_mod.Position{
            .x = rect.left,
            .y = rect.top,
        };

        self.config.saveCharacterPosition(self.allocator, thumbnail.character_name, pos) catch |err| {
            slog.err("Failed to save position for {s}: {}", .{ thumbnail.character_name, err });
        };
    }
};

const scalePixels = win32.scalePixels;
const dpiToScale = win32.dpiToScale;

/// ReturnToLastApp's target belongs to HotkeyManager; Painter's foreground hook is just where it's observed.
fn recordNonEveForeground(hwnd: win32.HWND) void {
    if (hotkeys_mod.g_hotkey_manager_ptr) |manager| manager.last_non_eve_foreground = hwnd;
}

fn showThumbnailWindows(thumbnail: *const ThumbnailWindow, shown: bool) void {
    const cmd: c_int = if (shown) win32.SW_SHOW else win32.SW_HIDE;
    _ = win32.ShowWindow(thumbnail.hwnd, cmd);
    _ = win32.ShowWindow(thumbnail.text_hwnd, cmd);
}

/// Builds a DWM_THUMBNAIL_PROPERTIES sized to (width, height); rcSource stays zeroed (whole source window) on every caller.
fn makeThumbnailProps(width: i32, height: i32, flags: u32) win32.DWM_THUMBNAIL_PROPERTIES {
    return .{
        .dwFlags = flags,
        .rcDestination = win32.RECT{ .left = 0, .top = 0, .right = width, .bottom = height },
        .rcSource = win32.RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .opacity = 255,
        .fVisible = win32.TRUE,
        .fSourceClientAreaOnly = win32.TRUE,
    };
}

fn windowDestroyProc(_: win32.HANDLE, _: win32.DWORD, hwnd: win32.HWND, _: win32.LONG, _: win32.LONG, _: win32.DWORD, _: win32.DWORD) callconv(.c) void {
    const painter = g_painter_ptr orelse return;

    const index = painter.resolveThumbnailIndexForDestroy(hwnd) orelse return;

    slog.info("Window closed (event), removing thumbnail for {s}", .{painter.thumbnails.items[index].character_name});
    painter.removeThumbnailAt(index);
    painter.finishRemovals();
}

fn regionSelectFinishedCallback() void {
    const painter = g_painter_ptr orelse return;
    painter.restoreThumbnailsAfterRegionSelect();
    painter.hint_box.hide();
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
        painter.reassertTopmost();
    }

    const is_eve_window = painter.hasThumbnail(hwnd);

    if (!is_eve_window) {
        if (!win32.isOwnProcessWindow(hwnd) and !win32.isDesktopShellWindow(hwnd)) {
            recordNonEveForeground(hwnd);
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
