const std = @import("std");
const win32 = @import("win32.zig");
const log = @import("log.zig");
const slog = log.scoped("scout");

pub const EveWindow = struct {
    hwnd: win32.HWND,
    title: []const u8,
    character_name: []const u8,
    process_id: win32.DWORD,
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
        for (self.closed_windows.items) |cw| {
            allocator.free(cw.character_name);
        }
        self.closed_windows.deinit(allocator);

        for (self.name_changes.items) |change| {
            allocator.free(change.old_name);
            allocator.free(change.new_name);
        }
        self.name_changes.deinit(allocator);
    }
};

pub const Scout = struct {
    allocator: std.mem.Allocator,
    config: *const @import("config.zig").Config,
    windows: std.ArrayList(EveWindow),
    name_to_hwnd: std.StringHashMap(win32.HWND),
    // O(1) window lookups by HWND
    hwnd_to_index: std.AutoHashMap(win32.HWND, usize),
    // Cache of known EVE process IDs to avoid re-checking executable path
    eve_pids: std.AutoHashMap(win32.DWORD, void),
    // Pending closed windows detected by destroy event hook
    pending_closed: std.ArrayList(ClosedWindow),
    // Pending name changes detected by title change event hook
    pending_name_changes: std.ArrayList(NameChange),
    // Flag set by create event hook to trigger immediate scan
    pending_scan: bool,
    create_event_hook: ?win32.HANDLE,
    name_change_hook: ?win32.HANDLE,
    destroy_event_hook: ?win32.HANDLE,

    pub fn init(allocator: std.mem.Allocator, config: *const @import("config.zig").Config) !Scout {
        var scout_instance = Scout{
            .allocator = allocator,
            .config = config,
            .windows = .empty,
            .name_to_hwnd = std.StringHashMap(win32.HWND).init(allocator),
            .hwnd_to_index = std.AutoHashMap(win32.HWND, usize).init(allocator),
            .eve_pids = std.AutoHashMap(win32.DWORD, void).init(allocator),
            .pending_closed = .empty,
            .pending_name_changes = .empty,
            .pending_scan = false,
            .create_event_hook = null,
            .name_change_hook = null,
            .destroy_event_hook = null,
        };

        scout_instance.name_change_hook = win32.SetWinEventHook(
            win32.EVENT_OBJECT_NAMECHANGE,
            win32.EVENT_OBJECT_NAMECHANGE,
            null,
            nameChangeCallback,
            // 0, 0 = all processes, all threads
            0,
            0,
            win32.WINEVENT_OUTOFCONTEXT,
        );

        if (scout_instance.name_change_hook) |_| {
            slog.debug("Title change event hook set up successfully", .{});
        } else {
            slog.warn("Failed to set up title change event hook - character name changes will not be detected until full window rescan", .{});
        }

        scout_instance.create_event_hook = win32.SetWinEventHook(
            win32.EVENT_OBJECT_CREATE,
            win32.EVENT_OBJECT_CREATE,
            null,
            windowCreateCallback,
            // 0, 0 = all processes, all threads
            0,
            0,
            win32.WINEVENT_OUTOFCONTEXT,
        );

        if (scout_instance.create_event_hook) |_| {
            slog.debug("Window creation event hook set up successfully", .{});
        } else {
            slog.warn("Failed to set up window creation event hook - new windows will only be detected via periodic scanning", .{});
        }

        scout_instance.destroy_event_hook = win32.SetWinEventHook(
            win32.EVENT_OBJECT_DESTROY,
            win32.EVENT_OBJECT_DESTROY,
            null,
            windowDestroyCallback,
            // 0, 0 = all processes, all threads
            0,
            0,
            win32.WINEVENT_OUTOFCONTEXT,
        );

        if (scout_instance.destroy_event_hook) |_| {
            slog.debug("Window destroy event hook set up successfully", .{});
        } else {
            slog.warn("Failed to set up window destroy event hook - closed windows will not be detected until periodic validation", .{});
        }

        return scout_instance;
    }

    /// Set the global Scout pointer for event callbacks
    pub fn setGlobalInstance(self: *Scout) void {
        g_scout_ptr = self;
    }

    pub fn deinit(self: *Scout) void {
        g_scout_ptr = null;

        if (self.create_event_hook) |hook| {
            _ = win32.UnhookWinEvent(hook);
        }
        if (self.name_change_hook) |hook| {
            _ = win32.UnhookWinEvent(hook);
        }
        if (self.destroy_event_hook) |hook| {
            _ = win32.UnhookWinEvent(hook);
        }

        for (self.pending_closed.items) |cw| {
            self.allocator.free(cw.character_name);
        }
        self.pending_closed.deinit(self.allocator);

        for (self.windows.items) |window| {
            self.allocator.free(window.title);
            self.allocator.free(window.character_name);
        }
        self.windows.deinit(self.allocator);
        self.name_to_hwnd.deinit();
        self.hwnd_to_index.deinit();
        self.eve_pids.deinit();
    }

    pub fn scanForEveWindows(self: *Scout) !void {
        // Enumerate all windows - callback will only add new ones not already tracked
        const result = win32.EnumWindows(enumWindowsCallback, win32.ptrToLparam(self));
        if (result == 0) {
            return error.EnumWindowsFailed;
        }
    }

    pub fn getWindows(self: *Scout) []const EveWindow {
        return self.windows.items;
    }

    /// Only called when windows are closed; drops PIDs for processes that no longer exist.
    pub fn cleanupStalePids(self: *Scout) void {
        var active_pids = std.AutoHashMap(win32.DWORD, void).init(self.allocator);
        defer active_pids.deinit();

        for (self.windows.items) |eve_window| {
            // Use cached PID instead of Win32 API call
            if (eve_window.process_id != 0) {
                active_pids.put(eve_window.process_id, {}) catch |err| {
                    slog.err("Failed to add PID {} to active set for '{s}': {}", .{ eve_window.process_id, eve_window.character_name, err });
                };
            }
        }

        var it = self.eve_pids.keyIterator();
        var pids_to_remove: std.ArrayList(win32.DWORD) = .empty;
        defer pids_to_remove.deinit(self.allocator);

        while (it.next()) |pid_ptr| {
            if (!active_pids.contains(pid_ptr.*)) {
                pids_to_remove.append(self.allocator, pid_ptr.*) catch |err| {
                    slog.err("Failed to append PID {} to removal list (stale PID cleanup incomplete): {}", .{ pid_ptr.*, err });
                };
            }
        }

        for (pids_to_remove.items) |pid| {
            _ = self.eve_pids.remove(pid);
        }

        if (pids_to_remove.items.len > 0) {
            slog.debug("Cleaned up {} stale PIDs from cache", .{pids_to_remove.items.len});
        }
    }

    /// Updates a window's title (called from the EVENT_OBJECT_NAMECHANGE hook); returns the
    /// old character name if it changed, for the caller to free.
    fn updateWindowTitle(self: *Scout, hwnd: win32.HWND) !?[]const u8 {
        const index = self.hwnd_to_index.get(hwnd) orelse return null;
        const eve_window = &self.windows.items[index];

        // Uses a stack buffer (not an allocation), since this runs every tick per tracked window just to detect the rare title-change case.
        var title_buf: [64]u8 = undefined;
        const current_title = win32.getWindowTitleBuf(eve_window.hwnd, &title_buf) catch |err| {
            slog.err("Failed to get window title for '{s}': {}", .{ eve_window.character_name, err });
            return null;
        };

        if (std.mem.eql(u8, eve_window.title, current_title)) {
            return null;
        }

        const new_char_name = extractCharacterName(current_title);

        const new_title_dup = self.allocator.dupe(u8, current_title) catch |err| {
            slog.err("Failed to allocate title for '{s}': {}", .{ new_char_name, err });
            return null;
        };
        self.allocator.free(eve_window.title);
        eve_window.title = new_title_dup;

        if (!std.mem.eql(u8, eve_window.character_name, new_char_name)) {
            // Save old name for caller to handle cleanup
            const old_name_copy = self.allocator.dupe(u8, eve_window.character_name) catch |err| {
                slog.err("Failed to duplicate old character name '{s}': {}", .{ eve_window.character_name, err });
                return null;
            };

            const old_name = eve_window.character_name;

            const new_char_dup = self.allocator.dupe(u8, new_char_name) catch |err| {
                slog.err("Failed to allocate character name '{s}': {}", .{ new_char_name, err });
                self.allocator.free(old_name_copy);
                return null;
            };

            _ = self.name_to_hwnd.remove(old_name);

            self.allocator.free(old_name);
            eve_window.character_name = new_char_dup;

            self.name_to_hwnd.put(new_char_dup, eve_window.hwnd) catch |err| {
                slog.err("Failed to map character name '{s}' to hwnd: {}", .{ new_char_name, err });
            };

            slog.info("Character changed: {s} -> {s}", .{ old_name_copy, new_char_name });

            // Store name change mapping for update() to return
            const new_name_copy = self.allocator.dupe(u8, new_char_name) catch |err| {
                slog.err("Failed to duplicate new character name '{s}': {}", .{ new_char_name, err });
                return old_name_copy;
            };

            self.pending_name_changes.append(self.allocator, .{
                .hwnd = eve_window.hwnd,
                .old_name = old_name_copy,
                .new_name = new_name_copy,
            }) catch |err| {
                slog.err("Failed to track name change {s} -> {s}: {}", .{ old_name_copy, new_char_name, err });
                self.allocator.free(old_name_copy);
                self.allocator.free(new_name_copy);
                return null;
            };

            // Now tracked in pending_name_changes instead
            return null;
        }

        return null;
    }

    /// Transfer ownership of pending closed windows list and reset for next cycle
    fn takeClosedWindows(self: *Scout) std.ArrayList(ClosedWindow) {
        const result = self.pending_closed;
        self.pending_closed = .empty;
        return result;
    }

    /// Transfer ownership of pending name changes list and reset for next cycle
    fn takeNameChanges(self: *Scout) std.ArrayList(NameChange) {
        const result = self.pending_name_changes;
        self.pending_name_changes = .empty;
        return result;
    }

    /// Re-reads titles for all tracked windows as a fallback for EVENT_OBJECT_NAMECHANGE events
    /// dropped before the HWND/PID was cached.
    /// Runs only on force_scan ticks (~1s), since GetWindowTextA on another process's window is a synchronous cross-process call.
    fn refreshTrackedWindowTitles(self: *Scout) void {
        // Snapshot the HWNDs first: updateWindowTitle may mutate windows[] via name changes but never adds/removes entries, so iterating by copy is safe.
        for (self.windows.items) |eve_window| {
            _ = self.updateWindowTitle(eve_window.hwnd) catch |err| {
                slog.warn("refreshTrackedWindowTitles: title update failed for '{s}': {}", .{ eve_window.character_name, err });
            };
        }
    }

    /// Main update cycle - performs all Scout operations for a single tick
    pub fn update(self: *Scout, force_scan: bool) !UpdateResult {
        // Transfer ownership to caller - they must call deinit() on result
        const closed = self.takeClosedWindows();
        const name_changes = self.takeNameChanges();

        if (closed.items.len > 0) {
            self.cleanupStalePids();
        }

        // Scan when a create event fired (pending_scan) or the caller forces a periodic scan.
        if (self.pending_scan or force_scan) {
            try self.scanForEveWindows();
            self.pending_scan = false;
        }

        // Catches missed name-change events; see refreshTrackedWindowTitles() doc comment.
        if (force_scan) self.refreshTrackedWindowTitles();

        return UpdateResult{
            .windows = self.getWindows(),
            .closed_windows = closed,
            .name_changes = name_changes,
        };
    }

    /// EVE window titles are typically: "EVE - CharacterName"
    fn extractCharacterName(title: []const u8) []const u8 {
        if (std.mem.indexOf(u8, title, " - ")) |dash_pos| {
            const name_start = dash_pos + 3;
            if (name_start < title.len) {
                return title[name_start..];
            }
        }
        return title;
    }

    /// Lookup HWND by character name (validates window before returning)
    pub fn getHwndByName(self: *const Scout, name: []const u8) ?win32.HWND {
        if (self.name_to_hwnd.get(name)) |hwnd| {
            if (win32.isWindow(hwnd)) return hwnd;
        }
        return null;
    }

    /// Clears the cached HWND for a character, forcing re-lookup on next getHwndByName; call when a HWND is known stale.
    pub fn clearHwndForCharacter(self: *Scout, name: []const u8) void {
        _ = self.name_to_hwnd.remove(name);
    }

    /// Call this after removing windows to keep indices consistent.
    fn rebuildHwndIndex(self: *Scout) void {
        self.hwnd_to_index.clearRetainingCapacity();
        for (self.windows.items, 0..) |*window, idx| {
            self.hwnd_to_index.put(window.hwnd, idx) catch |err| {
                slog.err("Failed to rebuild HWND index for {s}: {}", .{ window.character_name, err });
            };
        }
    }

    /// Re-checks a tracked window's class+exe against the current filter set from scratch,
    /// unlike enumWindowsCallback's class-first fast path which only applies to new windows.
    fn matchesCurrentFilters(self: *Scout, hwnd: win32.HWND, process_id: win32.DWORD) bool {
        var class_name: [64:0]u8 = undefined;
        const class_len = win32.GetClassNameA(hwnd, &class_name, class_name.len);
        if (class_len <= 0) return false;
        const class_slice = class_name[0..@intCast(class_len)];

        const process_handle = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, win32.FALSE, process_id);
        const handle = process_handle orelse return false;
        defer _ = win32.CloseHandle(handle);

        var exe_path: [260:0]u8 = undefined;
        const path_len = win32.GetModuleFileNameExA(handle, null, &exe_path, exe_path.len);
        if (path_len <= 0) return false;
        const path_slice = exe_path[0..@intCast(path_len)];

        for (self.config.windowFilters.items) |*filter| {
            if (filter.matchesClass(class_slice) and filter.matchesExecutable(path_slice)) return true;
        }
        return false;
    }

    /// Drops tracked windows that no longer match any filter (e.g. the filter that once matched
    /// them was edited or deleted); scanForEveWindows() alone won't catch this since it skips
    /// already-tracked HWNDs. Call after a config reload, before recreating thumbnails.
    pub fn pruneNonMatchingWindows(self: *Scout) void {
        var i: usize = self.windows.items.len;
        while (i > 0) {
            i -= 1;
            const window = self.windows.items[i];
            if (self.matchesCurrentFilters(window.hwnd, window.process_id)) continue;

            const removed = self.windows.orderedRemove(i);
            _ = self.name_to_hwnd.remove(removed.character_name);
            _ = self.eve_pids.remove(removed.process_id);
            self.allocator.free(removed.title);
            self.allocator.free(removed.character_name);
        }
        self.rebuildHwndIndex();
    }
};

/// EnumWindows callback: returning TRUE continues enumeration, FALSE stops it.
fn enumWindowsCallback(hwnd: win32.HWND, lParam: win32.LPARAM) callconv(.c) win32.BOOL {
    const scout: *Scout = win32.lparamToPtr(Scout, lParam);

    if (!win32.isWindowVisible(hwnd)) {
        return win32.TRUE;
    }

    // Fast filter: Check window class name first (much faster than OpenProcess)
    var class_name: [32:0]u8 = undefined;
    const class_len = win32.GetClassNameA(hwnd, &class_name, class_name.len);
    var class_slice: []const u8 = "";
    if (class_len > 0) {
        class_slice = class_name[0..@intCast(class_len)];
    } else {
        return win32.TRUE;
    }

    var matching_filter: ?*const @import("config.zig").WindowFilter = null;
    for (scout.config.windowFilters.items) |*filter| {
        if (filter.matchesClass(class_slice)) {
            matching_filter = filter;

            break;
        }
    }

    if (matching_filter == null) {
        return win32.TRUE;
    }

    if (scout.hwnd_to_index.contains(hwnd)) {
        return win32.TRUE;
    }

    var process_id: win32.DWORD = 0;
    _ = win32.GetWindowThreadProcessId(hwnd, &process_id);

    const is_cached = scout.eve_pids.contains(process_id);

    if (!is_cached) {
        var exe_path: [260:0]u8 = undefined;
        const path_slice = win32.queryProcessExePath(process_id, &exe_path) orelse return win32.TRUE;

        if (matching_filter) |filter| {
            if (!filter.matchesExecutable(path_slice)) {
                // A class-less filter can vacuously win the pick above; fall back to the rest.
                var found = false;
                for (scout.config.windowFilters.items) |*other| {
                    if (other == filter) continue;
                    if (other.matchesClass(class_slice) and other.matchesExecutable(path_slice)) {
                        matching_filter = other;
                        found = true;
                        break;
                    }
                }
                if (!found) return win32.TRUE;
            }
        }

        scout.eve_pids.put(process_id, {}) catch |err| {
            slog.err("Failed to cache PID: {}", .{err});
        };
    }

    const title_copy = win32.getWindowTitle(hwnd, scout.allocator) catch |err| {
        slog.err("Failed to get window title for hwnd {*}: {}", .{ hwnd, err });
        return win32.TRUE;
    };

    // Non-EVE titles aren't a stable per-window identity, so fall back to the filter's own name.
    const character_name_slice = if (std.mem.eql(u8, class_slice, "trinityWindow"))
        Scout.extractCharacterName(title_copy)
    else
        matching_filter.?.name;
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
    };

    scout.windows.append(scout.allocator, eve_window) catch |err| {
        slog.err("Failed to add EVE window '{s}' (hwnd {*}) to list: {}", .{ character_name, hwnd, err });
        scout.allocator.free(title_copy);
        scout.allocator.free(character_name);
        return win32.TRUE;
    };

    const new_index = scout.windows.items.len - 1;
    scout.hwnd_to_index.put(hwnd, new_index) catch |err| {
        slog.err("Failed to add HWND to index: {}", .{err});
        // Remove the window we just added since indexing failed
        const removed = scout.windows.pop().?;
        scout.allocator.free(removed.title);
        scout.allocator.free(removed.character_name);
        return win32.TRUE;
    };

    // Note: character_name pointer is now owned by windows[] and also used as HashMap key
    scout.name_to_hwnd.put(character_name, hwnd) catch |err| {
        slog.err("Failed to map character name to hwnd: {}", .{err});
        // Remove the window and index entry we just added since mapping failed
        _ = scout.hwnd_to_index.remove(hwnd);
        const removed = scout.windows.pop().?;
        scout.allocator.free(removed.title);
        scout.allocator.free(removed.character_name);
        return win32.TRUE;
    };

    return win32.TRUE;
}

// Global Scout pointer for event callback (similar to Painter's architecture)
var g_scout_ptr: ?*Scout = null;

fn nameChangeCallback(
    hWinEventHook: win32.HANDLE,
    event: win32.DWORD,
    hwnd: win32.HWND,
    idObject: win32.LONG,
    idChild: win32.LONG,
    idEventThread: win32.DWORD,
    dwmsEventTime: win32.DWORD,
) callconv(.c) void {
    _ = hWinEventHook;
    _ = event;
    _ = idChild;
    _ = idEventThread;
    _ = dwmsEventTime;

    // Only process main window title changes (not child controls)
    if (idObject != 0) return;

    const scout_ptr = g_scout_ptr orelse return;

    var process_id: win32.DWORD = 0;
    _ = win32.GetWindowThreadProcessId(hwnd, &process_id);
    if (!scout_ptr.eve_pids.contains(process_id)) {
        // Not a known EVE process, skip the expensive class name check below
        return;
    }

    // Kept as safety check in case PID cache is stale or process reuses PID
    var class_name: [32:0]u8 = undefined;
    const class_len = win32.GetClassNameA(hwnd, &class_name, class_name.len);
    if (class_len > 0) {
        const class_slice = class_name[0..@intCast(class_len)];
        if (!std.mem.eql(u8, class_slice, "trinityWindow")) {
            return;
        }
    } else {
        return;
    }

    const old_name = scout_ptr.updateWindowTitle(hwnd) catch return;
    if (old_name) |name| {
        scout_ptr.allocator.free(name);
    }
}

fn windowDestroyCallback(
    hWinEventHook: win32.HANDLE,
    event: win32.DWORD,
    hwnd: win32.HWND,
    idObject: win32.LONG,
    idChild: win32.LONG,
    idEventThread: win32.DWORD,
    dwmsEventTime: win32.DWORD,
) callconv(.c) void {
    _ = hWinEventHook;
    _ = event;
    _ = idChild;
    _ = idEventThread;
    _ = dwmsEventTime;

    // Only process main window destruction (not child controls)
    if (idObject != 0) return;

    const scout_ptr = g_scout_ptr orelse return;

    // Uses hwnd_to_index before checking class name, since a partially-destroyed window can fail GetClassNameA.
    const index = scout_ptr.hwnd_to_index.get(hwnd) orelse return;
    const eve_window = scout_ptr.windows.items[index];

    // Save character name for caller
    const closed_name = scout_ptr.allocator.dupe(u8, eve_window.character_name) catch |err| {
        slog.err("Failed to allocate closed character name '{s}': {}", .{ eve_window.character_name, err });
        return;
    };

    scout_ptr.pending_closed.append(scout_ptr.allocator, .{ .hwnd = hwnd, .character_name = closed_name }) catch |err| {
        slog.err("Failed to add '{s}' to pending closed list: {}", .{ closed_name, err });
        scout_ptr.allocator.free(closed_name);
        return;
    };

    slog.debug("Window destroyed: '{s}' (hwnd {*})", .{ eve_window.character_name, hwnd });
    const removed = scout_ptr.windows.orderedRemove(index);
    _ = scout_ptr.name_to_hwnd.remove(removed.character_name);
    _ = scout_ptr.hwnd_to_index.remove(removed.hwnd);
    scout_ptr.allocator.free(removed.title);
    scout_ptr.allocator.free(removed.character_name);

    // Rebuild hwnd_to_index since removal shifts array indices
    scout_ptr.rebuildHwndIndex();
}

fn windowCreateCallback(
    hWinEventHook: win32.HANDLE,
    event: win32.DWORD,
    hwnd: win32.HWND,
    idObject: win32.LONG,
    idChild: win32.LONG,
    idEventThread: win32.DWORD,
    dwmsEventTime: win32.DWORD,
) callconv(.c) void {
    _ = hWinEventHook;
    _ = event;
    _ = hwnd;
    _ = idChild;
    _ = idEventThread;
    _ = dwmsEventTime;

    // Only process main window creation (not child controls)
    if (idObject != 0) return;

    const scout_ptr = g_scout_ptr orelse return;

    // EVENT_OBJECT_CREATE fires for ALL windows, so this just flags a scan rather than validating expensively here.
    scout_ptr.pending_scan = true;
}
