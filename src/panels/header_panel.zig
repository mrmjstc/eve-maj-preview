//! The window class and procedure shared by the panels dragged by their header strip: the client list and the History and Intel panels.
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const panel_window = @import("../platform/panel_window.zig");
const drag = @import("drag.zig");
const panel_header = @import("panel_header.zig");
const log = @import("../log.zig");

const slog = log.Scoped("header_panel");

/// What a panel's header keeps between messages; main thread only.
pub const HeaderInput = struct {
    hovered: ?panel_header.Hit = null,
    /// Set while a WM_MOUSELEAVE is armed, so it's armed once per visit.
    is_tracking_leave: bool = false,

    /// Returns whether the hovered part changed.
    fn hover(self: *HeaderInput, hwnd: win32.HWND, hit: ?panel_header.Hit) bool {
        if (!self.is_tracking_leave) {
            self.is_tracking_leave = win32.trackMouseLeave(hwnd);
            if (!self.is_tracking_leave) slog.debug("Failed to track the cursor leaving a panel, so a lit header button may stay lit", .{});
        }
        if (panel_header.sameHit(self.hovered, hit)) return false;
        self.hovered = hit;
        return true;
    }

    /// Returns whether a part was lit.
    fn leave(self: *HeaderInput) bool {
        self.is_tracking_leave = false;
        const was_lit = self.hovered != null;
        self.hovered = null;
        return was_lit;
    }
};

/// `Window` is attached as its PanelWindow's owner once stored, and has a `host: panel_host.Host`, a `header_input: HeaderInput`, `headerLayout`, `toggleCollapsed`, `runHeaderAction(action)`, `redraw`, `saveWindowPosition` and `isPositionLocked`, and `onLeftClick(x, y)`, `handleMessage` or both; `handleMessage` returns null for a message left to Windows.
pub fn HeaderPanel(comptime Window: type, comptime class_name: [*:0]const u8) type {
    return struct {
        pub const register = gdi_overlay.WindowClass(class_name, windowProc).register;

        fn windowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
            const window = panel_window.ownerOf(Window, hwnd);
            // The header's buttons take clicks; the rest of it drags the panel unless it's locked.
            if (msg == win32.WM_NCHITTEST) {
                if (window) |open| {
                    if (screenHitAt(open, hwnd, lParam) != null or open.isPositionLocked()) return win32.HTCLIENT;
                }
            }
            const thumbnail_set = if (window) |open| open.host.thumbnail_set() else null;
            if (drag.handleMessage(thumbnail_set, hwnd, msg, lParam, panel_header.HEIGHT)) |result| return result;
            const open = window orelse return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
            switch (msg) {
                win32.WM_EXITSIZEMOVE => {
                    open.saveWindowPosition();
                    return 0;
                },
                win32.WM_NCLBUTTONDBLCLK => if (wParam == @as(win32.WPARAM, @intCast(win32.HTCAPTION))) {
                    open.toggleCollapsed();
                    return 0;
                },
                win32.WM_MOUSEMOVE => {
                    const hit = open.headerLayout().hitAt(win32.lparamX(lParam), win32.lparamY(lParam));
                    if (open.header_input.hover(hwnd, hit)) open.redraw();
                },
                win32.WM_MOUSELEAVE => if (open.header_input.leave()) open.redraw(),
                win32.WM_LBUTTONDOWN => if (open.headerLayout().hitAt(win32.lparamX(lParam), win32.lparamY(lParam))) |hit| {
                    switch (hit) {
                        .chevron => open.toggleCollapsed(),
                        .button => |action| open.runHeaderAction(action),
                    }
                    return 0;
                },
                else => {},
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

        /// From WM_NCHITTEST's screen position.
        fn screenHitAt(open: *const Window, hwnd: win32.HWND, lParam: win32.LPARAM) ?panel_header.Hit {
            var window_rect: win32.RECT = undefined;
            if (!win32.toBool(win32.GetWindowRect(hwnd, &window_rect))) return null;
            return open.headerLayout().hitAt(win32.lparamX(lParam) - window_rect.left, win32.lparamY(lParam) - window_rect.top);
        }
    };
}
