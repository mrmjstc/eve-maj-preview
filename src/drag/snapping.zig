//! Snapping a dragged window to screen edges, other thumbnails and saved (ghost) positions.
const win32 = @import("../platform/win32.zig");
const painter_mod = @import("../painter.zig");
const monitors = @import("../layout/monitors.zig");
const overlays = @import("overlays.zig");
const log = @import("../log.zig");

const Painter = painter_mod.Painter;
const GhostGroup = overlays.GhostGroup;
const slog = log.Scoped("drag");

pub const SnapPosition = struct { x: i32, y: i32 };

/// Screen edges, then thumbnail edges, then ghost positions, each snapping the previous result.
pub fn applySnapping(x: i32, y: i32, width: i32, height: i32, dragging_hwnd: win32.HWND) SnapPosition {
    const painter = painter_mod.g_painter_ptr orelse return .{ .x = x, .y = y };
    if (!painter.config.snapping.enabled) return .{ .x = x, .y = y };

    const threshold = painter.config.snapping.threshold;
    var result = SnapPosition{ .x = x, .y = y };

    if (painter.config.snapping.screenEdges) result = applyScreenEdgeSnapping(result.x, result.y, width, height, threshold, dragging_hwnd);
    if (painter.config.snapping.thumbnailEdges) result = applyThumbnailEdgeSnapping(result.x, result.y, width, height, threshold, dragging_hwnd, painter);
    if (painter.config.snapping.ghostPositions) result = applyGhostSnapping(result.x, result.y, width, height, threshold, dragging_hwnd, painter);

    return result;
}

pub fn applyScreenEdgeSnapping(x: i32, y: i32, width: i32, height: i32, threshold: i32, dragging_hwnd: win32.HWND) SnapPosition {
    var snapped_x = x;
    var snapped_y = y;

    const right = x + width;
    const bottom = y + height;

    const bounds = monitors.nearestMonitorBounds(dragging_hwnd).bounds;

    if (@abs(x - bounds.left) < threshold) snapped_x = bounds.left;
    if (@abs(right - bounds.right) < threshold) snapped_x = bounds.right - width;
    if (@abs(y - bounds.top) < threshold) snapped_y = bounds.top;
    if (@abs(bottom - bounds.bottom) < threshold) snapped_y = bounds.bottom - height;

    return .{ .x = snapped_x, .y = snapped_y };
}

/// Moves `snapped_x`/`snapped_y` toward `other_rect`'s nearest edge when it beats the best so far (`min_x_distance`/`min_y_distance`, seeded with the threshold).
fn snapAxesToRect(snapped_x: *i32, snapped_y: *i32, width: i32, height: i32, other_rect: win32.RECT, min_x_distance: *i32, min_y_distance: *i32) void {
    // Recalculated per call, since snapped_x/y may have changed on a prior call in the same loop.
    const snapped_right = snapped_x.* + width;
    const snapped_bottom = snapped_y.* + height;

    // Snapshot the pre-update position so all four candidates measure from the actual window, not one already overwritten this call.
    const original_x = snapped_x.*;
    const original_y = snapped_y.*;

    const other_left = other_rect.left;
    const other_right = other_rect.right;
    const other_top = other_rect.top;
    const other_bottom = other_rect.bottom;

    const overlaps_vertically = !(snapped_bottom < other_top or snapped_y.* > other_bottom);
    if (overlaps_vertically) {
        const distance_ll: i32 = @intCast(@abs(original_x - other_left));
        if (distance_ll <= min_x_distance.*) {
            min_x_distance.* = distance_ll;
            snapped_x.* = other_left;
        }
        const distance_lr: i32 = @intCast(@abs(original_x - other_right));
        if (distance_lr <= min_x_distance.*) {
            min_x_distance.* = distance_lr;
            snapped_x.* = other_right;
        }
        const distance_rl: i32 = @intCast(@abs(snapped_right - other_left));
        if (distance_rl <= min_x_distance.*) {
            min_x_distance.* = distance_rl;
            snapped_x.* = other_left - width;
        }
        const distance_rr: i32 = @intCast(@abs(snapped_right - other_right));
        if (distance_rr <= min_x_distance.*) {
            min_x_distance.* = distance_rr;
            snapped_x.* = other_right - width;
        }
    }

    // Recompute right edge for vertical-snap check: horizontal snapping above may have moved snapped_x.
    const snapped_right_now = snapped_x.* + width;
    const overlaps_horizontally = !(snapped_right_now < other_left or snapped_x.* > other_right);
    if (overlaps_horizontally) {
        const distance_tt: i32 = @intCast(@abs(original_y - other_top));
        if (distance_tt <= min_y_distance.*) {
            min_y_distance.* = distance_tt;
            snapped_y.* = other_top;
        }
        const distance_tb: i32 = @intCast(@abs(original_y - other_bottom));
        if (distance_tb <= min_y_distance.*) {
            min_y_distance.* = distance_tb;
            snapped_y.* = other_bottom;
        }
        const distance_bt: i32 = @intCast(@abs(snapped_bottom - other_top));
        if (distance_bt <= min_y_distance.*) {
            min_y_distance.* = distance_bt;
            snapped_y.* = other_top - height;
        }
        const distance_bb: i32 = @intCast(@abs(snapped_bottom - other_bottom));
        if (distance_bb <= min_y_distance.*) {
            min_y_distance.* = distance_bb;
            snapped_y.* = other_bottom - height;
        }
    }
}

fn applyThumbnailEdgeSnapping(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    threshold: i32,
    dragging_hwnd: win32.HWND,
    painter: *const Painter,
) SnapPosition {
    var snapped_x = x;
    var snapped_y = y;
    var min_x_distance: i32 = threshold;
    var min_y_distance: i32 = threshold;

    for (painter.thumbnails.items) |thumbnail| {
        if (thumbnail.hwnd == dragging_hwnd or thumbnail.text_hwnd == dragging_hwnd) continue;
        if (!win32.isWindow(thumbnail.hwnd)) continue;

        var other_rect: win32.RECT = undefined;
        _ = win32.GetWindowRect(thumbnail.hwnd, &other_rect);

        snapAxesToRect(&snapped_x, &snapped_y, width, height, other_rect, &min_x_distance, &min_y_distance);
    }

    return .{ .x = snapped_x, .y = snapped_y };
}

/// Snaps to a ghost's exact saved position when within `threshold` px (Chebyshev distance), else aligns edges against ghost rects like applyThumbnailEdgeSnapping does for live thumbnails.
fn applyGhostSnapping(x: i32, y: i32, width: i32, height: i32, threshold: i32, dragging_hwnd: win32.HWND, painter: *Painter) SnapPosition {
    // Non-thumbnail draggers (e.g. the notification history panel) own no character, so nothing is excluded from the ghost set.
    const character_name = if (painter.getThumbnailByOverlayHwnd(dragging_hwnd)) |t| t.character_name else "";

    // Reuses GhostOverlay.show's cache; the list view's drag never shows it, so it gets an uncached copy.
    var owned_fallback: ?[]GhostGroup = null;
    defer if (owned_fallback) |fallback| {
        for (fallback) |g| painter.allocator.free(g.names);
        painter.allocator.free(fallback);
    };

    const groups: []const GhostGroup = painter.ghost_overlay.groups orelse blk: {
        const fresh = overlays.collectGhostGroups(painter, character_name) catch |err| {
            slog.warn("Failed to collect ghost positions to snap to: {}", .{err});
            return .{ .x = x, .y = y };
        };
        owned_fallback = fresh;
        break :blk fresh;
    };

    var dock_x = x;
    var dock_y = y;
    var best_distance: i32 = threshold;

    for (groups) |group| {
        const dx: i32 = @intCast(@abs(x - group.rect.left));
        const dy: i32 = @intCast(@abs(y - group.rect.top));
        const distance = @max(dx, dy);
        if (distance <= best_distance) {
            best_distance = distance;
            dock_x = group.rect.left;
            dock_y = group.rect.top;
        }
    }

    var snapped_x = dock_x;
    var snapped_y = dock_y;
    var min_x_distance: i32 = threshold;
    var min_y_distance: i32 = threshold;

    for (groups) |group| {
        snapAxesToRect(&snapped_x, &snapped_y, width, height, group.rect, &min_x_distance, &min_y_distance);
    }

    return .{ .x = snapped_x, .y = snapped_y };
}
