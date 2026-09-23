// WH_KEYBOARD_LL rather than RegisterHotKey, since RegisterHotKey can't represent a bare-modifier
// trigger (e.g. plain "Shift"). Matches are re-posted as WM_HOTKEY, mirroring mouse_hook.zig, so
// HotkeyManager.handleHotkeyPress doesn't need to know whether a press came from mouse or keyboard.
const std = @import("std");
const win32 = @import("win32.zig");
const vk = @import("virtual_keys.zig");
const protocol = @import("protocol.zig");
const log = @import("log.zig");
const slog = log.scoped("keyboard_hook");

var g_bindings: std.AutoHashMap(u32, c_int) = undefined;
var g_swallow_release: std.AutoHashMap(u32, bool) = undefined;
var g_initialized = false;
var g_hook: ?win32.HHOOK = null;
var g_target_hwnd: ?win32.HWND = null;
/// Set while the config dialog is recording a new binding; see armWinKeyCapture's doc comment.
var g_capture_win_key = false;

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

/// Call only once at true process shutdown, never from a reload path that may register() again.
pub fn deinit() void {
    if (!g_initialized) return;
    g_bindings.deinit();
    g_swallow_release.deinit();
    g_initialized = false;
}

/// Distinguishes a repeat WM_HOTKEY from a new press; vk_code == 0 (mouse-button hotkeys) is always fresh.
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

/// Recording tears the hook down entirely, so this keeps it alive to swallow Win down/up and report via protocol.publishWinKeyCaptureResult - otherwise Windows pops the Start Menu before the dialog sees anything.
pub fn armWinKeyCapture(allocator: std.mem.Allocator) void {
    ensureInit(allocator);
    g_capture_win_key = true;
    if (g_hook == null) {
        installHook() catch {
            g_capture_win_key = false;
        };
    }
}

pub fn disarmWinKeyCapture() void {
    g_capture_win_key = false;
    if (g_initialized and g_bindings.count() == 0) uninstallHook();
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

/// Re-posts a match as WM_HOTKEY; returns whether the event should be swallowed. Falls back to the
/// bare (no-modifier) binding if the exact combo isn't bound, so an unrelated held modifier doesn't
/// block it; a more specific binding, if one exists, still wins outright.
fn dispatchIfBound(raw_vk: u32) bool {
    const base_vk = normalizeModifierVk(raw_vk);
    const mods = vk.currentModifiers() & ~selfModifierBit(base_vk);
    const combined = vk.combineKey(base_vk, mods);

    var id: c_int = undefined;
    if (g_bindings.get(combined)) |exact_id| {
        id = exact_id;
    } else if (mods != 0) {
        id = g_bindings.get(vk.combineKey(base_vk, 0)) orelse return false;
    } else {
        return false;
    }

    if (g_target_hwnd) |hwnd| {
        // Encode raw_vk into HIWORD(lParam) like a real WM_HOTKEY message, so hotkeyVkFromLparam needs no changes.
        const lparam: win32.LPARAM = @bitCast(@as(usize, raw_vk << 16));
        _ = win32.PostMessageA(hwnd, win32.WM_HOTKEY, @intCast(id), lparam);
    }
    return true;
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
            if (g_capture_win_key and is_win_vk) {
                protocol.publishWinKeyCaptureResult(vk.currentModifiers() & ~vk.MOD_WIN);
                return 1;
            }
            if (g_swallow_release.fetchRemove(info.vkCode)) |entry| {
                if (entry.value) return 1;
            }
        }
    }
    return win32.CallNextHookEx(null, nCode, wParam, lParam);
}
