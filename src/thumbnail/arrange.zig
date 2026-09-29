//! Placing, sizing and restyling the thumbnail windows from the running profile.
const win32 = @import("../platform/win32.zig");
const painter_mod = @import("../painter.zig");
const window = @import("window.zig");
const placement = @import("../layout/placement.zig");
const monitors = @import("../layout/monitors.zig");
const scout = @import("../clients/scout.zig");
const log = @import("../log.zig");
const slog = log.scoped("arrange");

const Painter = painter_mod.Painter;
const ThumbnailWindow = window.ThumbnailWindow;
const Size = window.Size;

pub const RegionFit = struct { region: win32.RECT, grid: placement.RegionFitGrid };

/// The RegionFit grid for `count` cells, or null outside RegionFit; the same for every thumbnail in a pass, so compute it once.
pub fn regionFit(painter: *const Painter, count: usize) ?RegionFit {
    const cfg = &painter.config.display;
    if (!placement.isRegionFitActive(cfg)) return null;
    // isRegionFitActive guarantees a region.
    const region = placement.regionRectFromConfig(cfg).?;
    const layout = painter.layout();
    return .{
        .region = region,
        .grid = placement.calculateRegionFitGrid(region, count, cfg.spacing, cfg.spacing, layout.regionFitAspectRatio(), layout.regionFitMaxCellSize(region)),
    };
}

/// Grid-fit sizes (RegionFit's or the not-logged-in space's) are already physical pixels; only a plain default or per-character size is DPI-scaled.
pub fn targetSize(painter: *const Painter, character_name: []const u8, count: usize, grid: ?placement.RegionFitGrid, scale: f32) Size {
    const cfg = &painter.config.display;
    const size = painter.layout().getThumbnailSize(character_name, count, grid);
    if (placement.isRegionFitActive(cfg) or placement.isCarvedOutOfRegionFit(cfg, character_name)) return .{ .width = size.width, .height = size.height };
    return .{ .width = win32.scalePixels(size.width, scale), .height = win32.scalePixels(size.height, scale) };
}

/// RegionFit and the not-logged-in space size every cell from the thumbnail count, so any arrival or departure reflows them all.
pub fn hasCountDependentLayout(painter: *const Painter) bool {
    return placement.isRegionFitActive(&painter.config.display) or placement.notLoggedInSpaceRectFromConfig(&painter.config.display) != null;
}

/// After a rank or count change (bulk create loops, group membership); no-op outside RegionFit.
pub fn reflowIfRegionFitActive(painter: *Painter) void {
    if (placement.isRegionFitActive(&painter.config.display)) repositionAll(painter);
}

/// Resizes a thumbnail to its configured size if it differs. Pass `grid` when calling for every thumbnail in a batch (see getThumbnailSize).
pub fn resizeIfNeeded(painter: *Painter, thumbnail: *ThumbnailWindow, grid: ?placement.RegionFitGrid) void {
    const scale = win32.dpiToScale(monitors.getWindowDpi(thumbnail.hwnd));
    const target = targetSize(painter, thumbnail.character_name, painter.thumbnails.items.len, grid, scale);

    var current: win32.RECT = undefined;
    if (!win32.toBool(win32.GetClientRect(thumbnail.hwnd, &current))) return;
    if (current.right == target.width and current.bottom == target.height) return;
    thumbnail.resize(target);
}

/// Re-applies every thumbnail's config-derived look, visibility and size and redraws it, ignoring needs_render; for the config dialog's live preview.
pub fn refreshVisuals(painter: *Painter) void {
    // Checked here so a live-preview toggle of hideWhenNoEveFocus reacts at once instead of on the next focus change.
    const any_eve_has_focus = painter.isEveWindowForeground();
    const grid = if (regionFit(painter, painter.layout().regionFitGridCount())) |rf| rf.grid else null;

    for (painter.thumbnails.items) |*thumbnail| {
        // Must run for every thumbnail, not just win32_enabled ones: list_view.zig reads these cache fields directly.
        thumbnail.refreshConfigCache(painter.config, &painter.auto_colors);
        painter.refreshGroupBadge(thumbnail);
        // Measured text sizes are cached by font, not text, so a changed display name would keep the old size.
        thumbnail.render_cache.invalidate();

        if (!thumbnail.win32_enabled) continue;

        _ = painter.applyAutoVisibility(thumbnail, any_eve_has_focus);

        // Opacity is otherwise only applied at window creation.
        _ = win32.SetLayeredWindowAttributes(thumbnail.hwnd, 0, thumbnail.cached_opacity, win32.LWA_ALPHA);
        win32.setClickThroughStyle(thumbnail.hwnd, painter.config.interaction.clickThrough);
        win32.setClickThroughStyle(thumbnail.text_hwnd, painter.config.interaction.clickThrough);
        resizeIfNeeded(painter, thumbnail, grid);
        painter.renderThumbnailLogged(thumbnail, "visuals refresh");
    }
}

/// A batched DeferWindowPos sized for both windows of every win32_enabled thumbnail; null if there's nothing to move or it fails.
pub fn beginDefer(painter: *const Painter) ?win32.HDWP {
    var window_count: c_int = 0;
    for (painter.thumbnails.items) |thumbnail| {
        if (thumbnail.win32_enabled) window_count += 2;
    }
    if (window_count == 0) return null;
    return win32.BeginDeferWindowPos(window_count);
}

/// Moves every thumbnail to where the display settings put it. Never writes startX/startY, which can be live-dragged in the running app.
pub fn repositionAll(painter: *Painter) void {
    var hdwp = beginDefer(painter) orelse return;
    const cfg = &painter.config.display;
    const layout = painter.layout();
    const monitor_placement = monitors.resolveMonitorPlacement(cfg);
    const monitor_bounds = if (monitor_placement) |mp| mp.bounds else null;
    const scale = win32.dpiToScale(monitors.dpiForMonitor(if (monitor_placement) |mp| mp.monitor else null));
    const not_logged_in_space = placement.notLoggedInSpaceRectFromConfig(cfg);
    const total_count = painter.thumbnails.items.len;

    // RegionFit fills in configured-order rank, not raw array position; notLoggedInSpace carves its placeholders out of that rank and count entirely.
    const display_order: ?placement.RegionFitDisplayOrder = if (placement.isRegionFitActive(cfg))
        layout.computeRegionFitDisplayOrder(painter.allocator, not_logged_in_space != null) catch |err| blk: {
            slog.warn("Failed to compute RegionFit display order: {}", .{err});
            break :blk null;
        }
    else
        null;
    defer if (display_order) |order| painter.allocator.free(order.ranks);

    const region_fit = regionFit(painter, if (display_order) |order| order.count else total_count);
    const not_logged_in: ?RegionFit = if (not_logged_in_space) |space|
        .{ .region = space, .grid = layout.notLoggedInSpaceGrid(space, layout.notLoggedInSpaceCount()) }
    else
        null;

    for (painter.thumbnails.items, 0..) |thumbnail, index| {
        if (!thumbnail.win32_enabled) continue;
        const carved_out = not_logged_in_space != null and scout.isGenericCharacterName(thumbnail.character_name);

        if (carved_out) {
            const nl = not_logged_in.?;
            const pos = placement.regionFitPositionForGrid(nl.region, nl.grid, layout.notLoggedInIndex(index), cfg.regionFitDirection, cfg.notLoggedInSpaceSpacing);
            // Sized explicitly, since it may still have a previous RegionFit cell's size.
            hdwp = thumbnail.deferPlace(hdwp, pos.x, pos.y, .{ .width = nl.grid.cell_width, .height = nl.grid.cell_height }) orelse return;
        } else if (region_fit) |rf| {
            const rank = if (display_order) |order| order.ranks[index] else index;
            const pos = placement.regionFitPositionForGrid(rf.region, rf.grid, rank, cfg.regionFitDirection, cfg.spacing);
            hdwp = thumbnail.deferPlace(hdwp, pos.x, pos.y, .{ .width = rf.grid.cell_width, .height = rf.grid.cell_height }) orelse return;
        } else {
            const size = targetSize(painter, thumbnail.character_name, total_count, null, scale);
            const pos = layout.calculateThumbnailPosition(thumbnail.character_name, size.width, size.height, index, total_count, monitor_bounds, scale);
            hdwp = thumbnail.deferPlace(hdwp, pos.x, pos.y, null) orelse return;
        }
    }
    _ = win32.EndDeferWindowPos(hdwp);

    if (region_fit != null or not_logged_in != null) {
        // Avoids a one-tick delay before the border catches up to the new cell size.
        for (painter.thumbnails.items) |*thumbnail| {
            if (!thumbnail.win32_enabled) continue;
            thumbnail.render_cache.settings = null;
            painter.renderThumbnailLogged(thumbnail, "region fit resize");
        }
    }
}

/// Puts every thumbnail back on top after another app's topmost window took the z-order band.
pub fn reassertTopmost(painter: *Painter) void {
    // Batched so DWM applies the whole z-order change at once, instead of compositing each step and flashing thumbnails.
    var hdwp = beginDefer(painter) orelse return;
    for (painter.thumbnails.items) |thumbnail| {
        if (!thumbnail.win32_enabled) continue;
        hdwp = win32.DeferWindowPos(hdwp, thumbnail.hwnd, win32.HWND_TOPMOST, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE) orelse return;
        hdwp = win32.DeferWindowPos(hdwp, thumbnail.text_hwnd, win32.HWND_TOPMOST, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE) orelse return;
    }
    _ = win32.EndDeferWindowPos(hdwp);
}
