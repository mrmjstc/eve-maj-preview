//! Dragging for the list view and History Panel: their header strip is the drag handle, and Windows moves them while we snap.
const win32 = @import("../platform/win32.zig");
const set = @import("../thumbnail/set.zig");
const snapping = @import("../drag/snapping.zig");
const log = @import("../log.zig");

const ThumbnailSet = set.ThumbnailSet;
const slog = log.Scoped("drag");

// Drag anchor from WM_ENTERSIZEMOVE, since WM_MOVING's rect already holds earlier snaps; only one window drags at a time.
var g_panel_drag_anchor_cursor: win32.POINT = .{ .x = 0, .y = 0 };
var g_panel_drag_anchor_rect: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

/// Handles a panel's header drag, snapping (none without a `thumbnail_set`) and background erase; null for any other message, and WM_ENTERSIZEMOVE must still call beginPanelDrag.
pub fn handleMessage(thumbnail_set: ?*ThumbnailSet, hwnd: win32.HWND, msg: win32.UINT, lParam: win32.LPARAM, header_height: i32) ?win32.LRESULT {
    switch (msg) {
        win32.WM_NCHITTEST => {
            var window_rect: win32.RECT = undefined;
            _ = win32.GetWindowRect(hwnd, &window_rect);
            return if (win32.lparamY(lParam) - window_rect.top < header_height) win32.HTCAPTION else win32.HTCLIENT;
        },
        win32.WM_MOVING => {
            updatePanelDragRect(thumbnail_set, hwnd, win32.lparamToPtr(win32.RECT, lParam));
            return win32.TRUE;
        },
        win32.WM_ERASEBKGND => return win32.TRUE,
        else => return null,
    }
}

/// Call from WM_ENTERSIZEMOVE before any other drag-start handling.
pub fn beginPanelDrag(hwnd: win32.HWND) void {
    _ = win32.GetCursorPos(&g_panel_drag_anchor_cursor);
    _ = win32.GetWindowRect(hwnd, &g_panel_drag_anchor_rect);
}

/// Recomputes the intended position from the cursor's movement since the drag began, ignoring Windows' possibly already-snapped `rect`, then snaps it.
fn updatePanelDragRect(thumbnail_set: ?*ThumbnailSet, hwnd: win32.HWND, rect: *win32.RECT) void {
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;

    var cursor: win32.POINT = undefined;
    if (!win32.toBool(win32.GetCursorPos(&cursor))) {
        slog.debug("Failed to get the cursor position while dragging a panel", .{});
        return;
    }
    const intended_x = g_panel_drag_anchor_rect.left + (cursor.x - g_panel_drag_anchor_cursor.x);
    const intended_y = g_panel_drag_anchor_rect.top + (cursor.y - g_panel_drag_anchor_cursor.y);

    const snapped: snapping.SnapPosition = if (thumbnail_set) |active_set| snapping.applySnapping(active_set, intended_x, intended_y, width, height, hwnd) else .{ .x = intended_x, .y = intended_y };

    rect.left = snapped.x;
    rect.top = snapped.y;
    rect.right = snapped.x + width;
    rect.bottom = snapped.y + height;
}
