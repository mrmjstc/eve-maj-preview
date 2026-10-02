//! Actions on every EVE client at once: minimize, close, and move to saved positions.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const scout = @import("scout.zig");
const log = @import("../log.zig");

const slog = log.scoped("client_actions");

/// Kept clear of the screen edges so a restored window's title bar stays grabbable.
const SCREEN_EDGE_MARGIN: i32 = 30;

pub fn minimizeAllClients(eve_windows: []const scout.EveWindow) void {
    slog.info("Minimizing all EVE clients (hotkey action)", .{});

    var minimized_count: usize = 0;
    for (eve_windows) |eve_window| {
        if (!win32.isWindow(eve_window.hwnd)) continue;

        _ = win32.ShowWindowAsync(eve_window.hwnd, win32.SW_FORCEMINIMIZE);
        minimized_count += 1;
        slog.debug("Minimized: {s}", .{eve_window.character_name});
    }

    if (minimized_count > 0) {
        slog.info("Minimized {} EVE client(s)", .{minimized_count});
    } else {
        slog.debug("No EVE clients to minimize", .{});
    }
}

/// Clamps `pos` onto a current monitor, in case the screen configuration changed since save; a point in a gap between monitors goes to the nearest one.
pub fn clampOntoScreen(pos: config_mod.Position) config_mod.Position {
    const left = win32.GetSystemMetrics(win32.SM_XVIRTUALSCREEN);
    const top = win32.GetSystemMetrics(win32.SM_YVIRTUALSCREEN);
    const virtual_screen: win32.RECT = .{
        .left = left,
        .top = top,
        .right = left + win32.GetSystemMetrics(win32.SM_CXVIRTUALSCREEN),
        .bottom = top + win32.GetSystemMetrics(win32.SM_CYVIRTUALSCREEN),
    };
    const clamped = clampToRect(pos, virtual_screen);

    const pt: win32.POINT = .{ .x = clamped.x, .y = clamped.y };
    if (win32.isOnMonitor(pt)) return clamped;
    const monitor = win32.nearestMonitor(pt) orelse return clamped;
    const monitor_rect = win32.monitorRect(monitor) orelse return clamped;
    return clampToRect(clamped, monitor_rect);
}

fn clampToRect(pos: config_mod.Position, rect: win32.RECT) config_mod.Position {
    const max_x = @max(rect.left, rect.right - SCREEN_EDGE_MARGIN);
    const max_y = @max(rect.top, rect.bottom - SCREEN_EDGE_MARGIN);
    return .{
        .x = std.math.clamp(pos.x, rect.left, max_x),
        .y = std.math.clamp(pos.y, rect.top, max_y),
    };
}

/// Moves a window's top-left corner to `pos`, restoring it first if minimized/maximized.
pub fn moveClientToPosition(hwnd: win32.HWND, pos: config_mod.Position) void {
    if (!win32.isWindow(hwnd)) return;

    var placement: win32.WINDOWPLACEMENT = undefined;
    placement.length = @sizeOf(win32.WINDOWPLACEMENT);
    if (win32.toBool(win32.GetWindowPlacement(hwnd, &placement))) {
        if (placement.showCmd == win32.SW_SHOWMINIMIZED or placement.showCmd == win32.SW_SHOWMAXIMIZED) {
            _ = win32.ShowWindowAsync(hwnd, win32.SW_RESTORE);
        }
    }

    const clamped = clampOntoScreen(pos);
    _ = win32.SetWindowPos(hwnd, win32.HWND_NOTOPMOST, clamped.x, clamped.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_ASYNCWINDOWPOS);
}

/// `painter` is anything with Painter.notify's signature, told about each client moved.
pub fn moveAllClientsToSavedPositions(eve_windows: []const scout.EveWindow, config: *const config_mod.Config, painter: anytype) void {
    slog.info("Moving all EVE clients to saved positions", .{});

    var moved_count: usize = 0;
    for (eve_windows) |eve_window| {
        if (config.isExcludedFromAutoMove(eve_window.character_name)) continue;
        const pos = config.getCharacterWindowPosition(eve_window.character_name) orelse continue;
        moveClientToPosition(eve_window.hwnd, pos);
        painter.notify(eve_window.hwnd, .{ .ntype = .SavedPositionMove });
        moved_count += 1;
        slog.debug("Moved {s} to saved position ({}, {})", .{ eve_window.character_name, pos.x, pos.y });
    }

    if (moved_count > 0) {
        slog.info("Moved {} EVE client(s) to saved positions", .{moved_count});
    } else {
        slog.debug("No EVE clients have a saved position", .{});
    }
}

pub fn closeAllClients(eve_windows: []const scout.EveWindow, config: *const config_mod.Config) void {
    slog.info("Closing all EVE clients (hotkey action)", .{});

    var closed_count: usize = 0;
    var excluded_count: usize = 0;

    for (eve_windows) |eve_window| {
        if (!win32.isWindow(eve_window.hwnd)) continue;

        if (config.isExcludedFromCloseAll(eve_window.character_name)) {
            slog.debug("Skipping excluded character: {s}", .{eve_window.character_name});
            excluded_count += 1;
            continue;
        }

        if (config.closeAll.excludeLoginScreenClients and scout.isGenericCharacterName(eve_window.character_name)) {
            slog.debug("Skipping login-screen client (hwnd {*})", .{eve_window.hwnd});
            excluded_count += 1;
            continue;
        }

        _ = win32.PostMessageA(eve_window.hwnd, win32.WM_CLOSE, 0, 0);
        closed_count += 1;
        slog.debug("Closing: {s}", .{eve_window.character_name});
    }

    if (closed_count > 0) {
        slog.info("Sent close message to {} EVE client(s) ({} excluded)", .{ closed_count, excluded_count });
    } else if (excluded_count > 0) {
        slog.info("No clients closed - all {} client(s) are excluded", .{excluded_count});
    } else {
        slog.debug("No EVE clients to close", .{});
    }
}
