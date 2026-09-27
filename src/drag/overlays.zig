const std = @import("std");
const win32 = @import("../platform/win32.zig");
const color_mod = @import("../util/color.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const log = @import("../log.zig");
const slog = log.scoped("drag_overlays");
const painter_mod = @import("../painter.zig");
const draw = @import("../thumbnail/draw.zig");
const monitors = @import("../layout/monitors.zig");
const placement = @import("../layout/placement.zig");

const Painter = painter_mod.Painter;

const WINDOW_CLASS_NAME = "EVE_GHOST_OVERLAY_CLASS";

/// One saved-position outline for the drag-time ghost overlay; `names` is the comma-joined list of every character sharing that exact rect.
pub const GhostGroup = struct {
    rect: win32.RECT,
    names: []const u8,
};

fn ghostRectsEqual(a: win32.RECT, b: win32.RECT) bool {
    return a.left == b.left and a.top == b.top and a.right == b.right and a.bottom == b.bottom;
}

/// Saved positions for every other character in the profile, grouped by exact rect match (identical x/y/w/h counts as "stacked"). Caller owns the returned slice and each group's `names`.
pub fn collectGhostGroups(painter: *const Painter, exclude_character: []const u8) ![]GhostGroup {
    const allocator = painter.allocator;
    const RawEntry = struct { name: []const u8, rect: win32.RECT };

    var raw = std.ArrayList(RawEntry).empty;
    defer raw.deinit(allocator);

    const cfg = &painter.config.display;
    const region_fit_grid: ?placement.RegionFitGrid = if (placement.isRegionFitActive(cfg)) blk: {
        const region = placement.regionRectFromConfig(cfg).?;
        break :blk placement.calculateRegionFitGrid(region, painter.layout().regionFitGridCount(), cfg.spacing, cfg.spacing, painter.layout().regionFitAspectRatio(), painter.layout().regionFitMaxCellSize(region));
    } else null;

    for (painter.config.characters.items) |char_config| {
        if (std.mem.eql(u8, char_config.name, exclude_character)) continue;
        const pos = char_config.position orelse continue;
        const size = painter.layout().getThumbnailSize(char_config.name, painter.thumbnails.items.len, region_fit_grid);
        try raw.append(allocator, .{
            .name = char_config.name,
            .rect = .{ .left = pos.x, .top = pos.y, .right = pos.x + size.width, .bottom = pos.y + size.height },
        });
    }

    var groups = std.ArrayList(GhostGroup).empty;
    errdefer {
        for (groups.items) |g| allocator.free(g.names);
        groups.deinit(allocator);
    }

    const used = try allocator.alloc(bool, raw.items.len);
    defer allocator.free(used);
    @memset(used, false);

    for (raw.items, 0..) |entry, i| {
        if (used[i]) continue;
        used[i] = true;

        var names = std.ArrayList(u8).empty;
        defer names.deinit(allocator);
        try names.appendSlice(allocator, entry.name);

        for (raw.items[i + 1 ..], i + 1..) |other, j| {
            if (used[j] or !ghostRectsEqual(entry.rect, other.rect)) continue;
            used[j] = true;
            try names.appendSlice(allocator, ", ");
            try names.appendSlice(allocator, other.name);
        }

        try groups.append(allocator, .{ .rect = entry.rect, .names = try names.toOwnedSlice(allocator) });
    }

    return groups.toOwnedSlice(allocator);
}

pub fn registerWindowClass(instance: win32.HINSTANCE) !void {
    try gdi_overlay.registerWindowClass(instance, win32.DefWindowProcA, WINDOW_CLASS_NAME, null);
}

/// A topmost, click-through overlay outlining every other saved position while a thumbnail or panel is dragged. Created lazily, hidden (not destroyed) between drags.
pub const GhostOverlay = struct {
    allocator: std.mem.Allocator,
    hwnd: ?win32.HWND = null,
    bitmap: ?gdi_overlay.OverlayBitmap = null,
    /// Computed once by show at drag-start; applyGhostSnapping reuses this for the rest of the drag instead of recomputing on every mouse move. Null while the overlay is hidden.
    groups: ?[]GhostGroup = null,

    pub fn init(allocator: std.mem.Allocator) GhostOverlay {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GhostOverlay) void {
        self.clearGroups();
        if (self.bitmap) |bitmap| bitmap.destroy();
        if (self.hwnd) |hwnd| _ = win32.DestroyWindow(hwnd);
    }

    /// Frees the groups populated by show (if any). Called on every exit path (hide, deinit) plus defensively at the start of show, so applyGhostSnapping never reads a stale slice.
    fn clearGroups(self: *GhostOverlay) void {
        if (self.groups) |groups| {
            for (groups) |g| self.allocator.free(g.names);
            self.allocator.free(groups);
            self.groups = null;
        }
    }

    /// Shows (creating on first use) a topmost, click-through overlay outlining every other saved position in the profile; called once when a drag starts. Ghosts are static for the duration of the drag, so the computed groups are cached for snapping.zig's applyGhostSnapping to reuse (see groups).
    pub fn show(self: *GhostOverlay, painter: *Painter, exclude_character: []const u8) void {
        self.clearGroups();

        const groups = collectGhostGroups(painter, exclude_character) catch |err| {
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
                painter.instance,
                null,
            ) orelse {
                slog.err("Failed to create ghost overlay window", .{});
                return;
            };
        }

        const hwnd = self.hwnd.?;

        if (gdi_overlay.OverlayBitmap.needsResize(self.bitmap, width, height)) {
            const init_dc = win32.GetDC(null) orelse return;
            defer _ = win32.ReleaseDC(null, init_dc);
            gdi_overlay.OverlayBitmap.recreate(&self.bitmap, init_dc, width, height) catch |err| {
                slog.err("Failed to allocate ghost overlay bitmap: {}", .{err});
                return;
            };
        }

        const overlay = &self.bitmap.?;
        overlay.clear();

        const font = painter.font_cache.characterNameFont(&painter.config.thumbnail, monitors.getWindowDpi(hwnd)) catch |err| {
            slog.err("Failed to get font for ghost overlay: {}", .{err});
            return;
        };
        const old_font = win32.SelectObject(overlay.mem_dc, font);
        defer {
            if (old_font) |of| _ = win32.SelectObject(overlay.mem_dc, of);
        }

        // Same hue as the focused/active thumbnail border, at reduced alpha so it still reads as a ghost rather than a real thumbnail.
        const outline_color: u32 = color_mod.withAlpha(painter.config.thumbnail.borderColor, 0xB0);
        const text_color: u32 = 0xE0FFFFFF;

        for (groups) |group| {
            const local_x = group.rect.left - bounds.left;
            const local_y = group.rect.top - bounds.top;
            const rect_w: usize = @intCast(group.rect.right - group.rect.left);
            const rect_h: usize = @intCast(group.rect.bottom - group.rect.top);

            gdi_overlay.drawRectOutline(overlay.pixels, overlay.width, overlay.height, local_x, local_y, rect_w, rect_h, 2, outline_color);

            const dims = draw.measureText(overlay.mem_dc, group.names);
            draw.renderText(overlay.mem_dc, group.names, local_x, local_y, text_color);
            gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, local_x, local_y, dims.width, dims.height);
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

/// Hint box centered on the monitor nearest `dragging_hwnd`; called once when a drag starts, static for its duration.
pub fn showDragHint(painter: *Painter, dragging_hwnd: win32.HWND) void {
    const nearest = monitors.nearestMonitorBounds(dragging_hwnd);
    const font = painter.font_cache.characterNameFont(&painter.config.thumbnail, monitors.dpiForMonitor(nearest.monitor)) catch |err| {
        slog.err("Failed to get font for drag hint: {}", .{err});
        return;
    };
    painter.hint_box.show(painter.instance, font, painter.config.thumbnail.characterNameColor | 0xFF000000, "Hold Ctrl to move all thumbnails together", "Turn off dragging from the tray icon or settings", nearest.bounds);
}
