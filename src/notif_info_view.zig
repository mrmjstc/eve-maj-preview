const std = @import("std");
const win32 = @import("win32.zig");
const config_mod = @import("config.zig");
const types = @import("types.zig");
const gdi_overlay = @import("gdi_overlay.zig");
const color_mod = @import("color.zig");
const log = @import("log.zig");
const slog = log.scoped("notif_info_view");

// Only used by const-pointer params so the painter ↔ notif_info_view import cycle stays invisible at struct-size level; mirrors list_view.zig's own ThumbnailWindow re-import.
const painter_mod = @import("painter.zig");

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

// Granularity of the timestamp text baked into the render signature, so it doesn't redraw every scan tick.
const TIMESTAMP_BUCKET_MS: u64 = 15_000;

// Order and labels for the footer's category filter buttons; index-paired with each other and with NotifInfoWindow.category_button_rects.
const CATEGORY_ORDER = [_]types.NotificationCategory{ .Fleet, .Mining, .Combat, .Navigation, .General };
const CATEGORY_LABELS = [_][]const u8{ "FLT", "MIN", "CBT", "NAV", "GEN" };

const ButtonRect = struct { left: i32 = 0, right: i32 = 0 };

fn categoryEnabled(cfg: *const config_mod.Config, cat: types.NotificationCategory) bool {
    return switch (cat) {
        .Fleet => cfg.display.notifInfoPanelShowFleet,
        .Mining => cfg.display.notifInfoPanelShowMining,
        .Combat => cfg.display.notifInfoPanelShowCombat,
        .Navigation => cfg.display.notifInfoPanelShowNavigation,
        .General => cfg.display.notifInfoPanelShowGeneral,
    };
}

fn setCategoryEnabled(cfg: *config_mod.Config, cat: types.NotificationCategory, value: bool) void {
    switch (cat) {
        .Fleet => cfg.display.notifInfoPanelShowFleet = value,
        .Mining => cfg.display.notifInfoPanelShowMining = value,
        .Combat => cfg.display.notifInfoPanelShowCombat = value,
        .Navigation => cfg.display.notifInfoPanelShowNavigation = value,
        .General => cfg.display.notifInfoPanelShowGeneral = value,
    }
}

/// With the filter buttons hidden (notifInfoPanelShowCategoryFilters off), notifications aren't silently dropped by a filter state the user can't see or change - everything shows.
fn effectiveCategoryEnabled(cfg: *const config_mod.Config, cat: types.NotificationCategory) bool {
    if (!cfg.display.notifInfoPanelShowCategoryFilters) return true;
    return categoryEnabled(cfg, cat);
}

const HTCAPTION: win32.LRESULT = 2;
const HTCLIENT: win32.LRESULT = 1;

var g_class_registered: bool = false;

var g_drag_anchor_cursor: win32.POINT = .{ .x = 0, .y = 0 };
var g_drag_anchor_rect: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

/// Set by Painter.init() so the window proc can activate EVE clients without a direct notif_info_view → input circular dependency.
pub var g_activate_fn: ?*const fn (win32.HWND) void = null;

const NOTIF_INFO_WINDOW_CLASS = "EVE_NOTIFINFO_CLASS";

pub const NotifInfoWindow = struct {
    hwnd: win32.HWND,
    instance: win32.HINSTANCE,
    allocator: std.mem.Allocator,
    config: *config_mod.Config,
    font: ?win32.HFONT = null,
    // Owns a copy rather than aliasing config.display.notifInfoPanelFontName, which config frees/replaces on a genuine rename.
    cached_font_name: []const u8 = "",
    cached_font_size: i32 = 0,
    cached_font_weight: types.FontWeight = .Regular,
    overlay: ?gdi_overlay.OverlayBitmap = null,
    last_win_w: i32 = -1,
    last_win_h: i32 = -1,
    last_render_signature: ?u64 = null,
    // Row index -> source hwnd for the history rows actually drawn this render, consumed by WM_LBUTTONDOWN.
    history_row_hwnds: [painter_mod.NOTIF_HISTORY_CAPACITY]win32.HWND = undefined,
    history_row_count: usize = 0,
    // Index-paired with CATEGORY_ORDER; recomputed every render, consumed by WM_LBUTTONDOWN's footer hit-test.
    category_button_rects: [CATEGORY_ORDER.len]ButtonRect = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        cfg: *config_mod.Config,
        instance: win32.HINSTANCE,
    ) !NotifInfoWindow {
        try registerWindowClass(instance);

        const hwnd = win32.CreateWindowExA(
            win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW |
                win32.WS_EX_NOACTIVATE | win32.WS_EX_LAYERED,
            NOTIF_INFO_WINDOW_CLASS,
            "EVE Notification History",
            win32.WS_POPUP,
            cfg.display.notifInfoPanelX,
            cfg.display.notifInfoPanelY,
            cfg.display.notifInfoPanelWidth,
            cfg.display.notifInfoPanelHeight,
            null,
            null,
            instance,
            null,
        ) orelse return error.CreateWindowFailed;
        errdefer _ = win32.DestroyWindow(hwnd);

        const font_name_z = try allocator.dupeZ(u8, cfg.display.notifInfoPanelFontName);
        defer allocator.free(font_name_z);

        const cached_font_name = try allocator.dupe(u8, cfg.display.notifInfoPanelFontName);
        errdefer allocator.free(cached_font_name);

        const font = win32.CreateFontA(
            -cfg.display.notifInfoPanelFontSize,
            0,
            0,
            0,
            cfg.display.notifInfoPanelFontWeight.toWin32Weight(),
            if (cfg.display.notifInfoPanelFontWeight.isItalic()) 1 else 0,
            0,
            0,
            win32.DEFAULT_CHARSET,
            win32.OUT_DEFAULT_PRECIS,
            win32.CLIP_DEFAULT_PRECIS,
            win32.CLEARTYPE_QUALITY,
            win32.DEFAULT_PITCH,
            font_name_z,
        );

        return .{
            .hwnd = hwnd,
            .instance = instance,
            .allocator = allocator,
            .config = cfg,
            .font = font,
            .cached_font_name = cached_font_name,
            .cached_font_size = cfg.display.notifInfoPanelFontSize,
            .cached_font_weight = cfg.display.notifInfoPanelFontWeight,
        };
    }

    pub fn deinit(self: *NotifInfoWindow) void {
        if (self.overlay) |o| o.destroy();
        if (self.font) |f| _ = win32.DeleteObject(f);
        self.allocator.free(self.cached_font_name);
        _ = win32.DestroyWindow(self.hwnd);
    }

    pub fn hide(self: *NotifInfoWindow) void {
        _ = win32.ShowWindow(self.hwnd, win32.SW_HIDE);
    }

    /// Recreates `font` if the panel's own font settings changed since last built (e.g. a live-previewed edit); mirrors list_view.zig's ensureFont, but tracks display.notifInfoPanelFont* rather than List View's own font settings.
    fn ensureFont(self: *NotifInfoWindow) void {
        const cfg = self.config.display;
        gdi_overlay.ensureFont(
            self.allocator,
            "notification history panel",
            &self.font,
            &self.cached_font_name,
            &self.cached_font_size,
            &self.cached_font_weight,
            cfg.notifInfoPanelFontName,
            cfg.notifInfoPanelFontSize,
            cfg.notifInfoPanelFontWeight,
        );
    }

    fn saveWindowPosition(self: *NotifInfoWindow) void {
        if (!self.config.display.rememberNotifInfoPanelPosition) return;

        var rect: win32.RECT = undefined;
        _ = win32.GetWindowRect(self.hwnd, &rect);

        const pos = config_mod.Position{
            .x = rect.left,
            .y = rect.top,
        };

        self.config.saveNotifInfoPanelPosition(self.allocator, pos) catch |err| {
            slog.err("Failed to save notification history panel position: {}", .{err});
        };
    }

    /// Character-name color for a history row: per-character override, else the auto-generated unique color (if enabled), else the default label color.
    fn resolveCharColor(self: *const NotifInfoWindow, name: []const u8) u32 {
        return (self.config.getCharacterNameColor(name) orelse ARGB_CHAR_NAME) & 0x00FF_FFFF;
    }

    /// Notification text color for a history row: the notification type's configured color, else the thumbnail overlay's default text color.
    fn resolveNotifTextColor(self: *const NotifInfoWindow, ntype: types.NotificationType) u32 {
        const type_cfg = self.config.thumbnail.notifications.getTypeConfig(ntype);
        return (type_cfg.text_color orelse self.config.thumbnail.characterNameColor) & 0x00FF_FFFF;
    }

    fn updateCategoryButtonRects(self: *NotifInfoWindow, win_w: i32) void {
        const n: i64 = @intCast(CATEGORY_ORDER.len);
        for (0..CATEGORY_ORDER.len) |i| {
            const left: i32 = @intCast(@divTrunc(@as(i64, win_w) * @as(i64, @intCast(i)), n));
            const right: i32 = @intCast(@divTrunc(@as(i64, win_w) * @as(i64, @intCast(i + 1)), n));
            self.category_button_rects[i] = .{ .left = left, .right = right };
        }
    }

    fn handleFooterClick(self: *NotifInfoWindow, cx: i32) void {
        for (CATEGORY_ORDER, 0..) |cat, i| {
            const rect = self.category_button_rects[i];
            if (cx < rect.left or cx >= rect.right) continue;

            setCategoryEnabled(self.config, cat, !categoryEnabled(self.config, cat));
            self.config.saveNotifInfoPanelCategoryFilter(self.allocator) catch |err| {
                slog.err("Failed to save notification history panel category filter: {}", .{err});
            };
            self.last_render_signature = null;
            return;
        }
    }

    fn computeRenderSignature(self: *const NotifInfoWindow, painter: *const painter_mod.Painter) u64 {
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
        for (CATEGORY_ORDER) |cat| {
            const enabled = categoryEnabled(self.config, cat);
            h.update(std.mem.asBytes(&enabled));
        }
        h.update(std.mem.asBytes(&painter.notification_history_count));
        h.update(std.mem.asBytes(&painter.notification_history_head));

        const show_timestamp = self.config.display.notifInfoPanelShowTimestamp;
        const now = win32.Ticks.now();

        var entries: [painter_mod.NOTIF_HISTORY_CAPACITY]painter_mod.NotificationHistoryEntry = undefined;
        const hist = painter.getNotificationHistory(&entries);
        for (hist) |*e| {
            h.update(e.characterName());
            h.update(e.text());
            const char_color = self.resolveCharColor(e.characterName());
            const text_color = self.resolveNotifTextColor(e.notification_type);
            h.update(std.mem.asBytes(&char_color));
            h.update(std.mem.asBytes(&text_color));
            if (show_timestamp) {
                const bucket = now.elapsedSince(e.timestamp_ms) / TIMESTAMP_BUCKET_MS;
                h.update(std.mem.asBytes(&bucket));
            }
        }

        return h.final();
    }

    /// Re-render the panel from the painter's live notification history; called every painter update tick and skips the GDI redraw when the render signature matches the previous tick's.
    pub fn render(self: *NotifInfoWindow, painter: *const painter_mod.Painter) !void {
        self.ensureFont();

        const signature = self.computeRenderSignature(painter);
        if (self.overlay != null and self.last_render_signature != null and self.last_render_signature.? == signature) {
            _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNOACTIVATE);
            return;
        }

        const win_w: i32 = @max(1, self.config.display.notifInfoPanelWidth);
        const win_h: i32 = @max(1, self.config.display.notifInfoPanelHeight);

        if (win_w != self.last_win_w or win_h != self.last_win_h) {
            _ = win32.SetWindowPos(
                self.hwnd,
                win32.HWND_TOPMOST,
                0,
                0,
                win_w,
                win_h,
                win32.SWP_NOMOVE | win32.SWP_NOACTIVATE,
            );
            self.last_win_w = win_w;
            self.last_win_h = win_h;
        }

        const needs_bmp = if (self.overlay) |o|
            o.width != @as(usize, @intCast(win_w)) or
                o.height != @as(usize, @intCast(win_h))
        else
            true;

        if (needs_bmp) {
            if (self.overlay) |o| o.destroy();
            self.overlay = null;
            const sdc = win32.GetDC(null) orelse return error.GetDCFailed;
            defer _ = win32.ReleaseDC(null, sdc);
            self.overlay = try gdi_overlay.OverlayBitmap.create(sdc, win_w, win_h);
        }

        const ov = &self.overlay.?;
        const W: usize = @intCast(win_w);
        const H: usize = @intCast(win_h);

        @memset(ov.pixels[0 .. W * H], 0);

        const show_filters = self.config.display.notifInfoPanelShowCategoryFilters;
        const footer_top: i32 = if (show_filters) @max(HEADER_HEIGHT, win_h - FOOTER_HEIGHT) else win_h;

        gdi_overlay.fillRect(ov.pixels, W, 0, 0, W, @intCast(HEADER_HEIGHT), self.withAlpha(RGB_HEADER));
        gdi_overlay.fillRect(ov.pixels, W, 0, @intCast(HEADER_HEIGHT), W, H - @as(usize, @intCast(HEADER_HEIGHT)), self.withAlpha(RGB_BODY));

        if (show_filters) {
            gdi_overlay.fillRect(ov.pixels, W, 0, @intCast(footer_top), W, @intCast(win_h - footer_top), self.withAlpha(RGB_HEADER));

            self.updateCategoryButtonRects(win_w);
            for (CATEGORY_ORDER, 0..) |cat, i| {
                if (!categoryEnabled(self.config, cat)) continue;
                const rect = self.category_button_rects[i];
                gdi_overlay.fillRect(ov.pixels, W, @intCast(rect.left), @intCast(footer_top), @intCast(rect.right - rect.left), @intCast(win_h - footer_top), self.withAlpha(RGB_BUTTON_ACTIVE_BG));
            }

            gdi_overlay.fillRect(ov.pixels, W, 0, @intCast(footer_top), W, 1, ARGB_SEPARATOR);
            for (1..CATEGORY_ORDER.len) |i| {
                const x: usize = @intCast(self.category_button_rects[i].left);
                gdi_overlay.fillRect(ov.pixels, W, x, @intCast(footer_top), 1, @intCast(win_h - footer_top), ARGB_SEPARATOR);
            }
        }

        const history_area_h: i32 = @max(0, footer_top - HEADER_HEIGHT);
        const history_rows_fit: usize = @intCast(@max(0, @divTrunc(history_area_h, ROW_HEIGHT)));
        const configured_max_rows: usize = @intCast(@max(1, self.config.display.notifInfoPanelMaxRows));
        const show_timestamp = self.config.display.notifInfoPanelShowTimestamp;
        const now = win32.Ticks.now();

        if (self.font) |f| {
            const old = win32.SelectObject(ov.mem_dc, f);
            defer {
                if (old) |o| _ = win32.SelectObject(ov.mem_dc, o);
            }

            const header_text = "Notification History";
            const header_text_h = measureTextHeight(ov.mem_dc, header_text);
            const header_text_y = @max(0, @divTrunc(HEADER_HEIGHT - header_text_h, 2));
            drawText(ov.mem_dc, header_text, TEXT_LEFT, header_text_y, ARGB_HDR_TEXT);

            var entries: [painter_mod.NOTIF_HISTORY_CAPACITY]painter_mod.NotificationHistoryEntry = undefined;
            const hist = painter.getNotificationHistory(&entries);
            const cap = @min(history_rows_fit, configured_max_rows);

            const max_w: usize = @intCast(@max(0, win_w - TEXT_LEFT - RIGHT_MARGIN));
            var shown: usize = 0;
            for (hist) |*entry| {
                if (shown >= cap) break;
                if (!effectiveCategoryEnabled(self.config, types.notificationCategory(entry.notification_type))) continue;

                const row_top = HEADER_HEIGHT + @as(i32, @intCast(shown)) * ROW_HEIGHT;
                self.history_row_hwnds[shown] = entry.source_hwnd;

                const char_color = self.resolveCharColor(entry.characterName());
                const text_color = self.resolveNotifTextColor(entry.notification_type);
                var ts_buf: [24]u8 = undefined;
                const timestamp = if (show_timestamp) formatRelativeTime(&ts_buf, now, entry.timestamp_ms) else null;
                drawHistoryRow(ov.mem_dc, entry.characterName(), entry.text(), TEXT_LEFT, row_top + 1, char_color, text_color, max_w, timestamp);
                shown += 1;
            }
            self.history_row_count = shown;

            if (shown == 0) {
                const empty_text = if (hist.len == 0) "No notifications yet" else "All notifications filtered";
                drawText(ov.mem_dc, empty_text, TEXT_LEFT, HEADER_HEIGHT + 2, ARGB_EMPTY_TEXT);
            }

            if (show_filters) {
                for (CATEGORY_ORDER, 0..) |cat, i| {
                    const rect = self.category_button_rects[i];
                    const label = CATEGORY_LABELS[i];
                    const active = categoryEnabled(self.config, cat);
                    const label_color = if (active) ARGB_BUTTON_ACTIVE_TEXT else ARGB_BUTTON_INACTIVE_TEXT;
                    const label_w = measureTextWidth(ov.mem_dc, label);
                    const cell_w: usize = @intCast(@max(0, rect.right - rect.left));
                    const label_x = rect.left + @as(i32, @intCast((cell_w -| label_w) / 2));
                    const label_h = measureTextHeight(ov.mem_dc, label);
                    const label_y = footer_top + @max(0, @divTrunc(FOOTER_HEIGHT - label_h, 2));
                    drawText(ov.mem_dc, label, label_x, label_y, label_color);
                }
            }
        }

        gdi_overlay.fillRect(ov.pixels, W, 0, @intCast(HEADER_HEIGHT - 1), W, 1, ARGB_SEPARATOR);

        {
            const frame_col = self.withAlpha(RGB_FRAME);
            gdi_overlay.fillRect(ov.pixels, W, 0, 0, W, 1, frame_col);
            gdi_overlay.fillRect(ov.pixels, W, 0, H - 1, W, 1, frame_col);
            gdi_overlay.fillRect(ov.pixels, W, 0, 0, 1, H, frame_col);
            gdi_overlay.fillRect(ov.pixels, W, W - 1, 0, 1, H, frame_col);
        }

        gdi_overlay.fixTextAlpha(ov.pixels, W, H);

        const sdc = win32.GetDC(null) orelse return error.GetDCFailed;
        defer _ = win32.ReleaseDC(null, sdc);

        const sz = win32.SIZE{ .cx = win_w, .cy = win_h };
        const pt = win32.POINT{ .x = 0, .y = 0 };
        var blend = win32.BLENDFUNCTION{
            .BlendOp = win32.AC_SRC_OVER,
            .BlendFlags = 0,
            .SourceConstantAlpha = self.config.display.notifInfoPanelOpacity,
            .AlphaFormat = win32.AC_SRC_ALPHA,
        };

        _ = win32.UpdateLayeredWindow(
            self.hwnd,
            sdc,
            null,
            @constCast(&sz),
            ov.mem_dc,
            @constCast(&pt),
            0,
            &blend,
            win32.ULW_ALPHA,
        );

        _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNOACTIVATE);
        self.last_render_signature = signature;
    }

    fn withAlpha(self: *const NotifInfoWindow, rgb: u32) u32 {
        return color_mod.withAlpha(rgb, self.config.display.notifInfoPanelOpacity);
    }
};

/// Formats how long ago `entry_ts` was relative to `now` as e.g. "just now", "5m ago", "2h ago".
fn formatRelativeTime(buf: *[24]u8, now: win32.Ticks, entry_ts: win32.Ticks) []const u8 {
    const elapsed_s = now.elapsedSince(entry_ts) / 1000;
    if (elapsed_s < 60) return "just now";
    if (elapsed_s < 3600) {
        return std.fmt.bufPrint(buf, "{d}m ago", .{elapsed_s / 60}) catch "?m ago";
    }
    return std.fmt.bufPrint(buf, "{d}h ago", .{elapsed_s / 3600}) catch "?h ago";
}

/// Draws "CharacterName: message" (name/message truncated to make room) followed by a right-aligned "timestamp" suffix, which is never dropped, even if it's all that fits.
fn drawHistoryRow(dc: win32.HDC, name: []const u8, msg: []const u8, x: i32, y: i32, name_color: u32, msg_color: u32, max_w: usize, timestamp: ?[]const u8) void {
    var remaining = max_w;

    if (timestamp) |ts| {
        const ts_w = @min(measureTextWidth(dc, ts), max_w);
        const gap_w = measureTextWidth(dc, " ");
        remaining = max_w -| (ts_w + gap_w);
        drawText(dc, ts, x + @as(i32, @intCast(max_w - ts_w)), y, ARGB_TIMESTAMP);
    }

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

    try gdi_overlay.registerWindowClass(instance, notifInfoWindowProc, NOTIF_INFO_WINDOW_CLASS, null);

    g_class_registered = true;
}

fn hiwordSigned(lParam: win32.LPARAM) i32 {
    return @as(i32, @intCast(@as(i16, @truncate(lParam >> 16))));
}

fn lowordSigned(lParam: win32.LPARAM) i32 {
    return @as(i32, @intCast(@as(i16, @truncate(lParam))));
}

fn notifInfoWindowProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_NCHITTEST => {
            const sy: i32 = hiwordSigned(lParam);

            var wr: win32.RECT = undefined;
            _ = win32.GetWindowRect(hwnd, &wr);
            const cy = sy - wr.top;

            const dragging_enabled = if (painter_mod.g_painter_ptr) |p| p.config.interaction.enableDragging else true;

            if (dragging_enabled and cy < HEADER_HEIGHT) return HTCAPTION;
            return HTCLIENT;
        },

        win32.WM_ENTERSIZEMOVE => {
            _ = win32.GetCursorPos(&g_drag_anchor_cursor);
            _ = win32.GetWindowRect(hwnd, &g_drag_anchor_rect);

            if (painter_mod.g_painter_ptr) |p| {
                // No single character owns this panel, so nothing is excluded - every saved position shows as a ghost.
                p.showGhostOverlay("");
            }
            return 0;
        },

        win32.WM_MOVING => {
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @intCast(lParam)));
            const width = rect.right - rect.left;
            const height = rect.bottom - rect.top;

            var cursor: win32.POINT = undefined;
            _ = win32.GetCursorPos(&cursor);
            const intended_x = g_drag_anchor_rect.left + (cursor.x - g_drag_anchor_cursor.x);
            const intended_y = g_drag_anchor_rect.top + (cursor.y - g_drag_anchor_cursor.y);

            const input_mod = @import("input.zig");
            const snapped = input_mod.applySnapping(intended_x, intended_y, width, height, hwnd);

            rect.left = snapped.x;
            rect.top = snapped.y;
            rect.right = snapped.x + width;
            rect.bottom = snapped.y + height;
            return win32.TRUE;
        },

        win32.WM_EXITSIZEMOVE => {
            if (painter_mod.g_painter_ptr) |p| {
                p.hideGhostOverlay();
                if (p.notif_info_window) |*niw| {
                    niw.saveWindowPosition();
                }
            }
            return 0;
        },

        win32.WM_LBUTTONDOWN => {
            const cy: i32 = hiwordSigned(lParam);
            if (cy < HEADER_HEIGHT) return 0;

            if (painter_mod.g_painter_ptr) |p| {
                if (p.notif_info_window) |*niw| {
                    const show_filters = niw.config.display.notifInfoPanelShowCategoryFilters;
                    const footer_top = if (show_filters) niw.last_win_h - FOOTER_HEIGHT else niw.last_win_h;
                    if (show_filters and cy >= footer_top) {
                        const cx: i32 = lowordSigned(lParam);
                        niw.handleFooterClick(cx);
                        return 0;
                    }

                    const row_i = @divTrunc(cy - HEADER_HEIGHT, ROW_HEIGHT);
                    if (row_i < 0) return 0;
                    const row: usize = @intCast(row_i);

                    if (row < niw.history_row_count) {
                        if (g_activate_fn) |activate| {
                            activate(niw.history_row_hwnds[row]);
                        }
                    }
                }
            }
            return 0;
        },

        win32.WM_ERASEBKGND => return 1,

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
    var buf: [TEXT_BUF:0]u8 = undefined;
    const orig_n = @min(text.len, TEXT_BUF - 4);
    var lo: usize = 0;
    var hi: usize = orig_n;

    const ellipsis = "...";
    var ellipsis_w: win32.SIZE = undefined;
    _ = win32.GetTextExtentPoint32A(dc, ellipsis, 3, &ellipsis_w);
    const budget: i32 = @as(i32, @intCast(max_w)) - ellipsis_w.cx;
    if (budget <= 0) return;

    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        @memcpy(buf[0..mid], text[0..mid]);
        buf[mid] = 0;
        var sz: win32.SIZE = undefined;
        _ = win32.GetTextExtentPoint32A(dc, &buf, @intCast(mid), &sz);
        if (sz.cx <= budget) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }

    var out: [TEXT_BUF:0]u8 = undefined;
    @memcpy(out[0..lo], text[0..lo]);
    @memcpy(out[lo .. lo + 3], ellipsis);
    out[lo + 3] = 0;
    drawText(dc, out[0 .. lo + 3], x, y, rgb);
}
