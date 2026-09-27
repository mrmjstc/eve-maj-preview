const win32 = @import("../platform/win32.zig");
const snapping = @import("snapping.zig");

// Dragging for the list view and History Panel: their header strip is the drag handle, and Windows moves them while we snap.

const HTCAPTION: win32.LRESULT = 2;
const HTCLIENT: win32.LRESULT = 1;

// Anchors a drag to the cursor position at WM_ENTERSIZEMOVE, since WM_MOVING's rect reflects prior snap overrides; a single shared pair is safe since only one window can be mid-drag at a time.
var g_panel_drag_anchor_cursor: win32.POINT = .{ .x = 0, .y = 0 };
var g_panel_drag_anchor_rect: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

/// WM_NCHITTEST for a panel whose header (the top `header_height` px) is its only drag handle.
pub fn panelHeaderHitTest(hwnd: win32.HWND, lParam: win32.LPARAM, header_height: i32) win32.LRESULT {
    const sy = win32.lparamY(lParam);
    var wr: win32.RECT = undefined;
    _ = win32.GetWindowRect(hwnd, &wr);
    const cy = sy - wr.top;
    if (cy < header_height) return HTCAPTION;
    return HTCLIENT;
}

/// Call from WM_ENTERSIZEMOVE before any other drag-start handling.
pub fn beginPanelDrag(hwnd: win32.HWND) void {
    _ = win32.GetCursorPos(&g_panel_drag_anchor_cursor);
    _ = win32.GetWindowRect(hwnd, &g_panel_drag_anchor_rect);
}

/// Call from WM_MOVING to recompute the truly-intended position from the absolute cursor delta since drag start (ignoring Windows' possibly already-snapped `rect`) and snap it via snapping.applySnapping.
pub fn updatePanelDragRect(hwnd: win32.HWND, rect: *win32.RECT) void {
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;

    var cursor: win32.POINT = undefined;
    _ = win32.GetCursorPos(&cursor);
    const intended_x = g_panel_drag_anchor_rect.left + (cursor.x - g_panel_drag_anchor_cursor.x);
    const intended_y = g_panel_drag_anchor_rect.top + (cursor.y - g_panel_drag_anchor_cursor.y);

    const snapped = snapping.applySnapping(intended_x, intended_y, width, height, hwnd);

    rect.left = snapped.x;
    rect.top = snapped.y;
    rect.right = snapped.x + width;
    rect.bottom = snapped.y + height;
}
