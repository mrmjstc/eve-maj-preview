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

/// A window being dragged, where it would land unsnapped.
pub const Drag = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    /// Never snapped to itself.
    hwnd: win32.HWND,

    fn movedTo(self: Drag, snapped: SnapPosition) Drag {
        var moved = self;
        moved.x = snapped.x;
        moved.y = snapped.y;
        return moved;
    }

    fn position(self: Drag) SnapPosition {
        return .{ .x = self.x, .y = self.y };
    }
};

/// For a thumbnail: screen edges, then thumbnail edges, then panel edges, then ghost positions, each snapping the previous result.
pub fn applySnapping(thumbnail_set: *ThumbnailSet, drag: Drag) SnapPosition {
    const settings = &thumbnail_set.config.snapping;
    if (!settings.enabled) return drag.position();
    const snapped = snapToEdges(thumbnail_set, settings, drag);
    if (!settings.ghostPositions) return snapped;
    return applyGhostSnapping(thumbnail_set, drag.movedTo(snapped), settings.threshold);
}

/// Like applySnapping for a panel, by the panels' own settings and without ghost positions.
pub fn applyPanelSnapping(thumbnail_set: *const ThumbnailSet, drag: Drag) SnapPosition {
    const settings = &thumbnail_set.config.panelSnapping;
    if (!settings.enabled) return drag.position();
    return snapToEdges(thumbnail_set, settings, drag);
}

pub fn applyScreenEdgeSnapping(drag: Drag, threshold: i32) SnapPosition {
    return snap_math.screenEdges(drag.x, drag.y, drag.width, drag.height, threshold, monitors.nearestMonitorBounds(drag.hwnd).bounds);
}

/// Screen edges, then thumbnail edges, then panel edges, as `settings` (a SnappingConfig or PanelSnappingConfig) turns each on.
fn snapToEdges(thumbnail_set: *const ThumbnailSet, settings: anytype, drag: Drag) SnapPosition {
    const threshold = settings.threshold;
    var result = drag.position();
    if (settings.screenEdges) result = applyScreenEdgeSnapping(drag.movedTo(result), threshold);
    if (settings.thumbnailEdges) result = applyThumbnailEdgeSnapping(thumbnail_set, drag.movedTo(result), threshold);
    if (settings.panelEdges) result = applyPanelEdgeSnapping(drag.movedTo(result), threshold);
    return result;
}

fn applyThumbnailEdgeSnapping(thumbnail_set: *const ThumbnailSet, drag: Drag, threshold: i32) SnapPosition {
    var snap: snap_math.EdgeSnap = .init(drag.x, drag.y, drag.width, drag.height, threshold);
    for (thumbnail_set.thumbnails.items) |thumbnail| {
        if (thumbnail.hwnd == drag.hwnd or thumbnail.text_hwnd == drag.hwnd) continue;
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
fn applyPanelEdgeSnapping(drag: Drag, threshold: i32) SnapPosition {
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

    var context: Context = .{ .snap = .init(drag.x, drag.y, drag.width, drag.height, threshold), .dragging_hwnd = drag.hwnd };
    _ = win32.EnumThreadWindows(win32.GetCurrentThreadId(), Context.visit, win32.ptrToLparam(&context));
    return context.snap.position();
}

/// Docks onto a saved position within `threshold` px (Chebyshev), then aligns edges against the ghosts.
fn applyGhostSnapping(thumbnail_set: *ThumbnailSet, drag: Drag, threshold: i32) SnapPosition {
    const character_name = if (thumbnail_set.getThumbnailByOverlayHwnd(drag.hwnd)) |t| t.character_name else "";

    // A drag without outlines has no cached groups, so it gets an uncached copy.
    var owned_fallback: ?[]GhostGroup = null;
    defer if (owned_fallback) |fallback| ghost_groups.freeGroups(thumbnail_set.allocator, fallback);

    const groups: []const GhostGroup = thumbnail_set.dragGhostGroups() orelse blk: {
        const fresh = ghost_groups.collect(thumbnail_set.allocator, thumbnail_set.config, character_name) catch |err| {
            slog.warn("Failed to collect ghost positions to snap to: {}", .{err});
            return drag.position();
        };
        owned_fallback = fresh;
        break :blk fresh;
    };

    var dock: snap_math.Dock = .init(drag.x, drag.y, threshold);
    for (groups) |group| dock.consider(group.rect);

    var snap: snap_math.EdgeSnap = .init(dock.position.x, dock.position.y, drag.width, drag.height, threshold);
    for (groups) |group| snap.toward(group.rect);
    return snap.position();
}
