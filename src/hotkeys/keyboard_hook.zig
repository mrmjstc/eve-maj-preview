//! Keyboard hotkeys through WH_KEYBOARD_LL, which unlike RegisterHotKey can bind a bare modifier; matches post WM_HOTKEY like mouse_hook.zig's.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const vk = @import("../platform/virtual_keys.zig");
const dialog_events = @import("../dialog/events.zig");
const HookBindings = @import("hook_bindings.zig").HookBindings;
const log = @import("../log.zig");

const slog = log.scoped("keyboard_hook");

var g_hook: HookBindings = .{
    .hook_type = win32.WH_KEYBOARD_LL,
    .proc = lowLevelKeyboardProc,
    .name = "keyboard",
    .on_uninstall = clearSwallowState,
};
/// Held hotkey keys; the value is whether to swallow the key's release.
var g_swallow_release: ?std.AutoHashMap(u32, bool) = null;
/// Set while the config dialog is recording a new binding; see armWinKeyCapture's doc comment.
var g_capture_win_key = false;

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
    if (g_swallow_release) |*map| map.deinit();
    g_swallow_release = null;
}

fn clearSwallowState() void {
    if (g_swallow_release) |*map| map.clearRetainingCapacity();
}

/// Distinguishes a repeat WM_HOTKEY from a new press; vk_code == 0 (mouse-button hotkeys) is always fresh.
pub fn trackPress(allocator: std.mem.Allocator, vk_code: u32) bool {
    if (vk_code == 0) return true;
    if (g_swallow_release == null) g_swallow_release = .init(allocator);

    const gop = g_swallow_release.?.getOrPut(vk_code) catch |err| {
        slog.warn("Failed to track hotkey press for vk 0x{X}: {}", .{ vk_code, err });
        return true;
    };
    if (gop.found_existing) return false;

    gop.value_ptr.* = false;
    return true;
}

/// Arms release-swallowing for vk_code once its action has moved focus, so the previously-focused client still believes the key is held.
pub fn markSwallowRelease(vk_code: u32) void {
    if (vk_code == 0) return;
    const map = if (g_swallow_release) |*m| m else return;
    if (map.getPtr(vk_code)) |swallow| swallow.* = true;
}

/// Keeps the hook alive while the dialog records a binding, to swallow Win and report it; otherwise the Start Menu opens first.
pub fn armWinKeyCapture() void {
    g_capture_win_key = true;
    if (g_hook.hook == null) {
        g_hook.install() catch {
            g_capture_win_key = false;
        };
    }
}

pub fn disarmWinKeyCapture() void {
    g_capture_win_key = false;
    if (g_hook.isEmpty()) g_hook.uninstall();
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

fn dispatchIfBound(raw_vk: u32) bool {
    const base_vk = normalizeModifierVk(raw_vk);
    // Encode raw_vk into HIWORD(lParam) like a real WM_HOTKEY message, so hotkeyVkFromLparam needs no changes.
    const lparam: win32.LPARAM = @bitCast(@as(usize, raw_vk << 16));
    return g_hook.dispatch(base_vk, vk.currentModifiers() & ~selfModifierBit(base_vk), lparam);
}

fn lowLevelKeyboardProc(nCode: c_int, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    // Per MSDN, a negative nCode must go straight to CallNextHookEx untouched, which the fallthrough below already does.
    if (nCode == win32.HC_ACTION) {
        const info = win32.lparamToPtr(win32.KBDLLHOOKSTRUCT, lParam);
        const is_win_vk = info.vkCode == win32.VK_LWIN or info.vkCode == win32.VK_RWIN;
        if (wParam == win32.WM_KEYDOWN or wParam == win32.WM_SYSKEYDOWN) {
            if (g_capture_win_key and is_win_vk) return 1;
            if (dispatchIfBound(info.vkCode)) return 1;
        } else if (wParam == win32.WM_KEYUP or wParam == win32.WM_SYSKEYUP) {
            // The conduit hotkey only consumes the down; a stray up reaching the new client makes it drop held modifiers.
            if (info.vkCode == vk.VK_FOCUS_GRANT) return 1;
            if (g_capture_win_key and is_win_vk) {
                dialog_events.winKeyCaptured(vk.currentModifiers() & ~vk.MOD_WIN);
                return 1;
            }
            if (g_swallow_release) |*map| {
                if (map.fetchRemove(info.vkCode)) |entry| {
                    if (entry.value) return 1;
                }
            }
        }
    }
    return win32.CallNextHookEx(null, nCode, wParam, lParam);
}
