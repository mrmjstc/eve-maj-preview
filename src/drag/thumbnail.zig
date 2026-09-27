const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");
const slog = log.scoped("drag");
const painter_mod = @import("../painter.zig");
const ThumbnailWindow = painter_mod.ThumbnailWindow;
const overlays = @import("overlays.zig");
const snapping = @import("snapping.zig");

// Right-button drag of a thumbnail and its linked text overlay; holding Ctrl moves every thumbnail together.

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
    if (!painter.config.interaction.enableDragging) return;

    g_drag_state = .{
        .is_dragging = true,
        .hwnd = hwnd,
        .offset_x = win32.lparamX(lParam),
        .offset_y = win32.lparamY(lParam),
    };

    if (painter.getThumbnailByOverlayHwnd(hwnd)) |thumbnail| {
        painter.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render dragging thumbnail for {s}: {}", .{ thumbnail.character_name, err });
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
    if (!g_drag_state.is_dragging or g_drag_state.hwnd != hwnd) return;
    stop();

    const painter = painter_mod.g_painter_ptr orelse return;
    if (painter.getThumbnailByOverlayHwnd(hwnd)) |thumbnail| {
        painter.renderThumbnail(thumbnail) catch |err| {
            slog.err("Failed to render thumbnail after drag for {s}: {}", .{ thumbnail.character_name, err });
        };
    }

    // Ctrl held during drag means all thumbnails moved together
    if (win32.isCtrlPressed()) {
        for (painter.thumbnails.items) |*saved_thumbnail| {
            painter.saveThumbnailPosition(saved_thumbnail.hwnd);
        }
    } else {
        painter.saveThumbnailPosition(thumbnail_hwnd);
    }
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

/// Handles mouse move during drag; thumbnail and text-overlay windows are linked and moved together.
pub fn move(hwnd: win32.HWND, lParam: win32.LPARAM) void {
    if (!g_drag_state.is_dragging or g_drag_state.hwnd != hwnd) return;

    if (!win32.isWindow(hwnd)) {
        slog.warn("Window {*} became invalid during drag operation, canceling drag", .{hwnd});
        stop();
        return;
    }

    var rect: win32.RECT = undefined;
    _ = win32.GetWindowRect(hwnd, &rect);

    const new_x = rect.left + win32.lparamX(lParam) - g_drag_state.offset_x;
    const new_y = rect.top + win32.lparamY(lParam) - g_drag_state.offset_y;

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

            var window_count: c_int = 0;
            for (painter.thumbnails.items) |thumbnail| {
                if (thumbnail.win32_enabled and win32.isWindow(thumbnail.hwnd) and win32.isWindow(thumbnail.text_hwnd)) {
                    window_count += 2;
                }
            }

            // Batched via DeferWindowPos so the whole group moves in one atomic DWM update instead of drifting apart across N sequential SetWindowPos calls.
            if (window_count > 0) {
                var hdwp = win32.BeginDeferWindowPos(window_count);
                for (painter.thumbnails.items) |thumbnail| {
                    if (!thumbnail.win32_enabled or !win32.isWindow(thumbnail.hwnd) or !win32.isWindow(thumbnail.text_hwnd)) {
                        continue;
                    }

                    var thumb_rect: win32.RECT = undefined;
                    _ = win32.GetWindowRect(thumbnail.hwnd, &thumb_rect);

                    const new_thumb_x = thumb_rect.left + delta_x;
                    const new_thumb_y = thumb_rect.top + delta_y;

                    if (hdwp) |h| {
                        hdwp = win32.DeferWindowPos(h, thumbnail.hwnd, win32.HWND_NOTOPMOST, new_thumb_x, new_thumb_y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
                    }
                    if (hdwp) |h| {
                        hdwp = win32.DeferWindowPos(h, thumbnail.text_hwnd, win32.HWND_TOPMOST, new_thumb_x, new_thumb_y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
                    }
                }
                if (hdwp) |h| {
                    _ = win32.EndDeferWindowPos(h);
                }
            }
        }
    } else {
        // Apply snapping only when dragging single thumbnail
        const snapped = snapping.applySnapping(new_x, new_y, width, height, hwnd);

        if (win32.linkedWindow(hwnd)) |other_hwnd| {
            // Z-order is keyed by identity (text overlay always TOPMOST above thumbnail), not by which window was grabbed, or the live thumbnail could hide the name/border until refocus.
            const dragged = if (painter_mod.g_painter_ptr) |painter| painter.getThumbnailByOverlayHwnd(hwnd) else null;
            const thumb_hwnd = if (dragged) |t| t.hwnd else hwnd;
            const text_hwnd = if (dragged) |t| t.text_hwnd else other_hwnd;
            _ = win32.SetWindowPos(thumb_hwnd, win32.HWND_NOTOPMOST, snapped.x, snapped.y, width, height, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
            _ = win32.SetWindowPos(text_hwnd, win32.HWND_TOPMOST, snapped.x, snapped.y, width, height, win32.SWP_NOACTIVATE);
        }
    }
}
