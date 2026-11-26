//! Keyboard hotkeys through WH_KEYBOARD_LL, which unlike RegisterHotKey can bind a bare modifier; matches post WM_HOTKEY like mouse_hook.zig's, from hook_thread.zig's thread.
const win32 = @import("../platform/win32.zig");
const vk = @import("../platform/virtual_keys.zig");
const hook_bindings = @import("hook_bindings.zig");
const press_rules = @import("press_rules.zig");
const messages = @import("../messages.zig");

const HookBindings = hook_bindings.HookBindings;

/// Hook thread only; pinned while the config dialog records, to capture a bare Win press.
var g_hook: HookBindings = .{
    .hook_type = win32.WH_KEYBOARD_LL,
    .proc = lowLevelKeyboardProc,
    .name = "keyboard",
    .on_uninstall = releaseAll,
};
/// Hook thread only.
var g_presses: press_rules.KeyPresses = .{};
/// Main thread only: given the modifiers held with a bare Win press while the config dialog records; set by the dialog.
pub var g_on_win_key: ?*const fn (modifiers: u32) void = null;

/// For hooks.zig, which sends each binding to the hook that sees it.
pub fn bindings() *HookBindings {
    return &g_hook;
}

/// Keeps the hook alive while the dialog records a binding, to swallow Win and report it to `hwnd`; otherwise the Start Menu opens first.
pub fn armWinKeyCapture(hwnd: win32.HWND) void {
    g_hook.pin(hwnd);
}

pub fn disarmWinKeyCapture() void {
    g_hook.unpin();
}

/// From the timer window's WM_WIN_KEY_CAPTURED; `wParam` holds the other modifiers held with Win.
pub fn onWinKeyCaptured(wParam: win32.WPARAM) void {
    const on_win_key = g_on_win_key orelse return;
    on_win_key(@truncate(wParam));
}

fn releaseAll() void {
    g_presses = .{};
}

fn isWinVk(vk_code: u32) bool {
    return vk_code == vk.VK_LWIN or vk_code == vk.VK_RWIN;
}

/// WH_KEYBOARD_LL reports the side-specific vk for Ctrl/Alt/Shift/Win (e.g. VK_LSHIFT), never the generic one.
fn normalizeModifierVk(raw_vk: u32) u32 {
    return switch (raw_vk) {
        vk.VK_LSHIFT, vk.VK_RSHIFT => vk.VK_SHIFT,
        vk.VK_LCONTROL, vk.VK_RCONTROL => vk.VK_CONTROL,
        vk.VK_LMENU, vk.VK_RMENU => vk.VK_MENU,
        vk.VK_LWIN, vk.VK_RWIN => vk.VK_LWIN,
        else => raw_vk,
    };
}

/// A bare-modifier trigger's own bit, excluded from the held-modifiers mask since GetAsyncKeyState already reflects it as down.
fn selfModifierBit(base_vk: u32) u32 {
    return switch (base_vk) {
        vk.VK_CONTROL => vk.MOD_CONTROL,
        vk.VK_MENU => vk.MOD_ALT,
        vk.VK_SHIFT => vk.MOD_SHIFT,
        vk.VK_LWIN => vk.MOD_WIN,
        else => 0,
    };
}

fn dispatchIfBound(raw_vk: u32, is_repeat: bool) bool {
    if (g_presses.isShiftedNavigation(raw_vk)) {
        if (vk.numpadForNavigation(raw_vk)) |numpad| return g_hook.dispatch(numpad, vk.currentModifiers() | vk.MOD_SHIFT, is_repeat);
    }
    const base_vk = normalizeModifierVk(raw_vk);
    return g_hook.dispatch(base_vk, vk.currentModifiers() & ~selfModifierBit(base_vk), is_repeat);
}

/// Whether to swallow it; a repeat follows its press even if the key's binding changed meanwhile.
fn onKeyDown(vk_code: u8, is_shifted_numpad: bool) bool {
    switch (g_presses.keyDown(vk_code, is_shifted_numpad)) {
        .pass => return false,
        .repeat => {
            _ = dispatchIfBound(vk_code, true);
            return true;
        },
        .first => {
            const is_swallowed = (g_hook.is_pinned and isWinVk(vk_code)) or dispatchIfBound(vk_code, false);
            g_presses.decide(vk_code, is_swallowed);
            return is_swallowed;
        },
    }
}

/// Whether to swallow it; see press_rules.KeyPresses.keyUp.
fn onKeyUp(vk_code: u8) bool {
    if (g_hook.is_pinned and isWinVk(vk_code)) {
        if (g_hook.target_hwnd) |hwnd| _ = win32.PostMessageA(hwnd, messages.WM_WIN_KEY_CAPTURED, vk.currentModifiers() & ~vk.MOD_WIN, 0);
    }
    return g_presses.keyUp(vk_code);
}

fn lowLevelKeyboardProc(nCode: c_int, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    // A negative nCode must go straight to CallNextHookEx, untouched.
    if (nCode == win32.HC_ACTION) {
        const info = win32.lparamToPtr(win32.KBDLLHOOKSTRUCT, lParam);
        if (info.vkCode < g_presses.presses.len) {
            const event: press_rules.KeyEvent = .{
                .vk_code = @intCast(info.vkCode),
                .is_key_up = wParam == win32.WM_KEYUP or wParam == win32.WM_SYSKEYUP,
                .is_extended = info.flags & win32.LLKHF_EXTENDED != 0,
                .timestamp_ms = info.time,
            };
            const is_swallowed = switch (wParam) {
                win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => onKeyDown(event.vk_code, g_presses.isShiftedNumpad(event)),
                win32.WM_KEYUP, win32.WM_SYSKEYUP => onKeyUp(event.vk_code),
                else => false,
            };
            g_presses.noteEvent(event);
            if (is_swallowed) return 1;
        }
    }
    return win32.CallNextHookEx(null, nCode, wParam, lParam);
}
