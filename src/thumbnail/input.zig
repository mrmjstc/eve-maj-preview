const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");
const slog = log.scoped("input");
const painter_mod = @import("../painter.zig");
const hotkeys_mod = @import("../hotkeys/manager.zig");
const membership = @import("../hotkeys/membership.zig");
const activation = @import("../clients/activation.zig");
const thumbnail_drag = @import("../drag/thumbnail.zig");
const ThumbnailWindow = painter_mod.ThumbnailWindow;

// Click state for mouse-up triggered clicks (left-click only; right-click drags)
const ClickState = struct {
    pending: bool = false,
    hwnd: ?win32.HWND = null,
    source_hwnd: ?win32.HWND = null,
    shift_pressed: bool = false,
};

var g_click_state: ClickState = .{};

/// Resolves the thumbnail under the cursor, polled on demand since hotkey presses carry no SOURCE_HWND message.
pub fn resolveThumbnailUnderCursor() ?*ThumbnailWindow {
    const painter = painter_mod.g_painter_ptr orelse return null;

    var pt: win32.POINT = undefined;
    if (!win32.toBool(win32.GetCursorPos(&pt))) return null;

    const hwnd_at_cursor = win32.WindowFromPoint(pt) orelse return null;
    const source_hwnd = win32.GetPropA(hwnd_at_cursor, "SOURCE_HWND") orelse return null;

    return painter.getThumbnailBySourceHwnd(source_hwnd);
}

pub fn handleThumbnailShiftClick(source_hwnd: win32.HWND) void {
    const painter = painter_mod.g_painter_ptr orelse return;

    if (!painter.config.exclusion.enableShiftClickExclude) {
        // Exclusion disabled: fall back to a plain click instead of swallowing the input
        activation.activate(source_hwnd);
        return;
    }

    if (hotkeys_mod.g_hotkey_manager_ptr) |manager| membership.toggleThumbnailExclusion(manager, source_hwnd);
}

fn dispatchClick(source_hwnd: win32.HWND, shift_pressed: bool) void {
    if (shift_pressed) {
        handleThumbnailShiftClick(source_hwnd);
    } else {
        activation.activate(source_hwnd);
    }
}

fn handleLButtonDown(hwnd: win32.HWND) void {
    const source_hwnd = win32.GetPropA(hwnd, "SOURCE_HWND") orelse return;
    const painter = painter_mod.g_painter_ptr orelse return;
    const shift_pressed = win32.isShiftPressed();

    if (painter.config.interaction.clickTrigger == .MouseDown) {
        dispatchClick(source_hwnd, shift_pressed);
    } else {
        g_click_state = .{
            .pending = true,
            .hwnd = hwnd,
            .source_hwnd = source_hwnd,
            .shift_pressed = shift_pressed,
        };
    }
}

fn handleLButtonUp(hwnd: win32.HWND) void {
    const click = g_click_state;
    g_click_state = .{};

    const painter = painter_mod.g_painter_ptr orelse return;
    if (painter.config.interaction.clickTrigger != .MouseUp or !click.pending or click.hwnd != hwnd) return;
    if (click.source_hwnd) |source_hwnd| dispatchClick(source_hwnd, click.shift_pressed);
}

/// Returns whether it set the cursor.
fn applyHoverCursor() bool {
    const painter = painter_mod.g_painter_ptr orelse return false;
    const resource: win32.LPCSTR = switch (painter.config.interaction.hoverCursor) {
        .Default => return false,
        .Hand => win32.IDC_HAND,
        .Crosshair => win32.IDC_CROSS,
        .Move => win32.IDC_SIZEALL,
        .Help => win32.IDC_HELP,
    };
    // SetCursor(null) hides the cursor, so a failed load must fall back to the class cursor.
    const cursor = win32.LoadCursorA(null, resource) orelse return false;
    _ = win32.SetCursor(cursor);
    return true;
}

/// Messages the thumbnail and its text overlay handle identically; null for anything else.
fn handleSharedMessage(hwnd: win32.HWND, msg: win32.UINT, lParam: win32.LPARAM, is_text_overlay: bool) ?win32.LRESULT {
    switch (msg) {
        win32.WM_LBUTTONDOWN => handleLButtonDown(hwnd),
        win32.WM_LBUTTONUP => handleLButtonUp(hwnd),
        win32.WM_RBUTTONDOWN => thumbnail_drag.start(hwnd, lParam),
        win32.WM_RBUTTONUP => {
            // A drag started on the text overlay still saves the thumbnail's position.
            const thumbnail_hwnd = if (is_text_overlay) win32.linkedWindow(hwnd) else hwnd;
            if (thumbnail_hwnd) |thumb_hwnd| thumbnail_drag.end(hwnd, thumb_hwnd);
        },
        win32.WM_MOUSEMOVE => thumbnail_drag.move(hwnd, lParam),
        win32.WM_SETCURSOR => {
            if (!applyHoverCursor()) return null;
            return 1;
        },
        win32.WM_CLOSE => {
            _ = win32.DestroyWindow(hwnd);
        },
        win32.WM_DESTROY => {},
        else => return null,
    }
    return 0;
}

/// Window procedure for thumbnail windows.
pub fn windowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_ACTIVATE => {
            if (win32.linkedWindow(hwnd)) |text_hwnd| {
                _ = win32.SetWindowPos(text_hwnd, win32.HWND_TOPMOST, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
            }
        },
        win32.WM_DPICHANGED => {
            // Position only; resizeThumbnailIfNeeded re-derives the size from our own scale formula.
            const suggested = win32.lparamToPtr(win32.RECT, lParam);
            const painter = painter_mod.g_painter_ptr orelse return 0;
            const thumbnail = painter.getThumbnailByOverlayHwnd(hwnd) orelse return 0;
            painter.resizeThumbnailIfNeeded(thumbnail, null);

            var rect: win32.RECT = undefined;
            _ = win32.GetClientRect(thumbnail.hwnd, &rect);
            thumbnail.moveTo(suggested.left, suggested.top, .{ .width = rect.right, .height = rect.bottom });

            painter.renderThumbnail(thumbnail) catch |err| {
                slog.err("Failed to render thumbnail after DPI change for {s}: {}", .{ thumbnail.character_name, err });
            };
            return 0;
        },
        else => if (handleSharedMessage(hwnd, msg, lParam, false)) |result| return result,
    }
    return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
}

/// Window procedure for text overlay windows: handles clicks and dragging
pub fn textWindowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    if (handleSharedMessage(hwnd, msg, lParam, true)) |result| return result;
    return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
}
