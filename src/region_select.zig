const std = @import("std");
const win32 = @import("win32.zig");
const gdi_overlay = @import("gdi_overlay.zig");
const protocol = @import("protocol.zig");
const log = @import("log.zig");
const slog = log.scoped("region_select");

const WINDOW_CLASS_NAME = "EVE_REGION_SELECT_CLASS";
const REDRAW_THROTTLE_MS: u64 = 16;
const BORDER_THICKNESS: usize = 2;
/// Below this, a drag is treated as an accidental click; distinct from DisplayConfig.REGION_WIDTH/HEIGHT_MIN, the saved-value minimum.
const MIN_DRAG_PX: i32 = 10;

const DIM_COLOR: u32 = 0x60000000;
const CLEAR_COLOR: u32 = 0x00000000;
const DEFAULT_BORDER_COLOR: u32 = 0xFF3399FF;

var g_window_class_registered = false;
var g_border_color: u32 = DEFAULT_BORDER_COLOR;
var g_active = false;
var g_dragging = false;
var g_hwnd: ?win32.HWND = null;
var g_bitmap: ?gdi_overlay.OverlayBitmap = null;
var g_virtual_screen: win32.RECT = undefined;
var g_anchor: win32.POINT = undefined;
var g_current: win32.POINT = undefined;
var g_last_redraw: win32.Ticks = undefined;
var g_cross_cursor: ?win32.HCURSOR = null;

pub fn registerWindowClass(instance: win32.HINSTANCE) !void {
    if (g_window_class_registered) return;
    g_cross_cursor = win32.LoadCursorA(null, win32.IDC_CROSS);
    try gdi_overlay.registerWindowClass(instance, wndProc, WINDOW_CLASS_NAME, null);
    g_window_class_registered = true;
}

/// Starts (or resets, if already in progress) the drag-to-select overlay; publishes the result via
/// protocol.publishRegionSelectResult. accent_color is 0xAARRGGBB, forced fully opaque.
pub fn start(instance: win32.HINSTANCE, accent_color: u32) void {
    g_border_color = accent_color | 0xFF000000;

    const left: i32 = win32.GetSystemMetrics(win32.SM_XVIRTUALSCREEN);
    const top: i32 = win32.GetSystemMetrics(win32.SM_YVIRTUALSCREEN);
    const width: i32 = win32.GetSystemMetrics(win32.SM_CXVIRTUALSCREEN);
    const height: i32 = win32.GetSystemMetrics(win32.SM_CYVIRTUALSCREEN);
    g_virtual_screen = .{ .left = left, .top = top, .right = left + width, .bottom = top + height };
    g_dragging = false;

    if (g_hwnd) |hwnd| {
        _ = win32.SetWindowPos(hwnd, win32.HWND_TOPMOST, left, top, width, height, win32.SWP_NOACTIVATE);
    } else {
        g_hwnd = win32.CreateWindowExA(
            win32.WS_EX_LAYERED | win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW,
            WINDOW_CLASS_NAME,
            "",
            win32.WS_POPUP,
            left,
            top,
            width,
            height,
            null,
            null,
            instance,
            null,
        ) orelse {
            slog.err("Failed to create region-select overlay window", .{});
            return;
        };
    }

    const hwnd = g_hwnd.?;
    ensureBitmap(width, height);
    g_active = true;
    g_last_redraw = win32.Ticks.now();
    redraw();

    _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
    grabForegroundFocus(hwnd);
}

/// Plain SetForegroundWindow (input.zig's forceSetForegroundWindow) only works when the calling process just received user input, which isn't true here since StartRegionSelect arrives over WM_COPYDATA - Windows' foreground-lock would otherwise silently eat it, leaving Escape going nowhere.
fn grabForegroundFocus(hwnd: win32.HWND) void {
    const current_thread = win32.GetCurrentThreadId();
    var attached = false;
    var foreground_thread: win32.DWORD = 0;

    if (win32.GetForegroundWindow()) |foreground| {
        foreground_thread = win32.GetWindowThreadProcessId(foreground, null);
        if (foreground_thread != 0 and foreground_thread != current_thread) {
            attached = win32.AttachThreadInput(current_thread, foreground_thread, win32.TRUE) != 0;
        }
    }

    _ = win32.SetForegroundWindow(hwnd);
    _ = win32.BringWindowToTop(hwnd);
    _ = win32.SetFocus(hwnd);

    if (attached) {
        _ = win32.AttachThreadInput(current_thread, foreground_thread, win32.FALSE);
    }
}

fn ensureBitmap(width: i32, height: i32) void {
    const needs_new = if (g_bitmap) |b|
        b.width != @as(usize, @intCast(width)) or b.height != @as(usize, @intCast(height))
    else
        true;
    if (!needs_new) return;

    if (g_bitmap) |b| b.destroy();
    g_bitmap = null;

    const dc = win32.GetDC(null) orelse return;
    defer _ = win32.ReleaseDC(null, dc);
    g_bitmap = gdi_overlay.OverlayBitmap.create(dc, width, height) catch |err| {
        slog.err("Failed to allocate region-select overlay bitmap: {}", .{err});
        return;
    };
}

fn normalizedSelection() win32.RECT {
    var rect = win32.RECT{
        .left = @min(g_anchor.x, g_current.x),
        .top = @min(g_anchor.y, g_current.y),
        .right = @max(g_anchor.x, g_current.x),
        .bottom = @max(g_anchor.y, g_current.y),
    };
    rect.left = std.math.clamp(rect.left, g_virtual_screen.left, g_virtual_screen.right);
    rect.right = std.math.clamp(rect.right, g_virtual_screen.left, g_virtual_screen.right);
    rect.top = std.math.clamp(rect.top, g_virtual_screen.top, g_virtual_screen.bottom);
    rect.bottom = std.math.clamp(rect.bottom, g_virtual_screen.top, g_virtual_screen.bottom);
    return rect;
}

fn drawBorder(bmp: *const gdi_overlay.OverlayBitmap, x: usize, y: usize, w: usize, h: usize) void {
    const t = BORDER_THICKNESS;
    gdi_overlay.fillRect(bmp.pixels, bmp.width, x, y, w, @min(t, h), g_border_color);
    if (h > t) gdi_overlay.fillRect(bmp.pixels, bmp.width, x, y + h - t, w, t, g_border_color);
    gdi_overlay.fillRect(bmp.pixels, bmp.width, x, y, @min(t, w), h, g_border_color);
    if (w > t) gdi_overlay.fillRect(bmp.pixels, bmp.width, x + w - t, y, t, h, g_border_color);
}

fn redraw() void {
    const hwnd = g_hwnd orelse return;
    if (g_bitmap == null) return;
    const bmp = &g_bitmap.?;

    gdi_overlay.fillRect(bmp.pixels, bmp.width, 0, 0, bmp.width, bmp.height, DIM_COLOR);

    if (g_dragging) {
        const sel = normalizedSelection();
        const w = sel.right - sel.left;
        const h = sel.bottom - sel.top;
        if (w > 0 and h > 0) {
            const local_x: usize = @intCast(sel.left - g_virtual_screen.left);
            const local_y: usize = @intCast(sel.top - g_virtual_screen.top);
            const uw: usize = @intCast(w);
            const uh: usize = @intCast(h);
            gdi_overlay.fillRect(bmp.pixels, bmp.width, local_x, local_y, uw, uh, CLEAR_COLOR);
            drawBorder(bmp, local_x, local_y, uw, uh);
        }
    }

    const screen_dc = win32.GetDC(null) orelse return;
    defer _ = win32.ReleaseDC(null, screen_dc);
    const window_size = win32.SIZE{ .cx = @intCast(bmp.width), .cy = @intCast(bmp.height) };
    const source_pos = win32.POINT{ .x = 0, .y = 0 };
    var blend = win32.BLENDFUNCTION{
        .BlendOp = win32.AC_SRC_OVER,
        .BlendFlags = 0,
        .SourceConstantAlpha = 255,
        .AlphaFormat = win32.AC_SRC_ALPHA,
    };
    _ = win32.UpdateLayeredWindow(hwnd, screen_dc, null, @constCast(&window_size), bmp.mem_dc, @constCast(&source_pos), 0, &blend, win32.ULW_ALPHA);
}

fn maybeRedrawThrottled() void {
    const now = win32.Ticks.now();
    if (now.elapsedSince(g_last_redraw) < REDRAW_THROTTLE_MS) return;
    g_last_redraw = now;
    redraw();
}

fn finish(cancelled: bool) void {
    if (g_hwnd) |hwnd| _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
    g_active = false;
    g_dragging = false;

    if (cancelled) {
        protocol.publishRegionSelectResult(2, .{ .left = 0, .top = 0, .right = 0, .bottom = 0 });
        return;
    }

    const rect = normalizedSelection();
    if (rect.right - rect.left < MIN_DRAG_PX or rect.bottom - rect.top < MIN_DRAG_PX) {
        protocol.publishRegionSelectResult(2, .{ .left = 0, .top = 0, .right = 0, .bottom = 0 });
        return;
    }
    protocol.publishRegionSelectResult(1, rect);
}

fn wndProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_SETCURSOR => {
            // Explicit crosshair so it's obvious the whole screen is draggable, not just click-through like the ghost/hint overlays.
            _ = win32.SetCursor(g_cross_cursor);
            return 1;
        },
        win32.WM_LBUTTONDOWN => {
            var pt: win32.POINT = undefined;
            _ = win32.GetCursorPos(&pt);
            g_anchor = pt;
            g_current = pt;
            g_dragging = true;
            _ = win32.SetCapture(hwnd);
            redraw();
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            if (!g_dragging) return 0;
            var pt: win32.POINT = undefined;
            _ = win32.GetCursorPos(&pt);
            g_current = pt;
            maybeRedrawThrottled();
            return 0;
        },
        win32.WM_LBUTTONUP => {
            if (!g_dragging) return 0;
            _ = win32.ReleaseCapture();
            finish(false);
            return 0;
        },
        win32.WM_KEYDOWN => {
            if (wParam == win32.VK_ESCAPE) {
                if (g_dragging) _ = win32.ReleaseCapture();
                finish(true);
            }
            return 0;
        },
        win32.WM_CAPTURECHANGED => {
            // Capture stolen by something else mid-drag (e.g. alt-tab): treat as a cancel so the overlay never gets stuck.
            if (g_dragging) finish(true);
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}
