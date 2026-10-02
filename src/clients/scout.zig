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
    title: []const u8,
    character_name: []const u8,
    process_id: win32.DWORD,
    is_eve_client: bool,
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
    hwnd_to_index: std.AutoHashMap(win32.HWND, usize),
    /// Filled by the WinEvent hooks between ticks and handed over by update().
    pending_closed: std.ArrayList(ClosedWindow),
    pending_name_changes: std.ArrayList(NameChange),
    /// FIFO queue of windows currently not logged in, oldest-logged-out first; fed by renameWindow/enumWindowsCallback, consumed by hotkeys/cycling.zig's cycleNotLoggedIn via getNotLoggedInHwnds.
    not_logged_in_queue: std.ArrayList(win32.HWND),
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
            .hwnd_to_index = std.AutoHashMap(win32.HWND, usize).init(allocator),
            .pending_closed = .empty,
            .pending_name_changes = .empty,
            .not_logged_in_queue = .empty,
            .pending_scan = false,
            .name_change_hook = installHook(win32.EVENT_OBJECT_NAMECHANGE, nameChangeCallback, "Title change", "character name changes will not be detected until full window rescan"),
            .create_event_hook = installHook(win32.EVENT_OBJECT_CREATE, windowCreateCallback, "Window creation", "new windows will only be detected via periodic scanning"),
            .destroy_event_hook = installHook(win32.EVENT_OBJECT_DESTROY, windowDestroyCallback, "Window destroy", "closed windows will only be dropped on a profile reload"),
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
        self.hwnd_to_index.deinit();
        self.not_logged_in_queue.deinit(self.allocator);
    }

    fn freeWindow(self: *Scout, window: EveWindow) void {
        self.allocator.free(window.title);
        self.allocator.free(window.character_name);
    }

    /// Stops tracking windows[index]; callers rebuild hwnd_to_index once they're done removing, since later indices shift.
    fn removeWindowAt(self: *Scout, index: usize) void {
        const removed = self.windows.orderedRemove(index);
        _ = self.hwnd_to_index.remove(removed.hwnd);
        self.untrackNotLoggedIn(removed.hwnd);
        self.freeWindow(removed);
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

    /// Bumps hwnd to the back of the not-logged-in FIFO used by the cycle-not-logged-in hotkey; re-logout bumps instead of duplicating.
    fn trackNotLoggedIn(self: *Scout, hwnd: win32.HWND) void {
        self.untrackNotLoggedIn(hwnd);
        self.not_logged_in_queue.append(self.allocator, hwnd) catch |err| {
            slog.err("Failed to queue not-logged-in window: {}", .{err});
        };
    }

    /// Removes hwnd from the not-logged-in FIFO, e.g. once its title changes away from "EVE", so a stale entry doesn't keep matching a since-logged-in character.
    fn untrackNotLoggedIn(self: *Scout, hwnd: win32.HWND) void {
        const index = std.mem.indexOfScalar(win32.HWND, self.not_logged_in_queue.items, hwnd) orelse return;
        _ = self.not_logged_in_queue.orderedRemove(index);
    }

    /// Caller-owned snapshot of the not-logged-in FIFO, oldest first. Caller frees with allocator.
    pub fn getNotLoggedInHwnds(self: *Scout, allocator: std.mem.Allocator) !std.ArrayList(win32.HWND) {
        var result: std.ArrayList(win32.HWND) = .empty;
        try result.appendSlice(allocator, self.not_logged_in_queue.items);
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
        const index = self.hwnd_to_index.get(hwnd) orelse return;
        const eve_window = &self.windows.items[index];

        // A stack buffer, since this runs for every tracked window on each refresh to catch a rare change.
        var title_buf: [64]u8 = undefined;
        const current_title = win32.getWindowTitleBuf(eve_window.hwnd, &title_buf) catch |err| switch (err) {
            error.NoWindowTitle => return,
            else => {
                slog.err("Failed to get window title for '{s}': {}", .{ eve_window.character_name, err });
                return;
            },
        };

        if (std.mem.eql(u8, eve_window.title, current_title)) return;

        const new_title = self.allocator.dupe(u8, current_title) catch |err| {
            slog.err("Failed to allocate title for '{s}': {}", .{ eve_window.character_name, err });
            return;
        };
        self.allocator.free(eve_window.title);
        eve_window.title = new_title;

        if (!eve_window.is_eve_client) return;
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

        if (isGenericCharacterName(window_name)) {
            self.trackNotLoggedIn(eve_window.hwnd);
        } else {
            self.untrackNotLoggedIn(eve_window.hwnd);
        }

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

    /// Catches title changes whose event came before the window was tracked; only on force_scan ticks, as each read is a cross-process call.
    fn refreshTrackedWindowTitles(self: *Scout) void {
        // Iterating by copy is safe: updateWindowTitle may rename entries but never adds or removes them.
        for (self.windows.items) |eve_window| {
            self.updateWindowTitle(eve_window.hwnd);
        }
    }

    /// Once per tick; caller deinits the result.
    pub fn update(self: *Scout, force_scan: bool) !UpdateResult {
        const closed = self.pending_closed;
        self.pending_closed = .empty;
        const name_changes = self.pending_name_changes;
        self.pending_name_changes = .empty;

        if (self.pending_scan or force_scan) {
            try self.scanForEveWindows();
            self.pending_scan = false;
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

    fn rebuildHwndIndex(self: *Scout) void {
        self.hwnd_to_index.clearRetainingCapacity();
        for (self.windows.items, 0..) |*window, idx| {
            self.hwnd_to_index.put(window.hwnd, idx) catch |err| {
                slog.err("Failed to rebuild HWND index for '{s}': {}", .{ window.character_name, err });
            };
        }
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

    /// Checks class and executable, as enumWindowsCallback does for a new window.
    fn matchesCurrentFilters(self: *const Scout, hwnd: win32.HWND, process_id: win32.DWORD) bool {
        var class_name: [64:0]u8 = undefined;
        const class_slice = win32.getClassNameBuf(hwnd, &class_name) orelse return false;

        var exe_path: [260:0]u8 = undefined;
        const path_slice = win32.queryProcessExePath(process_id, &exe_path) orelse return false;

        return self.findMatchingFilter(class_slice, path_slice) != null;
    }

    /// Drops windows no filter matches any more, which scanning skips as already tracked; call after a reload, before recreating thumbnails.
    pub fn pruneNonMatchingWindows(self: *Scout) void {
        var i: usize = self.windows.items.len;
        while (i > 0) {
            i -= 1;
            const window = self.windows.items[i];
            if (self.matchesCurrentFilters(window.hwnd, window.process_id)) continue;

            _ = self.reportClosed(window);
            self.removeWindowAt(i);
        }
        self.rebuildHwndIndex();
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
    if (scout.hwnd_to_index.contains(hwnd)) {
        return win32.TRUE;
    }

    // Class first, since it's much cheaper than opening the process for its executable path.
    var class_name: [64:0]u8 = undefined;
    const class_slice = win32.getClassNameBuf(hwnd, &class_name) orelse return win32.TRUE;
    if (scout.findMatchingFilter(class_slice, null) == null) return win32.TRUE;

    var process_id: win32.DWORD = 0;
    _ = win32.GetWindowThreadProcessId(hwnd, &process_id);

    var exe_path: [260:0]u8 = undefined;
    const path_slice = win32.queryProcessExePath(process_id, &exe_path) orelse return win32.TRUE;
    const matching_filter = scout.findMatchingFilter(class_slice, path_slice) orelse return win32.TRUE;

    const title_copy = win32.getWindowTitle(hwnd, scout.allocator) catch |err| switch (err) {
        error.NoWindowTitle => return win32.TRUE,
        else => {
            slog.err("Failed to get window title for hwnd {*}: {}", .{ hwnd, err });
            return win32.TRUE;
        },
    };

    // Non-EVE titles aren't a stable per-window identity, so fall back to the filter's own name.
    const is_eve_client = std.mem.eql(u8, class_slice, EVE_WINDOW_CLASS);
    const character_name_slice = if (is_eve_client) Scout.extractCharacterName(title_copy) else matching_filter.name;
    const character_name = scout.allocator.dupe(u8, character_name_slice) catch |err| {
        slog.err("Failed to allocate character name '{s}' for hwnd {*}: {}", .{ character_name_slice, hwnd, err });
        scout.allocator.free(title_copy);
        return win32.TRUE;
    };

    const eve_window = EveWindow{
        .hwnd = hwnd,
        .title = title_copy,
        .character_name = character_name,
        .process_id = process_id,
        .is_eve_client = is_eve_client,
    };

    scout.windows.append(scout.allocator, eve_window) catch |err| {
        slog.err("Failed to add EVE window '{s}' (hwnd {*}) to list: {}", .{ character_name, hwnd, err });
        scout.freeWindow(eve_window);
        return win32.TRUE;
    };

    scout.hwnd_to_index.put(hwnd, scout.windows.items.len - 1) catch |err| {
        slog.err("Failed to index '{s}': {}", .{ character_name, err });
        scout.freeWindow(scout.windows.pop().?);
        return win32.TRUE;
    };

    // Window was already not-logged-in when first discovered (e.g. app launch), so no name-change transition fires for it; queue it here instead.
    if (isGenericCharacterName(character_name)) {
        scout.trackNotLoggedIn(hwnd);
    }

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
    const index = scout_ptr.hwnd_to_index.get(hwnd) orelse return;
    const eve_window = scout_ptr.windows.items[index];
    if (!scout_ptr.reportClosed(eve_window)) return;

    slog.debug("Window destroyed: '{s}' (hwnd {*})", .{ eve_window.character_name, hwnd });
    scout_ptr.removeWindowAt(index);
    scout_ptr.rebuildHwndIndex();
}

fn windowCreateCallback(_: win32.HANDLE, _: win32.DWORD, _: win32.HWND, id_object: win32.LONG, _: win32.LONG, _: win32.DWORD, _: win32.DWORD) callconv(.c) void {
    // The main window only, not child controls.
    if (id_object != 0) return;

    const scout_ptr = g_scout_ptr orelse return;

    // EVENT_OBJECT_CREATE fires for ALL windows, so this just flags a scan rather than validating expensively here.
    scout_ptr.pending_scan = true;
}
