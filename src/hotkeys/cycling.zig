const std = @import("std");
const win32 = @import("../platform/win32.zig");
const activation = @import("../clients/activation.zig");
const scout = @import("../clients/scout.zig");
const config_mod = @import("../config.zig");
const strings = @import("../util/strings.zig");
const log = @import("../log.zig");
const slog = log.scoped("hotkeys");
const bindings = @import("bindings.zig");
const HotkeyManager = @import("manager.zig").HotkeyManager;

/// Cursors for the cycles whose position isn't kept in config (hotkey groups) or hotkey_map (per-character hotkeys).
pub const CycleState = struct {
    /// Each hotkey group's position, in config.hotkeyGroups order; null = not yet cycled.
    group_cursors: []?usize,
    /// Global across all groups; null = not yet cycled.
    excluded_index: ?usize = null,
    /// Owned; a name rather than an index since notified_queue mutates between presses.
    last_notified_name: ?[]const u8 = null,
    /// Owned; same rationale as last_notified_name, since Scout.windows mutates between presses.
    last_all_clients_name: ?[]const u8 = null,
    /// An HWND, not a name: every not-logged-in window shares the name "EVE".
    last_not_logged_in_hwnd: ?win32.HWND = null,
    character_order: CharacterOrderCache = .{},

    pub fn init(allocator: std.mem.Allocator, group_count: usize) !CycleState {
        const group_cursors = try allocator.alloc(?usize, group_count);
        @memset(group_cursors, null);
        return .{ .group_cursors = group_cursors };
    }

    pub fn deinit(self: *CycleState, allocator: std.mem.Allocator) void {
        allocator.free(self.group_cursors);
        if (self.last_notified_name) |name| allocator.free(name);
        if (self.last_all_clients_name) |name| allocator.free(name);
        self.character_order.deinit();
    }
};

/// Character name -> configured-order index, rebuilt only when the Characters list's names/order change, which is far less often than cycle hotkeys are pressed.
const CharacterOrderCache = struct {
    map: ?std.StringHashMap(usize) = null,
    signature: u64 = 0,

    fn deinit(self: *CharacterOrderCache) void {
        if (self.map) |*map| map.deinit();
    }

    fn get(self: *CharacterOrderCache, allocator: std.mem.Allocator, characters: []const config_mod.CharacterConfig) !*const std.StringHashMap(usize) {
        const sig = characterOrderSignature(characters);
        if (self.map == null or self.signature != sig) {
            if (self.map) |*old| old.deinit();
            self.map = try config_mod.buildCharacterOrderMap(characters, allocator);
            self.signature = sig;
        }
        return &self.map.?;
    }

    /// Caller owns the returned slice; windows for unconfigured characters sort after configured ones, keeping discovery order among themselves.
    fn orderedIndices(self: *CharacterOrderCache, allocator: std.mem.Allocator, characters: []const config_mod.CharacterConfig, windows: []const scout.EveWindow) ![]usize {
        const order_map = try self.get(allocator, characters);

        const indices = try allocator.alloc(usize, windows.len);
        for (indices, 0..) |*slot, i| slot.* = i;

        const Ctx = struct {
            windows: []const scout.EveWindow,
            order_map: *const std.StringHashMap(usize),

            fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return config_mod.orderMapLessThan(ctx.order_map, ctx.windows[a_index].character_name, ctx.windows[b_index].character_name, a_index, b_index);
            }
        };

        std.sort.pdq(usize, indices, Ctx{ .windows = windows, .order_map = order_map }, Ctx.lessThan);
        return indices;
    }
};

fn characterOrderSignature(characters: []const config_mod.CharacterConfig) u64 {
    var h = std.hash.Wyhash.init(0);
    for (characters) |char| {
        h.update(char.name);
        // The map's keys borrow these names, so a reallocated but equal name (a discarded dialog preview) must rebuild it too.
        h.update(std.mem.asBytes(&char.name.ptr));
    }
    return h.final();
}

/// Visits every index in [0, num) once, starting one step past `cursor`; a missing or stale cursor starts at the first index in `forward` direction.
pub const CycleOrder = struct {
    idx: usize,
    num: usize,
    forward: bool,
    remaining: usize,

    pub fn init(cursor: ?usize, num: usize, forward: bool) CycleOrder {
        const valid_cursor = if (cursor) |c| (if (c < num) c else null) else null;
        // Wraps harmlessly when num == 0: remaining is 0, so next() never steps.
        const before_start = valid_cursor orelse (if (forward) num -% 1 else 0);
        return .{ .idx = before_start, .num = num, .forward = forward, .remaining = num };
    }

    pub fn next(self: *CycleOrder) ?usize {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        if (self.forward) {
            self.idx = (self.idx + 1) % self.num;
        } else {
            self.idx = if (self.idx == 0) self.num - 1 else self.idx - 1;
        }
        return self.idx;
    }
};

pub fn directionName(forward: bool) []const u8 {
    return if (forward) "forward" else "backward";
}

/// Takes an optional target since callers pass GetForegroundWindow() directly.
fn indexOfHwnd(hwnds: []const win32.HWND, target: ?win32.HWND) ?usize {
    return std.mem.indexOfScalar(win32.HWND, hwnds, target orelse return null);
}

/// Whether hwnd still shows the generic "EVE" login-screen title, used to skip stale not-logged-in queue entries.
fn isHwndStillNotLoggedIn(windows: []const scout.EveWindow, hwnd: win32.HWND) bool {
    for (windows) |w| {
        if (w.hwnd == hwnd and scout.isGenericCharacterName(w.character_name)) return true;
    }
    return false;
}

/// Replaces `field.*` with an owned copy of name, freeing the previous value.
fn setOwnedCursorName(allocator: std.mem.Allocator, field: *?[]const u8, name: []const u8, context: []const u8) void {
    const duped = allocator.dupe(u8, name) catch |err| {
        slog.err("Failed to remember {s} cycle cursor for {s}: {}", .{ context, name, err });
        return;
    };
    if (field.*) |old| allocator.free(old);
    field.* = duped;
}

/// Cycles to the next running character sharing this hotkey.
pub fn activatePerCharacterGroup(m: *HotkeyManager, group: *bindings.CharacterGroup) void {
    const num = group.character_indices.len;
    var it = CycleOrder.init(group.current_index, num, true);
    while (it.next()) |idx| {
        const char_index = group.character_indices[idx];
        if (char_index >= m.config.characters.items.len) continue;
        const char_name = m.config.characters.items[char_index].name;

        if (m.scout.getHwndByName(char_name)) |hwnd| {
            group.current_index = idx;
            slog.info("Activating character: {s} ({}/{})", .{ char_name, idx + 1, num });
            activation.activate(hwnd);
            return;
        }
    }

    slog.warn("No character sharing this hotkey is currently running", .{});
}

/// Like cycleNotLoggedIn but scoped to one group, with not-logged-in clients appended after the group's characters when includeNotLoggedIn is set.
pub fn cycleGroup(m: *HotkeyManager, group_index: usize, forward: bool) void {
    const group = &m.config.hotkeyGroups.items[group_index];
    const cursor = &m.cycle.group_cursors[group_index];
    const num_chars = group.characters.items.len;

    var nli_hwnds: std.ArrayList(win32.HWND) = .empty;
    defer nli_hwnds.deinit(m.allocator);
    if (group.includeNotLoggedIn) {
        nli_hwnds = m.scout.getNotLoggedInHwnds(m.allocator) catch |err| blk: {
            slog.err("Failed to build not-logged-in window list for group cycle: {}", .{err});
            break :blk .empty;
        };
    }
    const num_nli = nli_hwnds.items.len;
    const total = num_chars + num_nli;
    if (total == 0) {
        slog.warn("Attempted to cycle empty hotkey group", .{});
        return;
    }

    // Prefers the real foreground window for the not-logged-in tail, since logging out while already focused fires no OS focus event to update the cursor.
    var found_index: ?usize = null;
    if (num_nli > 0) {
        if (indexOfHwnd(nli_hwnds.items, win32.GetForegroundWindow())) |i| found_index = num_chars + i;
    }
    if (found_index == null) {
        if (cursor.*) |ci| {
            if (ci < num_chars) found_index = ci;
        }
    }
    if (found_index == null and num_nli > 0) {
        if (m.cycle.last_not_logged_in_hwnd) |last_hwnd| {
            if (indexOfHwnd(nli_hwnds.items, last_hwnd)) |i| found_index = num_chars + i;
        }
    }

    const windows = m.scout.getWindows();
    var it = CycleOrder.init(found_index, total, forward);
    while (it.next()) |idx| {
        if (idx < num_chars) {
            const char_name = group.characters.items[idx];

            if (m.exclusions.isExcludedInGroup(group_index, char_name)) {
                slog.debug("Skipping excluded character: {s}", .{char_name});
                continue;
            }

            if (m.scout.getHwndByName(char_name)) |hwnd| {
                cursor.* = idx;
                slog.info("Cycling {s} to: {s} ({}/{})", .{ directionName(forward), char_name, idx + 1, total });
                activation.activate(hwnd);
                return;
            }
            continue;
        }

        const hwnd = nli_hwnds.items[idx - num_chars];
        if (!isHwndStillNotLoggedIn(windows, hwnd)) {
            slog.debug("Queued not-logged-in window {*} is no longer at the login screen, skipping", .{hwnd});
            continue;
        }

        cursor.* = idx;
        slog.info("Cycling {s} to not-logged-in client ({}/{})", .{ directionName(forward), idx + 1, total });
        activation.activate(hwnd);
        m.cycle.last_not_logged_in_hwnd = hwnd;
        return;
    }

    slog.warn("No characters from hotkey group are currently running (or all are excluded)", .{});
}

/// Cycle through excluded characters in the order they were added to exclusion lists
pub fn cycleExcluded(m: *HotkeyManager, forward: bool) void {
    slog.info("{s} excluded character hotkey pressed", .{if (forward) "Next" else "Previous"});
    const excluded_list = m.exclusions.list(m.allocator);

    const num_excluded = excluded_list.items.len;
    if (num_excluded == 0) {
        slog.info("No excluded characters to cycle through", .{});
        return;
    }

    var it = CycleOrder.init(m.cycle.excluded_index, num_excluded, forward);
    while (it.next()) |idx| {
        const char_name = excluded_list.items[idx];

        if (m.scout.getHwndByName(char_name)) |hwnd| {
            m.cycle.excluded_index = idx;
            slog.info("Cycling {s} to excluded character: {s} ({}/{})", .{ directionName(forward), char_name, idx + 1, num_excluded });
            activation.activate(hwnd);
            return;
        }
        slog.debug("Excluded character {s} is not currently running, skipping", .{char_name});
    }

    slog.warn("No excluded characters are currently running", .{});
}

/// Cycles to the most-recently-notified character (FIFO).
pub fn cycleNotified(m: *HotkeyManager, forward: bool) void {
    slog.info("Cycle notified character hotkey pressed ({s})", .{directionName(forward)});
    const retention_ms: u64 = @as(u64, m.config.thumbnail.notifications.notified_cycle_retention_seconds) * 1000;

    var names = m.painter.notified_queue.namesWithin(m.allocator, retention_ms) catch |err| {
        slog.err("Failed to build notified-character list: {}", .{err});
        return;
    };
    defer names.deinit(m.allocator);

    const num_notified = names.items.len;
    if (num_notified == 0) {
        slog.info("No recently-notified characters to cycle through", .{});
        return;
    }

    const found_index = if (m.cycle.last_notified_name) |last_name| strings.indexOfString(names.items, last_name) else null;
    var it = CycleOrder.init(found_index, num_notified, forward);
    while (it.next()) |index| {
        const char_name = names.items[index];

        if (m.scout.getHwndByName(char_name)) |hwnd| {
            slog.info("Cycling {s} to notified character: {s} ({}/{})", .{ directionName(forward), char_name, index + 1, num_notified });
            activation.activate(hwnd);
            setOwnedCursorName(m.allocator, &m.cycle.last_notified_name, char_name, "notified");
            return;
        }
        slog.debug("Notified character {s} is not currently running, skipping", .{char_name});
    }

    slog.warn("No recently-notified characters are currently running", .{});
}

/// Cycles every logged-in client in Characters-list order (unconfigured ones follow, in Scout's discovery order); unlike other cycles, every entry is guaranteed running.
pub fn cycleAllClients(m: *HotkeyManager, forward: bool) void {
    slog.info("Cycle all clients hotkey pressed ({s})", .{directionName(forward)});
    const windows = m.scout.getWindows();
    const num = windows.len;
    if (num == 0) {
        slog.info("No logged-in clients to cycle through", .{});
        return;
    }

    const order = m.cycle.character_order.orderedIndices(m.allocator, m.config.characters.items, windows) catch |err| {
        slog.err("Failed to build character-ordered client list: {}", .{err});
        return;
    };
    defer m.allocator.free(order);

    var found_index: ?usize = null;
    if (m.cycle.last_all_clients_name) |last_name| {
        for (order, 0..) |window_index, i| {
            if (std.mem.eql(u8, windows[window_index].character_name, last_name)) {
                found_index = i;
                break;
            }
        }
    }

    const respect_exclusions = m.global_settings.cycleAllClientsRespectExclusions;
    var it = CycleOrder.init(found_index, num, forward);
    while (it.next()) |index| {
        const w = windows[order[index]];
        if (scout.isGenericCharacterName(w.character_name)) continue;
        if (respect_exclusions and m.isCharacterExcluded(w.character_name)) continue;

        slog.info("Cycling {s} to client: {s} ({}/{})", .{ directionName(forward), w.character_name, index + 1, num });
        activation.activate(w.hwnd);
        setOwnedCursorName(m.allocator, &m.cycle.last_all_clients_name, w.character_name, "all-clients");
        return;
    }

    slog.warn("No logged-in clients are eligible to cycle to (all excluded)", .{});
}

/// Cycles windows still at the login screen ("EVE" title), in the order they logged out.
pub fn cycleNotLoggedIn(m: *HotkeyManager, forward: bool) void {
    slog.info("Cycle not-logged-in hotkey pressed ({s})", .{directionName(forward)});
    var hwnds = m.scout.getNotLoggedInHwnds(m.allocator) catch |err| {
        slog.err("Failed to build not-logged-in window list: {}", .{err});
        return;
    };
    defer hwnds.deinit(m.allocator);

    const num = hwnds.items.len;
    if (num == 0) {
        slog.info("No not-logged-in clients to cycle through", .{});
        return;
    }

    // Prefers the real foreground window over the remembered cursor, since logging out while already focused fires no OS focus event to update it.
    var found_index = indexOfHwnd(hwnds.items, win32.GetForegroundWindow());
    if (found_index == null) {
        if (m.cycle.last_not_logged_in_hwnd) |last_hwnd| {
            found_index = indexOfHwnd(hwnds.items, last_hwnd);
        }
    }

    const windows = m.scout.getWindows();
    var it = CycleOrder.init(found_index, num, forward);
    while (it.next()) |index| {
        const hwnd = hwnds.items[index];

        if (isHwndStillNotLoggedIn(windows, hwnd)) {
            slog.info("Cycling {s} to not-logged-in client ({}/{})", .{ directionName(forward), index + 1, num });
            activation.activate(hwnd);
            m.cycle.last_not_logged_in_hwnd = hwnd;
            return;
        }
        slog.debug("Queued not-logged-in window {*} is no longer at the login screen, skipping", .{hwnd});
    }

    slog.warn("No queued not-logged-in clients are still at the login screen", .{});
}

/// Moves every cycle cursor onto a manually focused character, so the next cycle press continues from it.
pub fn syncToFocusedCharacter(m: *HotkeyManager, character_name: []const u8, hwnd: win32.HWND) void {
    // Verify the window actually has focus first, to avoid stale updates during rapid cycling.
    if (hwnd != win32.GetForegroundWindow()) {
        slog.debug("Ignoring updateFocusedCharacter for {s} - not the foreground window", .{character_name});
        return;
    }

    // Every not-logged-in window shares the name "EVE", so hwnd (not name) is the cursor; skip the by-name syncing below, which doesn't apply.
    if (scout.isGenericCharacterName(character_name)) {
        m.cycle.last_not_logged_in_hwnd = hwnd;
        return;
    }

    syncExcludedCycleIndex(m, character_name);

    const already_synced = if (m.cycle.last_all_clients_name) |last| std.mem.eql(u8, last, character_name) else false;
    if (!already_synced) setOwnedCursorName(m.allocator, &m.cycle.last_all_clients_name, character_name, "all-clients");

    var pc_it = m.hotkey_map.valueIterator();
    while (pc_it.next()) |action| {
        const group = switch (action.*) {
            .ActivateCharacter => |*character_group| character_group,
            else => continue,
        };
        for (group.character_indices, 0..) |char_index, idx| {
            if (char_index < m.config.characters.items.len and std.mem.eql(u8, m.config.characters.items[char_index].name, character_name)) {
                group.current_index = idx;
                break;
            }
        }
    }

    syncGroupCycleIndex(m.config.hotkeyGroups.items, m.cycle.group_cursors, character_name, m.config.hotkeys.resetGroupIndexOnNonGroupFocus);
}

/// `cursors` parallels `groups`; reset_on_leave clears the cursor of groups character_name isn't in.
fn syncGroupCycleIndex(groups: []const config_mod.HotkeyGroupConfig, cursors: []?usize, character_name: []const u8, reset_on_leave: bool) void {
    for (groups, cursors) |*group, *cursor| {
        if (strings.indexOfString(group.characters.items, character_name)) |index| {
            if (cursor.* == null or cursor.*.? != index) {
                slog.debug("Updated hotkey group index: {s} now at position {}/{}", .{ character_name, index + 1, group.characters.items.len });
                cursor.* = index;
            }
        } else if (reset_on_leave and cursor.* != null) {
            slog.debug("Reset hotkey group cycle index - {s} left this group", .{character_name});
            cursor.* = null;
        }
    }
}

fn syncExcludedCycleIndex(m: *HotkeyManager, character_name: []const u8) void {
    const excluded_list = m.exclusions.list(m.allocator);
    const index = strings.indexOfString(excluded_list.items, character_name) orelse return;
    if (m.cycle.excluded_index == null or m.cycle.excluded_index.? != index) {
        slog.debug("Updated excluded cycle index: {s} now at position {}/{}", .{ character_name, index + 1, excluded_list.items.len });
        m.cycle.excluded_index = index;
    }
}
