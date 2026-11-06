//! Snapping a dragged window to screen edges, other thumbnails, panels and saved (ghost) positions.
const win32 = @import("../platform/win32.zig");
const panel_window = @import("../platform/panel_window.zig");
const set = @import("../thumbnail/set.zig");
const monitors = @import("../layout/monitors.zig");
const ghost_groups = @import("ghost_groups.zig");
const snap_math = @import("snap_math.zig");
const log = @import("../log.zig");

const ThumbnailSet = set.ThumbnailSet;
const GhostGroup = ghost_groups.GhostGroup;
const slog = log.Scoped("drag");

pub const SnapPosition = snap_math.SnapPosition;

/// For a thumbnail: screen edges, then thumbnail edges, then panel edges, then ghost positions, each snapping the previous result.
pub fn applySnapping(thumbnail_set: *ThumbnailSet, x: i32, y: i32, width: i32, height: i32, dragging_hwnd: win32.HWND) SnapPosition {
    const settings = &thumbnail_set.config.snapping;
    if (!settings.enabled) return .{ .x = x, .y = y };
    const snapped = snapToEdges(thumbnail_set, settings, x, y, width, height, dragging_hwnd);
    if (!settings.ghostPositions) return snapped;
    return applyGhostSnapping(snapped.x, snapped.y, width, height, settings.threshold, dragging_hwnd, thumbnail_set);
}

/// Like applySnapping for a panel, by the panels' own settings and without ghost positions.
pub fn applyPanelSnapping(thumbnail_set: *const ThumbnailSet, x: i32, y: i32, width: i32, height: i32, dragging_hwnd: win32.HWND) SnapPosition {
    const settings = &thumbnail_set.config.panelSnapping;
    if (!settings.enabled) return .{ .x = x, .y = y };
    return snapToEdges(thumbnail_set, settings, x, y, width, height, dragging_hwnd);
}

pub fn applyScreenEdgeSnapping(x: i32, y: i32, width: i32, height: i32, threshold: i32, dragging_hwnd: win32.HWND) SnapPosition {
    return snap_math.screenEdges(x, y, width, height, threshold, monitors.nearestMonitorBounds(dragging_hwnd).bounds);
}

/// Screen edges, then thumbnail edges, then panel edges, as `settings` (a SnappingConfig or PanelSnappingConfig) turns each on.
fn snapToEdges(thumbnail_set: *const ThumbnailSet, settings: anytype, x: i32, y: i32, width: i32, height: i32, dragging_hwnd: win32.HWND) SnapPosition {
    const threshold = settings.threshold;
    var result: SnapPosition = .{ .x = x, .y = y };
    if (settings.screenEdges) result = applyScreenEdgeSnapping(result.x, result.y, width, height, threshold, dragging_hwnd);
    if (settings.thumbnailEdges) result = applyThumbnailEdgeSnapping(result.x, result.y, width, height, threshold, dragging_hwnd, thumbnail_set);
    if (settings.panelEdges) result = applyPanelEdgeSnapping(result.x, result.y, width, height, threshold, dragging_hwnd);
    return result;
}

fn applyThumbnailEdgeSnapping(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    threshold: i32,
    dragging_hwnd: win32.HWND,
    thumbnail_set: *const ThumbnailSet,
) SnapPosition {
    var snap = snap_math.EdgeSnap.init(x, y, width, height, threshold);
    for (thumbnail_set.thumbnails.items) |thumbnail| {
        if (thumbnail.hwnd == dragging_hwnd or thumbnail.text_hwnd == dragging_hwnd) continue;
        if (!win32.isWindow(thumbnail.hwnd)) continue;

        var other_rect: win32.RECT = undefined;
        if (!win32.toBool(win32.GetWindowRect(thumbnail.hwnd, &other_rect))) {
            slog.debug("Skipped snapping to '{s}': its position couldn't be read", .{thumbnail.character_name});
            continue;
        }

        snap.toward(other_rect);
    }
    return snap.position();
}

/// Lines up against the visible panels on this thread, which owns every panel and thumbnail.
fn applyPanelEdgeSnapping(x: i32, y: i32, width: i32, height: i32, threshold: i32, dragging_hwnd: win32.HWND) SnapPosition {
    const Context = struct {
        snap: snap_math.EdgeSnap,
        dragging_hwnd: win32.HWND,

        fn visit(hwnd: win32.HWND, lParam: win32.LPARAM) callconv(.c) win32.BOOL {
            const context = win32.lparamToPtr(@This(), lParam);
            if (hwnd == context.dragging_hwnd or !panel_window.isPanel(hwnd)) return win32.TRUE;
            if (!win32.isWindowVisible(hwnd) or win32.isWindowIconic(hwnd)) return win32.TRUE;
            const other_rect = win32.visibleWindowRect(hwnd) orelse {
                slog.debug("Skipped snapping to a panel: its position couldn't be read", .{});
                return win32.TRUE;
            };
            context.snap.toward(other_rect);
            return win32.TRUE;
        }
    };

    var context: Context = .{ .snap = .init(x, y, width, height, threshold), .dragging_hwnd = dragging_hwnd };
    _ = win32.EnumThreadWindows(win32.GetCurrentThreadId(), Context.visit, win32.ptrToLparam(&context));
    return context.snap.position();
}

/// Snaps to a ghost's exact saved position when within `threshold` px (Chebyshev distance), else aligns edges against ghost rects like applyThumbnailEdgeSnapping does for live thumbnails.
fn applyGhostSnapping(x: i32, y: i32, width: i32, height: i32, threshold: i32, dragging_hwnd: win32.HWND, thumbnail_set: *ThumbnailSet) SnapPosition {
    const character_name = if (thumbnail_set.getThumbnailByOverlayHwnd(dragging_hwnd)) |t| t.character_name else "";

    // Reuses GhostOverlay.show's cache; a drag without outlines never shows it, so it gets an uncached copy.
    var owned_fallback: ?[]GhostGroup = null;
    defer if (owned_fallback) |fallback| ghost_groups.freeGroups(thumbnail_set.allocator, fallback);

    const groups: []const GhostGroup = thumbnail_set.ghost_overlay.groups orelse blk: {
        const fresh = ghost_groups.collect(thumbnail_set.allocator, thumbnail_set.config, character_name) catch |err| {
            slog.warn("Failed to collect ghost positions to snap to: {}", .{err});
            return .{ .x = x, .y = y };
        };
        owned_fallback = fresh;
        break :blk fresh;
    };

    var dock = snap_math.Dock.init(x, y, threshold);
    for (groups) |group| dock.consider(group.rect);

    var snap = snap_math.EdgeSnap.init(dock.position.x, dock.position.y, width, height, threshold);
    for (groups) |group| snap.toward(group.rect);
    return snap.position();
}
