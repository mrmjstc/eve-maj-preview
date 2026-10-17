//! Bindings for one low-level input hook, installed only while something is bound, re-posting each match as WM_HOTKEY from hook_thread.zig's thread.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const vk = @import("../platform/virtual_keys.zig");
const hook_thread = @import("hook_thread.zig");
const log = @import("../log.zig");

const slog = log.Scoped("hotkeys");

/// Far more clients and window-filter matches than anyone runs.
const MAX_FOCUS_WINDOWS = 128;
/// WM_HOTKEY's lParam for a key held past its first press.
const REPEAT_LPARAM: win32.LPARAM = 1;

/// What the require-EVE-focus setting checks a match against; built by the main thread, with a copy kept on the hook thread.
pub const FocusFilter = struct {
    is_required: bool = false,
    /// Matches anywhere, so the suspend hotkey still resumes outside EVE.
    exempt_id: ?c_int = null,
    /// Every tracked window, window-filter matches included, as HotkeyManager.foregroundEveWindow counts them.
    windows: [MAX_FOCUS_WINDOWS]win32.HWND = undefined,
    window_count: usize = 0,

    /// False once full, leaving `hwnd` out.
    pub fn add(self: *FocusFilter, hwnd: win32.HWND) bool {
        if (self.window_count == self.windows.len) return false;
        self.windows[self.window_count] = hwnd;
        self.window_count += 1;
        return true;
    }

    pub fn eql(self: *const FocusFilter, other: *const FocusFilter) bool {
        return self.is_required == other.is_required and
            std.meta.eql(self.exempt_id, other.exempt_id) and
            std.mem.eql(win32.HWND, self.windows[0..self.window_count], other.windows[0..other.window_count]);
    }

    fn allows(self: *const FocusFilter, id: c_int) bool {
        if (!self.is_required) return true;
        if (self.exempt_id) |exempt_id| {
            if (id == exempt_id) return true;
        }
        const foreground = win32.GetForegroundWindow() orelse return false;
        return std.mem.indexOfScalar(win32.HWND, self.windows[0..self.window_count], foreground) != null;
    }
};

/// Owned by the hook thread: the main thread changes it only through the pub methods, which run there by hook_thread.call.
pub const HookBindings = struct {
    hook_type: c_int,
    proc: win32.HOOKPROC,
    name: []const u8,
    /// Resets hook-specific state that mustn't outlive the hook, like presses still held.
    on_uninstall: *const fn () void,
    /// Combined vk to hotkey ID.
    map: ?std.AutoHashMap(u32, c_int) = null,
    hook: ?win32.HHOOK = null,
    target_hwnd: ?win32.HWND = null,
    /// Disables dispatch's bare-key fallback, so an unbound combo passes through.
    requires_exact_modifiers: bool = false,
    /// Keeps the hook installed with nothing bound, e.g. while the config dialog records a key.
    is_pinned: bool = false,

    const Change = union(enum) {
        register: struct { allocator: std.mem.Allocator, target_hwnd: win32.HWND, combined_vk: u32, id: c_int },
        unregister: u32,
        unregister_all,
        requires_exact_modifiers: bool,
        pin: win32.HWND,
        unpin,
        deinit,
    };

    const ChangeRequest = struct {
        bindings: *HookBindings,
        change: Change,
        /// Stays an error unless the hook thread runs the change.
        result: anyerror!void = error.HookThreadUnreachable,

        fn run(request: *ChangeRequest) void {
            request.result = request.bindings.apply(request.change);
        }
    };

    /// Installs the hook on first registration; logs its own failure.
    pub fn register(self: *HookBindings, allocator: std.mem.Allocator, target_hwnd: win32.HWND, combined_vk: u32, id: c_int) !void {
        var pending: ChangeRequest = .{ .bindings = self, .change = .{ .register = .{ .allocator = allocator, .target_hwnd = target_hwnd, .combined_vk = combined_vk, .id = id } } };
        _ = hook_thread.call(&pending, ChangeRequest.run);
        return pending.result;
    }

    pub fn unregister(self: *HookBindings, combined_vk: u32) void {
        self.send(.{ .unregister = combined_vk });
    }

    /// Safe to call even if nothing was ever registered.
    pub fn unregisterAll(self: *HookBindings) void {
        self.send(.unregister_all);
    }

    pub fn setExactModifiers(self: *HookBindings, is_exact: bool) void {
        self.send(.{ .requires_exact_modifiers = is_exact });
    }

    /// Keeps the hook installed with nothing bound, posting what it reports to `target_hwnd`.
    pub fn pin(self: *HookBindings, target_hwnd: win32.HWND) void {
        self.send(.{ .pin = target_hwnd });
    }

    pub fn unpin(self: *HookBindings) void {
        self.send(.unpin);
    }

    /// Call only once at true process shutdown, before hook_thread.stop, never from a reload path that may register() again.
    pub fn deinit(self: *HookBindings) void {
        self.send(.deinit);
    }

    /// Hook thread only: whether it matched and was posted; unless requires_exact_modifiers, an unbound combo falls back to the bare key's binding, so an unrelated held modifier doesn't block it.
    pub fn dispatch(self: *const HookBindings, base_vk: u32, modifiers: u32, is_repeat: bool) bool {
        const map = if (self.map) |*m| m else return false;
        const id = map.get(vk.combineKey(base_vk, modifiers)) orelse
            (if (modifiers != 0 and !self.requires_exact_modifiers) map.get(vk.combineKey(base_vk, 0)) else null) orelse
            return false;
        if (!g_focus_filter.allows(id)) return false;

        if (self.target_hwnd) |hwnd| {
            _ = win32.PostMessageA(hwnd, win32.WM_HOTKEY, @intCast(id), if (is_repeat) REPEAT_LPARAM else 0);
        }
        return true;
    }

    /// For changes the caller needs nothing back from: every failure is logged where it happens.
    fn send(self: *HookBindings, change: Change) void {
        var pending: ChangeRequest = .{ .bindings = self, .change = change };
        _ = hook_thread.call(&pending, ChangeRequest.run);
    }

    fn apply(self: *HookBindings, change: Change) !void {
        switch (change) {
            .register => |binding| try self.add(binding.allocator, binding.target_hwnd, binding.combined_vk, binding.id),
            .unregister => |combined_vk| {
                if (self.map) |*map| _ = map.remove(combined_vk);
                self.uninstallIfUnused();
            },
            .unregister_all => {
                if (self.map) |*map| map.clearRetainingCapacity();
                self.uninstallIfUnused();
            },
            .requires_exact_modifiers => |is_exact| self.requires_exact_modifiers = is_exact,
            .pin => |target_hwnd| {
                self.target_hwnd = target_hwnd;
                if (self.hook == null) try self.install();
                self.is_pinned = true;
            },
            .unpin => {
                self.is_pinned = false;
                self.uninstallIfUnused();
            },
            .deinit => {
                self.uninstall();
                if (self.map) |*map| map.deinit();
                self.map = null;
            },
        }
    }

    fn add(self: *HookBindings, allocator: std.mem.Allocator, target_hwnd: win32.HWND, combined_vk: u32, id: c_int) !void {
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

    fn isEmpty(self: *const HookBindings) bool {
        const map = self.map orelse return true;
        return map.count() == 0;
    }

    /// Logs its own failure.
    fn install(self: *HookBindings) !void {
        self.hook = win32.SetWindowsHookExA(self.hook_type, self.proc, win32.GetModuleHandleA(null), 0);
        if (self.hook == null) {
            slog.err("Failed to install low-level {s} hook", .{self.name});
            return error.HookInstallFailed;
        }
        slog.debug("Low-level {s} hook installed", .{self.name});
    }

    fn uninstallIfUnused(self: *HookBindings) void {
        if (self.is_pinned or !self.isEmpty()) return;
        self.uninstall();
    }

    fn uninstall(self: *HookBindings) void {
        if (self.hook) |hook| {
            _ = win32.UnhookWindowsHookEx(hook);
            self.hook = null;
            slog.debug("Low-level {s} hook removed", .{self.name});
        }
        self.on_uninstall();
    }
};

/// Hook thread only.
var g_focus_filter: FocusFilter = .{};

/// Replaces the hook thread's copy; false if it couldn't, which hook_thread.call logs.
pub fn setFocusFilter(filter: FocusFilter) bool {
    var copy = filter;
    return hook_thread.call(&copy, storeFocusFilter);
}

/// Whether a WM_HOTKEY from dispatch is a held key's auto-repeat.
pub fn isRepeat(lParam: win32.LPARAM) bool {
    return lParam == REPEAT_LPARAM;
}

fn storeFocusFilter(filter: *FocusFilter) void {
    g_focus_filter = filter.*;
}
