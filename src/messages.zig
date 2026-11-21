//! The app's own window messages and the timer window's timer IDs, each kept unique here.
const std = @import("std");
const win32 = @import("platform/win32.zig");

pub const WM_TRAYICON = win32.WM_USER + 1;
pub const WM_SWITCH_PROFILE = win32.WM_APP + 4;
pub const WM_HOTKEYS_STATE_CHANGED = win32.WM_APP + 12;
pub const WM_KNOTS_COMMAND = win32.WM_APP + 16;
/// Posted to the hotkey hook thread, with a request in lParam.
pub const WM_HOOK_REQUEST = win32.WM_APP + 20;
/// Posted to the timer window when the config dialog records a bare Win press; wParam holds the other held modifiers.
pub const WM_WIN_KEY_CAPTURED = win32.WM_APP + 21;

pub const TICK_TIMER_ID: usize = 1;
/// Auto-hides every thumbnail once no EVE window has had focus for hideDebounceMs.
pub const HIDE_DEBOUNCE_TIMER_ID: usize = 2;

comptime {
    const message_ids = [_]win32.UINT{ WM_TRAYICON, WM_SWITCH_PROFILE, WM_HOTKEYS_STATE_CHANGED, WM_KNOTS_COMMAND, WM_HOOK_REQUEST, WM_WIN_KEY_CAPTURED };
    for (message_ids, 0..) |id, index| {
        if (std.mem.indexOfScalar(win32.UINT, message_ids[index + 1 ..], id) != null) @compileError(std.fmt.comptimePrint("window message {d} is defined twice", .{id}));
    }
    if (TICK_TIMER_ID == HIDE_DEBOUNCE_TIMER_ID) @compileError("the timer window's timers share an ID");
}
