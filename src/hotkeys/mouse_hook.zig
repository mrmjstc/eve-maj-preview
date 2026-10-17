//! Mouse button and wheel hotkeys through WH_MOUSE_LL; matches post WM_HOTKEY like keyboard_hook.zig's, from hook_thread.zig's thread.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const vk = @import("../platform/virtual_keys.zig");
const hook_bindings = @import("hook_bindings.zig");

const HookBindings = hook_bindings.HookBindings;

/// The buttons a hotkey can bind; the wheel has no release to follow.
const Button = enum { middle, x1, x2 };

/// Hook thread only.
var g_hook: HookBindings = .{
    .hook_type = win32.WH_MOUSE_LL,
    .proc = lowLevelMouseProc,
    .name = "mouse",
    .on_uninstall = releaseAll,
};
/// Hook thread only: whether each button's current press was swallowed, so its release follows it like keyboard_hook.zig's keys.
var g_swallowed_presses: std.EnumArray(Button, bool) = .initFill(false);

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

fn releaseAll() void {
    g_swallowed_presses = .initFill(false);
}

fn buttonVk(button: Button) u32 {
    return switch (button) {
        .middle => vk.VK_MBUTTON,
        .x1 => vk.VK_XBUTTON1,
        .x2 => vk.VK_XBUTTON2,
    };
}

/// Null for a side button beyond the two Windows names.
fn sideButton(info: *const win32.MSLLHOOKSTRUCT) ?Button {
    return switch (win32.getXButton(info.mouseData)) {
        win32.XBUTTON1 => .x1,
        win32.XBUTTON2 => .x2,
        else => null,
    };
}

/// Whether to swallow it.
fn onButtonDown(button: Button) bool {
    const is_swallowed = g_hook.dispatch(buttonVk(button), vk.currentModifiers(), false);
    g_swallowed_presses.set(button, is_swallowed);
    return is_swallowed;
}

/// Whether to swallow it: only a swallowed press's, so the newly focused client never sees a button-up without its down.
fn onButtonUp(button: Button) bool {
    const was_swallowed = g_swallowed_presses.get(button);
    g_swallowed_presses.set(button, false);
    return was_swallowed;
}

/// Whether to swallow it; each notch is a press of its own.
fn onWheel(info: *const win32.MSLLHOOKSTRUCT) bool {
    const wheel_vk: u32 = if (win32.getWheelDelta(info.mouseData) > 0) vk.VK_WHEELUP else vk.VK_WHEELDOWN;
    return g_hook.dispatch(wheel_vk, vk.currentModifiers(), false);
}

fn lowLevelMouseProc(nCode: c_int, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    // Per MSDN, a negative nCode must go straight to CallNextHookEx untouched, which the fallthrough below already does.
    if (nCode == win32.HC_ACTION) {
        const info = win32.lparamToPtr(win32.MSLLHOOKSTRUCT, lParam);
        const is_swallowed = switch (wParam) {
            win32.WM_MBUTTONDOWN => onButtonDown(.middle),
            win32.WM_MBUTTONUP => onButtonUp(.middle),
            win32.WM_XBUTTONDOWN => if (sideButton(info)) |button| onButtonDown(button) else false,
            win32.WM_XBUTTONUP => if (sideButton(info)) |button| onButtonUp(button) else false,
            win32.WM_MOUSEWHEEL => onWheel(info),
            else => false,
        };
        if (is_swallowed) return 1;
    }
    return win32.CallNextHookEx(null, nCode, wParam, lParam);
}
