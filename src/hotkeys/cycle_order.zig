//! Where a cycle hotkey goes next: cycle orders, positions in a chain of groups and the cursors that track them; no Win32 calls.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const scout = @import("../clients/scout.zig");
const characters = @import("../config/characters.zig");
const hotkeys_config = @import("../config/hotkeys.zig");
const strings = @import("../util/strings.zig");
const log = @import("../log.zig");

const CharacterConfig = characters.CharacterConfig;
const HotkeyGroupConfig = hotkeys_config.HotkeyGroupConfig;
const slog = log.Scoped("hotkeys");

/// Visits each index below item_count once, from one past `cursor`, or the first in its direction when stale; stops at the end unless it `wraps`.
pub const CycleOrder = struct {
    index: usize,
    item_count: usize,
    is_forward: bool,
    remaining_count: usize,

    pub const Options = struct { is_forward: bool, wraps: bool = true };

    pub fn init(cursor: ?usize, item_count: usize, options: Options) CycleOrder {
        const is_forward = options.is_forward;
        const valid_cursor = if (cursor) |position| (if (position < item_count) position else null) else null;
        // Wraps harmlessly when item_count == 0: remaining_count is 0, so next() never steps.
        const before_start = valid_cursor orelse (if (is_forward) item_count -% 1 else 0);
        const remaining_count = if (options.wraps) item_count else if (valid_cursor) |position| (if (is_forward) item_count - 1 - position else position) else item_count;
        return .{ .index = before_start, .item_count = item_count, .is_forward = is_forward, .remaining_count = remaining_count };
    }

    pub fn next(self: *CycleOrder) ?usize {
        if (self.remaining_count == 0) return null;
        self.remaining_count -= 1;
        if (self.is_forward) {
            self.index = (self.index + 1) % self.item_count;
        } else {
            self.index = if (self.index == 0) self.item_count - 1 else self.index - 1;
        }
        return self.index;
    }
};

/// Character name to configured-order index, rebuilt only when the Characters list's names or order change, far less often than cycling presses.
pub const CharacterOrderCache = struct {
    map: ?std.StringHashMap(usize) = null,
    signature: u64 = 0,

    pub fn deinit(self: *CharacterOrderCache) void {
        if (self.map) |*map| map.deinit();
    }

    fn get(self: *CharacterOrderCache, allocator: std.mem.Allocator, configured: []const CharacterConfig) !*const std.StringHashMap(usize) {
        const signature = characterOrderSignature(configured);
        if (self.map == null or self.signature != signature) {
            if (self.map) |*old| old.deinit();
            self.map = try characters.buildCharacterOrderMap(configured, allocator);
            self.signature = signature;
        }
        return &self.map.?;
    }

    /// Caller owns the returned slice; windows for unconfigured characters sort after configured ones, keeping discovery order among themselves.
    pub fn orderedIndices(self: *CharacterOrderCache, allocator: std.mem.Allocator, configured: []const CharacterConfig, windows: []const scout.EveWindow) ![]usize {
        const order_map = try self.get(allocator, configured);

        const indices = try allocator.alloc(usize, windows.len);
        for (indices, 0..) |*slot, i| slot.* = i;

        const Context = struct {
            windows: []const scout.EveWindow,
            order_map: *const std.StringHashMap(usize),

            fn lessThan(context: @This(), a_index: usize, b_index: usize) bool {
                return characters.orderMapLessThan(context.order_map, context.windows[a_index].character_name, context.windows[b_index].character_name, a_index, b_index);
            }
        };

        std.sort.pdq(usize, indices, Context{ .windows = windows, .order_map = order_map }, Context.lessThan);
        return indices;
    }
};

pub const ChainMember = struct {
    group_index: usize,
    /// Into that group's characters.
    index: usize,
};

/// What a chain of groups sharing one cycle key holds, from chainOf.
pub const Chain = struct {
    member_count: usize,
    /// Any group in it includes not-logged-in clients, which then follow its members.
    includes_not_logged_in: bool,
    /// Every group in it stops at its ends; one that wraps makes the chain wrap.
    stops_at_ends: bool,
};

pub const ChainCheck = union(enum) {
    chain: Chain,
    /// A group index past the end of the groups.
    invalid_group: usize,
};

/// The inputs to planGroupCycle; borrows every slice.
pub const GroupCycle = struct {
    groups: []const HotkeyGroupConfig,
    group_indices: []const usize,
    chain: Chain,
    /// One cursor per group in `groups`.
    cursors: []const ?usize,
    last_cycled_group: ?usize,
    /// Windows at the login screen, oldest logout first; empty unless the chain includes them.
    not_logged_in_hwnds: []const win32.HWND,
    last_not_logged_in_hwnd: ?win32.HWND,
    foreground_hwnd: ?win32.HWND,
    /// The focused client's character, if a tracked client has focus.
    focused_name: ?[]const u8,
    is_forward: bool,
};

/// What a group cycle press does; `position` counts members first, then not-logged-in clients, out of `total_count`.
pub const GroupStep = union(enum) {
    /// The chain holds no one.
    empty,
    member: struct { member: ChainMember, hwnd: win32.HWND, position: usize, total_count: usize },
    not_logged_in: struct { hwnd: win32.HWND, position: usize, total_count: usize },
    /// The chain stops at its ends and has nowhere further to go, but focus has moved off the end client, so it comes back.
    refocus_end: struct { hwnd: win32.HWND, position: usize, total_count: usize },
    /// The chain stops at its ends and the end client already has focus.
    at_end,
    /// No running, non-excluded client in the chain.
    none,
};

pub fn directionName(is_forward: bool) []const u8 {
    return if (is_forward) "forward" else "backward";
}

pub fn chainOf(groups: []const HotkeyGroupConfig, group_indices: []const usize) ChainCheck {
    var chain: Chain = .{ .member_count = 0, .includes_not_logged_in = false, .stops_at_ends = true };
    for (group_indices) |group_index| {
        if (group_index >= groups.len) return .{ .invalid_group = group_index };
        const group = &groups[group_index];
        chain.member_count += group.characters.items.len;
        chain.includes_not_logged_in = chain.includes_not_logged_in or group.includeNotLoggedIn;
        chain.stops_at_ends = chain.stops_at_ends and group.stopAtEnds;
    }
    return .{ .chain = chain };
}

/// Walks the chain from its cursor to the next running, non-excluded member or not-logged-in client.
/// `clients`: `hwndFor(name) ?win32.HWND` and `isExcluded(name) bool`.
pub fn planGroupCycle(cycle: GroupCycle, clients: anytype) GroupStep {
    const member_count = cycle.chain.member_count;
    const total_count = member_count + cycle.not_logged_in_hwnds.len;
    if (total_count == 0) return .empty;

    // Prefers the real foreground window for the not-logged-in tail, since logging out while already focused fires no OS focus event to update the cursor.
    var found_index: ?usize = null;
    if (indexOfHwnd(cycle.not_logged_in_hwnds, cycle.foreground_hwnd)) |i| found_index = member_count + i;
    if (found_index == null) found_index = chainCursor(cycle.groups, cycle.group_indices, cycle.cursors, cycle.last_cycled_group, cycle.focused_name);
    if (found_index == null) {
        if (indexOfHwnd(cycle.not_logged_in_hwnds, cycle.last_not_logged_in_hwnd)) |i| found_index = member_count + i;
    }

    var it: CycleOrder = .init(found_index, total_count, .{ .is_forward = cycle.is_forward, .wraps = !cycle.chain.stops_at_ends });
    while (it.next()) |position| {
        if (position >= member_count) return .{
            .not_logged_in = .{ .hwnd = cycle.not_logged_in_hwnds[position - member_count], .position = position, .total_count = total_count },
        };
        const member = chainMember(cycle.groups, cycle.group_indices, position);
        const hwnd = memberHwnd(cycle, member, clients) orelse continue;
        return .{ .member = .{ .member = member, .hwnd = hwnd, .position = position, .total_count = total_count } };
    }

    if (!cycle.chain.stops_at_ends) return .none;
    const current = found_index orelse return .none;
    const hwnd = if (current >= member_count)
        cycle.not_logged_in_hwnds[current - member_count]
    else
        memberHwnd(cycle, chainMember(cycle.groups, cycle.group_indices, current), clients) orelse return .none;
    if (hwnd == cycle.foreground_hwnd) return .at_end;
    return .{ .refocus_end = .{ .hwnd = hwnd, .position = current, .total_count = total_count } };
}

/// Takes an optional target since callers pass GetForegroundWindow() directly.
pub fn indexOfHwnd(hwnds: []const win32.HWND, target: ?win32.HWND) ?usize {
    return std.mem.findScalar(win32.HWND, hwnds, target orelse return null);
}

/// `cursors` parallels `groups`; should_reset_on_leave clears the cursor of groups character_name isn't in.
pub fn syncGroupCycleIndex(groups: []const HotkeyGroupConfig, cursors: []?usize, character_name: []const u8, should_reset_on_leave: bool) void {
    for (groups, cursors) |*group, *cursor| {
        if (strings.indexOfString(group.characters.items, character_name)) |index| {
            if (cursor.* != index) {
                slog.debug("Updated hotkey group index: {s} now at position {}/{}", .{ character_name, index + 1, group.characters.items.len });
                cursor.* = index;
            }
        } else if (should_reset_on_leave and cursor.* != null) {
            slog.debug("Reset hotkey group cycle index - {s} left this group", .{character_name});
            cursor.* = null;
        }
    }
}

/// `position` must be below the chain's total member count.
fn chainMember(groups: []const HotkeyGroupConfig, group_indices: []const usize, position: usize) ChainMember {
    var remaining = position;
    for (group_indices) |group_index| {
        const member_count = groups[group_index].characters.items.len;
        if (remaining < member_count) return .{ .group_index = group_index, .index = remaining };
        remaining -= member_count;
    }
    unreachable;
}

/// Prefers the group whose cursor is on the focused character, then the last-cycled one, since a character can sit in several groups.
fn chainCursor(groups: []const HotkeyGroupConfig, group_indices: []const usize, cursors: []const ?usize, last_cycled_group: ?usize, focused_name: ?[]const u8) ?usize {
    var best: ?usize = null;
    var best_rank: u8 = 0;
    var offset: usize = 0;
    for (group_indices) |group_index| {
        const members = groups[group_index].characters.items;
        const start = offset;
        offset += members.len;

        const cursor = cursors[group_index] orelse continue;
        if (cursor >= members.len) continue;
        const is_focused = if (focused_name) |name| std.mem.eql(u8, members[cursor], name) else false;
        const is_last = last_cycled_group == group_index;
        const rank: u8 = 1 + 2 * @as(u8, @intFromBool(is_focused)) + @intFromBool(is_last);
        if (rank > best_rank) {
            best_rank = rank;
            best = start + cursor;
        }
    }
    return best;
}

/// Null for an excluded member or one with no running window.
fn memberHwnd(cycle: GroupCycle, member: ChainMember, clients: anytype) ?win32.HWND {
    const name = cycle.groups[member.group_index].characters.items[member.index];
    if (clients.isExcluded(name)) return null;
    return clients.hwndFor(name);
}

fn characterOrderSignature(configured: []const CharacterConfig) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    for (configured) |character| {
        hasher.update(character.name);
        // The map's keys borrow these names, so a reallocated but equal name (a discarded dialog preview) must rebuild it too.
        hasher.update(std.mem.asBytes(&character.name.ptr));
    }
    return hasher.final();
}

const testing = std.testing;

/// A stand-in client handle; never passed to Win32.
fn fakeHwnd(n: usize) win32.HWND {
    return @ptrFromInt(0x1000 + n * 0x10);
}

/// planGroupCycle's `clients`: each name in `running` has fakeHwnd(its index).
const FakeClients = struct {
    running: []const []const u8,
    excluded: []const []const u8 = &.{},

    fn hwndFor(self: FakeClients, name: []const u8) ?win32.HWND {
        return fakeHwnd(strings.indexOfString(self.running, name) orelse return null);
    }

    fn isExcluded(self: FakeClients, name: []const u8) bool {
        return strings.indexOfString(self.excluded, name) != null;
    }
};

fn testGroup(names: [][]const u8, options: struct { stops_at_ends: bool = false, includes_not_logged_in: bool = false }) HotkeyGroupConfig {
    return .{ .characters = .fromOwnedSlice(names), .stopAtEnds = options.stops_at_ends, .includeNotLoggedIn = options.includes_not_logged_in };
}

/// A cycle over every group in `groups`, with nothing focused and no not-logged-in clients unless the test sets them.
fn cycleOver(groups: []const HotkeyGroupConfig, group_indices: []const usize, cursors: []const ?usize) GroupCycle {
    return .{
        .groups = groups,
        .group_indices = group_indices,
        .chain = chainOf(groups, group_indices).chain,
        .cursors = cursors,
        .last_cycled_group = null,
        .not_logged_in_hwnds = &.{},
        .last_not_logged_in_hwnd = null,
        .foreground_hwnd = null,
        .focused_name = null,
        .is_forward = true,
    };
}

test "CycleOrder wraps from the last item to the first" {
    var order: CycleOrder = .init(1, 3, .{ .is_forward = true });
    try testing.expectEqual(2, order.next().?);
    try testing.expectEqual(0, order.next().?);
    try testing.expectEqual(1, order.next().?);
    try testing.expectEqual(null, order.next());
}

test "CycleOrder starts at the first item in its direction when the cursor is stale" {
    var forward: CycleOrder = .init(null, 3, .{ .is_forward = true });
    try testing.expectEqual(0, forward.next().?);
    var backward: CycleOrder = .init(7, 3, .{ .is_forward = false });
    try testing.expectEqual(2, backward.next().?);
}

test "CycleOrder without wrapping stops at either end" {
    var forward: CycleOrder = .init(1, 3, .{ .is_forward = true, .wraps = false });
    try testing.expectEqual(2, forward.next().?);
    try testing.expectEqual(null, forward.next());
    var backward: CycleOrder = .init(1, 3, .{ .is_forward = false, .wraps = false });
    try testing.expectEqual(0, backward.next().?);
    try testing.expectEqual(null, backward.next());
}

test "CycleOrder visits nothing in an empty list" {
    var order: CycleOrder = .init(null, 0, .{ .is_forward = true });
    try testing.expectEqual(null, order.next());
}

test "chainMember finds a position's group across groups sharing a key" {
    var first = [_][]const u8{ "A", "B" };
    var second = [_][]const u8{ "C", "D", "E" };
    const groups = [_]HotkeyGroupConfig{ testGroup(&first, .{}), testGroup(&second, .{}) };
    const member = chainMember(&groups, &.{ 0, 1 }, 3);
    try testing.expectEqual(1, member.group_index);
    try testing.expectEqual(1, member.index);
}

test "chainOf reports a group index past the end" {
    var names = [_][]const u8{"A"};
    const groups = [_]HotkeyGroupConfig{testGroup(&names, .{})};
    try testing.expectEqual(ChainCheck{ .invalid_group = 3 }, chainOf(&groups, &.{ 0, 3 }));
}

test "chainOf stops at the ends only when every group does" {
    var first = [_][]const u8{"A"};
    var second = [_][]const u8{"B"};
    const groups = [_]HotkeyGroupConfig{ testGroup(&first, .{ .stops_at_ends = true }), testGroup(&second, .{ .includes_not_logged_in = true }) };
    const chain = chainOf(&groups, &.{ 0, 1 }).chain;
    try testing.expect(!chain.stops_at_ends);
    try testing.expect(chain.includes_not_logged_in);
    try testing.expectEqual(2, chain.member_count);
}

test "chainCursor prefers the group whose cursor is on the focused character" {
    var first = [_][]const u8{ "A", "B" };
    var second = [_][]const u8{ "C", "B" };
    const groups = [_]HotkeyGroupConfig{ testGroup(&first, .{}), testGroup(&second, .{}) };
    const cursors = [_]?usize{ 0, 1 };
    try testing.expectEqual(3, chainCursor(&groups, &.{ 0, 1 }, &cursors, 0, "B").?);
    try testing.expectEqual(0, chainCursor(&groups, &.{ 0, 1 }, &cursors, 0, null).?);
}

test "syncGroupCycleIndex moves the cursors onto a focused member, and resets the rest only when asked" {
    var first = [_][]const u8{ "A", "B" };
    var second = [_][]const u8{"C"};
    const groups = [_]HotkeyGroupConfig{ testGroup(&first, .{}), testGroup(&second, .{}) };
    var cursors = [_]?usize{ null, 0 };
    syncGroupCycleIndex(&groups, &cursors, "B", false);
    try testing.expectEqual(1, cursors[0].?);
    try testing.expectEqual(0, cursors[1].?);
    syncGroupCycleIndex(&groups, &cursors, "B", true);
    try testing.expectEqual(null, cursors[1]);
}

test "orderedIndices puts configured characters first and keeps the rest in discovery order" {
    const configured = [_]CharacterConfig{ .{ .name = "Zed" }, .{ .name = "Amy" } };
    const windows = [_]scout.EveWindow{
        .{ .hwnd = fakeHwnd(0), .character_name = "Other", .process_id = 1, .is_eve_client = true },
        .{ .hwnd = fakeHwnd(1), .character_name = "Amy", .process_id = 2, .is_eve_client = true },
        .{ .hwnd = fakeHwnd(2), .character_name = "Extra", .process_id = 3, .is_eve_client = true },
        .{ .hwnd = fakeHwnd(3), .character_name = "Zed", .process_id = 4, .is_eve_client = true },
    };
    var cache: CharacterOrderCache = .{};
    defer cache.deinit();
    const order = try cache.orderedIndices(testing.allocator, &configured, &windows);
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(usize, &.{ 3, 1, 0, 2 }, order);
}

test "a group cycle skips excluded and closed characters" {
    var names = [_][]const u8{ "A", "B", "C", "D" };
    const groups = [_]HotkeyGroupConfig{testGroup(&names, .{})};
    const step = planGroupCycle(cycleOver(&groups, &.{0}, &.{0}), FakeClients{ .running = &.{ "A", "B", "D" }, .excluded = &.{"B"} });
    try testing.expectEqual(3, step.member.member.index);
    try testing.expectEqual(fakeHwnd(2), step.member.hwnd);
    try testing.expectEqual(3, step.member.position);
}

test "a group cycle wraps past the last member" {
    var names = [_][]const u8{ "A", "B" };
    const groups = [_]HotkeyGroupConfig{testGroup(&names, .{})};
    const step = planGroupCycle(cycleOver(&groups, &.{0}, &.{1}), FakeClients{ .running = &.{ "A", "B" } });
    try testing.expectEqual(0, step.member.member.index);
}

test "a group cycle backwards from no cursor starts at the last member" {
    var names = [_][]const u8{ "A", "B", "C" };
    const groups = [_]HotkeyGroupConfig{testGroup(&names, .{})};
    var cycle = cycleOver(&groups, &.{0}, &.{null});
    cycle.is_forward = false;
    const step = planGroupCycle(cycle, FakeClients{ .running = &.{ "A", "B", "C" } });
    try testing.expectEqual(2, step.member.member.index);
}

test "a stop-at-ends group refocuses its end member once focus has moved away" {
    var names = [_][]const u8{ "A", "B" };
    const groups = [_]HotkeyGroupConfig{testGroup(&names, .{ .stops_at_ends = true })};
    const clients = FakeClients{ .running = &.{ "A", "B" } };

    var cycle = cycleOver(&groups, &.{0}, &.{1});
    cycle.foreground_hwnd = fakeHwnd(9);
    const away = planGroupCycle(cycle, clients);
    try testing.expectEqual(fakeHwnd(1), away.refocus_end.hwnd);

    cycle.foreground_hwnd = fakeHwnd(1);
    try testing.expectEqual(GroupStep.at_end, planGroupCycle(cycle, clients));
}

test "groups sharing a key cycle through each other as one chain" {
    var first = [_][]const u8{ "A", "B" };
    var second = [_][]const u8{"C"};
    const groups = [_]HotkeyGroupConfig{ testGroup(&first, .{}), testGroup(&second, .{}) };
    const step = planGroupCycle(cycleOver(&groups, &.{ 0, 1 }, &.{ 1, null }), FakeClients{ .running = &.{ "A", "B", "C" } });
    try testing.expectEqual(1, step.member.member.group_index);
    try testing.expectEqual(0, step.member.member.index);
    try testing.expectEqual(3, step.member.total_count);
}

test "the not-logged-in tail follows the members, from the focused login window" {
    var names = [_][]const u8{"A"};
    const groups = [_]HotkeyGroupConfig{testGroup(&names, .{ .includes_not_logged_in = true })};
    const login_windows = [_]win32.HWND{ fakeHwnd(7), fakeHwnd(8) };
    var cycle = cycleOver(&groups, &.{0}, &.{0});
    cycle.not_logged_in_hwnds = &login_windows;
    cycle.foreground_hwnd = fakeHwnd(7);
    const step = planGroupCycle(cycle, FakeClients{ .running = &.{"A"} });
    try testing.expectEqual(fakeHwnd(8), step.not_logged_in.hwnd);
    try testing.expectEqual(2, step.not_logged_in.position);
}

test "a group cycle with no one in it is empty, and with no one running finds nothing" {
    const empty_groups = [_]HotkeyGroupConfig{.{}};
    try testing.expectEqual(GroupStep.empty, planGroupCycle(cycleOver(&empty_groups, &.{0}, &.{null}), FakeClients{ .running = &.{} }));

    var names = [_][]const u8{ "A", "B" };
    const groups = [_]HotkeyGroupConfig{testGroup(&names, .{})};
    try testing.expectEqual(GroupStep.none, planGroupCycle(cycleOver(&groups, &.{0}, &.{0}), FakeClients{ .running = &.{"Z"} }));
}
