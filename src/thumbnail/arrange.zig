//! Placing, sizing and restyling the thumbnail windows from the running profile.
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const set = @import("set.zig");
const window = @import("window.zig");
const placement = @import("../layout/placement.zig");
const spaces = @import("../layout/spaces.zig");
const monitors = @import("../layout/monitors.zig");
const log = @import("../log.zig");

const ThumbnailSet = set.ThumbnailSet;
const ThumbnailWindow = window.ThumbnailWindow;
const Size = window.Size;
const slog = log.Scoped("arrange");

pub const Place = struct { position: config_mod.Position, size: Size };

/// The end of its space until the next reflow ranks it, else its hand-placed spot.
pub fn newPlace(thumbnail_set: *const ThumbnailSet, character_name: []const u8, monitor_bounds: ?win32.RECT, scale: f32) Place {
    const layout = thumbnail_set.layout();
    if (spaces.spaceFor(thumbnail_set.config, character_name)) |space_index| {
        var counts = layout.spaceCounts();
        counts[space_index] += 1;
        if (layout.spaceCells(&counts)[space_index]) |cell| {
            return .{ .position = cell.position(counts[space_index] - 1), .size = cellSize(cell) };
        }
    }
    const size = handPlacedSize(thumbnail_set, character_name, scale);
    return .{ .position = layout.calculateThumbnailPosition(character_name, size.width, size.height, thumbnail_set.thumbnails.items.len, monitor_bounds, scale), .size = size };
}

/// Spaces size every cell from how many thumbnails they hold, so any arrival or departure reflows them all.
pub fn hasCountDependentLayout(thumbnail_set: *const ThumbnailSet) bool {
    return spaces.anyActive(thumbnail_set.config);
}

/// After a change to space membership, ranks, counts or thumbnail size.
pub fn reflowIfSpacesActive(thumbnail_set: *ThumbnailSet) void {
    if (spaces.anyActive(thumbnail_set.config)) repositionAll(thumbnail_set);
}

/// Pass `cells` when resizing every thumbnail in a batch.
pub fn resizeIfNeeded(thumbnail_set: *ThumbnailSet, thumbnail: *ThumbnailWindow, cells: ?*const placement.SpaceCells) void {
    var fresh: placement.SpaceCells = undefined;
    const current_cells = cells orelse blk: {
        fresh = spaceCells(thumbnail_set);
        break :blk &fresh;
    };
    const target = targetSize(thumbnail_set, thumbnail.character_name, current_cells, windowScale(thumbnail));

    var current: win32.RECT = undefined;
    if (!win32.toBool(win32.GetClientRect(thumbnail.hwnd, &current))) {
        slog.warn("Failed to read the size of '{s}' to resize it", .{thumbnail.character_name});
        return;
    }
    if (current.right == target.width and current.bottom == target.height) return;
    thumbnail.resize(target);
}

/// For the dialog's live preview, before the reflow and refreshVisuals.
pub fn refreshConfigCaches(thumbnail_set: *ThumbnailSet) void {
    // Every thumbnail, not just is_win32_enabled ones: list_view.zig reads these cache fields directly.
    for (thumbnail_set.thumbnails.items) |*thumbnail| {
        thumbnail.refreshConfigCache(thumbnail_set.config, &thumbnail_set.auto_colors);
        thumbnail_set.refreshGroupBadge(thumbnail);
        // Measured text sizes are cached by font, not text, so a changed display name would keep the old size.
        thumbnail.render_cache.invalidate();
    }
}

/// Ignores needs_render; for the dialog's live preview, after refreshConfigCaches.
pub fn refreshVisuals(thumbnail_set: *ThumbnailSet) void {
    // So a live auto-hide toggle reacts now, not on the next focus change.
    const any_eve_has_focus = thumbnail_set.isEveWindowForeground();
    const cells = spaceCells(thumbnail_set);

    for (thumbnail_set.thumbnails.items) |*thumbnail| {
        // Before the skip too: the client list shows tracking-only entries by their visibility.
        _ = thumbnail_set.applyAutoVisibility(thumbnail, any_eve_has_focus);

        if (!thumbnail.is_win32_enabled) continue;

        // Opacity is otherwise only applied at window creation.
        _ = win32.SetLayeredWindowAttributes(thumbnail.hwnd, 0, thumbnail.cached_opacity, win32.LWA_ALPHA);
        win32.setClickThroughStyle(thumbnail.hwnd, thumbnail_set.config.interaction.clickThrough);
        win32.setClickThroughStyle(thumbnail.text_hwnd, thumbnail_set.config.interaction.clickThrough);
        resizeIfNeeded(thumbnail_set, thumbnail, &cells);
        thumbnail_set.renderThumbnailLogged(thumbnail, "visuals refresh");
    }
}

/// Null if there's nothing to move or it fails.
pub fn beginDefer(thumbnail_set: *const ThumbnailSet) ?win32.HDWP {
    var window_count: c_int = 0;
    for (thumbnail_set.thumbnails.items) |thumbnail| {
        if (thumbnail.is_win32_enabled) window_count += 2;
    }
    if (window_count == 0) return null;
    return win32.BeginDeferWindowPos(window_count + 2);
}

/// Never writes startX/startY, which can be live-dragged in the running app.
pub fn repositionAll(thumbnail_set: *ThumbnailSet) void {
    var assignment = assignSpaces(thumbnail_set) catch |err| {
        slog.err("Failed to assign thumbnails to their spaces: {}", .{err});
        return;
    };
    defer assignment.deinit(thumbnail_set.allocator);

    var hdwp = beginDefer(thumbnail_set) orelse return;
    const layout = thumbnail_set.layout();
    const monitor_placement = monitors.resolveMonitorPlacement(&thumbnail_set.config.display);
    const monitor_bounds = if (monitor_placement) |mp| mp.bounds else null;
    const scale = win32.dpiToScale(monitors.dpiForMonitor(if (monitor_placement) |mp| mp.monitor else null));
    const cells = layout.spaceCells(&assignment.counts);

    for (thumbnail_set.thumbnails.items, assignment.space_indices, assignment.rank, 0..) |thumbnail, assigned_space, rank, index| {
        if (!thumbnail.is_win32_enabled) continue;
        // Hidden before it moves, or it shows at its new place until the next render hides it.
        if (thumbnail.cached_hide_thumbnail) thumbnail.show(false);
        if (assigned_space) |space_index| {
            if (cells[space_index]) |cell| {
                const position = cell.position(rank);
                hdwp = thumbnail.deferPlace(hdwp, position.x, position.y, cellSize(cell)) orelse return;
                continue;
            }
        }
        // Sized too, since it may still have a space cell's size from before it left that space.
        const size = handPlacedSize(thumbnail_set, thumbnail.character_name, windowScale(&thumbnail));
        const position = layout.calculateThumbnailPosition(thumbnail.character_name, size.width, size.height, index, monitor_bounds, scale);
        hdwp = thumbnail.deferPlace(hdwp, position.x, position.y, size) orelse return;
    }
    hdwp = thumbnail_set.renderer.hover_zoom.deferRaise(hdwp) orelse return;
    _ = win32.EndDeferWindowPos(hdwp);

    if (spaces.anyActive(thumbnail_set.config)) {
        // Avoids a one-tick delay before the border catches up to the new cell size.
        for (thumbnail_set.thumbnails.items) |*thumbnail| {
            if (!thumbnail.is_win32_enabled) continue;
            thumbnail.render_cache.settings = null;
            thumbnail_set.renderThumbnailLogged(thumbnail, "space resize");
        }
    }
}

/// Puts every thumbnail back on top after another app's topmost window took the z-order band.
pub fn reassertTopmost(thumbnail_set: *ThumbnailSet) void {
    // Batched so DWM doesn't composite each step and flash thumbnails.
    var hdwp = beginDefer(thumbnail_set) orelse return;
    for (thumbnail_set.thumbnails.items) |thumbnail| {
        if (!thumbnail.is_win32_enabled) continue;
        hdwp = win32.deferRaiseTopmost(hdwp, thumbnail.hwnd) orelse return;
        hdwp = win32.deferRaiseTopmost(hdwp, thumbnail.text_hwnd) orelse return;
    }
    hdwp = thumbnail_set.renderer.hover_zoom.deferRaise(hdwp) orelse return;
    _ = win32.EndDeferWindowPos(hdwp);
}

fn spaceCells(thumbnail_set: *const ThumbnailSet) placement.SpaceCells {
    const layout = thumbnail_set.layout();
    return layout.spaceCells(&layout.spaceCounts());
}

/// A space's cell is already physical pixels; only a hand-placed thumbnail's configured size is DPI-scaled.
fn targetSize(thumbnail_set: *const ThumbnailSet, character_name: []const u8, cells: *const placement.SpaceCells, scale: f32) Size {
    if (placement.cellFor(thumbnail_set.config, cells, character_name)) |cell| return cellSize(cell);
    return handPlacedSize(thumbnail_set, character_name, scale);
}

/// Caller frees with Assignment.deinit.
fn assignSpaces(thumbnail_set: *const ThumbnailSet) !spaces.Assignment {
    const names = try thumbnail_set.allocator.alloc([]const u8, thumbnail_set.thumbnails.items.len);
    defer thumbnail_set.allocator.free(names);
    for (thumbnail_set.thumbnails.items, names) |thumbnail, *name| name.* = thumbnail.character_name;
    return spaces.assign(thumbnail_set.allocator, thumbnail_set.config, names);
}

fn cellSize(cell: placement.SpaceCell) Size {
    return .{ .width = cell.grid.cell_width, .height = cell.grid.cell_height };
}

fn handPlacedSize(thumbnail_set: *const ThumbnailSet, character_name: []const u8, scale: f32) Size {
    const size = thumbnail_set.config.handPlacedSize(character_name);
    return .{ .width = win32.scalePixels(size.width, scale), .height = win32.scalePixels(size.height, scale) };
}

fn windowScale(thumbnail: *const ThumbnailWindow) f32 {
    return win32.dpiToScale(monitors.getWindowDpi(thumbnail.hwnd));
}
