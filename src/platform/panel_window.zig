//! A topmost layered panel redrawn into a DIB, shared by the client list and the History Panel: its window, font, bitmap and redraw skipping.
const std = @import("std");
const win32 = @import("win32.zig");
const fonts = @import("fonts.zig");
const gdi_overlay = @import("gdi_overlay.zig");

pub const PanelWindow = struct {
    hwnd: win32.HWND,
    allocator: std.mem.Allocator,
    font: ?win32.HFONT = null,
    // The settings `font` was made from; owns its name, since the config frees its own on a rename.
    font_name: []const u8 = "",
    font_size: i32 = 0,
    font_weight: fonts.FontWeight = .Regular,
    bitmap: ?gdi_overlay.OverlayBitmap = null,
    // -1 forces a resize on the first frame.
    width: i32 = -1,
    height: i32 = -1,
    last_signature: ?u64 = null,
    /// Where the settings last put the panel, so a drag isn't undone by followPosition until the settings change.
    placed: win32.POINT = .{ .x = 0, .y = 0 },

    pub fn create(allocator: std.mem.Allocator, instance: win32.HINSTANCE, class_name: [*:0]const u8, title: [*:0]const u8, rect: win32.RECT) !PanelWindow {
        const hwnd = win32.CreateWindowExA(
            win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW | win32.WS_EX_NOACTIVATE | win32.WS_EX_LAYERED,
            class_name,
            title,
            win32.WS_POPUP,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            null,
            null,
            instance,
            null,
        ) orelse return error.CreateWindowFailed;
        return .{ .hwnd = hwnd, .allocator = allocator, .placed = .{ .x = rect.left, .y = rect.top } };
    }

    /// Moves the panel when its configured position changes.
    pub fn followPosition(self: *PanelWindow, x: i32, y: i32) void {
        if (self.placed.x == x and self.placed.y == y) return;
        self.placed = .{ .x = x, .y = y };
        _ = win32.SetWindowPos(self.hwnd, win32.HWND_TOPMOST, x, y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
    }

    pub fn deinit(self: *PanelWindow) void {
        if (self.bitmap) |bitmap| bitmap.destroy();
        if (self.font) |font| _ = win32.DeleteObject(font);
        self.allocator.free(self.font_name);
        _ = win32.DestroyWindow(self.hwnd);
    }

    /// Makes `font` match these settings, recreating it after a live-previewed change.
    pub fn ensureFont(self: *PanelWindow, context: []const u8, name: []const u8, size: i32, weight: fonts.FontWeight) !void {
        try gdi_overlay.ensureFont(self.allocator, context, &self.font, &self.font_name, &self.font_size, &self.font_weight, name, size, weight);
    }

    /// Whether `signature` matches the last frame shown, so there's nothing to redraw; keeps the window shown either way.
    pub fn isUnchanged(self: *PanelWindow, signature: u64) bool {
        if (self.bitmap == null or self.last_signature != signature) return false;
        _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNOACTIVATE);
        return true;
    }

    /// Sizes the window and its bitmap to `width`×`height`, and returns the bitmap cleared for drawing.
    pub fn beginFrame(self: *PanelWindow, width: i32, height: i32) !*gdi_overlay.OverlayBitmap {
        if (width != self.width or height != self.height) {
            _ = win32.SetWindowPos(self.hwnd, win32.HWND_TOPMOST, 0, 0, width, height, win32.SWP_NOMOVE | win32.SWP_NOACTIVATE);
            self.width = width;
            self.height = height;
        }
        if (gdi_overlay.OverlayBitmap.needsResize(self.bitmap, width, height)) {
            const screen_dc = win32.GetDC(null) orelse return error.GetDCFailed;
            defer _ = win32.ReleaseDC(null, screen_dc);
            try gdi_overlay.OverlayBitmap.recreate(&self.bitmap, screen_dc, width, height);
        }
        const bitmap = &self.bitmap.?;
        bitmap.clear();
        return bitmap;
    }

    /// Shows the frame drawn since beginFrame; `signature` identifies it for isUnchanged.
    pub fn present(self: *PanelWindow, opacity: u8, signature: u64) void {
        gdi_overlay.presentLayered(self.hwnd, &self.bitmap.?, opacity);
        _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNOACTIVATE);
        self.last_signature = signature;
    }

    pub fn hide(self: *const PanelWindow) void {
        _ = win32.ShowWindow(self.hwnd, win32.SW_HIDE);
    }

    pub fn topLeft(self: *const PanelWindow) win32.POINT {
        var rect: win32.RECT = undefined;
        _ = win32.GetWindowRect(self.hwnd, &rect);
        return .{ .x = rect.left, .y = rect.top };
    }
};
