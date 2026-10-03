//! The History Panel: a draggable list of recent notifications, with category filter buttons.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const PanelWindow = @import("../platform/panel_window.zig").PanelWindow;
const config_mod = @import("../config.zig");
const color = @import("../util/color.zig");
const notification = @import("notification.zig");
const history = @import("history.zig");
const painter_mod = @import("../painter.zig");
const activation = @import("../clients/activation.zig");
const drag_panel = @import("../drag/panel.zig");
const log = @import("../log.zig");

const slog = log.scoped("history_panel");

const HEADER_HEIGHT: i32 = 18;
const FOOTER_HEIGHT: i32 = 18;
const ROW_HEIGHT: i32 = 16;
const TEXT_LEFT: i32 = 6;
const RIGHT_MARGIN: i32 = 6;
const TEXT_BUF: usize = 160;

const RGB_HEADER: u32 = 0x001A1A1A;
const RGB_BODY: u32 = 0x000F0F0F;
const ARGB_SEPARATOR: u32 = 0xFF888888;
const ARGB_HDR_TEXT: u32 = 0xFFFFFFFF;
const ARGB_CHAR_NAME: u32 = 0xFFCCCCCC;
const ARGB_EMPTY_TEXT: u32 = 0xFF666666;
const ARGB_TIMESTAMP: u32 = 0xFF666666;
const RGB_FRAME: u32 = 0x00888888;
// Neutral gray, not an accent color, to match the panel's existing monochrome palette.
const RGB_BUTTON_ACTIVE_BG: u32 = 0x00404040;
const ARGB_BUTTON_ACTIVE_TEXT: u32 = ARGB_HDR_TEXT;
const ARGB_BUTTON_INACTIVE_TEXT: u32 = ARGB_EMPTY_TEXT;

/// Granularity of the timestamp text baked into the render signature, so it doesn't redraw every scan tick.
const TIMESTAMP_BUCKET_MS: u64 = 15_000;

/// Order and labels for the footer's category filter buttons; index-paired with each other and with HistoryPanelWindow.category_button_rects.
const CATEGORY_ORDER = [_]notification.NotificationCategory{ .Fleet, .Mining, .Combat, .Navigation, .General };
const CATEGORY_LABELS = [_][]const u8{ "FLT", "MIN", "CBT", "NAV", "GEN" };

const HISTORY_PANEL_WINDOW_CLASS = "EVE_HISTORY_PANEL_CLASS";

const ButtonRect = struct { left: i32 = 0, right: i32 = 0 };

/// Owns the History Panel window and when it's on-screen: display.showNotifInfoPanel creates it, hideNotifInfoPanelWhenNoCharacters auto-hides it, and the tray toggle can force it visible.
pub const HistoryPanel = struct {
    window: ?HistoryPanelWindow = null,
    /// Tray-toggle override: forces the panel visible past hideNotifInfoPanelWhenNoCharacters until characters go logged-in -> logged-out again.
    force_visible: bool = false,
    /// Last-seen "any character logged in", used to detect the logged-in -> logged-out edge that clears force_visible.
    had_characters: bool = false,

    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) HistoryPanel {
        if (!store.live.display.showNotifInfoPanel) return .{};
        const window = HistoryPanelWindow.init(allocator, store, instance) catch |err| {
            slog.err("Failed to create History Panel window: {}", .{err});
            return .{};
        };
        return .{ .window = window };
    }

    pub fn deinit(self: *HistoryPanel) void {
        if (self.window) |*window| window.deinit();
        self.window = null;
    }

    /// Whether the panel is actually on-screen, accounting for hideNotifInfoPanelWhenNoCharacters and the tray-toggle override; drives both the render/hide gate and the tray menu's checked state.
    pub fn isVisible(self: *const HistoryPanel, cfg: *const config_mod.Config, any_character_logged_in: bool) bool {
        if (self.window == null) return false;
        if (!cfg.display.hideNotifInfoPanelWhenNoCharacters) return true;
        return any_character_logged_in or self.force_visible;
    }

    /// Keyed on isVisible() rather than window existence, so it turns fully off (not re-hidden) when toggled while visible, and forces it on immediately - even with no characters logged in - when toggled while off/auto-hidden.
    pub fn toggle(self: *HistoryPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE, any_character_logged_in: bool) void {
        if (self.isVisible(&store.live, any_character_logged_in)) {
            self.deinit();
            store.update(.{ .display = .{ .showNotifInfoPanel = false } });
            self.force_visible = false;
            return;
        }
        if (self.window == null) {
            self.window = HistoryPanelWindow.init(allocator, store, instance) catch |err| {
                slog.err("Failed to create History Panel window: {}", .{err});
                return;
            };
        }
        store.update(.{ .display = .{ .showNotifInfoPanel = true } });
        self.force_visible = true;
    }

    /// Matches the window to showNotifInfoPanel and its configured position, for a change made in the config dialog rather than by `toggle`.
    pub fn sync(self: *HistoryPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) void {
        const wanted = store.live.display.showNotifInfoPanel;
        if (!wanted and self.window != null) {
            self.deinit();
            self.force_visible = false;
        } else if (wanted and self.window == null) {
            self.window = HistoryPanelWindow.init(allocator, store, instance) catch |err| {
                slog.err("Failed to create History Panel window: {}", .{err});
                return;
            };
        }
        if (self.window) |*window| window.panel.followPosition(store.live.display.notifInfoPanelX, store.live.display.notifInfoPanelY);
    }

    /// Per-tick: renders the panel from the painter's live history, or hides it.
    pub fn update(self: *HistoryPanel, painter: *const painter_mod.Painter, any_character_logged_in: bool) void {
        if (self.had_characters and !any_character_logged_in) self.force_visible = false;
        self.had_characters = any_character_logged_in;

        const window = if (self.window) |*w| w else return;
        if (self.isVisible(painter.config, any_character_logged_in)) {
            window.render(painter) catch |err| {
                slog.err("Failed to render History Panel window: {}", .{err});
            };
        } else {
            window.hide();
        }
    }
};

/// `first`/`last` are newest-first history indices, equal unless merged.
const HistoryRow = struct {
    hwnd: win32.HWND,
    count: usize,
    first: usize,
    last: usize,
};

pub const HistoryPanelWindow = struct {
    panel: PanelWindow,
    store: *config_mod.ProfileStore,
    config: *const config_mod.Config,
    history_rows: [history.CAPACITY]HistoryRow = undefined,
    history_row_count: usize = 0,
    /// Index-paired with CATEGORY_ORDER; recomputed every render for WM_LBUTTONDOWN's footer hit-test.
    category_button_rects: [CATEGORY_ORDER.len]ButtonRect = undefined,

    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) !HistoryPanelWindow {
        const display = &store.live.display;
        try registerWindowClass(instance);
        const panel = try PanelWindow.create(allocator, instance, HISTORY_PANEL_WINDOW_CLASS, "EVE Notification History", .{
            .left = display.notifInfoPanelX,
            .top = display.notifInfoPanelY,
            .right = display.notifInfoPanelX + display.notifInfoPanelWidth,
            .bottom = display.notifInfoPanelY + display.notifInfoPanelHeight,
        });
        return .{ .panel = panel, .store = store, .config = &store.live };
    }

    pub fn deinit(self: *HistoryPanelWindow) void {
        self.panel.deinit();
    }

    pub fn hide(self: *const HistoryPanelWindow) void {
        self.panel.hide();
    }

    fn saveWindowPosition(self: *HistoryPanelWindow) void {
        if (!self.config.display.rememberNotifInfoPanelPosition) return;
        const pos = self.panel.topLeft();
        self.store.update(.{ .display = .{ .notifInfoPanelX = pos.x, .notifInfoPanelY = pos.y } });
    }

    /// The type's configured color, else the thumbnail overlay's default text color.
    fn resolveNotifTextColor(self: *const HistoryPanelWindow, ntype: notification.NotificationType) u32 {
        const type_cfg = self.config.thumbnail.notifications.getTypeConfig(ntype);
        return (type_cfg.text_color orelse self.config.thumbnail.characterNameColor) & 0x00FF_FFFF;
    }

    fn updateCategoryButtonRects(self: *HistoryPanelWindow, win_w: i32) void {
        const n: i64 = @intCast(CATEGORY_ORDER.len);
        for (0..CATEGORY_ORDER.len) |i| {
            const left: i32 = @intCast(@divTrunc(@as(i64, win_w) * @as(i64, @intCast(i)), n));
            const right: i32 = @intCast(@divTrunc(@as(i64, win_w) * @as(i64, @intCast(i + 1)), n));
            self.category_button_rects[i] = .{ .left = left, .right = right };
        }
    }

    fn handleFooterClick(self: *HistoryPanelWindow, cx: i32) void {
        for (CATEGORY_ORDER, 0..) |category, i| {
            const rect = self.category_button_rects[i];
            if (cx < rect.left or cx >= rect.right) continue;

            setCategoryEnabled(self.store, category, !categoryEnabled(self.config, category));
            return;
        }
    }

    fn computeRenderSignature(self: *const HistoryPanelWindow, painter: *const painter_mod.Painter) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelWidth));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelHeight));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelOpacity));
        h.update(self.config.display.notifInfoPanelFontName);
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelFontSize));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelFontWeight));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelMaxRows));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelShowTimestamp));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelShowCategoryFilters));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelMergeEnabled));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelMergeWindowSec));
        for (CATEGORY_ORDER) |category| {
            const enabled = categoryEnabled(self.config, category);
            h.update(std.mem.asBytes(&enabled));
        }
        h.update(std.mem.asBytes(&painter.notification_history.revision));

        const show_timestamp = self.config.display.notifInfoPanelShowTimestamp;
        const now = win32.Ticks.now();

        var entries: [history.CAPACITY]history.Entry = undefined;
        const hist = painter.notification_history.snapshot(&entries);
        for (hist) |*entry| {
            h.update(entry.characterName());
            h.update(entry.text());
            h.update(std.mem.asBytes(&entry.unmerged));
            const char_color = (entry.character_color orelse ARGB_CHAR_NAME) & 0x00FF_FFFF;
            const text_color = self.resolveNotifTextColor(entry.notification_type);
            h.update(std.mem.asBytes(&char_color));
            h.update(std.mem.asBytes(&text_color));
            if (show_timestamp) {
                const bucket = now.elapsedSince(entry.timestamp_ms) / TIMESTAMP_BUCKET_MS;
                h.update(std.mem.asBytes(&bucket));
            }
        }

        return h.final();
    }

    /// Called every painter tick; redraws only when the render signature changed.
    pub fn render(self: *HistoryPanelWindow, painter: *const painter_mod.Painter) !void {
        const display = &self.config.display;
        try self.panel.ensureFont("History Panel", display.notifInfoPanelFontName, display.notifInfoPanelFontSize, display.notifInfoPanelFontWeight);

        const signature = self.computeRenderSignature(painter);
        if (self.panel.isUnchanged(signature)) return;

        const win_w: i32 = @max(1, display.notifInfoPanelWidth);
        const win_h: i32 = @max(1, display.notifInfoPanelHeight);
        const bitmap = try self.panel.beginFrame(win_w, win_h);
        const width: usize = bitmap.width;
        const height: usize = bitmap.height;

        const show_filters = self.config.display.notifInfoPanelShowCategoryFilters;
        const footer_top: i32 = if (show_filters) @max(HEADER_HEIGHT, win_h - FOOTER_HEIGHT) else win_h;

        gdi_overlay.fillRect(bitmap.pixels, width, height, 0, 0, width, @intCast(HEADER_HEIGHT), color.withAlpha(RGB_HEADER, 0xFF));
        gdi_overlay.fillRect(bitmap.pixels, width, height, 0, @intCast(HEADER_HEIGHT), width, height - @as(usize, @intCast(HEADER_HEIGHT)), color.withAlpha(RGB_BODY, 0xFF));

        if (show_filters) {
            gdi_overlay.fillRect(bitmap.pixels, width, height, 0, @intCast(footer_top), width, @intCast(win_h - footer_top), color.withAlpha(RGB_HEADER, 0xFF));

            self.updateCategoryButtonRects(win_w);
            for (CATEGORY_ORDER, 0..) |category, i| {
                if (!categoryEnabled(self.config, category)) continue;
                const rect = self.category_button_rects[i];
                gdi_overlay.fillRect(bitmap.pixels, width, height, @intCast(rect.left), @intCast(footer_top), @intCast(rect.right - rect.left), @intCast(win_h - footer_top), color.withAlpha(RGB_BUTTON_ACTIVE_BG, 0xFF));
            }

            gdi_overlay.fillRect(bitmap.pixels, width, height, 0, @intCast(footer_top), width, 1, ARGB_SEPARATOR);
            for (1..CATEGORY_ORDER.len) |i| {
                const x: usize = @intCast(self.category_button_rects[i].left);
                gdi_overlay.fillRect(bitmap.pixels, width, height, x, @intCast(footer_top), 1, @intCast(win_h - footer_top), ARGB_SEPARATOR);
            }
        }

        const history_area_h: i32 = @max(0, footer_top - HEADER_HEIGHT);
        const history_rows_fit: usize = @intCast(@max(0, @divTrunc(history_area_h, ROW_HEIGHT)));
        const configured_max_rows: usize = @intCast(@max(1, self.config.display.notifInfoPanelMaxRows));
        const show_timestamp = self.config.display.notifInfoPanelShowTimestamp;
        const now = win32.Ticks.now();

        if (self.panel.font) |f| {
            const old = win32.SelectObject(bitmap.mem_dc, f);
            defer {
                if (old) |o| _ = win32.SelectObject(bitmap.mem_dc, o);
            }

            const header_text = "Notification History";
            const header_text_h = measureTextHeight(bitmap.mem_dc, header_text);
            const header_text_y = @max(0, @divTrunc(HEADER_HEIGHT - header_text_h, 2));
            drawText(bitmap.mem_dc, header_text, TEXT_LEFT, header_text_y, ARGB_HDR_TEXT);

            var entries: [history.CAPACITY]history.Entry = undefined;
            const hist = painter.notification_history.snapshot(&entries);
            const cap = @min(history_rows_fit, configured_max_rows);

            const max_w: usize = @intCast(@max(0, win_w - TEXT_LEFT - RIGHT_MARGIN));
            const merge_enabled = self.config.display.notifInfoPanelMergeEnabled;
            const merge_window_ms: u64 = @as(u64, @intCast(@max(0, self.config.display.notifInfoPanelMergeWindowSec))) * 1000;
            var shown: usize = 0;
            for (hist, 0..) |*entry, i| {
                if (!effectiveCategoryEnabled(self.config, notification.notificationCategory(entry.notification_type))) continue;

                if (merge_enabled and shown > 0 and !entry.unmerged) {
                    const row = &self.history_rows[shown - 1];
                    const prev = &hist[row.last];
                    if (!prev.unmerged and prev.notification_type == entry.notification_type and
                        std.mem.eql(u8, prev.text(), entry.text()) and
                        prev.timestamp_ms.elapsedSince(entry.timestamp_ms) <= merge_window_ms)
                    {
                        row.count += 1;
                        row.last = i;
                        continue;
                    }
                }

                if (shown >= cap) break;
                self.history_rows[shown] = .{ .hwnd = entry.source_hwnd, .count = 1, .first = i, .last = i };
                shown += 1;
            }
            self.history_row_count = shown;

            for (self.history_rows[0..shown], 0..) |row, row_i| {
                const entry = &hist[row.first];
                const row_top = HEADER_HEIGHT + @as(i32, @intCast(row_i)) * ROW_HEIGHT;
                const char_color = (entry.character_color orelse ARGB_CHAR_NAME) & 0x00FF_FFFF;
                const text_color = self.resolveNotifTextColor(entry.notification_type);
                var ts_buf: [24]u8 = undefined;
                const timestamp = if (show_timestamp) formatRelativeTime(&ts_buf, now, entry.timestamp_ms) else null;
                if (row.count > 1) {
                    drawMergedRow(bitmap.mem_dc, entry.text(), row.count, TEXT_LEFT, row_top + 1, char_color, text_color, max_w, timestamp);
                } else {
                    drawHistoryRow(bitmap.mem_dc, entry.characterName(), entry.text(), TEXT_LEFT, row_top + 1, char_color, text_color, max_w, timestamp);
                }
            }

            if (shown == 0) {
                const empty_text = if (hist.len == 0) "No notifications yet" else "All notifications filtered";
                drawText(bitmap.mem_dc, empty_text, TEXT_LEFT, HEADER_HEIGHT + 2, ARGB_EMPTY_TEXT);
            }

            if (show_filters) {
                for (CATEGORY_ORDER, 0..) |category, i| {
                    const rect = self.category_button_rects[i];
                    const label = CATEGORY_LABELS[i];
                    const active = categoryEnabled(self.config, category);
                    const label_color = if (active) ARGB_BUTTON_ACTIVE_TEXT else ARGB_BUTTON_INACTIVE_TEXT;
                    const label_w = measureTextWidth(bitmap.mem_dc, label);
                    const cell_w: usize = @intCast(@max(0, rect.right - rect.left));
                    const label_x = rect.left + @as(i32, @intCast((cell_w -| label_w) / 2));
                    const label_h = measureTextHeight(bitmap.mem_dc, label);
                    const label_y = footer_top + @max(0, @divTrunc(FOOTER_HEIGHT - label_h, 2));
                    drawText(bitmap.mem_dc, label, label_x, label_y, label_color);
                }
            }
        }

        gdi_overlay.fillRect(bitmap.pixels, width, height, 0, @intCast(HEADER_HEIGHT - 1), width, 1, ARGB_SEPARATOR);

        {
            const frame_col = color.withAlpha(RGB_FRAME, 0xFF);
            gdi_overlay.fillRect(bitmap.pixels, width, height, 0, 0, width, 1, frame_col);
            gdi_overlay.fillRect(bitmap.pixels, width, height, 0, height - 1, width, 1, frame_col);
            gdi_overlay.fillRect(bitmap.pixels, width, height, 0, 0, 1, height, frame_col);
            gdi_overlay.fillRect(bitmap.pixels, width, height, width - 1, 0, 1, height, frame_col);
        }

        gdi_overlay.fixTextAlpha(bitmap.pixels, width, height);
        self.panel.present(display.notifInfoPanelOpacity, signature);
    }
};

var g_class_registered: bool = false;

fn categoryEnabled(cfg: *const config_mod.Config, category: notification.NotificationCategory) bool {
    return switch (category) {
        .Fleet => cfg.display.notifInfoPanelShowFleet,
        .Mining => cfg.display.notifInfoPanelShowMining,
        .Combat => cfg.display.notifInfoPanelShowCombat,
        .Navigation => cfg.display.notifInfoPanelShowNavigation,
        .General => cfg.display.notifInfoPanelShowGeneral,
    };
}

fn setCategoryEnabled(store: *config_mod.ProfileStore, category: notification.NotificationCategory, value: bool) void {
    switch (category) {
        .Fleet => store.update(.{ .display = .{ .notifInfoPanelShowFleet = value } }),
        .Mining => store.update(.{ .display = .{ .notifInfoPanelShowMining = value } }),
        .Combat => store.update(.{ .display = .{ .notifInfoPanelShowCombat = value } }),
        .Navigation => store.update(.{ .display = .{ .notifInfoPanelShowNavigation = value } }),
        .General => store.update(.{ .display = .{ .notifInfoPanelShowGeneral = value } }),
    }
}

/// With the filter buttons hidden (notifInfoPanelShowCategoryFilters off), notifications aren't silently dropped by a filter state the user can't see or change - everything shows.
fn effectiveCategoryEnabled(cfg: *const config_mod.Config, category: notification.NotificationCategory) bool {
    if (!cfg.display.notifInfoPanelShowCategoryFilters) return true;
    return categoryEnabled(cfg, category);
}

/// Formats how long ago `entry_ts` was relative to `now` as e.g. "just now", "5m ago", "2h ago".
fn formatRelativeTime(buf: *[24]u8, now: win32.Ticks, entry_ts: win32.Ticks) []const u8 {
    const elapsed_s = now.elapsedSince(entry_ts) / 1000;
    if (elapsed_s < 60) return "just now";
    if (elapsed_s < 3600) {
        return std.fmt.bufPrint(buf, "{d}m ago", .{elapsed_s / 60}) catch "?m ago";
    }
    return std.fmt.bufPrint(buf, "{d}h ago", .{elapsed_s / 3600}) catch "?h ago";
}

fn drawTimestampSuffix(dc: win32.HDC, x: i32, y: i32, max_w: usize, timestamp: ?[]const u8) usize {
    const ts = timestamp orelse return max_w;
    const ts_w = @min(measureTextWidth(dc, ts), max_w);
    const gap_w = measureTextWidth(dc, " ");
    drawText(dc, ts, x + @as(i32, @intCast(max_w - ts_w)), y, ARGB_TIMESTAMP);
    return max_w -| (ts_w + gap_w);
}

fn drawMergedRow(dc: win32.HDC, msg: []const u8, count: usize, x: i32, y: i32, count_color: u32, msg_color: u32, max_w: usize, timestamp: ?[]const u8) void {
    const remaining = drawTimestampSuffix(dc, x, y, max_w, timestamp);

    var count_buf: [16]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "+{d}", .{count}) catch unreachable;
    const sep = ": ";
    const count_w = measureTextWidth(dc, count_text);
    const prefix_w = count_w + measureTextWidth(dc, sep);
    if (prefix_w > remaining) {
        drawTextTruncated(dc, count_text, x, y, count_color, remaining);
        return;
    }
    drawText(dc, count_text, x, y, count_color);
    drawText(dc, sep, x + @as(i32, @intCast(count_w)), y, msg_color);

    const msg_max = remaining - prefix_w;
    if (msg_max == 0) return;
    const msg_x = x + @as(i32, @intCast(prefix_w));
    if (measureTextWidth(dc, msg) <= msg_max) {
        drawText(dc, msg, msg_x, y, msg_color);
    } else {
        drawTextTruncated(dc, msg, msg_x, y, msg_color, msg_max);
    }
}

/// Draws "CharacterName: message" (name/message truncated to make room) followed by a right-aligned "timestamp" suffix, which is never dropped, even if it's all that fits.
fn drawHistoryRow(dc: win32.HDC, name: []const u8, msg: []const u8, x: i32, y: i32, name_color: u32, msg_color: u32, max_w: usize, timestamp: ?[]const u8) void {
    const remaining = drawTimestampSuffix(dc, x, y, max_w, timestamp);

    const name_w = measureTextWidth(dc, name);
    if (name_w > remaining) {
        drawTextTruncated(dc, name, x, y, name_color, remaining);
        return;
    }
    drawText(dc, name, x, y, name_color);

    const remaining_after_name = remaining -| name_w;
    if (remaining_after_name == 0) return;

    const sep = ": ";
    const sep_w = measureTextWidth(dc, sep);
    if (sep_w > remaining_after_name) return;
    drawText(dc, sep, x + @as(i32, @intCast(name_w)), y, msg_color);

    const remaining_for_msg = remaining_after_name - sep_w;
    if (remaining_for_msg == 0) return;
    const msg_x = x + @as(i32, @intCast(name_w + sep_w));

    const msg_w = measureTextWidth(dc, msg);
    if (msg_w <= remaining_for_msg) {
        drawText(dc, msg, msg_x, y, msg_color);
    } else {
        drawTextTruncated(dc, msg, msg_x, y, msg_color, remaining_for_msg);
    }
}

fn registerWindowClass(instance: win32.HINSTANCE) !void {
    if (g_class_registered) return;

    try gdi_overlay.registerWindowClass(instance, historyPanelWindowProc, HISTORY_PANEL_WINDOW_CLASS, null);

    g_class_registered = true;
}

fn historyPanelWindowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    if (drag_panel.handleMessage(hwnd, msg, lParam, HEADER_HEIGHT)) |result| return result;
    switch (msg) {
        win32.WM_ENTERSIZEMOVE => {
            drag_panel.beginPanelDrag(hwnd);
            // No single character owns this panel, so every saved position shows as a ghost.
            if (painter_mod.g_painter_ptr) |painter| painter.ghost_overlay.show(painter, "");
            return 0;
        },
        win32.WM_EXITSIZEMOVE => {
            const painter = painter_mod.g_painter_ptr orelse return 0;
            painter.ghost_overlay.hide();
            if (painter.history_panel.window) |*window| window.saveWindowPosition();
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            const cy = win32.lparamY(lParam);
            if (cy < HEADER_HEIGHT) return 0;

            const painter = painter_mod.g_painter_ptr orelse return 0;
            const window = if (painter.history_panel.window) |*w| w else return 0;
            const show_filters = window.config.display.notifInfoPanelShowCategoryFilters;
            const footer_top = if (show_filters) window.panel.height - FOOTER_HEIGHT else window.panel.height;
            if (show_filters and cy >= footer_top) {
                window.handleFooterClick(win32.lparamX(lParam));
                return 0;
            }

            const row: usize = @intCast(@divTrunc(cy - HEADER_HEIGHT, ROW_HEIGHT));
            if (row >= window.history_row_count) return 0;
            const hist_row = window.history_rows[row];
            if (hist_row.count > 1) {
                painter.notification_history.unmergeRange(hist_row.first, hist_row.last);
            } else {
                activation.activate(hist_row.hwnd);
            }
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}

fn toBufZ(text: []const u8) [TEXT_BUF:0]u8 {
    return gdi_overlay.toBufZ(TEXT_BUF, text);
}

fn drawText(dc: win32.HDC, text: []const u8, x: i32, y: i32, rgb: u32) void {
    _ = win32.SetBkMode(dc, win32.TRANSPARENT);
    const buf = toBufZ(text);
    const n = @min(text.len, TEXT_BUF - 1);

    _ = win32.SetTextColor(dc, gdi_overlay.toColorRef(rgb & 0x00FF_FFFF));
    _ = win32.TextOutA(dc, x, y, &buf, @intCast(n));
}

fn measureTextWidth(dc: win32.HDC, text: []const u8) usize {
    return gdi_overlay.measureTextWidth(TEXT_BUF, dc, text);
}

fn measureTextHeight(dc: win32.HDC, text: []const u8) i32 {
    const buf = toBufZ(text);
    const n = @min(text.len, TEXT_BUF - 1);
    var sz: win32.SIZE = undefined;
    _ = win32.GetTextExtentPoint32A(dc, &buf, @intCast(n), &sz);
    return @max(0, sz.cy);
}

fn drawTextTruncated(dc: win32.HDC, text: []const u8, x: i32, y: i32, rgb: u32, max_w: usize) void {
    var out: [TEXT_BUF:0]u8 = undefined;
    const truncated = gdi_overlay.truncateTextToFit(TEXT_BUF, dc, &out, text, max_w);
    drawText(dc, truncated, x, y, rgb);
}
