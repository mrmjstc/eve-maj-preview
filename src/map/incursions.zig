//! Incursions: where each stages and which systems it infests, parsed from ESI's reply; no I/O.
const std = @import("std");
const universe = @import("universe.zig");
const log = @import("../log.zig");

const SystemIndex = universe.SystemIndex;
const SystemSet = universe.SystemSet;
const slog = log.Scoped("map");

/// Well past the handful the game runs at once; any beyond it go unshown.
pub const MAX_INCURSIONS = 16;

pub const State = enum { established, mobilizing, withdrawing };

const Row = struct { staging_solar_system_id: u32, infested_solar_systems: []const u32, state: []const u8, influence: f32 = 0 };

pub const Incursion = struct {
    staging: SystemIndex,
    state: State,
    influence_percent: u8,
    /// By SystemIndex, the staging system included.
    infested: SystemSet = .empty,
};

pub const Incursions = struct {
    incursions: [MAX_INCURSIONS]Incursion = undefined,
    count: usize = 0,

    /// `body` is /incursions/'s reply; systems with no gates are skipped.
    pub fn parse(allocator: std.mem.Allocator, body: []const u8) !Incursions {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const rows = try std.json.parseFromSliceLeaky([]const Row, arena.allocator(), body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });

        var parsed: Incursions = .{};
        for (rows) |row| {
            if (parsed.count == MAX_INCURSIONS) break;
            const state = std.meta.stringToEnum(State, row.state) orelse {
                slog.warn("Failed to read an incursion in state '{s}'", .{row.state});
                continue;
            };
            const staging = universe.findSystemById(row.staging_solar_system_id) orelse continue;
            var incursion: Incursion = .{ .staging = staging, .state = state, .influence_percent = percentOf(row.influence) };
            incursion.infested.set(staging);
            for (row.infested_solar_systems) |id| {
                if (universe.findSystemById(id)) |system| incursion.infested.set(system);
            }
            parsed.incursions[parsed.count] = incursion;
            parsed.count += 1;
        }
        return parsed;
    }

    pub fn slice(self: *const Incursions) []const Incursion {
        return self.incursions[0..self.count];
    }

    /// Whether one incursion infests both ends of a gate.
    pub fn coversGate(self: *const Incursions, first: SystemIndex, second: SystemIndex) bool {
        for (self.slice()) |*incursion| {
            if (incursion.infested.isSet(first) and incursion.infested.isSet(second)) return true;
        }
        return false;
    }

    pub fn stagedAt(self: *const Incursions, system: SystemIndex) ?*const Incursion {
        for (self.slice()) |*incursion| {
            if (incursion.staging == system) return incursion;
        }
        return null;
    }
};

/// ESI gives influence from 0 to 1.
fn percentOf(influence: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(influence, 0, 1) * 100));
}

const testing = std.testing;

const REPLY =
    \\[{"constellation_id":20000483,"faction_id":500019,"has_boss":true,"infested_solar_systems":[30003309,30003310,30003319],"influence":0.9395,"staging_solar_system_id":30003319,"state":"mobilizing","type":"Incursion"},
    \\{"constellation_id":20000608,"faction_id":500019,"has_boss":false,"infested_solar_systems":[30004160,30004159],"influence":1.0,"staging_solar_system_id":30004159,"state":"established","type":"Incursion"}]
;
const STAGING_ID = 30003319;
const INFESTED_ID = 30003310;
const OTHER_STAGING_ID = 30004159;

test "parse reads each incursion's staging system, state and influence" {
    const parsed: Incursions = try .parse(testing.allocator, REPLY);
    try testing.expectEqual(@as(usize, 2), parsed.count);
    try testing.expectEqual(universe.findSystemById(STAGING_ID).?, parsed.incursions[0].staging);
    try testing.expectEqual(State.mobilizing, parsed.incursions[0].state);
    try testing.expectEqual(@as(u8, 94), parsed.incursions[0].influence_percent);
    try testing.expectEqual(@as(u8, 100), parsed.incursions[1].influence_percent);
}

test "an incursion infests only the systems listed, and its staging system" {
    const parsed: Incursions = try .parse(testing.allocator,
        \\[{"infested_solar_systems":[30003310],"staging_solar_system_id":30003319,"state":"withdrawing"}]
    );
    const infested = &parsed.incursions[0].infested;
    try testing.expectEqual(@as(usize, 2), infested.count());
    try testing.expect(infested.isSet(universe.findSystemById(STAGING_ID).?));
    try testing.expect(infested.isSet(universe.findSystemById(INFESTED_ID).?));
}

test "parse skips an incursion it can't place or read" {
    const parsed: Incursions = try .parse(testing.allocator,
        \\[{"infested_solar_systems":[],"staging_solar_system_id":31000005,"state":"mobilizing"},
        \\{"infested_solar_systems":[],"staging_solar_system_id":30003319,"state":"brewing"}]
    );
    try testing.expectEqual(@as(usize, 0), parsed.count);
}

test "parse fails on a malformed reply" {
    try testing.expectError(error.SyntaxError, Incursions.parse(testing.allocator, "[{not json"));
}

test "stagedAt finds an incursion only at its staging system" {
    const parsed: Incursions = try .parse(testing.allocator, REPLY);
    try testing.expectEqual(State.established, parsed.stagedAt(universe.findSystemById(OTHER_STAGING_ID).?).?.state);
    try testing.expect(parsed.stagedAt(universe.findSystemById(INFESTED_ID).?) == null);
}

test "a gate counts as covered only with both ends in one incursion" {
    const parsed: Incursions = try .parse(testing.allocator, REPLY);
    const staging = universe.findSystemById(STAGING_ID).?;
    try testing.expect(parsed.coversGate(staging, universe.findSystemById(INFESTED_ID).?));
    try testing.expect(!parsed.coversGate(staging, universe.findSystemById(OTHER_STAGING_ID).?));
}
