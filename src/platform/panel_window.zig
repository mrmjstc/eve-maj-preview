//! A panel redrawn into a DIB, shared by the client list and the History, Map and Intel panels: its window, a borderless overlay or a normal one, its font, bitmap and redraw skipping.
const std = @import("std");
const win32 = @import("win32.zig");
const fonts = @import("fonts.zig");
const gdi_overlay = @import("gdi_overlay.zig");
const log = @import("../log.zig");

const slog = log.Scoped("panel_window");

const NATIVE_STYLE: win32.DWORD = win32.WS_OVERLAPPEDWINDOW;
/// Layered only for its opacity; SetLayeredWindowAttributes leaves painting to WM_PAINT.
const NATIVE_EX_STYLE: win32.DWORD = win32.WS_EX_LAYERED;

/// What a normal window keeps beyond an overlay.
const NativeState = struct {
    /// The client size the settings last asked for, so a resize by hand isn't undone until they change.
    settled: win32.SIZE,
    opacity: u8 = 255,
    is_topmost: bool,
};

pub const PanelWindow = struct {
    hwnd: win32.HWND,
    allocator: std.mem.Allocator,
    font: gdi_overlay.CachedFont = .{},
    /// A smaller font for headers and secondary text; ensureSmallFont makes it.
    small_font: gdi_overlay.CachedFont = .{},
    bitmap: ?gdi_overlay.OverlayBitmap = null,
    /// The client size; -1 forces an overlay's resize on the first frame, and a normal window's owner keeps it from WM_SIZE.
    width: i32 = -1,
    height: i32 = -1,
    last_signature: ?u64 = null,
    /// Where the settings last put the panel, so a drag isn't undone by followPosition until the settings change.
    placed: win32.POINT = .{ .x = 0, .y = 0 },
    /// Null for a borderless overlay.
    native: ?NativeState = null,

    pub fn init(allocator: std.mem.Allocator, instance: win32.HINSTANCE, class_name: [*:0]const u8, title: [*:0]const u8, rect: win32.RECT) !PanelWindow {
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

    /// A window with a title bar, on the taskbar, painted on WM_PAINT through `paint`; `client_rect` is the area inside its frame.
    pub fn initNative(allocator: std.mem.Allocator, instance: win32.HINSTANCE, class_name: [*:0]const u8, title: [*:0]const u8, client_rect: win32.RECT, is_topmost: bool) !PanelWindow {
        const width = win32.rectWidth(client_rect);
        const height = win32.rectHeight(client_rect);
        const outer = outerSize(width, height);
        const ex_style: win32.DWORD = if (is_topmost) NATIVE_EX_STYLE | win32.WS_EX_TOPMOST else NATIVE_EX_STYLE;
        const hwnd = win32.CreateWindowExA(ex_style, class_name, title, NATIVE_STYLE, client_rect.left, client_rect.top, outer.cx, outer.cy, null, null, instance, null) orelse return error.CreateWindowFailed;
        errdefer _ = win32.DestroyWindow(hwnd);
        // A layered window doesn't show until this is called.
        if (!win32.toBool(win32.SetLayeredWindowAttributes(hwnd, 0, 255, win32.LWA_ALPHA))) return error.SetOpacityFailed;

        const dark_mode: win32.DWORD = 1;
        _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark_mode, @sizeOf(win32.DWORD));
        if (win32.LoadIconA(instance, @ptrFromInt(win32.APP_ICON_ID))) |icon| {
            _ = win32.SendMessageA(hwnd, win32.WM_SETICON, win32.ICON_BIG, win32.ptrToLparam(icon));
            _ = win32.SendMessageA(hwnd, win32.WM_SETICON, win32.ICON_SMALL, win32.ptrToLparam(icon));
        }
        return .{
            .hwnd = hwnd,
            .allocator = allocator,
            .placed = .{ .x = client_rect.left, .y = client_rect.top },
            .width = width,
            .height = height,
            .native = .{ .settled = .{ .cx = width, .cy = height }, .is_topmost = is_topmost },
        };
    }

    /// A normal window's full size for a client area of `width`×`height`.
    pub fn outerSize(width: i32, height: i32) win32.SIZE {
        var rect: win32.RECT = .{ .left = 0, .top = 0, .right = width, .bottom = height };
        if (!win32.toBool(win32.AdjustWindowRectEx(&rect, NATIVE_STYLE, win32.FALSE, NATIVE_EX_STYLE))) slog.warn("Failed to measure the window's frame: error {d}", .{win32.GetLastError()});
        return .{ .cx = win32.rectWidth(rect), .cy = win32.rectHeight(rect) };
    }

    /// Moves the panel when its configured position changes.
    pub fn followPosition(self: *PanelWindow, x: i32, y: i32) void {
        if (self.placed.x == x and self.placed.y == y) return;
        self.placed = .{ .x = x, .y = y };
        if (self.native != null) {
            _ = win32.SetWindowPos(self.hwnd, win32.HWND_NOTOPMOST, x, y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
        } else {
            _ = win32.SetWindowPos(self.hwnd, win32.HWND_TOPMOST, x, y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
        }
    }

    /// Resizes a normal window when its configured client size changes; a maximized one waits until it's restored.
    pub fn followSize(self: *PanelWindow, width: i32, height: i32) void {
        const native = if (self.native) |*state| state else return;
        if (native.settled.cx == width and native.settled.cy == height) return;
        if (win32.isWindowZoomed(self.hwnd)) return;
        native.settled = .{ .cx = width, .cy = height };
        const outer = outerSize(width, height);
        _ = win32.SetWindowPos(self.hwnd, win32.HWND_NOTOPMOST, 0, 0, outer.cx, outer.cy, win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
    }

    /// Whether a normal window stays above others.
    pub fn followTopmost(self: *PanelWindow, is_topmost: bool) void {
        const native = if (self.native) |*state| state else return;
        if (native.is_topmost == is_topmost) return;
        native.is_topmost = is_topmost;
        _ = win32.SetWindowPos(self.hwnd, if (is_topmost) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
    }

    pub fn deinit(self: *PanelWindow) void {
        if (self.bitmap) |bitmap| bitmap.deinit();
        self.font.deinit(self.allocator);
        self.small_font.deinit(self.allocator);
        _ = win32.DestroyWindow(self.hwnd);
    }

    /// Makes `font` match these settings, recreating it after a live-previewed change.
    pub fn ensureFont(self: *PanelWindow, context: []const u8, name: []const u8, size: i32, weight: fonts.FontWeight) !void {
        try self.font.ensure(self.allocator, context, name, size, weight);
    }

    /// Like ensureFont, for `small_font`.
    pub fn ensureSmallFont(self: *PanelWindow, context: []const u8, name: []const u8, size: i32, weight: fonts.FontWeight) !void {
        try self.small_font.ensure(self.allocator, context, name, size, weight);
    }

    /// Whether `signature` matches the last frame shown, so there's nothing to redraw; keeps the window shown either way.
    pub fn isUnchanged(self: *const PanelWindow, signature: u64) bool {
        if (self.bitmap == null or self.last_signature != signature) return false;
        self.show();
        return true;
    }

    /// Sizes the window and its bitmap to `width`×`height`, and returns the bitmap cleared for drawing.
    pub fn beginFrame(self: *PanelWindow, width: i32, height: i32) !*gdi_overlay.OverlayBitmap {
        if (self.native == null and (width != self.width or height != self.height)) {
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
        self.last_signature = signature;
        if (self.native) |*native| {
            if (native.opacity != opacity) {
                native.opacity = opacity;
                _ = win32.SetLayeredWindowAttributes(self.hwnd, 0, opacity, win32.LWA_ALPHA);
            }
            _ = win32.GdiFlush();
            _ = win32.InvalidateRect(self.hwnd, null, win32.FALSE);
            // WM_PAINT otherwise waits for an empty queue, which a moving mouse keeps from happening.
            _ = win32.UpdateWindow(self.hwnd);
        } else {
            gdi_overlay.presentLayered(self.hwnd, &self.bitmap.?, opacity);
        }
        self.show();
    }

    /// For a normal window's WM_PAINT.
    pub fn paint(self: *const PanelWindow) void {
        var paint_info: win32.PAINTSTRUCT = undefined;
        const dc = win32.BeginPaint(self.hwnd, &paint_info) orelse return;
        defer _ = win32.EndPaint(self.hwnd, &paint_info);
        const bitmap = if (self.bitmap) |*shown| shown else return;
        _ = win32.BitBlt(dc, 0, 0, @intCast(bitmap.width), @intCast(bitmap.height), bitmap.mem_dc, 0, 0, win32.SRCCOPY);
    }

    fn show(self: *const PanelWindow) void {
        if (self.native == null) {
            _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNOACTIVATE);
        } else if (!win32.isWindowVisible(self.hwnd)) {
            // Only when hidden, as doing it each frame would undo a minimize.
            _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNA);
        }
    }

    pub fn hide(self: *const PanelWindow) void {
        _ = win32.ShowWindow(self.hwnd, win32.SW_HIDE);
    }

    /// Null, logged, if the window's position can't be read.
    pub fn bounds(self: *const PanelWindow) ?win32.RECT {
        var rect: win32.RECT = undefined;
        if (!win32.toBool(win32.GetWindowRect(self.hwnd, &rect))) {
            slog.warn("Failed to read the panel's position", .{});
            return null;
        }
        return rect;
    }

    /// Null, logged, if the window's position can't be read.
    pub fn topLeft(self: *const PanelWindow) ?win32.POINT {
        const rect = self.bounds() orelse return null;
        return .{ .x = rect.left, .y = rect.top };
    }
};
