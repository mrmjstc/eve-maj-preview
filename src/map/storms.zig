//! Metaliminal storms: where each is centred and which systems it covers, parsed from EVE-Scout's reports; no I/O.
const std = @import("std");
const universe = @import("universe.zig");
const log = @import("../log.zig");

const SystemIndex = universe.SystemIndex;
const SystemSet = universe.SystemSet;
const slog = log.Scoped("map");

/// The game always has this many, two of each kind.
pub const MAX_STORMS = 8;
/// A storm's strongest effects reach this far from its centre.
const CORE_JUMPS = 1;
/// A storm's weaker effects reach this far from its centre.
const PERIPHERY_JUMPS = 3;
/// In a report; EVE-Scout logs other oddities in the same list.
const STORM_CATEGORY = "storm";

pub const Kind = enum { electric, exotic, gamma, plasma };
pub const Zone = enum { center, core, periphery };

/// A gate inside a storm.
pub const EdgeMark = struct { kind: Kind, is_core: bool };

const Row = struct { observation_category: []const u8, observation_type: []const u8, system_id: u32, hours_in_system: u32 = 0 };

pub const Storm = struct {
    center: SystemIndex,
    kind: Kind,
    /// Since it was last reported moving, as of the fetch.
    hours_in_system: u32,
    /// By SystemIndex, the centre included.
    core: SystemSet = .empty,
    /// By SystemIndex, all it covers, the core included.
    covered: SystemSet = .empty,

    fn init(center: SystemIndex, kind: Kind, hours_in_system: u32) Storm {
        var storm: Storm = .{ .center = center, .kind = kind, .hours_in_system = hours_in_system };
        var distances: universe.Distances = undefined;
        universe.measureDistances(center, PERIPHERY_JUMPS, &distances);
        for (distances, 0..) |jumps, index| {
            if (jumps == universe.UNREACHED) continue;
            storm.covered.set(index);
            if (jumps <= CORE_JUMPS) storm.core.set(index);
        }
        return storm;
    }

    /// Null outside the storm.
    pub fn zoneOf(self: *const Storm, system: SystemIndex) ?Zone {
        if (system == self.center) return .center;
        if (self.core.isSet(system)) return .core;
        return if (self.covered.isSet(system)) .periphery else null;
    }
};

pub const Storms = struct {
    storms: [MAX_STORMS]Storm = undefined,
    count: usize = 0,

    /// `body` is EVE-Scout's observations reply; storms centred somewhere with no gates are skipped.
    pub fn parse(allocator: std.mem.Allocator, body: []const u8) !Storms {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const rows = try std.json.parseFromSliceLeaky([]const Row, arena.allocator(), body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });

        var parsed: Storms = .{};
        for (rows) |row| {
            if (!std.mem.eql(u8, row.observation_category, STORM_CATEGORY) or parsed.count == MAX_STORMS) continue;
            const kind = kindOf(row.observation_type) orelse {
                slog.warn("Failed to read a storm of type '{s}'", .{row.observation_type});
                continue;
            };
            const center = universe.findSystemById(row.system_id) orelse continue;
            parsed.storms[parsed.count] = .init(center, kind, row.hours_in_system);
            parsed.count += 1;
        }
        return parsed;
    }

    pub fn slice(self: *const Storms) []const Storm {
        return self.storms[0..self.count];
    }

    /// The strongest storm over the gate between two systems, the core first; storms can overlap.
    pub fn edgeMark(self: *const Storms, first: SystemIndex, second: SystemIndex) ?EdgeMark {
        var mark: ?EdgeMark = null;
        for (self.slice()) |*storm| {
            if (storm.core.isSet(first) and storm.core.isSet(second)) return .{ .kind = storm.kind, .is_core = true };
            if (mark == null and storm.covered.isSet(first) and storm.covered.isSet(second)) mark = .{ .kind = storm.kind, .is_core = false };
        }
        return mark;
    }

    pub fn centeredOn(self: *const Storms, system: SystemIndex) ?*const Storm {
        for (self.slice()) |*storm| {
            if (storm.center == system) return storm;
        }
        return null;
    }
};

/// `observation_type` reads like "gamma_a"; the letter tells the two of a kind apart.
fn kindOf(observation_type: []const u8) ?Kind {
    const end = std.mem.indexOfScalar(u8, observation_type, '_') orelse observation_type.len;
    return std.meta.stringToEnum(Kind, observation_type[0..end]);
}

const testing = std.testing;

const REPLY =
    \\[{"observation_type":"gamma_a","observation_category":"storm","hours_in_system":17,"system_id":30000439},
    \\{"observation_type":"electric_b","observation_category":"storm","hours_in_system":7,"system_id":30003217},
    \\{"observation_type":"toms_shuttle","observation_category":"space_oddity","hours_in_system":339,"system_id":30021407}]
;

test "parse reads the storms and skips other oddities" {
    const parsed: Storms = try .parse(testing.allocator, REPLY);
    try testing.expectEqual(@as(usize, 2), parsed.count);
    try testing.expectEqual(Kind.gamma, parsed.storms[0].kind);
    try testing.expectEqualStrings("OEG-K9", universe.systemName(parsed.storms[0].center));
    try testing.expectEqual(@as(u32, 17), parsed.storms[0].hours_in_system);
    try testing.expectEqual(Kind.electric, parsed.storms[1].kind);
}

test "parse skips a storm it can't place or name" {
    const parsed: Storms = try .parse(testing.allocator,
        \\[{"observation_type":"gamma_a","observation_category":"storm","system_id":31000005},
        \\{"observation_type":"sleet_a","observation_category":"storm","system_id":30000439}]
    );
    try testing.expectEqual(@as(usize, 0), parsed.count);
}

test "parse fails on a malformed reply" {
    try testing.expectError(error.SyntaxError, Storms.parse(testing.allocator, "[{not json"));
}

test "a storm's zones run out from its centre by gate jumps" {
    const parsed: Storms = try .parse(testing.allocator, REPLY);
    const storm = &parsed.storms[0];
    var distances: universe.Distances = undefined;
    universe.measureDistances(storm.center, 4, &distances);
    try testing.expectEqual(Zone.center, storm.zoneOf(storm.center).?);
    for (distances, 0..) |jumps, index| {
        const expected: ?Zone = switch (jumps) {
            0 => .center,
            1 => .core,
            2, 3 => .periphery,
            else => null,
        };
        try testing.expectEqual(expected, storm.zoneOf(@intCast(index)));
    }
}

test "a gate's mark is the core's where the core covers both ends, and none past the storm" {
    const parsed: Storms = try .parse(testing.allocator, REPLY);
    const storm = &parsed.storms[0];
    var links = universe.neighbours(storm.center);
    const next = links.next().?;
    try testing.expectEqual(EdgeMark{ .kind = .gamma, .is_core = true }, parsed.edgeMark(storm.center, next).?);

    var distances: universe.Distances = undefined;
    universe.measureDistances(storm.center, 4, &distances);
    const third = std.mem.indexOfScalar(u8, &distances, 3).?;
    var outward = universe.neighbours(@intCast(third));
    while (outward.next()) |neighbour| {
        if (distances[neighbour] == 4) try testing.expect(parsed.edgeMark(@intCast(third), neighbour) == null);
        if (distances[neighbour] == 2) try testing.expectEqual(EdgeMark{ .kind = .gamma, .is_core = false }, parsed.edgeMark(@intCast(third), neighbour).?);
    }
}

test "centeredOn finds a storm only at its centre" {
    const parsed: Storms = try .parse(testing.allocator, REPLY);
    try testing.expectEqual(Kind.electric, parsed.centeredOn(parsed.storms[1].center).?.kind);
    try testing.expect(parsed.centeredOn(universe.findSystem("Jita").?) == null);
}
