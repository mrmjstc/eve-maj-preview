//! Dragging for the list view and the History, Map and Intel panels: their header strip, or the Map Panel's title bar, is the drag handle, and Windows moves them while we snap.
const win32 = @import("../platform/win32.zig");
const vk = @import("../platform/virtual_keys.zig");
const set = @import("../thumbnail/set.zig");
const snapping = @import("../drag/snapping.zig");
const log = @import("../log.zig");

const ThumbnailSet = set.ThumbnailSet;
const slog = log.Scoped("drag");

// Drag anchor, since WM_MOVING's rect already holds earlier snaps; one window drags at a time.
var g_panel_drag_anchor_cursor: win32.POINT = .{ .x = 0, .y = 0 };
var g_panel_drag_anchor_rect: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
/// Where the left button went down on a panel's drag handle, which Windows only starts moving once the cursor has left it.
var g_panel_press_cursor: ?win32.POINT = null;
/// How far in from the window rect each side of the drawn frame sits; nonzero only for a normal window's invisible resize borders.
var g_panel_drag_frame_inset: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

/// Header drag, snapping (none without `thumbnail_set`) and background erase; null for the rest, WM_EXITSIZEMOVE included, so the panel saves its place.
pub fn handleMessage(thumbnail_set: ?*const ThumbnailSet, hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM, header_height: i32) ?win32.LRESULT {
    switch (msg) {
        win32.WM_NCHITTEST => {
            var window_rect: win32.RECT = undefined;
            if (!win32.toBool(win32.GetWindowRect(hwnd, &window_rect))) {
                slog.debug("Failed to read a panel's position to hit-test its header", .{});
                return win32.HTCLIENT;
            }
            return if (win32.lparamY(lParam) - window_rect.top < header_height) win32.HTCAPTION else win32.HTCLIENT;
        },
        win32.WM_NCLBUTTONDOWN => {
            // Not handled: Windows still runs its move loop from it.
            if (wParam == @as(win32.WPARAM, @intCast(win32.HTCAPTION))) g_panel_press_cursor = .{ .x = win32.lparamX(lParam), .y = win32.lparamY(lParam) };
            return null;
        },
        win32.WM_ENTERSIZEMOVE => {
            beginPanelDrag(hwnd);
            return 0;
        },
        win32.WM_MOVING => {
            updatePanelDragRect(thumbnail_set, hwnd, win32.lparamToPtr(win32.RECT, lParam));
            return win32.TRUE;
        },
        win32.WM_ERASEBKGND => return win32.TRUE,
        else => return null,
    }
}

/// From the press, if the button is still down, so the panel keeps the cursor's grip; else, as from the keyboard, from the cursor now.
fn beginPanelDrag(hwnd: win32.HWND) void {
    const press = g_panel_press_cursor;
    g_panel_press_cursor = null;
    if (!win32.toBool(win32.GetWindowRect(hwnd, &g_panel_drag_anchor_rect))) {
        slog.debug("Failed to read where a panel drag started, so it may jump", .{});
    }
    const held_press = if (win32.isKeyDown(vk.VK_LBUTTON)) press else null;
    if (held_press) |point| {
        g_panel_drag_anchor_cursor = point;
    } else if (!win32.toBool(win32.GetCursorPos(&g_panel_drag_anchor_cursor))) {
        slog.debug("Failed to read the cursor where a panel drag started, so it may jump", .{});
    }
    const visible = win32.visibleWindowRect(hwnd) orelse g_panel_drag_anchor_rect;
    g_panel_drag_frame_inset = .{
        .left = visible.left - g_panel_drag_anchor_rect.left,
        .top = visible.top - g_panel_drag_anchor_rect.top,
        .right = g_panel_drag_anchor_rect.right - visible.right,
        .bottom = g_panel_drag_anchor_rect.bottom - visible.bottom,
    };
}

/// Places it by the cursor's move since the drag began, not Windows' possibly already-snapped `rect`, then snaps the drawn frame.
fn updatePanelDragRect(thumbnail_set: ?*const ThumbnailSet, hwnd: win32.HWND, rect: *win32.RECT) void {
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;

    var cursor: win32.POINT = undefined;
    if (!win32.toBool(win32.GetCursorPos(&cursor))) {
        slog.debug("Failed to get the cursor position while dragging a panel", .{});
        return;
    }
    const inset = g_panel_drag_frame_inset;
    const intended_x = g_panel_drag_anchor_rect.left + (cursor.x - g_panel_drag_anchor_cursor.x) + inset.left;
    const intended_y = g_panel_drag_anchor_rect.top + (cursor.y - g_panel_drag_anchor_cursor.y) + inset.top;
    const visible_width = width - inset.left - inset.right;
    const visible_height = height - inset.top - inset.bottom;

    const snapped: snapping.SnapPosition = if (thumbnail_set) |active_set| snapping.applyPanelSnapping(active_set, .{
        .x = intended_x,
        .y = intended_y,
        .width = visible_width,
        .height = visible_height,
        .hwnd = hwnd,
    }) else .{ .x = intended_x, .y = intended_y };

    rect.left = snapped.x - inset.left;
    rect.top = snapped.y - inset.top;
    rect.right = rect.left + width;
    rect.bottom = rect.top + height;
}
