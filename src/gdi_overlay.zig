const std = @import("std");
const win32 = @import("win32.zig");
const types = @import("types.zig");
const log = @import("log.zig");
const slog = log.scoped("gdi_overlay");

/// Top-down 32bpp DIB section selected into its own memory DC, for GDI text/shape rendering
/// into a pixel buffer that later becomes a layered window's alpha-blended source.
pub const OverlayBitmap = struct {
    mem_dc: win32.HDC,
    bitmap: win32.HBITMAP,
    pixels: [*]u32,
    width: usize,
    height: usize,
    old_bitmap: win32.HANDLE,

    pub fn create(screen_dc: win32.HDC, width: i32, height: i32) !OverlayBitmap {
        const mem_dc = win32.CreateCompatibleDC(screen_dc) orelse return error.CreateDCFailed;
        errdefer _ = win32.DeleteDC(mem_dc);

        var bmi = std.mem.zeroes(win32.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(win32.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = width;
        // Negative height selects top-down row order.
        bmi.bmiHeader.biHeight = -height;
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = win32.BI_RGB;

        var pixels: ?*anyopaque = null;
        const bitmap = win32.CreateDIBSection(mem_dc, &bmi, win32.DIB_RGB_COLORS, &pixels, null, 0) orelse return error.CreateBitmapFailed;
        errdefer _ = win32.DeleteObject(bitmap);

        const pixel_data: [*]u32 = @ptrCast(@alignCast(pixels.?));
        const old_bitmap = win32.SelectObject(mem_dc, bitmap) orelse return error.SelectObjectFailed;

        return .{
            .mem_dc = mem_dc,
            .bitmap = bitmap,
            .pixels = pixel_data,
            .width = @intCast(width),
            .height = @intCast(height),
            .old_bitmap = old_bitmap,
        };
    }

    pub fn destroy(self: OverlayBitmap) void {
        _ = win32.SelectObject(self.mem_dc, self.old_bitmap);
        _ = win32.DeleteObject(self.bitmap);
        _ = win32.DeleteDC(self.mem_dc);
    }

    pub fn needsResize(existing: ?OverlayBitmap, width: i32, height: i32) bool {
        const b = existing orelse return true;
        return b.width != @as(usize, @intCast(width)) or b.height != @as(usize, @intCast(height));
    }

    /// Destroys `slot.*` if present and replaces it with a fresh bitmap of the given size; `slot.*` is left null if creation fails.
    pub fn recreate(slot: *?OverlayBitmap, screen_dc: win32.HDC, width: i32, height: i32) !void {
        if (slot.*) |existing| existing.destroy();
        slot.* = null;
        slot.* = try create(screen_dc, width, height);
    }
};

/// Converts this app's 0xAARRGGBB color into a Win32 COLORREF (0x00BBGGRR) for GDI APIs; without this, SetTextColor swaps red and blue.
pub fn toColorRef(color: u32) u32 {
    const r = (color >> 16) & 0xFF;
    const g = (color >> 8) & 0xFF;
    const b = color & 0xFF;
    return (b << 16) | (g << 8) | r;
}

/// GDI text rendering leaves the alpha byte at 0; sets alpha=255 on every pixel with non-zero RGB still at alpha 0 within the given rect, without touching alpha other drawing code already set.
pub fn fixTextAlphaRect(pixels: [*]u32, width: usize, height: usize, x: i32, y: i32, w: usize, h: usize) void {
    const start_x: usize = @intCast(@max(0, x));
    const start_y: usize = @intCast(@max(0, y));
    const end_x = @min(start_x + w, width);
    const end_y = @min(start_y + h, height);
    if (end_x <= start_x or end_y <= start_y) return;

    for (start_y..end_y) |py| {
        const row = pixels[py * width + start_x .. py * width + end_x];
        for (row) |*p| {
            const v = p.*;
            if ((v >> 24) == 0 and (v & 0x00FF_FFFF) != 0) {
                p.* = v | 0xFF00_0000;
            }
        }
    }
}

/// Same as fixTextAlphaRect but over the whole buffer.
pub fn fixTextAlpha(pixels: [*]u32, width: usize, height: usize) void {
    fixTextAlphaRect(pixels, width, height, 0, 0, width, height);
}

/// No-ops if the rect would overrun the buffer's row width.
pub fn fillRect(pixels: [*]u32, stride: usize, x: usize, y: usize, w: usize, h: usize, argb: u32) void {
    const end_y = y + h;
    const end_x = x + w;
    if (end_x > stride) return;
    var py = y;
    while (py < end_y) : (py += 1) {
        @memset(pixels[py * stride + x .. py * stride + end_x], argb);
    }
}

/// Copies `text` into a fixed-size null-terminated buffer, truncating to fit.
pub fn toBufZ(comptime buf_size: usize, text: []const u8) [buf_size:0]u8 {
    var buf: [buf_size:0]u8 = undefined;
    const n = @min(text.len, buf_size - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return buf;
}

/// Measures the pixel width of `text` (truncated to `buf_size - 1` bytes) using the currently selected font.
pub fn measureTextWidth(comptime buf_size: usize, dc: win32.HDC, text: []const u8) usize {
    const buf = toBufZ(buf_size, text);
    const n = @min(text.len, buf_size - 1);
    var sz: win32.SIZE = undefined;
    _ = win32.GetTextExtentPoint32A(dc, &buf, @intCast(n), &sz);
    return @intCast(@max(0, sz.cx));
}

/// Longest prefix of `text` (plus "...") that fits within `max_w` pixels measured on `dc`, written into `out`; returns the prefix as-is (no ellipsis) if it already fits.
pub fn truncateTextToFit(comptime buf_size: usize, dc: win32.HDC, out: *[buf_size:0]u8, text: []const u8, max_w: usize) []const u8 {
    var buf: [buf_size:0]u8 = undefined;
    // -4 leaves room for the "..." suffix.
    const orig_n = @min(text.len, buf_size - 4);
    @memcpy(buf[0..orig_n], text[0..orig_n]);
    buf[orig_n] = 0;
    var sz: win32.SIZE = undefined;
    _ = win32.GetTextExtentPoint32A(dc, &buf, @intCast(orig_n), &sz);
    if (@as(usize, @intCast(@max(0, sz.cx))) <= max_w) {
        @memcpy(out[0..orig_n], text[0..orig_n]);
        out[orig_n] = 0;
        return out[0..orig_n];
    }

    const ellipsis = "...";
    var ellipsis_w: win32.SIZE = undefined;
    _ = win32.GetTextExtentPoint32A(dc, ellipsis, 3, &ellipsis_w);
    const budget: i32 = @as(i32, @intCast(max_w)) - ellipsis_w.cx;
    if (budget <= 0) return out[0..0];

    var lo: usize = 0;
    var hi: usize = orig_n;
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        @memcpy(buf[0..mid], text[0..mid]);
        buf[mid] = 0;
        _ = win32.GetTextExtentPoint32A(dc, &buf, @intCast(mid), &sz);
        if (sz.cx <= budget) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }

    @memcpy(out[0..lo], text[0..lo]);
    @memcpy(out[lo .. lo + 3], ellipsis);
    out[lo + 3] = 0;
    return out[0 .. lo + 3];
}

/// `background` may be null for a layered/owner-drawn window that paints its own background.
pub fn registerWindowClass(
    instance: win32.HINSTANCE,
    wnd_proc: *const fn (win32.HWND, win32.UINT, win32.WPARAM, win32.LPARAM) callconv(.c) win32.LRESULT,
    class_name: [*:0]const u8,
    background: ?win32.HBRUSH,
) !void {
    const cursor = win32.LoadCursorA(null, win32.IDC_ARROW);
    const wc = win32.WNDCLASSEXA{
        .cbSize = @sizeOf(win32.WNDCLASSEXA),
        .style = 0,
        .lpfnWndProc = wnd_proc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = cursor,
        .hbrBackground = background,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };

    if (win32.RegisterClassExA(&wc) == 0) {
        return error.RegisterClassFailed;
    }
}

const HTCAPTION: win32.LRESULT = 2;
const HTCLIENT: win32.LRESULT = 1;

// Anchors a drag to the cursor position at WM_ENTERSIZEMOVE, since WM_MOVING's rect reflects prior snap overrides; a single shared pair is safe since only one window can be mid-drag at a time.
var g_panel_drag_anchor_cursor: win32.POINT = .{ .x = 0, .y = 0 };
var g_panel_drag_anchor_rect: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

/// WM_NCHITTEST for a panel whose header (the top `header_height` px) is its only drag handle.
pub fn panelHeaderHitTest(hwnd: win32.HWND, lParam: win32.LPARAM, header_height: i32, dragging_enabled: bool) win32.LRESULT {
    const sy: i32 = @as(i32, @intCast(@as(i16, @truncate(lParam >> 16))));
    var wr: win32.RECT = undefined;
    _ = win32.GetWindowRect(hwnd, &wr);
    const cy = sy - wr.top;
    if (dragging_enabled and cy < header_height) return HTCAPTION;
    return HTCLIENT;
}

/// Call from WM_ENTERSIZEMOVE before any other drag-start handling.
pub fn beginPanelDrag(hwnd: win32.HWND) void {
    _ = win32.GetCursorPos(&g_panel_drag_anchor_cursor);
    _ = win32.GetWindowRect(hwnd, &g_panel_drag_anchor_rect);
}

/// Call from WM_MOVING to recompute the truly-intended position from the absolute cursor delta since drag start (ignoring Windows' possibly already-snapped `rect`) and snap it via input.applySnapping.
pub fn updatePanelDragRect(hwnd: win32.HWND, rect: *win32.RECT) void {
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;

    var cursor: win32.POINT = undefined;
    _ = win32.GetCursorPos(&cursor);
    const intended_x = g_panel_drag_anchor_rect.left + (cursor.x - g_panel_drag_anchor_cursor.x);
    const intended_y = g_panel_drag_anchor_rect.top + (cursor.y - g_panel_drag_anchor_cursor.y);

    const input_mod = @import("input.zig");
    const snapped = input_mod.applySnapping(intended_x, intended_y, width, height, hwnd);

    rect.left = snapped.x;
    rect.top = snapped.y;
    rect.right = snapped.x + width;
    rect.bottom = snapped.y + height;
}

/// For a single-font-at-a-time caller; painter.zig's per-slot/DPI cache (`Painter.getCachedFont`) needs its own since it juggles many fonts at once.
pub fn ensureFont(
    allocator: std.mem.Allocator,
    context: []const u8,
    font: *?win32.HFONT,
    cached_name: *[]const u8,
    cached_size: *i32,
    cached_weight: *types.FontWeight,
    want_name: []const u8,
    want_size: i32,
    want_weight: types.FontWeight,
) void {
    const unchanged = font.* != null and
        std.mem.eql(u8, cached_name.*, want_name) and
        cached_size.* == want_size and
        cached_weight.* == want_weight;
    if (unchanged) return;

    if (font.*) |old| _ = win32.DeleteObject(old);
    font.* = null;

    const name_z = allocator.dupeZ(u8, want_name) catch |err| {
        slog.err("Failed to allocate {s} font name: {}", .{ context, err });
        return;
    };
    defer allocator.free(name_z);

    const name_copy = allocator.dupe(u8, want_name) catch |err| {
        slog.err("Failed to allocate {s} font name: {}", .{ context, err });
        return;
    };

    font.* = win32.CreateFontA(
        -want_size,
        0,
        0,
        0,
        want_weight.toWin32Weight(),
        if (want_weight.isItalic()) 1 else 0,
        0,
        0,
        win32.DEFAULT_CHARSET,
        win32.OUT_DEFAULT_PRECIS,
        win32.CLIP_DEFAULT_PRECIS,
        win32.CLEARTYPE_QUALITY,
        win32.DEFAULT_PITCH,
        name_z,
    );

    allocator.free(cached_name.*);
    cached_name.* = name_copy;
    cached_size.* = want_size;
    cached_weight.* = want_weight;
}
