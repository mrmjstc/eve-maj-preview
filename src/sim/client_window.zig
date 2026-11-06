//! A stand-in EVE client: one "trinityWindow" per process, titled with the character logged in.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const win32_sim = @import("win32_sim.zig");
const lines = @import("lines.zig");
const log = @import("../log.zig");

const slog = log.Scoped("sim_client");

/// What scout.zig recognizes an EVE client's window by.
pub const CLASS_NAME = "trinityWindow";
/// Posted by the simulator: the title changes as EVE's does at login and logout.
pub const WM_SIM_LOGIN = win32.WM_APP + 1;
pub const WM_SIM_LOGOUT = win32.WM_APP + 2;
/// 16:9, like the game's own window.
const WIDTH = 1024;
const HEIGHT = 576;
const TITLE_PREFIX = "EVE - ";
/// Fits TITLE_PREFIX and the longest name kept.
const TITLE_LENGTH = TITLE_PREFIX.len + lines.MAX_CHARACTER_NAME_LENGTH + 1;
/// Negative asks GDI for the characters' height rather than the cell's.
const NAME_FONT_HEIGHT = -56;
const STATE_FONT_HEIGHT = -24;
/// How far above the window's middle the name starts.
const NAME_RISE = 48;
/// How far below the window's middle the login state starts.
const STATE_DROP = 24;
/// Dark tints, one per character by its ID, so thumbnails tell clients apart at a glance.
const TINTS = [_]u32{ 0x1B2A41, 0x2D1B41, 0x1B4130, 0x41301B, 0x411B2A, 0x1B3B41, 0x33411B, 0x3A1B1B };
const TEXT_COLOR: u32 = 0xE8E6E1;
const MUTED_COLOR: u32 = 0x96948F;

var g_name_buf: [lines.MAX_CHARACTER_NAME_LENGTH]u8 = undefined;
var g_name: []const u8 = "";
var g_is_logged_in: bool = true;
var g_background: ?win32.HBRUSH = null;
var g_name_font: ?win32.HFONT = null;
var g_state_font: ?win32.HFONT = null;

/// Returns once the window is closed.
pub fn run(name: []const u8) !void {
    const length = @min(name.len, lines.MAX_CHARACTER_NAME_LENGTH);
    @memcpy(g_name_buf[0..length], name[0..length]);
    g_name = g_name_buf[0..length];

    const tint = TINTS[lines.characterId(g_name) % TINTS.len];
    g_background = win32.CreateSolidBrush(gdi_overlay.toColorRef(tint));
    defer if (g_background) |brush| {
        _ = win32.DeleteObject(brush);
    };
    g_name_font = createFont(NAME_FONT_HEIGHT, win32.FW_SEMIBOLD);
    defer if (g_name_font) |font| {
        _ = win32.DeleteObject(font);
    };
    g_state_font = createFont(STATE_FONT_HEIGHT, win32.FW_NORMAL);
    defer if (g_state_font) |font| {
        _ = win32.DeleteObject(font);
    };

    const instance = win32.GetModuleHandleA(null) orelse return error.GetModuleHandleFailed;
    const window_class: win32.WNDCLASSEXA = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXA),
        .style = win32_sim.CS_HREDRAW | win32_sim.CS_VREDRAW,
        .lpfnWndProc = windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = win32.LoadCursorA(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (win32.RegisterClassExA(&window_class) == 0) {
        slog.err("Failed to register the client window class: error {d}", .{win32.GetLastError()});
        return error.RegisterClassFailed;
    }

    var title_buf: [TITLE_LENGTH]u8 = undefined;
    const title = try loggedInTitle(&title_buf);
    if (win32.CreateWindowExA(0, CLASS_NAME, title, win32.WS_OVERLAPPEDWINDOW | win32_sim.WS_VISIBLE, win32_sim.CW_USEDEFAULT, win32_sim.CW_USEDEFAULT, WIDTH, HEIGHT, null, null, instance, null) == null) {
        slog.err("Failed to create the window for '{s}': error {d}", .{ g_name, win32.GetLastError() });
        return error.CreateWindowFailed;
    }

    var msg: win32.MSG = undefined;
    while (win32.GetMessageA(&msg, null, 0, 0) > 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageA(&msg);
    }
}

fn windowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    switch (msg) {
        WM_SIM_LOGIN, WM_SIM_LOGOUT => {
            g_is_logged_in = msg == WM_SIM_LOGIN;
            var title_buf: [TITLE_LENGTH]u8 = undefined;
            // TITLE_LENGTH fits the longest name run keeps.
            const title = if (g_is_logged_in) loggedInTitle(&title_buf) catch unreachable else "EVE";
            if (!win32.toBool(win32.SetWindowTextA(hwnd, title))) slog.warn("Failed to retitle '{s}' for its login: error {d}", .{ g_name, win32.GetLastError() });
            _ = win32.InvalidateRect(hwnd, null, win32.FALSE);
            return 0;
        },
        win32.WM_ERASEBKGND => return 1,
        win32.WM_PAINT => {
            paint(hwnd);
            return 0;
        },
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}

/// The character's name over its tint, and whether it's logged in.
fn paint(hwnd: win32.HWND) void {
    var paint_struct: win32.PAINTSTRUCT = undefined;
    const hdc = win32.BeginPaint(hwnd, &paint_struct) orelse return;
    defer _ = win32.EndPaint(hwnd, &paint_struct);
    var rect: win32.RECT = undefined;
    if (!win32.toBool(win32.GetClientRect(hwnd, &rect))) return;
    if (g_background) |brush| _ = win32_sim.FillRect(hdc, &rect, brush);
    _ = win32.SetBkMode(hdc, win32.TRANSPARENT);
    const middle = @divTrunc(rect.top + rect.bottom, 2);
    _ = win32.SetTextColor(hdc, gdi_overlay.toColorRef(TEXT_COLOR));
    centeredText(hdc, rect, middle - NAME_RISE, g_name_font, g_name);
    _ = win32.SetTextColor(hdc, gdi_overlay.toColorRef(MUTED_COLOR));
    centeredText(hdc, rect, middle + STATE_DROP, g_state_font, if (g_is_logged_in) "Logged in" else "Logged out");
}

fn centeredText(hdc: win32.HDC, rect: win32.RECT, top: c_int, font: ?win32.HFONT, text: []const u8) void {
    const previous = if (font) |chosen| win32.SelectObject(hdc, chosen) else null;
    defer if (previous) |restored| {
        _ = win32.SelectObject(hdc, restored);
    };
    var size: win32.SIZE = .{ .cx = 0, .cy = 0 };
    _ = win32.GetTextExtentPoint32A(hdc, @ptrCast(text.ptr), @intCast(text.len), &size);
    const left = @divTrunc(rect.left + rect.right - size.cx, 2);
    _ = win32.TextOutA(hdc, left, top, @ptrCast(text.ptr), @intCast(text.len));
}

/// Null falls back to the DC's own font.
fn createFont(height: c_int, weight: c_int) ?win32.HFONT {
    const font = win32.CreateFontA(height, 0, 0, 0, weight, 0, 0, 0, win32.DEFAULT_CHARSET, win32.OUT_DEFAULT_PRECIS, win32.CLIP_DEFAULT_PRECIS, win32.CLEARTYPE_QUALITY, win32.DEFAULT_PITCH, "Segoe UI");
    if (font == null) slog.warn("Failed to create the client window's font, using the default", .{});
    return font;
}

/// Which scout reads the character from.
fn loggedInTitle(buf: []u8) ![:0]const u8 {
    return std.mem.printSentinel(buf, TITLE_PREFIX ++ "{s}", .{g_name}, 0);
}
