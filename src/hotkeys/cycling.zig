//! The cycle hotkeys: through a group, a shared per-character key, and the excluded, notified, all and not-logged-in clients.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const activation = @import("../clients/activation.zig");
const scout = @import("../clients/scout.zig");
const config = @import("../config.zig");
const strings = @import("../util/strings.zig");
const bindings = @import("bindings.zig");
const HotkeyManager = @import("manager.zig").HotkeyManager;
const log = @import("../log.zig");

const slog = log.scoped("hotkeys");

/// Cursors for the cycles whose position isn't kept in config (hotkey groups) or hotkey_map (per-character hotkeys).
pub const CycleState = struct {
    /// Each hotkey group's position, in config.hotkeyGroups order; null = not yet cycled.
    group_cursors: []?usize,
    /// Where the last group cycle landed, for a character in several groups sharing a key.
    last_cycled_group: ?usize = null,
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

    fn get(self: *CharacterOrderCache, allocator: std.mem.Allocator, characters: []const config.CharacterConfig) !*const std.StringHashMap(usize) {
        const sig = characterOrderSignature(characters);
        if (self.map == null or self.signature != sig) {
            if (self.map) |*old| old.deinit();
            self.map = try config.buildCharacterOrderMap(characters, allocator);
            self.signature = sig;
        }
        return &self.map.?;
    }

    /// Caller owns the returned slice; windows for unconfigured characters sort after configured ones, keeping discovery order among themselves.
    fn orderedIndices(self: *CharacterOrderCache, allocator: std.mem.Allocator, characters: []const config.CharacterConfig, windows: []const scout.EveWindow) ![]usize {
        const order_map = try self.get(allocator, characters);

        const indices = try allocator.alloc(usize, windows.len);
        for (indices, 0..) |*slot, i| slot.* = i;

        const Ctx = struct {
            windows: []const scout.EveWindow,
            order_map: *const std.StringHashMap(usize),

            fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return config.orderMapLessThan(ctx.order_map, ctx.windows[a_index].character_name, ctx.windows[b_index].character_name, a_index, b_index);
            }
        };

        std.sort.pdq(usize, indices, Ctx{ .windows = windows, .order_map = order_map }, Ctx.lessThan);
        return indices;
    }
};

/// Visits every index in [0, num) once, starting one step past `cursor`; a missing or stale cursor starts at the first index in `forward` direction.
/// Without `wrap`, stops at the last index in `forward` direction instead of going round.
pub const CycleOrder = struct {
    idx: usize,
    num: usize,
    forward: bool,
    remaining: usize,

    pub fn init(cursor: ?usize, num: usize, forward: bool, wrap: bool) CycleOrder {
        const valid_cursor = if (cursor) |c| (if (c < num) c else null) else null;
        // Wraps harmlessly when num == 0: remaining is 0, so next() never steps.
        const before_start = valid_cursor orelse (if (forward) num -% 1 else 0);
        const remaining = if (wrap) num else if (valid_cursor) |c| (if (forward) num - 1 - c else c) else num;
        return .{ .idx = before_start, .num = num, .forward = forward, .remaining = remaining };
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

/// Cycles to the next running character sharing this hotkey.
pub fn activatePerCharacterGroup(manager: *HotkeyManager, group: *bindings.CharacterGroup) void {
    const num = group.character_indices.len;
    var it = CycleOrder.init(group.current_index, num, true, true);
    while (it.next()) |idx| {
        const char_index = group.character_indices[idx];
        if (char_index >= manager.config.characters.items.len) continue;
        const char_name = manager.config.characters.items[char_index].name;

        if (manager.scout.getHwndByName(char_name)) |hwnd| {
            group.current_index = idx;
            slog.info("Activating character: {s} ({}/{})", .{ char_name, idx + 1, num });
            activation.activate(hwnd);
            return;
        }
    }

    slog.warn("No character sharing this hotkey is currently running", .{});
}

/// Cycles the groups' members as one list; logged-out clients join if any group includes them, ends stop only if all do.
pub fn cycleGroups(manager: *HotkeyManager, group_indices: []const usize, forward: bool) void {
    const groups = manager.config.hotkeyGroups.items;
    var member_count: usize = 0;
    var include_not_logged_in = false;
    var stop_at_ends = true;
    for (group_indices) |group_index| {
        if (group_index >= groups.len) {
            slog.err("Failed to cycle group: index {} is out of range", .{group_index});
            return;
        }
        const group = &groups[group_index];
        member_count += group.characters.items.len;
        include_not_logged_in = include_not_logged_in or group.includeNotLoggedIn;
        stop_at_ends = stop_at_ends and group.stopAtEnds;
    }

    var not_logged_in_hwnds: std.ArrayList(win32.HWND) = .empty;
    defer not_logged_in_hwnds.deinit(manager.allocator);
    if (include_not_logged_in) {
        not_logged_in_hwnds = manager.scout.getNotLoggedInHwnds(manager.allocator) catch |err| blk: {
            slog.err("Failed to build not-logged-in window list for group cycle: {}", .{err});
            break :blk .empty;
        };
    }
    const not_logged_in_count = not_logged_in_hwnds.items.len;
    const total = member_count + not_logged_in_count;
    if (total == 0) {
        slog.warn("Attempted to cycle empty hotkey group", .{});
        return;
    }

    // Prefers the real foreground window for the not-logged-in tail, since logging out while already focused fires no OS focus event to update the cursor.
    var found_index: ?usize = null;
    if (not_logged_in_count > 0) {
        if (indexOfHwnd(not_logged_in_hwnds.items, win32.GetForegroundWindow())) |i| found_index = member_count + i;
    }
    if (found_index == null) found_index = chainCursor(manager, group_indices);
    if (found_index == null and not_logged_in_count > 0) {
        if (manager.cycle.last_not_logged_in_hwnd) |last_hwnd| {
            if (indexOfHwnd(not_logged_in_hwnds.items, last_hwnd)) |i| found_index = member_count + i;
        }
    }

    var it = CycleOrder.init(found_index, total, forward, !stop_at_ends);
    while (it.next()) |idx| {
        if (idx < member_count) {
            const member = chainMember(groups, group_indices, idx);
            const char_name = groups[member.group_index].characters.items[member.index];

            if (manager.exclusions.contains(char_name)) {
                slog.debug("Skipping excluded character: {s}", .{char_name});
                continue;
            }

            if (manager.scout.getHwndByName(char_name)) |hwnd| {
                manager.cycle.group_cursors[member.group_index] = member.index;
                manager.cycle.last_cycled_group = member.group_index;
                slog.info("Cycling {s} to: {s} ({}/{})", .{ directionName(forward), char_name, idx + 1, total });
                activation.activate(hwnd);
                return;
            }
            continue;
        }

        const hwnd = not_logged_in_hwnds.items[idx - member_count];
        // The not-logged-in tail is tracked by hwnd, so no group position applies.
        for (group_indices) |group_index| manager.cycle.group_cursors[group_index] = null;
        slog.info("Cycling {s} to not-logged-in client ({}/{})", .{ directionName(forward), idx + 1, total });
        activation.activate(hwnd);
        manager.cycle.last_not_logged_in_hwnd = hwnd;
        return;
    }

    if (stop_at_ends) {
        if (found_index) |current| {
            if (chainEntryHwnd(manager, group_indices, member_count, not_logged_in_hwnds.items, current)) |hwnd| {
                if (hwnd == win32.GetForegroundWindow()) {
                    slog.debug("Already at the {s} end of hotkey group", .{directionName(forward)});
                    return;
                }
                slog.info("Refocusing {s} end of hotkey group ({}/{})", .{ directionName(forward), current + 1, total });
                activation.activate(hwnd);
                return;
            }
        }
    }

    slog.warn("No characters from hotkey group are currently running (or all are excluded)", .{});
}

/// In the order the characters were excluded.
pub fn cycleExcluded(manager: *HotkeyManager, forward: bool) void {
    slog.info("{s} excluded character hotkey pressed", .{if (forward) "Next" else "Previous"});
    const excluded_names = manager.exclusions.names.items;

    const num_excluded = excluded_names.len;
    if (num_excluded == 0) {
        slog.info("No excluded characters to cycle through", .{});
        return;
    }

    var it = CycleOrder.init(manager.cycle.excluded_index, num_excluded, forward, true);
    while (it.next()) |idx| {
        const char_name = excluded_names[idx];

        if (manager.scout.getHwndByName(char_name)) |hwnd| {
            manager.cycle.excluded_index = idx;
            slog.info("Cycling {s} to excluded character: {s} ({}/{})", .{ directionName(forward), char_name, idx + 1, num_excluded });
            activation.activate(hwnd);
            return;
        }
        slog.debug("Excluded character {s} is not currently running, skipping", .{char_name});
    }

    slog.warn("No excluded characters are currently running", .{});
}

/// Cycles to the most-recently-notified character (FIFO).
pub fn cycleNotified(manager: *HotkeyManager, forward: bool) void {
    slog.info("Cycle notified character hotkey pressed ({s})", .{directionName(forward)});
    const retention_ms: u64 = @as(u64, manager.live().thumbnail.notifications.notified_cycle_retention_seconds) * 1000;

    var names = manager.painter.notified_queue.namesWithin(manager.allocator, retention_ms) catch |err| {
        slog.err("Failed to build notified-character list: {}", .{err});
        return;
    };
    defer names.deinit(manager.allocator);

    const num_notified = names.items.len;
    if (num_notified == 0) {
        slog.info("No recently-notified characters to cycle through", .{});
        return;
    }

    const found_index = if (manager.cycle.last_notified_name) |last_name| strings.indexOfString(names.items, last_name) else null;
    var it = CycleOrder.init(found_index, num_notified, forward, true);
    while (it.next()) |index| {
        const char_name = names.items[index];

        if (manager.scout.getHwndByName(char_name)) |hwnd| {
            slog.info("Cycling {s} to notified character: {s} ({}/{})", .{ directionName(forward), char_name, index + 1, num_notified });
            activation.activate(hwnd);
            setOwnedCursorName(manager.allocator, &manager.cycle.last_notified_name, char_name, "notified");
            return;
        }
        slog.debug("Notified character {s} is not currently running, skipping", .{char_name});
    }

    slog.warn("No recently-notified characters are currently running", .{});
}

/// Cycles every logged-in client in Characters-list order (unconfigured ones follow, in Scout's discovery order); unlike other cycles, every entry is guaranteed running.
pub fn cycleAllClients(manager: *HotkeyManager, forward: bool) void {
    slog.info("Cycle all clients hotkey pressed ({s})", .{directionName(forward)});
    const windows = manager.scout.getWindows();
    const num = windows.len;
    if (num == 0) {
        slog.info("No logged-in clients to cycle through", .{});
        return;
    }

    const order = manager.cycle.character_order.orderedIndices(manager.allocator, manager.live().characters.items, windows) catch |err| {
        slog.err("Failed to build character-ordered client list: {}", .{err});
        return;
    };
    defer manager.allocator.free(order);

    var found_index: ?usize = null;
    if (manager.cycle.last_all_clients_name) |last_name| {
        for (order, 0..) |window_index, i| {
            if (std.mem.eql(u8, windows[window_index].character_name, last_name)) {
                found_index = i;
                break;
            }
        }
    }

    const respect_exclusions = manager.liveGlobal().cycleAllClientsRespectExclusions;
    var it = CycleOrder.init(found_index, num, forward, true);
    while (it.next()) |index| {
        const w = windows[order[index]];
        if (scout.isGenericCharacterName(w.character_name)) continue;
        if (respect_exclusions and manager.exclusions.contains(w.character_name)) continue;

        slog.info("Cycling {s} to client: {s} ({}/{})", .{ directionName(forward), w.character_name, index + 1, num });
        activation.activate(w.hwnd);
        setOwnedCursorName(manager.allocator, &manager.cycle.last_all_clients_name, w.character_name, "all-clients");
        return;
    }

    slog.warn("No logged-in clients are eligible to cycle to (all excluded)", .{});
}

/// Cycles windows still at the login screen ("EVE" title), in the order they logged out.
pub fn cycleNotLoggedIn(manager: *HotkeyManager, forward: bool) void {
    slog.info("Cycle not-logged-in hotkey pressed ({s})", .{directionName(forward)});
    var hwnds = manager.scout.getNotLoggedInHwnds(manager.allocator) catch |err| {
        slog.err("Failed to build not-logged-in window list: {}", .{err});
        return;
    };
    defer hwnds.deinit(manager.allocator);

    const num = hwnds.items.len;
    if (num == 0) {
        slog.info("No not-logged-in clients to cycle through", .{});
        return;
    }

    // Prefers the real foreground window over the remembered cursor, since logging out while already focused fires no OS focus event to update it.
    var found_index = indexOfHwnd(hwnds.items, win32.GetForegroundWindow());
    if (found_index == null) {
        if (manager.cycle.last_not_logged_in_hwnd) |last_hwnd| {
            found_index = indexOfHwnd(hwnds.items, last_hwnd);
        }
    }

    var it = CycleOrder.init(found_index, num, forward, true);
    const index = it.next() orelse return;
    const hwnd = hwnds.items[index];
    slog.info("Cycling {s} to not-logged-in client ({}/{})", .{ directionName(forward), index + 1, num });
    activation.activate(hwnd);
    manager.cycle.last_not_logged_in_hwnd = hwnd;
}

/// Moves every cycle cursor onto a manually focused character, so the next cycle press continues from it.
pub fn syncToFocusedCharacter(manager: *HotkeyManager, character_name: []const u8, hwnd: win32.HWND) void {
    // Verify the window actually has focus first, to avoid stale updates during rapid cycling.
    if (hwnd != win32.GetForegroundWindow()) {
        slog.debug("Ignoring focus sync for {s} - not the foreground window", .{character_name});
        return;
    }

    // Every not-logged-in window shares the name "EVE", so hwnd (not name) is the cursor; skip the by-name syncing below, which doesn't apply.
    if (scout.isGenericCharacterName(character_name)) {
        manager.cycle.last_not_logged_in_hwnd = hwnd;
        return;
    }

    syncExcludedCycleIndex(manager, character_name);

    const already_synced = if (manager.cycle.last_all_clients_name) |last| std.mem.eql(u8, last, character_name) else false;
    if (!already_synced) setOwnedCursorName(manager.allocator, &manager.cycle.last_all_clients_name, character_name, "all-clients");

    var actions = manager.hotkey_map.valueIterator();
    while (actions.next()) |action| {
        if (action.* != .activate_character) continue;
        const group = &action.activate_character;
        for (group.character_indices, 0..) |char_index, idx| {
            if (char_index < manager.config.characters.items.len and std.mem.eql(u8, manager.config.characters.items[char_index].name, character_name)) {
                group.current_index = idx;
                break;
            }
        }
    }

    syncGroupCycleIndex(manager.config.hotkeyGroups.items, manager.cycle.group_cursors, character_name, manager.live().hotkeys.resetGroupIndexOnNonGroupFocus);
}

fn characterOrderSignature(characters: []const config.CharacterConfig) u64 {
    var h = std.hash.Wyhash.init(0);
    for (characters) |char| {
        h.update(char.name);
        // The map's keys borrow these names, so a reallocated but equal name (a discarded dialog preview) must rebuild it too.
        h.update(std.mem.asBytes(&char.name.ptr));
    }
    return h.final();
}

/// Takes an optional target since callers pass GetForegroundWindow() directly.
fn indexOfHwnd(hwnds: []const win32.HWND, target: ?win32.HWND) ?usize {
    return std.mem.findScalar(win32.HWND, hwnds, target orelse return null);
}

const ChainMember = struct {
    group_index: usize,
    /// Into that group's characters.
    index: usize,
};

/// `position` must be below the chain's total member count.
fn chainMember(groups: []const config.HotkeyGroupConfig, group_indices: []const usize, position: usize) ChainMember {
    var remaining = position;
    for (group_indices) |group_index| {
        const member_count = groups[group_index].characters.items.len;
        if (remaining < member_count) return .{ .group_index = group_index, .index = remaining };
        remaining -= member_count;
    }
    unreachable;
}

/// Prefers the group whose cursor is on the focused character, then the last-cycled one, since a character can sit in several groups.
fn chainCursor(manager: *HotkeyManager, group_indices: []const usize) ?usize {
    const groups = manager.config.hotkeyGroups.items;
    const focused_name = if (manager.foregroundEveWindow()) |eve_window| eve_window.character_name else null;
    var best: ?usize = null;
    var best_rank: u8 = 0;
    var offset: usize = 0;
    for (group_indices) |group_index| {
        const members = groups[group_index].characters.items;
        const start = offset;
        offset += members.len;

        const cursor = manager.cycle.group_cursors[group_index] orelse continue;
        if (cursor >= members.len) continue;
        const is_focused = if (focused_name) |name| std.mem.eql(u8, members[cursor], name) else false;
        const is_last = manager.cycle.last_cycled_group == group_index;
        const rank: u8 = 1 + 2 * @as(u8, @intFromBool(is_focused)) + @intFromBool(is_last);
        if (rank > best_rank) {
            best_rank = rank;
            best = start + cursor;
        }
    }
    return best;
}

/// The window for a chain position, where not-logged-in positions follow the groups' characters; null if it isn't a valid target.
fn chainEntryHwnd(manager: *HotkeyManager, group_indices: []const usize, member_count: usize, not_logged_in_hwnds: []const win32.HWND, position: usize) ?win32.HWND {
    if (position >= member_count) return not_logged_in_hwnds[position - member_count];
    const groups = manager.config.hotkeyGroups.items;
    const member = chainMember(groups, group_indices, position);
    const char_name = groups[member.group_index].characters.items[member.index];
    if (manager.exclusions.contains(char_name)) return null;
    return manager.scout.getHwndByName(char_name);
}

/// Replaces `field.*` with an owned copy of name, freeing the previous value.
fn setOwnedCursorName(allocator: std.mem.Allocator, field: *?[]const u8, name: []const u8, context: []const u8) void {
    const duped = allocator.dupe(u8, name) catch |err| {
        slog.err("Failed to remember {s} cycle cursor for '{s}': {}", .{ context, name, err });
        return;
    };
    if (field.*) |old| allocator.free(old);
    field.* = duped;
}

/// `cursors` parallels `groups`; reset_on_leave clears the cursor of groups character_name isn't in.
fn syncGroupCycleIndex(groups: []const config.HotkeyGroupConfig, cursors: []?usize, character_name: []const u8, reset_on_leave: bool) void {
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

fn syncExcludedCycleIndex(manager: *HotkeyManager, character_name: []const u8) void {
    const excluded_names = manager.exclusions.names.items;
    const index = strings.indexOfString(excluded_names, character_name) orelse return;
    if (manager.cycle.excluded_index == null or manager.cycle.excluded_index.? != index) {
        slog.debug("Updated excluded cycle index: {s} now at position {}/{}", .{ character_name, index + 1, excluded_names.len });
        manager.cycle.excluded_index = index;
    }
}
