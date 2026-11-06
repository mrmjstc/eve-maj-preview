//! The keyboard and mouse hooks as one set of bindings: a key goes to the hook that sees it, and the rest to both.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const vk = @import("../platform/virtual_keys.zig");
const keyboard_hook = @import("keyboard_hook.zig");
const mouse_hook = @import("mouse_hook.zig");
const hook_bindings = @import("hook_bindings.zig");

const HookBindings = hook_bindings.HookBindings;

/// Once at startup, before hook_thread.start.
pub fn setAllocator(allocator: std.mem.Allocator) void {
    keyboard_hook.bindings().setAllocator(allocator);
    mouse_hook.bindings().setAllocator(allocator);
}

/// The hook that sees `combined_vk` re-posts a match to `target_hwnd` as WM_HOTKEY, installing itself on its first binding; logs its own failure.
pub fn register(target_hwnd: win32.HWND, combined_vk: u32, id: c_int) !void {
    try bindingsFor(combined_vk).register(target_hwnd, combined_vk, id);
}

pub fn unregister(combined_vk: u32) void {
    bindingsFor(combined_vk).unregister(combined_vk);
}

pub fn setExactModifiers(is_exact: bool) void {
    keyboard_hook.bindings().setExactModifiers(is_exact);
    mouse_hook.bindings().setExactModifiers(is_exact);
}

/// Safe to call even if nothing was ever registered.
pub fn unregisterAll() void {
    mouse_hook.bindings().unregisterAll();
    keyboard_hook.bindings().unregisterAll();
}

/// Call only once at true process shutdown, before hook_thread.stop, never from a reload path that may register() again.
pub fn deinit() void {
    mouse_hook.bindings().deinit();
    keyboard_hook.bindings().deinit();
}

fn bindingsFor(combined_vk: u32) *HookBindings {
    return if (vk.isMouseHookVk(vk.extractVk(combined_vk))) mouse_hook.bindings() else keyboard_hook.bindings();
}
