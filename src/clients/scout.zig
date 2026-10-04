//! Finds EVE client windows and the character in each, via WinEvent hooks between periodic scans.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");

const slog = log.scoped("scout");

/// character_name before login or after logout while the client window stays open.
const GENERIC_CHARACTER_NAME = "EVE";

/// An EVE client's window class; windows of any other class come from user-added window filters.
const EVE_WINDOW_CLASS = "trinityWindow";

pub const EveWindow = struct {
    hwnd: win32.HWND,
    /// Owned by Scout; a copy of an EveWindow borrows it until Scout drops the window.
    character_name: []const u8,
    process_id: win32.DWORD,
    is_eve_client: bool,
    /// When this window last went to the login screen, from Scout.next_logout_order; 0 while logged in.
    logged_out_order: u64 = 0,
    /// Zero at the login screen and for filter windows.
    logged_in_at: win32.Ticks = .{},
    /// False while logged_in_at is only when the character was first seen.
    is_login_time_exact: bool = false,
};

/// Names are owned; freed by UpdateResult.deinit.
pub const NameChange = struct {
    hwnd: win32.HWND,
    old_name: []const u8,
    new_name: []const u8,
    logged_in_at: win32.Ticks,
};

/// character_name isn't unique (multiple windows can all report "EVE"), so hwnd travels with it; owned, freed by UpdateResult.deinit.
pub const ClosedWindow = struct {
    hwnd: win32.HWND,
    character_name: []const u8,
};

pub const UpdateResult = struct {
    windows: []const EveWindow,
    closed_windows: std.ArrayList(ClosedWindow),
    name_changes: std.ArrayList(NameChange),

    pub fn deinit(self: *UpdateResult, allocator: std.mem.Allocator) void {
        freeClosedWindows(allocator, &self.closed_windows);
        freeNameChanges(allocator, &self.name_changes);
    }
};

pub const Scout = struct {
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    windows: std.ArrayList(EveWindow),
    /// Filled by the WinEvent hooks between ticks and handed over by update().
    pending_closed: std.ArrayList(ClosedWindow),
    pending_name_changes: std.ArrayList(NameChange),
    next_logout_order: u64 = 1,
    /// Title-change and destroy hooks per tracked process, so other apps' events never wake us.
    process_hooks: std.AutoHashMap(win32.DWORD, ProcessHooks),
    /// Set when a window stops being tracked; update() then unhooks processes left with none, outside any hook callback.
    process_hooks_stale: bool = false,

    const ProcessHooks = struct {
        name_change: ?win32.HANDLE,
        destroy: ?win32.HANDLE,

        fn unhook(self: ProcessHooks) void {
            if (self.name_change) |hook| _ = win32.UnhookWinEvent(hook);
            if (self.destroy) |hook| _ = win32.UnhookWinEvent(hook);
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: *const config_mod.Config) Scout {
        return .{
            .allocator = allocator,
            .config = config,
            .windows = .empty,
            .pending_closed = .empty,
            .pending_name_changes = .empty,
            .process_hooks = .init(allocator),
        };
    }

    /// Hooks title changes and destroys for `process_id` once its first window is tracked.
    fn watchProcess(self: *Scout, process_id: win32.DWORD) void {
        if (self.process_hooks.contains(process_id)) return;

        const hooks: ProcessHooks = .{
            .name_change = win32.setWinEventHookForProcess(win32.EVENT_OBJECT_NAMECHANGE, nameChangeCallback, process_id),
            .destroy = win32.setWinEventHookForProcess(win32.EVENT_OBJECT_DESTROY, windowDestroyCallback, process_id),
        };
        if (hooks.name_change == null) slog.warn("Failed to hook title changes for pid {} - character name changes will be noticed within a second instead", .{process_id});
        if (hooks.destroy == null) slog.warn("Failed to hook window destroys for pid {} - closed windows will be noticed within a second instead", .{process_id});

        self.process_hooks.put(process_id, hooks) catch |err| {
            slog.err("Failed to record event hooks for pid {}: {}", .{ process_id, err });
            hooks.unhook();
        };
    }

    /// Unhooks every process no tracked window belongs to any more.
    fn unwatchUnusedProcesses(self: *Scout) void {
        if (!self.process_hooks_stale) return;
        self.process_hooks_stale = false;

        var it = self.process_hooks.iterator();
        while (it.next()) |entry| {
            if (self.tracksProcess(entry.key_ptr.*)) continue;
            entry.value_ptr.unhook();
            self.process_hooks.removeByPtr(entry.key_ptr);
            // Removal invalidates the iterator.
            it = self.process_hooks.iterator();
        }
    }

    fn tracksProcess(self: *const Scout, process_id: win32.DWORD) bool {
        for (self.windows.items) |window| {
            if (window.process_id == process_id) return true;
        }
        return false;
    }

    pub fn setGlobalInstance(self: *Scout) void {
        g_scout_ptr = self;
    }

    pub fn deinit(self: *Scout) void {
        g_scout_ptr = null;

        var hooks = self.process_hooks.valueIterator();
        while (hooks.next()) |process_hooks| process_hooks.unhook();
        self.process_hooks.deinit();

        freeClosedWindows(self.allocator, &self.pending_closed);
        freeNameChanges(self.allocator, &self.pending_name_changes);

        for (self.windows.items) |window| self.freeWindow(window);
        self.windows.deinit(self.allocator);
    }

    fn freeWindow(self: *Scout, window: EveWindow) void {
        self.allocator.free(window.character_name);
    }

    fn removeWindowAt(self: *Scout, index: usize) void {
        self.freeWindow(self.windows.orderedRemove(index));
        self.process_hooks_stale = true;
    }

    /// Hands `window` to the next update's closed_windows, so the painter and chatlog let it go like any closed client; false if it couldn't be.
    fn reportClosed(self: *Scout, window: EveWindow) bool {
        const name = self.allocator.dupe(u8, window.character_name) catch |err| {
            slog.err("Failed to allocate closed character name '{s}': {}", .{ window.character_name, err });
            return false;
        };
        self.pending_closed.append(self.allocator, .{ .hwnd = window.hwnd, .character_name = name }) catch |err| {
            slog.err("Failed to add '{s}' to pending closed list: {}", .{ name, err });
            self.allocator.free(name);
            return false;
        };
        return true;
    }

    fn logoutOrder(self: *Scout, character_name: []const u8) u64 {
        if (!isGenericCharacterName(character_name)) return 0;
        defer self.next_logout_order += 1;
        return self.next_logout_order;
    }

    /// Windows at the login screen, oldest logout first; caller frees with allocator.
    pub fn getNotLoggedInHwnds(self: *const Scout, allocator: std.mem.Allocator) !std.ArrayList(win32.HWND) {
        var logged_out: std.ArrayList(EveWindow) = .empty;
        defer logged_out.deinit(allocator);
        for (self.windows.items) |window| {
            if (window.logged_out_order != 0) try logged_out.append(allocator, window);
        }
        std.sort.pdq(EveWindow, logged_out.items, {}, struct {
            fn lessThan(_: void, a: EveWindow, b: EveWindow) bool {
                return a.logged_out_order < b.logged_out_order;
            }
        }.lessThan);

        var result: std.ArrayList(win32.HWND) = .empty;
        errdefer result.deinit(allocator);
        for (logged_out.items) |window| try result.append(allocator, window.hwnd);
        return result;
    }

    pub fn scanForEveWindows(self: *Scout) !void {
        if (!win32.toBool(win32.EnumWindows(enumWindowsCallback, win32.ptrToLparam(self)))) return error.EnumWindowsFailed;
    }

    pub fn getWindows(self: *Scout) []const EveWindow {
        return self.windows.items;
    }

    /// Re-reads hwnd's title and records a NameChange if the character behind it changed.
    fn updateWindowTitle(self: *Scout, hwnd: win32.HWND) void {
        const index = self.indexOf(hwnd) orelse return;
        const eve_window = &self.windows.items[index];
        // A filter's windows are named after the filter, not their title.
        if (!eve_window.is_eve_client) return;

        var title_buf: [64]u8 = undefined;
        const current_title = win32.getWindowTitleBuf(eve_window.hwnd, &title_buf) catch |err| switch (err) {
            error.MissingWindowTitle => return,
            else => {
                slog.err("Failed to get window title for '{s}': {}", .{ eve_window.character_name, err });
                return;
            },
        };

        const new_char_name = extractCharacterName(current_title);
        if (!std.mem.eql(u8, eve_window.character_name, new_char_name)) {
            self.renameWindow(eve_window, new_char_name);
        }
    }

    fn renameWindow(self: *Scout, eve_window: *EveWindow, new_name: []const u8) void {
        const window_name = self.allocator.dupe(u8, new_name) catch |err| {
            slog.err("Failed to allocate character name '{s}': {}", .{ new_name, err });
            return;
        };
        const change_name = self.allocator.dupe(u8, new_name) catch |err| {
            slog.err("Failed to duplicate new character name '{s}': {}", .{ new_name, err });
            self.allocator.free(window_name);
            return;
        };

        // The old name moves into the NameChange rather than being copied.
        const old_name = eve_window.character_name;
        eve_window.character_name = window_name;

        eve_window.logged_out_order = self.logoutOrder(window_name);
        eve_window.logged_in_at = loginTime(eve_window.is_eve_client, window_name);
        eve_window.is_login_time_exact = true;

        slog.info("Character changed: {s} -> {s}", .{ old_name, new_name });

        self.pending_name_changes.append(self.allocator, .{
            .hwnd = eve_window.hwnd,
            .old_name = old_name,
            .new_name = change_name,
            .logged_in_at = eve_window.logged_in_at,
        }) catch |err| {
            slog.err("Failed to track name change '{s}' -> '{s}': {}", .{ old_name, new_name, err });
            self.allocator.free(old_name);
            self.allocator.free(change_name);
        };
    }

    /// Catches windows closed without a destroy event, e.g. when that hook couldn't be installed.
    fn dropClosedWindows(self: *Scout) void {
        var i: usize = self.windows.items.len;
        while (i > 0) {
            i -= 1;
            const window = self.windows.items[i];
            if (win32.isWindow(window.hwnd)) continue;
            if (!self.reportClosed(window)) continue;
            slog.info("Window closed without a destroy event: '{s}' (hwnd {*})", .{ window.character_name, window.hwnd });
            self.removeWindowAt(i);
        }
    }

    /// Catches title changes whose event came before the window was tracked; only on force_scan ticks, as each read is a cross-process call.
    fn refreshTrackedWindowTitles(self: *Scout) void {
        // Iterating by copy is safe: updateWindowTitle may rename entries but never adds or removes them.
        for (self.windows.items) |eve_window| {
            self.updateWindowTitle(eve_window.hwnd);
        }
    }

    /// Once per tick; caller deinits the result.
    pub fn update(self: *Scout, force_scan: bool) UpdateResult {
        if (force_scan) self.dropClosedWindows();
        const closed = self.pending_closed;
        self.pending_closed = .empty;
        const name_changes = self.pending_name_changes;
        self.pending_name_changes = .empty;

        // The only place new windows are found; a creation hook would wake us for every window on the desktop.
        if (force_scan) {
            self.scanForEveWindows() catch |err| {
                slog.warn("Failed to scan for windows, retrying on the next scan: {}", .{err});
            };
            self.refreshTrackedWindowTitles();
        }
        self.unwatchUnusedProcesses();

        return UpdateResult{
            .windows = self.getWindows(),
            .closed_windows = closed,
            .name_changes = name_changes,
        };
    }

    /// "EVE - CharacterName" gives "CharacterName"; the whole title when nothing follows a " - ".
    fn extractCharacterName(title: []const u8) []const u8 {
        const dash_pos = std.mem.indexOf(u8, title, " - ") orelse return title;
        const name = title[dash_pos + " - ".len ..];
        return if (name.len == 0) title else name;
    }

    /// `started_at` is UTC Unix seconds; null if it's outside the client's lifetime.
    pub fn backdateLogin(self: *Scout, hwnd: win32.HWND, started_at: i64, now: i64) ?win32.Ticks {
        const index = self.indexOf(hwnd) orelse return null;
        const eve_window = &self.windows.items[index];
        if (eve_window.logged_in_at.isZero() or eve_window.is_login_time_exact) return null;

        const process_started = win32.processStartTime(eve_window.process_id) orelse {
            slog.warn("Failed to read when the client for '{s}' started, keeping its first-seen login time", .{eve_window.character_name});
            return null;
        };
        // Log names are whole seconds.
        if (started_at < process_started.toUnixSeconds() - 1 or started_at > now) {
            slog.debug("Ignoring gamelog session start for {s}: outside its client's lifetime", .{eve_window.character_name});
            return null;
        }

        const session_ms: u64 = @intCast((now - started_at) * std.time.ms_per_s);
        const backdated: win32.Ticks = .{ .ms = win32.Ticks.now().ms -| session_ms };
        if (backdated.isZero() or backdated.ms >= eve_window.logged_in_at.ms) return null;

        eve_window.logged_in_at = backdated;
        eve_window.is_login_time_exact = true;
        slog.info("Backdated login for {s} by {}s to its gamelog's session start", .{ eve_window.character_name, session_ms / std.time.ms_per_s });
        return backdated;
    }

    /// First live window with this name, which a filter's windows and logged-out clients share.
    pub fn getHwndByName(self: *const Scout, name: []const u8) ?win32.HWND {
        for (self.windows.items) |window| {
            if (std.mem.eql(u8, window.character_name, name) and win32.isWindow(window.hwnd)) return window.hwnd;
        }
        return null;
    }

    fn indexOf(self: *const Scout, hwnd: win32.HWND) ?usize {
        for (self.windows.items, 0..) |window, index| {
            if (window.hwnd == hwnd) return index;
        }
        return null;
    }

    /// First filter matching both class and executable; a null exe_path checks the class alone.
    fn findMatchingFilter(self: *const Scout, class_name: []const u8, exe_path: ?[]const u8) ?*const config_mod.WindowFilterConfig {
        for (self.config.windowFilters.items) |*filter| {
            if (!filter.matchesClass(class_name)) continue;
            if (exe_path) |path| {
                if (!filter.matchesExecutable(path)) continue;
            }
            return filter;
        }
        return null;
    }

    fn currentFilter(self: *const Scout, hwnd: win32.HWND, process_id: win32.DWORD) ?*const config_mod.WindowFilterConfig {
        var class_name: [64:0]u8 = undefined;
        const class_slice = win32.getClassNameBuf(hwnd, &class_name) orelse return null;

        var exe_path: [260:0]u8 = undefined;
        const path_slice = win32.queryProcessExePath(process_id, &exe_path) orelse return null;

        return self.findMatchingFilter(class_slice, path_slice);
    }

    /// Drops windows no filter matches any more, which scanning skips as already tracked, and renames non-EVE windows after a renamed filter; call after a reload, before recreating thumbnails.
    pub fn pruneNonMatchingWindows(self: *Scout) void {
        var i: usize = self.windows.items.len;
        while (i > 0) {
            i -= 1;
            const window = &self.windows.items[i];
            const filter = self.currentFilter(window.hwnd, window.process_id) orelse {
                _ = self.reportClosed(window.*);
                self.removeWindowAt(i);
                continue;
            };
            if (!window.is_eve_client and !std.mem.eql(u8, window.character_name, filter.name)) self.renameWindow(window, filter.name);
        }
    }
};

/// Set by setGlobalInstance for the WinEvent callbacks and other modules; also main.zig's only handle.
pub var g_scout_ptr: ?*Scout = null;

pub fn isGenericCharacterName(name: []const u8) bool {
    return std.mem.eql(u8, name, GENERIC_CHARACTER_NAME);
}

fn loginTime(is_eve_client: bool, character_name: []const u8) win32.Ticks {
    return if (is_eve_client and !isGenericCharacterName(character_name)) win32.Ticks.now() else .{};
}

fn freeClosedWindows(allocator: std.mem.Allocator, list: *std.ArrayList(ClosedWindow)) void {
    for (list.items) |cw| allocator.free(cw.character_name);
    list.deinit(allocator);
}

fn freeNameChanges(allocator: std.mem.Allocator, list: *std.ArrayList(NameChange)) void {
    for (list.items) |change| {
        allocator.free(change.old_name);
        allocator.free(change.new_name);
    }
    list.deinit(allocator);
}

fn enumWindowsCallback(hwnd: win32.HWND, lParam: win32.LPARAM) callconv(.c) win32.BOOL {
    const scout: *Scout = win32.lparamToPtr(Scout, lParam);

    if (!win32.isWindowVisible(hwnd)) {
        return win32.TRUE;
    }

    // Already tracked: skip the class-name lookup and filter-match loop below entirely.
    if (scout.indexOf(hwnd) != null) return win32.TRUE;

    // Class first, since it's much cheaper than opening the process for its executable path.
    var class_name: [64:0]u8 = undefined;
    const class_slice = win32.getClassNameBuf(hwnd, &class_name) orelse return win32.TRUE;
    if (scout.findMatchingFilter(class_slice, null) == null) return win32.TRUE;

    var process_id: win32.DWORD = 0;
    _ = win32.GetWindowThreadProcessId(hwnd, &process_id);

    var exe_path: [260:0]u8 = undefined;
    const path_slice = win32.queryProcessExePath(process_id, &exe_path) orelse return win32.TRUE;
    const matching_filter = scout.findMatchingFilter(class_slice, path_slice) orelse return win32.TRUE;

    var title_buf: [64]u8 = undefined;
    const title = win32.getWindowTitleBuf(hwnd, &title_buf) catch |err| switch (err) {
        error.MissingWindowTitle => return win32.TRUE,
        else => {
            slog.err("Failed to get window title for hwnd {*}: {}", .{ hwnd, err });
            return win32.TRUE;
        },
    };

    // Non-EVE titles aren't a stable per-window identity, so fall back to the filter's own name.
    const is_eve_client = std.mem.eql(u8, class_slice, EVE_WINDOW_CLASS);
    const character_name_slice = if (is_eve_client) Scout.extractCharacterName(title) else matching_filter.name;
    const character_name = scout.allocator.dupe(u8, character_name_slice) catch |err| {
        slog.err("Failed to allocate character name '{s}' for hwnd {*}: {}", .{ character_name_slice, hwnd, err });
        return win32.TRUE;
    };

    const eve_window = EveWindow{
        .hwnd = hwnd,
        .character_name = character_name,
        .process_id = process_id,
        .is_eve_client = is_eve_client,
        .logged_out_order = scout.logoutOrder(character_name),
        .logged_in_at = loginTime(is_eve_client, character_name),
    };

    scout.windows.append(scout.allocator, eve_window) catch |err| {
        slog.err("Failed to add EVE window '{s}' (hwnd {*}) to list: {}", .{ character_name, hwnd, err });
        scout.freeWindow(eve_window);
        return win32.TRUE;
    };
    scout.watchProcess(process_id);

    return win32.TRUE;
}

fn nameChangeCallback(_: win32.HANDLE, _: win32.DWORD, hwnd: win32.HWND, id_object: win32.LONG, _: win32.LONG, _: win32.DWORD, _: win32.DWORD) callconv(.c) void {
    // The main window only, not child controls.
    if (id_object != 0) return;

    const scout_ptr = g_scout_ptr orelse return;
    scout_ptr.updateWindowTitle(hwnd);
}

fn windowDestroyCallback(_: win32.HANDLE, _: win32.DWORD, hwnd: win32.HWND, id_object: win32.LONG, _: win32.LONG, _: win32.DWORD, _: win32.DWORD) callconv(.c) void {
    // The main window only, not child controls.
    if (id_object != 0) return;

    const scout_ptr = g_scout_ptr orelse return;

    // By hwnd alone, since a partially-destroyed window can fail GetClassNameA.
    const index = scout_ptr.indexOf(hwnd) orelse return;
    const eve_window = scout_ptr.windows.items[index];
    if (!scout_ptr.reportClosed(eve_window)) return;

    slog.debug("Window destroyed: '{s}' (hwnd {*})", .{ eve_window.character_name, hwnd });
    scout_ptr.removeWindowAt(index);
}
