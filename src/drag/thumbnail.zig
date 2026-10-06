//! Right-button drag of a thumbnail and its linked text overlay; holding Ctrl moves every thumbnail together.
const win32 = @import("../platform/win32.zig");
const painter_mod = @import("../painter.zig");
const overlays = @import("overlays.zig");
const snapping = @import("snapping.zig");
const arrange = @import("../thumbnail/arrange.zig");
const spaces = @import("../layout/spaces.zig");
const log = @import("../log.zig");

const Painter = painter_mod.Painter;
const ThumbnailWindow = painter_mod.ThumbnailWindow;
const slog = log.scoped("drag");

const DragState = struct {
    is_dragging: bool = false,
    hwnd: ?win32.HWND = null,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
};

var g_drag_state: DragState = .{};

/// Whether this thumbnail (by either its overlay or text-overlay hwnd) is the one currently being dragged.
pub fn isDragging(thumbnail: *const ThumbnailWindow) bool {
    return g_drag_state.is_dragging and (g_drag_state.hwnd == thumbnail.hwnd or g_drag_state.hwnd == thumbnail.text_hwnd);
}

pub fn start(hwnd: win32.HWND, lParam: win32.LPARAM) void {
    const painter = painter_mod.g_painter_ptr orelse return;
    if (!painter.config.interaction.enableDragging or grabbedThumbnailIsPlaced(painter, hwnd)) return;

    painter.hover_zoom.hide();
    g_drag_state = .{
        .is_dragging = true,
        .hwnd = hwnd,
        .offset_x = win32.lparamX(lParam),
        .offset_y = win32.lparamY(lParam),
    };

    if (painter.getThumbnailByOverlayHwnd(hwnd)) |thumbnail| {
        painter.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render dragging thumbnail for '{s}': {}", .{ thumbnail.character_name, err });
        };
        if (painter.config.snapping.showGhostPositionBorders) {
            painter.ghost_overlay.show(painter, thumbnail.character_name);
        }
    }
    overlays.showDragHint(painter, hwnd);

    _ = win32.SetCapture(hwnd);
}

/// Saves `thumbnail_hwnd`'s position, whichever of its two windows (`hwnd`) was grabbed.
pub fn end(hwnd: win32.HWND, thumbnail_hwnd: win32.HWND) void {
    if (g_drag_state.hwnd != hwnd or !g_drag_state.is_dragging) return;
    stop();

    const painter = painter_mod.g_painter_ptr orelse return;
    if (painter.getThumbnailByOverlayHwnd(hwnd)) |thumbnail| {
        painter.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render thumbnail after drag for '{s}': {}", .{ thumbnail.character_name, err });
        };
    }

    if (win32.isCtrlPressed()) {
        painter.saveAllThumbnailPositions();
    } else {
        painter.saveThumbnailPosition(thumbnail_hwnd);
    }
}

/// A drop there would only last until the next reflow, and would save a position the layout ignores.
fn grabbedThumbnailIsPlaced(painter: *Painter, hwnd: win32.HWND) bool {
    const thumbnail = painter.getThumbnailByOverlayHwnd(hwnd) orelse return false;
    return spaces.spaceFor(painter.config, thumbnail.character_name) != null;
}

/// Cleared before any re-render, so effectiveRenderState already sees the drag as over.
fn stop() void {
    g_drag_state = .{};
    _ = win32.ReleaseCapture();
    if (painter_mod.g_painter_ptr) |painter| {
        painter.ghost_overlay.hide();
        painter.hint_box.hide();
    }
}

/// The thumbnail and its text overlay move together.
pub fn move(hwnd: win32.HWND) void {
    if (!g_drag_state.is_dragging or g_drag_state.hwnd != hwnd) return;

    if (!win32.isWindow(hwnd)) {
        slog.warn("Window {*} became invalid during drag operation, canceling drag", .{hwnd});
        stop();
        return;
    }

    var rect: win32.RECT = undefined;
    _ = win32.GetWindowRect(hwnd, &rect);

    // The real cursor, not the message's coordinates, which lag behind a window that's moving under them.
    var cursor: win32.POINT = undefined;
    if (!win32.toBool(win32.GetCursorPos(&cursor))) return;
    const new_x = cursor.x - g_drag_state.offset_x;
    const new_y = cursor.y - g_drag_state.offset_y;

    const width = win32.rectWidth(rect);
    const height = win32.rectHeight(rect);

    if (win32.isCtrlPressed()) {
        // Thumbnail-edge and ghost snapping don't apply to a group move; screen edges still do.
        var delta_x = new_x - rect.left;
        var delta_y = new_y - rect.top;

        if (painter_mod.g_painter_ptr) |painter| {
            if (painter.config.snapping.enabled and painter.config.snapping.screenEdges) {
                const snapped = snapping.applyScreenEdgeSnapping(new_x, new_y, width, height, painter.config.snapping.threshold, hwnd);
                delta_x = snapped.x - rect.left;
                delta_y = snapped.y - rect.top;
            }

            // Batched so the whole group moves in one DWM update instead of drifting apart across separate moves.
            var hdwp = arrange.beginDefer(painter) orelse return;
            for (painter.thumbnails.items) |thumbnail| {
                if (!thumbnail.win32_enabled or !win32.isWindow(thumbnail.hwnd) or !win32.isWindow(thumbnail.text_hwnd)) continue;

                var thumb_rect: win32.RECT = undefined;
                _ = win32.GetWindowRect(thumbnail.hwnd, &thumb_rect);
                hdwp = thumbnail.deferPlace(hdwp, thumb_rect.left + delta_x, thumb_rect.top + delta_y, null) orelse return;
            }
            _ = win32.EndDeferWindowPos(hdwp);
        }
    } else {
        const snapped = snapping.applySnapping(new_x, new_y, width, height, hwnd);

        const painter = painter_mod.g_painter_ptr orelse return;
        const dragged = painter.getThumbnailByOverlayHwnd(hwnd) orelse return;
        dragged.moveTo(snapped.x, snapped.y, .{ .width = width, .height = height });
    }
}
