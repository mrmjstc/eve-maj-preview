//! The cycle hotkeys: through a group, a shared per-character key, and the excluded, notified, all and not-logged-in clients.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const activation = @import("../control/activation.zig");
const scout = @import("../clients/scout.zig");
const strings = @import("../util/strings.zig");
const bindings = @import("bindings.zig");
const cycle_order = @import("cycle_order.zig");
const manager_mod = @import("manager.zig");
const log = @import("../log.zig");

const HotkeyManager = manager_mod.HotkeyManager;
const CycleOrder = cycle_order.CycleOrder;
const directionName = cycle_order.directionName;
const slog = log.Scoped("hotkeys");

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
    character_order: cycle_order.CharacterOrderCache = .{},

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

/// cycle_order.planGroupCycle's view of the running clients.
const Clients = struct {
    manager: *const HotkeyManager,

    pub fn hwndFor(self: Clients, name: []const u8) ?win32.HWND {
        return self.manager.scout.getHwndByName(name);
    }

    pub fn isExcluded(self: Clients, name: []const u8) bool {
        const is_excluded = self.manager.exclusions.contains(name);
        if (is_excluded) slog.debug("Skipping excluded character: {s}", .{name});
        return is_excluded;
    }
};

/// Cycles to the next running character sharing this hotkey.
pub fn activatePerCharacterGroup(manager: *HotkeyManager, group: *bindings.CharacterGroup) void {
    const member_count = group.character_indices.len;
    var it = CycleOrder.init(group.current_index, member_count, .{ .is_forward = true });
    while (it.next()) |member_index| {
        const character_index = group.character_indices[member_index];
        if (character_index >= manager.config.characters.items.len) continue;
        const character_name = manager.config.characters.items[character_index].name;

        if (manager.scout.getHwndByName(character_name)) |hwnd| {
            group.current_index = member_index;
            slog.info("Activating character: {s} ({}/{})", .{ character_name, member_index + 1, member_count });
            activation.activate(manager.app, hwnd);
            return;
        }
    }

    slog.info("No running character for the shared character hotkey", .{});
}

/// Cycles the groups' members as one list; logged-out clients join if any group includes them, ends stop only if all do.
pub fn cycleGroups(manager: *HotkeyManager, group_indices: []const usize, is_forward: bool) void {
    const groups = manager.config.hotkeyGroups.items;
    const chain = switch (cycle_order.chainOf(groups, group_indices)) {
        .chain => |chain| chain,
        .invalid_group => |group_index| {
            slog.err("Failed to cycle group: index {} is out of range", .{group_index});
            return;
        },
    };

    var not_logged_in_hwnds: std.ArrayList(win32.HWND) = .empty;
    defer not_logged_in_hwnds.deinit(manager.allocator);
    if (chain.includes_not_logged_in) {
        not_logged_in_hwnds = manager.scout.getNotLoggedInHwnds(manager.allocator) catch |err| blk: {
            slog.err("Failed to build not-logged-in window list for group cycle: {}", .{err});
            break :blk .empty;
        };
    }

    const step = cycle_order.planGroupCycle(.{
        .groups = groups,
        .group_indices = group_indices,
        .chain = chain,
        .cursors = manager.cycle.group_cursors,
        .last_cycled_group = manager.cycle.last_cycled_group,
        .not_logged_in_hwnds = not_logged_in_hwnds.items,
        .last_not_logged_in_hwnd = manager.cycle.last_not_logged_in_hwnd,
        .foreground_hwnd = win32.GetForegroundWindow(),
        .focused_name = if (manager.foregroundEveWindow()) |eve_window| eve_window.character_name else null,
        .is_forward = is_forward,
    }, Clients{ .manager = manager });

    switch (step) {
        .empty => slog.info("Hotkey group has no characters to cycle", .{}),
        .member => |target| {
            const member = target.member;
            manager.cycle.group_cursors[member.group_index] = member.index;
            manager.cycle.last_cycled_group = member.group_index;
            slog.info("Cycling {s} to: {s} ({}/{})", .{ directionName(is_forward), groups[member.group_index].characters.items[member.index], target.position + 1, target.total_count });
            activation.activate(manager.app, target.hwnd);
        },
        .not_logged_in => |target| {
            // The not-logged-in tail is tracked by hwnd, so no group position applies.
            for (group_indices) |group_index| manager.cycle.group_cursors[group_index] = null;
            slog.info("Cycling {s} to not-logged-in client ({}/{})", .{ directionName(is_forward), target.position + 1, target.total_count });
            activation.activate(manager.app, target.hwnd);
            manager.cycle.last_not_logged_in_hwnd = target.hwnd;
        },
        .refocus_end => |target| {
            slog.info("Refocusing {s} end of hotkey group ({}/{})", .{ directionName(is_forward), target.position + 1, target.total_count });
            activation.activate(manager.app, target.hwnd);
        },
        .at_end => slog.debug("Already at the {s} end of hotkey group", .{directionName(is_forward)}),
        .none => slog.info("No running, non-excluded character in the hotkey group", .{}),
    }
}

/// In the order the characters were excluded.
pub fn cycleExcluded(manager: *HotkeyManager, is_forward: bool) void {
    slog.info("Cycle excluded character hotkey pressed ({s})", .{directionName(is_forward)});
    const excluded_names = manager.exclusions.names.items;

    const excluded_count = excluded_names.len;
    if (excluded_count == 0) {
        slog.info("No excluded characters to cycle through", .{});
        return;
    }

    var it = CycleOrder.init(manager.cycle.excluded_index, excluded_count, .{ .is_forward = is_forward });
    while (it.next()) |name_index| {
        const character_name = excluded_names[name_index];

        if (manager.scout.getHwndByName(character_name)) |hwnd| {
            manager.cycle.excluded_index = name_index;
            slog.info("Cycling {s} to excluded character: {s} ({}/{})", .{ directionName(is_forward), character_name, name_index + 1, excluded_count });
            activation.activate(manager.app, hwnd);
            return;
        }
        slog.debug("Excluded character {s} is not currently running, skipping", .{character_name});
    }

    slog.info("No excluded character is running", .{});
}

/// Cycles to the most-recently-notified character (FIFO).
pub fn cycleNotified(manager: *HotkeyManager, is_forward: bool) void {
    slog.info("Cycle notified character hotkey pressed ({s})", .{directionName(is_forward)});
    const retention_ms: u64 = @as(u64, manager.live().thumbnail.notifications.notified_cycle_retention_seconds) * std.time.ms_per_s;

    var names = manager.notified_queue.namesWithin(manager.allocator, retention_ms) catch |err| {
        slog.err("Failed to build notified-character list: {}", .{err});
        return;
    };
    defer names.deinit(manager.allocator);

    const notified_count = names.items.len;
    if (notified_count == 0) {
        slog.info("No recently-notified characters to cycle through", .{});
        return;
    }

    const found_index = if (manager.cycle.last_notified_name) |last_name| strings.indexOfString(names.items, last_name) else null;
    var it = CycleOrder.init(found_index, notified_count, .{ .is_forward = is_forward });
    while (it.next()) |index| {
        const character_name = names.items[index];

        if (manager.scout.getHwndByName(character_name)) |hwnd| {
            slog.info("Cycling {s} to notified character: {s} ({}/{})", .{ directionName(is_forward), character_name, index + 1, notified_count });
            activation.activate(manager.app, hwnd);
            setOwnedCursorName(manager.allocator, &manager.cycle.last_notified_name, character_name, "notified");
            return;
        }
        slog.debug("Notified character {s} is not currently running, skipping", .{character_name});
    }

    slog.info("No notified character is running", .{});
}

/// Cycles every logged-in client in Characters-list order (unconfigured ones follow, in Scout's discovery order); unlike other cycles, every entry is guaranteed running.
pub fn cycleAllClients(manager: *HotkeyManager, is_forward: bool) void {
    slog.info("Cycle all clients hotkey pressed ({s})", .{directionName(is_forward)});
    const windows = manager.scout.getWindows();
    const window_count = windows.len;
    if (window_count == 0) {
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

    const respects_exclusions = manager.liveGlobal().cycleAllClientsRespectExclusions;
    var it = CycleOrder.init(found_index, window_count, .{ .is_forward = is_forward });
    while (it.next()) |index| {
        const eve_window = windows[order[index]];
        if (scout.isGenericCharacterName(eve_window.character_name)) continue;
        if (respects_exclusions and manager.exclusions.contains(eve_window.character_name)) continue;

        slog.info("Cycling {s} to client: {s} ({}/{})", .{ directionName(is_forward), eve_window.character_name, index + 1, window_count });
        activation.activate(manager.app, eve_window.hwnd);
        setOwnedCursorName(manager.allocator, &manager.cycle.last_all_clients_name, eve_window.character_name, "all-clients");
        return;
    }

    slog.info("Every logged-in client is excluded from cycling", .{});
}

/// Cycles windows still at the login screen ("EVE" title), in the order they logged out.
pub fn cycleNotLoggedIn(manager: *HotkeyManager, is_forward: bool) void {
    slog.info("Cycle not-logged-in hotkey pressed ({s})", .{directionName(is_forward)});
    var hwnds = manager.scout.getNotLoggedInHwnds(manager.allocator) catch |err| {
        slog.err("Failed to build not-logged-in window list: {}", .{err});
        return;
    };
    defer hwnds.deinit(manager.allocator);

    const hwnd_count = hwnds.items.len;
    if (hwnd_count == 0) {
        slog.info("No not-logged-in clients to cycle through", .{});
        return;
    }

    // Prefers the real foreground window over the remembered cursor, since logging out while already focused fires no OS focus event to update it.
    var found_index = cycle_order.indexOfHwnd(hwnds.items, win32.GetForegroundWindow());
    if (found_index == null) {
        if (manager.cycle.last_not_logged_in_hwnd) |last_hwnd| {
            found_index = cycle_order.indexOfHwnd(hwnds.items, last_hwnd);
        }
    }

    var it = CycleOrder.init(found_index, hwnd_count, .{ .is_forward = is_forward });
    const index = it.next() orelse return;
    const hwnd = hwnds.items[index];
    slog.info("Cycling {s} to not-logged-in client ({}/{})", .{ directionName(is_forward), index + 1, hwnd_count });
    activation.activate(manager.app, hwnd);
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

    const is_already_synced = if (manager.cycle.last_all_clients_name) |last| std.mem.eql(u8, last, character_name) else false;
    if (!is_already_synced) setOwnedCursorName(manager.allocator, &manager.cycle.last_all_clients_name, character_name, "all-clients");

    var actions = manager.hotkey_map.valueIterator();
    while (actions.next()) |action| {
        if (action.* != .activate_character) continue;
        const group = &action.activate_character;
        for (group.character_indices, 0..) |character_index, member_index| {
            if (character_index < manager.config.characters.items.len and std.mem.eql(u8, manager.config.characters.items[character_index].name, character_name)) {
                group.current_index = member_index;
                break;
            }
        }
    }

    cycle_order.syncGroupCycleIndex(manager.config.hotkeyGroups.items, manager.cycle.group_cursors, character_name, manager.live().hotkeys.resetGroupIndexOnNonGroupFocus);
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

fn syncExcludedCycleIndex(manager: *HotkeyManager, character_name: []const u8) void {
    const excluded_names = manager.exclusions.names.items;
    const index = strings.indexOfString(excluded_names, character_name) orelse return;
    if (manager.cycle.excluded_index != index) {
        slog.debug("Updated excluded cycle index: {s} now at position {}/{}", .{ character_name, index + 1, excluded_names.len });
        manager.cycle.excluded_index = index;
    }
}
