//! The stargate map of New Eden, built from CCP's static data by .claude/tools/build_universe.py; no I/O.
const std = @import("std");

/// Layout in the script's docstring; embedded, so it needs no parsing or allocation.
const DATA = @embedFile("universe.bin");
const HEADER_SIZE = 14;
const SYSTEM_RECORD_SIZE = 14;
const LINK_COUNT: usize = readNumber(6);
const CONSTELLATION_COUNT: usize = readNumber(10);
const NAME_OFFSETS = HEADER_SIZE;
const LINK_OFFSETS = NAME_OFFSETS + (SYSTEM_COUNT + 1) * 2;
const LINKS = LINK_OFFSETS + (SYSTEM_COUNT + 1) * 2;
const BY_ID = LINKS + LINK_COUNT * 2;
const REGION_NAME_OFFSETS = BY_ID + SYSTEM_COUNT * 2;
const CONSTELLATION_NAME_OFFSETS = REGION_NAME_OFFSETS + (REGION_COUNT + 1) * 2;
const REGION_IDS = CONSTELLATION_NAME_OFFSETS + (CONSTELLATION_COUNT + 1) * 2;
const SYSTEMS = REGION_IDS + REGION_COUNT * 4;
const NAMES = SYSTEMS + SYSTEM_COUNT * SYSTEM_RECORD_SIZE;

pub const SYSTEM_COUNT: usize = readNumber(4);
/// Regions with gates, as wormhole space has none.
pub const REGION_COUNT: usize = readNumber(8);
pub const MAX_REGION_SYSTEMS: usize = readNumber(12);
/// In Distances: further than the search went, or not linked by gates at all (Pochven, unreachable pockets).
pub const UNREACHED: u8 = 0xFF;

/// Into the sorted names; wormhole systems have no gates, so they aren't here.
pub const SystemIndex = u16;
/// Into the regions, sorted by name.
pub const RegionIndex = u8;
/// Jumps from one system to each other, by SystemIndex.
pub const Distances = [SYSTEM_COUNT]u8;

pub const SystemInfo = struct {
    /// CCP's, as ESI names systems.
    id: u32,
    /// On CCP's flattened map, where regions keep their places in New Eden; grows rightwards.
    x: i16,
    /// On CCP's flattened map; grows down the screen.
    y: i16,
    constellation: u16,
    region: RegionIndex,
    /// As the game shows it: 5 reads 0.5, and anything at or below 0 is null security.
    security_tenths: i8,
    station_count: u8,
    planet_count: u8,
};

/// A system's gate neighbours.
pub const Neighbours = struct {
    next_link: usize,
    end: usize,

    pub fn next(self: *Neighbours) ?SystemIndex {
        if (self.next_link == self.end) return null;
        defer self.next_link += 1;
        return readNumber(LINKS + self.next_link * 2);
    }
};

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

/// By CCP's ID, as ESI gives it; null for what has no gates.
pub fn findSystemById(id: u32) ?SystemIndex {
    var low: usize = 0;
    var high: usize = SYSTEM_COUNT;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const system: SystemIndex = readNumber(BY_ID + middle * 2);
        switch (std.math.order(systemInfo(system).id, id)) {
            .eq => return system,
            .lt => low = middle + 1,
            .gt => high = middle,
        }
    }
    return null;
}

/// By CCP's ID, which unlike a RegionIndex outlives a map update; searched linearly, as there are only a few dozen.
pub fn findRegionById(id: u32) ?RegionIndex {
    for (0..REGION_COUNT) |index| {
        const region: RegionIndex = @intCast(index);
        if (regionId(region) == id) return region;
    }
    return null;
}

/// Borrows from the embedded map, so it lasts as long as the app.
pub fn systemName(system: SystemIndex) []const u8 {
    return nameAt(NAME_OFFSETS + @as(usize, system) * 2);
}

/// Borrows from the embedded map, so it lasts as long as the app.
pub fn regionName(region: RegionIndex) []const u8 {
    return nameAt(REGION_NAME_OFFSETS + @as(usize, region) * 2);
}

/// Borrows from the embedded map, so it lasts as long as the app.
pub fn constellationName(constellation: u16) []const u8 {
    return nameAt(CONSTELLATION_NAME_OFFSETS + @as(usize, constellation) * 2);
}

pub fn regionId(region: RegionIndex) u32 {
    return std.mem.readInt(u32, DATA[REGION_IDS + @as(usize, region) * 4 ..][0..4], .little);
}

pub fn systemInfo(system: SystemIndex) SystemInfo {
    const record = DATA[SYSTEMS + @as(usize, system) * SYSTEM_RECORD_SIZE ..][0..SYSTEM_RECORD_SIZE];
    return .{
        .id = std.mem.readInt(u32, record[0..4], .little),
        .x = std.mem.readInt(i16, record[4..6], .little),
        .y = std.mem.readInt(i16, record[6..8], .little),
        .constellation = std.mem.readInt(u16, record[8..10], .little),
        .region = record[10],
        .security_tenths = @bitCast(record[11]),
        .station_count = record[12],
        .planet_count = record[13],
    };
}

pub fn neighbours(system: SystemIndex) Neighbours {
    return .{
        .next_link = readNumber(LINK_OFFSETS + @as(usize, system) * 2),
        .end = readNumber(LINK_OFFSETS + (@as(usize, system) + 1) * 2),
    };
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
        var links = neighbours(system);
        while (links.next()) |neighbour| {
            if (distances[neighbour] != UNREACHED) continue;
            distances[neighbour] = jumps + 1;
            queue[tail] = neighbour;
            tail += 1;
        }
    }
}

/// `offset_position` holds a name's start offset, and the next number its end.
fn nameAt(offset_position: usize) []const u8 {
    const start: usize = readNumber(offset_position);
    const end: usize = readNumber(offset_position + 2);
    return DATA[NAMES + start .. NAMES + end];
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

test "findSystemById reverses every system's id, and misses wormhole systems" {
    for (0..SYSTEM_COUNT) |index| {
        const system: SystemIndex = @intCast(index);
        try testing.expectEqual(system, findSystemById(systemInfo(system).id).?);
    }
    try testing.expectEqual(findSystem("Jita").?, findSystemById(30000142).?);
    try testing.expect(findSystemById(31000005) == null);
}

test "a system's record reads its region, constellation and security" {
    const jita = systemInfo(findSystem("Jita").?);
    try testing.expectEqualStrings("The Forge", regionName(jita.region));
    try testing.expectEqualStrings("Kimotoro", constellationName(jita.constellation));
    try testing.expectEqual(@as(i8, 9), jita.security_tenths);
    try testing.expect(jita.station_count > 0);
    try testing.expect(systemInfo(findSystem("C-J6MT").?).security_tenths < 0);
    try testing.expect(jita.x != 0 or jita.y != 0);
}

test "neighbours lists a system's gates" {
    var links = neighbours(findSystem("Jita").?);
    var has_perimeter = false;
    while (links.next()) |neighbour| {
        if (std.mem.eql(u8, systemName(neighbour), "Perimeter")) has_perimeter = true;
    }
    try testing.expect(has_perimeter);
}

test "regions are sorted by name and found by their saved id" {
    for (1..REGION_COUNT) |index| {
        const region: RegionIndex = @intCast(index);
        try testing.expect(std.ascii.orderIgnoreCase(regionName(region - 1), regionName(region)) == .lt);
    }
    const forge = findRegionById(10000002).?;
    try testing.expectEqualStrings("The Forge", regionName(forge));
    try testing.expect(findRegionById(1) == null);
}

test "measureDistances stops at max_jumps" {
    var distances: Distances = undefined;
    const jita = findSystem("Jita").?;
    measureDistances(jita, 1, &distances);
    try testing.expectEqual(@as(u8, 0), distances[jita]);
    try testing.expectEqual(@as(u8, 1), distances[findSystem("Perimeter").?]);
    try testing.expectEqual(UNREACHED, distances[findSystem("Amarr").?]);
}
