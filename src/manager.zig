const std = @import("std");
const win32 = @import("win32.zig");
const config_mod = @import("config.zig");
const scout_mod = @import("scout.zig");
const input = @import("input.zig");
const log = @import("log.zig");
const slog = log.scoped("manager");

/// Owns timer state for the auto-minimize feature.
pub const WindowManager = struct {
    /// 0 means no active timer.
    minimize_timer_id: usize = 0,
    /// Window that should not be minimized when the timer fires.
    hwnd_to_activate: ?win32.HWND = null,

    pub fn init() WindowManager {
        return .{};
    }

    pub fn startAutoMinimizeTimer(
        self: *WindowManager,
        hwnd_to_keep: win32.HWND,
        timer_owner_hwnd: win32.HWND,
        config: *const config_mod.Config,
    ) void {
        if (!config.autoMinimize.enabled) return;

        if (self.minimize_timer_id != 0) {
            _ = win32.KillTimer(timer_owner_hwnd, self.minimize_timer_id);
            self.minimize_timer_id = 0;
        }

        self.hwnd_to_activate = hwnd_to_keep;

        // Timer ID 1 is reserved for the main loop, so use 2 here.
        const timer_id: usize = 2;
        self.minimize_timer_id = win32.SetTimer(
            timer_owner_hwnd,
            timer_id,
            config.autoMinimize.delayMs,
            null,
        );

        if (self.minimize_timer_id == 0) {
            slog.err("Failed to start auto-minimize timer", .{});
        }
    }

    /// Minimize all inactive windows (called when auto-minimize timer fires); caller must have already cancelled the timer.
    pub fn minimizeInactiveWindows(
        self: *WindowManager,
        eve_windows: []const scout_mod.EveWindow,
        config: *const config_mod.Config,
    ) void {
        const hwnd_to_keep = self.hwnd_to_activate orelse return;

        var minimized_count: usize = 0;
        for (eve_windows) |eve_window| {
            if (eve_window.hwnd == hwnd_to_keep) continue;
            if (!win32.isWindow(eve_window.hwnd)) continue;
            if (config.isExcludedFromMinimize(eve_window.character_name)) {
                continue;
            }

            _ = win32.ShowWindowAsync(eve_window.hwnd, win32.SW_FORCEMINIMIZE);
            minimized_count += 1;
        }

        if (minimized_count > 0) {
            slog.info("Auto-minimized {} inactive window(s)", .{minimized_count});
            // Batch-minimizing other windows can transiently steal focus.
            if (win32.isWindow(hwnd_to_keep)) input.forceSetForegroundWindow(hwnd_to_keep);
        }

        self.hwnd_to_activate = null;
    }

    pub fn cancelAutoMinimizeTimer(self: *WindowManager, timer_owner_hwnd: win32.HWND) void {
        if (self.minimize_timer_id != 0) {
            _ = win32.KillTimer(timer_owner_hwnd, self.minimize_timer_id);
            self.minimize_timer_id = 0;
        }
    }
};

/// Minimize all EVE client windows (hotkey action), regardless of their current state
pub fn minimizeAllClients(eve_windows: []const scout_mod.EveWindow) void {
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

/// Kept clear of the virtual screen edges so a restored window's title bar stays grabbable.
const SCREEN_EDGE_MARGIN: i32 = 30;

/// Clamps `pos` to the current virtual screen, in case the screen configuration changed since save.
fn clampToVirtualScreen(pos: config_mod.Position) config_mod.Position {
    const screen_left: i32 = win32.GetSystemMetrics(win32.SM_XVIRTUALSCREEN);
    const screen_top: i32 = win32.GetSystemMetrics(win32.SM_YVIRTUALSCREEN);
    const screen_width: i32 = win32.GetSystemMetrics(win32.SM_CXVIRTUALSCREEN);
    const screen_height: i32 = win32.GetSystemMetrics(win32.SM_CYVIRTUALSCREEN);

    const max_x = @max(screen_left, screen_left + screen_width - SCREEN_EDGE_MARGIN);
    const max_y = @max(screen_top, screen_top + screen_height - SCREEN_EDGE_MARGIN);

    return .{
        .x = std.math.clamp(pos.x, screen_left, max_x),
        .y = std.math.clamp(pos.y, screen_top, max_y),
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

    const clamped = clampToVirtualScreen(pos);
    _ = win32.SetWindowPos(hwnd, win32.HWND_NOTOPMOST, clamped.x, clamped.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
}

/// Move every EVE client window with a saved position to that position (hotkey action / auto-move-on-login).
pub fn moveAllClientsToSavedPositions(eve_windows: []const scout_mod.EveWindow, config: *const config_mod.Config) void {
    slog.info("Moving all EVE clients to saved positions (hotkey action)", .{});

    var moved_count: usize = 0;
    for (eve_windows) |eve_window| {
        const pos = config.getCharacterWindowPosition(eve_window.character_name) orelse continue;
        moveClientToPosition(eve_window.hwnd, pos);
        moved_count += 1;
        slog.debug("Moved {s} to saved position ({}, {})", .{ eve_window.character_name, pos.x, pos.y });
    }

    if (moved_count > 0) {
        slog.info("Moved {} EVE client(s) to saved positions", .{moved_count});
    } else {
        slog.debug("No EVE clients have a saved position", .{});
    }
}

/// Close all EVE client windows (hotkey action), except those in the exclude list
pub fn closeAllClients(eve_windows: []const scout_mod.EveWindow, config: *const config_mod.Config) void {
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
