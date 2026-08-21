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
const TEXT_LEFT: i32 = 6;
const RIGHT_MARGIN: i32 = 6;
const TEXT_BUF: usize = 160;

const RGB_HEADER: u32 = 0x001A1A1A;
const RGB_BODY: u32 = 0x000F0F0F;
const ARGB_SEPARATOR: u32 = 0xFF888888;
const ARGB_HDR_TEXT: u32 = 0xFFFFFFFF;
const ARGB_CHAR_NAME: u32 = 0xFFCCCCCC;
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
            .cached_font_name = cfg.display.notifInfoPanelFontName,
            .cached_font_size = cfg.display.notifInfoPanelFontSize,
            .cached_font_weight = cfg.display.notifInfoPanelFontWeight,
        };
    }

    pub fn deinit(self: *NotifInfoWindow) void {
        if (self.overlay) |o| o.destroy();
        if (self.font) |f| _ = win32.DeleteObject(f);
        _ = win32.DestroyWindow(self.hwnd);
    }

    /// Recreates `font` if the panel's own font settings changed since last built (e.g. a live-previewed edit); mirrors list_view.zig's ensureFont, but tracks display.notifInfoPanelFont* rather than List View's own font settings.
    fn ensureFont(self: *NotifInfoWindow) void {
        const cfg = self.config.display;
        const unchanged = self.font != null and
            std.mem.eql(u8, self.cached_font_name, cfg.notifInfoPanelFontName) and
            self.cached_font_size == cfg.notifInfoPanelFontSize and
            self.cached_font_weight == cfg.notifInfoPanelFontWeight;
        if (unchanged) return;

        if (self.font) |old| _ = win32.DeleteObject(old);
        self.font = null;

        const font_name_z = self.allocator.dupeZ(u8, cfg.notifInfoPanelFontName) catch |err| {
            slog.err("Failed to allocate notification history panel font name: {}", .{err});
            return;
        };
        defer self.allocator.free(font_name_z);

        self.font = win32.CreateFontA(
            -cfg.notifInfoPanelFontSize,
            0,
            0,
            0,
            cfg.notifInfoPanelFontWeight.toWin32Weight(),
            if (cfg.notifInfoPanelFontWeight.isItalic()) 1 else 0,
            0,
            0,
            win32.DEFAULT_CHARSET,
            win32.OUT_DEFAULT_PRECIS,
            win32.CLIP_DEFAULT_PRECIS,
            win32.CLEARTYPE_QUALITY,
            win32.DEFAULT_PITCH,
            font_name_z,
        );
        self.cached_font_name = cfg.notifInfoPanelFontName;
        self.cached_font_size = cfg.notifInfoPanelFontSize;
        self.cached_font_weight = cfg.notifInfoPanelFontWeight;
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
        return (self.config.getCharacterNameColor(name) orelse (ARGB_CHAR_NAME & 0x00FF_FFFF)) & 0x00FF_FFFF;
    }

    /// Notification text color for a history row: the notification type's configured color, else the thumbnail overlay's default text color.
    fn resolveNotifTextColor(self: *const NotifInfoWindow, ntype: types.NotificationType) u32 {
        const type_cfg = self.config.thumbnail.notifications.getTypeConfig(ntype);
        return (type_cfg.text_color orelse self.config.thumbnail.textColor) & 0x00FF_FFFF;
    }

    fn computeRenderSignature(self: *const NotifInfoWindow, painter: *const painter_mod.Painter) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelWidth));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelHeight));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelOpacity));
        h.update(self.config.display.notifInfoPanelFontName);
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelFontSize));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelFontWeight));
        h.update(std.mem.asBytes(&painter.notification_history_count));
        h.update(std.mem.asBytes(&painter.notification_history_head));

        var entries: [painter_mod.NOTIF_HISTORY_CAPACITY]painter_mod.NotificationHistoryEntry = undefined;
        const hist = painter.getNotificationHistory(&entries);
        for (hist) |*e| {
            h.update(e.characterName());
            h.update(e.text());
            const char_color = self.resolveCharColor(e.characterName());
            const text_color = self.resolveNotifTextColor(e.notification_type);
            h.update(std.mem.asBytes(&char_color));
            h.update(std.mem.asBytes(&text_color));
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

        const history_area_h: i32 = @max(0, win_h - HEADER_HEIGHT);
        const history_rows_fit: usize = @intCast(@max(0, @divTrunc(history_area_h, ROW_HEIGHT)));

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
            const shown = @min(hist.len, history_rows_fit);
            self.history_row_count = shown;

            if (shown == 0) {
                drawText(ov.mem_dc, "No notifications yet", TEXT_LEFT, HEADER_HEIGHT + 2, ARGB_EMPTY_TEXT);
            }

            const max_w: usize = @intCast(@max(0, win_w - TEXT_LEFT - RIGHT_MARGIN));
            for (hist[0..shown], 0..) |*entry, i| {
                const row_top = HEADER_HEIGHT + @as(i32, @intCast(i)) * ROW_HEIGHT;
                self.history_row_hwnds[i] = entry.source_hwnd;

                const char_color = self.resolveCharColor(entry.characterName());
                const text_color = self.resolveNotifTextColor(entry.notification_type);
                drawHistoryRow(ov.mem_dc, entry.characterName(), entry.text(), TEXT_LEFT, row_top + 1, char_color, text_color, max_w);
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
        const a: u32 = self.config.display.notifInfoPanelOpacity;
        return (a << 24) | (rgb & 0x00FF_FFFF);
    }
};

/// Draws "CharacterName: message" with the name and message independently colored, truncating the message (then the name, if needed) to fit max_w.
fn drawHistoryRow(dc: win32.HDC, name: []const u8, msg: []const u8, x: i32, y: i32, name_color: u32, msg_color: u32, max_w: usize) void {
    const name_w = measureTextWidth(dc, name);
    if (name_w > max_w) {
        drawTextTruncated(dc, name, x, y, name_color, max_w);
        return;
    }
    drawText(dc, name, x, y, name_color);

    const remaining_after_name = max_w -| name_w;
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

fn measureTextHeight(dc: win32.HDC, text: []const u8) i32 {
    var buf: [TEXT_BUF:0]u8 = undefined;
    const n = @min(text.len, TEXT_BUF - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
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
