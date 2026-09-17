// Global keyboard hotkeys are bound via a WH_KEYBOARD_LL low-level hook rather than
// RegisterHotKey, since RegisterHotKey can't represent a bare-modifier trigger (e.g. "Shift"
// alone, or "Ctrl+Shift" with Shift as the trigger and Ctrl held) - Windows silently refuses
// those combos. Matches are re-posted as WM_HOTKEY, mirroring mouse_hook.zig, so the rest of
// the dispatch pipeline (HotkeyManager.handleHotkeyPress) doesn't need to know whether a press
// came from the mouse or the keyboard.
const std = @import("std");
const win32 = @import("win32.zig");
const vk = @import("virtual_keys.zig");
const log = @import("log.zig");
const slog = log.scoped("keyboard_hook");

var g_bindings: std.AutoHashMap(u32, c_int) = undefined;
var g_swallow_release: std.AutoHashMap(u32, bool) = undefined;
var g_initialized = false;
var g_hook: ?win32.HHOOK = null;
var g_target_hwnd: ?win32.HWND = null;

fn ensureInit(allocator: std.mem.Allocator) void {
    if (g_initialized) return;
    g_bindings = std.AutoHashMap(u32, c_int).init(allocator);
    g_swallow_release = std.AutoHashMap(u32, bool).init(allocator);
    g_initialized = true;
}

/// Register a keyboard hotkey (combined vk from virtual_keys.zig); installs the low-level hook on first registration.
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

/// Remove all keyboard bindings and uninstall the hook; safe to call even if nothing was ever registered.
pub fn unregisterAll() void {
    if (!g_initialized) return;
    g_bindings.clearRetainingCapacity();
    uninstallHook();
}

/// Frees g_bindings/g_swallow_release; call only once at true process shutdown, never from a reload path that may register() again.
pub fn deinit() void {
    if (!g_initialized) return;
    g_bindings.deinit();
    g_swallow_release.deinit();
    g_initialized = false;
}

/// Marks vk_code down to distinguish a repeat WM_HOTKEY from a new press; swallow-on-release is decided later via markSwallowRelease.
/// Mouse-button hotkeys route through handleHotkeyPress too, with vk_code == 0, which is always treated as a fresh press.
pub fn trackPress(allocator: std.mem.Allocator, vk_code: u32) bool {
    if (vk_code == 0) return true;
    ensureInit(allocator);

    const gop = g_swallow_release.getOrPut(vk_code) catch |err| {
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
    if (!g_initialized) return;
    if (g_swallow_release.getPtr(vk_code)) |swallow| swallow.* = true;
}

fn installHook() !void {
    const hmod = win32.GetModuleHandleA(null);
    g_hook = win32.SetWindowsHookExA(win32.WH_KEYBOARD_LL, lowLevelKeyboardProc, hmod, 0);
    if (g_hook == null) {
        slog.err("Failed to install low-level keyboard hook", .{});
        return error.KeyboardHookInstallFailed;
    }
    slog.debug("Low-level keyboard hook installed", .{});
}

fn uninstallHook() void {
    if (g_hook) |hook| {
        _ = win32.UnhookWindowsHookEx(hook);
        g_hook = null;
        slog.debug("Low-level keyboard hook removed", .{});
    }
    g_swallow_release.clearRetainingCapacity();
}

/// WH_KEYBOARD_LL reports the side-specific extended vk for Ctrl/Alt/Shift (e.g. VK_LSHIFT), never
/// the generic one, and only VK_LWIN/VK_RWIN exist for Win - normalize to the generic vk for matching.
fn normalizeModifierVk(raw_vk: u32) u32 {
    return switch (raw_vk) {
        win32.VK_LSHIFT, win32.VK_RSHIFT => vk.VK_SHIFT,
        win32.VK_LCONTROL, win32.VK_RCONTROL => vk.VK_CONTROL,
        win32.VK_LMENU, win32.VK_RMENU => vk.VK_MENU,
        win32.VK_LWIN, win32.VK_RWIN => vk.VK_LWIN,
        else => raw_vk,
    };
}

/// Modifier bit a generic modifier vk itself represents, so it can be excluded from the held-modifiers
/// mask before matching (GetAsyncKeyState already reflects the key's own new state by the time the hook fires).
fn selfModifierBit(base_vk: u32) u32 {
    return switch (base_vk) {
        vk.VK_CONTROL => vk.MOD_CONTROL,
        vk.VK_MENU => vk.MOD_ALT,
        vk.VK_SHIFT => vk.MOD_SHIFT,
        vk.VK_LWIN => vk.MOD_WIN,
        else => 0,
    };
}

/// Look up a bound base virtual key (with the currently-held modifiers, excluding the base key's
/// own modifier identity if it is one) and re-post a match as WM_HOTKEY; returns whether the event should be swallowed.
fn dispatchIfBound(raw_vk: u32) bool {
    const base_vk = normalizeModifierVk(raw_vk);
    const mods = vk.currentModifiers() & ~selfModifierBit(base_vk);
    const combined = vk.combineKey(base_vk, mods);
    if (g_bindings.get(combined)) |id| {
        if (g_target_hwnd) |hwnd| {
            // Encode raw_vk into HIWORD(lParam) like a real WM_HOTKEY message, so hotkeyVkFromLparam/
            // trackPress/markSwallowRelease downstream (hotkeys.zig's handleHotkeyPress) need no changes.
            // Release-swallowing is armed there, not here - only after an action actually moves focus.
            const lparam: win32.LPARAM = @bitCast(@as(usize, raw_vk << 16));
            _ = win32.PostMessageA(hwnd, win32.WM_HOTKEY, @intCast(id), lparam);
        }
        return true;
    }
    return false;
}

fn lowLevelKeyboardProc(nCode: c_int, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    // Per MSDN, a negative nCode must go straight to CallNextHookEx untouched, which the fallthrough below already does.
    if (nCode == win32.HC_ACTION) {
        const info = win32.lparamToPtr(win32.KBDLLHOOKSTRUCT, lParam);
        if (wParam == win32.WM_KEYDOWN or wParam == win32.WM_SYSKEYDOWN) {
            if (dispatchIfBound(info.vkCode)) return 1;
        } else if (wParam == win32.WM_KEYUP or wParam == win32.WM_SYSKEYUP) {
            if (g_swallow_release.fetchRemove(info.vkCode)) |entry| {
                if (entry.value) return 1;
            }
        }
    }
    return win32.CallNextHookEx(null, nCode, wParam, lParam);
}
