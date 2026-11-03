//! Finds systems and regions by name in the embedded map; no I/O.
const std = @import("std");
const universe = @import("universe.zig");

const RegionIndex = universe.RegionIndex;
const SystemIndex = universe.SystemIndex;

pub const MAX_HITS = 8;
pub const MAX_QUERY_LENGTH = 32;
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

    fn addRegions(self: *Hits, query: []const u8, match: Match) void {
        for (0..universe.REGION_COUNT) |index| {
            const region: RegionIndex = @intCast(index);
            if (matches(universe.regionName(region), query, match)) self.add(.{ .region = region });
        }
    }

    fn addSystems(self: *Hits, query: []const u8, match: Match) void {
        for (0..universe.SYSTEM_COUNT) |index| {
            if (self.count == MAX_HITS) return;
            const system: SystemIndex = @intCast(index);
            if (matches(universe.systemName(system), query, match)) self.add(.{ .system = system });
        }
    }
};

/// Names starting with `query` come before those only containing it, regions before systems, and trade hubs before other systems; ignores case.
pub fn find(query: []const u8) Hits {
    var hits: Hits = .{};
    const trimmed = std.mem.trim(u8, query, " ");
    if (trimmed.len == 0) return hits;
    hits.addRegions(trimmed, .starts_with);
    hits.addSystems(trimmed, .hub);
    hits.addSystems(trimmed, .starts_with);
    hits.addRegions(trimmed, .contains);
    hits.addSystems(trimmed, .contains);
    return hits;
}

/// Each kind skips what the kinds before it already took.
fn matches(name: []const u8, query: []const u8, match: Match) bool {
    return switch (match) {
        .hub => isTradeHub(name) and std.ascii.startsWithIgnoreCase(name, query),
        .starts_with => !isTradeHub(name) and std.ascii.startsWithIgnoreCase(name, query),
        .contains => !std.ascii.startsWithIgnoreCase(name, query) and containsIgnoringCase(name, query),
    };
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

test "blank and unknown queries find nothing" {
    try testing.expectEqual(@as(usize, 0), find("").count);
    try testing.expectEqual(@as(usize, 0), find("   ").count);
    try testing.expectEqual(@as(usize, 0), find("not a place").count);
}
