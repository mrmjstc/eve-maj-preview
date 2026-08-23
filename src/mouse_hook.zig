// RegisterHotKey is keyboard-only and can't bind mouse buttons or the wheel, so this module
// hooks WH_MOUSE_LL instead and re-posts matches as WM_HOTKEY, keeping hotkey dispatch agnostic
// to whether a press came from the mouse or the keyboard.
const std = @import("std");
const win32 = @import("win32.zig");
const vk = @import("virtual_keys.zig");
const log = @import("log.zig");
const slog = log.scoped("mouse_hook");

var g_bindings: std.AutoHashMap(u32, c_int) = undefined;
var g_initialized = false;
var g_hook: ?win32.HHOOK = null;
var g_target_hwnd: ?win32.HWND = null;
var g_swallow_xbutton1_up = false;
var g_swallow_xbutton2_up = false;

fn ensureInit(allocator: std.mem.Allocator) void {
    if (g_initialized) return;
    g_bindings = std.AutoHashMap(u32, c_int).init(allocator);
    g_initialized = true;
}

/// Register a mouse-button hotkey (combined vk from virtual_keys.zig, e.g. XButton1+Ctrl); installs the low-level hook on first registration.
pub fn register(allocator: std.mem.Allocator, target_hwnd: win32.HWND, combined_vk: u32, id: c_int) !void {
    ensureInit(allocator);
    g_target_hwnd = target_hwnd;
    try g_bindings.put(combined_vk, id);
    if (g_hook == null) {
        installHook() catch |err| {
            _ = g_bindings.remove(combined_vk);
            return err;
        };
    }
}

pub fn unregister(combined_vk: u32) void {
    if (!g_initialized) return;
    _ = g_bindings.remove(combined_vk);
    if (g_bindings.count() == 0) uninstallHook();
}

/// Remove all mouse-button bindings and uninstall the hook; safe to call even if nothing was ever registered.
pub fn unregisterAll() void {
    if (!g_initialized) return;
    g_bindings.clearRetainingCapacity();
    uninstallHook();
}

/// Frees g_bindings; call only once at true process shutdown, never from a reload path that may register() again.
pub fn deinit() void {
    if (!g_initialized) return;
    g_bindings.deinit();
    g_initialized = false;
}

fn installHook() !void {
    const hmod = win32.GetModuleHandleA(null);
    g_hook = win32.SetWindowsHookExA(win32.WH_MOUSE_LL, lowLevelMouseProc, hmod, 0);
    if (g_hook == null) {
        slog.err("Failed to install low-level mouse hook", .{});
        return error.MouseHookInstallFailed;
    }
    slog.debug("Low-level mouse hook installed", .{});
}

fn uninstallHook() void {
    if (g_hook) |hook| {
        _ = win32.UnhookWindowsHookEx(hook);
        g_hook = null;
        slog.debug("Low-level mouse hook removed", .{});
    }
    g_swallow_xbutton1_up = false;
    g_swallow_xbutton2_up = false;
}

fn currentModifiers() u32 {
    var mods: u32 = 0;
    if (win32.isCtrlPressed()) mods |= vk.MOD_CONTROL;
    if (win32.isAltPressed()) mods |= vk.MOD_ALT;
    if (win32.isShiftPressed()) mods |= vk.MOD_SHIFT;
    if (win32.isWinPressed()) mods |= vk.MOD_WIN;
    return mods;
}

/// Look up a bound base virtual key (with the currently-held modifiers) and re-post a match as WM_HOTKEY; returns whether the event should be swallowed.
fn dispatchIfBound(base_vk: u32) bool {
    const combined = vk.combineKey(base_vk, currentModifiers());
    if (g_bindings.get(combined)) |id| {
        if (g_target_hwnd) |hwnd| {
            _ = win32.PostMessageA(hwnd, win32.WM_HOTKEY, @intCast(id), 0);
        }
        return true;
    }
    return false;
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
            // Swallow the click, matching RegisterHotKey's exclusive-capture semantics.
            if (button_vk) |base_vk| {
                if (dispatchIfBound(base_vk)) {
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
            // Swallow the scroll, matching RegisterHotKey's exclusive-capture semantics.
            if (dispatchIfBound(wheel_vk)) return 1;
        }
    }
    return win32.CallNextHookEx(null, nCode, wParam, lParam);
}
