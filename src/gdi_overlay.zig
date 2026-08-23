const std = @import("std");
const win32 = @import("win32.zig");

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
