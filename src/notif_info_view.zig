const std = @import("std");
const win32 = @import("win32.zig");
const config_mod = @import("config.zig");
const types = @import("types.zig");
const gdi_overlay = @import("gdi_overlay.zig");
const log = @import("log.zig");
const slog = log.scoped("notif_info_view");

// Only used by const-pointer params so the painter ↔ notif_info_view import cycle stays invisible at struct-size level; mirrors list_view.zig's own ThumbnailWindow re-import.
const painter_mod = @import("painter.zig");

const HEADER_HEIGHT: i32 = 18;
const ROW_HEIGHT: i32 = 16;
const INFO_LABEL_HEIGHT: i32 = 14;
const TEXT_LEFT: i32 = 6;
const RIGHT_MARGIN: i32 = 6;
const TEXT_BUF: usize = 160;

const RGB_HEADER: u32 = 0x001A1A1A;
const RGB_BODY: u32 = 0x000F0F0F;
const RGB_INFO_BG: u32 = 0x00151515;
const ARGB_SEPARATOR: u32 = 0xFF888888;
const ARGB_HDR_TEXT: u32 = 0xFFFFFFFF;
const ARGB_CHAR_NAME: u32 = 0xFFCCCCCC;
const ARGB_NOTIF_TEXT: u32 = 0xFFFFAA00;
const ARGB_EMPTY_TEXT: u32 = 0xFF666666;
const RGB_FRAME: u32 = 0x00888888;

const HTCAPTION: win32.LRESULT = 2;
const HTCLIENT: win32.LRESULT = 1;

var g_class_registered: bool = false;

var g_drag_anchor_cursor: win32.POINT = .{ .x = 0, .y = 0 };
var g_drag_anchor_rect: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

/// Set by Painter.init() so the window proc can activate EVE clients without a direct notif_info_view → input circular dependency.
pub var g_activate_fn: ?*const fn (win32.HWND) void = null;

const NOTIF_INFO_WINDOW_CLASS = "EVE_NOTIFINFO_CLASS";

fn formatIskAbbrev(buf: []u8, value: f64) []const u8 {
    const abs_value = @abs(value);
    if (abs_value >= 1_000_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.2}b isk", .{value / 1_000_000_000.0}) catch "?";
    } else if (abs_value >= 1_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.1}m isk", .{value / 1_000_000.0}) catch "?";
    } else if (abs_value >= 1_000.0) {
        return std.fmt.bufPrint(buf, "{d:.0}k isk", .{value / 1_000.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.0} isk", .{value}) catch "?";
    }
}

fn formatM3Abbrev(buf: []u8, value: f64) []const u8 {
    const abs_value = @abs(value);
    if (abs_value >= 1_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.1}m m3", .{value / 1_000_000.0}) catch "?";
    } else if (abs_value >= 1_000.0) {
        return std.fmt.bufPrint(buf, "{d:.1}k m3", .{value / 1_000.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.0} m3", .{value}) catch "?";
    }
}

pub const NotifInfoWindow = struct {
    hwnd: win32.HWND,
    instance: win32.HINSTANCE,
    allocator: std.mem.Allocator,
    config: *config_mod.Config,
    font: ?win32.HFONT = null,
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

    pub fn init(
        allocator: std.mem.Allocator,
        cfg: *config_mod.Config,
        instance: win32.HINSTANCE,
    ) !NotifInfoWindow {
        try registerClass(instance);

        const hwnd = win32.CreateWindowExA(
            win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW |
                win32.WS_EX_NOACTIVATE | win32.WS_EX_LAYERED,
            NOTIF_INFO_WINDOW_CLASS,
            "EVE Notifications & Info",
            win32.WS_POPUP,
            cfg.display.notifInfoPanelX,
            cfg.display.notifInfoPanelY,
            cfg.thumbnail.width,
            cfg.thumbnail.height * 2,
            null,
            null,
            instance,
            null,
        ) orelse return error.CreateWindowFailed;
        errdefer _ = win32.DestroyWindow(hwnd);

        const font_name_z = try allocator.dupeZ(u8, cfg.thumbnail.textFontName);
        defer allocator.free(font_name_z);

        const font = win32.CreateFontA(
            -cfg.thumbnail.textFontSize,
            0,
            0,
            0,
            cfg.thumbnail.textFontWeight.toWin32Weight(),
            if (cfg.thumbnail.textFontWeight.isItalic()) 1 else 0,
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
            .cached_font_name = cfg.thumbnail.textFontName,
            .cached_font_size = cfg.thumbnail.textFontSize,
            .cached_font_weight = cfg.thumbnail.textFontWeight,
        };
    }

    pub fn deinit(self: *NotifInfoWindow) void {
        if (self.overlay) |o| o.destroy();
        if (self.font) |f| _ = win32.DeleteObject(f);
        _ = win32.DestroyWindow(self.hwnd);
    }

    /// Recreates `font` if the thumbnail overlay text font settings changed since last built; mirrors list_view.zig's ensureFont, but tracks thumbnail.textFont* (the overlay text styling) rather than List View's own font settings.
    fn ensureFont(self: *NotifInfoWindow) void {
        const cfg = self.config.thumbnail;
        const unchanged = self.font != null and
            std.mem.eql(u8, self.cached_font_name, cfg.textFontName) and
            self.cached_font_size == cfg.textFontSize and
            self.cached_font_weight == cfg.textFontWeight;
        if (unchanged) return;

        if (self.font) |old| _ = win32.DeleteObject(old);
        self.font = null;

        const font_name_z = self.allocator.dupeZ(u8, cfg.textFontName) catch |err| {
            slog.err("Failed to allocate notif/info panel font name: {}", .{err});
            return;
        };
        defer self.allocator.free(font_name_z);

        self.font = win32.CreateFontA(
            -cfg.textFontSize,
            0,
            0,
            0,
            cfg.textFontWeight.toWin32Weight(),
            if (cfg.textFontWeight.isItalic()) 1 else 0,
            0,
            0,
            win32.DEFAULT_CHARSET,
            win32.OUT_DEFAULT_PRECIS,
            win32.CLIP_DEFAULT_PRECIS,
            win32.CLEARTYPE_QUALITY,
            win32.DEFAULT_PITCH,
            font_name_z,
        );
        self.cached_font_name = cfg.textFontName;
        self.cached_font_size = cfg.textFontSize;
        self.cached_font_weight = cfg.textFontWeight;
    }

    fn saveWindowPosition(self: *NotifInfoWindow) void {
        var rect: win32.RECT = undefined;
        _ = win32.GetWindowRect(self.hwnd, &rect);

        const pos = config_mod.Position{
            .x = rect.left,
            .y = rect.top,
        };

        self.config.saveNotifInfoPanelPosition(self.allocator, pos) catch |err| {
            slog.err("Failed to save notification/info panel position: {}", .{err});
        };
    }

    /// Whether the Bounty/Mining totals rows should be drawn this render: gated on the setting being enabled AND the total being nonzero, so an idle character doesn't leave a permanent "0" row.
    fn infoRowsShown(self: *const NotifInfoWindow, painter: *const painter_mod.Painter) struct { bounty: bool, mining: bool } {
        return .{
            .bounty = self.config.bounty.enabled and painter.total_bounty_isk != 0,
            .mining = self.config.mining.enabled and (painter.total_mining_m3 != 0 or painter.total_mining_isk != 0),
        };
    }

    fn computeRenderSignature(self: *const NotifInfoWindow, painter: *const painter_mod.Painter) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.config.thumbnail.width));
        h.update(std.mem.asBytes(&self.config.thumbnail.height));
        h.update(self.config.thumbnail.textFontName);
        h.update(std.mem.asBytes(&self.config.thumbnail.textFontSize));
        h.update(std.mem.asBytes(&self.config.thumbnail.textFontWeight));
        h.update(std.mem.asBytes(&self.config.bounty.enabled));
        h.update(std.mem.asBytes(&self.config.bounty.color));
        h.update(std.mem.asBytes(&self.config.mining.enabled));
        h.update(std.mem.asBytes(&self.config.mining.color));
        h.update(std.mem.asBytes(&self.config.mining.show_isk_rate));
        h.update(std.mem.asBytes(&painter.total_bounty_isk));
        h.update(std.mem.asBytes(&painter.total_mining_m3));
        h.update(std.mem.asBytes(&painter.total_mining_isk));
        h.update(std.mem.asBytes(&painter.notification_history_count));
        h.update(std.mem.asBytes(&painter.notification_history_head));

        var entries: [painter_mod.NOTIF_HISTORY_CAPACITY]painter_mod.NotificationHistoryEntry = undefined;
        const hist = painter.getNotificationHistory(&entries);
        for (hist) |*e| {
            h.update(e.characterName());
            h.update(e.text());
        }

        return h.final();
    }

    /// Re-render the panel from the painter's live notification history + activity totals; called every painter update tick and skips the GDI redraw when the render signature matches the previous tick's.
    pub fn render(self: *NotifInfoWindow, painter: *const painter_mod.Painter) !void {
        self.ensureFont();

        const signature = self.computeRenderSignature(painter);
        if (self.overlay != null and self.last_render_signature != null and self.last_render_signature.? == signature) {
            _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNOACTIVATE);
            return;
        }

        const win_w: i32 = @max(1, self.config.thumbnail.width);
        const win_h: i32 = @max(1, self.config.thumbnail.height * 2);

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
            const sdc = win32.GetDC(null) orelse return error.GetDCFailed;
            defer _ = win32.ReleaseDC(null, sdc);
            self.overlay = try gdi_overlay.OverlayBitmap.create(sdc, win_w, win_h);
        }

        const ov = &self.overlay.?;
        const W: usize = @intCast(win_w);
        const H: usize = @intCast(win_h);

        @memset(ov.pixels[0 .. W * H], 0);

        fillRect(ov.pixels, W, 0, 0, W, @intCast(HEADER_HEIGHT), self.withAlpha(RGB_HEADER));
        fillRect(ov.pixels, W, 0, @intCast(HEADER_HEIGHT), W, H - @as(usize, @intCast(HEADER_HEIGHT)), self.withAlpha(RGB_BODY));

        const shown_rows = self.infoRowsShown(painter);
        var info_rows: i32 = 0;
        if (shown_rows.bounty) info_rows += 1;
        if (shown_rows.mining) info_rows += 1;
        // BOX_PADDING covers the border box's own top/bottom border lines plus a little breathing room around the "Fleet Totals" label and rows.
        const BOX_PADDING: i32 = 6;
        const info_height: i32 = if (info_rows > 0) BOX_PADDING + INFO_LABEL_HEIGHT + info_rows * ROW_HEIGHT + BOX_PADDING else 0;
        const history_area_h: i32 = @max(0, win_h - HEADER_HEIGHT - info_height);
        const history_rows_fit: usize = @intCast(@max(0, @divTrunc(history_area_h, ROW_HEIGHT)));

        if (self.font) |f| {
            const old = win32.SelectObject(ov.mem_dc, f);
            defer {
                if (old) |o| _ = win32.SelectObject(ov.mem_dc, o);
            }

            drawText(ov.mem_dc, "Notifications", TEXT_LEFT, 3, ARGB_HDR_TEXT);

            var entries: [painter_mod.NOTIF_HISTORY_CAPACITY]painter_mod.NotificationHistoryEntry = undefined;
            const hist = painter.getNotificationHistory(&entries);
            const shown = @min(hist.len, history_rows_fit);
            self.history_row_count = shown;

            if (shown == 0) {
                drawText(ov.mem_dc, "No notifications yet", TEXT_LEFT, HEADER_HEIGHT + 2, ARGB_EMPTY_TEXT);
            }

            for (hist[0..shown], 0..) |*entry, i| {
                const row_top = HEADER_HEIGHT + @as(i32, @intCast(i)) * ROW_HEIGHT;
                self.history_row_hwnds[i] = entry.source_hwnd;

                var line_buf: [TEXT_BUF]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "{s}: {s}", .{ entry.characterName(), entry.text() }) catch entry.text();

                const max_w: usize = @intCast(@max(0, win_w - TEXT_LEFT - RIGHT_MARGIN));
                const name_w = measureTextWidth(ov.mem_dc, line);
                if (name_w <= max_w) {
                    drawText(ov.mem_dc, line, TEXT_LEFT, row_top + 1, ARGB_NOTIF_TEXT);
                } else {
                    drawTextTruncated(ov.mem_dc, line, TEXT_LEFT, row_top + 1, ARGB_NOTIF_TEXT, max_w);
                }
            }

            if (info_rows > 0) {
                const info_top: i32 = win_h - info_height;
                const box_l: usize = 2;
                const box_r: usize = W - 2;
                const box_t: usize = @intCast(info_top);
                const box_b: usize = H - 2;
                const box_w = box_r - box_l;
                const box_h = box_b - box_t;
                const frame_col = self.withAlpha(RGB_FRAME);

                fillRect(ov.pixels, W, box_l, box_t, box_w, box_h, self.withAlpha(RGB_INFO_BG));
                fillRect(ov.pixels, W, box_l, box_t, box_w, 1, frame_col);
                fillRect(ov.pixels, W, box_l, box_b - 1, box_w, 1, frame_col);
                fillRect(ov.pixels, W, box_l, box_t, 1, box_h, frame_col);
                fillRect(ov.pixels, W, box_r - 1, box_t, 1, box_h, frame_col);

                drawText(ov.mem_dc, "Fleet Totals", TEXT_LEFT, info_top + 3, ARGB_HDR_TEXT);

                var row_i: i32 = 0;
                var val_buf: [32]u8 = undefined;

                if (shown_rows.bounty) {
                    const y = info_top + BOX_PADDING + INFO_LABEL_HEIGHT + row_i * ROW_HEIGHT;
                    const val = formatIskAbbrev(&val_buf, painter.total_bounty_isk);
                    drawKeyValue(ov.mem_dc, "Bounty", val, TEXT_LEFT, y, win_w - RIGHT_MARGIN, self.config.bounty.color & 0xFFFFFF);
                    row_i += 1;
                }

                if (shown_rows.mining) {
                    const y = info_top + BOX_PADDING + INFO_LABEL_HEIGHT + row_i * ROW_HEIGHT;
                    var m3_buf: [32]u8 = undefined;
                    var isk_buf: [32]u8 = undefined;
                    const m3_str = formatM3Abbrev(&m3_buf, painter.total_mining_m3);
                    const val = if (self.config.mining.show_isk_rate)
                        std.fmt.bufPrint(&val_buf, "{s} / {s}", .{ m3_str, formatIskAbbrev(&isk_buf, painter.total_mining_isk) }) catch m3_str
                    else
                        m3_str;
                    drawKeyValue(ov.mem_dc, "Mining", val, TEXT_LEFT, y, win_w - RIGHT_MARGIN, self.config.mining.color & 0xFFFFFF);
                    row_i += 1;
                }
            }
        }

        fillRect(ov.pixels, W, 0, @intCast(HEADER_HEIGHT - 1), W, 1, ARGB_SEPARATOR);

        {
            const frame_col = self.withAlpha(RGB_FRAME);
            fillRect(ov.pixels, W, 0, 0, W, 1, frame_col);
            fillRect(ov.pixels, W, 0, H - 1, W, 1, frame_col);
            fillRect(ov.pixels, W, 0, 0, 1, H, frame_col);
            fillRect(ov.pixels, W, W - 1, 0, 1, H, frame_col);
        }

        gdi_overlay.fixTextAlpha(ov.pixels, W, H);

        const sdc = win32.GetDC(null) orelse return error.GetDCFailed;
        defer _ = win32.ReleaseDC(null, sdc);

        const sz = win32.SIZE{ .cx = win_w, .cy = win_h };
        const pt = win32.POINT{ .x = 0, .y = 0 };
        var blend = win32.BLENDFUNCTION{
            .BlendOp = win32.AC_SRC_OVER,
            .BlendFlags = 0,
            .SourceConstantAlpha = self.config.display.listViewOpacity,
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
        const a: u32 = self.config.display.listViewOpacity;
        return (a << 24) | (rgb & 0x00FF_FFFF);
    }
};

fn drawKeyValue(dc: win32.HDC, key: []const u8, value: []const u8, left_x: i32, y: i32, right_x: i32, value_color: u32) void {
    drawText(dc, key, left_x, y, ARGB_CHAR_NAME);
    drawTextRight(dc, value, right_x, y, value_color);
}

fn registerClass(instance: win32.HINSTANCE) !void {
    if (g_class_registered) return;

    const cursor = win32.LoadCursorA(null, win32.IDC_ARROW);
    const wc = win32.WNDCLASSEXA{
        .cbSize = @sizeOf(win32.WNDCLASSEXA),
        .style = 0,
        .lpfnWndProc = notifInfoWindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = cursor,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = NOTIF_INFO_WINDOW_CLASS,
        .hIconSm = null,
    };

    if (win32.RegisterClassExA(&wc) == 0) {
        return error.RegisterClassFailed;
    }

    g_class_registered = true;
}

fn notifInfoWindowProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_NCHITTEST => {
            const sy: i32 = @as(i32, @intCast(@as(i16, @truncate(lParam >> 16))));

            var wr: win32.RECT = undefined;
            _ = win32.GetWindowRect(hwnd, &wr);
            const cy = sy - wr.top;

            const painter_ptr_mod = @import("painter.zig");
            const dragging_enabled = if (painter_ptr_mod.g_painter_ptr) |p| p.config.interaction.enableDragging else true;

            if (dragging_enabled and cy < HEADER_HEIGHT) return HTCAPTION;
            return HTCLIENT;
        },

        win32.WM_ENTERSIZEMOVE => {
            _ = win32.GetCursorPos(&g_drag_anchor_cursor);
            _ = win32.GetWindowRect(hwnd, &g_drag_anchor_rect);
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
            const painter_ptr_mod = @import("painter.zig");
            if (painter_ptr_mod.g_painter_ptr) |p| {
                if (p.notif_info_window) |*niw| {
                    niw.saveWindowPosition();
                }
            }
            return 0;
        },

        win32.WM_LBUTTONDOWN => {
            const cy: i32 = @as(i32, @intCast(@as(i16, @truncate(lParam >> 16))));
            if (cy < HEADER_HEIGHT) return 0;

            const row_i = @divTrunc(cy - HEADER_HEIGHT, ROW_HEIGHT);
            if (row_i < 0) return 0;
            const row: usize = @intCast(row_i);

            const painter_ptr_mod = @import("painter.zig");
            if (painter_ptr_mod.g_painter_ptr) |p| {
                if (p.notif_info_window) |*niw| {
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

fn fillRect(pixels: [*]u32, stride: usize, x: usize, y: usize, w: usize, h: usize, argb: u32) void {
    const end_y = y + h;
    const end_x = x + w;
    if (end_x > stride) return;
    var py = y;
    while (py < end_y) : (py += 1) {
        @memset(pixels[py * stride + x .. py * stride + end_x], argb);
    }
}

fn drawText(dc: win32.HDC, text: []const u8, x: i32, y: i32, rgb: u32) void {
    _ = win32.SetBkMode(dc, win32.TRANSPARENT);
    var buf: [TEXT_BUF:0]u8 = undefined;
    const n = @min(text.len, TEXT_BUF - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;

    _ = win32.SetTextColor(dc, gdi_overlay.toColorRef(rgb & 0x00FF_FFFF));
    _ = win32.TextOutA(dc, x, y, &buf, @intCast(n));
}

fn measureTextWidth(dc: win32.HDC, text: []const u8) usize {
    var buf: [TEXT_BUF:0]u8 = undefined;
    const n = @min(text.len, TEXT_BUF - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    var sz: win32.SIZE = undefined;
    _ = win32.GetTextExtentPoint32A(dc, &buf, @intCast(n), &sz);
    return @intCast(@max(0, sz.cx));
}

fn drawTextRight(dc: win32.HDC, text: []const u8, right_x: i32, y: i32, rgb: u32) void {
    const w = measureTextWidth(dc, text);
    drawText(dc, text, right_x - @as(i32, @intCast(w)), y, rgb);
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
