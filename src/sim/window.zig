//! The simulator's knots window, run on the main thread, with the timer that runs the fleet's due steps.
const std = @import("std");
const knots = @import("knots");
const ui = @import("ui");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const style = @import("../dialog/knots/style.zig");
const images = @import("../dialog/knots/images.zig");
const color_convert = @import("../dialog/knots/color_convert.zig");
const fleet_mod = @import("fleet.zig");
const view = @import("view.zig");
const log = @import("../log.zig");

const Fleet = fleet_mod.Fleet;
const slog = log.Scoped("sim");

const WINDOW_TITLE = "EVE-Maj Client Simulator";
/// In logical pixels.
const WIDTH = 1180;
const HEIGHT = 820;
const TICK_TIMER_ID = 1;
/// Fine enough for the 1.5s alert storm, cheap enough to idle.
const TICK_INTERVAL_MS = 100;

/// Set while the window runs, for the frame and window procedure callbacks.
var g_fleet: ?*Fleet = null;
/// Set while the window runs, for the frame callback.
var g_controls: ?*view.Controls = null;
/// knots' window procedure, which the subclass forwards to.
var g_knots_proc: isize = 0;

/// Returns once the window is closed; `allocator` must be the one knots grows the text boxes with.
pub fn run(allocator: std.mem.Allocator, io: std.Io, fleet: *Fleet) !void {
    var controls: view.Controls = try .init(allocator);
    defer controls.deinit(allocator);
    images.init(allocator);
    defer images.deinit();

    var app = try knots.App.init(io, allocator, .{
        .window = .{ .width = WIDTH, .height = HEIGHT, .title = WINDOW_TITLE },
        .ui = .{
            .theme = style.theme,
            .fonts = &.{
                .{ .name = style.FONT_REGULAR, .data = style.FONT_REGULAR_DATA },
                .{ .name = style.FONT_SEMIBOLD, .data = style.FONT_SEMIBOLD_DATA },
            },
        },
    });
    defer app.deinit();

    const window: win32.HWND = @ptrCast(app.main_viewport.window.getWindowHandle().windows.hwnd);
    setIcon(window);
    styleTitleBar(window);
    g_fleet = fleet;
    g_controls = &controls;
    defer {
        g_fleet = null;
        g_controls = null;
    }
    // Without it nothing scheduled would ever run.
    g_knots_proc = win32.SetWindowLongPtrW(window, win32.GWLP_WNDPROC, @bitCast(@intFromPtr(&windowProc)));
    if (g_knots_proc == 0) {
        slog.err("Failed to subclass the simulator window: error {d}", .{win32.GetLastError()});
        return error.SubclassFailed;
    }
    if (win32.SetTimer(window, TICK_TIMER_ID, TICK_INTERVAL_MS, null) == 0) {
        slog.err("Failed to start the simulator's tick: error {d}", .{win32.GetLastError()});
        return error.SetTimerFailed;
    }
    defer _ = win32.KillTimer(window, TICK_TIMER_ID);

    fleet.note(.info, "Ready. Add clients on the left; the app picks them up like real EVE clients.", .{});
    try app.start(frame);
}

fn frame(_: *knots.View, context: *ui.Frame) !void {
    const fleet = g_fleet orelse return;
    const controls = g_controls orelse return;
    try view.frame(context, fleet, controls);
}

fn windowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    if (msg == win32.WM_TIMER and wParam == TICK_TIMER_ID) {
        const fleet = g_fleet orelse return 0;
        if (fleet.tick()) _ = win32.InvalidateRect(hwnd, null, win32.FALSE);
        return 0;
    }
    return win32.CallWindowProcW(g_knots_proc, hwnd, msg, wParam, lParam);
}

/// The app's own icon, from app.rc.
fn setIcon(window: win32.HWND) void {
    const instance = win32.GetModuleHandleA(null) orelse {
        slog.warn("Failed to load the app icon for the simulator window: error {d}", .{win32.GetLastError()});
        return;
    };
    const icon = win32.LoadIconA(instance, @ptrFromInt(win32.APP_ICON_ID)) orelse {
        slog.warn("Failed to load the app icon for the simulator window", .{});
        return;
    };
    _ = win32.SendMessageA(window, win32.WM_SETICON, win32.ICON_BIG, @bitCast(@intFromPtr(icon)));
    _ = win32.SendMessageA(window, win32.WM_SETICON, win32.ICON_SMALL, @bitCast(@intFromPtr(icon)));
}

/// Coloured like the header under it, as the configuration window's is.
fn styleTitleBar(window: win32.HWND) void {
    setWindowAttribute(window, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, 1);
    setWindowAttribute(window, win32.DWMWA_CAPTION_COLOR, toColorRef(style.CHROME));
    setWindowAttribute(window, win32.DWMWA_TEXT_COLOR, toColorRef(style.MUTED));
    setWindowAttribute(window, win32.DWMWA_BORDER_COLOR, toColorRef(style.BORDER));
}

/// Every attribute set here is a DWORD-sized BOOL or COLORREF.
fn setWindowAttribute(window: win32.HWND, attribute: win32.DWORD, value: win32.DWORD) void {
    const result = win32.DwmSetWindowAttribute(window, attribute, &value, @sizeOf(win32.DWORD));
    // Debug only: Windows 10 rejects the colour attributes and keeps its own title bar.
    if (result < 0) slog.debug("Failed to set window attribute {d}: HRESULT 0x{x}", .{ attribute, @as(u32, @bitCast(result)) });
}

fn toColorRef(color: ui.Color) win32.DWORD {
    return gdi_overlay.toColorRef(color_convert.toArgb(color));
}
