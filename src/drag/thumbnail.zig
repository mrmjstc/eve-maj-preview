//! Right-button drag of a thumbnail and its linked text overlay; holding Ctrl moves every thumbnail together.
const win32 = @import("../platform/win32.zig");
const set = @import("../thumbnail/set.zig");
const snapping = @import("snapping.zig");
const arrange = @import("../thumbnail/arrange.zig");
const spaces = @import("../layout/spaces.zig");
const log = @import("../log.zig");

const ThumbnailSet = set.ThumbnailSet;
const slog = log.Scoped("drag");

const DragState = struct {
    /// Null when no drag is in progress.
    hwnd: ?win32.HWND = null,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
};

var g_drag_state: DragState = .{};

pub fn start(thumbnail_set: *ThumbnailSet, hwnd: win32.HWND, lParam: win32.LPARAM) void {
    if (!thumbnail_set.config.interaction.enableDragging or grabbedThumbnailIsPlaced(thumbnail_set, hwnd)) return;

    thumbnail_set.hideHoverZoom();
    g_drag_state = .{
        .hwnd = hwnd,
        .offset_x = win32.lparamX(lParam),
        .offset_y = win32.lparamY(lParam),
    };

    if (thumbnail_set.getThumbnailByOverlayHwnd(hwnd)) |thumbnail| {
        thumbnail.is_dragged = true;
        thumbnail_set.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render dragging thumbnail for '{s}': {}", .{ thumbnail.character_name, err });
        };
    }
    thumbnail_set.showDragOverlays(hwnd);

    _ = win32.SetCapture(hwnd);
}

/// Saves `thumbnail_hwnd`'s position, whichever of its two windows (`hwnd`) was grabbed.
pub fn end(thumbnail_set: *ThumbnailSet, hwnd: win32.HWND, thumbnail_hwnd: win32.HWND) void {
    if (g_drag_state.hwnd != hwnd) return;
    stop(thumbnail_set);

    if (thumbnail_set.getThumbnailByOverlayHwnd(hwnd)) |thumbnail| {
        thumbnail_set.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render thumbnail after drag for '{s}': {}", .{ thumbnail.character_name, err });
        };
    }

    if (win32.isCtrlPressed()) {
        thumbnail_set.saveAllThumbnailPositions();
    } else {
        thumbnail_set.saveThumbnailPosition(thumbnail_hwnd);
    }
}

pub fn move(thumbnail_set: *ThumbnailSet, hwnd: win32.HWND) void {
    if (g_drag_state.hwnd != hwnd) return;

    if (!win32.isWindow(hwnd)) {
        slog.warn("Window {*} became invalid during drag operation, canceling drag", .{hwnd});
        stop(thumbnail_set);
        return;
    }

    var rect: win32.RECT = undefined;
    if (!win32.toBool(win32.GetWindowRect(hwnd, &rect))) {
        slog.warn("Failed to read the dragged window's position, canceling drag", .{});
        stop(thumbnail_set);
        return;
    }

    // The real cursor, not the message's coordinates, which lag behind a window that's moving under them.
    var cursor: win32.POINT = undefined;
    if (!win32.toBool(win32.GetCursorPos(&cursor))) {
        slog.debug("Failed to get the cursor position while dragging a thumbnail", .{});
        return;
    }
    const new_x = cursor.x - g_drag_state.offset_x;
    const new_y = cursor.y - g_drag_state.offset_y;

    const width = win32.rectWidth(rect);
    const height = win32.rectHeight(rect);
    const unsnapped: snapping.Drag = .{ .x = new_x, .y = new_y, .width = width, .height = height, .hwnd = hwnd };

    if (!win32.isCtrlPressed()) {
        const snapped = snapping.applySnapping(thumbnail_set, unsnapped);
        const dragged = thumbnail_set.getThumbnailByOverlayHwnd(hwnd) orelse return;
        dragged.moveTo(snapped.x, snapped.y, .{ .width = width, .height = height });
        return;
    }

    // Thumbnail-edge and ghost snapping don't apply to a group move; screen edges still do.
    var delta_x = new_x - rect.left;
    var delta_y = new_y - rect.top;
    if (thumbnail_set.config.snapping.enabled and thumbnail_set.config.snapping.screenEdges) {
        const snapped = snapping.applyScreenEdgeSnapping(unsnapped, thumbnail_set.config.snapping.threshold);
        delta_x = snapped.x - rect.left;
        delta_y = snapped.y - rect.top;
    }

    // Batched so the whole group moves in one DWM update instead of drifting apart across separate moves.
    var hdwp = arrange.beginDefer(thumbnail_set) orelse return;
    for (thumbnail_set.thumbnails.items) |thumbnail| {
        if (!win32.isWindow(thumbnail.hwnd) or !win32.isWindow(thumbnail.text_hwnd)) continue;

        var thumbnail_rect: win32.RECT = undefined;
        if (!win32.toBool(win32.GetWindowRect(thumbnail.hwnd, &thumbnail_rect))) {
            slog.warn("Failed to read the position of '{s}', leaving it out of the group move", .{thumbnail.character_name});
            continue;
        }
        hdwp = thumbnail.deferPlace(hdwp, thumbnail_rect.left + delta_x, thumbnail_rect.top + delta_y, null) orelse {
            slog.warn("Failed to queue the group move for '{s}'", .{thumbnail.character_name});
            return;
        };
    }
    _ = win32.EndDeferWindowPos(hdwp);
}

/// True when the thumbnail sits in a thumbnail space, where a drop would last only until the next reflow.
fn grabbedThumbnailIsPlaced(thumbnail_set: *ThumbnailSet, hwnd: win32.HWND) bool {
    const thumbnail = thumbnail_set.getThumbnailByOverlayHwnd(hwnd) orelse return false;
    return spaces.spaceFor(thumbnail_set.config, thumbnail.character_name) != null;
}

/// Cleared before any re-render, so effectiveRenderState already sees the drag as over.
fn stop(thumbnail_set: *ThumbnailSet) void {
    if (g_drag_state.hwnd) |hwnd| {
        if (thumbnail_set.getThumbnailByOverlayHwnd(hwnd)) |thumbnail| thumbnail.is_dragged = false;
    }
    g_drag_state = .{};
    _ = win32.ReleaseCapture();
    thumbnail_set.hideDragOverlays();
}
