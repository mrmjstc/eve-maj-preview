//! Mouse input on a thumbnail and its text overlay: clicks, drags, the hover cursor and hover zoom; the client list's rows share its clicks and cursor.
const win32 = @import("../platform/win32.zig");
const app = @import("../app.zig");
const membership = @import("../hotkeys/membership.zig");
const activation = @import("activation.zig");
const thumbnail_drag = @import("../drag/thumbnail.zig");
const window = @import("../thumbnail/window.zig");
const log = @import("../log.zig");

const slog = log.Scoped("thumbnail_input");

/// A left press waiting for its release when clicks trigger on mouse-up; right-click drags instead.
const ClickState = struct {
    is_pending: bool = false,
    hwnd: ?win32.HWND = null,
    source_hwnd: ?win32.HWND = null,
    is_shift_pressed: bool = false,
};

var g_click_state: ClickState = .{};

/// A left press on `hwnd` for `source_hwnd`'s client: activates it, or toggles its exclusion with Shift, now or on release by Click Trigger.
pub fn press(hwnd: win32.HWND, source_hwnd: win32.HWND) void {
    const thumbnail_set = app.currentThumbnailSet() orelse return;
    const is_shift_pressed = win32.isShiftPressed();

    if (thumbnail_set.config.interaction.clickTrigger == .MouseDown) {
        dispatchClick(source_hwnd, is_shift_pressed);
    } else {
        g_click_state = .{
            .is_pending = true,
            .hwnd = hwnd,
            .source_hwnd = source_hwnd,
            .is_shift_pressed = is_shift_pressed,
        };
    }
}

/// A left release on `hwnd`, completing a press made there while clicks trigger on mouse-up.
pub fn release(hwnd: win32.HWND) void {
    const click = g_click_state;
    g_click_state = .{};

    const thumbnail_set = app.currentThumbnailSet() orelse return;
    if (thumbnail_set.config.interaction.clickTrigger != .MouseUp or !click.is_pending or click.hwnd != hwnd) return;
    if (click.source_hwnd) |source_hwnd| dispatchClick(source_hwnd, click.is_shift_pressed);
}

/// False when it's Default or fails to load, so Windows sets the class cursor.
pub fn applyHoverCursor() bool {
    const thumbnail_set = app.currentThumbnailSet() orelse return false;
    const resource: win32.LPCSTR = switch (thumbnail_set.config.interaction.hoverCursor) {
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

pub fn windowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_ACTIVATE => raiseTextOverlay(hwnd),
        win32.WM_DPICHANGED => {
            // Position only; resizeThumbnailIfNeeded re-derives the size from our own scale formula.
            const suggested = win32.lparamToPtr(win32.RECT, lParam);
            const thumbnail_set = app.currentThumbnailSet() orelse return 0;
            const thumbnail = thumbnail_set.getThumbnailByOverlayHwnd(hwnd) orelse return 0;
            thumbnail_set.resizeThumbnailIfNeeded(thumbnail, null);

            var rect: win32.RECT = undefined;
            const size: ?window.Size = if (win32.toBool(win32.GetClientRect(thumbnail.hwnd, &rect))) .{ .width = rect.right, .height = rect.bottom } else null;
            thumbnail.moveTo(suggested.left, suggested.top, size);

            thumbnail_set.renderThumbnail(thumbnail) catch |err| {
                slog.err("Failed to render thumbnail after DPI change for '{s}': {}", .{ thumbnail.character_name, err });
            };
            return 0;
        },
        else => if (handleSharedMessage(hwnd, msg, lParam, false)) |result| return result,
    }
    return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
}

/// The EVENT_OBJECT_DESTROY hook ThumbnailSet.init sets on our own process's windows.
pub fn windowDestroyProc(_: win32.HANDLE, _: win32.DWORD, hwnd: win32.HWND, _: win32.LONG, _: win32.LONG, _: win32.DWORD, _: win32.DWORD) callconv(.c) void {
    const thumbnail_set = app.currentThumbnailSet() orelse return;
    thumbnail_set.removeDestroyedOverlay(hwnd);
}

pub fn textWindowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    if (handleSharedMessage(hwnd, msg, lParam, true)) |result| return result;
    return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
}

/// Batched with the hover zoom's raise, so the text is never composited above the zoom in between.
fn raiseTextOverlay(hwnd: win32.HWND) void {
    const text_hwnd = win32.linkedWindow(hwnd) orelse return;
    var hdwp = win32.BeginDeferWindowPos(3) orelse {
        slog.debug("Failed to begin raising the text overlay", .{});
        return;
    };
    hdwp = win32.deferRaiseTopmost(hdwp, text_hwnd) orelse {
        slog.debug("Failed to raise the text overlay", .{});
        return;
    };
    if (app.currentThumbnailSet()) |thumbnail_set| {
        hdwp = thumbnail_set.renderer.hover_zoom.deferRaise(hdwp) orelse {
            slog.debug("Failed to raise the hover zoom with the text overlay", .{});
            return;
        };
    }
    _ = win32.EndDeferWindowPos(hdwp);
}

fn handleThumbnailShiftClick(running: *app.App, source_hwnd: win32.HWND) void {
    const thumbnail_set = running.thumbnail_set orelse return;

    if (!thumbnail_set.config.exclusion.enableShiftClickExclude) {
        // A plain click rather than swallowing the input.
        activation.activate(running, source_hwnd);
        return;
    }

    if (running.hotkey_manager) |manager| membership.toggleThumbnailExclusion(manager, source_hwnd);
}

fn dispatchClick(source_hwnd: win32.HWND, is_shift_pressed: bool) void {
    const running = app.g_app orelse return;
    if (is_shift_pressed) {
        handleThumbnailShiftClick(running, source_hwnd);
    } else {
        activation.activate(running, source_hwnd);
    }
}

fn handleLButtonDown(hwnd: win32.HWND) void {
    const source_hwnd = win32.GetPropA(hwnd, window.SOURCE_HWND_PROP) orelse return;
    press(hwnd, source_hwnd);
}

fn handleMouseMove(hwnd: win32.HWND) void {
    const thumbnail_set = app.currentThumbnailSet() orelse return;
    thumbnail_drag.move(thumbnail_set, hwnd);

    const thumbnail = thumbnail_set.getThumbnailByOverlayHwnd(hwnd) orelse return;
    if (!thumbnail_set.config.interaction.hoverZoomEnabled or thumbnail.is_dragged) return;

    // Re-armed on every move, since the cursor crosses between the thumbnail and its text overlay.
    if (!win32.trackMouseLeave(hwnd)) slog.debug("Failed to track mouse leave for '{s}'", .{thumbnail.character_name});
    thumbnail_set.renderer.hover_zoom.show(thumbnail_set.instance, &thumbnail_set.renderer.font_cache, thumbnail, thumbnail_set.config);
}

/// Messages the thumbnail and its text overlay handle identically; null for anything else.
fn handleSharedMessage(hwnd: win32.HWND, msg: win32.UINT, lParam: win32.LPARAM, is_text_overlay: bool) ?win32.LRESULT {
    switch (msg) {
        win32.WM_LBUTTONDOWN => handleLButtonDown(hwnd),
        win32.WM_LBUTTONUP => release(hwnd),
        win32.WM_RBUTTONDOWN => if (app.currentThumbnailSet()) |thumbnail_set| thumbnail_drag.start(thumbnail_set, hwnd, lParam),
        win32.WM_RBUTTONUP => {
            // A drag started on the text overlay still saves the thumbnail's position.
            const thumbnail_hwnd = (if (is_text_overlay) win32.linkedWindow(hwnd) else hwnd) orelse return 0;
            const thumbnail_set = app.currentThumbnailSet() orelse return 0;
            thumbnail_drag.end(thumbnail_set, hwnd, thumbnail_hwnd);
        },
        win32.WM_MOUSEMOVE => handleMouseMove(hwnd),
        win32.WM_MOUSELEAVE => if (app.currentThumbnailSet()) |thumbnail_set| thumbnail_set.checkHoverZoom(),
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
