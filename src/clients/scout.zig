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
    character_name: []const u8,
    process_id: win32.DWORD,
    is_eve_client: bool,
    /// When this window last went to the login screen, from Scout.next_logout_order; 0 while logged in.
    logged_out_order: u64 = 0,
};

pub const NameChange = struct {
    hwnd: win32.HWND,
    old_name: []const u8,
    new_name: []const u8,
};

/// character_name isn't unique (multiple windows can all report "EVE"), so hwnd travels with it.
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
    /// Set by the create hook so the next update() rescans.
    pending_scan: bool,
    create_event_hook: ?win32.HANDLE,
    name_change_hook: ?win32.HANDLE,
    destroy_event_hook: ?win32.HANDLE,

    pub fn init(allocator: std.mem.Allocator, config: *const config_mod.Config) Scout {
        return .{
            .allocator = allocator,
            .config = config,
            .windows = .empty,
            .pending_closed = .empty,
            .pending_name_changes = .empty,
            .pending_scan = false,
            .name_change_hook = installHook(win32.EVENT_OBJECT_NAMECHANGE, nameChangeCallback, "Title change", "character name changes will not be detected until full window rescan"),
            .create_event_hook = installHook(win32.EVENT_OBJECT_CREATE, windowCreateCallback, "Window creation", "new windows will only be detected via periodic scanning"),
            .destroy_event_hook = installHook(win32.EVENT_OBJECT_DESTROY, windowDestroyCallback, "Window destroy", "closed windows will be noticed within a second instead"),
        };
    }

    fn installHook(event: win32.DWORD, proc: win32.WINEVENTPROC, name: []const u8, fallback: []const u8) ?win32.HANDLE {
        const hook = win32.setWinEventHook(event, proc) orelse {
            slog.warn("Failed to set up {s} event hook - {s}", .{ name, fallback });
            return null;
        };
        slog.debug("{s} event hook set up successfully", .{name});
        return hook;
    }

    pub fn setGlobalInstance(self: *Scout) void {
        g_scout_ptr = self;
    }

    pub fn deinit(self: *Scout) void {
        g_scout_ptr = null;

        for ([_]?win32.HANDLE{ self.create_event_hook, self.name_change_hook, self.destroy_event_hook }) |maybe_hook| {
            if (maybe_hook) |hook| _ = win32.UnhookWinEvent(hook);
        }

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
            error.NoWindowTitle => return,
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

        slog.info("Character changed: {s} -> {s}", .{ old_name, new_name });

        self.pending_name_changes.append(self.allocator, .{
            .hwnd = eve_window.hwnd,
            .old_name = old_name,
            .new_name = change_name,
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

        if (self.pending_scan or force_scan) {
            if (self.scanForEveWindows()) |_| {
                self.pending_scan = false;
            } else |err| {
                slog.warn("Failed to scan for windows, retrying on the next scan: {}", .{err});
            }
        }

        if (force_scan) self.refreshTrackedWindowTitles();

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
        error.NoWindowTitle => return win32.TRUE,
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
    };

    scout.windows.append(scout.allocator, eve_window) catch |err| {
        slog.err("Failed to add EVE window '{s}' (hwnd {*}) to list: {}", .{ character_name, hwnd, err });
        scout.freeWindow(eve_window);
        return win32.TRUE;
    };

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

fn windowCreateCallback(_: win32.HANDLE, _: win32.DWORD, _: win32.HWND, id_object: win32.LONG, _: win32.LONG, _: win32.DWORD, _: win32.DWORD) callconv(.c) void {
    // The main window only, not child controls.
    if (id_object != 0) return;

    const scout_ptr = g_scout_ptr orelse return;

    // EVENT_OBJECT_CREATE fires for ALL windows, so this just flags a scan rather than validating expensively here.
    scout_ptr.pending_scan = true;
}
