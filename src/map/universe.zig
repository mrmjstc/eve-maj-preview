//! The stargate map of New Eden, built from CCP's static data by .claude/tools/build_universe.py; no I/O.
const std = @import("std");

/// Layout in the script's docstring; embedded, so it needs no parsing or allocation.
const DATA = @embedFile("universe.bin");
const HEADER_SIZE = 8;
const LINK_COUNT: usize = readNumber(6);
const NAME_OFFSETS = HEADER_SIZE;
const LINK_OFFSETS = NAME_OFFSETS + (SYSTEM_COUNT + 1) * 2;
const LINKS = LINK_OFFSETS + (SYSTEM_COUNT + 1) * 2;
const NAMES = LINKS + LINK_COUNT * 2;

pub const SYSTEM_COUNT: usize = readNumber(4);
/// In Distances: further than the search went, or not linked by gates at all (Pochven, unreachable pockets).
pub const UNREACHED: u8 = 0xFF;

/// Into the sorted names; wormhole systems have no gates, so they aren't here.
pub const SystemIndex = u16;
/// Jumps from one system to each other, by SystemIndex.
pub const Distances = [SYSTEM_COUNT]u8;

comptime {
    std.debug.assert(std.mem.eql(u8, DATA[0..4], "EVEU"));
}

/// Ignores case.
pub fn findSystem(name: []const u8) ?SystemIndex {
    var low: usize = 0;
    var high: usize = SYSTEM_COUNT;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const system: SystemIndex = @intCast(middle);
        switch (std.ascii.orderIgnoreCase(systemName(system), name)) {
            .eq => return system,
            .lt => low = middle + 1,
            .gt => high = middle,
        }
    }
    return null;
}

/// Borrows from the embedded map, so it lasts as long as the app.
pub fn systemName(system: SystemIndex) []const u8 {
    const start: usize = readNumber(NAME_OFFSETS + @as(usize, system) * 2);
    const end: usize = readNumber(NAME_OFFSETS + (@as(usize, system) + 1) * 2);
    return DATA[NAMES + start .. NAMES + end];
}

/// `max_jumps` must be below UNREACHED.
pub fn measureDistances(start: SystemIndex, max_jumps: u8, distances: *Distances) void {
    @memset(distances, UNREACHED);
    var queue: [SYSTEM_COUNT]SystemIndex = undefined;
    distances[start] = 0;
    queue[0] = start;
    var head: usize = 0;
    var tail: usize = 1;
    while (head < tail) : (head += 1) {
        const system = queue[head];
        const jumps = distances[system];
        if (jumps >= max_jumps) break;
        const first: usize = readNumber(LINK_OFFSETS + @as(usize, system) * 2);
        const end: usize = readNumber(LINK_OFFSETS + (@as(usize, system) + 1) * 2);
        for (first..end) |link| {
            const neighbour = readNumber(LINKS + link * 2);
            if (distances[neighbour] != UNREACHED) continue;
            distances[neighbour] = jumps + 1;
            queue[tail] = neighbour;
            tail += 1;
        }
    }
}

fn readNumber(position: usize) u16 {
    return std.mem.readInt(u16, DATA[position..][0..2], .little);
}

const testing = std.testing;

fn jumpsBetween(from: []const u8, to: []const u8) !u8 {
    var distances: Distances = undefined;
    measureDistances(findSystem(from) orelse return error.TestExpectedSystem, UNREACHED - 1, &distances);
    return distances[findSystem(to) orelse return error.TestExpectedSystem];
}

test "findSystem ignores case and misses what isn't a gated system" {
    try testing.expectEqualStrings("C-J6MT", systemName(findSystem("c-j6mt").?));
    try testing.expectEqualStrings("Old Man Star", systemName(findSystem("OLD MAN STAR").?));
    try testing.expect(findSystem("Not A System") == null);
    try testing.expect(findSystem("") == null);
}

test "every system's name finds that system" {
    for (0..SYSTEM_COUNT) |index| {
        const system: SystemIndex = @intCast(index);
        try testing.expectEqual(system, findSystem(systemName(system)).?);
    }
}

test "distances match ESI's shortest routes" {
    try testing.expectEqual(@as(u8, 11), try jumpsBetween("Jita", "Amarr"));
    try testing.expectEqual(@as(u8, 26), try jumpsBetween("Jita", "C-J6MT"));
    try testing.expectEqual(@as(u8, 33), try jumpsBetween("Amarr", "1DQ1-A"));
    try testing.expectEqual(@as(u8, 8), try jumpsBetween("Dodixie", "Tama"));
    try testing.expectEqual(@as(u8, 0), try jumpsBetween("Jita", "Jita"));
}

test "measureDistances stops at max_jumps" {
    var distances: Distances = undefined;
    const jita = findSystem("Jita").?;
    measureDistances(jita, 1, &distances);
    try testing.expectEqual(@as(u8, 0), distances[jita]);
    try testing.expectEqual(@as(u8, 1), distances[findSystem("Perimeter").?]);
    try testing.expectEqual(UNREACHED, distances[findSystem("Amarr").?]);
}
