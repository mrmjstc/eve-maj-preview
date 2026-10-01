//! Bindings for one low-level input hook, installed only while something is bound, re-posting each match as WM_HOTKEY.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const vk = @import("../platform/virtual_keys.zig");
const log = @import("../log.zig");

const slog = log.scoped("hotkeys");

/// Combined vk to hotkey ID.
pub const HookBindings = struct {
    hook_type: c_int,
    proc: win32.HOOKPROC,
    name: []const u8,
    /// Resets hook-specific state that mustn't outlive the hook, like armed release-swallows.
    on_uninstall: *const fn () void,
    map: ?std.AutoHashMap(u32, c_int) = null,
    hook: ?win32.HHOOK = null,
    target_hwnd: ?win32.HWND = null,
    /// Disables dispatch's bare-key fallback, so an unbound combo passes through.
    exact_modifiers: bool = false,

    /// Installs the hook on first registration.
    pub fn register(self: *HookBindings, allocator: std.mem.Allocator, target_hwnd: win32.HWND, combined_vk: u32, id: c_int) !void {
        if (self.map == null) self.map = .init(allocator);
        const map = &self.map.?;
        self.target_hwnd = target_hwnd;
        try map.put(combined_vk, id);
        if (self.hook == null) {
            self.install() catch |err| {
                _ = map.remove(combined_vk);
                return err;
            };
        }
    }

    pub fn unregister(self: *HookBindings, combined_vk: u32) void {
        const map = if (self.map) |*m| m else return;
        _ = map.remove(combined_vk);
        if (map.count() == 0) self.uninstall();
    }

    /// Safe to call even if nothing was ever registered.
    pub fn unregisterAll(self: *HookBindings) void {
        if (self.map) |*map| map.clearRetainingCapacity();
        self.uninstall();
    }

    /// Call only once at true process shutdown, never from a reload path that may register() again.
    pub fn deinit(self: *HookBindings) void {
        if (self.map) |*map| map.deinit();
        self.map = null;
    }

    pub fn isEmpty(self: *const HookBindings) bool {
        const map = self.map orelse return true;
        return map.count() == 0;
    }

    /// Logs its own failure.
    pub fn install(self: *HookBindings) !void {
        self.hook = win32.SetWindowsHookExA(self.hook_type, self.proc, win32.GetModuleHandleA(null), 0);
        if (self.hook == null) {
            slog.err("Failed to install low-level {s} hook", .{self.name});
            return error.HookInstallFailed;
        }
        slog.debug("Low-level {s} hook installed", .{self.name});
    }

    pub fn uninstall(self: *HookBindings) void {
        if (self.hook) |hook| {
            _ = win32.UnhookWindowsHookEx(hook);
            self.hook = null;
            slog.debug("Low-level {s} hook removed", .{self.name});
        }
        self.on_uninstall();
    }

    /// Whether it matched; unless exact_modifiers, an unbound combo falls back to the bare key's binding, so an unrelated held modifier doesn't block it.
    pub fn dispatch(self: *const HookBindings, base_vk: u32, mods: u32, lparam: win32.LPARAM) bool {
        const map = if (self.map) |*m| m else return false;
        const id = map.get(vk.combineKey(base_vk, mods)) orelse
            (if (mods != 0 and !self.exact_modifiers) map.get(vk.combineKey(base_vk, 0)) else null) orelse
            return false;

        if (self.target_hwnd) |hwnd| {
            _ = win32.PostMessageA(hwnd, win32.WM_HOTKEY, @intCast(id), lparam);
        }
        return true;
    }
};
