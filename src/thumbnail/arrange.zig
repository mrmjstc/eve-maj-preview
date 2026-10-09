//! Placing, sizing and restyling the thumbnail windows from the running profile.
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const painter_mod = @import("../painter.zig");
const window = @import("window.zig");
const placement = @import("../layout/placement.zig");
const spaces = @import("../layout/spaces.zig");
const monitors = @import("../layout/monitors.zig");
const log = @import("../log.zig");
const slog = log.scoped("arrange");

const Painter = painter_mod.Painter;
const ThumbnailWindow = window.ThumbnailWindow;
const Size = window.Size;

pub const Place = struct { pos: config_mod.Position, size: Size };

/// Every active space's grid for the current thumbnails.
pub fn spaceCells(painter: *const Painter) placement.SpaceCells {
    const layout = painter.layout();
    return layout.spaceCells(&layout.spaceCounts());
}

/// A space's cell is already physical pixels; only a hand-placed thumbnail's configured size is DPI-scaled.
pub fn targetSize(painter: *const Painter, character_name: []const u8, cells: *const placement.SpaceCells, scale: f32) Size {
    if (placement.cellFor(painter.config, cells, character_name)) |cell| return cellSize(cell);
    return handPlacedSize(painter, character_name, scale);
}

/// Where a thumbnail not yet in the list goes: the end of its space until the reflow that follows ranks it, else its hand-placed spot.
pub fn newPlace(painter: *const Painter, character_name: []const u8, monitor_bounds: ?win32.RECT, scale: f32) Place {
    const layout = painter.layout();
    if (spaces.spaceFor(painter.config, character_name)) |space_index| {
        var counts = layout.spaceCounts();
        counts[space_index] += 1;
        if (layout.spaceCells(&counts)[space_index]) |cell| {
            return .{ .pos = cell.position(counts[space_index] - 1), .size = cellSize(cell) };
        }
    }
    const size = handPlacedSize(painter, character_name, scale);
    return .{ .pos = layout.calculateThumbnailPosition(character_name, size.width, size.height, painter.thumbnails.items.len, monitor_bounds, scale), .size = size };
}

/// Spaces size every cell from how many thumbnails they hold, so any arrival or departure reflows them all.
pub fn hasCountDependentLayout(painter: *const Painter) bool {
    return spaces.anyActive(painter.config);
}

/// After a change to who goes where or how big the cells are: membership, ranks, counts or the thumbnail size; no-op while no space is active.
pub fn reflowIfSpacesActive(painter: *Painter) void {
    if (spaces.anyActive(painter.config)) repositionAll(painter);
}

/// Pass `cells` when resizing every thumbnail in a batch.
pub fn resizeIfNeeded(painter: *Painter, thumbnail: *ThumbnailWindow, cells: ?*const placement.SpaceCells) void {
    var fresh: placement.SpaceCells = undefined;
    const current_cells = cells orelse blk: {
        fresh = spaceCells(painter);
        break :blk &fresh;
    };
    const target = targetSize(painter, thumbnail.character_name, current_cells, windowScale(thumbnail));

    var current: win32.RECT = undefined;
    if (!win32.toBool(win32.GetClientRect(thumbnail.hwnd, &current))) return;
    if (current.right == target.width and current.bottom == target.height) return;
    thumbnail.resize(target);
}

/// Re-reads every thumbnail's config-derived settings, e.g. whether it's hidden; for the config dialog's live preview, before the reflow and refreshVisuals.
pub fn refreshConfigCaches(painter: *Painter) void {
    // Every thumbnail, not just win32_enabled ones: list_view.zig reads these cache fields directly.
    for (painter.thumbnails.items) |*thumbnail| {
        thumbnail.refreshConfigCache(painter.config, &painter.auto_colors);
        painter.refreshGroupBadge(thumbnail);
        // Measured text sizes are cached by font, not text, so a changed display name would keep the old size.
        thumbnail.render_cache.invalidate();
    }
}

/// Re-applies every thumbnail's visibility and size and redraws it, ignoring needs_render; for the config dialog's live preview, after refreshConfigCaches.
pub fn refreshVisuals(painter: *Painter) void {
    // Checked here so a live-preview toggle of the focus auto-hide reacts at once instead of on the next focus change.
    const any_eve_has_focus = painter.isEveWindowForeground();
    const cells = spaceCells(painter);

    for (painter.thumbnails.items) |*thumbnail| {
        // Before the skip too: the client list shows tracking-only entries by their visibility.
        _ = painter.applyAutoVisibility(thumbnail, any_eve_has_focus);

        if (!thumbnail.win32_enabled) continue;

        // Opacity is otherwise only applied at window creation.
        _ = win32.SetLayeredWindowAttributes(thumbnail.hwnd, 0, thumbnail.cached_opacity, win32.LWA_ALPHA);
        win32.setClickThroughStyle(thumbnail.hwnd, painter.config.interaction.clickThrough);
        win32.setClickThroughStyle(thumbnail.text_hwnd, painter.config.interaction.clickThrough);
        resizeIfNeeded(painter, thumbnail, &cells);
        painter.renderThumbnailLogged(thumbnail, "visuals refresh");
    }
}

/// Sized for every win32_enabled thumbnail's two windows plus the hover zoom's; null if there's nothing to move or it fails.
pub fn beginDefer(painter: *const Painter) ?win32.HDWP {
    var window_count: c_int = 0;
    for (painter.thumbnails.items) |thumbnail| {
        if (thumbnail.win32_enabled) window_count += 2;
    }
    if (window_count == 0) return null;
    return win32.BeginDeferWindowPos(window_count + 2);
}

/// Moves every thumbnail to where the display settings put it. Never writes startX/startY, which can be live-dragged in the running app.
pub fn repositionAll(painter: *Painter) void {
    var assignment = assignSpaces(painter) catch |err| {
        slog.err("Failed to assign thumbnails to their spaces: {}", .{err});
        return;
    };
    defer assignment.deinit(painter.allocator);

    var hdwp = beginDefer(painter) orelse return;
    const layout = painter.layout();
    const monitor_placement = monitors.resolveMonitorPlacement(&painter.config.display);
    const monitor_bounds = if (monitor_placement) |mp| mp.bounds else null;
    const scale = win32.dpiToScale(monitors.dpiForMonitor(if (monitor_placement) |mp| mp.monitor else null));
    const cells = layout.spaceCells(&assignment.counts);

    for (painter.thumbnails.items, assignment.space_of, assignment.rank, 0..) |thumbnail, space_of, rank, index| {
        if (!thumbnail.win32_enabled) continue;
        // Hidden before it moves, or it shows at its new place until the next render hides it.
        if (thumbnail.cached_hide_thumbnail) thumbnail.show(false);
        if (space_of) |space_index| if (cells[space_index]) |cell| {
            const pos = cell.position(rank);
            hdwp = thumbnail.deferPlace(hdwp, pos.x, pos.y, cellSize(cell)) orelse return;
            continue;
        };
        // Sized too, since it may still have a space cell's size from before it left that space.
        const size = handPlacedSize(painter, thumbnail.character_name, windowScale(&thumbnail));
        const pos = layout.calculateThumbnailPosition(thumbnail.character_name, size.width, size.height, index, monitor_bounds, scale);
        hdwp = thumbnail.deferPlace(hdwp, pos.x, pos.y, size) orelse return;
    }
    hdwp = painter.hover_zoom.deferRaise(hdwp) orelse return;
    _ = win32.EndDeferWindowPos(hdwp);

    if (spaces.anyActive(painter.config)) {
        // Avoids a one-tick delay before the border catches up to the new cell size.
        for (painter.thumbnails.items) |*thumbnail| {
            if (!thumbnail.win32_enabled) continue;
            thumbnail.render_cache.settings = null;
            painter.renderThumbnailLogged(thumbnail, "space resize");
        }
    }
}


/// Puts every thumbnail back on top after another app's topmost window took the z-order band.
pub fn reassertTopmost(painter: *Painter) void {
    // Batched so DWM applies the whole z-order change at once, instead of compositing each step and flashing thumbnails.
    var hdwp = beginDefer(painter) orelse return;
    for (painter.thumbnails.items) |thumbnail| {
        if (!thumbnail.win32_enabled) continue;
        hdwp = win32.deferRaiseTopmost(hdwp, thumbnail.hwnd) orelse return;
        hdwp = win32.deferRaiseTopmost(hdwp, thumbnail.text_hwnd) orelse return;
    }
    hdwp = painter.hover_zoom.deferRaise(hdwp) orelse return;
    _ = win32.EndDeferWindowPos(hdwp);
}

/// Caller frees with Assignment.deinit.
fn assignSpaces(painter: *const Painter) !spaces.Assignment {
    const names = try painter.allocator.alloc([]const u8, painter.thumbnails.items.len);
    defer painter.allocator.free(names);
    for (painter.thumbnails.items, names) |thumbnail, *name| name.* = thumbnail.character_name;
    return spaces.assign(painter.allocator, painter.config, names);
}

fn cellSize(cell: placement.SpaceCell) Size {
    return .{ .width = cell.grid.cell_width, .height = cell.grid.cell_height };
}

fn handPlacedSize(painter: *const Painter, character_name: []const u8, scale: f32) Size {
    const size = painter.config.handPlacedSize(character_name);
    return .{ .width = win32.scalePixels(size.width, scale), .height = win32.scalePixels(size.height, scale) };
}

fn windowScale(thumbnail: *const ThumbnailWindow) f32 {
    return win32.dpiToScale(monitors.getWindowDpi(thumbnail.hwnd));
}
