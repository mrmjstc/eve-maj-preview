//! The ghost overlay outlining saved positions while something is dragged, and the drag hint.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const color = @import("../util/color.zig");
const config_mod = @import("../config.zig");
const draw = @import("../thumbnail/draw.zig");
const font_cache_mod = @import("../thumbnail/font_cache.zig");
const ghost_groups = @import("ghost_groups.zig");
const monitors = @import("../layout/monitors.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");
const lang = @import("../lang/lang.zig");
const log = @import("../log.zig");

const Config = config_mod.Config;
const FontCache = font_cache_mod.FontCache;
const GhostGroup = ghost_groups.GhostGroup;
const slog = log.Scoped("drag_overlays");

const WINDOW_CLASS_NAME = "EVE_GHOST_OVERLAY_CLASS";
const OUTLINE_THICKNESS = 2;

/// A topmost, click-through overlay outlining every other saved position during a drag, created on first use and hidden between drags.
pub const GhostOverlay = struct {
    allocator: std.mem.Allocator,
    hwnd: ?win32.HWND = null,
    bitmap: ?gdi_overlay.OverlayBitmap = null,
    /// Set by show for the whole drag, so snapping needn't recompute it every mouse move; null while hidden.
    groups: ?[]GhostGroup = null,

    pub fn init(allocator: std.mem.Allocator) GhostOverlay {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GhostOverlay) void {
        self.clearGroups();
        if (self.bitmap) |bitmap| bitmap.deinit();
        if (self.hwnd) |hwnd| _ = win32.DestroyWindow(hwnd);
    }

    /// Also run at the start of show, so snapping never reads a stale slice.
    fn clearGroups(self: *GhostOverlay) void {
        const groups = self.groups orelse return;
        ghost_groups.freeGroups(self.allocator, groups);
        self.groups = null;
    }

    /// Called once when a drag starts, since the ghosts don't change during it.
    pub fn show(self: *GhostOverlay, instance: win32.HINSTANCE, font_cache: *FontCache, config: *const Config, exclude_character: []const u8) void {
        self.clearGroups();

        const groups = ghost_groups.collect(self.allocator, config, exclude_character) catch |err| {
            slog.err("Failed to collect ghost positions: {}", .{err});
            return;
        };
        self.groups = groups;

        if (groups.len == 0) {
            self.hide();
            return;
        }

        var bounds = groups[0].rect;
        for (groups[1..]) |g| {
            bounds.left = @min(bounds.left, g.rect.left);
            bounds.top = @min(bounds.top, g.rect.top);
            bounds.right = @max(bounds.right, g.rect.right);
            bounds.bottom = @max(bounds.bottom, g.rect.bottom);
        }

        const width = bounds.right - bounds.left;
        const height = bounds.bottom - bounds.top;
        if (width <= 0 or height <= 0) {
            self.hide();
            return;
        }

        if (self.hwnd) |hwnd| {
            _ = win32.SetWindowPos(hwnd, win32.HWND_TOPMOST, bounds.left, bounds.top, width, height, win32.SWP_NOACTIVATE);
        } else {
            GhostClass.register(instance) catch |err| {
                slog.err("Failed to register the ghost overlay window class: {}", .{err});
                return;
            };
            self.hwnd = win32.CreateWindowExA(
                win32.WS_EX_LAYERED | win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW | win32.WS_EX_NOACTIVATE | win32.WS_EX_TRANSPARENT,
                WINDOW_CLASS_NAME,
                "",
                win32.WS_POPUP,
                bounds.left,
                bounds.top,
                width,
                height,
                null,
                null,
                instance,
                null,
            ) orelse {
                slog.err("Failed to create ghost overlay window", .{});
                return;
            };
        }

        const hwnd = self.hwnd.?;

        const overlay = gdi_overlay.OverlayBitmap.ensureSize(&self.bitmap, width, height) catch |err| {
            slog.err("Failed to allocate ghost overlay bitmap: {}", .{err});
            return;
        };
        overlay.clear();

        const font = font_cache.characterNameFont(&config.thumbnail, monitors.getWindowDpi(hwnd)) catch |err| {
            slog.err("Failed to get font for ghost overlay: {}", .{err});
            return;
        };
        const old_font = win32.SelectObject(overlay.mem_dc, font);
        defer {
            if (old_font) |previous_font| _ = win32.SelectObject(overlay.mem_dc, previous_font);
        }

        // Reduced alpha, so it reads as a ghost rather than a real thumbnail.
        const outline_color: u32 = color.withAlpha(config.focusedBorderColor(), 0xB0);
        const text_color: u32 = 0xE0FFFFFF;

        for (groups) |group| {
            const local_x = group.rect.left - bounds.left;
            const local_y = group.rect.top - bounds.top;
            const rect_width: usize = @intCast(group.rect.right - group.rect.left);
            const rect_height: usize = @intCast(group.rect.bottom - group.rect.top);

            pixel_buffer.drawRectOutline(overlay.canvas(), local_x, local_y, rect_width, rect_height, OUTLINE_THICKNESS, outline_color);

            const dimensions = draw.measureText(overlay.mem_dc, group.names);
            draw.renderText(overlay.mem_dc, group.names, local_x, local_y, text_color);
            pixel_buffer.fixTextAlphaRect(overlay.canvas(), local_x, local_y, dimensions.width, dimensions.height);
        }

        gdi_overlay.presentLayered(hwnd, overlay, 255);

        _ = win32.ShowWindow(hwnd, win32.SW_SHOWNOACTIVATE);
    }

    pub fn hide(self: *GhostOverlay) void {
        self.clearGroups();
        if (self.hwnd) |hwnd| {
            _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
        }
    }
};

const GhostClass = gdi_overlay.WindowClass(WINDOW_CLASS_NAME, win32.DefWindowProcA);

/// Hint box centered on the monitor nearest `dragging_hwnd`; called once when a drag starts, static for its duration.
pub fn showDragHint(hint_box: *gdi_overlay.HintBox, instance: win32.HINSTANCE, font_cache: *FontCache, config: *const Config, dragging_hwnd: win32.HWND) void {
    const nearest = monitors.nearestMonitorBounds(dragging_hwnd);
    const font = font_cache.characterNameFont(&config.thumbnail, monitors.dpiForMonitor(nearest.monitor)) catch |err| {
        slog.err("Failed to get font for drag hint: {}", .{err});
        return;
    };
    hint_box.show(instance, font, color.withAlpha(config.thumbnail.characterNameColor, 0xFF), lang.text("Hold Ctrl to move all thumbnails together"), lang.text("Turn off dragging from the tray icon or settings"), nearest.bounds);
}
