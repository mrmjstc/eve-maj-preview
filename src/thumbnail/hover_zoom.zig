//! The enlarged copy of a thumbnail shown while the cursor rests on it.
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const painter_mod = @import("../painter.zig");
const window = @import("window.zig");
const overlay = @import("overlay.zig");
const font_cache_mod = @import("font_cache.zig");
const zoom = @import("../layout/zoom.zig");
const monitors = @import("../layout/monitors.zig");
const thumbnail_drag = @import("../drag/thumbnail.zig");
const log = @import("../log.zig");

const ThumbnailWindow = window.ThumbnailWindow;
const Painter = painter_mod.Painter;
const Config = config_mod.Config;
const FontCache = font_cache_mod.FontCache;
const slog = log.scoped("hover_zoom");

/// The game picture, and the thumbnail's text overlay redrawn at the zoom's size above it.
const Windows = struct {
    hwnd: win32.HWND,
    text_hwnd: win32.HWND,
};

pub const HoverZoom = struct {
    /// Created on first use, then kept hidden between zooms.
    windows: ?Windows = null,
    thumbnail_id: ?win32.HTHUMBNAIL = null,
    /// The client being shown; null while hidden.
    source_hwnd: ?win32.HWND = null,
    /// Screen rect of the zoom while shown.
    rect: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    render_cache: overlay.RenderCache = .{},

    /// Cheap to repeat on every mouse move: does nothing while `thumbnail` is already shown.
    pub fn show(self: *HoverZoom, instance: win32.HINSTANCE, font_cache: *FontCache, thumbnail: *const ThumbnailWindow, config: *const Config) void {
        if (self.source_hwnd == thumbnail.source_hwnd) return;
        self.hide();

        const windows = self.windows orelse blk: {
            const created = create(instance) catch |err| {
                slog.err("Failed to create the hover zoom windows: {}", .{err});
                return;
            };
            self.windows = created;
            break :blk created;
        };
        const hwnd = windows.hwnd;
        const interaction = &config.interaction;

        var base: win32.RECT = undefined;
        if (!win32.toBool(win32.GetWindowRect(thumbnail.hwnd, &base))) {
            slog.warn("Failed to read the thumbnail rect to zoom '{s}'", .{thumbnail.character_name});
            return;
        }
        const bounds = monitors.nearestMonitorBounds(thumbnail.hwnd).bounds;
        const rect = zoom.zoomedRect(base, interaction.hoverZoomPercent, interaction.hoverZoomAnchor, bounds);
        const size = window.Size{ .width = win32.rectWidth(rect), .height = win32.rectHeight(rect) };

        var thumbnail_id: win32.HTHUMBNAIL = undefined;
        if (win32.DwmRegisterThumbnail(hwnd, thumbnail.source_hwnd, &thumbnail_id) != 0) {
            slog.warn("Failed to register the hover zoom thumbnail for '{s}'", .{thumbnail.character_name});
            return;
        }
        self.thumbnail_id = thumbnail_id;

        const props = window.thumbnailProps(size, win32.DWM_TNP_VISIBLE | win32.DWM_TNP_RECTDESTINATION | win32.DWM_TNP_SOURCECLIENTAREAONLY);
        if (win32.DwmUpdateThumbnailProperties(thumbnail_id, &props) != 0) {
            slog.warn("Failed to size the hover zoom thumbnail for '{s}'", .{thumbnail.character_name});
            self.hide();
            return;
        }

        self.source_hwnd = thumbnail.source_hwnd;
        self.rect = rect;
        _ = win32.SetWindowPos(hwnd, win32.HWND_TOPMOST, rect.left, rect.top, size.width, size.height, win32.SWP_NOACTIVATE | win32.SWP_SHOWWINDOW);

        // Null before the thumbnail's first render; renderOverlay draws the text then.
        const settings = thumbnail.render_cache.settings orelse return;
        self.drawOverlay(font_cache, thumbnail, settings, config);
    }

    /// Call after any thumbnail's overlay is redrawn; ignores all but the zoomed one.
    pub fn renderOverlay(self: *HoverZoom, font_cache: *FontCache, thumbnail: *const ThumbnailWindow, settings: overlay.RenderSettings, config: *const Config) void {
        if (self.source_hwnd != thumbnail.source_hwnd) return;
        self.drawOverlay(font_cache, thumbnail, settings, config);
    }

    /// Goes last in a batch that raises thumbnails, so none is ever composited above the zoom.
    pub fn deferRaise(self: *const HoverZoom, hdwp: win32.HDWP) ?win32.HDWP {
        if (self.source_hwnd == null) return hdwp;
        const windows = self.windows orelse return hdwp;
        // Picture first, so the text ends up above it.
        const after_picture = win32.deferRaiseTopmost(hdwp, windows.hwnd) orelse return null;
        return win32.deferRaiseTopmost(after_picture, windows.text_hwnd);
    }

    pub fn hide(self: *HoverZoom) void {
        // Hidden before unregistering, so the window never shows its empty background.
        if (self.windows) |windows| {
            _ = win32.ShowWindow(windows.text_hwnd, win32.SW_HIDE);
            _ = win32.ShowWindow(windows.hwnd, win32.SW_HIDE);
        }
        if (self.thumbnail_id) |id| _ = win32.DwmUnregisterThumbnail(id);
        self.thumbnail_id = null;
        self.source_hwnd = null;
    }

    /// `thumbnail` is null once the zoomed client's thumbnail is gone.
    pub fn hideUnlessHovered(self: *HoverZoom, thumbnail: ?*const ThumbnailWindow) void {
        if (self.source_hwnd == null) return;
        if (thumbnail) |hovered| {
            if (isHovered(hovered)) return;
        }
        self.hide();
    }

    pub fn deinit(self: *HoverZoom) void {
        self.hide();
        if (self.windows) |windows| {
            _ = win32.DestroyWindow(windows.text_hwnd);
            _ = win32.DestroyWindow(windows.hwnd);
        }
        self.windows = null;
        self.render_cache.deinit();
    }

    /// Text keeps the thumbnail's font sizes; only the canvas grows.
    fn drawOverlay(self: *HoverZoom, font_cache: *FontCache, thumbnail: *const ThumbnailWindow, settings: overlay.RenderSettings, config: *const Config) void {
        const windows = self.windows orelse return;
        const width = win32.rectWidth(self.rect);
        const height = win32.rectHeight(self.rect);
        var zoomed = settings;
        zoomed.overlay_width = width;
        zoomed.overlay_height = height;
        // Its measured text is keyed by font only, and nothing clears it on a rename.
        self.render_cache.invalidate();
        overlay.renderOverlay(font_cache, &self.render_cache, windows.text_hwnd, thumbnail, zoomed, config) catch |err| {
            slog.err("Failed to render the hover zoom overlay for '{s}': {}", .{ thumbnail.character_name, err });
            return;
        };
        // Shown only once drawn, so it never flashes the previous zoom's text.
        if (!win32.isWindowVisible(windows.text_hwnd)) {
            _ = win32.SetWindowPos(windows.text_hwnd, win32.HWND_TOPMOST, self.rect.left, self.rect.top, width, height, win32.SWP_NOACTIVATE | win32.SWP_SHOWWINDOW);
        }
    }
};

/// From a mouse move on either of `thumbnail`'s windows (`hwnd`).
pub fn onHover(painter: *Painter, hwnd: win32.HWND, thumbnail: *const ThumbnailWindow) void {
    if (!painter.config.interaction.hoverZoomEnabled or thumbnail_drag.isDragging(thumbnail)) return;

    // Re-armed on every move, since the cursor crosses between the thumbnail and its text overlay.
    if (!win32.trackMouseLeave(hwnd)) slog.debug("Failed to track mouse leave for '{s}'", .{thumbnail.character_name});
    painter.hover_zoom.show(painter.instance, &painter.font_cache, thumbnail, painter.config);
}

/// Also run per tick, since a hidden or moved thumbnail sends no mouse leave.
pub fn check(painter: *Painter) void {
    const source_hwnd = painter.hover_zoom.source_hwnd orelse return;
    const interaction = &painter.config.interaction;
    if (!interaction.hoverZoomEnabled or interaction.clickThrough) return painter.hover_zoom.hide();
    painter.hover_zoom.hideUnlessHovered(painter.getThumbnailBySourceHwnd(source_hwnd));
}

/// Reuses the thumbnail classes, whose input handling these click-through windows never reach.
fn create(instance: win32.HINSTANCE) !Windows {
    const hwnd = try createPopup(instance, window.WINDOW_CLASS_NAME);
    errdefer _ = win32.DestroyWindow(hwnd);
    if (!win32.toBool(win32.SetLayeredWindowAttributes(hwnd, 0, 255, win32.LWA_ALPHA))) return error.SetLayeredWindowAttributesFailed;

    const text_hwnd = try createPopup(instance, window.TEXT_WINDOW_CLASS_NAME);
    return .{ .hwnd = hwnd, .text_hwnd = text_hwnd };
}

/// Click-through, so the thumbnail underneath keeps the mouse and decides when the zoom closes.
fn createPopup(instance: win32.HINSTANCE, class_name: [*:0]const u8) !win32.HWND {
    return win32.CreateWindowExA(
        win32.WS_EX_LAYERED | win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW | win32.WS_EX_NOACTIVATE | win32.WS_EX_TRANSPARENT,
        class_name,
        "",
        win32.WS_POPUP,
        0,
        0,
        0,
        0,
        null,
        null,
        instance,
        null,
    ) orelse error.CreateWindowFailed;
}

fn isHovered(thumbnail: *const ThumbnailWindow) bool {
    if (!win32.isWindowVisible(thumbnail.hwnd) or thumbnail_drag.isDragging(thumbnail)) return false;

    var cursor: win32.POINT = undefined;
    if (!win32.toBool(win32.GetCursorPos(&cursor))) return false;
    var rect: win32.RECT = undefined;
    if (!win32.toBool(win32.GetWindowRect(thumbnail.hwnd, &rect))) return false;
    return win32.rectContains(rect, cursor);
}
