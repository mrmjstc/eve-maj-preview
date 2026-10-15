//! Draws a thumbnail's overlay, and the hover zoom's copy of it, skipping a redraw when nothing it shows has changed.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const window = @import("window.zig");
const overlay = @import("overlay.zig");
const font_cache_mod = @import("font_cache.zig");
const hover_zoom_mod = @import("hover_zoom.zig");

const Config = config_mod.Config;
const ThumbnailWindow = window.ThumbnailWindow;

/// The fonts every overlay draws with, and the hover zoom, whose text is redrawn whenever its thumbnail's is.
pub const Renderer = struct {
    font_cache: font_cache_mod.FontCache,
    hover_zoom: hover_zoom_mod.HoverZoom = .{},

    pub fn init(allocator: std.mem.Allocator) Renderer {
        return .{ .font_cache = .init(allocator) };
    }

    pub fn deinit(self: *Renderer) void {
        self.font_cache.deinit();
        self.hover_zoom.deinit();
    }

    /// A no-op outside Thumbnails mode, where the list window draws instead.
    pub fn render(self: *Renderer, config: *const Config, thumbnail: *ThumbnailWindow, active_source_hwnd: ?win32.HWND) !void {
        if (!thumbnail.is_win32_enabled) return;
        const settings = overlay.createRenderSettings(config, thumbnail, active_source_hwnd);

        if (thumbnail.render_cache.settings) |cached| {
            if (overlay.renderSettingsEqual(cached, settings)) return;
            if (overlay.renderSettingsOnlyVisibilityChanged(cached, settings)) {
                thumbnail.show(settings.show_thumbnail);
                thumbnail.render_cache.settings = settings;
                return;
            }
        }

        thumbnail.show(settings.show_thumbnail);
        if (settings.show_thumbnail) {
            try overlay.renderThumbnailOverlay(&self.font_cache, thumbnail, settings, config);
            self.hover_zoom.renderOverlay(&self.font_cache, thumbnail, settings, config);
        }

        thumbnail.render_cache.settings = settings;
    }
};
