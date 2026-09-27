// SetForegroundWindow silently refuses unless the caller just received real input, which a hotkey
// dispatched via the low-level keyboard/mouse hooks doesn't carry. A permanently-registered, physically
// unreachable RegisterHotKey "conduit" binding stays alive purely to borrow that exemption on demand.
const win32 = @import("win32.zig");
const virtual_keys = @import("virtual_keys.zig");
const log = @import("../log.zig");
const slog = log.scoped("focus_grant");

const FOCUS_GRANT_VK: win32.UINT = virtual_keys.VK_FOCUS_GRANT;
const FOCUS_GRANT_ID_BASE: c_int = 9000;
// MOD_ALT|MOD_CONTROL|MOD_SHIFT|MOD_WIN occupy bits 0-3, so every value 0-15 is already a valid combo.
const FOCUS_GRANT_COMBO_COUNT: u32 = 16;

var g_focus_grant_hwnd: ?win32.HWND = null;
var g_focus_grant_target: ?win32.HWND = null;
/// The switch is async, so callers can't detect it via GetForegroundWindow right after requesting it.
pub var g_focus_switch_requested = false;

/// Call once at startup.
pub fn install(hwnd: win32.HWND) void {
    g_focus_grant_hwnd = hwnd;
    for (0..FOCUS_GRANT_COMBO_COUNT) |i| {
        const mods: win32.UINT = @intCast(i);
        const id = FOCUS_GRANT_ID_BASE + @as(c_int, @intCast(i));
        if (!win32.toBool(win32.RegisterHotKey(hwnd, id, mods, FOCUS_GRANT_VK))) {
            slog.err("Failed to register foreground-grant conduit hotkey {} (mods=0x{X})", .{ id, mods });
        }
    }
}

/// Call once at shutdown.
pub fn uninstall() void {
    const hwnd = g_focus_grant_hwnd orelse return;
    for (0..FOCUS_GRANT_COMBO_COUNT) |i| {
        _ = win32.UnregisterHotKey(hwnd, FOCUS_GRANT_ID_BASE + @as(c_int, @intCast(i)));
    }
    g_focus_grant_hwnd = null;
}

/// Returns false if id isn't the conduit hotkey, so the caller can dispatch it normally.
pub fn handleWmHotkey(id: c_int) bool {
    if (id < FOCUS_GRANT_ID_BASE or id >= FOCUS_GRANT_ID_BASE + @as(c_int, @intCast(FOCUS_GRANT_COMBO_COUNT))) return false;

    const target = g_focus_grant_target orelse return true;
    // Worth one immediate retry rather than leaving the user stuck on the wrong window.
    if (!win32.toBool(win32.SetForegroundWindow(target))) {
        _ = win32.SetForegroundWindow(target);
    }
    _ = win32.SetFocus(target);
    return true;
}

/// Direct SetForegroundWindow is a same-process fast path; the conduit hotkey is the reliable
/// (async) path for the cross-process case, which plain SetForegroundWindow can't do alone.
pub fn forceSetForegroundWindow(target_hwnd: win32.HWND) void {
    _ = win32.SetForegroundWindow(target_hwnd);
    _ = win32.SetFocus(target_hwnd);

    g_focus_grant_target = target_hwnd;
    g_focus_switch_requested = true;
    // keybd_event only injects this vk, so held modifiers stay held and still match a registration.
    win32.keybd_event(@intCast(FOCUS_GRANT_VK), 0, 0, 0);
    win32.keybd_event(@intCast(FOCUS_GRANT_VK), 0, win32.KEYEVENTF_KEYUP, 0);
}
