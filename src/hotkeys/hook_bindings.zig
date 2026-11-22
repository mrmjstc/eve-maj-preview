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
    /// Combined vk to hotkey ID; null until setAllocator.
    map: ?std.AutoHashMap(u32, c_int) = null,
    hook: ?win32.HHOOK = null,
    target_hwnd: ?win32.HWND = null,
    /// Disables dispatch's bare-key fallback, so an unbound combo passes through.
    requires_exact_modifiers: bool = false,
    /// Keeps the hook installed with nothing bound, e.g. while the config dialog records a key.
    is_pinned: bool = false,

    const Change = union(enum) {
        register: struct { target_hwnd: win32.HWND, combined_vk: u32, id: c_int },
        unregister: u32,
        unregister_all,
        requires_exact_modifiers: bool,
        pin: win32.HWND,
        unpin,
        deinit,
    };

    const HookChange = enum { none, installed, removed };

    const ChangeRequest = struct {
        bindings: *HookBindings,
        change: Change,
        /// Stays an error unless the hook thread runs the change.
        result: anyerror!void = error.HookThreadUnreachable,
        /// What the change did to the hook, for the main thread to log once the call returns.
        hook_change: HookChange = .none,
        /// GetLastError of a failed install, for the main thread to log.
        install_error: ?win32.DWORD = null,

        fn run(request: *ChangeRequest) void {
            request.result = request.bindings.apply(request.change, request);
        }
    };

    /// Once at startup, before hook_thread.start, so no other thread can reach the map yet; `allocator` must outlive deinit.
    pub fn setAllocator(self: *HookBindings, allocator: std.mem.Allocator) void {
        self.map = .init(allocator);
    }

    /// Installs the hook on first registration, logging if that fails; error.AlreadyBound, unlogged, when another ID holds the combo, which keeps it.
    pub fn register(self: *HookBindings, target_hwnd: win32.HWND, combined_vk: u32, id: c_int) !void {
        var pending: ChangeRequest = .{
            .bindings = self,
            .change = .{ .register = .{ .target_hwnd = target_hwnd, .combined_vk = combined_vk, .id = id } },
        };
        _ = hook_thread.call(&pending, ChangeRequest.run);
        self.logHookChange(&pending);
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

    /// Hook thread only; whether it posted, an unbound combo using its bare key's binding unless requires_exact_modifiers, so a held modifier can't block it.
    pub fn dispatch(self: *const HookBindings, base_vk: u32, modifiers: u32, is_repeat: bool) bool {
        const map = if (self.map) |*m| m else return false;
        const id = map.get(vk.combineKey(base_vk, modifiers)) orelse
            (if (modifiers != 0 and !self.requires_exact_modifiers) map.get(vk.combineKey(base_vk, 0)) else null) orelse
            return false;
        if (!g_focus_filter.allows(id)) return false;

        if (self.target_hwnd) |hwnd| {
            if (!win32.toBool(win32.PostMessageA(hwnd, win32.WM_HOTKEY, @intCast(id), if (is_repeat) REPEAT_LPARAM else 0))) {
                g_last_post_error.store(win32.GetLastError(), .monotonic);
                _ = g_failed_post_count.fetchAdd(1, .monotonic);
            }
        }
        return true;
    }

    /// For changes the caller needs nothing back from: a failed install is logged by logHookChange.
    fn send(self: *HookBindings, change: Change) void {
        var pending: ChangeRequest = .{ .bindings = self, .change = change };
        _ = hook_thread.call(&pending, ChangeRequest.run);
        self.logHookChange(&pending);
    }

    /// Main thread, once `call` returns; `name` never changes, so reading it here is safe.
    fn logHookChange(self: *const HookBindings, request: *const ChangeRequest) void {
        if (request.install_error) |install_error| slog.err("Failed to install low-level {s} hook: error {d}", .{ self.name, install_error });
        switch (request.hook_change) {
            .none => {},
            .installed => slog.debug("Low-level {s} hook installed", .{self.name}),
            .removed => slog.debug("Low-level {s} hook removed", .{self.name}),
        }
    }

    fn apply(self: *HookBindings, change: Change, request: *ChangeRequest) !void {
        switch (change) {
            .register => |binding| try self.add(binding.target_hwnd, binding.combined_vk, binding.id, request),
            .unregister => |combined_vk| {
                if (self.map) |*map| _ = map.remove(combined_vk);
                self.uninstallIfUnused(request);
            },
            .unregister_all => {
                if (self.map) |*map| map.clearRetainingCapacity();
                self.uninstallIfUnused(request);
            },
            .requires_exact_modifiers => |is_exact| self.requires_exact_modifiers = is_exact,
            .pin => |target_hwnd| {
                self.target_hwnd = target_hwnd;
                if (self.hook == null) try self.install(request);
                self.is_pinned = true;
            },
            .unpin => {
                self.is_pinned = false;
                self.uninstallIfUnused(request);
            },
            .deinit => {
                self.uninstall(request);
                if (self.map) |*map| map.deinit();
                self.map = null;
            },
        }
    }

    fn add(self: *HookBindings, target_hwnd: win32.HWND, combined_vk: u32, id: c_int, request: *ChangeRequest) !void {
        const map = if (self.map) |*m| m else return error.MissingAllocator;
        if (map.get(combined_vk)) |bound_id| {
            if (bound_id != id) return error.AlreadyBound;
        }
        self.target_hwnd = target_hwnd;
        try map.put(combined_vk, id);
        if (self.hook == null) {
            self.install(request) catch |err| {
                _ = map.remove(combined_vk);
                return err;
            };
        }
    }

    fn isEmpty(self: *const HookBindings) bool {
        const map = self.map orelse return true;
        return map.count() == 0;
    }

    /// Records a failure in `request` for logHookChange rather than logging it here.
    fn install(self: *HookBindings, request: *ChangeRequest) !void {
        self.hook = win32.SetWindowsHookExA(self.hook_type, self.proc, win32.GetModuleHandleA(null), 0);
        if (self.hook == null) {
            request.install_error = win32.GetLastError();
            return error.HookInstallFailed;
        }
        request.hook_change = .installed;
    }

    fn uninstallIfUnused(self: *HookBindings, request: *ChangeRequest) void {
        if (self.is_pinned or !self.isEmpty()) return;
        self.uninstall(request);
    }

    fn uninstall(self: *HookBindings, request: *ChangeRequest) void {
        if (self.hook) |hook| {
            _ = win32.UnhookWindowsHookEx(hook);
            self.hook = null;
            request.hook_change = .removed;
        }
        self.on_uninstall();
    }
};

/// Hook thread only.
var g_focus_filter: FocusFilter = .{};
/// Matches the hook thread couldn't post; it counts them rather than logging, and logFailedPosts logs and clears them on the main thread.
var g_failed_post_count: std.atomic.Value(u32) = .init(0);
/// GetLastError of the latest failed post; written by the hook thread, read by logFailedPosts.
var g_last_post_error: std.atomic.Value(win32.DWORD) = .init(0);

/// Main thread, per tick: logs the hotkey presses the hook thread couldn't pass on since the last call.
pub fn logFailedPosts() void {
    const failed_count = g_failed_post_count.swap(0, .monotonic);
    if (failed_count == 0) return;
    slog.err("Failed to pass on {d} hotkey press(es): error {d}", .{ failed_count, g_last_post_error.load(.monotonic) });
}

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
