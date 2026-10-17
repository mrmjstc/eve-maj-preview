//! Keyboard hotkeys through WH_KEYBOARD_LL, which unlike RegisterHotKey can bind a bare modifier; matches post WM_HOTKEY like mouse_hook.zig's, from hook_thread.zig's thread.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const vk = @import("../platform/virtual_keys.zig");
const hook_bindings = @import("hook_bindings.zig");

const HookBindings = hook_bindings.HookBindings;

/// How a key's current press was decided at its first key-down; its repeats and release follow, so an app sees whole presses or none.
const Press = enum { released, swallowed, passed };

/// Hook thread only; pinned while the config dialog records, to capture a bare Win press.
var g_hook: HookBindings = .{
    .hook_type = win32.WH_KEYBOARD_LL,
    .proc = lowLevelKeyboardProc,
    .name = "keyboard",
    .on_uninstall = releaseAll,
};
/// Hook thread only; indexed by the raw vk code.
var g_presses: [256]Press = @splat(.released);
/// Main thread only: given the modifiers held with a bare Win press while the config dialog records; set by the dialog.
pub var g_on_win_key: ?*const fn (modifiers: u32) void = null;

/// Installs the hook on first registration; logs its own failure.
pub fn register(allocator: std.mem.Allocator, target_hwnd: win32.HWND, combined_vk: u32, id: c_int) !void {
    try g_hook.register(allocator, target_hwnd, combined_vk, id);
}

pub fn unregister(combined_vk: u32) void {
    g_hook.unregister(combined_vk);
}

pub fn setExactModifiers(is_exact: bool) void {
    g_hook.setExactModifiers(is_exact);
}

/// Safe to call even if nothing was ever registered.
pub fn unregisterAll() void {
    g_hook.unregisterAll();
}

/// Call only once at true process shutdown, before hook_thread.stop, never from a reload path that may register() again.
pub fn deinit() void {
    g_hook.deinit();
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
    g_presses = @splat(.released);
}

fn isWinVk(vk_code: u32) bool {
    return vk_code == win32.VK_LWIN or vk_code == win32.VK_RWIN;
}

/// WH_KEYBOARD_LL reports the side-specific vk for Ctrl/Alt/Shift/Win (e.g. VK_LSHIFT), never the generic one.
fn normalizeModifierVk(raw_vk: u32) u32 {
    return switch (raw_vk) {
        win32.VK_LSHIFT, win32.VK_RSHIFT => vk.VK_SHIFT,
        win32.VK_LCONTROL, win32.VK_RCONTROL => vk.VK_CONTROL,
        win32.VK_LMENU, win32.VK_RMENU => vk.VK_MENU,
        win32.VK_LWIN, win32.VK_RWIN => vk.VK_LWIN,
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
    const base_vk = normalizeModifierVk(raw_vk);
    return g_hook.dispatch(base_vk, vk.currentModifiers() & ~selfModifierBit(base_vk), is_repeat);
}

/// Whether to swallow it; a repeat follows its press even if the key's binding changed meanwhile.
fn onKeyDown(vk_code: u8) bool {
    switch (g_presses[vk_code]) {
        .passed => return false,
        .swallowed => {
            _ = dispatchIfBound(vk_code, true);
            return true;
        },
        .released => {
            const is_swallowed = (g_hook.is_pinned and isWinVk(vk_code)) or dispatchIfBound(vk_code, false);
            g_presses[vk_code] = if (is_swallowed) .swallowed else .passed;
            return is_swallowed;
        },
    }
}

/// Whether to swallow it: a client given a key-up it never saw go down drops its held modifiers, which would break holding Ctrl through a cycle.
fn onKeyUp(vk_code: u8) bool {
    const press = g_presses[vk_code];
    g_presses[vk_code] = .released;
    // The conduit hotkey only consumes the down; a stray up reaching the new client makes it drop held modifiers.
    if (vk_code == vk.VK_FOCUS_GRANT) return true;
    if (g_hook.is_pinned and isWinVk(vk_code)) {
        if (g_hook.target_hwnd) |hwnd| _ = win32.PostMessageA(hwnd, win32.WM_WIN_KEY_CAPTURED, vk.currentModifiers() & ~vk.MOD_WIN, 0);
    }
    return press == .swallowed;
}

fn lowLevelKeyboardProc(nCode: c_int, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    // Per MSDN, a negative nCode must go straight to CallNextHookEx untouched, which the fallthrough below already does.
    if (nCode == win32.HC_ACTION) {
        const info = win32.lparamToPtr(win32.KBDLLHOOKSTRUCT, lParam);
        if (info.vkCode < g_presses.len) {
            const vk_code: u8 = @intCast(info.vkCode);
            const is_swallowed = switch (wParam) {
                win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => onKeyDown(vk_code),
                win32.WM_KEYUP, win32.WM_SYSKEYUP => onKeyUp(vk_code),
                else => false,
            };
            if (is_swallowed) return 1;
        }
    }
    return win32.CallNextHookEx(null, nCode, wParam, lParam);
}
