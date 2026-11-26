//! Which system a travelling group is in, and who it has left behind; no I/O.
const std = @import("std");
const activity = @import("../config/activity.zig");

const TravelConfig = activity.TravelConfig;

/// One client's jumps, which the roster records and travel/left_behind.zig reads.
pub const LeftBehindState = struct {
    /// When it last jumped, in ms on the caller's clock; 0 when it hasn't this session.
    last_jump_ms: u64 = 0,
    /// Guards the left-behind alert to one per episode; cleared on jump.
    alert_fired: bool = false,

    pub fn recordJump(self: *LeftBehindState, now_ms: u64) void {
        self.last_jump_ms = now_ms;
        self.alert_fired = false;
    }
};

pub const Traveler = struct {
    /// Borrows from the caller.
    system_name: []const u8,
    /// When it last jumped, in ms on the caller's clock; 0 when it hasn't this session.
    last_jump_ms: u64,
    /// Excluded from cycling, which marks it as off on its own: it neither counts toward the group nor gets the alert.
    is_excluded: bool,
};

/// Where most tracked travelers are, once enough have been there for window_seconds; borrows from `travelers`.
pub fn groupSystem(travel: *const TravelConfig, travelers: []const Traveler, now_ms: u64) ?[]const u8 {
    var eligible_count: usize = 0;
    for (travelers) |traveler| {
        if (isTracked(traveler)) eligible_count += 1;
    }
    if (eligible_count < 2) return null;

    var group_system: []const u8 = "";
    var group_count: usize = 0;
    var group_arrival_ms: u64 = 0;
    for (travelers) |candidate| {
        if (!isTracked(candidate)) continue;
        var same_system_count: usize = 0;
        var arrival_ms: u64 = 0;
        for (travelers) |other| {
            if (!isTracked(other) or !std.mem.eql(u8, other.system_name, candidate.system_name)) continue;
            same_system_count += 1;
            arrival_ms = @max(arrival_ms, other.last_jump_ms);
        }
        if (same_system_count > group_count) {
            group_count = same_system_count;
            group_system = candidate.system_name;
            group_arrival_ms = arrival_ms;
        }
    }

    if (group_count < requiredCount(travel, eligible_count)) return null;
    if (now_ms -| group_arrival_ms < @as(u64, travel.window_seconds) * std.time.ms_per_s) return null;
    return group_system;
}

pub fn isLeftBehind(traveler: Traveler, group_system: []const u8) bool {
    return isTracked(traveler) and !std.mem.eql(u8, traveler.system_name, group_system);
}

/// Counts toward the group, and can be left behind by it.
fn isTracked(traveler: Traveler) bool {
    return traveler.last_jump_ms != 0 and !traveler.is_excluded;
}

/// How many of the `eligible_count` tracked travelers must share a system for it to count as the group's.
fn requiredCount(travel: *const TravelConfig, eligible_count: usize) usize {
    return switch (travel.threshold_mode) {
        .percent => @intFromFloat(@ceil(travel.threshold_percent / 100.0 * @as(f32, @floatFromInt(eligible_count)))),
        .count => travel.threshold_count,
    };
}

const testing = std.testing;

const NOW_MS: u64 = 1_000_000;
const SETTLED_MS: u64 = NOW_MS - 60_000;

fn arrived(system_name: []const u8, last_jump_ms: u64) Traveler {
    return .{ .system_name = system_name, .last_jump_ms = last_jump_ms, .is_excluded = false };
}

test "with fewer than two tracked travelers there's no group" {
    const travel: TravelConfig = .{};
    const travelers = [_]Traveler{ arrived("Jita", SETTLED_MS), arrived("Perimeter", 0) };
    try testing.expectEqual(null, groupSystem(&travel, &travelers, NOW_MS));
}

test "the system most travelers are in is the group's once they've been there for the window" {
    const travel: TravelConfig = .{ .window_seconds = 30 };
    const travelers = [_]Traveler{ arrived("Jita", SETTLED_MS), arrived("Jita", SETTLED_MS), arrived("Perimeter", SETTLED_MS) };
    try testing.expectEqualStrings("Jita", groupSystem(&travel, &travelers, NOW_MS).?);
    try testing.expect(isLeftBehind(travelers[2], "Jita"));
    try testing.expect(!isLeftBehind(travelers[0], "Jita"));
}

test "the window counts from the group's latest arrival" {
    const travel: TravelConfig = .{ .window_seconds = 30 };
    const travelers = [_]Traveler{ arrived("Jita", SETTLED_MS), arrived("Jita", NOW_MS - 29_999), arrived("Perimeter", SETTLED_MS) };
    try testing.expectEqual(null, groupSystem(&travel, &travelers, NOW_MS));
    try testing.expect(groupSystem(&travel, &travelers, NOW_MS + 1) != null);
}

test "the percent threshold is a share of every tracked traveler, rounded up" {
    const travelers = [_]Traveler{ arrived("Jita", SETTLED_MS), arrived("Jita", SETTLED_MS), arrived("Perimeter", SETTLED_MS), arrived("Amarr", SETTLED_MS) };
    const half: TravelConfig = .{ .threshold_mode = .percent, .threshold_percent = 50.0 };
    const most: TravelConfig = .{ .threshold_mode = .percent, .threshold_percent = 51.0 };
    try testing.expectEqualStrings("Jita", groupSystem(&half, &travelers, NOW_MS).?);
    try testing.expectEqual(null, groupSystem(&most, &travelers, NOW_MS));
}

test "the count threshold needs that many travelers in one system" {
    const travelers = [_]Traveler{ arrived("Jita", SETTLED_MS), arrived("Jita", SETTLED_MS), arrived("Perimeter", SETTLED_MS) };
    const two: TravelConfig = .{ .threshold_mode = .count, .threshold_count = 2 };
    const three: TravelConfig = .{ .threshold_mode = .count, .threshold_count = 3 };
    try testing.expectEqualStrings("Jita", groupSystem(&two, &travelers, NOW_MS).?);
    try testing.expectEqual(null, groupSystem(&three, &travelers, NOW_MS));
}

test "excluded travelers and ones that haven't jumped neither count nor get left behind" {
    var excluded = arrived("Perimeter", SETTLED_MS);
    excluded.is_excluded = true;
    const travelers = [_]Traveler{ arrived("Jita", SETTLED_MS), arrived("Jita", SETTLED_MS), excluded, excluded, excluded, arrived("Amarr", 0) };
    const travel: TravelConfig = .{ .threshold_mode = .percent, .threshold_percent = 100.0 };
    try testing.expectEqualStrings("Jita", groupSystem(&travel, &travelers, NOW_MS).?);
    try testing.expect(!isLeftBehind(excluded, "Jita"));
    try testing.expect(!isLeftBehind(travelers[5], "Jita"));
}
