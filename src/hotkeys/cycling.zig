//! The cycle hotkeys: through a group, a shared per-character key, and the excluded, notified, all and not-logged-in clients; each returns the client to bring to the front, or null.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const scout = @import("../clients/scout.zig");
const strings = @import("../util/strings.zig");
const bindings = @import("bindings.zig");
const cycle_order = @import("cycle_order.zig");
const commands_mod = @import("commands.zig");
const log = @import("../log.zig");

const Commands = commands_mod.Commands;
const CycleOrder = cycle_order.CycleOrder;
const directionName = cycle_order.directionName;
const slog = log.Scoped("hotkeys");

/// Every cycle's position but the per-character hotkeys', which the hotkey manager's map keeps.
pub const CycleState = struct {
    /// Each hotkey group's position, in the saved config.hotkeyGroups order; null = not yet cycled, and empty until reset.
    group_cursors: std.ArrayList(?usize) = .empty,
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

    pub fn deinit(self: *CycleState, allocator: std.mem.Allocator) void {
        self.group_cursors.deinit(allocator);
        if (self.last_notified_name) |name| allocator.free(name);
        if (self.last_all_clients_name) |name| allocator.free(name);
        self.character_order.deinit();
    }

    /// Back to no cycle position, for `group_count` saved groups; as when the hotkey manager is recreated after a Save or profile switch.
    pub fn reset(self: *CycleState, allocator: std.mem.Allocator, group_count: usize) void {
        self.deinit(allocator);
        self.* = .{};
        self.group_cursors.appendNTimes(allocator, null, group_count) catch |err| {
            slog.err("Failed to keep the hotkey groups' cycle positions, so group cycling is off until the next Save: {}", .{err});
        };
    }
};

/// cycle_order.planGroupCycle's view of the running clients.
const Clients = struct {
    commands: *const Commands,

    pub fn hwndFor(self: Clients, name: []const u8) ?win32.HWND {
        return self.commands.scout.getHwndByName(name);
    }

    pub fn isExcluded(self: Clients, name: []const u8) bool {
        const is_excluded = self.commands.exclusions.contains(name);
        if (is_excluded) slog.debug("Skipping excluded character: {s}", .{name});
        return is_excluded;
    }
};

/// Cycles to the next running character sharing this hotkey.
pub fn activatePerCharacterGroup(commands: *const Commands, group: *bindings.CharacterGroup) ?win32.HWND {
    const member_count = group.character_indices.len;
    var it = CycleOrder.init(group.current_index, member_count, .{ .is_forward = true });
    while (it.next()) |member_index| {
        const character_index = group.character_indices[member_index];
        if (character_index >= commands.config.characters.items.len) continue;
        const character_name = commands.config.characters.items[character_index].name;

        if (commands.scout.getHwndByName(character_name)) |hwnd| {
            group.current_index = member_index;
            slog.info("Activating character: {s} ({}/{})", .{ character_name, member_index + 1, member_count });
            return hwnd;
        }
    }

    slog.info("No running character for the shared character hotkey", .{});
    return null;
}

/// Cycles the groups' members as one list; logged-out clients join if any group includes them, ends stop only if all do.
pub fn cycleGroups(commands: *const Commands, group_indices: []const usize, is_forward: bool) ?win32.HWND {
    const groups = commands.config.hotkeyGroups.items;
    if (commands.cycle.group_cursors.items.len != groups.len) {
        slog.warn("Failed to cycle group: its cycle positions weren't kept", .{});
        return null;
    }
    const chain = switch (cycle_order.chainOf(groups, group_indices)) {
        .chain => |chain| chain,
        .invalid_group => |group_index| {
            slog.err("Failed to cycle group: index {} is out of range", .{group_index});
            return null;
        },
    };

    var not_logged_in_hwnds: std.ArrayList(win32.HWND) = .empty;
    defer not_logged_in_hwnds.deinit(commands.allocator);
    if (chain.includes_not_logged_in) {
        not_logged_in_hwnds = commands.scout.getNotLoggedInHwnds(commands.allocator) catch |err| blk: {
            slog.err("Failed to build not-logged-in window list for group cycle: {}", .{err});
            break :blk .empty;
        };
    }

    const step = cycle_order.planGroupCycle(.{
        .groups = groups,
        .group_indices = group_indices,
        .chain = chain,
        .cursors = commands.cycle.group_cursors.items,
        .last_cycled_group = commands.cycle.last_cycled_group,
        .not_logged_in_hwnds = not_logged_in_hwnds.items,
        .last_not_logged_in_hwnd = commands.cycle.last_not_logged_in_hwnd,
        .foreground_hwnd = win32.GetForegroundWindow(),
        .focused_name = if (commands.foregroundEveWindow()) |eve_window| eve_window.character_name else null,
        .is_forward = is_forward,
    }, Clients{ .commands = commands });

    switch (step) {
        .empty => slog.info("Hotkey group has no characters to cycle", .{}),
        .member => |target| {
            const member = target.member;
            commands.cycle.group_cursors.items[member.group_index] = member.index;
            commands.cycle.last_cycled_group = member.group_index;
            slog.info("Cycling {s} to: {s} ({}/{})", .{ directionName(is_forward), groups[member.group_index].characters.items[member.index], target.position + 1, target.total_count });
            return target.hwnd;
        },
        .not_logged_in => |target| {
            // The not-logged-in tail is tracked by hwnd, so no group position applies.
            for (group_indices) |group_index| commands.cycle.group_cursors.items[group_index] = null;
            slog.info("Cycling {s} to not-logged-in client ({}/{})", .{ directionName(is_forward), target.position + 1, target.total_count });
            commands.cycle.last_not_logged_in_hwnd = target.hwnd;
            return target.hwnd;
        },
        .refocus_end => |target| {
            slog.info("Refocusing {s} end of hotkey group ({}/{})", .{ directionName(is_forward), target.position + 1, target.total_count });
            return target.hwnd;
        },
        .at_end => slog.debug("Already at the {s} end of hotkey group", .{directionName(is_forward)}),
        .none => slog.info("No running, non-excluded character in the hotkey group", .{}),
    }
    return null;
}

/// In the order the characters were excluded.
pub fn cycleExcluded(commands: *const Commands, is_forward: bool) ?win32.HWND {
    slog.info("Cycle excluded character hotkey pressed ({s})", .{directionName(is_forward)});
    const excluded_names = commands.exclusions.names.items;

    const excluded_count = excluded_names.len;
    if (excluded_count == 0) {
        slog.info("No excluded characters to cycle through", .{});
        return null;
    }

    var it = CycleOrder.init(commands.cycle.excluded_index, excluded_count, .{ .is_forward = is_forward });
    while (it.next()) |name_index| {
        const character_name = excluded_names[name_index];

        if (commands.scout.getHwndByName(character_name)) |hwnd| {
            commands.cycle.excluded_index = name_index;
            slog.info("Cycling {s} to excluded character: {s} ({}/{})", .{ directionName(is_forward), character_name, name_index + 1, excluded_count });
            return hwnd;
        }
        slog.debug("Excluded character {s} is not currently running, skipping", .{character_name});
    }

    slog.info("No excluded character is running", .{});
    return null;
}

/// Forward visits the oldest notification first (FIFO).
pub fn cycleNotified(commands: *const Commands, is_forward: bool) ?win32.HWND {
    slog.info("Cycle notified character hotkey pressed ({s})", .{directionName(is_forward)});
    const retention_ms: u64 = @as(u64, commands.live().notifications.notified_cycle_retention_seconds) * std.time.ms_per_s;

    var names = commands.notified_queue.namesWithin(commands.allocator, retention_ms) catch |err| {
        slog.err("Failed to build notified-character list: {}", .{err});
        return null;
    };
    defer names.deinit(commands.allocator);

    const notified_count = names.items.len;
    if (notified_count == 0) {
        slog.info("No recently-notified characters to cycle through", .{});
        return null;
    }

    const found_index = if (commands.cycle.last_notified_name) |last_name| strings.indexOfString(names.items, last_name) else null;
    var it = CycleOrder.init(found_index, notified_count, .{ .is_forward = is_forward });
    while (it.next()) |index| {
        const character_name = names.items[index];

        if (commands.scout.getHwndByName(character_name)) |hwnd| {
            slog.info("Cycling {s} to notified character: {s} ({}/{})", .{ directionName(is_forward), character_name, index + 1, notified_count });
            setOwnedCursorName(commands.allocator, &commands.cycle.last_notified_name, character_name, "notified");
            return hwnd;
        }
        slog.debug("Notified character {s} is not currently running, skipping", .{character_name});
    }

    slog.info("No notified character is running", .{});
    return null;
}

/// In Characters-list order, unconfigured clients after in Scout's; unlike other cycles, every entry is running.
pub fn cycleAllClients(commands: *const Commands, is_forward: bool) ?win32.HWND {
    slog.info("Cycle all clients hotkey pressed ({s})", .{directionName(is_forward)});
    const windows = commands.scout.getWindows();
    const window_count = windows.len;
    if (window_count == 0) {
        slog.info("No logged-in clients to cycle through", .{});
        return null;
    }

    const order = commands.cycle.character_order.orderedIndices(commands.allocator, commands.live().characters.items, windows) catch |err| {
        slog.err("Failed to build character-ordered client list: {}", .{err});
        return null;
    };
    defer commands.allocator.free(order);

    var found_index: ?usize = null;
    if (commands.cycle.last_all_clients_name) |last_name| {
        for (order, 0..) |window_index, i| {
            if (std.mem.eql(u8, windows[window_index].character_name, last_name)) {
                found_index = i;
                break;
            }
        }
    }

    const respects_exclusions = commands.liveGlobal().cycleAllClientsRespectExclusions;
    var it = CycleOrder.init(found_index, window_count, .{ .is_forward = is_forward });
    while (it.next()) |index| {
        const eve_window = windows[order[index]];
        if (scout.isGenericCharacterName(eve_window.character_name)) continue;
        if (respects_exclusions and commands.exclusions.contains(eve_window.character_name)) continue;

        slog.info("Cycling {s} to client: {s} ({}/{})", .{ directionName(is_forward), eve_window.character_name, index + 1, window_count });
        setOwnedCursorName(commands.allocator, &commands.cycle.last_all_clients_name, eve_window.character_name, "all-clients");
        return eve_window.hwnd;
    }

    slog.info("Every logged-in client is excluded from cycling", .{});
    return null;
}

/// Cycles windows still at the login screen ("EVE" title), in the order they logged out.
pub fn cycleNotLoggedIn(commands: *const Commands, is_forward: bool) ?win32.HWND {
    slog.info("Cycle not-logged-in hotkey pressed ({s})", .{directionName(is_forward)});
    var hwnds = commands.scout.getNotLoggedInHwnds(commands.allocator) catch |err| {
        slog.err("Failed to build not-logged-in window list: {}", .{err});
        return null;
    };
    defer hwnds.deinit(commands.allocator);

    const hwnd_count = hwnds.items.len;
    if (hwnd_count == 0) {
        slog.info("No not-logged-in clients to cycle through", .{});
        return null;
    }

    // Prefers the real foreground window over the remembered cursor, since logging out while already focused fires no OS focus event to update it.
    var found_index = cycle_order.indexOfHwnd(hwnds.items, win32.GetForegroundWindow());
    if (found_index == null) {
        if (commands.cycle.last_not_logged_in_hwnd) |last_hwnd| {
            found_index = cycle_order.indexOfHwnd(hwnds.items, last_hwnd);
        }
    }

    var it = CycleOrder.init(found_index, hwnd_count, .{ .is_forward = is_forward });
    const index = it.next() orelse {
        slog.debug("No not-logged-in client to cycle to", .{});
        return null;
    };
    const hwnd = hwnds.items[index];
    slog.info("Cycling {s} to not-logged-in client ({}/{})", .{ directionName(is_forward), index + 1, hwnd_count });
    commands.cycle.last_not_logged_in_hwnd = hwnd;
    return hwnd;
}

/// Moves the cycle cursors onto a manually focused character; returns whether it was one, so the manager moves its per-character cursors too.
pub fn syncToFocusedCharacter(commands: *const Commands, character_name: []const u8, hwnd: win32.HWND) bool {
    // Focus events can arrive late during rapid cycling.
    if (hwnd != win32.GetForegroundWindow()) {
        slog.debug("Ignoring focus sync for {s} - not the foreground window", .{character_name});
        return false;
    }

    // Every login-screen window is named "EVE", so its cursor is the hwnd rather than a name.
    if (scout.isGenericCharacterName(character_name)) {
        commands.cycle.last_not_logged_in_hwnd = hwnd;
        return false;
    }

    syncExcludedCycleIndex(commands, character_name);

    const is_already_synced = if (commands.cycle.last_all_clients_name) |last| std.mem.eql(u8, last, character_name) else false;
    if (!is_already_synced) setOwnedCursorName(commands.allocator, &commands.cycle.last_all_clients_name, character_name, "all-clients");

    const groups = commands.config.hotkeyGroups.items;
    if (commands.cycle.group_cursors.items.len == groups.len) {
        cycle_order.syncGroupCycleIndex(groups, commands.cycle.group_cursors.items, character_name, commands.live().hotkeys.resetGroupIndexOnNonGroupFocus);
    }
    return true;
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

fn syncExcludedCycleIndex(commands: *const Commands, character_name: []const u8) void {
    const excluded_names = commands.exclusions.names.items;
    const index = strings.indexOfString(excluded_names, character_name) orelse return;
    if (commands.cycle.excluded_index != index) {
        slog.debug("Updated excluded cycle index: {s} now at position {}/{}", .{ character_name, index + 1, excluded_names.len });
        commands.cycle.excluded_index = index;
    }
}
