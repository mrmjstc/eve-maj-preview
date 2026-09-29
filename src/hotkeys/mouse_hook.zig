//! Mouse button and wheel hotkeys through WH_MOUSE_LL; matches post WM_HOTKEY like keyboard_hook.zig's.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const vk = @import("../platform/virtual_keys.zig");
const HookBindings = @import("hook_bindings.zig").HookBindings;

var g_hook: HookBindings = .{
    .hook_type = win32.WH_MOUSE_LL,
    .proc = lowLevelMouseProc,
    .name = "mouse",
    .on_uninstall = clearSwallowState,
};
var g_swallow_xbutton1_up = false;
var g_swallow_xbutton2_up = false;

/// Installs the hook on first registration.
pub fn register(allocator: std.mem.Allocator, target_hwnd: win32.HWND, combined_vk: u32, id: c_int) !void {
    try g_hook.register(allocator, target_hwnd, combined_vk, id);
}

pub fn unregister(combined_vk: u32) void {
    g_hook.unregister(combined_vk);
}

/// Safe to call even if nothing was ever registered.
pub fn unregisterAll() void {
    g_hook.unregisterAll();
}

/// Call only once at true process shutdown, never from a reload path that may register() again.
pub fn deinit() void {
    g_hook.deinit();
}

fn clearSwallowState() void {
    g_swallow_xbutton1_up = false;
    g_swallow_xbutton2_up = false;
}

fn lowLevelMouseProc(nCode: c_int, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    // Per MSDN, a negative nCode must go straight to CallNextHookEx untouched, which the fallthrough below already does.
    if (nCode >= 0) {
        if (wParam == win32.WM_XBUTTONDOWN) {
            const info = win32.lparamToPtr(win32.MSLLHOOKSTRUCT, lParam);
            const button = win32.getXButton(info.mouseData);
            const button_vk: ?u32 = switch (button) {
                win32.XBUTTON1 => vk.VK_XBUTTON1,
                win32.XBUTTON2 => vk.VK_XBUTTON2,
                else => null,
            };
            // Swallow the click so the underlying app never sees it.
            if (button_vk) |base_vk| {
                if (g_hook.dispatch(base_vk, vk.currentModifiers(), 0)) {
                    // Arm the matching release swallow so the newly-focused client doesn't see a phantom button-up.
                    switch (button) {
                        win32.XBUTTON1 => g_swallow_xbutton1_up = true,
                        win32.XBUTTON2 => g_swallow_xbutton2_up = true,
                        else => {},
                    }
                    return 1;
                }
            }
        } else if (wParam == win32.WM_XBUTTONUP) {
            const info = win32.lparamToPtr(win32.MSLLHOOKSTRUCT, lParam);
            switch (win32.getXButton(info.mouseData)) {
                win32.XBUTTON1 => if (g_swallow_xbutton1_up) {
                    g_swallow_xbutton1_up = false;
                    return 1;
                },
                win32.XBUTTON2 => if (g_swallow_xbutton2_up) {
                    g_swallow_xbutton2_up = false;
                    return 1;
                },
                else => {},
            }
        } else if (wParam == win32.WM_MOUSEWHEEL) {
            const info = win32.lparamToPtr(win32.MSLLHOOKSTRUCT, lParam);
            const wheel_vk: u32 = if (win32.getWheelDelta(info.mouseData) > 0) vk.VK_WHEELUP else vk.VK_WHEELDOWN;
            // Swallow the scroll so the underlying app never sees it.
            if (g_hook.dispatch(wheel_vk, vk.currentModifiers(), 0)) return 1;
        }
    }
    return win32.CallNextHookEx(null, nCode, wParam, lParam);
}
