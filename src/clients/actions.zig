//! Actions on EVE clients: minimizing, closing, and moving them to saved positions.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const scout = @import("scout.zig");
const animation = @import("animation.zig");
const exclusions_mod = @import("exclusions.zig");
const strings = @import("../util/strings.zig");
const log = @import("../log.zig");

const slog = log.Scoped("actions");

/// Kept clear of the screen edges so a restored window's title bar stays grabbable.
const SCREEN_EDGE_MARGIN: i32 = 30;

pub fn minimizeAllClients(eve_windows: []const scout.EveWindow, config: *const config_mod.Config) void {
    slog.info("Minimizing all EVE clients (hotkey action)", .{});

    var minimized_count: usize = 0;
    for (eve_windows) |eve_window| {
        if (!eve_window.is_eve_client or !win32.isWindow(eve_window.hwnd)) continue;

        animation.showClient(config, eve_window.hwnd, win32.SW_FORCEMINIMIZE);
        minimized_count += 1;
        slog.debug("Minimized: {s}", .{eve_window.character_name});
    }

    if (minimized_count > 0) {
        slog.info("Minimized {} EVE client(s)", .{minimized_count});
    } else {
        slog.debug("No EVE clients to minimize", .{});
    }
}

/// Clamps `position` onto its title bar's monitor when that title bar would be off every screen (e.g. the screen configuration changed since save), or when the corner sits on a monitor of another scale.
pub fn clampOntoScreen(position: config_mod.Position) config_mod.Position {
    // Probe inside the title bar: saved corners include the invisible resize border, so a client snapped to a screen edge sits a few pixels off it.
    const probe: win32.POINT = .{ .x = position.x +| SCREEN_EDGE_MARGIN, .y = position.y +| SCREEN_EDGE_MARGIN };
    const monitor = win32.nearestMonitor(probe) orelse return position;
    const monitor_rect = win32.monitorRect(monitor) orelse return position;
    if (!win32.isOnMonitor(probe)) return clampToRect(position, monitor_rect);

    // Windows rescales a DPI-unaware window's position when its corner lands on a monitor of another scale.
    const corner_monitor = win32.nearestMonitor(.{ .x = position.x, .y = position.y }) orelse return position;
    if (corner_monitor == monitor or win32.monitorDpi(corner_monitor) == win32.monitorDpi(monitor)) return position;
    return clampToRect(position, monitor_rect);
}

/// Ignores excludeFromMinimize: a new client is still at the login screen, so it has no character yet.
pub fn minimizeNewClient(config: *const config_mod.Config, source_hwnd: win32.HWND) void {
    animation.showClient(config, source_hwnd, win32.SW_FORCEMINIMIZE);
    slog.info("Started a new client minimized", .{});
}

/// Restores a minimized or maximized window first.
pub fn moveClientToPosition(config: *const config_mod.Config, hwnd: win32.HWND, position: config_mod.Position) void {
    if (!win32.isWindow(hwnd)) return;

    var placement: win32.WINDOWPLACEMENT = undefined;
    placement.length = @sizeOf(win32.WINDOWPLACEMENT);
    if (win32.toBool(win32.GetWindowPlacement(hwnd, &placement))) {
        const is_minimized = placement.showCmd == win32.SW_SHOWMINIMIZED;
        if (is_minimized or placement.showCmd == win32.SW_SHOWMAXIMIZED) {
            animation.showClient(config, hwnd, win32.SW_RESTORE);
        }
        // Minimized from maximized, the first restore only brings it back maximized.
        if (is_minimized and placement.flags & win32.WPF_RESTORETOMAXIMIZED != 0) {
            animation.showClient(config, hwnd, win32.SW_RESTORE);
        }
    } else {
        slog.warn("Failed to get the placement of window {*}, moving it as is", .{hwnd});
    }

    const clamped = clampOntoScreen(position);
    _ = win32.SetWindowPos(hwnd, win32.HWND_NOTOPMOST, clamped.x, clamped.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_ASYNCWINDOWPOS);
}

/// `thumbnail_set` is anything with ThumbnailSet.notify's signature, told about each client moved.
pub fn moveAllClientsToSavedPositions(eve_windows: []const scout.EveWindow, config: *const config_mod.Config, thumbnail_set: anytype) void {
    slog.info("Moving all EVE clients to saved positions", .{});

    var moved_count: usize = 0;
    for (eve_windows) |eve_window| {
        if (!eve_window.is_eve_client or config.isExcludedFromAutoMove(eve_window.character_name)) continue;
        const position = config.getCharacterWindowPosition(eve_window.character_name) orelse continue;
        moveClientToPosition(config, eve_window.hwnd, position);
        thumbnail_set.notify(eve_window.hwnd, .{ .notification_type = .SavedPositionMove });
        moved_count += 1;
        slog.debug("Moved {s} to saved position ({}, {})", .{ eve_window.character_name, position.x, position.y });
    }

    if (moved_count > 0) {
        slog.info("Moved {} EVE client(s) to saved positions", .{moved_count});
    } else {
        slog.debug("No EVE clients have a saved position", .{});
    }
}

pub fn closeAllClients(eve_windows: []const scout.EveWindow, config: *const config_mod.Config, exclusions: *const exclusions_mod.Exclusions) void {
    slog.info("Closing all EVE clients (hotkey action)", .{});

    var closed_count: usize = 0;
    var excluded_count: usize = 0;

    for (eve_windows) |eve_window| {
        if (!eve_window.is_eve_client or !win32.isWindow(eve_window.hwnd)) continue;

        if (config.isExcludedFromCloseAll(eve_window.character_name)) {
            slog.debug("Skipping excluded character: {s}", .{eve_window.character_name});
            excluded_count += 1;
            continue;
        }

        if (config.closeAll.excludeCycleExcludedClients and exclusions.contains(eve_window.character_name)) {
            slog.debug("Skipping cycle-excluded character: {s}", .{eve_window.character_name});
            excluded_count += 1;
            continue;
        }

        if (config.closeAll.excludeLoginScreenClients and scout.isGenericCharacterName(eve_window.character_name)) {
            slog.debug("Skipping login-screen client (hwnd {*})", .{eve_window.hwnd});
            excluded_count += 1;
            continue;
        }

        if (closeClient(eve_window)) closed_count += 1;
    }

    if (closed_count > 0) {
        slog.info("Sent close message to {} EVE client(s) ({} excluded)", .{ closed_count, excluded_count });
    } else if (excluded_count > 0) {
        slog.info("No clients closed - all {} client(s) are excluded", .{excluded_count});
    } else {
        slog.debug("No EVE clients to close", .{});
    }
}

/// Ignores the Close All exclusions: the group's members were picked for it.
pub fn closeGroupClients(eve_windows: []const scout.EveWindow, groups: []const config_mod.HotkeyGroupConfig, group_index: usize) void {
    if (group_index >= groups.len) {
        slog.err("Failed to close group: index {} is out of range", .{group_index});
        return;
    }
    const group = &groups[group_index];
    var name_buf: [config_mod.HotkeyGroupConfig.DISPLAY_NAME_SIZE]u8 = undefined;
    const group_name = group.displayName(&name_buf, group_index);

    var closed_count: usize = 0;
    for (eve_windows) |eve_window| {
        if (!eve_window.is_eve_client or !win32.isWindow(eve_window.hwnd)) continue;
        if (strings.indexOfString(group.characters.items, eve_window.character_name) == null) continue;
        if (closeClient(eve_window)) closed_count += 1;
    }

    if (closed_count > 0) {
        slog.info("Sent close message to {} EVE client(s) in group '{s}'", .{ closed_count, group_name });
    } else {
        slog.info("No running clients in group '{s}' to close", .{group_name});
    }
}

/// Logs its own failure; returns whether the close was sent.
pub fn closeClient(eve_window: scout.EveWindow) bool {
    if (!win32.toBool(win32.PostMessageA(eve_window.hwnd, win32.WM_CLOSE, 0, 0))) {
        slog.warn("Failed to send close to '{s}'", .{eve_window.character_name});
        return false;
    }
    slog.debug("Closing: {s}", .{eve_window.character_name});
    return true;
}

fn clampToRect(position: config_mod.Position, rect: win32.RECT) config_mod.Position {
    const max_x = @max(rect.left, rect.right - SCREEN_EDGE_MARGIN);
    const max_y = @max(rect.top, rect.bottom - SCREEN_EDGE_MARGIN);
    return .{
        .x = std.math.clamp(position.x, rect.left, max_x),
        .y = std.math.clamp(position.y, rect.top, max_y),
    };
}
