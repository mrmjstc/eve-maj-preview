const std = @import("std");
const win32 = @import("win32.zig");
const input = @import("input.zig");
const config_mod = @import("config.zig");
const color_mod = @import("color.zig");
const state_mod = @import("state.zig");
const types = @import("types.zig");
const manager_mod = @import("manager.zig");
const scout_mod = @import("scout.zig");
const list_view = @import("list_view.zig");
const notif_info_view = @import("notif_info_view.zig");
const activity_tracker = @import("activity_tracker.zig");
const gdi_overlay = @import("gdi_overlay.zig");
const main_mod = @import("main.zig");
const log = @import("log.zig");
const slog = log.scoped("painter");
const tts = @import("tts.zig");

const WINDOW_CLASS_NAME = "EVE_THUMBNAIL_CLASS";
const TEXT_WINDOW_CLASS_NAME = "EVE_TEXT_OVERLAY_CLASS";
const GHOST_WINDOW_CLASS_NAME = "EVE_GHOST_OVERLAY_CLASS";
const HIDE_DEBOUNCE_TIMER_ID = 1;

// Re-export shared types for backward compatibility
pub const BorderStyle = types.BorderStyle;
pub const TextPosition = types.TextPosition;
pub const ExclusionOverlayStyle = types.ExclusionOverlayStyle;

// Re-export ThumbnailState from state module for convenience
pub const ThumbnailState = state_mod.ThumbnailState;

pub const ActiveNotification = struct {
    text: []const u8,
    notification_type: types.NotificationType,
    start_time: u64,
    duration_ms: u32,
    suppress_when_focused: bool,
    suppress_when_clicked: bool,
    border_color_override: ?u32 = null,
    text_color_override: ?u32 = null,
    show_border: bool = true,
    flash_border: bool = false,
};

/// Ring-buffer capacity for Painter.notification_history, feeding the History Panel's history list.
pub const NOTIF_HISTORY_CAPACITY = 15;

/// One past notification retained for the History Panel; fixed-size buffers avoid a heap allocation per notification.
pub const NotificationHistoryEntry = struct {
    source_hwnd: win32.HWND,
    notification_type: types.NotificationType,
    character_name_buf: [64]u8 = undefined,
    character_name_len: u8 = 0,
    text_buf: [96]u8 = undefined,
    text_len: u8 = 0,
    timestamp_ms: u64 = 0,

    pub fn characterName(self: *const NotificationHistoryEntry) []const u8 {
        return self.character_name_buf[0..self.character_name_len];
    }

    pub fn text(self: *const NotificationHistoryEntry) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

/// Cap on simultaneously stacked notifications per thumbnail; kept small since the overlay is drawn onto a small thumbnail bitmap.
const MAX_STACKED_NOTIFICATIONS: usize = 3;

/// One resolved (text, color) line of the stacked notification block; built by createRenderSettings, drawn by renderThumbnailOverlay.
const NotificationLine = struct {
    text: []const u8 = "",
    color: u32 = 0xFFFFFF,
};

const NOTIFICATION_FLASH_PHASE_MS: u64 = 150;
const NOTIFICATION_FLASH_CYCLES: u64 = 4;
const NOTIFICATION_FLASH_TOTAL_MS: u64 = NOTIFICATION_FLASH_PHASE_MS * NOTIFICATION_FLASH_CYCLES * 2;

/// Whether a flashing notification's border should currently be hidden; returns false once the flash sequence has finished and the border settles steady-on.
fn isNotificationFlashOff(notif: ActiveNotification, now: u64) bool {
    if (!notif.show_border or !notif.flash_border) return false;
    const elapsed = now - notif.start_time;
    if (elapsed >= NOTIFICATION_FLASH_TOTAL_MS) return false;
    const phase = (elapsed / NOTIFICATION_FLASH_PHASE_MS) % 2;
    return phase == 1;
}

const TEXT_BUFFER_SIZE = 256;
const TEXT_PADDING_X = 5;
const TEXT_PADDING_Y = 2;
const OVERLAY_ALPHA = 255;

/// Settings for rendering thumbnail overlays (text and border).
const RenderSettings = struct {
    show_text: bool = true,
    show_character_name: bool = true,
    character_name: []const u8 = "",
    show_system_name: bool = false,
    system_name: []const u8 = "",
    character_name_color: u32 = 0xFFFFFF,
    system_name_color: u32 = 0xFFFFFF,
    character_name_bg_color: u32 = 0x80000000,
    system_name_bg_color: u32 = 0x80000000,
    character_name_font_name: []const u8 = "Segoe UI",
    character_name_font_size: i32 = 14,
    character_name_font_weight: types.FontWeight = .Regular,
    character_name_position: TextPosition = .TopLeft,
    character_name_offset_x: i32 = 0,
    character_name_offset_y: i32 = 0,
    system_name_position: TextPosition = .BottomLeft,
    system_name_offset_x: i32 = 0,
    system_name_offset_y: i32 = 0,
    system_name_font_name: []const u8 = "Segoe UI",
    system_name_font_size: i32 = 12,
    system_name_font_weight: types.FontWeight = .Regular,
    show_notifications: bool = false,
    notification_lines: [MAX_STACKED_NOTIFICATIONS]NotificationLine = .{NotificationLine{}} ** MAX_STACKED_NOTIFICATIONS,
    notification_line_count: usize = 0,
    notifications_position: TextPosition = .Center,
    notifications_offset_x: i32 = 0,
    notifications_offset_y: i32 = 0,
    notifications_font_name: []const u8 = "Segoe UI",
    notifications_font_size: i32 = 12,
    notifications_font_weight: types.FontWeight = .Regular,
    notifications_bg_color: u32 = 0x80000000,

    show_border: bool = true,
    border_width: u8 = 2,
    border_color: u32 = 0xFF606060,
    border_style: BorderStyle = .Solid,

    show_exclusion_overlay: bool = false,
    exclusion_overlay_style: types.ExclusionOverlayStyle = .X,
    exclusion_overlay_color: u32 = 0x33FF0000,

    show_quick_group_badge: bool = false,
    quick_group_badge_text: []const u8 = "",
    quick_group_badge_color: u32 = 0xFF44FF44,
    quick_group_badge_position: TextPosition = .RightCenter,
    quick_group_badge_offset_x: i32 = 0,
    quick_group_badge_offset_y: i32 = 0,
    quick_group_badge_font_name: []const u8 = "Segoe UI",
    quick_group_badge_font_size: i32 = 12,
    quick_group_badge_font_weight: types.FontWeight = .Regular,
    quick_group_badge_bg_color: u32 = 0x80000000,
    combat_incoming_bg_color: u32 = 0x80000000,
    combat_outgoing_bg_color: u32 = 0x80000000,
    mining_bg_color: u32 = 0x80000000,
    bounty_bg_color: u32 = 0x80000000,

    show_thumbnail: bool = true,
    overlay_alpha: u8 = OVERLAY_ALPHA,

    overlay_width: c_int,
    overlay_height: c_int,

    dps_incoming: f32 = 0.0,
    dps_outgoing: f32 = 0.0,
    mining_rate: f32 = 0.0,
    mining_isk_rate: f32 = 0.0,
    bounty_isk_rate: f32 = 0.0,
    // Included so the false->true transition on first tracker push invalidates the cache even when the (sentineled) rate value itself didn't change.
    has_dps_data: bool = false,
    has_mining_data: bool = false,
    has_bounty_data: bool = false,

    // Included so a config-only color change still invalidates renderThumbnail's cache even when the DPS/rate value itself hasn't moved.
    dps_incoming_color: u32 = 0xFFFF4444,
    dps_outgoing_color: u32 = 0xFF44FF44,
    mining_color: u32 = 0xFF44AAFF,
    bounty_color: u32 = 0xFFFFD700,
};

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
    // Wall-clock ms of last stargate/conduit jump; 0 = hasn't jumped this session.
    last_jump_ms: i64 = 0,
    // Guards the left-behind alert to one-per-episode; cleared on jump.
    travel_alert_fired: bool = false,
    // Packed newest-first at the front (no gaps); see Painter.pushNotification.
    active_notifications: [MAX_STACKED_NOTIFICATIONS]?ActiveNotification = .{@as(?ActiveNotification, null)} ** MAX_STACKED_NOTIFICATIONS,
    last_click_time: u64 = 0,
    // GetTickCount64() of the last notification actually shown per type; suppressed attempts don't update this, so throttle_ms anchors to the last one actually displayed.
    last_notification_time_by_type: std.enums.EnumArray(types.NotificationType, u64) = .initFill(0),
    is_excluded_from_cycle: bool = false,
    needs_render: bool = false,
    win32_enabled: bool = true,

    // Null means not enough span yet to trust a rate (see activity_tracker.zig).
    last_incoming_dps: ?f32 = null,
    last_outgoing_dps: ?f32 = null,
    last_mining_rate: ?f32 = null,
    last_mining_isk_rate: ?f32 = null,
    last_bounty_isk_rate: ?f32 = null,

    // False until the tracker's first push actually arrives; distinguishes "never heard from the tracker yet" (show nothing) from a genuine null rate the tracker reported (show "??"), since both look identical as `null` otherwise.
    has_dps_data: bool = false,
    has_mining_data: bool = false,
    has_bounty_data: bool = false,

    // Cached overlay bitmap — kept alive between renders, recreated only on resize
    cached_overlay: ?gdi_overlay.OverlayBitmap = null,

    visibility_state: state_mod.VisibilityState = .Visible,
    /// When checkAutoMinimize's delay should count from; refreshed every tick this thumbnail is Active or Minimized, left untouched otherwise so its frozen value is the moment it last became eligible.
    inactive_since: i64 = 0,
    /// Edge-detector so a minimize/restore with no accompanying focus change still marks this dirty for repaint.
    was_minimized: bool = false,

    cached_render_settings: ?RenderSettings = null,
    cached_char_dims: ?TextDimensions = null,
    cached_sys_dims: ?TextDimensions = null,
    cached_qg_dims: ?TextDimensions = null,
    cached_font_name: []const u8 = "",
    cached_font_size: i32 = 0,
    cached_font_weight: types.FontWeight = .Regular,
    cached_sys_font_name: []const u8 = "",
    cached_sys_font_size: i32 = 0,
    cached_sys_font_weight: types.FontWeight = .Regular,
    cached_qg_font_name: []const u8 = "",
    cached_qg_font_size: i32 = 0,
    cached_qg_font_weight: types.FontWeight = .Regular,
    cached_system_color: u32,
    // Auto-generated per-character name color, resolved from config; null when "Unique Character Name Colors" is disabled, and callers fall back to their own default.
    cached_character_color: ?u32,
    // Display name and per-character active-border override, resolved from config on character_name change or (re)creation rather than every tick (list_view.zig hashes these every ~50ms per thumbnail).
    cached_display_name: []const u8,
    cached_active_border_override: ?u32,
    // Owned, comma-joined quick-group membership label ("1, 3"); "" = none.
    cached_quick_group_label: []const u8,

    /// Whether this thumbnail's source_hwnd is the live "who's focused" pointer.
    pub fn isFocused(self: *const ThumbnailWindow, active_source_hwnd: ?win32.HWND) bool {
        return self.source_hwnd == active_source_hwnd;
    }

    /// The single canonical "what should this render/style as" computation. The returned ThumbnailState
    /// is used purely as a style-lookup key (config.zig's getStateConfig) - never stored back onto the thumbnail.
    pub fn effectiveRenderState(self: *const ThumbnailWindow, active_source_hwnd: ?win32.HWND) ThumbnailState {
        if (input.isThumbnailDragging(self)) return .Dragging;
        if (self.active_notifications[0] != null) return .Alert;
        if (self.isFocused(active_source_hwnd)) return .Active;
        if (win32.isWindowIconic(self.source_hwnd)) return .Minimized;
        return .Inactive;
    }

    /// Sets visibility state, silently failing via tryTransitionVisibility if invalid.
    pub fn setVisibility(self: *ThumbnailWindow, new_visibility: state_mod.VisibilityState) void {
        const blocks_hiding = self.active_notifications[0] != null or input.isThumbnailDragging(self);
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

/// Per-purpose font cache slot (see `Painter.cached_fonts`). Kept as u4 (not u3) so a future slot doesn't need a resize.
/// `combat` is incoming DPS's slot; outgoing DPS has its own.
pub const FontSlot = enum(u4) { main, combat, mining, bounty, system_name, quick_group_badge, notification, combat_outgoing };

const FontCacheEntry = struct {
    font: ?win32.HFONT = null,
    name: []const u8 = "",
    size: i32 = 0,
    weight: types.FontWeight = .Regular,
};

/// dpi realistically never exceeds ~480 (5x scale), well under the 16 bits reserved here.
fn fontCacheKey(slot: FontSlot, dpi: u32) u32 {
    return (@as(u32, @intFromEnum(slot)) << 16) | (dpi & 0xFFFF);
}

pub var g_painter_ptr: ?*Painter = null;
pub var g_hotkey_manager_ptr: ?*@import("hotkeys.zig").HotkeyManager = null;

fn isCharacterTravelExcluded(character_name: []const u8) bool {
    if (g_hotkey_manager_ptr) |mgr| {
        return mgr.isCharacterExcluded(character_name);
    }
    return false;
}

// Global so registration persists across Painter instances, not just one.
var g_window_class_registered: bool = false;

/// One entry in the "recently notified" FIFO queue; owns a copy of the name since it must outlive ThumbnailWindow.character_name, which is freed on window close.
const NotifiedCharacterEntry = struct {
    character_name: []const u8,
    notified_at_ms: u64,
};

/// One saved-position outline for the drag-time ghost overlay; `names` is the comma-joined list of every character sharing that exact rect.
pub const GhostGroup = struct {
    rect: win32.RECT,
    names: []const u8,
};

fn ghostRectsEqual(a: win32.RECT, b: win32.RECT) bool {
    return a.left == b.left and a.top == b.top and a.right == b.right and a.bottom == b.bottom;
}

pub const Painter = struct {
    allocator: std.mem.Allocator,
    thumbnails: std.ArrayList(ThumbnailWindow),
    hwnd_to_thumbnail_index: std.AutoHashMap(win32.HWND, usize),
    // thumbnail.hwnd → index, for O(1) lookups.
    thumbnail_hwnd_to_index: std.AutoHashMap(win32.HWND, usize),
    // thumbnail.text_hwnd → index, for O(1) lookups.
    text_hwnd_to_index: std.AutoHashMap(win32.HWND, usize),
    last_hwnd_index_rebuild: u64 = 0,
    instance: win32.HINSTANCE,
    config: *config_mod.Config,
    focus_event_hook: ?win32.HANDLE = null,
    destroy_event_hook: ?win32.HANDLE = null,
    hide_debounce_timer_hwnd: ?win32.HWND = null,
    /// Keyed by (FontSlot, DPI) via fontCacheKey, so different-DPI monitors don't evict each other's fonts every render.
    cached_fonts: std.AutoHashMap(u32, FontCacheEntry),
    /// Non-null when viewMode == .ClientList; owns the compact list panel window.
    list_window: ?list_view.ListWindow = null,
    /// Non-null when display.showNotifInfoPanel is enabled; owns the notification-history/activity-totals panel.
    notif_info_window: ?notif_info_view.NotifInfoWindow = null,
    /// FIFO queue of recently-notified characters, oldest first; populated by trackNotifiedCharacter, consumed by HotkeyManager.cycleNotified via getNotifiedCharacterNames.
    notified_queue: std.ArrayList(NotifiedCharacterEntry) = .empty,
    /// Ring buffer of the last NOTIF_HISTORY_CAPACITY notifications shown, across all characters, newest overwrites oldest; feeds notif_info_window.
    notification_history: [NOTIF_HISTORY_CAPACITY]NotificationHistoryEntry = undefined,
    notification_history_head: usize = 0,
    notification_history_count: usize = 0,
    /// Tray-toggle override: forces the History Panel visible past hideNotifInfoPanelWhenNoCharacters until characters go logged-in -> logged-out again.
    notif_history_force_visible: bool = false,
    /// Last-seen anyCharacterLoggedIn() result, used to detect the logged-in -> logged-out edge that clears notif_history_force_visible.
    notif_history_had_characters: bool = false,
    /// Transient overlay shown only while dragging, outlining other characters' saved positions; created lazily, hidden (not destroyed) between drags.
    ghost_overlay_hwnd: ?win32.HWND = null,
    ghost_overlay_bitmap: ?gdi_overlay.OverlayBitmap = null,
    /// Sole "who's focused" source of truth; write only via reconcileThumbnailStates.
    active_source_hwnd: ?win32.HWND = null,
    /// Last EVE thumbnail hwnd that held focus; used by checkAutoMinimize's exemptLastActiveOnFocusLoss option to identify which client to spare once EVE itself has no window focused.
    last_focused_source_hwnd: ?win32.HWND = null,

    fn getThumbnailSize(self: *const Painter, character_name: []const u8) struct { width: i32, height: i32 } {
        if (self.config.getCharacterSize(character_name)) |char_size| {
            return .{
                .width = char_size.width orelse self.config.thumbnail.width,
                .height = char_size.height orelse self.config.thumbnail.height,
            };
        }
        return .{
            .width = self.config.thumbnail.width,
            .height = self.config.thumbnail.height,
        };
    }

    /// Gets or creates the cached font for the given (slot, dpi), recreating it only if its settings changed.
    fn getCachedFont(self: *Painter, slot: FontSlot, dpi: u32, font_name: []const u8, font_size: i32, font_weight: types.FontWeight) !win32.HFONT {
        const gop = try self.cached_fonts.getOrPut(fontCacheKey(slot, dpi));
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const entry = gop.value_ptr;

        const cache_valid = entry.font != null and
            std.mem.eql(u8, entry.name, font_name) and
            entry.size == font_size and
            entry.weight == font_weight;

        if (cache_valid) {
            return entry.font.?;
        }

        if (entry.font) |old_font| {
            _ = win32.DeleteObject(old_font);
            entry.font = null;
            slog.debug("Font cache invalidated for slot {} @ {} DPI (settings changed)", .{ slot, dpi });
        }

        const font_name_z = try self.allocator.dupeZ(u8, font_name);
        defer self.allocator.free(font_name_z);

        // Owns a copy rather than borrowing font_name, which may be freed/replaced out from under a cached entry.
        const name_copy = try self.allocator.dupe(u8, font_name);
        errdefer self.allocator.free(name_copy);

        const font = win32.CreateFontA(
            -font_size,
            0,
            0,
            0,
            font_weight.toWin32Weight(),
            if (font_weight.isItalic()) 1 else 0,
            0,
            0,
            win32.DEFAULT_CHARSET,
            win32.OUT_DEFAULT_PRECIS,
            win32.CLIP_DEFAULT_PRECIS,
            win32.CLEARTYPE_QUALITY,
            win32.DEFAULT_PITCH,
            font_name_z,
        );

        if (font == null) {
            return error.CreateFontFailed;
        }

        self.allocator.free(entry.name);
        entry.font = font;
        entry.name = name_copy;
        entry.size = font_size;
        entry.weight = font_weight;

        slog.debug("Created cached font for slot {} @ {} DPI: {s} size={} weight={}", .{ slot, dpi, font_name, font_size, font_weight });

        return font.?;
    }

    pub fn init(allocator: std.mem.Allocator, cfg: *config_mod.Config) !Painter {
        const instance = win32.GetModuleHandleA(null) orelse return error.GetModuleHandleFailed;

        var painter: Painter = .{
            .allocator = allocator,
            .thumbnails = .empty,
            .hwnd_to_thumbnail_index = std.AutoHashMap(win32.HWND, usize).init(allocator),
            .thumbnail_hwnd_to_index = std.AutoHashMap(win32.HWND, usize).init(allocator),
            .text_hwnd_to_index = std.AutoHashMap(win32.HWND, usize).init(allocator),
            .cached_fonts = std.AutoHashMap(u32, FontCacheEntry).init(allocator),
            .instance = instance,
            .config = cfg,
        };

        try painter.registerWindowClass();

        painter.focus_event_hook = win32.SetWinEventHook(
            win32.EVENT_SYSTEM_FOREGROUND,
            win32.EVENT_SYSTEM_FOREGROUND,
            null,
            winEventProc,
            0,
            0,
            win32.WINEVENT_OUTOFCONTEXT,
        );

        if (painter.focus_event_hook) |_| {} else {
            slog.err("Failed to set up focus event hook", .{});
        }

        painter.destroy_event_hook = win32.SetWinEventHook(
            win32.EVENT_OBJECT_DESTROY,
            win32.EVENT_OBJECT_DESTROY,
            null,
            windowDestroyProc,
            0,
            0,
            win32.WINEVENT_OUTOFCONTEXT,
        );

        if (painter.destroy_event_hook) |_| {} else {
            slog.err("Failed to set up destroy event hook", .{});
        }

        // Lets the list window proc activate EVE clients without a direct list_view → input dependency.
        list_view.g_activate_fn = input.handleThumbnailClick;
        list_view.g_shift_click_fn = input.handleThumbnailShiftClick;
        notif_info_view.g_activate_fn = input.handleThumbnailClick;

        if (cfg.display.viewMode == .ClientList) {
            painter.list_window = list_view.ListWindow.init(allocator, cfg, instance) catch |err| blk: {
                slog.err("Failed to create list window: {}", .{err});
                break :blk null;
            };
        }

        if (cfg.display.showNotifInfoPanel) {
            painter.notif_info_window = notif_info_view.NotifInfoWindow.init(allocator, cfg, instance) catch |err| blk: {
                slog.err("Failed to create notification/info window: {}", .{err});
                break :blk null;
            };
        }

        return painter;
    }

    pub fn deinit(self: *Painter) void {
        g_painter_ptr = null;

        // Destroy list window first (before unhooking events)
        if (self.list_window) |*lw| {
            lw.deinit();
            self.list_window = null;
        }

        if (self.notif_info_window) |*niw| {
            niw.deinit();
            self.notif_info_window = null;
        }

        var font_it = self.cached_fonts.valueIterator();
        while (font_it.next()) |entry| {
            if (entry.font) |font| {
                _ = win32.DeleteObject(font);
                entry.font = null;
            }
            self.allocator.free(entry.name);
        }
        self.cached_fonts.deinit();

        if (self.focus_event_hook) |hook| {
            _ = win32.UnhookWinEvent(hook);
        }
        if (self.destroy_event_hook) |hook| {
            _ = win32.UnhookWinEvent(hook);
        }

        if (self.ghost_overlay_bitmap) |bitmap| bitmap.destroy();
        if (self.ghost_overlay_hwnd) |hwnd| _ = win32.DestroyWindow(hwnd);

        for (self.thumbnails.items) |thumbnail| {
            self.destroyThumbnailResources(thumbnail);
        }
        self.thumbnails.deinit(self.allocator);
        for (self.notified_queue.items) |entry| self.allocator.free(entry.character_name);
        self.notified_queue.deinit(self.allocator);
        self.hwnd_to_thumbnail_index.deinit();
        self.thumbnail_hwnd_to_index.deinit();
        self.text_hwnd_to_index.deinit();
    }

    /// Compares all visual fields of RenderSettings except show_thumbnail; shared by renderSettingsEqual and renderSettingsOnlyVisibilityChanged.
    fn renderSettingsVisualEqual(a: RenderSettings, b: RenderSettings) bool {
        return a.show_text == b.show_text and
            a.show_character_name == b.show_character_name and
            stringsEqualFast(a.character_name, b.character_name) and
            a.show_system_name == b.show_system_name and
            stringsEqualFast(a.system_name, b.system_name) and
            a.character_name_color == b.character_name_color and
            a.system_name_color == b.system_name_color and
            a.character_name_bg_color == b.character_name_bg_color and
            a.system_name_bg_color == b.system_name_bg_color and
            stringsEqualFast(a.character_name_font_name, b.character_name_font_name) and
            a.character_name_font_size == b.character_name_font_size and
            a.character_name_font_weight == b.character_name_font_weight and
            a.character_name_position == b.character_name_position and
            a.character_name_offset_x == b.character_name_offset_x and
            a.character_name_offset_y == b.character_name_offset_y and
            a.system_name_position == b.system_name_position and
            a.system_name_offset_x == b.system_name_offset_x and
            a.system_name_offset_y == b.system_name_offset_y and
            stringsEqualFast(a.system_name_font_name, b.system_name_font_name) and
            a.system_name_font_size == b.system_name_font_size and
            a.system_name_font_weight == b.system_name_font_weight and
            a.show_notifications == b.show_notifications and
            a.notification_line_count == b.notification_line_count and
            (blk: {
                var idx: usize = 0;
                while (idx < a.notification_line_count) : (idx += 1) {
                    const al = a.notification_lines[idx];
                    const bl = b.notification_lines[idx];
                    if (al.color != bl.color) break :blk false;
                    if (!stringsEqualFast(al.text, bl.text)) break :blk false;
                }
                break :blk true;
            }) and
            a.notifications_position == b.notifications_position and
            a.notifications_offset_x == b.notifications_offset_x and
            a.notifications_offset_y == b.notifications_offset_y and
            stringsEqualFast(a.notifications_font_name, b.notifications_font_name) and
            a.notifications_font_size == b.notifications_font_size and
            a.notifications_font_weight == b.notifications_font_weight and
            a.notifications_bg_color == b.notifications_bg_color and
            a.show_border == b.show_border and
            a.border_width == b.border_width and
            a.border_color == b.border_color and
            a.border_style == b.border_style and
            a.show_exclusion_overlay == b.show_exclusion_overlay and
            a.exclusion_overlay_style == b.exclusion_overlay_style and
            a.exclusion_overlay_color == b.exclusion_overlay_color and
            a.show_quick_group_badge == b.show_quick_group_badge and
            stringsEqualFast(a.quick_group_badge_text, b.quick_group_badge_text) and
            a.quick_group_badge_color == b.quick_group_badge_color and
            a.quick_group_badge_position == b.quick_group_badge_position and
            a.quick_group_badge_offset_x == b.quick_group_badge_offset_x and
            a.quick_group_badge_offset_y == b.quick_group_badge_offset_y and
            stringsEqualFast(a.quick_group_badge_font_name, b.quick_group_badge_font_name) and
            a.quick_group_badge_font_size == b.quick_group_badge_font_size and
            a.quick_group_badge_font_weight == b.quick_group_badge_font_weight and
            a.quick_group_badge_bg_color == b.quick_group_badge_bg_color and
            a.overlay_alpha == b.overlay_alpha and
            a.overlay_width == b.overlay_width and
            a.overlay_height == b.overlay_height and
            a.dps_incoming == b.dps_incoming and
            a.dps_outgoing == b.dps_outgoing and
            a.mining_rate == b.mining_rate and
            a.mining_isk_rate == b.mining_isk_rate and
            a.bounty_isk_rate == b.bounty_isk_rate and
            a.has_dps_data == b.has_dps_data and
            a.has_mining_data == b.has_mining_data and
            a.has_bounty_data == b.has_bounty_data and
            a.dps_incoming_color == b.dps_incoming_color and
            a.dps_outgoing_color == b.dps_outgoing_color and
            a.mining_color == b.mining_color and
            a.bounty_color == b.bounty_color and
            a.combat_incoming_bg_color == b.combat_incoming_bg_color and
            a.combat_outgoing_bg_color == b.combat_outgoing_bg_color and
            a.mining_bg_color == b.mining_bg_color and
            a.bounty_bg_color == b.bounty_bg_color;
    }

    fn renderSettingsEqual(a: RenderSettings, b: RenderSettings) bool {
        return a.show_thumbnail == b.show_thumbnail and renderSettingsVisualEqual(a, b);
    }

    fn renderSettingsOnlyVisibilityChanged(a: RenderSettings, b: RenderSettings) bool {
        return a.show_thumbnail != b.show_thumbnail and renderSettingsVisualEqual(a, b);
    }

    /// Single point for rendering any thumbnail overlay; skips the re-render when RenderSettings haven't changed.
    pub fn renderThumbnail(self: *const Painter, thumbnail: *ThumbnailWindow) !void {
        // ClientList mode renders via ListWindow.render() instead; Nothing mode renders nothing
        if (!thumbnail.win32_enabled) return;
        const settings = createRenderSettings(self.config, thumbnail, self.active_source_hwnd);

        if (thumbnail.cached_render_settings) |cached| {
            if (renderSettingsEqual(cached, settings)) {
                return;
            }

            // Only visibility changed? Just show/hide windows without re-rendering
            if (renderSettingsOnlyVisibilityChanged(cached, settings)) {
                if (settings.show_thumbnail) {
                    _ = win32.ShowWindow(thumbnail.hwnd, win32.SW_SHOW);
                    _ = win32.ShowWindow(thumbnail.text_hwnd, win32.SW_SHOW);
                } else {
                    _ = win32.ShowWindow(thumbnail.hwnd, win32.SW_HIDE);
                    _ = win32.ShowWindow(thumbnail.text_hwnd, win32.SW_HIDE);
                }
                thumbnail.cached_render_settings = settings;
                return;
            }
        }

        if (settings.show_thumbnail) {
            _ = win32.ShowWindow(thumbnail.hwnd, win32.SW_SHOW);
            _ = win32.ShowWindow(thumbnail.text_hwnd, win32.SW_SHOW);

            try renderThumbnailOverlay(
                thumbnail,
                settings,
                self.config,
            );
        } else {
            _ = win32.ShowWindow(thumbnail.hwnd, win32.SW_HIDE);
            _ = win32.ShowWindow(thumbnail.text_hwnd, win32.SW_HIDE);
        }

        thumbnail.cached_render_settings = settings;
    }

    /// renderThumbnail, logging (not propagating) a failure with context folded into the message.
    fn renderThumbnailLogged(self: *const Painter, thumbnail: *ThumbnailWindow, context: []const u8) void {
        self.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render thumbnail for {s} ({s}): {}", .{ thumbnail.character_name, context, err });
        };
    }

    /// Destroys all resources for a single thumbnail; child windows and the DWM thumbnail must go before the parent window.
    fn destroyThumbnailResources(self: *Painter, thumbnail: ThumbnailWindow) void {
        if (thumbnail.win32_enabled) {
            // Destroy cached overlay bitmap (GDI resources must be freed before window destruction)
            if (thumbnail.cached_overlay) |o| o.destroy();

            _ = win32.DestroyWindow(thumbnail.text_hwnd);
            _ = win32.DwmUnregisterThumbnail(thumbnail.thumbnail_id);
            _ = win32.DestroyWindow(thumbnail.hwnd);
        }

        // Free allocated strings (always, regardless of mode)
        self.allocator.free(thumbnail.title);
        self.allocator.free(thumbnail.character_name);
        self.allocator.free(thumbnail.system_name);
        self.allocator.free(thumbnail.cached_quick_group_label);
        for (thumbnail.active_notifications) |maybe_notif| {
            if (maybe_notif) |notif| self.allocator.free(notif.text);
        }
    }

    pub fn hasThumbnail(self: *Painter, source_hwnd: win32.HWND) bool {
        return self.hwnd_to_thumbnail_index.contains(source_hwnd);
    }

    /// Remove thumbnails whose source / related windows are gone (defensive cleanup)
    pub fn cleanupClosedThumbnails(self: *Painter, closed_windows: []const scout_mod.ClosedWindow) void {
        // By source_hwnd, not name: multiple windows can share a name (e.g. "EVE").
        var removed_any = false;
        for (closed_windows) |cw| {
            var i: usize = 0;
            while (i < self.thumbnails.items.len) {
                const thumbnail = self.thumbnails.items[i];
                if (thumbnail.source_hwnd == cw.hwnd) {
                    slog.info("Cleaning up closed thumbnail for {s}", .{thumbnail.character_name});
                    _ = self.hwnd_to_thumbnail_index.remove(thumbnail.source_hwnd);
                    _ = self.thumbnail_hwnd_to_index.remove(thumbnail.hwnd);
                    _ = self.text_hwnd_to_index.remove(thumbnail.text_hwnd);
                    self.destroyThumbnailResources(thumbnail);
                    _ = self.thumbnails.orderedRemove(i);
                    removed_any = true;
                    break;
                }
                i += 1;
            }
        }

        if (removed_any) {
            self.rebuildHwndIndex(false);
        }
    }

    /// Rebuilds all HWND → index mappings; call after removing thumbnails to keep indices consistent. `force` bypasses the rate limit when the caller needs a correct index immediately.
    fn rebuildHwndIndex(self: *Painter, force: bool) void {
        const now = win32.GetTickCount64();
        if (!force and now - self.last_hwnd_index_rebuild < 100) {
            slog.debug("Skipping HWND index rebuild (rate limited: {}ms since last rebuild)", .{now - self.last_hwnd_index_rebuild});
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

    /// Recompute and cache a thumbnail's quick-group badge label after its membership changed.
    pub fn refreshQuickGroupBadge(self: *Painter, thumbnail: *ThumbnailWindow) void {
        var label_buf = std.ArrayList(u8).empty;
        defer label_buf.deinit(self.allocator);

        for (self.config.quickGroups.items, 0..) |*group, index| {
            var is_member = false;
            for (group.characters.items) |char_name| {
                if (std.mem.eql(u8, char_name, thumbnail.character_name)) {
                    is_member = true;
                    break;
                }
            }
            if (!is_member) continue;

            if (label_buf.items.len > 0) {
                label_buf.appendSlice(self.allocator, ", ") catch return;
            }
            if (group.name.len > 0) {
                label_buf.appendSlice(self.allocator, group.name) catch return;
            } else {
                var index_buf: [20]u8 = undefined;
                const index_str = std.fmt.bufPrint(&index_buf, "{}", .{index + 1}) catch return;
                label_buf.appendSlice(self.allocator, index_str) catch return;
            }
        }

        const new_label = self.allocator.dupe(u8, label_buf.items) catch return;
        self.allocator.free(thumbnail.cached_quick_group_label);
        thumbnail.cached_quick_group_label = new_label;
        thumbnail.cached_qg_dims = null;
    }

    /// Reconciles focus, then refreshes minimized-state bookkeeping (inactive_since, dirty-on-minimize-change); call periodically from the timer.
    pub fn updateThumbnailStates(self: *Painter) void {
        if (self.thumbnails.items.len == 0) return;

        self.reconcileThumbnailStates(win32.GetForegroundWindow());

        const now = std.time.milliTimestamp();
        for (self.thumbnails.items) |*thumbnail| {
            if (input.isThumbnailDragging(thumbnail)) continue;

            const is_active = thumbnail.isFocused(self.active_source_hwnd);
            const is_minimized = win32.isWindowIconic(thumbnail.source_hwnd);

            if (is_active or is_minimized) {
                thumbnail.inactive_since = now;
            }

            if (is_minimized != thumbnail.was_minimized) {
                thumbnail.was_minimized = is_minimized;
                thumbnail.needs_render = true;
            }
        }
    }

    /// Returns the live scout's tracked EVE windows, or logs and returns null if scout isn't available.
    fn getEveWindowsOrLog(action: []const u8) ?[]const scout_mod.EveWindow {
        const scout_ptr = main_mod.g_scout_ptr orelse {
            slog.err("Scout not available for {s}", .{action});
            return null;
        };
        return scout_ptr.getWindows();
    }

    /// Minimizes each EVE window `autoMinimize.delayMs` after it last stopped being Active/Minimized (see ThumbnailWindow.inactive_since); call once per tick.
    fn checkAutoMinimize(self: *Painter) void {
        if (!self.config.autoMinimize.enabled) return;
        if (self.thumbnails.items.len == 0) return;

        const now = std.time.milliTimestamp();
        const delay_ms: i64 = self.config.autoMinimize.delayMs;
        var minimized_any = false;

        // active_source_hwnd is the literal foreground window, so it's non-null even on a non-EVE app.
        const eve_has_focus = if (self.active_source_hwnd) |hwnd| self.hwnd_to_thumbnail_index.contains(hwnd) else false;

        for (self.thumbnails.items) |*thumbnail| {
            if (input.isThumbnailDragging(thumbnail)) continue;
            if (thumbnail.isFocused(self.active_source_hwnd)) continue;
            if (win32.isWindowIconic(thumbnail.source_hwnd)) continue;
            if (self.config.autoMinimize.exemptLastActiveOnFocusLoss and
                !eve_has_focus and
                thumbnail.source_hwnd == self.last_focused_source_hwnd) continue;
            if (now - thumbnail.inactive_since < delay_ms) continue;
            if (self.config.isExcludedFromMinimize(thumbnail.character_name)) continue;
            if (!win32.isWindow(thumbnail.source_hwnd)) continue;

            _ = win32.ShowWindowAsync(thumbnail.source_hwnd, win32.SW_FORCEMINIMIZE);
            minimized_any = true;
            slog.info("Auto-minimized {s} (inactive {}ms)", .{ thumbnail.character_name, now - thumbnail.inactive_since });
        }

        if (minimized_any) {
            for (self.thumbnails.items) |*thumbnail| {
                if (thumbnail.isFocused(self.active_source_hwnd) and win32.isWindow(thumbnail.source_hwnd)) {
                    // Minimizing the other windows can transiently steal focus from the active one.
                    input.forceSetForegroundWindow(thumbnail.source_hwnd);
                    break;
                }
            }
        }
    }

    /// Minimize all EVE client windows regardless of their current state (hotkey action).
    pub fn minimizeAllClients(_: *Painter) void {
        const eve_windows = getEveWindowsOrLog("minimize all clients") orelse return;
        manager_mod.minimizeAllClients(eve_windows);
    }

    /// Move all EVE client windows with a saved position to that position (hotkey action).
    pub fn moveAllClientsToSavedPositions(self: *Painter) void {
        const eve_windows = getEveWindowsOrLog("move all clients to saved positions") orelse return;
        manager_mod.moveAllClientsToSavedPositions(eve_windows, self.config);
    }

    /// Close all EVE client windows except those in the exclude list (hotkey action).
    pub fn closeAllClients(self: *Painter) void {
        const eve_windows = getEveWindowsOrLog("close all clients") orelse return;
        manager_mod.closeAllClients(eve_windows, self.config);
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

    /// Toggle auto-minimize mode temporarily, without persisting to config (hotkey action).
    pub fn toggleAutoMinimize(self: *Painter) void {
        self.config.autoMinimize.enabled = !self.config.autoMinimize.enabled;
        const state = if (self.config.autoMinimize.enabled) "enabled" else "disabled";
        slog.info("Auto-minimize toggled: {s}", .{state});
    }

    /// Sole writer of active_source_hwnd, the single source of truth for who's focused; call instead of setting it directly.
    pub fn reconcileThumbnailStates(self: *Painter, should_be_active_hwnd: ?win32.HWND) void {
        const old_active = self.active_source_hwnd;
        self.active_source_hwnd = should_be_active_hwnd;
        const active_changed = old_active != should_be_active_hwnd;
        if (should_be_active_hwnd) |hwnd| {
            if (self.hwnd_to_thumbnail_index.contains(hwnd)) self.last_focused_source_hwnd = hwnd;
        }

        for (self.thumbnails.items) |*thumbnail| {
            // Unhide automatically-hidden thumbnails when EVE gains focus; manual hiding persists until the user toggles visibility.
            if (thumbnail.visibility_state == .HiddenAutomatic and should_be_active_hwnd != null) {
                thumbnail.setVisibility(.Visible);
                thumbnail.needs_render = true;
            }

            if (active_changed and (thumbnail.source_hwnd == old_active or thumbnail.source_hwnd == should_be_active_hwnd)) {
                thumbnail.needs_render = true;
            }
        }
    }

    /// Updates system name for a character using HWND (O(1) lookup); see ThumbnailWindow.system_name_event_ts and .last_jump_ms for `event_ts`/`is_jump`.
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
        thumbnail.cached_system_color = self.config.getSystemNameColor(system_name);
        thumbnail.cached_sys_dims = null;
        slog.debug("System '{s}' color resolved to: 0x{X:0>6}", .{ system_name, thumbnail.cached_system_color & 0xFFFFFF });

        if (is_jump) {
            thumbnail.last_jump_ms = std.time.milliTimestamp();
            thumbnail.travel_alert_fired = false;
        }

        thumbnail.needs_render = true;
        slog.debug("Updated system for {s}: {s}", .{ thumbnail.character_name, system_name });
    }

    pub fn showNotification(
        self: *Painter,
        source_hwnd: win32.HWND,
        notification_text: []const u8,
        notification_type: types.NotificationType,
    ) !void {
        if (self.getThumbnailBySourceHwnd(source_hwnd)) |thumbnail| {
            if (!self.config.thumbnail.notifications.enabled) return;

            const type_config = self.config.thumbnail.notifications.getTypeConfig(notification_type);

            if (!type_config.enabled) return;

            const is_focused = thumbnail.isFocused(self.active_source_hwnd);
            if (type_config.suppress_when_focused and is_focused) {
                return;
            }

            if (type_config.suppress_when_clicked) {
                const now = win32.GetTickCount64();
                if (now - thumbnail.last_click_time < self.config.thumbnail.notifications.suppress_click_duration_ms) {
                    return;
                }
            }

            if (type_config.throttle_ms > 0) {
                const last = thumbnail.last_notification_time_by_type.get(notification_type);
                if (last != 0 and win32.GetTickCount64() - last < type_config.throttle_ms) {
                    return;
                }
            }
            thumbnail.last_notification_time_by_type.set(notification_type, win32.GetTickCount64());

            self.pushNotification(thumbnail, .{
                .text = try self.allocator.dupe(u8, notification_text),
                .notification_type = notification_type,
                .start_time = win32.GetTickCount64(),
                .duration_ms = type_config.duration_ms,
                .suppress_when_focused = type_config.suppress_when_focused,
                .suppress_when_clicked = type_config.suppress_when_clicked,
                .border_color_override = type_config.border_color,
                .text_color_override = type_config.text_color,
                .show_border = type_config.show_border,
                .flash_border = type_config.flash_border,
            });

            self.trackNotifiedCharacter(thumbnail.character_name);
            self.pushNotificationHistory(source_hwnd, thumbnail.character_name, notification_text, notification_type);

            // Speaks the same phrase the visual notification shows, gated by the master switch plus this type's own opt-in.
            if (self.config.thumbnail.notifications.tts_enabled and type_config.tts_enabled) {
                tts.setVoiceSettings(self.config.thumbnail.notifications.tts_volume, self.config.thumbnail.notifications.tts_rate);
                if (self.config.thumbnail.notifications.tts_speak_character_name and thumbnail.character_name.len > 0) {
                    const spoken_name = if (self.config.thumbnail.notifications.tts_use_display_name)
                        thumbnail.cached_display_name
                    else
                        thumbnail.character_name;
                    var speak_buf: [256]u8 = undefined;
                    const spoken = std.fmt.bufPrint(&speak_buf, "{s}, {s}", .{ spoken_name, notification_text }) catch notification_text;
                    tts.speakAlert(spoken);
                } else {
                    tts.speakAlert(notification_text);
                }
            }

            slog.debug("Queued notification for {s}: [{s}] {s} (border_color_override: {?})", .{ thumbnail.character_name, @tagName(notification_type), notification_text, type_config.border_color });
            return;
        }

        // Window not found - this can happen if thumbnail hasn't been created yet
        slog.debug("Window 0x{x} not found for notification update (thumbnail may not exist yet)", .{@intFromPtr(source_hwnd)});
    }

    /// Flags characters behind the group's current system by more than config.travel.window_seconds.
    pub fn checkTravelLeftBehind(self: *Painter, now_ms: i64) void {
        const cfg = self.config.travel;
        if (!cfg.enabled) return;

        var eligible_count: usize = 0;
        for (self.thumbnails.items) |*thumb| {
            if (thumb.last_jump_ms == 0 or isCharacterTravelExcluded(thumb.character_name)) continue;
            eligible_count += 1;
        }
        if (eligible_count < 2) return;

        var group_system: []const u8 = "";
        var group_count: usize = 0;
        var group_arrival_ms: i64 = 0;

        for (self.thumbnails.items) |*candidate| {
            if (candidate.last_jump_ms == 0 or isCharacterTravelExcluded(candidate.character_name)) continue;

            var count: usize = 0;
            var arrival_ms: i64 = 0;
            for (self.thumbnails.items) |*other| {
                if (other.last_jump_ms == 0 or isCharacterTravelExcluded(other.character_name)) continue;
                if (!std.mem.eql(u8, other.system_name, candidate.system_name)) continue;
                count += 1;
                if (other.last_jump_ms > arrival_ms) arrival_ms = other.last_jump_ms;
            }

            if (count > group_count) {
                group_count = count;
                group_system = candidate.system_name;
                group_arrival_ms = arrival_ms;
            }
        }
        if (group_count == 0) return;

        const required: usize = switch (cfg.threshold_mode) {
            .percent => @intFromFloat(@ceil(cfg.threshold_percent / 100.0 * @as(f32, @floatFromInt(eligible_count)))),
            .count => cfg.threshold_count,
        };
        if (group_count < required) return;

        const window_ms: i64 = @as(i64, cfg.window_seconds) * 1000;
        if (now_ms - group_arrival_ms < window_ms) return;

        for (self.thumbnails.items) |*thumb| {
            if (thumb.last_jump_ms == 0 or isCharacterTravelExcluded(thumb.character_name)) continue;
            if (std.mem.eql(u8, thumb.system_name, group_system)) continue;
            if (thumb.travel_alert_fired) continue;

            thumb.travel_alert_fired = true;
            var buf: [96]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "Left behind in {s}", .{thumb.system_name}) catch "Left behind";
            self.showNotification(thumb.source_hwnd, text, .TravelLeftBehind) catch |err| {
                slog.err("Failed to show travel left-behind notification for {s}: {}", .{ thumb.character_name, err });
            };
        }
    }

    /// Inserts `entry` at the front of thumbnail's notification stack (newest first). Replaces any existing entry of the
    /// same notification_type in place (bump-to-top) and evicts the oldest entry once the stack is at MAX_STACKED_NOTIFICATIONS.
    pub fn pushNotification(self: *Painter, thumbnail: *ThumbnailWindow, entry: ActiveNotification) void {
        var count: usize = 0;
        while (count < MAX_STACKED_NOTIFICATIONS and thumbnail.active_notifications[count] != null) : (count += 1) {}

        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (thumbnail.active_notifications[i].?.notification_type == entry.notification_type) {
                self.allocator.free(thumbnail.active_notifications[i].?.text);
                var j = i;
                while (j + 1 < count) : (j += 1) {
                    thumbnail.active_notifications[j] = thumbnail.active_notifications[j + 1];
                }
                count -= 1;
                break;
            }
        }

        if (count == MAX_STACKED_NOTIFICATIONS) {
            self.allocator.free(thumbnail.active_notifications[count - 1].?.text);
            count -= 1;
        }

        var k = count;
        while (k > 0) : (k -= 1) {
            thumbnail.active_notifications[k] = thumbnail.active_notifications[k - 1];
        }
        thumbnail.active_notifications[0] = entry;

        thumbnail.needs_render = true;
    }

    /// Removes every stacked notification with suppress_when_clicked set (used by input.zig's click handler). Returns whether anything was removed.
    pub fn dismissClickSuppressedNotifications(self: *Painter, thumbnail: *ThumbnailWindow) bool {
        var write_idx: usize = 0;
        var removed_any = false;
        var read_idx: usize = 0;
        while (read_idx < MAX_STACKED_NOTIFICATIONS) : (read_idx += 1) {
            const entry = thumbnail.active_notifications[read_idx] orelse break;
            if (entry.suppress_when_clicked) {
                self.allocator.free(entry.text);
                removed_any = true;
                continue;
            }
            thumbnail.active_notifications[write_idx] = entry;
            write_idx += 1;
        }
        while (write_idx < MAX_STACKED_NOTIFICATIONS) : (write_idx += 1) {
            thumbnail.active_notifications[write_idx] = null;
        }

        if (removed_any) {
            thumbnail.needs_render = true;
        }
        return removed_any;
    }

    /// Pushes/bumps character_name into the "recently notified" FIFO used by the cycle-to-notified-character hotkey; re-notifying bumps to the back instead of duplicating.
    fn trackNotifiedCharacter(self: *Painter, character_name: []const u8) void {
        const now = win32.GetTickCount64();

        for (self.notified_queue.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.character_name, character_name)) {
                const existing = self.notified_queue.orderedRemove(i);
                self.notified_queue.append(self.allocator, .{
                    .character_name = existing.character_name,
                    .notified_at_ms = now,
                }) catch |err| {
                    slog.err("Failed to requeue notified character {s}: {}", .{ character_name, err });
                    self.allocator.free(existing.character_name);
                };
                return;
            }
        }

        const name_dup = self.allocator.dupe(u8, character_name) catch |err| {
            slog.err("Failed to track notified character {s}: {}", .{ character_name, err });
            return;
        };
        self.notified_queue.append(self.allocator, .{ .character_name = name_dup, .notified_at_ms = now }) catch |err| {
            slog.err("Failed to queue notified character {s}: {}", .{ character_name, err });
            self.allocator.free(name_dup);
        };
    }

    /// Caller-owned snapshot of "recently notified" entries within retention_ms, oldest first; returned strings borrow Painter's storage and are valid only until the next trackNotifiedCharacter call.
    /// Caller frees the returned ArrayList itself (not the strings) with out_allocator.
    pub fn getNotifiedCharacterNames(self: *Painter, out_allocator: std.mem.Allocator, retention_ms: u64) !std.ArrayList([]const u8) {
        const now = win32.GetTickCount64();
        var result: std.ArrayList([]const u8) = .empty;
        errdefer result.deinit(out_allocator);

        for (self.notified_queue.items) |entry| {
            if (now - entry.notified_at_ms <= retention_ms) {
                try result.append(out_allocator, entry.character_name);
            }
        }
        return result;
    }

    /// Re-applies opacity and forces a redraw (and resize if needed) of every thumbnail from the current config, unconditionally (ignoring needs_render) for main.zig's config-dialog live preview.
    pub fn refreshAllThumbnailVisuals(self: *Painter) void {
        // Re-evaluate focus against the current foreground window here so a live-preview toggle of hideWhenNoEveFocus reacts immediately instead of waiting for the next focus-change WinEvent.
        const any_eve_has_focus = if (win32.GetForegroundWindow()) |foreground_hwnd|
            self.hwnd_to_thumbnail_index.contains(foreground_hwnd)
        else
            false;

        for (self.thumbnails.items) |*thumbnail| {
            if (!thumbnail.win32_enabled) continue;

            if (self.config.thumbnail.hideWhenNoEveFocus and !any_eve_has_focus) {
                if (thumbnail.visibility_state == .Visible) thumbnail.setVisibility(.HiddenAutomatic);
            } else if (thumbnail.visibility_state == .HiddenAutomatic) {
                thumbnail.setVisibility(.Visible);
            }

            // thumbnailOpacity is otherwise only applied once, at window creation time.
            _ = win32.SetLayeredWindowAttributes(thumbnail.hwnd, 0, self.config.thumbnail.thumbnailOpacity, win32.LWA_ALPHA);
            // Re-resolve here too (normally only done on system-name change) so live-previewed color edits show up immediately.
            thumbnail.cached_system_color = if (thumbnail.system_name.len > 0)
                self.config.getSystemNameColor(thumbnail.system_name)
            else
                self.config.thumbnail.systemNameColor;
            thumbnail.cached_character_color = self.config.getCharacterNameColor(thumbnail.character_name);
            thumbnail.cached_display_name = self.config.getDisplayName(thumbnail.character_name);
            self.resizeThumbnailIfNeeded(thumbnail);
            // RenderSettings' equality check only compares character_name, so it can miss a change to one of the resolved fields above; force the full-render path since this only runs on debounced (~120ms) preview edits.
            thumbnail.cached_render_settings = null;
            // Force re-measurement: a display-name-only edit changes the string without touching the font, which is otherwise the only re-measure trigger.
            thumbnail.cached_char_dims = null;
            thumbnail.cached_sys_dims = null;
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
        const monitor_placement = resolveMonitorPlacement(cfg);
        const monitor_bounds = if (monitor_placement) |mp| mp.bounds else null;
        const scale = dpiToScale(if (monitor_placement) |mp| getMonitorDpi(mp.monitor) else defaultDpi());
        for (self.thumbnails.items, 0..) |thumbnail, index| {
            if (!thumbnail.win32_enabled) continue;
            const thumb_size = self.getThumbnailSize(thumbnail.character_name);
            const scaled_width = scalePixels(thumb_size.width, scale);
            const scaled_height = scalePixels(thumb_size.height, scale);
            const pos = self.calculateThumbnailPosition(thumbnail.character_name, scaled_width, scaled_height, index, monitor_bounds, scale);
            hdwp = win32.DeferWindowPos(hdwp, thumbnail.hwnd, win32.HWND_NOTOPMOST, pos.x, pos.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE) orelse return;
            hdwp = win32.DeferWindowPos(hdwp, thumbnail.text_hwnd, win32.HWND_TOPMOST, pos.x, pos.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOACTIVATE) orelse return;
        }
        _ = win32.EndDeferWindowPos(hdwp);
    }

    /// Resizes a thumbnail's window and DWM rect to the DPI-scaled configured size if changed; text_hwnd resizes separately via UpdateLayeredWindow.
    pub fn resizeThumbnailIfNeeded(self: *Painter, thumbnail: *ThumbnailWindow) void {
        const logical = self.getThumbnailSize(thumbnail.character_name);
        const scale = dpiToScale(getWindowDpi(thumbnail.hwnd));
        const target_width = scalePixels(logical.width, scale);
        const target_height = scalePixels(logical.height, scale);

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

    fn processDirtyThumbnails(self: *Painter) !void {
        self.renderDirtyThumbnails(null);
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

    /// Re-render thumbnails with updated DPS values (called from main timer loop)
    pub fn processDirtyDpsOverlays(self: *Painter) void {
        self.processDirtyThumbnails() catch |err| {
            slog.err("Failed to render thumbnails after DPS update: {}", .{err});
        };
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

    /// Unconditionally clears the entire notification stack (e.g. on character logout), same as a full natural expiry.
    fn clearAllNotifications(self: *Painter, thumbnail: *ThumbnailWindow) void {
        var had_any = false;
        for (&thumbnail.active_notifications) |*slot| {
            if (slot.*) |notif| {
                self.allocator.free(notif.text);
                slot.* = null;
                had_any = true;
            }
        }
        if (!had_any) return;

        thumbnail.needs_render = true;
    }

    /// Clear expired notifications (call from update loop)
    pub fn updateNotifications(self: *Painter) void {
        const now = win32.GetTickCount64();

        for (self.thumbnails.items) |*thumbnail| {
            var write_idx: usize = 0;
            var any_expired = false;
            var read_idx: usize = 0;
            while (read_idx < MAX_STACKED_NOTIFICATIONS) : (read_idx += 1) {
                const notif = thumbnail.active_notifications[read_idx] orelse break;
                // duration_ms == 0 means the notification is permanent.
                if (notif.duration_ms > 0 and (now - notif.start_time) >= notif.duration_ms) {
                    self.allocator.free(notif.text);
                    any_expired = true;
                    continue;
                }
                thumbnail.active_notifications[write_idx] = notif;
                write_idx += 1;
            }

            if (any_expired) {
                while (write_idx < MAX_STACKED_NOTIFICATIONS) : (write_idx += 1) {
                    thumbnail.active_notifications[write_idx] = null;
                }
                thumbnail.needs_render = true;
            }

            // Force a render each tick so the newest entry's alternating on/off flash phases actually paint.
            if (thumbnail.active_notifications[0]) |notif| {
                if (notif.flash_border and (now - notif.start_time) < NOTIFICATION_FLASH_TOTAL_MS) {
                    thumbnail.needs_render = true;
                }
            }
        }
    }

    /// Reacts to Scout's name-change events: syncs the affected thumbnail's name/title and runs the associated side effects (position restore, system-name clear, exclusion restore).
    pub fn applyNameChanges(self: *Painter, name_changes: []const scout_mod.NameChange, eve_windows: []const scout_mod.EveWindow) void {
        for (name_changes) |change| {
            const thumbnail = self.getThumbnailBySourceHwnd(change.hwnd) orelse continue;

            const was_generic = scout_mod.isGenericCharacterName(change.old_name);
            const now_specific = !scout_mod.isGenericCharacterName(change.new_name);

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
            thumbnail.cached_char_dims = null;
            thumbnail.cached_display_name = self.config.getDisplayName(new_char_dup);
            thumbnail.cached_active_border_override = if (self.config.getCharacterBorderColors(new_char_dup)) |c| c.activeBorderColor else null;
            thumbnail.cached_character_color = self.config.getCharacterNameColor(new_char_dup);

            // If character logged in (changed from "EVE" to actual name), move the thumbnail box to its remembered spot
            if (was_generic and now_specific) {
                if (thumbnail.win32_enabled) {
                    if (self.config.getCharacterPosition(change.new_name)) |saved_pos| {
                        const thumb_size = self.getThumbnailSize(change.new_name);
                        _ = win32.SetWindowPos(thumbnail.hwnd, win32.HWND_NOTOPMOST, saved_pos.x, saved_pos.y, thumb_size.width, thumb_size.height, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
                        _ = win32.SetWindowPos(thumbnail.text_hwnd, win32.HWND_TOPMOST, saved_pos.x, saved_pos.y, thumb_size.width, thumb_size.height, win32.SWP_NOACTIVATE);
                        slog.info("Moved {s} thumbnail to saved position: ({}, {})", .{ change.new_name, saved_pos.x, saved_pos.y });
                    } else {
                        slog.debug("No saved thumbnail position for {s}, keeping current location", .{change.new_name});
                    }
                }

                // Auto-move-on-login setting: same action as the hotkey, but for the real EVE client window
                if (self.config.autoMovePosition.enabled) {
                    if (self.config.getCharacterWindowPosition(change.new_name)) |window_pos| {
                        manager_mod.moveClientToPosition(thumbnail.source_hwnd, window_pos);
                        slog.info("Auto-moved {s} client window to saved position: ({}, {})", .{ change.new_name, window_pos.x, window_pos.y });
                    } else {
                        slog.debug("No saved window position for {s}, auto-move-on-login skipped", .{change.new_name});
                    }
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
                thumbnail.cached_sys_dims = null;
                slog.debug("Cleared system name for logged out client", .{});

                self.clearAllNotifications(thumbnail);
            }

            // Update exclusion state when character name becomes known (e.g., "EVE" -> "Probe Enthusiast")
            if (was_generic and now_specific) {
                if (g_hotkey_manager_ptr) |manager| {
                    const is_excluded = manager.isCharacterExcluded(change.new_name);
                    if (is_excluded != thumbnail.is_excluded_from_cycle) {
                        thumbnail.is_excluded_from_cycle = is_excluded;
                        if (is_excluded) {
                            slog.info("Restored exclusion state for {s}", .{change.new_name});
                        }
                    }
                }
            }

            self.renderThumbnailLogged(thumbnail, "name change");

            slog.info("Updated thumbnail for {s}", .{thumbnail.character_name});
        }
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
    fn syncThumbnailsWithWindows(self: *Painter, eve_windows: []const scout_mod.EveWindow) bool {
        var created_new = false;

        for (eve_windows) |eve_window| {
            if (!self.hasThumbnail(eve_window.hwnd)) {
                self.createThumbnail(&eve_window, "") catch |err| {
                    slog.err("Failed to create thumbnail for {s}: {}", .{ eve_window.character_name, err });
                    continue;
                };
                created_new = true;
            }
        }

        return created_new;
    }

    /// Main update cycle - performs all Painter operations for a single tick
    pub fn update(self: *Painter, eve_windows: []const scout_mod.EveWindow, closed_windows: []const scout_mod.ClosedWindow, name_changes: []const scout_mod.NameChange) !void {
        self.cleanupClosedThumbnails(closed_windows);
        self.updateThumbnailStates();
        self.checkAutoMinimize();
        self.applyNameChanges(name_changes, eve_windows);
        self.syncThumbnailTitles(eve_windows);

        // createThumbnail seeds title/character_name from eve_window, so new thumbnails need no re-sync.
        _ = self.syncThumbnailsWithWindows(eve_windows);

        // Thumbnail-mode only — ClientList has no Win32 windows to redraw here.
        try self.processDirtyThumbnails();

        if (self.list_window) |*lw| {
            lw.render(self.thumbnails.items, self.active_source_hwnd) catch |err| {
                slog.err("Failed to render list window: {}", .{err});
            };
        }

        {
            const characters_logged_in = self.anyCharacterLoggedIn();
            if (self.notif_history_had_characters and !characters_logged_in) {
                self.notif_history_force_visible = false;
            }
            self.notif_history_had_characters = characters_logged_in;
        }

        if (self.notif_info_window) |*niw| {
            if (self.isNotifInfoPanelVisible()) {
                niw.render(self) catch |err| {
                    slog.err("Failed to render notification history window: {}", .{err});
                };
            } else {
                niw.hide();
            }
        }
    }

    /// True when at least one tracked EVE client currently has a real (non-generic) character name, i.e. is logged in.
    pub fn anyCharacterLoggedIn(self: *const Painter) bool {
        for (self.thumbnails.items) |thumbnail| {
            if (!scout_mod.isGenericCharacterName(thumbnail.character_name)) return true;
        }
        return false;
    }

    /// Whether the History Panel is actually on-screen right now, accounting for hideNotifInfoPanelWhenNoCharacters and the tray-toggle force override; drives both the render/hide gate and the tray menu's checked state.
    pub fn isNotifInfoPanelVisible(self: *const Painter) bool {
        if (self.notif_info_window == null) return false;
        if (!self.config.display.hideNotifInfoPanelWhenNoCharacters) return true;
        return self.anyCharacterLoggedIn() or self.notif_history_force_visible;
    }

    /// Toggles the history panel between visible and off, keyed on isNotifInfoPanelVisible() rather than mere window existence so it turns fully off (not re-hidden) when clicked while visible, and forces it on immediately - even with no characters logged in - when clicked while off/auto-hidden. Used by the tray menu's "Show History Panel" item.
    pub fn toggleNotifInfoPanel(self: *Painter) void {
        if (self.isNotifInfoPanelVisible()) {
            if (self.notif_info_window) |*niw| {
                niw.deinit();
                self.notif_info_window = null;
            }
            self.config.display.showNotifInfoPanel = false;
            self.notif_history_force_visible = false;
        } else {
            if (self.notif_info_window == null) {
                self.notif_info_window = notif_info_view.NotifInfoWindow.init(self.allocator, self.config, self.instance) catch |err| {
                    slog.err("Failed to create notification history window: {}", .{err});
                    return;
                };
            }
            self.config.display.showNotifInfoPanel = true;
            self.notif_history_force_visible = true;
        }
    }

    /// Resets the notification-history ring buffer; used by the tray menu's "Clear Notification History" action.
    pub fn clearNotificationHistory(self: *Painter) void {
        self.notification_history_head = 0;
        self.notification_history_count = 0;
    }

    /// Returns the notification-history ring buffer entries in newest-first order, written into `out` (capped to NOTIF_HISTORY_CAPACITY and out.len).
    pub fn getNotificationHistory(self: *const Painter, out: []NotificationHistoryEntry) []NotificationHistoryEntry {
        const n = @min(self.notification_history_count, out.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const idx = (self.notification_history_head + NOTIF_HISTORY_CAPACITY - 1 - i) % NOTIF_HISTORY_CAPACITY;
            out[i] = self.notification_history[idx];
        }
        return out[0..n];
    }

    /// Appends a notification to the history ring buffer (overwrites the oldest entry once full); called from showNotification for every notification actually shown.
    fn pushNotificationHistory(self: *Painter, source_hwnd: win32.HWND, character_name: []const u8, notification_text: []const u8, notification_type: types.NotificationType) void {
        var entry: NotificationHistoryEntry = .{ .source_hwnd = source_hwnd, .notification_type = notification_type, .timestamp_ms = win32.GetTickCount64() };

        const name_n = @min(character_name.len, entry.character_name_buf.len);
        @memcpy(entry.character_name_buf[0..name_n], character_name[0..name_n]);
        entry.character_name_len = @intCast(name_n);

        const text_n = @min(notification_text.len, entry.text_buf.len);
        @memcpy(entry.text_buf[0..text_n], notification_text[0..text_n]);
        entry.text_len = @intCast(text_n);

        self.notification_history[self.notification_history_head] = entry;
        self.notification_history_head = (self.notification_history_head + 1) % NOTIF_HISTORY_CAPACITY;
        if (self.notification_history_count < NOTIF_HISTORY_CAPACITY) self.notification_history_count += 1;
    }

    fn registerWindowClass(self: *Painter) !void {
        if (g_window_class_registered) return;

        const cursor = win32.LoadCursorA(null, win32.IDC_ARROW);

        // Black, not white COLOR_WINDOW: shows through whenever DWM has no live thumbnail frame to composite.
        const thumbnail_bg_brush = win32.CreateSolidBrush(0x00000000) orelse return error.CreateBrushFailed;

        const wc = win32.WNDCLASSEXA{
            .cbSize = @sizeOf(win32.WNDCLASSEXA),
            .style = 0,
            .lpfnWndProc = input.getWindowProc(),
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.instance,
            .hIcon = null,
            .hCursor = cursor,
            .hbrBackground = thumbnail_bg_brush,
            .lpszMenuName = null,
            .lpszClassName = WINDOW_CLASS_NAME,
            .hIconSm = null,
        };

        if (win32.RegisterClassExA(&wc) == 0) {
            return error.RegisterClassFailed;
        }

        const text_wc = win32.WNDCLASSEXA{
            .cbSize = @sizeOf(win32.WNDCLASSEXA),
            .style = 0,
            .lpfnWndProc = input.getTextWindowProc(),
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.instance,
            .hIcon = null,
            .hCursor = cursor,
            // No background brush for a layered window.
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = TEXT_WINDOW_CLASS_NAME,
            .hIconSm = null,
        };

        if (win32.RegisterClassExA(&text_wc) == 0) {
            return error.RegisterTextClassFailed;
        }

        const ghost_wc = win32.WNDCLASSEXA{
            .cbSize = @sizeOf(win32.WNDCLASSEXA),
            .style = 0,
            .lpfnWndProc = win32.DefWindowProcA,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.instance,
            .hIcon = null,
            .hCursor = cursor,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = GHOST_WINDOW_CLASS_NAME,
            .hIconSm = null,
        };

        if (win32.RegisterClassExA(&ghost_wc) == 0) {
            return error.RegisterGhostClassFailed;
        }

        g_window_class_registered = true;
    }

    const MonitorEnumData = struct {
        target_index: u32,
        current_index: u32,
        found_monitor: ?win32.HMONITOR,
    };

    fn monitorEnumProc(
        hMonitor: win32.HMONITOR,
        hdcMonitor: ?win32.HDC,
        lprcMonitor: ?*win32.RECT,
        dwData: win32.LPARAM,
    ) callconv(.c) win32.BOOL {
        _ = hdcMonitor;
        _ = lprcMonitor;

        const data: *MonitorEnumData = win32.lparamToPtr(MonitorEnumData, dwData);

        if (data.current_index == data.target_index) {
            data.found_monitor = hMonitor;
            // FALSE stops EnumDisplayMonitors.
            return win32.FALSE;
        }

        data.current_index += 1;
        // TRUE continues enumeration.
        return win32.TRUE;
    }

    const MonitorPlacement = struct {
        bounds: win32.RECT,
        monitor: win32.HMONITOR,
    };

    /// Get monitor bounds and handle by 0-based index; null if out of range.
    fn getMonitorPlacement(monitor_index: u32, use_work_area: bool) ?MonitorPlacement {
        var enum_data = MonitorEnumData{
            .target_index = monitor_index,
            .current_index = 0,
            .found_monitor = null,
        };

        const result = win32.EnumDisplayMonitors(
            null,
            null,
            monitorEnumProc,
            win32.ptrToLparam(&enum_data),
        );
        _ = result;

        // result is FALSE whenever we stopped enumeration early on a match, not an error.
        if (enum_data.found_monitor == null) {
            slog.warn("Monitor index {} not found (total monitors available: {})", .{ monitor_index, enum_data.current_index });
            return null;
        }

        var monitor_info = win32.MONITORINFO{
            .cbSize = @sizeOf(win32.MONITORINFO),
            .rcMonitor = undefined,
            .rcWork = undefined,
            .dwFlags = 0,
        };

        if (win32.GetMonitorInfoA(enum_data.found_monitor.?, &monitor_info) == win32.FALSE) {
            slog.err("Failed to get monitor info for monitor index {}", .{monitor_index});
            return null;
        }

        return .{
            // Work area (excludes taskbar) or full monitor bounds
            .bounds = if (use_work_area) monitor_info.rcWork else monitor_info.rcMonitor,
            .monitor = enum_data.found_monitor.?,
        };
    }

    /// DPI for a specific monitor; used before a window exists on it yet.
    fn getMonitorDpi(hmonitor: win32.HMONITOR) u32 {
        var dpi_x: win32.UINT = 96;
        var dpi_y: win32.UINT = 96;
        _ = win32.GetDpiForMonitor(hmonitor, win32.MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
        return dpi_x;
    }

    /// DPI of whichever monitor a window currently sits on; queried live, nothing to invalidate.
    fn getWindowDpi(hwnd: win32.HWND) u32 {
        return win32.GetDpiForWindow(hwnd);
    }

    /// DPI for the system default monitor; used as a fallback when no target monitor is configured.
    fn defaultDpi() u32 {
        return win32.GetDpiForSystem();
    }

    fn dpiToScale(dpi: u32) f32 {
        return @as(f32, @floatFromInt(dpi)) / 96.0;
    }

    fn resolveMonitorPlacement(cfg: *const config_mod.Config.DisplayConfig) ?MonitorPlacement {
        return if (cfg.monitorIndex) |monitor_idx| getMonitorPlacement(monitor_idx, cfg.useMonitorWorkArea) else null;
    }

    /// Clamps *value into [min, max], warning with axis_label/low_word/high_word/context worked into the message on either bound.
    fn clampAxisWithWarn(value: *i32, min: i32, max: i32, axis_label: []const u8, low_word: []const u8, high_word: []const u8, context: []const u8) void {
        if (value.* < min) {
            slog.warn("Thumbnail {s} position {} too far {s}{s}, clamping to {}", .{ axis_label, value.*, low_word, context, min });
            value.* = min;
        } else if (value.* > max) {
            slog.warn("Thumbnail {s} position {} too far {s}{s}, clamping to {}", .{ axis_label, value.*, high_word, context, max });
            value.* = max;
        }
    }

    fn calculateThumbnailPosition(
        self: *const Painter,
        character_name: []const u8,
        thumb_width: i32,
        thumb_height: i32,
        index: usize,
        monitor_bounds: ?win32.RECT,
        scale: f32,
    ) config_mod.Position {
        const cfg = &self.config.display;

        const is_generic = scout_mod.isGenericCharacterName(character_name);
        const use_saved_position = !is_generic and
            cfg.honorSavedPositions and
            self.config.getCharacterPosition(character_name) != null;

        if (use_saved_position) {
            // Saved positions are absolute physical pixels (see saveThumbnailPosition), so scaling doesn't apply.
            const saved_pos = self.config.getCharacterPosition(character_name).?;
            slog.debug("Using saved position for {s}: ({}, {})", .{ character_name, saved_pos.x, saved_pos.y });
            return .{ .x = saved_pos.x, .y = saved_pos.y };
        }

        var pos = switch (cfg.layoutMode) {
            .Custom => blk: {
                slog.debug("Custom layout mode, no saved position, using origin", .{});
                break :blk config_mod.Position{ .x = scalePixels(cfg.startX, scale), .y = scalePixels(cfg.startY, scale) };
            },
            .Overlay => blk: {
                slog.debug("Overlay mode, spawning thumbnail #{} at ({}, {})", .{ index, cfg.startX, cfg.startY });
                break :blk config_mod.Position{ .x = scalePixels(cfg.startX, scale), .y = scalePixels(cfg.startY, scale) };
            },
            .Grid => self.calculateGridPosition(index, thumb_width, thumb_height, scale),
            .VerticalStack => self.calculateStackPosition(index, thumb_width, thumb_height, true, scale),
            .HorizontalStack => self.calculateStackPosition(index, thumb_width, thumb_height, false, scale),
            .VerticalList => self.calculateListPosition(index, thumb_width, thumb_height, true, scale),
            .HorizontalList => self.calculateListPosition(index, thumb_width, thumb_height, false, scale),
        };

        var bounds_for_clamping: ?win32.RECT = null;
        if (monitor_bounds) |bounds| {
            // Position is relative to monitor's top-left corner
            pos.x += bounds.left;
            pos.y += bounds.top;
            bounds_for_clamping = bounds;
        }

        // Clamp to keep thumbnails from spawning fully off-screen, while still allowing edge placement.
        const clamp_margin = 50;

        if (bounds_for_clamping) |bounds| {
            const min_x = bounds.left - clamp_margin;
            const max_x = bounds.right - thumb_width + clamp_margin;
            const min_y = bounds.top - clamp_margin;
            const max_y = bounds.bottom - thumb_height + clamp_margin;

            clampAxisWithWarn(&pos.x, min_x, max_x, "X", "left", "right", " for monitor");
            clampAxisWithWarn(&pos.y, min_y, max_y, "Y", "up", "down", " for monitor");
        } else {
            const min_x = -3840 - clamp_margin;
            const max_x = 7680 - thumb_width + clamp_margin;
            const min_y = -2160 - clamp_margin;
            const max_y = 4320 - thumb_height + clamp_margin;

            clampAxisWithWarn(&pos.x, min_x, max_x, "X", "left", "right", "");
            clampAxisWithWarn(&pos.y, min_y, max_y, "Y", "up", "down", "");
        }

        return pos;
    }

    fn calculateGridPosition(
        self: *const Painter,
        index: usize,
        thumb_width: i32,
        thumb_height: i32,
        scale: f32,
    ) config_mod.Position {
        const cfg = &self.config.display;
        const spacing_x = scalePixels(cfg.getSpacingX(), scale);
        const spacing_y = scalePixels(cfg.getSpacingY(), scale);
        const columns = cfg.gridColumns;

        var col: i32 = undefined;
        var row: i32 = undefined;

        switch (cfg.layoutDirection) {
            .RowFirst_LTR_TTB => {
                col = @intCast(index % columns);
                row = @intCast(index / columns);
            },
            .RowFirst_RTL_TTB => {
                col = @as(i32, @intCast(columns - 1)) - @as(i32, @intCast(index % columns));
                row = @intCast(index / columns);
            },
            .RowFirst_LTR_BTT => {
                col = @intCast(index % columns);
                row = -@as(i32, @intCast(index / columns));
            },
            .RowFirst_RTL_BTT => {
                col = @as(i32, @intCast(columns - 1)) - @as(i32, @intCast(index % columns));
                row = -@as(i32, @intCast(index / columns));
            },
            .ColumnFirst_TTB_LTR => {
                const rows = cfg.gridRows orelse 999;
                col = @intCast(index / rows);
                row = @intCast(index % rows);
            },
            .ColumnFirst_BTT_LTR => {
                const rows = cfg.gridRows orelse 999;
                col = @intCast(index / rows);
                row = -@as(i32, @intCast(index % rows));
            },
            .ColumnFirst_TTB_RTL => {
                const rows = cfg.gridRows orelse 999;
                col = -@as(i32, @intCast(index / rows));
                row = @intCast(index % rows);
            },
            .ColumnFirst_BTT_RTL => {
                const rows = cfg.gridRows orelse 999;
                col = -@as(i32, @intCast(index / rows));
                row = -@as(i32, @intCast(index % rows));
            },
            else => {
                // Fallback to simple left-to-right, top-to-bottom
                col = @intCast(index % columns);
                row = @intCast(index / columns);
            },
        }

        const start_x = scalePixels(cfg.startX, scale);
        const start_y = scalePixels(cfg.startY, scale);
        const x = col * (thumb_width + spacing_x) + start_x;
        const y = row * (thumb_height + spacing_y) + start_y;

        slog.debug("Grid layout: thumbnail #{} at ({}, {}) [col={}, row={}]", .{ index, x, y, col, row });
        return .{ .x = x, .y = y };
    }

    fn calculateStackPosition(
        self: *const Painter,
        index: usize,
        thumb_width: i32,
        thumb_height: i32,
        is_vertical: bool,
        scale: f32,
    ) config_mod.Position {
        const cfg = &self.config.display;
        const start_x = scalePixels(cfg.startX, scale);
        const start_y = scalePixels(cfg.startY, scale);
        const offset = scalePixels(cfg.stackOffset, scale);
        const idx = @as(i32, @intCast(index));
        const alignment = cfg.stackAlignment;

        if (is_vertical) {
            // Vertical stack - align on secondary axis (horizontal/X)
            const y = start_y + (idx * (thumb_height + offset));
            var x = start_x;

            switch (alignment) {
                .TopLeft, .LeftCenter, .BottomLeft => {
                    x = start_x;
                },
                .TopCenter, .Center, .BottomCenter => {
                    x = start_x - @divTrunc(thumb_width, 2);
                },
                .TopRight, .RightCenter, .BottomRight => {
                    x = start_x - thumb_width;
                },
            }

            slog.debug("Vertical stack: thumbnail #{} at ({}, {}) [alignment={}]", .{ index, x, y, alignment });
            return .{ .x = x, .y = y };
        } else {
            // Horizontal stack - align on secondary axis (vertical/Y)
            const x = start_x + (idx * (thumb_width + offset));
            var y = start_y;

            switch (alignment) {
                .TopLeft, .TopCenter, .TopRight => {
                    y = start_y;
                },
                .LeftCenter, .Center, .RightCenter => {
                    y = start_y - @divTrunc(thumb_height, 2);
                },
                .BottomLeft, .BottomCenter, .BottomRight => {
                    y = start_y - thumb_height;
                },
            }

            slog.debug("Horizontal stack: thumbnail #{} at ({}, {}) [alignment={}]", .{ index, x, y, alignment });
            return .{ .x = x, .y = y };
        }
    }

    fn calculateListPosition(
        self: *const Painter,
        index: usize,
        thumb_width: i32,
        thumb_height: i32,
        is_vertical: bool,
        scale: f32,
    ) config_mod.Position {
        const cfg = &self.config.display;
        const spacing_x = scalePixels(cfg.getSpacingX(), scale);
        const spacing_y = scalePixels(cfg.getSpacingY(), scale);
        const start_x = scalePixels(cfg.startX, scale);
        const start_y = scalePixels(cfg.startY, scale);

        if (is_vertical) {
            // Vertical list (multiple columns, fill top-to-bottom first)
            const rows = cfg.gridRows orelse 999;
            const col = @as(i32, @intCast(index / rows));
            const row = @as(i32, @intCast(index % rows));
            const x = col * (thumb_width + spacing_x) + start_x;
            const y = row * (thumb_height + spacing_y) + start_y;
            slog.debug("Vertical list: thumbnail #{} at ({}, {}) [col={}, row={}]", .{ index, x, y, col, row });
            return .{ .x = x, .y = y };
        } else {
            // Horizontal list (multiple rows, fill left-to-right first)
            const cols = cfg.gridColumns;
            const col = @as(i32, @intCast(index % cols));
            const row = @as(i32, @intCast(index / cols));
            const x = col * (thumb_width + spacing_x) + start_x;
            const y = row * (thumb_height + spacing_y) + start_y;
            slog.debug("Horizontal list: thumbnail #{} at ({}, {}) [col={}, row={}]", .{ index, x, y, col, row });
            return .{ .x = x, .y = y };
        }
    }

    fn determineInitialVisibility(
        self: *const Painter,
        source_hwnd: win32.HWND,
    ) state_mod.VisibilityState {
        const foreground_hwnd = win32.GetForegroundWindow();

        var any_eve_has_focus = (source_hwnd == foreground_hwnd);
        if (!any_eve_has_focus) {
            for (self.thumbnails.items) |existing_thumbnail| {
                if (existing_thumbnail.source_hwnd == foreground_hwnd) {
                    any_eve_has_focus = true;
                    break;
                }
            }
        }

        return if (self.config.thumbnail.hideWhenNoEveFocus and !any_eve_has_focus)
            .HiddenAutomatic
        else
            .Visible;
    }

    const ThumbnailStrings = struct {
        title: []const u8,
        character_name: []const u8,
        system_name: []const u8,
        quick_group_label: []const u8,

        fn free(self: ThumbnailStrings, allocator: std.mem.Allocator) void {
            allocator.free(self.title);
            allocator.free(self.character_name);
            allocator.free(self.system_name);
            allocator.free(self.quick_group_label);
        }
    };

    /// Dupes the four owned strings a ThumbnailWindow needs; on partial failure, whatever already succeeded is freed before the error propagates.
    fn dupeThumbnailStrings(allocator: std.mem.Allocator, title: []const u8, character_name: []const u8, system_name: []const u8) !ThumbnailStrings {
        const title_copy = try allocator.dupe(u8, title);
        errdefer allocator.free(title_copy);
        const char_name_copy = try allocator.dupe(u8, character_name);
        errdefer allocator.free(char_name_copy);
        const sys_name_copy = try allocator.dupe(u8, system_name);
        errdefer allocator.free(sys_name_copy);
        const quick_group_label_copy = try allocator.dupe(u8, "");
        errdefer allocator.free(quick_group_label_copy);

        return .{
            .title = title_copy,
            .character_name = char_name_copy,
            .system_name = sys_name_copy,
            .quick_group_label = quick_group_label_copy,
        };
    }

    const ThumbnailCacheFields = struct {
        system_color: u32,
        character_color: ?u32,
        display_name: []const u8,
        active_border_override: ?u32,
    };

    /// Resolves the four config-derived cache fields a freshly-created ThumbnailWindow needs.
    fn resolveThumbnailCacheFields(self: *const Painter, character_name: []const u8, system_name: []const u8) ThumbnailCacheFields {
        return .{
            .system_color = if (system_name.len > 0) self.config.getSystemNameColor(system_name) else self.config.thumbnail.systemNameColor,
            .character_color = self.config.getCharacterNameColor(character_name),
            .display_name = self.config.getDisplayName(character_name),
            .active_border_override = if (self.config.getCharacterBorderColors(character_name)) |c| c.activeBorderColor else null,
        };
    }

    pub fn createThumbnail(self: *Painter, eve_window: *const scout_mod.EveWindow, initial_system_name: []const u8) !void {
        if (self.config.autoMovePosition.enabled) {
            if (self.config.getCharacterWindowPosition(eve_window.character_name)) |pos| {
                manager_mod.moveClientToPosition(eve_window.hwnd, pos);
            }
        }

        // ClientList and Nothing modes only need a data record, not real Win32 windows.
        if (self.config.display.viewMode != .Thumbnails) {
            const initial_visibility = self.determineInitialVisibility(eve_window.hwnd);
            const is_excluded = if (g_hotkey_manager_ptr) |mgr| mgr.isCharacterExcluded(eve_window.character_name) else false;

            const strings = try dupeThumbnailStrings(self.allocator, eve_window.title, eve_window.character_name, initial_system_name);
            errdefer strings.free(self.allocator);
            const cache_fields = self.resolveThumbnailCacheFields(strings.character_name, strings.system_name);

            // Sentinel HWND, never passed to Win32 APIs since win32_enabled is false.
            const sentinel: win32.HWND = @ptrFromInt(1);
            const thumbnail = ThumbnailWindow{
                .hwnd = sentinel,
                .text_hwnd = sentinel,
                .thumbnail_id = sentinel,
                .source_hwnd = eve_window.hwnd,
                .title = strings.title,
                .character_name = strings.character_name,
                .system_name = strings.system_name,
                .cached_system_color = cache_fields.system_color,
                .cached_character_color = cache_fields.character_color,
                .cached_display_name = cache_fields.display_name,
                .cached_active_border_override = cache_fields.active_border_override,
                .cached_quick_group_label = strings.quick_group_label,
                .inactive_since = std.time.milliTimestamp(),
                .visibility_state = initial_visibility,
                .is_excluded_from_cycle = is_excluded,
                .win32_enabled = false,
            };

            try self.thumbnails.append(self.allocator, thumbnail);
            const new_index = self.thumbnails.items.len - 1;
            // Only register source HWND, since thumbnail/text HWNDs are sentinels.
            try self.hwnd_to_thumbnail_index.put(eve_window.hwnd, new_index);

            // This window may already be the real foreground window; reconcile now instead of waiting for the next tick.
            const foreground_hwnd = win32.GetForegroundWindow();
            self.reconcileThumbnailStates(foreground_hwnd);
            if (foreground_hwnd == eve_window.hwnd) {
                if (g_hotkey_manager_ptr) |manager| {
                    manager.updateFocusedCharacter(eve_window.character_name);
                }
            }

            slog.info("Created tracking entry for {s} ({s} mode)", .{ eve_window.character_name, @tagName(self.config.display.viewMode) });
            return;
        }

        // Thumbnail mode: full Win32/DWM path.
        const char_name_z = try self.allocator.dupeZ(u8, eve_window.character_name);
        defer self.allocator.free(char_name_z);

        const logical_size = self.getThumbnailSize(eve_window.character_name);
        const cfg = &self.config.display;
        const monitor_placement = resolveMonitorPlacement(cfg);
        const monitor_bounds = if (monitor_placement) |mp| mp.bounds else null;
        const scale = dpiToScale(if (monitor_placement) |mp| getMonitorDpi(mp.monitor) else defaultDpi());
        const thumb_size = .{
            .width = scalePixels(logical_size.width, scale),
            .height = scalePixels(logical_size.height, scale),
        };
        const pos = self.calculateThumbnailPosition(eve_window.character_name, thumb_size.width, thumb_size.height, self.thumbnails.items.len, monitor_bounds, scale);

        // Create thumbnail window (borderless, layered for transparency)
        const hwnd = win32.CreateWindowExA(
            win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW | win32.WS_EX_LAYERED | win32.WS_EX_NOACTIVATE,
            WINDOW_CLASS_NAME,
            char_name_z.ptr,
            win32.WS_POPUP | win32.WS_VISIBLE,
            pos.x,
            pos.y,
            thumb_size.width,
            thumb_size.height,
            null,
            null,
            self.instance,
            null,
        ) orelse return error.CreateWindowFailed;

        _ = win32.SetLayeredWindowAttributes(hwnd, 0, self.config.thumbnail.thumbnailOpacity, win32.LWA_ALPHA);

        var thumbnail_id: win32.HTHUMBNAIL = undefined;
        const hr = win32.DwmRegisterThumbnail(hwnd, eve_window.hwnd, &thumbnail_id);
        if (hr != 0) {
            _ = win32.DestroyWindow(hwnd);
            return error.DwmRegisterThumbnailFailed;
        }

        // Update thumbnail properties - fill entire window
        var client_rect: win32.RECT = undefined;
        _ = win32.GetClientRect(hwnd, &client_rect);

        const props = makeThumbnailProps(client_rect.right, client_rect.bottom, win32.DWM_TNP_VISIBLE | win32.DWM_TNP_RECTDESTINATION | win32.DWM_TNP_SOURCECLIENTAREAONLY);

        const update_hr = win32.DwmUpdateThumbnailProperties(thumbnail_id, &props);
        if (update_hr != 0) {
            _ = win32.DwmUnregisterThumbnail(thumbnail_id);
            _ = win32.DestroyWindow(hwnd);
            return error.DwmUpdateThumbnailPropertiesFailed;
        }

        _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
        _ = win32.UpdateWindow(hwnd);

        // Covers the full thumbnail, not just a top bar; not WS_EX_TRANSPARENT so the border can actually render.
        const text_hwnd = win32.CreateWindowExA(
            win32.WS_EX_LAYERED | win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW | win32.WS_EX_NOACTIVATE,
            TEXT_WINDOW_CLASS_NAME,
            char_name_z.ptr,
            win32.WS_POPUP,
            pos.x,
            pos.y,
            thumb_size.width,
            thumb_size.height,
            null,
            null,
            self.instance,
            null,
        ) orelse {
            _ = win32.DwmUnregisterThumbnail(thumbnail_id);
            _ = win32.DestroyWindow(hwnd);
            return error.CreateTextWindowFailed;
        };
        errdefer {
            _ = win32.DestroyWindow(text_hwnd);
            _ = win32.DwmUnregisterThumbnail(thumbnail_id);
            _ = win32.DestroyWindow(hwnd);
        }

        const initial_visibility = self.determineInitialVisibility(eve_window.hwnd);

        // Check if character is excluded from hotkey cycling (restore exclusion state after restart)
        const is_excluded = if (g_hotkey_manager_ptr) |manager| blk: {
            const excluded = manager.isCharacterExcluded(eve_window.character_name);
            if (excluded) {
                slog.info("Character {s} is excluded from cycling, setting visual indicator", .{eve_window.character_name});
            }
            break :blk excluded;
        } else blk: {
            slog.debug("Hotkey manager not available during thumbnail creation for {s}", .{eve_window.character_name});
            break :blk false;
        };

        const strings = try dupeThumbnailStrings(self.allocator, eve_window.title, eve_window.character_name, initial_system_name);
        errdefer strings.free(self.allocator);
        const cache_fields = self.resolveThumbnailCacheFields(strings.character_name, strings.system_name);

        var thumbnail = ThumbnailWindow{
            .hwnd = hwnd,
            .text_hwnd = text_hwnd,
            .thumbnail_id = thumbnail_id,
            .source_hwnd = eve_window.hwnd,
            .title = strings.title,
            .character_name = strings.character_name,
            .system_name = strings.system_name,
            .cached_system_color = cache_fields.system_color,
            .cached_character_color = cache_fields.character_color,
            .cached_display_name = cache_fields.display_name,
            .cached_active_border_override = cache_fields.active_border_override,
            .cached_quick_group_label = strings.quick_group_label,
            .inactive_since = std.time.milliTimestamp(),
            .visibility_state = initial_visibility,
            .is_excluded_from_cycle = is_excluded,
        };
        try self.renderThumbnail(&thumbnail);

        // Store source window handle for click-to-focus
        _ = win32.SetPropA(hwnd, "SOURCE_HWND", eve_window.hwnd);
        _ = win32.SetPropA(text_hwnd, "SOURCE_HWND", eve_window.hwnd);

        _ = win32.SetWindowLongPtrA(hwnd, win32.GWLP_USERDATA, win32.hwndToUserData(text_hwnd));

        // For reverse lookup during drag.
        _ = win32.SetWindowLongPtrA(text_hwnd, win32.GWLP_USERDATA, win32.hwndToUserData(hwnd));

        _ = win32.SetWindowPos(text_hwnd, win32.HWND_TOPMOST, pos.x, pos.y, thumb_size.width, thumb_size.height, win32.SWP_NOACTIVATE);
        _ = win32.ShowWindow(text_hwnd, win32.SW_SHOW);
        _ = win32.UpdateWindow(text_hwnd);

        try self.thumbnails.append(self.allocator, thumbnail);
        // Add to HWND indices for O(1) lookups by all window handles
        const new_index = self.thumbnails.items.len - 1;
        try self.hwnd_to_thumbnail_index.put(eve_window.hwnd, new_index);
        try self.thumbnail_hwnd_to_index.put(hwnd, new_index);
        try self.text_hwnd_to_index.put(text_hwnd, new_index);

        // This window may already be the real foreground window; reconcile now instead of waiting for the next tick.
        const foreground_hwnd = win32.GetForegroundWindow();
        self.reconcileThumbnailStates(foreground_hwnd);
        if (foreground_hwnd == eve_window.hwnd) {
            if (g_hotkey_manager_ptr) |manager| {
                manager.updateFocusedCharacter(eve_window.character_name);
            }
        }

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

    /// Saved positions for every other character in the profile, grouped by exact rect match (identical x/y/w/h counts as "stacked"). Caller owns the returned slice and each group's `names`.
    pub fn collectGhostGroups(self: *Painter, allocator: std.mem.Allocator, exclude_character: []const u8) ![]GhostGroup {
        const RawEntry = struct { name: []const u8, rect: win32.RECT };

        var raw = std.ArrayList(RawEntry).empty;
        defer raw.deinit(allocator);

        for (self.config.characters.items) |char_config| {
            if (std.mem.eql(u8, char_config.name, exclude_character)) continue;
            const pos = char_config.position orelse continue;
            const size = self.getThumbnailSize(char_config.name);
            try raw.append(allocator, .{
                .name = char_config.name,
                .rect = .{ .left = pos.x, .top = pos.y, .right = pos.x + size.width, .bottom = pos.y + size.height },
            });
        }

        var groups = std.ArrayList(GhostGroup).empty;
        errdefer {
            for (groups.items) |g| allocator.free(g.names);
            groups.deinit(allocator);
        }

        const used = try allocator.alloc(bool, raw.items.len);
        defer allocator.free(used);
        @memset(used, false);

        for (raw.items, 0..) |entry, i| {
            if (used[i]) continue;
            used[i] = true;

            var names = std.ArrayList(u8).empty;
            defer names.deinit(allocator);
            try names.appendSlice(allocator, entry.name);

            for (raw.items[i + 1 ..], i + 1..) |other, j| {
                if (used[j] or !ghostRectsEqual(entry.rect, other.rect)) continue;
                used[j] = true;
                try names.appendSlice(allocator, ", ");
                try names.appendSlice(allocator, other.name);
            }

            try groups.append(allocator, .{ .rect = entry.rect, .names = try names.toOwnedSlice(allocator) });
        }

        return groups.toOwnedSlice(allocator);
    }

    /// Shows (creating on first use) a topmost, click-through overlay outlining every other saved position in the profile; called once when a drag starts. Ghosts are static for the duration of the drag.
    pub fn showGhostOverlay(self: *Painter, exclude_character: []const u8) void {
        const groups = self.collectGhostGroups(self.allocator, exclude_character) catch |err| {
            slog.err("Failed to collect ghost positions: {}", .{err});
            return;
        };
        defer {
            for (groups) |g| self.allocator.free(g.names);
            self.allocator.free(groups);
        }

        if (groups.len == 0) {
            self.hideGhostOverlay();
            return;
        }

        var bounds = groups[0].rect;
        for (groups[1..]) |g| {
            bounds.left = @min(bounds.left, g.rect.left);
            bounds.top = @min(bounds.top, g.rect.top);
            bounds.right = @max(bounds.right, g.rect.right);
            bounds.bottom = @max(bounds.bottom, g.rect.bottom);
        }

        const width = bounds.right - bounds.left;
        const height = bounds.bottom - bounds.top;
        if (width <= 0 or height <= 0) {
            self.hideGhostOverlay();
            return;
        }

        if (self.ghost_overlay_hwnd) |hwnd| {
            _ = win32.SetWindowPos(hwnd, win32.HWND_TOPMOST, bounds.left, bounds.top, width, height, win32.SWP_NOACTIVATE);
        } else {
            self.ghost_overlay_hwnd = win32.CreateWindowExA(
                win32.WS_EX_LAYERED | win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW | win32.WS_EX_NOACTIVATE | win32.WS_EX_TRANSPARENT,
                GHOST_WINDOW_CLASS_NAME,
                "",
                win32.WS_POPUP,
                bounds.left,
                bounds.top,
                width,
                height,
                null,
                null,
                self.instance,
                null,
            ) orelse {
                slog.err("Failed to create ghost overlay window", .{});
                return;
            };
        }

        const hwnd = self.ghost_overlay_hwnd.?;

        const needs_new_bitmap = if (self.ghost_overlay_bitmap) |b|
            b.width != @as(usize, @intCast(width)) or b.height != @as(usize, @intCast(height))
        else
            true;

        if (needs_new_bitmap) {
            if (self.ghost_overlay_bitmap) |b| b.destroy();
            self.ghost_overlay_bitmap = null;
            const init_dc = win32.GetDC(null) orelse return;
            defer _ = win32.ReleaseDC(null, init_dc);
            self.ghost_overlay_bitmap = gdi_overlay.OverlayBitmap.create(init_dc, width, height) catch |err| {
                slog.err("Failed to allocate ghost overlay bitmap: {}", .{err});
                return;
            };
        }

        const overlay = &self.ghost_overlay_bitmap.?;
        clearPixels(overlay.pixels, overlay.width * overlay.height);

        const ghost_dpi = getWindowDpi(hwnd);
        const ghost_scale = dpiToScale(ghost_dpi);
        const font = self.getCachedFont(.main, ghost_dpi, self.config.thumbnail.characterNameFontName, scalePixels(self.config.thumbnail.characterNameFontSize, ghost_scale), self.config.thumbnail.characterNameFontWeight) catch |err| {
            slog.err("Failed to get font for ghost overlay: {}", .{err});
            return;
        };
        const old_font = win32.SelectObject(overlay.mem_dc, font);
        defer {
            if (old_font) |of| _ = win32.SelectObject(overlay.mem_dc, of);
        }

        // Same hue as the focused/active thumbnail border, at reduced alpha so it still reads as a ghost rather than a real thumbnail.
        const outline_color: u32 = color_mod.withAlpha(self.config.thumbnail.borderColor, 0xB0);
        const text_color: u32 = 0xE0FFFFFF;

        for (groups) |group| {
            const local_x = group.rect.left - bounds.left;
            const local_y = group.rect.top - bounds.top;
            const rect_w: usize = @intCast(group.rect.right - group.rect.left);
            const rect_h: usize = @intCast(group.rect.bottom - group.rect.top);

            drawRectOutline(overlay.pixels, overlay.width, overlay.height, local_x, local_y, rect_w, rect_h, 2, outline_color);

            const dims = measureText(overlay.mem_dc, group.names);
            renderText(overlay.mem_dc, group.names, local_x, local_y, text_color);
            gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, local_x, local_y, dims.width, dims.height);
        }

        const screen_dc = win32.GetDC(null) orelse return;
        defer _ = win32.ReleaseDC(null, screen_dc);
        const window_size = win32.SIZE{ .cx = @intCast(overlay.width), .cy = @intCast(overlay.height) };
        const source_pos = win32.POINT{ .x = 0, .y = 0 };
        var blend = win32.BLENDFUNCTION{
            .BlendOp = win32.AC_SRC_OVER,
            .BlendFlags = 0,
            .SourceConstantAlpha = 255,
            .AlphaFormat = win32.AC_SRC_ALPHA,
        };

        _ = win32.UpdateLayeredWindow(
            hwnd,
            screen_dc,
            null,
            @constCast(&window_size),
            overlay.mem_dc,
            @constCast(&source_pos),
            0,
            &blend,
            win32.ULW_ALPHA,
        );

        _ = win32.ShowWindow(hwnd, win32.SW_SHOWNOACTIVATE);
    }

    pub fn hideGhostOverlay(self: *Painter) void {
        if (self.ghost_overlay_hwnd) |hwnd| {
            _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
        }
    }
};

/// Scales a logical (96-DPI) pixel value to the given monitor scale factor, rounding to nearest.
fn scalePixels(value: i32, scale: f32) i32 {
    if (scale == 1.0) return value;
    return @intFromFloat(@round(@as(f32, @floatFromInt(value)) * scale));
}

/// Clears all pixels to transparent via @memset on the typed slice.
fn clearPixels(pixels: [*]u32, count: usize) void {
    @memset(pixels[0..count], 0);
}

const HorizontalAlign = enum { left, center, right };

fn horizontalAlignOf(position: TextPosition) HorizontalAlign {
    return switch (position) {
        .TopLeft, .LeftCenter, .BottomLeft => .left,
        .TopCenter, .Center, .BottomCenter => .center,
        .TopRight, .RightCenter, .BottomRight => .right,
    };
}

/// x for a line of `line_width` so it sits flush against whichever edge `alignment` anchors to, within a block of `block_width` starting at `block_x`.
fn alignedLineX(block_x: i32, block_width: usize, line_width: usize, alignment: HorizontalAlign) i32 {
    return switch (alignment) {
        .left => block_x,
        .center => block_x + @as(i32, @intCast((block_width -| line_width) / 2)),
        .right => block_x + @as(i32, @intCast(block_width -| line_width)),
    };
}

const VerticalAlign = enum { top, middle, bottom };

fn verticalAlignOf(position: TextPosition) VerticalAlign {
    return switch (position) {
        .TopLeft, .TopCenter, .TopRight => .top,
        .LeftCenter, .Center, .RightCenter => .middle,
        .BottomLeft, .BottomCenter, .BottomRight => .bottom,
    };
}

/// y for a line of `line_height` so it sits flush against whichever edge `alignment` anchors to, within a block of `block_height` starting at `block_y`; same shape as alignedLineX for the vertical axis.
fn alignedLineY(block_y: i32, block_height: usize, line_height: usize, alignment: VerticalAlign) i32 {
    return switch (alignment) {
        .top => block_y,
        .middle => block_y + @as(i32, @intCast((block_height -| line_height) / 2)),
        .bottom => block_y + @as(i32, @intCast(block_height -| line_height)),
    };
}

fn calculateTextPosition(
    position: TextPosition,
    text_width: usize,
    text_height: usize,
    overlay_width: usize,
    overlay_height: usize,
    offset_x: i32,
    offset_y: i32,
) TextPos {
    var x = alignedLineX(0, overlay_width, text_width, horizontalAlignOf(position));
    var y = alignedLineY(0, overlay_height, text_height, verticalAlignOf(position));

    x += offset_x;
    y += offset_y;

    x = @max(0, @min(x, @as(i32, @intCast(overlay_width)) - @as(i32, @intCast(text_width))));
    y = @max(0, @min(y, @as(i32, @intCast(overlay_height)) - @as(i32, @intCast(text_height))));

    return .{ .x = x, .y = y };
}

/// Fills a rectangular region of pixels with a single colour via @memset on each row slice.
fn fillTextBackground(pixels: [*]u32, width: usize, height: usize, x: i32, y: i32, text_width: usize, bar_height: usize, color: u32) void {
    const start_x: usize = @intCast(@max(0, x));
    const start_y: usize = @intCast(@max(0, y));
    const end_y = @min(start_y + bar_height, height);
    const end_x = @min(start_x + text_width, width);
    if (end_x <= start_x or end_y <= start_y) return;
    const span = end_x - start_x;
    // Must be premultiplied, or fixTextAlphaRect's "alpha==0 but rgb!=0" heuristic mistakes a
    // transparent non-black background for unfixed GDI text and forces it fully opaque.
    const blended = premultiplyAlpha(color);
    for (start_y..end_y) |py| {
        @memset(pixels[py * width + start_x .. py * width + start_x + span], blended);
    }
}

/// Pre-multiplies color by alpha, valid only when blending onto an already-transparent buffer.
fn premultiplyAlpha(color: u32) u32 {
    const fg_alpha = (color >> 24) & 0xFF;
    if (fg_alpha == 255) return color;
    const r = ((color >> 16) & 0xFF) * fg_alpha / 255;
    const g = ((color >> 8) & 0xFF) * fg_alpha / 255;
    const b = (color & 0xFF) * fg_alpha / 255;
    return (fg_alpha << 24) | (r << 16) | (g << 8) | b;
}

/// Draws one diagonal band; is_diag2 selects top-right→bottom-left over top-left→bottom-right. Shared by X (both bands) and DiagonalSlash (diag2 only).
fn drawDiagonalBand(pixels: [*]u32, width: usize, height: usize, color: u32, is_diag2: bool) void {
    const iw: i32 = @intCast(width);
    const ih: i32 = @intCast(height);
    // Line half-width in pixels, scaled proportionally with the aspect ratio.
    const half: i32 = @max(1, @divTrunc(5 * iw, ih));
    for (0..height) |y| {
        const iy: i32 = @intCast(y);
        const row = pixels[y * width .. y * width + width];
        const cx = if (is_diag2) @divTrunc((ih - iy) * iw, ih) else @divTrunc(iy * iw, ih);
        const lo: usize = @intCast(@max(0, cx - half));
        const hi: usize = @intCast(@max(0, @min(iw, cx + half + 1)));
        if (lo < hi) @memset(row[lo..hi], color);
    }
}

/// Draws the exclusion overlay onto an already-cleared buffer.
fn drawExclusionOverlay(pixels: [*]u32, width: usize, height: usize, color: u32, style: types.ExclusionOverlayStyle) void {
    const fg_alpha = (color >> 24) & 0xFF;
    if (fg_alpha == 0) return;
    const blended = premultiplyAlpha(color);

    switch (style) {
        .None => {},
        .SolidTint => @memset(pixels[0 .. width * height], blended),
        .CircleSlash => {
            const cx: f32 = @as(f32, @floatFromInt(width)) / 2;
            const cy: f32 = @as(f32, @floatFromInt(height)) / 2;
            const radius = @min(cx, cy) * 0.7;
            const thickness = @max(2.0, radius * 0.18);
            // Slash extends a bit past the ring, matching the standard "no entry" glyph.
            const slash_reach = radius * 1.15;
            const sqrt2 = @sqrt(@as(f32, 2.0));
            for (0..height) |y| {
                const row_start = y * width;
                const fy: f32 = @floatFromInt(y);
                for (0..width) |x| {
                    const fx: f32 = @floatFromInt(x);
                    const dx = fx - cx;
                    const dy = fy - cy;
                    const dist = @sqrt(dx * dx + dy * dy);
                    const on_ring = @abs(dist - radius) <= thickness / 2;
                    // Slash direction runs lower-left to upper-right (dx + dy = 0 through centre).
                    const on_slash = @abs(dx + dy) / sqrt2 <= thickness / 2 and dist <= slash_reach;
                    if (on_ring or on_slash) pixels[row_start + x] = blended;
                }
            }
        },
        .DiagonalHatch => {
            // Same ratio as BorderStyle.DiagonalHatch, but filling the whole area.
            const pattern_length = 6;
            const mark_length = 3;
            for (0..height) |y| {
                const row_start = y * width;
                for (0..width) |x| {
                    if (((x + y) % pattern_length) < mark_length) {
                        pixels[row_start + x] = blended;
                    }
                }
            }
        },
        .Checkerboard => {
            const square_size = 8;
            for (0..height) |y| {
                const row_start = y * width;
                for (0..width) |x| {
                    if (((x / square_size) + (y / square_size)) % 2 == 0) {
                        pixels[row_start + x] = blended;
                    }
                }
            }
        },
        .X => {
            drawDiagonalBand(pixels, width, height, blended, false);
            drawDiagonalBand(pixels, width, height, blended, true);
        },
        .DiagonalSlash => drawDiagonalBand(pixels, width, height, blended, true),
    }
}

const BorderRegion = struct {
    x_start: usize,
    y_start: usize,
    x_end: usize,
    y_end: usize,
};

/// The four border bands (top/bottom/left/right), each `border_width` thick and running the full length of its edge. Shared by every style that walks the border pixel-by-pixel instead of memset-ing solid runs.
fn borderRegions(width: usize, height: usize, border_width: usize) [4]BorderRegion {
    return .{
        .{ .x_start = 0, .y_start = 0, .x_end = width, .y_end = border_width },
        .{ .x_start = 0, .y_start = height - border_width, .x_end = width, .y_end = height },
        .{ .x_start = 0, .y_start = 0, .x_end = border_width, .y_end = height },
        .{ .x_start = width - border_width, .y_start = 0, .x_end = width, .y_end = height },
    };
}

/// Marks pixels along the border's length using a repeating mark/gap pattern, where `pos` runs along the edge; shared by Dashed and Dotted, which differ only in the mark/gap lengths.
fn drawLengthwisePattern(pixels: [*]u32, width: usize, height: usize, border_width: usize, color: u32, mark_length: usize, gap_length: usize) void {
    const pattern_length = mark_length + gap_length;

    for (borderRegions(width, height, border_width)) |region| {
        const is_horizontal = (region.x_end - region.x_start) == width;

        for (region.y_start..region.y_end) |y| {
            const row_start = y * width;
            for (region.x_start..region.x_end) |x| {
                const pos = if (is_horizontal) x else y;

                if ((pos % pattern_length) < mark_length) {
                    pixels[row_start + x] = color;
                }
            }
        }
    }
}

fn drawBorder(pixels: [*]u32, width: usize, height: usize, border_width: usize, color: u32, style: BorderStyle) void {
    switch (style) {
        .Solid => {
            // Top and bottom bands — each is a contiguous run of (border_width * width) pixels.
            @memset(pixels[0 .. border_width * width], color);
            @memset(pixels[(height - border_width) * width .. height * width], color);

            // Left and right strips for the middle rows (corners already covered above).
            for (border_width..(height - border_width)) |y| {
                const row = y * width;
                @memset(pixels[row .. row + border_width], color);
                @memset(pixels[row + width - border_width .. row + width], color);
            }
        },
        .Dashed => drawLengthwisePattern(pixels, width, height, border_width, color, 8, 4),
        .Dotted => {
            // Square-ish dots roughly one border-width wide, spaced two border-widths apart, distinct from Dashed's fixed 8px marks.
            const dot_length = if (border_width == 0) 0 else @max(1, border_width);
            drawLengthwisePattern(pixels, width, height, border_width, color, dot_length, dot_length * 2);
        },
        .Double => {
            // Mirrors the CSS "double" border look; at very thin widths the lines abut with no visible gap and just render as solid.
            const line_width = if (border_width == 0) 0 else @max(1, border_width / 3);
            const inner_start = border_width - line_width;

            // Top band: outer line at the edge, inner line just before the band ends.
            @memset(pixels[0 .. line_width * width], color);
            @memset(pixels[inner_start * width .. border_width * width], color);

            // Bottom band: mirrored from the far edge.
            @memset(pixels[(height - line_width) * width .. height * width], color);
            @memset(pixels[(height - border_width) * width .. (height - border_width + line_width) * width], color);

            // Left/right double lines for the middle rows (corners already covered above).
            for (border_width..(height - border_width)) |y| {
                const row = y * width;
                @memset(pixels[row .. row + line_width], color);
                @memset(pixels[row + inner_start .. row + border_width], color);
                @memset(pixels[row + width - border_width .. row + width - border_width + line_width], color);
                @memset(pixels[row + width - line_width .. row + width], color);
            }
        },
        .DiagonalHatch => {
            // Fixed mark/gap ratio regardless of border_width so the 45-degree hatch angle stays consistent.
            const pattern_length = 6;
            const mark_length = 3;

            for (borderRegions(width, height, border_width)) |region| {
                for (region.y_start..region.y_end) |y| {
                    const row_start = y * width;
                    for (region.x_start..region.x_end) |x| {
                        if (((x + y) % pattern_length) < mark_length) {
                            pixels[row_start + x] = color;
                        }
                    }
                }
            }
        },
        .DashDot => {
            // Dash, gap, dot, gap: a four-phase pattern, so it needs its own test rather than drawLengthwisePattern's single mark/gap pair.
            const dash_length: usize = 8;
            const gap_length: usize = 4;
            const dot_length: usize = if (border_width == 0) 0 else @max(1, border_width);
            const pattern_length = dash_length + gap_length + dot_length + gap_length;
            const dot_start = dash_length + gap_length;

            for (borderRegions(width, height, border_width)) |region| {
                const is_horizontal = (region.x_end - region.x_start) == width;

                for (region.y_start..region.y_end) |y| {
                    const row_start = y * width;
                    for (region.x_start..region.x_end) |x| {
                        const pos = if (is_horizontal) x else y;
                        const phase = pos % pattern_length;
                        const in_dash = phase < dash_length;
                        const in_dot = phase >= dot_start and phase < dot_start + dot_length;

                        if (in_dash or in_dot) {
                            pixels[row_start + x] = color;
                        }
                    }
                }
            }
        },
        .CornerBrackets => {
            // Arm length scales with border_width but is capped at a third of the shorter dimension so brackets from adjacent corners never meet.
            const arm_length = @min(border_width * 4, @min(width, height) / 3);

            // Top-left
            fillRect(pixels, width, 0, 0, arm_length, border_width, color);
            fillRect(pixels, width, 0, 0, border_width, arm_length, color);
            // Top-right
            fillRect(pixels, width, width - arm_length, 0, arm_length, border_width, color);
            fillRect(pixels, width, width - border_width, 0, border_width, arm_length, color);
            // Bottom-left
            fillRect(pixels, width, 0, height - border_width, arm_length, border_width, color);
            fillRect(pixels, width, 0, height - arm_length, border_width, arm_length, color);
            // Bottom-right
            fillRect(pixels, width, width - arm_length, height - border_width, arm_length, border_width, color);
            fillRect(pixels, width, width - border_width, height - arm_length, border_width, arm_length, color);
        },
    }
}

/// Fills an axis-aligned `w`x`h` rectangle at (`x`, `y`) with `color`; shared by CornerBrackets, which draws eight of these (two arms per corner).
fn fillRect(pixels: [*]u32, width: usize, x: usize, y: usize, w: usize, h: usize, color: u32) void {
    for (y..y + h) |row_y| {
        const row = row_y * width;
        @memset(pixels[row + x .. row + x + w], color);
    }
}

/// Draws a `thickness`-px outline of an arbitrary sub-rect within a `buf_width`x`buf_height` pixel buffer; unlike drawBorder (which frames the whole buffer), this frames a rect placed anywhere inside it. Clamped to the buffer bounds.
fn drawRectOutline(pixels: [*]u32, buf_width: usize, buf_height: usize, x: i32, y: i32, w: usize, h: usize, thickness: usize, color: u32) void {
    const left: usize = @intCast(std.math.clamp(x, 0, @as(i32, @intCast(buf_width))));
    const top: usize = @intCast(std.math.clamp(y, 0, @as(i32, @intCast(buf_height))));
    const right = @min(buf_width, left + w);
    const bottom = @min(buf_height, top + h);
    if (right <= left or bottom <= top) return;

    const t = @min(thickness, @min(right - left, bottom - top));
    fillRect(pixels, buf_width, left, top, right - left, t, color);
    fillRect(pixels, buf_width, left, bottom - t, right - left, t, color);
    fillRect(pixels, buf_width, left, top, t, bottom - top, color);
    fillRect(pixels, buf_width, right - t, top, t, bottom - top, color);
}

/// Inserts comma thousands-separators into the leading run of ASCII digits in `text` (e.g. "12405.3 m3/min" -> "12,405.3 m3/min").
fn insertThousandsSeparators(buf: []u8, text: []const u8) []const u8 {
    var digit_end: usize = 0;
    while (digit_end < text.len and text[digit_end] >= '0' and text[digit_end] <= '9') : (digit_end += 1) {}
    if (digit_end <= 3) return text;

    var out: usize = 0;
    const first_group = if (digit_end % 3 == 0) 3 else digit_end % 3;
    if (first_group > buf.len) return text;
    @memcpy(buf[0..first_group], text[0..first_group]);
    out = first_group;

    var i = first_group;
    while (i < digit_end) : (i += 3) {
        if (out + 4 > buf.len) return text;
        buf[out] = ',';
        @memcpy(buf[out + 1 ..][0..3], text[i..][0..3]);
        out += 4;
    }

    const rest = text[digit_end..];
    if (out + rest.len > buf.len) return text;
    @memcpy(buf[out..][0..rest.len], rest);
    return buf[0 .. out + rest.len];
}

/// Abbreviates an ISK value with k/m suffixes (e.g. 2_450_000.0 -> "2.5m", 200_000.0 -> "200k", 850.0 -> "850").
fn formatIskAbbrev(buf: []u8, value: f32) []const u8 {
    const abs_value = @abs(value);
    if (abs_value >= 1_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.1}m", .{value / 1_000_000.0}) catch "?";
    } else if (abs_value >= 1_000.0) {
        return std.fmt.bufPrint(buf, "{d:.0}k", .{value / 1_000.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.0}", .{value}) catch "?";
    }
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

pub const TextDimensions = struct {
    width: usize,
    height: usize,
};

const TextPos = struct {
    x: i32,
    y: i32,
};

/// Pointer+len fast path before falling back to a byte compare; config/notif-owned slices are pointer+len identical every tick when unchanged.
fn stringsEqualFast(a: []const u8, b: []const u8) bool {
    return (a.ptr == b.ptr and a.len == b.len) or std.mem.eql(u8, a, b);
}

/// Whether a cached font's name/size/weight differ from the settings that would be used to render now.
fn fontSettingsChanged(cached_name: []const u8, cached_size: i32, cached_weight: types.FontWeight, new_name: []const u8, new_size: i32, new_weight: types.FontWeight) bool {
    return !stringsEqualFast(cached_name, new_name) or cached_size != new_size or cached_weight != new_weight;
}

fn toBufZ(text: []const u8) [TEXT_BUFFER_SIZE:0]u8 {
    var buf: [TEXT_BUFFER_SIZE:0]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return buf;
}

/// Measures text dimensions without rendering; the correct font must already be selected into `dc` by the caller.
fn measureText(dc: win32.HDC, text: []const u8) TextDimensions {
    const text_buffer = toBufZ(text);
    const text_len = @min(text.len, text_buffer.len - 1);

    var text_size: win32.SIZE = undefined;
    _ = win32.GetTextExtentPoint32A(dc, &text_buffer, @intCast(text_len), &text_size);

    return .{
        .width = @intCast(text_size.cx + (TEXT_PADDING_X * 2)),
        .height = @intCast(text_size.cy + (TEXT_PADDING_Y * 2)),
    };
}

/// Renders text onto the device context at the specified position; the correct font must already be selected into `dc` by the caller.
fn renderText(dc: win32.HDC, text: []const u8, x: i32, y: i32, color: u32) void {
    _ = win32.SetBkMode(dc, win32.TRANSPARENT);
    _ = win32.SetTextColor(dc, gdi_overlay.toColorRef(color));

    const text_buffer = toBufZ(text);
    const text_len = @min(text.len, text_buffer.len - 1);

    _ = win32.TextOutA(dc, x + TEXT_PADDING_X, y + TEXT_PADDING_Y, &text_buffer, @intCast(text_len));
}

fn renderThumbnailOverlay(thumbnail: *ThumbnailWindow, settings: RenderSettings, config: *const config_mod.Config) !void {
    const hwnd = thumbnail.text_hwnd;
    const character_name = thumbnail.character_name;
    const system_name = thumbnail.system_name;

    const width = settings.overlay_width;
    const height = settings.overlay_height;

    // Reuse the cached overlay bitmap unless dimensions changed (first render or resize).
    const needs_new_bitmap = if (thumbnail.cached_overlay) |o|
        o.width != @as(usize, @intCast(width)) or o.height != @as(usize, @intCast(height))
    else
        true;

    if (needs_new_bitmap) {
        if (thumbnail.cached_overlay) |o| o.destroy();
        const init_dc = win32.GetDC(null) orelse return error.GetDCFailed;
        defer _ = win32.ReleaseDC(null, init_dc);
        thumbnail.cached_overlay = try gdi_overlay.OverlayBitmap.create(init_dc, width, height);
        slog.debug("Allocated overlay bitmap {}x{} for {s}", .{ width, height, thumbnail.character_name });
    }

    const overlay = &thumbnail.cached_overlay.?;

    const pixel_count = overlay.width * overlay.height;
    clearPixels(overlay.pixels, pixel_count);

    if (settings.show_exclusion_overlay) {
        drawExclusionOverlay(overlay.pixels, overlay.width, overlay.height, settings.exclusion_overlay_color, settings.exclusion_overlay_style);
    }

    const painter = g_painter_ptr orelse return error.NoPainter;
    const dpi = Painter.getWindowDpi(thumbnail.hwnd);
    // Combat/mining/bounty font sizes bypass RenderSettings (see createRenderSettings), so they're scaled here instead.
    const dpi_scale = Painter.dpiToScale(dpi);
    const font = try painter.getCachedFont(
        .main,
        dpi,
        settings.character_name_font_name,
        settings.character_name_font_size,
        settings.character_name_font_weight,
    );

    // Select the main font once for all char/system/notification measure+render calls; restore the original object on function exit.
    const old_main_font = win32.SelectObject(overlay.mem_dc, font);
    defer {
        if (old_main_font) |of| _ = win32.SelectObject(overlay.mem_dc, of);
    }

    const display_name = config.getDisplayName(character_name);

    const font_changed = fontSettingsChanged(
        thumbnail.cached_font_name,
        thumbnail.cached_font_size,
        thumbnail.cached_font_weight,
        settings.character_name_font_name,
        settings.character_name_font_size,
        settings.character_name_font_weight,
    );

    var char_text_dims: TextDimensions = .{ .width = 0, .height = 0 };
    if (settings.show_character_name) {
        if (thumbnail.cached_char_dims != null and !font_changed) {
            char_text_dims = thumbnail.cached_char_dims.?;
        } else {
            char_text_dims = measureText(overlay.mem_dc, display_name);
            thumbnail.cached_char_dims = char_text_dims;
            thumbnail.cached_font_name = settings.character_name_font_name;
            thumbnail.cached_font_size = settings.character_name_font_size;
            thumbnail.cached_font_weight = settings.character_name_font_weight;
        }
    }

    // Resolved once here and reused at the render phase below, same pattern as dps_in_font/mining_font/bounty_font.
    var system_text_dims: TextDimensions = .{ .width = 0, .height = 0 };
    var sys_font: ?win32.HFONT = null;
    if (settings.show_system_name) {
        const sf = try painter.getCachedFont(.system_name, dpi, settings.system_name_font_name, settings.system_name_font_size, settings.system_name_font_weight);
        sys_font = sf;
        const sys_font_changed = fontSettingsChanged(
            thumbnail.cached_sys_font_name,
            thumbnail.cached_sys_font_size,
            thumbnail.cached_sys_font_weight,
            settings.system_name_font_name,
            settings.system_name_font_size,
            settings.system_name_font_weight,
        );
        if (thumbnail.cached_sys_dims != null and !sys_font_changed) {
            system_text_dims = thumbnail.cached_sys_dims.?;
        } else {
            _ = win32.SelectObject(overlay.mem_dc, sf);
            system_text_dims = measureText(overlay.mem_dc, system_name);
            _ = win32.SelectObject(overlay.mem_dc, font);
            thumbnail.cached_sys_dims = system_text_dims;
            thumbnail.cached_sys_font_name = settings.system_name_font_name;
            thumbnail.cached_sys_font_size = settings.system_name_font_size;
            thumbnail.cached_sys_font_weight = settings.system_name_font_weight;
        }
    }

    // Stacked notification lines aren't dims-cached (unlike char/system name above): the stack's contents change
    // far more often than those, so a cache would invalidate almost every render anyway.
    var notif_line_dims: [MAX_STACKED_NOTIFICATIONS]TextDimensions = undefined;
    var notifications_text_dims: TextDimensions = .{ .width = 0, .height = 0 };
    const has_notification_text = settings.notification_line_count > 0;
    var notif_font: ?win32.HFONT = null;
    if (settings.show_notifications and has_notification_text) {
        const nf = try painter.getCachedFont(.notification, dpi, settings.notifications_font_name, settings.notifications_font_size, settings.notifications_font_weight);
        notif_font = nf;
        _ = win32.SelectObject(overlay.mem_dc, nf);
        var idx: usize = 0;
        while (idx < settings.notification_line_count) : (idx += 1) {
            notif_line_dims[idx] = measureText(overlay.mem_dc, settings.notification_lines[idx].text);
            notifications_text_dims.width = @max(notifications_text_dims.width, notif_line_dims[idx].width);
            notifications_text_dims.height += notif_line_dims[idx].height;
        }
        _ = win32.SelectObject(overlay.mem_dc, font);
    }

    var qg_badge_dims: TextDimensions = .{ .width = 0, .height = 0 };
    var qg_font: ?win32.HFONT = null;
    if (settings.show_quick_group_badge) {
        const qf = try painter.getCachedFont(.quick_group_badge, dpi, settings.quick_group_badge_font_name, settings.quick_group_badge_font_size, settings.quick_group_badge_font_weight);
        qg_font = qf;
        const qg_font_changed = fontSettingsChanged(
            thumbnail.cached_qg_font_name,
            thumbnail.cached_qg_font_size,
            thumbnail.cached_qg_font_weight,
            settings.quick_group_badge_font_name,
            settings.quick_group_badge_font_size,
            settings.quick_group_badge_font_weight,
        );
        if (thumbnail.cached_qg_dims != null and !qg_font_changed) {
            qg_badge_dims = thumbnail.cached_qg_dims.?;
        } else {
            _ = win32.SelectObject(overlay.mem_dc, qf);
            qg_badge_dims = measureText(overlay.mem_dc, settings.quick_group_badge_text);
            _ = win32.SelectObject(overlay.mem_dc, font);
            thumbnail.cached_qg_dims = qg_badge_dims;
            thumbnail.cached_qg_font_name = settings.quick_group_badge_font_name;
            thumbnail.cached_qg_font_size = settings.quick_group_badge_font_size;
            thumbnail.cached_qg_font_weight = settings.quick_group_badge_font_weight;
        }
    }

    const char_text_pos: TextPos = if (settings.show_character_name)
        calculateTextPosition(
            settings.character_name_position,
            char_text_dims.width,
            char_text_dims.height,
            overlay.width,
            overlay.height,
            settings.character_name_offset_x,
            settings.character_name_offset_y,
        )
    else
        TextPos{ .x = 0, .y = 0 };

    const system_text_pos: TextPos = if (settings.show_system_name)
        calculateTextPosition(
            settings.system_name_position,
            system_text_dims.width,
            system_text_dims.height,
            overlay.width,
            overlay.height,
            settings.system_name_offset_x,
            settings.system_name_offset_y,
        )
    else
        TextPos{ .x = 0, .y = 0 };

    const notifications_text_pos: TextPos = if (settings.show_notifications and has_notification_text)
        calculateTextPosition(
            settings.notifications_position,
            notifications_text_dims.width,
            notifications_text_dims.height,
            overlay.width,
            overlay.height,
            settings.notifications_offset_x,
            settings.notifications_offset_y,
        )
    else
        TextPos{ .x = 0, .y = 0 };

    const qg_badge_pos: TextPos = if (settings.show_quick_group_badge)
        calculateTextPosition(
            settings.quick_group_badge_position,
            qg_badge_dims.width,
            qg_badge_dims.height,
            overlay.width,
            overlay.height,
            settings.quick_group_badge_offset_x,
            settings.quick_group_badge_offset_y,
        )
    else
        TextPos{ .x = 0, .y = 0 };

    if (settings.show_character_name) {
        fillTextBackground(
            overlay.pixels,
            overlay.width,
            overlay.height,
            char_text_pos.x,
            char_text_pos.y,
            char_text_dims.width,
            char_text_dims.height,
            settings.character_name_bg_color,
        );
    }

    if (settings.show_system_name) {
        fillTextBackground(
            overlay.pixels,
            overlay.width,
            overlay.height,
            system_text_pos.x,
            system_text_pos.y,
            system_text_dims.width,
            system_text_dims.height,
            settings.system_name_bg_color,
        );
    }

    if (settings.show_notifications and has_notification_text) {
        fillTextBackground(
            overlay.pixels,
            overlay.width,
            overlay.height,
            notifications_text_pos.x,
            notifications_text_pos.y,
            notifications_text_dims.width,
            notifications_text_dims.height,
            settings.notifications_bg_color,
        );
    }

    if (settings.show_quick_group_badge) {
        fillTextBackground(
            overlay.pixels,
            overlay.width,
            overlay.height,
            qg_badge_pos.x,
            qg_badge_pos.y,
            qg_badge_dims.width,
            qg_badge_dims.height,
            settings.quick_group_badge_bg_color,
        );
    }

    // Fill DPS text backgrounds before the border, matching char/system name draw order.
    var dps_in_buf: [32]u8 = undefined;
    var dps_out_buf: [32]u8 = undefined;
    var dps_in_text: []const u8 = "";
    var dps_out_text: []const u8 = "";
    var dps_in_pos: TextPos = .{ .x = 0, .y = 0 };
    var dps_out_pos: TextPos = .{ .x = 0, .y = 0 };
    var dps_in_dims: TextDimensions = .{ .width = 0, .height = 0 };
    var dps_out_dims: TextDimensions = .{ .width = 0, .height = 0 };
    var dps_in_font: ?win32.HFONT = null;
    var dps_out_font: ?win32.HFONT = null;
    if (config.combat.enabled and config.thumbnail.showText) {
        const combat_cfg = &config.combat;
        if (combat_cfg.show_incoming and thumbnail.has_dps_data and (thumbnail.last_incoming_dps == null or thumbnail.last_incoming_dps.? > 0)) {
            const f = try painter.getCachedFont(.combat, dpi, combat_cfg.incoming_font_name, scalePixels(combat_cfg.incoming_font_size, dpi_scale), combat_cfg.incoming_font_weight);
            dps_in_font = f;
            _ = win32.SelectObject(overlay.mem_dc, f);
            dps_in_text = if (thumbnail.last_incoming_dps) |dps|
                std.fmt.bufPrint(&dps_in_buf, "IN: {d:.0}", .{dps}) catch "IN: ---"
            else
                "IN: ??";
            dps_in_dims = measureText(overlay.mem_dc, dps_in_text);
            dps_in_pos = calculateTextPosition(combat_cfg.incoming_position, dps_in_dims.width, dps_in_dims.height, overlay.width, overlay.height, combat_cfg.incoming_offset_x, combat_cfg.incoming_offset_y);
            fillTextBackground(overlay.pixels, overlay.width, overlay.height, dps_in_pos.x, dps_in_pos.y, dps_in_dims.width, dps_in_dims.height, settings.combat_incoming_bg_color);
            _ = win32.SelectObject(overlay.mem_dc, font);
        }
        if (combat_cfg.show_outgoing and thumbnail.has_dps_data and (thumbnail.last_outgoing_dps == null or thumbnail.last_outgoing_dps.? > 0)) {
            const f = try painter.getCachedFont(.combat_outgoing, dpi, combat_cfg.outgoing_font_name, scalePixels(combat_cfg.outgoing_font_size, dpi_scale), combat_cfg.outgoing_font_weight);
            dps_out_font = f;
            _ = win32.SelectObject(overlay.mem_dc, f);
            dps_out_text = if (thumbnail.last_outgoing_dps) |dps|
                std.fmt.bufPrint(&dps_out_buf, "OUT: {d:.0}", .{dps}) catch "OUT: ---"
            else
                "OUT: ??";
            dps_out_dims = measureText(overlay.mem_dc, dps_out_text);
            dps_out_pos = calculateTextPosition(combat_cfg.outgoing_position, dps_out_dims.width, dps_out_dims.height, overlay.width, overlay.height, combat_cfg.outgoing_offset_x, combat_cfg.outgoing_offset_y);
            fillTextBackground(overlay.pixels, overlay.width, overlay.height, dps_out_pos.x, dps_out_pos.y, dps_out_dims.width, dps_out_dims.height, settings.combat_outgoing_bg_color);
            _ = win32.SelectObject(overlay.mem_dc, font);
        }
    }

    // Measure and fill mining rate text background BEFORE the border so the border renders on top.
    // ISK rate (if shown) stacks as a second GDI-single-line text; both lines share one background width so text can align to mining_cfg.position's edge without a gap.
    var mining_buf: [32]u8 = undefined;
    var mining_isk_buf: [24]u8 = undefined;
    var mining_text: []const u8 = "";
    var mining_isk_text: []const u8 = "";
    var mining_pos: TextPos = .{ .x = 0, .y = 0 };
    var mining_isk_pos: TextPos = .{ .x = 0, .y = 0 };
    var mining_dims: TextDimensions = .{ .width = 0, .height = 0 };
    var mining_isk_dims: TextDimensions = .{ .width = 0, .height = 0 };
    var mining_block_x: i32 = 0;
    var mining_block_width: usize = 0;
    var mining_font: ?win32.HFONT = null;
    if (config.mining.enabled and config.thumbnail.showText and thumbnail.has_mining_data and (thumbnail.last_mining_rate == null or thumbnail.last_mining_rate.? > 0)) {
        const mining_cfg = &config.mining;
        const mf = try painter.getCachedFont(.mining, dpi, mining_cfg.font_name, scalePixels(mining_cfg.font_size, dpi_scale), mining_cfg.font_weight);
        mining_font = mf;
        _ = win32.SelectObject(overlay.mem_dc, mf);
        if (thumbnail.last_mining_rate) |rate| {
            // Displayed per-minute rather than per-second so low-yield ore doesn't round to "0".
            const rate_per_min = rate * 60.0;
            var raw_buf: [16]u8 = undefined;
            const raw = if (rate_per_min < 10.0)
                std.fmt.bufPrint(&raw_buf, "{d:.1}", .{rate_per_min}) catch "---"
            else
                std.fmt.bufPrint(&raw_buf, "{d:.0}", .{rate_per_min}) catch "---";
            var comma_buf: [16]u8 = undefined;
            const formatted = insertThousandsSeparators(&comma_buf, raw);
            mining_text = std.fmt.bufPrint(&mining_buf, "M: {s} m3/min", .{formatted}) catch "M: ---";
        } else {
            mining_text = "M: ?? m3/min";
        }
        mining_dims = measureText(overlay.mem_dc, mining_text);

        if (mining_cfg.show_isk_rate) {
            const period_secs: f32 = if (mining_cfg.isk_rate_unit == .hour) 3600.0 else 60.0;
            const unit_suffix: []const u8 = if (mining_cfg.isk_rate_unit == .hour) "hr" else "min";
            if (thumbnail.last_mining_isk_rate) |isk_rate| {
                var isk_buf: [16]u8 = undefined;
                const isk_abbrev = formatIskAbbrev(&isk_buf, isk_rate * period_secs);
                mining_isk_text = std.fmt.bufPrint(&mining_isk_buf, "{s} ISK/{s}", .{ isk_abbrev, unit_suffix }) catch "";
            } else {
                mining_isk_text = std.fmt.bufPrint(&mining_isk_buf, "?? ISK/{s}", .{unit_suffix}) catch "";
            }
            mining_isk_dims = measureText(overlay.mem_dc, mining_isk_text);
        }

        // Anchored as one combined block so Bottom*/Center* positions account for both lines' height, not just the first; each line then just stacks top-down from there.
        mining_block_width = @max(mining_dims.width, mining_isk_dims.width);
        const combined_height = mining_dims.height + mining_isk_dims.height;
        const anchor = calculateTextPosition(mining_cfg.position, mining_block_width, combined_height, overlay.width, overlay.height, mining_cfg.offset_x, mining_cfg.offset_y);
        mining_block_x = anchor.x;

        const h_align = horizontalAlignOf(mining_cfg.position);
        mining_pos = .{ .x = alignedLineX(anchor.x, mining_block_width, mining_dims.width, h_align), .y = anchor.y };
        mining_isk_pos = .{ .x = alignedLineX(anchor.x, mining_block_width, mining_isk_dims.width, h_align), .y = anchor.y + @as(i32, @intCast(mining_dims.height)) };

        fillTextBackground(overlay.pixels, overlay.width, overlay.height, mining_block_x, mining_pos.y, mining_block_width, mining_dims.height, settings.mining_bg_color);
        if (mining_isk_text.len > 0) {
            fillTextBackground(overlay.pixels, overlay.width, overlay.height, mining_block_x, mining_isk_pos.y, mining_block_width, mining_isk_dims.height, settings.mining_bg_color);
        }
        _ = win32.SelectObject(overlay.mem_dc, font);
    }

    // Measure and fill bounty rate text background BEFORE the border, same as the mining block above.
    var bounty_buf: [24]u8 = undefined;
    var bounty_text: []const u8 = "";
    var bounty_pos: TextPos = .{ .x = 0, .y = 0 };
    var bounty_dims: TextDimensions = .{ .width = 0, .height = 0 };
    var bounty_font: ?win32.HFONT = null;
    if (config.bounty.enabled and config.thumbnail.showText and thumbnail.has_bounty_data and (thumbnail.last_bounty_isk_rate == null or thumbnail.last_bounty_isk_rate.? > 0)) {
        const bounty_cfg = &config.bounty;
        const bf = try painter.getCachedFont(.bounty, dpi, bounty_cfg.font_name, scalePixels(bounty_cfg.font_size, dpi_scale), bounty_cfg.font_weight);
        bounty_font = bf;
        _ = win32.SelectObject(overlay.mem_dc, bf);
        const period_secs: f32 = if (bounty_cfg.isk_rate_unit == .hour) 3600.0 else 60.0;
        const unit_suffix: []const u8 = if (bounty_cfg.isk_rate_unit == .hour) "hr" else "min";
        if (thumbnail.last_bounty_isk_rate) |isk_rate| {
            var isk_buf: [16]u8 = undefined;
            const isk_abbrev = formatIskAbbrev(&isk_buf, isk_rate * period_secs);
            bounty_text = std.fmt.bufPrint(&bounty_buf, "B: {s} ISK/{s}", .{ isk_abbrev, unit_suffix }) catch "B: ---";
        } else {
            bounty_text = std.fmt.bufPrint(&bounty_buf, "B: ?? ISK/{s}", .{unit_suffix}) catch "B: ---";
        }
        bounty_dims = measureText(overlay.mem_dc, bounty_text);
        bounty_pos = calculateTextPosition(bounty_cfg.position, bounty_dims.width, bounty_dims.height, overlay.width, overlay.height, bounty_cfg.offset_x, bounty_cfg.offset_y);

        fillTextBackground(overlay.pixels, overlay.width, overlay.height, bounty_pos.x, bounty_pos.y, bounty_dims.width, bounty_dims.height, settings.bounty_bg_color);
        _ = win32.SelectObject(overlay.mem_dc, font);
    }

    if (settings.show_border) {
        drawBorder(
            overlay.pixels,
            overlay.width,
            overlay.height,
            @intCast(settings.border_width),
            settings.border_color,
            settings.border_style,
        );
    }

    // Main font is already selected (hoisted at the top of this function).
    if (settings.show_character_name) {
        renderText(overlay.mem_dc, display_name, char_text_pos.x, char_text_pos.y, settings.character_name_color);
    }
    if (settings.show_system_name) {
        const sf = sys_font.?;
        _ = win32.SelectObject(overlay.mem_dc, sf);
        renderText(overlay.mem_dc, system_name, system_text_pos.x, system_text_pos.y, settings.system_name_color);
        _ = win32.SelectObject(overlay.mem_dc, font);
    }
    if (settings.show_notifications and has_notification_text) {
        const nf = notif_font.?;
        _ = win32.SelectObject(overlay.mem_dc, nf);
        var notif_line_y = notifications_text_pos.y;
        var idx: usize = 0;
        while (idx < settings.notification_line_count) : (idx += 1) {
            const line = settings.notification_lines[idx];
            renderText(overlay.mem_dc, line.text, notifications_text_pos.x, notif_line_y, line.color);
            notif_line_y += @as(i32, @intCast(notif_line_dims[idx].height));
        }
        _ = win32.SelectObject(overlay.mem_dc, font);
    }
    if (settings.show_quick_group_badge) {
        const qf = qg_font.?;
        _ = win32.SelectObject(overlay.mem_dc, qf);
        renderText(overlay.mem_dc, settings.quick_group_badge_text, qg_badge_pos.x, qg_badge_pos.y, settings.quick_group_badge_color);
        _ = win32.SelectObject(overlay.mem_dc, font);
    }
    if (config.combat.enabled and config.thumbnail.showText) {
        const combat_cfg = &config.combat;
        if (combat_cfg.show_incoming and dps_in_text.len > 0) {
            _ = win32.SelectObject(overlay.mem_dc, dps_in_font.?);
            renderText(overlay.mem_dc, dps_in_text, dps_in_pos.x, dps_in_pos.y, combat_cfg.incoming_color);
            _ = win32.SelectObject(overlay.mem_dc, font);
        }
        if (combat_cfg.show_outgoing and dps_out_text.len > 0) {
            _ = win32.SelectObject(overlay.mem_dc, dps_out_font.?);
            renderText(overlay.mem_dc, dps_out_text, dps_out_pos.x, dps_out_pos.y, combat_cfg.outgoing_color);
            _ = win32.SelectObject(overlay.mem_dc, font);
        }
    }

    if (config.mining.enabled and config.thumbnail.showText and mining_text.len > 0) {
        const mf = mining_font.?;
        _ = win32.SelectObject(overlay.mem_dc, mf);
        renderText(overlay.mem_dc, mining_text, mining_pos.x, mining_pos.y, config.mining.color);
        if (mining_isk_text.len > 0) {
            renderText(overlay.mem_dc, mining_isk_text, mining_isk_pos.x, mining_isk_pos.y, config.mining.color);
        }
        _ = win32.SelectObject(overlay.mem_dc, font);
    }

    if (config.bounty.enabled and config.thumbnail.showText and bounty_text.len > 0) {
        const bf = bounty_font.?;
        _ = win32.SelectObject(overlay.mem_dc, bf);
        renderText(overlay.mem_dc, bounty_text, bounty_pos.x, bounty_pos.y, config.bounty.color);
        _ = win32.SelectObject(overlay.mem_dc, font);
    }

    // Bounded to the rects text/glyphs were actually drawn into instead of scanning the whole overlay.
    if (settings.show_character_name) {
        gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, char_text_pos.x, char_text_pos.y, char_text_dims.width, char_text_dims.height);
    }
    if (settings.show_system_name) {
        gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, system_text_pos.x, system_text_pos.y, system_text_dims.width, system_text_dims.height);
    }
    if (settings.show_notifications and has_notification_text) {
        gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, notifications_text_pos.x, notifications_text_pos.y, notifications_text_dims.width, notifications_text_dims.height);
    }
    if (settings.show_quick_group_badge) {
        gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, qg_badge_pos.x, qg_badge_pos.y, qg_badge_dims.width, qg_badge_dims.height);
    }
    if (config.combat.enabled) {
        if (dps_in_text.len > 0) {
            gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, dps_in_pos.x, dps_in_pos.y, dps_in_dims.width, dps_in_dims.height);
        }
        if (dps_out_text.len > 0) {
            gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, dps_out_pos.x, dps_out_pos.y, dps_out_dims.width, dps_out_dims.height);
        }
    }
    if (mining_text.len > 0) {
        gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, mining_block_x, mining_pos.y, mining_block_width, mining_dims.height);
    }
    if (mining_isk_text.len > 0) {
        gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, mining_block_x, mining_isk_pos.y, mining_block_width, mining_isk_dims.height);
    }
    if (bounty_text.len > 0) {
        gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, bounty_pos.x, bounty_pos.y, bounty_dims.width, bounty_dims.height);
    }

    const window_size = win32.SIZE{ .cx = width, .cy = height };
    const source_pos = win32.POINT{ .x = 0, .y = 0 };
    var blend = win32.BLENDFUNCTION{
        .BlendOp = win32.AC_SRC_OVER,
        .BlendFlags = 0,
        .SourceConstantAlpha = settings.overlay_alpha,
        .AlphaFormat = win32.AC_SRC_ALPHA,
    };

    // hdcDst=null is valid here: UpdateLayeredWindow uses the screen DC internally when hdcSrc is supplied, sparing a GetDC/ReleaseDC pair every repaint.
    _ = win32.UpdateLayeredWindow(
        hwnd,
        null,
        null,
        @constCast(&window_size),
        overlay.mem_dc,
        @constCast(&source_pos),
        0,
        &blend,
        win32.ULW_ALPHA,
    );
}

// Per-state override (if any) wins, then opacity is forced fully opaque when the window's own
// Opacity setting should apply instead, so it isn't compounded with this color's own alpha.
fn resolveTextBgColor(state_cfg: config_mod.Config.StateVisualConfig, base_color: u32, force_opaque: bool) u32 {
    const resolved = state_cfg.getTextBgColor(base_color);
    return if (force_opaque) color_mod.withAlpha(resolved, 255) else resolved;
}

/// Builds RenderSettings from Painter config; the single point where a thumbnail's effective render state determines all visual properties.
fn createRenderSettings(cfg: *config_mod.Config, thumbnail: *const ThumbnailWindow, active_source_hwnd: ?win32.HWND) RenderSettings {
    const state = thumbnail.effectiveRenderState(active_source_hwnd);
    const character_name = thumbnail.character_name;
    const system_name = thumbnail.system_name;
    const cached_system_color = thumbnail.cached_system_color;
    const is_visible = thumbnail.visibility_state.isVisible();
    // Read live rather than cached, so fonts/geometry track whichever monitor this window is on right now.
    const dpi_scale = Painter.dpiToScale(Painter.getWindowDpi(thumbnail.hwnd));

    const state_cfg = cfg.thumbnail.getStateConfig(state);

    // Already resolved when system name was set.
    const system_color = cached_system_color;

    // Alert is treated like Active as a base (it's an attention event); StateVisualConfig for Alert, per-type overrides, and per-character overrides all layer on top of this.
    const is_alert_like = (state == .Active or state == .Alert);
    const base_border_width = if (is_alert_like) cfg.thumbnail.borderWidth else cfg.thumbnail.inactiveBorderWidth;
    const base_border_color = if (is_alert_like) cfg.thumbnail.borderColor else cfg.thumbnail.inactiveBorderColor;
    const base_border_style = if (is_alert_like) cfg.thumbnail.borderStyle else cfg.thumbnail.inactiveBorderStyle;
    const base_show_border = if (is_alert_like) cfg.thumbnail.showBorderWhenFocused else cfg.thumbnail.showBorderWhenInactive;

    // Per-character override: hides this thumbnail unconditionally, regardless of state.
    const char_hidden = cfg.isThumbnailHidden(character_name);

    // char_hidden is handled separately as an absolute override on the final show_thumbnail field below.
    const base_show_thumbnail = if (!is_visible)
        false
    else if (state == .Active)
        !cfg.thumbnail.activeThumbnailHidden
    else
        true;

    // If the thumbnail, active thumbnail, or this character specifically is hidden, don't show border or text either.
    const should_hide_all = !is_visible or char_hidden or (state == .Active and cfg.thumbnail.activeThumbnailHidden);

    // Whether this thumbnail belongs to the character focused when the notification fired; notification border effects must not fight with that character's always-on active border.
    const notif_on_focused_char = thumbnail.isFocused(active_source_hwnd);

    // Border color/flash effects are governed solely by the newest (index 0) stacked notification; older entries only add text lines.
    // Per-type "show_border: false" forces the border off during Alert, skipped for the focused character so it can't also hide that character's active border.
    const notif_hides_border = state == .Alert and !notif_on_focused_char and
        if (thumbnail.active_notifications[0]) |notif| !notif.show_border else false;

    // Blinks the border off for alternating phases at Alert start (see isNotificationFlashOff), skipped for the focused character for the same reason as notif_hides_border.
    const notif_flash_hides_border = state == .Alert and !notif_on_focused_char and
        if (thumbnail.active_notifications[0]) |notif| isNotificationFlashOff(notif, win32.GetTickCount64()) else false;

    const effective_show_border = if (should_hide_all or notif_hides_border or notif_flash_hides_border)
        false
    else
        state_cfg.getShowBorder(base_show_border);

    const effective_show_text = if (should_hide_all)
        false
    else
        cfg.thumbnail.showText;

    const effective_show_character_name = if (should_hide_all)
        false
    else
        (cfg.thumbnail.showText and cfg.thumbnail.showCharacterName);

    const effective_show_system_name = if (should_hide_all)
        false
    else
        (cfg.thumbnail.showText and cfg.thumbnail.showSystemName);

    const effective_show_notifications = if (should_hide_all)
        false
    else
        (cfg.thumbnail.showText and cfg.thumbnail.notifications.enabled);

    // Combat/Mining/Bounty are also gated by showText, but checked directly in the render function below,
    // since they already bypass RenderSettings entirely for their enabled-checks.
    const effective_show_quick_group_badge = if (should_hide_all)
        false
    else
        (cfg.thumbnail.showText and cfg.thumbnail.showQuickGroupBadge);

    var final_border_color = state_cfg.getBorderColor(base_border_color);

    // When suppress_when_focused is true and the character is focused, the border falls back to normal Active appearance instead of the Alert override color.
    const is_suppressed_alert = if (state == .Alert) blk: {
        if (thumbnail.active_notifications[0]) |notif| {
            const notif_is_focused = thumbnail.isFocused(active_source_hwnd);
            break :blk notif.suppress_when_focused and notif_is_focused;
        }
        break :blk false;
    } else false;

    // Per-type border color override sits above the Alert StateVisualConfig but below per-character overrides; skipped when the alert is suppressed.
    if (state == .Alert and !is_suppressed_alert) {
        if (thumbnail.active_notifications[0]) |notif| {
            if (notif.border_color_override) |color| {
                final_border_color = color;
            }
        }
    }

    // Fallback color for stacked notification lines that don't carry their own text_color_override.
    const notification_base_text_color = state_cfg.getTextColor(cfg.thumbnail.characterNameColor);

    // Per-character border color has the highest precedence; a suppressed Alert is treated as Active for border purposes.
    if (cfg.getCharacterBorderColors(character_name)) |char_colors| {
        if (state == .Active or (state == .Alert and is_suppressed_alert)) {
            if (char_colors.activeBorderColor) |color| {
                final_border_color = color;
            }
        } else if (state == .Inactive or state == .Minimized) {
            if (char_colors.inactiveBorderColor) |color| {
                final_border_color = color;
            }
        }
    }

    // Unique Character Name Colors takes precedence over the per-state color, same as border color above.
    var final_text_color = state_cfg.getTextColor(cfg.thumbnail.characterNameColor);
    if (thumbnail.cached_character_color) |unique_color| {
        final_text_color = unique_color;
    }

    const char_size = cfg.getCharacterSize(character_name);
    const logical_width = if (char_size) |cs| cs.width orelse cfg.thumbnail.width else cfg.thumbnail.width;
    const logical_height = if (char_size) |cs| cs.height orelse cfg.thumbnail.height else cfg.thumbnail.height;
    const overlay_width = scalePixels(logical_width, dpi_scale);
    const overlay_height = scalePixels(logical_height, dpi_scale);

    // Builds the visible stack, newest first: each entry keeps its own suppress_when_focused/text_color_override,
    // so different notification types can be filtered and colored independently within the same stack.
    var notification_lines: [MAX_STACKED_NOTIFICATIONS]NotificationLine = .{NotificationLine{}} ** MAX_STACKED_NOTIFICATIONS;
    var notification_line_count: usize = 0;
    if (effective_show_notifications) {
        const notif_is_focused = thumbnail.isFocused(active_source_hwnd);
        for (thumbnail.active_notifications) |maybe_notif| {
            const notif = maybe_notif orelse break;
            if (notif.suppress_when_focused and notif_is_focused) continue;
            notification_lines[notification_line_count] = .{
                .text = notif.text,
                .color = notif.text_color_override orelse notification_base_text_color,
            };
            notification_line_count += 1;
        }
    }

    return .{
        .show_text = effective_show_text,
        .show_character_name = effective_show_character_name,
        .character_name = character_name,
        .show_system_name = effective_show_system_name,
        .system_name = system_name,
        .character_name_color = final_text_color,
        .system_name_color = system_color,
        .character_name_bg_color = resolveTextBgColor(state_cfg, cfg.thumbnail.characterNameBgColor, cfg.thumbnail.applyOpacityToOverlayTexts),
        .system_name_bg_color = resolveTextBgColor(state_cfg, cfg.thumbnail.systemNameBgColor, cfg.thumbnail.applyOpacityToOverlayTexts),
        .quick_group_badge_bg_color = resolveTextBgColor(state_cfg, cfg.thumbnail.quickGroupBadgeBgColor, cfg.thumbnail.applyOpacityToOverlayTexts),
        .notifications_bg_color = resolveTextBgColor(state_cfg, cfg.thumbnail.notifications.bg_color, cfg.thumbnail.applyOpacityToOverlayTexts),
        .combat_incoming_bg_color = resolveTextBgColor(state_cfg, cfg.combat.incoming_bg_color, cfg.thumbnail.applyOpacityToOverlayTexts),
        .combat_outgoing_bg_color = resolveTextBgColor(state_cfg, cfg.combat.outgoing_bg_color, cfg.thumbnail.applyOpacityToOverlayTexts),
        .mining_bg_color = resolveTextBgColor(state_cfg, cfg.mining.bg_color, cfg.thumbnail.applyOpacityToOverlayTexts),
        .bounty_bg_color = resolveTextBgColor(state_cfg, cfg.bounty.bg_color, cfg.thumbnail.applyOpacityToOverlayTexts),
        .character_name_font_name = cfg.thumbnail.characterNameFontName,
        .character_name_font_size = scalePixels(cfg.thumbnail.characterNameFontSize, dpi_scale),
        .character_name_font_weight = cfg.thumbnail.characterNameFontWeight,
        .character_name_position = cfg.thumbnail.characterNamePosition,
        .character_name_offset_x = cfg.thumbnail.characterNameOffsetX,
        .character_name_offset_y = cfg.thumbnail.characterNameOffsetY,
        .system_name_position = cfg.thumbnail.systemNamePosition,
        .system_name_offset_x = cfg.thumbnail.systemNameOffsetX,
        .system_name_offset_y = cfg.thumbnail.systemNameOffsetY,
        .system_name_font_name = cfg.thumbnail.systemNameFontName,
        .system_name_font_size = scalePixels(cfg.thumbnail.systemNameFontSize, dpi_scale),
        .system_name_font_weight = cfg.thumbnail.systemNameFontWeight,
        .show_notifications = effective_show_notifications,
        .notification_lines = notification_lines,
        .notification_line_count = notification_line_count,
        .notifications_position = cfg.thumbnail.notifications.position,
        .notifications_offset_x = cfg.thumbnail.notifications.offset_x,
        .notifications_offset_y = cfg.thumbnail.notifications.offset_y,
        .notifications_font_name = cfg.thumbnail.notifications.font_name,
        .notifications_font_size = scalePixels(cfg.thumbnail.notifications.font_size, dpi_scale),
        .notifications_font_weight = cfg.thumbnail.notifications.font_weight,
        .show_border = effective_show_border,
        .border_width = state_cfg.getBorderWidth(base_border_width),
        .border_color = final_border_color,
        .border_style = state_cfg.getBorderStyle(base_border_style),
        .show_exclusion_overlay = blk: {
            const show = thumbnail.is_excluded_from_cycle and is_visible;
            if (thumbnail.is_excluded_from_cycle) {
                slog.debug("Render settings for {s}: is_excluded={}, is_visible={}, show_overlay={}", .{ character_name, thumbnail.is_excluded_from_cycle, is_visible, show });
            }
            break :blk show;
        },
        .exclusion_overlay_style = cfg.thumbnail.exclusionOverlayStyle,
        .exclusion_overlay_color = cfg.thumbnail.exclusionOverlayColor,
        .show_quick_group_badge = effective_show_quick_group_badge and thumbnail.cached_quick_group_label.len > 0 and is_visible,
        .quick_group_badge_text = thumbnail.cached_quick_group_label,
        .quick_group_badge_color = cfg.thumbnail.quickGroupBadgeColor,
        .quick_group_badge_position = cfg.thumbnail.quickGroupBadgePosition,
        .quick_group_badge_offset_x = cfg.thumbnail.quickGroupBadgeOffsetX,
        .quick_group_badge_offset_y = cfg.thumbnail.quickGroupBadgeOffsetY,
        .quick_group_badge_font_name = cfg.thumbnail.quickGroupBadgeFontName,
        .quick_group_badge_font_size = scalePixels(cfg.thumbnail.quickGroupBadgeFontSize, dpi_scale),
        .quick_group_badge_font_weight = cfg.thumbnail.quickGroupBadgeFontWeight,
        // visibility_state and per-character hideThumbnail take absolute priority over per-state showThumbnail config.
        .show_thumbnail = if (!is_visible or char_hidden) false else state_cfg.getShowThumbnail(base_show_thumbnail),
        .overlay_alpha = if (cfg.thumbnail.applyOpacityToOverlayTexts) cfg.thumbnail.thumbnailOpacity else OVERLAY_ALPHA,
        .overlay_width = overlay_width,
        .overlay_height = overlay_height,
        // -1.0 stands in for "calculating" (null) here — no real rate is negative, and this struct only needs
        // equality for cache invalidation, not the calculating/zero distinction the render code below cares about.
        .dps_incoming = if (cfg.combat.enabled) (thumbnail.last_incoming_dps orelse -1.0) else 0.0,
        .dps_outgoing = if (cfg.combat.enabled) (thumbnail.last_outgoing_dps orelse -1.0) else 0.0,
        .mining_rate = if (cfg.mining.enabled) (thumbnail.last_mining_rate orelse -1.0) else 0.0,
        .mining_isk_rate = if (cfg.mining.enabled and cfg.mining.show_isk_rate) (thumbnail.last_mining_isk_rate orelse -1.0) else 0.0,
        .bounty_isk_rate = if (cfg.bounty.enabled) (thumbnail.last_bounty_isk_rate orelse -1.0) else 0.0,
        .has_dps_data = thumbnail.has_dps_data,
        .has_mining_data = thumbnail.has_mining_data,
        .has_bounty_data = thumbnail.has_bounty_data,
        .dps_incoming_color = cfg.combat.incoming_color,
        .dps_outgoing_color = cfg.combat.outgoing_color,
        .mining_color = cfg.mining.color,
        .bounty_color = cfg.bounty.color,
    };
}

fn windowDestroyProc(
    hWinEventHook: win32.HANDLE,
    event: win32.DWORD,
    hwnd: win32.HWND,
    idObject: win32.LONG,
    idChild: win32.LONG,
    idEventThread: win32.DWORD,
    dwmsEventTime: win32.DWORD,
) callconv(.c) void {
    _ = hWinEventHook;
    _ = event;
    _ = idObject;
    _ = idChild;
    _ = idEventThread;
    _ = dwmsEventTime;

    const painter = g_painter_ptr orelse return;

    const index = painter.resolveThumbnailIndexForDestroy(hwnd) orelse return;

    const thumbnail = painter.thumbnails.items[index];
    slog.info("Window closed (event), removing thumbnail for {s}", .{thumbnail.character_name});

    _ = painter.hwnd_to_thumbnail_index.remove(thumbnail.source_hwnd);
    _ = painter.thumbnail_hwnd_to_index.remove(thumbnail.hwnd);
    _ = painter.text_hwnd_to_index.remove(thumbnail.text_hwnd);

    painter.destroyThumbnailResources(thumbnail);
    _ = painter.thumbnails.orderedRemove(index);

    painter.rebuildHwndIndex(false);
}

/// True if hwnd belongs to explorer.exe (taskbar, tray, Start menu, etc.), which should always be able to sit above our thumbnails.
fn isExplorerOwned(hwnd: win32.HWND) bool {
    var process_id: win32.DWORD = 0;
    _ = win32.GetWindowThreadProcessId(hwnd, &process_id);
    if (process_id == 0) return false;

    const process_handle = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, win32.FALSE, process_id) orelse return false;
    defer _ = win32.CloseHandle(process_handle);

    var exe_path: [260:0]u8 = undefined;
    const path_len = win32.GetModuleFileNameExA(process_handle, null, &exe_path, exe_path.len);
    if (path_len == 0) return false;

    const path_slice = exe_path[0..@intCast(path_len)];
    const suffix = "\\explorer.exe";
    if (path_slice.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(path_slice[path_slice.len - suffix.len ..], suffix);
}

fn winEventProc(
    hWinEventHook: win32.HANDLE,
    event: win32.DWORD,
    hwnd: win32.HWND,
    idObject: win32.LONG,
    idChild: win32.LONG,
    idEventThread: win32.DWORD,
    dwmsEventTime: win32.DWORD,
) callconv(.c) void {
    _ = hWinEventHook;
    _ = event;
    _ = idObject;
    _ = idChild;
    _ = idEventThread;
    _ = dwmsEventTime;

    const painter = g_painter_ptr orelse return;

    // O(1) lookup: Check if it's one of our thumbnail windows (early exit - most common case)
    if (painter.thumbnail_hwnd_to_index.contains(hwnd) or painter.text_hwnd_to_index.contains(hwnd)) {
        slog.debug("Thumbnail window got focus (ignoring): {*}", .{hwnd});
        return;
    }

    // A newly-foregrounded topmost window gets inserted above ours in the z-order band; push back unless it's shell UI allowed to stay on top.
    const ex_style = win32.GetWindowLongPtrA(hwnd, win32.GWL_EXSTYLE);
    if (ex_style & win32.WS_EX_TOPMOST != 0 and !isExplorerOwned(hwnd)) {
        painter.reassertTopmost();
    }

    const is_eve_window = painter.hwnd_to_thumbnail_index.contains(hwnd);

    if (!is_eve_window) {
        if (painter.config.thumbnail.hideWhenNoEveFocus) {
            slog.debug("Non-EVE window focused (hwnd={*}), starting {}ms debounce timer (hideWhenNoEveFocus=true)", .{ hwnd, painter.config.thumbnail.hideDebounceMs });
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
            slog.debug("Non-EVE window focused (hwnd={*}), ignoring (hideWhenNoEveFocus=false)", .{hwnd});
        }
        return;
    }

    // Cancel any pending hide timer since an EVE window now has focus
    if (painter.hide_debounce_timer_hwnd) |timer_hwnd| {
        _ = win32.KillTimer(timer_hwnd, HIDE_DEBOUNCE_TIMER_ID);
        painter.hide_debounce_timer_hwnd = null;
        slog.debug("Cancelled hide debounce timer (EVE window focused)", .{});
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
        slog.debug("EVE window focused: {s}", .{thumbnail.character_name});
        if (g_hotkey_manager_ptr) |manager| {
            manager.updateFocusedCharacter(thumbnail.character_name);
        }
    }
}
