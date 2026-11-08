//! Finds systems and regions by name in the embedded map; no I/O.
const std = @import("std");
const universe = @import("universe.zig");

const RegionIndex = universe.RegionIndex;
const SystemIndex = universe.SystemIndex;

pub const MAX_HITS = 8;
pub const MAX_QUERY_LENGTH = 32;
/// Fits the longest name; a test holds the map to it.
const MAX_NAME_LENGTH = 32;
/// The likeliest of the systems sharing a start, whatever the alphabet says.
const TRADE_HUBS = [_][]const u8{ "Jita", "Amarr", "Dodixie", "Rens", "Hek" };

pub const Hit = union(enum) { system: SystemIndex, region: RegionIndex };

const Match = enum { hub, starts_with, contains };

/// Best first.
pub const Hits = struct {
    items: [MAX_HITS]Hit = undefined,
    count: usize = 0,

    pub fn slice(self: *const Hits) []const Hit {
        return self.items[0..self.count];
    }

    fn add(self: *Hits, hit: Hit) void {
        if (self.count == MAX_HITS) return;
        self.items[self.count] = hit;
        self.count += 1;
    }

    fn addRegions(self: *Hits, key: []const u8, match: Match) void {
        for (0..universe.REGION_COUNT) |index| {
            const region: RegionIndex = @intCast(index);
            if (matches(universe.regionName(region), key, match)) self.add(.{ .region = region });
        }
    }

    fn addSystems(self: *Hits, key: []const u8, match: Match) void {
        for (0..universe.SYSTEM_COUNT) |index| {
            if (self.count == MAX_HITS) return;
            const system: SystemIndex = @intCast(index);
            if (matches(universe.systemName(system), key, match)) self.add(.{ .system = system });
        }
    }
};

/// Names starting with `query` come before those only containing it, regions before systems, and trade hubs before other systems; ignores case and hyphens.
pub fn find(query: []const u8) Hits {
    var hits: Hits = .{};
    var key_buffer: [MAX_QUERY_LENGTH]u8 = undefined;
    const key = searchKey(&key_buffer, std.mem.trim(u8, query, " "));
    if (key.len == 0) return hits;
    hits.addRegions(key, .starts_with);
    hits.addSystems(key, .hub);
    hits.addSystems(key, .starts_with);
    hits.addRegions(key, .contains);
    hits.addSystems(key, .contains);
    return hits;
}

/// Each kind skips what the kinds before it already took; `key` is the query's searchKey.
fn matches(name: []const u8, key: []const u8, match: Match) bool {
    var name_buffer: [MAX_NAME_LENGTH]u8 = undefined;
    const name_key = searchKey(&name_buffer, name);
    return switch (match) {
        .hub => isTradeHub(name) and std.ascii.startsWithIgnoreCase(name_key, key),
        .starts_with => !isTradeHub(name) and std.ascii.startsWithIgnoreCase(name_key, key),
        .contains => !std.ascii.startsWithIgnoreCase(name_key, key) and containsIgnoringCase(name_key, key),
    };
}

/// `text` without its hyphens, so "cj6" finds C-J6MT; cut short at `buffer`'s size, and `buffer` holds what's returned.
fn searchKey(buffer: []u8, text: []const u8) []const u8 {
    var length: usize = 0;
    for (text) |char| {
        if (char == '-') continue;
        if (length == buffer.len) break;
        buffer[length] = char;
        length += 1;
    }
    return buffer[0..length];
}

fn isTradeHub(name: []const u8) bool {
    for (TRADE_HUBS) |hub| {
        if (std.mem.eql(u8, name, hub)) return true;
    }
    return false;
}

fn containsIgnoringCase(name: []const u8, query: []const u8) bool {
    if (query.len > name.len) return false;
    for (0..name.len - query.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(name[start..][0..query.len], query)) return true;
    }
    return false;
}

const testing = std.testing;

test "a system is found by the start of its name, whatever the case" {
    const hits = find("jit");
    try testing.expectEqual(@as(usize, 1), hits.count);
    try testing.expectEqualStrings("Jita", universe.systemName(hits.slice()[0].system));
}

test "a region comes before systems sharing its start" {
    const hits = find("the f");
    try testing.expectEqualStrings("The Forge", universe.regionName(hits.slice()[0].region));
}

test "names starting with the query come before those containing it" {
    const hits = find("amarr");
    try testing.expectEqualStrings("Amarr", universe.systemName(hits.slice()[0].system));
}

test "a trade hub comes first among systems sharing its start, and only once" {
    const hits = find("ji");
    try testing.expectEqualStrings("Jita", universe.systemName(hits.slice()[0].system));
    try testing.expectEqualStrings("JI-1UQ", universe.systemName(hits.slice()[1].system));
    for (hits.slice()[1..]) |hit| try testing.expect(!std.mem.eql(u8, universe.systemName(hit.system), "Jita"));
}

test "every trade hub is a real system" {
    for (TRADE_HUBS) |hub| try testing.expect(universe.findSystem(hub) != null);
}

test "a system is found by the middle of its name" {
    const hits = find("j6mt");
    try testing.expectEqual(@as(usize, 1), hits.count);
    try testing.expectEqualStrings("C-J6MT", universe.systemName(hits.slice()[0].system));
}

test "a broad query stops at the list's size, and no hit appears twice" {
    const hits = find("a");
    try testing.expectEqual(@as(usize, MAX_HITS), hits.count);
    for (hits.slice(), 0..) |hit, index| {
        for (hits.slice()[index + 1 ..]) |other| try testing.expect(!std.meta.eql(hit, other));
    }
}

test "a name's hyphens can be left out of the query, or typed" {
    const hits = find("cj6");
    try testing.expectEqualStrings("C-J6MT", universe.systemName(hits.slice()[0].system));
    const typed = find("c-j6");
    try testing.expectEqualStrings("C-J6MT", universe.systemName(typed.slice()[0].system));
}

test "every name fits the key buffer" {
    for (0..universe.SYSTEM_COUNT) |index| try testing.expect(universe.systemName(@intCast(index)).len <= MAX_NAME_LENGTH);
    for (0..universe.REGION_COUNT) |index| try testing.expect(universe.regionName(@intCast(index)).len <= MAX_NAME_LENGTH);
}

test "blank and unknown queries find nothing" {
    try testing.expectEqual(@as(usize, 0), find("").count);
    try testing.expectEqual(@as(usize, 0), find("   ").count);
    try testing.expectEqual(@as(usize, 0), find("-").count);
    try testing.expectEqual(@as(usize, 0), find("not a place").count);
}
