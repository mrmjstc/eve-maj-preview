//! The window class and procedure shared by the panels dragged by their header strip: the client list and the History and Intel panels.
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const panel_window = @import("../platform/panel_window.zig");
const drag = @import("drag.zig");

/// `Window` is attached as its PanelWindow's owner once stored, and has a `host: panel_host.Host`, `headerHeight` and `saveWindowPosition`, and `onLeftClick(x, y)` or `handleMessage`, which returns null for a message left to Windows.
pub fn HeaderPanel(comptime Window: type, comptime class_name: [*:0]const u8) type {
    return struct {
        pub const register = gdi_overlay.WindowClass(class_name, windowProc).register;

        fn windowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
            const window = panel_window.ownerOf(Window, hwnd);
            // The window is attached only once it exists, so creation's messages go without a header.
            const header_height = if (window) |open| open.headerHeight() else 0;
            const thumbnail_set = if (window) |open| open.host.thumbnail_set() else null;
            if (drag.handleMessage(thumbnail_set, hwnd, msg, lParam, header_height)) |result| return result;
            const open = window orelse return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
            if (msg == win32.WM_EXITSIZEMOVE) {
                open.saveWindowPosition();
                return 0;
            }
            if (comptime @hasDecl(Window, "onLeftClick")) {
                if (msg == win32.WM_LBUTTONDOWN) {
                    open.onLeftClick(win32.lparamX(lParam), win32.lparamY(lParam));
                    return 0;
                }
            }
            if (comptime @hasDecl(Window, "handleMessage")) {
                if (open.handleMessage(hwnd, msg, wParam, lParam)) |result| return result;
            }
            return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
        }
    };
}
