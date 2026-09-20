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

    pub fn destroy(self: *const OverlayBitmap) void {
        _ = win32.SelectObject(self.mem_dc, self.old_bitmap);
        _ = win32.DeleteObject(self.bitmap);
        _ = win32.DeleteDC(self.mem_dc);
    }

    pub fn needsResize(existing: ?OverlayBitmap, width: i32, height: i32) bool {
        const b = existing orelse return true;
        return b.width != @as(usize, @intCast(width)) or b.height != @as(usize, @intCast(height));
    }

    /// Leaves `slot.*` null, rather than a stale bitmap, if creation fails.
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

/// No-ops if the rect would overrun the buffer's row width or its height.
pub fn fillRect(pixels: [*]u32, stride: usize, height: usize, x: usize, y: usize, w: usize, h: usize, argb: u32) void {
    const end_y = y + h;
    const end_x = x + w;
    if (end_x > stride or end_y > height) return;
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

/// Translucent black backing shared by the small hint boxes and labels drawn over the desktop.
pub const HINT_BG_COLOR: u32 = 0xC8000000;

/// Measures `text` (truncated to `buf_size - 1` bytes) using the currently selected font.
pub fn measureTextSize(comptime buf_size: usize, dc: win32.HDC, text: []const u8) win32.SIZE {
    const buf = toBufZ(buf_size, text);
    const n = @min(text.len, buf_size - 1);
    var sz: win32.SIZE = undefined;
    _ = win32.GetTextExtentPoint32A(dc, &buf, @intCast(n), &sz);
    return sz;
}

/// Measures the pixel width of `text` (truncated to `buf_size - 1` bytes) using the currently selected font.
pub fn measureTextWidth(comptime buf_size: usize, dc: win32.HDC, text: []const u8) usize {
    return @intCast(@max(0, measureTextSize(buf_size, dc, text).cx));
}

/// UTF-8 to UTF-16 into `out`, truncating to `buf_size` bytes; returns the number of UTF-16 units written.
fn toWide(comptime buf_size: usize, text: []const u8, out: *[buf_size]u16) usize {
    const len = @min(text.len, buf_size);
    if (len == 0) return 0;
    const written = win32.MultiByteToWideChar(win32.CP_UTF8, 0, text.ptr, @intCast(len), out, @intCast(buf_size));
    return @intCast(@max(0, written));
}

/// Like `measureTextSize`, for UTF-8 text such as translated labels.
pub fn measureTextSizeUtf8(comptime buf_size: usize, dc: win32.HDC, text: []const u8) win32.SIZE {
    var wide: [buf_size]u16 = undefined;
    const n = toWide(buf_size, text, &wide);
    var sz = win32.SIZE{ .cx = 0, .cy = 0 };
    _ = win32.GetTextExtentPoint32W(dc, &wide, @intCast(n), &sz);
    return sz;
}

/// Like `drawText`, for UTF-8 text such as translated labels.
pub fn drawTextUtf8(comptime buf_size: usize, dc: win32.HDC, x: i32, y: i32, text: []const u8, color: u32) void {
    var wide: [buf_size]u16 = undefined;
    const n = toWide(buf_size, text, &wide);
    _ = win32.SetBkMode(dc, win32.TRANSPARENT);
    _ = win32.SetTextColor(dc, toColorRef(color));
    _ = win32.TextOutW(dc, x, y, &wide, @intCast(n));
}

/// Draws `text` (truncated to `buf_size - 1` bytes) with a transparent background in the currently selected font; `color` is 0xAARRGGBB.
pub fn drawText(comptime buf_size: usize, dc: win32.HDC, x: i32, y: i32, text: []const u8, color: u32) void {
    const buf = toBufZ(buf_size, text);
    const n = @min(text.len, buf_size - 1);
    _ = win32.SetBkMode(dc, win32.TRANSPARENT);
    _ = win32.SetTextColor(dc, toColorRef(color));
    _ = win32.TextOutA(dc, x, y, &buf, @intCast(n));
}

/// Corners are cut with per-row insets (no anti-aliasing), which is fine at the small radii UI buttons use.
pub fn fillRoundedRect(pixels: [*]u32, stride: usize, height: usize, x: usize, y: usize, w: usize, h: usize, radius: usize, argb: u32) void {
    const r = @min(radius, @min(w, h) / 2);
    const radius_f: f32 = @floatFromInt(r);
    var row: usize = 0;
    while (row < h) : (row += 1) {
        const from_edge = @min(row, h - 1 - row);
        var inset: usize = 0;
        if (from_edge < r) {
            const dy = radius_f - @as(f32, @floatFromInt(from_edge)) - 0.5;
            inset = @intFromFloat(@round(radius_f - @sqrt(radius_f * radius_f - dy * dy)));
        }
        fillRect(pixels, stride, height, x + inset, y + row, w - 2 * inset, 1, argb);
    }
}

/// Null if `name` isn't installed, since CreateFontA silently substitutes another face. Matches by prefix because GDI can report a weight variant of a variable font (e.g. "Cascadia Code SemiBold") as the face.
pub fn createInstalledFont(dc: win32.HDC, name: [:0]const u8, height_px: i32, weight: c_int) ?win32.HFONT {
    const font = win32.CreateFontA(-height_px, 0, 0, 0, weight, 0, 0, 0, win32.DEFAULT_CHARSET, win32.OUT_DEFAULT_PRECIS, win32.CLIP_DEFAULT_PRECIS, win32.CLEARTYPE_QUALITY, win32.DEFAULT_PITCH, name.ptr) orelse return null;

    const old_font = win32.SelectObject(dc, font);
    var face: [64]u8 = undefined;
    const face_len = win32.GetTextFaceA(dc, face.len, &face);
    if (old_font) |of| _ = win32.SelectObject(dc, of);

    if (face_len > 1 and std.ascii.startsWithIgnoreCase(face[0..@intCast(face_len - 1)], name)) return font;
    _ = win32.DeleteObject(font);
    return null;
}

pub const ButtonFace = struct {
    fill: u32,
    border: u32,
    text_color: u32,
    radius: usize,
    border_px: usize,
};

/// A filled, bordered, rounded button with `label` centered in `font`; `rect` is in bitmap coordinates.
pub fn drawButtonFace(bmp: *const OverlayBitmap, rect: win32.RECT, label: []const u8, font: win32.HFONT, face: ButtonFace) void {
    const x: usize = @intCast(rect.left);
    const y: usize = @intCast(rect.top);
    const w: usize = @intCast(win32.rectWidth(rect));
    const h: usize = @intCast(win32.rectHeight(rect));
    fillRoundedRect(bmp.pixels, bmp.width, bmp.height, x, y, w, h, face.radius, face.border);
    fillRoundedRect(bmp.pixels, bmp.width, bmp.height, x + face.border_px, y + face.border_px, w - 2 * face.border_px, h - 2 * face.border_px, face.radius -| face.border_px, face.fill);

    const old_font = win32.SelectObject(bmp.mem_dc, font);
    defer {
        if (old_font) |of| _ = win32.SelectObject(bmp.mem_dc, of);
    }
    const label_buf_size = 32;
    const text_size = measureTextSizeUtf8(label_buf_size, bmp.mem_dc, label);
    const text_w: usize = @intCast(text_size.cx);
    const text_h: usize = @intCast(text_size.cy);
    const text_x: i32 = @intCast(x + (w -| text_w) / 2);
    const text_y: i32 = @intCast(y + (h -| text_h) / 2);
    drawTextUtf8(label_buf_size, bmp.mem_dc, text_x, text_y, label, face.text_color);
    fixTextAlphaRect(bmp.pixels, bmp.width, bmp.height, text_x, text_y, text_w, text_h);
}

/// Draws a `thickness`-px outline of a rect placed anywhere inside a `buf_width`x`buf_height` pixel buffer, clamped to the buffer bounds.
pub fn drawRectOutline(pixels: [*]u32, buf_width: usize, buf_height: usize, x: i32, y: i32, w: usize, h: usize, thickness: usize, color: u32) void {
    const left: usize = @intCast(std.math.clamp(x, 0, @as(i32, @intCast(buf_width))));
    const top: usize = @intCast(std.math.clamp(y, 0, @as(i32, @intCast(buf_height))));
    const right = @min(buf_width, left + w);
    const bottom = @min(buf_height, top + h);
    if (right <= left or bottom <= top) return;

    const t = @min(thickness, @min(right - left, bottom - top));
    fillRect(pixels, buf_width, buf_height, left, top, right - left, t, color);
    fillRect(pixels, buf_width, buf_height, left, bottom - t, right - left, t, color);
    fillRect(pixels, buf_width, buf_height, left, top, t, bottom - top, color);
    fillRect(pixels, buf_width, buf_height, right - t, top, t, bottom - top, color);
}

/// Pushes the bitmap to a layered window at its origin using per-pixel alpha, scaled by `opacity`.
pub fn presentLayered(hwnd: win32.HWND, bmp: *const OverlayBitmap, opacity: u8) void {
    const screen_dc = win32.GetDC(null) orelse {
        slog.err("Failed to get screen DC to present layered overlay", .{});
        return;
    };
    defer _ = win32.ReleaseDC(null, screen_dc);

    const window_size = win32.SIZE{ .cx = @intCast(bmp.width), .cy = @intCast(bmp.height) };
    const source_pos = win32.POINT{ .x = 0, .y = 0 };
    var blend = win32.BLENDFUNCTION{
        .BlendOp = win32.AC_SRC_OVER,
        .BlendFlags = 0,
        .SourceConstantAlpha = opacity,
        .AlphaFormat = win32.AC_SRC_ALPHA,
    };
    _ = win32.UpdateLayeredWindow(hwnd, screen_dc, null, @constCast(&window_size), bmp.mem_dc, @constCast(&source_pos), 0, &blend, win32.ULW_ALPHA);
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
) !void {
    const unchanged = font.* != null and
        std.mem.eql(u8, cached_name.*, want_name) and
        cached_size.* == want_size and
        cached_weight.* == want_weight;
    if (unchanged) return;

    if (font.*) |old| _ = win32.DeleteObject(old);
    font.* = null;

    const name_z = allocator.dupeZ(u8, want_name) catch |err| {
        slog.err("Failed to allocate {s} font name: {}", .{ context, err });
        return err;
    };
    defer allocator.free(name_z);

    const name_copy = allocator.dupe(u8, want_name) catch |err| {
        slog.err("Failed to allocate {s} font name: {}", .{ context, err });
        return err;
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
