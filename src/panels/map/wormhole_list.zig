//! The Thera and Turnur card's list: one hub's connections by region and system, and its scrolling; no I/O.
const std = @import("std");
const universe = @import("../../map/universe.zig");
const wormholes = @import("../../map/wormholes.zig");

const Connections = wormholes.Connections;
const Hub = wormholes.Hub;
const SystemIndex = universe.SystemIndex;

pub const MAX_ENTRIES = wormholes.MAX_CONNECTIONS;
/// Rows a wheel notch scrolls.
const SCROLL_STEP = 3;

pub const Entry = struct {
    /// Its place in the Connections it was built from.
    index: u16,
    system: SystemIndex,
};

/// `hub`'s connections; `buffer` holds what's returned.
pub fn build(connections: *const Connections, hub: Hub, buffer: *[MAX_ENTRIES]Entry) []const Entry {
    var count: usize = 0;
    for (connections.slice(), 0..) |connection, index| {
        if (connection.hub != hub) continue;
        buffer[count] = .{ .index = @intCast(index), .system = connection.system };
        count += 1;
    }
    std.mem.sort(Entry, buffer[0..count], {}, comesFirst);
    return buffer[0..count];
}

/// The furthest the list scrolls with `visible_count` rows showing.
pub fn maxScroll(entry_count: usize, visible_count: usize) usize {
    return entry_count -| visible_count;
}

/// `scroll` moved by `notches`, up for positive, kept inside the list.
pub fn scrolled(scroll: usize, notches: i32, entry_count: usize, visible_count: usize) usize {
    const step: i64 = @as(i64, notches) * SCROLL_STEP;
    const moved = @as(i64, @intCast(scroll)) - step;
    return @intCast(std.math.clamp(moved, 0, @as(i64, @intCast(maxScroll(entry_count, visible_count)))));
}

/// By region name, then system name.
fn comesFirst(_: void, first: Entry, second: Entry) bool {
    const order = std.mem.order(u8, universe.regionName(universe.systemInfo(first.system).region), universe.regionName(universe.systemInfo(second.system).region));
    if (order != .eq) return order == .lt;
    return std.mem.lessThan(u8, universe.systemName(first.system), universe.systemName(second.system));
}

const testing = std.testing;

test "build lists one hub's connections, sorted by region then system" {
    var connections: Connections = .{};
    try connections.add(testing.allocator, "[{\"in_system_id\":30002187},{\"in_system_id\":30000144},{\"in_system_id\":30000142}]", .thera);
    try connections.add(testing.allocator, "[{\"in_system_id\":30002187}]", .turnur);
    var buffer: [MAX_ENTRIES]Entry = undefined;
    const entries = build(&connections, .thera, &buffer);
    try testing.expectEqual(@as(usize, 3), entries.len);
    // Domain's Amarr, then The Forge's Jita and Perimeter.
    try testing.expectEqualStrings("Amarr", universe.systemName(entries[0].system));
    try testing.expectEqualStrings("Jita", universe.systemName(entries[1].system));
    try testing.expectEqualStrings("Perimeter", universe.systemName(entries[2].system));
    try testing.expectEqual(@as(u16, 1), entries[2].index);
    try testing.expectEqual(@as(usize, 1), build(&connections, .turnur, &buffer).len);
}

test "scrolling stays inside the list" {
    try testing.expectEqual(@as(usize, 3), scrolled(0, -1, 20, 10));
    try testing.expectEqual(@as(usize, 10), scrolled(9, -1, 20, 10));
    try testing.expectEqual(@as(usize, 0), scrolled(2, 1, 20, 10));
    try testing.expectEqual(@as(usize, 0), scrolled(0, -1, 5, 10));
}
