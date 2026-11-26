//! Faction warfare: who occupies each warzone system and how far it's contested, parsed from ESI's reply; no I/O.
const std = @import("std");
const universe = @import("universe.zig");
const log = @import("../log.zig");

const slog = log.Scoped("map");

/// In System.occupier and System.owner: not in a warzone.
pub const NO_FACTION: u8 = 0;

/// The factions at war, as ESI names them; a System's occupier and owner are a place here, past NO_FACTION.
pub const FACTIONS = [_]Faction{
    .{ .id = 500001, .name = "Caldari State" },
    .{ .id = 500002, .name = "Minmatar Republic" },
    .{ .id = 500003, .name = "Amarr Empire" },
    .{ .id = 500004, .name = "Gallente Federation" },
    .{ .id = 500010, .name = "Guristas Pirates" },
    .{ .id = 500011, .name = "Angel Cartel" },
};

pub const Faction = struct {
    id: u32,
    name: []const u8,
};

pub const State = enum { uncontested, contested, vulnerable, captured };

/// A warzone system's standing; the zero value is a system outside every warzone.
pub const System = struct {
    /// 1 + its place in FACTIONS, or NO_FACTION.
    occupier: u8 = NO_FACTION,
    /// 1 + its place in FACTIONS, or NO_FACTION.
    owner: u8 = NO_FACTION,
    /// Victory points against the threshold, capped at 100.
    contested_percent: u8 = 0,
    state: State = .uncontested,
};

const Row = struct {
    solar_system_id: u32,
    occupier_faction_id: u32,
    owner_faction_id: u32,
    contested: []const u8,
    victory_points: u32 = 0,
    victory_points_threshold: u32 = 0,
};

/// `body` is /fw/systems/'s reply, written into `systems` by SystemIndex; a system with a faction not in FACTIONS is skipped.
pub fn apply(allocator: std.mem.Allocator, body: []const u8, systems: []System) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const rows = try std.json.parseFromSliceLeaky([]const Row, arena.allocator(), body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    var unknown_id: ?u32 = null;
    defer if (unknown_id) |id| slog.warn("Failed to show the systems faction {d} occupies, as it's new to the map", .{id});
    for (rows) |row| {
        const system = universe.findSystemById(row.solar_system_id) orelse continue;
        const occupier = factionOf(row.occupier_faction_id) orelse {
            unknown_id = row.occupier_faction_id;
            continue;
        };
        const percent = if (row.victory_points_threshold == 0) 0 else @min(100, @as(u64, row.victory_points) * 100 / row.victory_points_threshold);
        systems[system] = .{
            .occupier = occupier,
            .owner = factionOf(row.owner_faction_id) orelse occupier,
            .contested_percent = @intCast(percent),
            .state = std.meta.stringToEnum(State, row.contested) orelse .contested,
        };
    }
}

/// `place` is an occupier or owner, past NO_FACTION.
pub fn faction(place: u8) Faction {
    return FACTIONS[place - 1];
}

/// 1 + its place in FACTIONS.
fn factionOf(id: u32) ?u8 {
    for (FACTIONS, 1..) |known, place| {
        if (known.id == id) return @intCast(place);
    }
    return null;
}

const testing = std.testing;

test "apply reads each system's occupier, owner, contest and state" {
    var systems: [universe.SYSTEM_COUNT]System = @splat(.{});
    try apply(testing.allocator,
        \\[{"contested":"contested","occupier_faction_id":500003,"owner_faction_id":500002,"solar_system_id":30002957,"victory_points":37500,"victory_points_threshold":75000},
        \\{"contested":"vulnerable","occupier_faction_id":500004,"owner_faction_id":500004,"solar_system_id":30005295,"victory_points":90000,"victory_points_threshold":75000},
        \\{"contested":"contested","occupier_faction_id":123,"owner_faction_id":123,"solar_system_id":30005296,"victory_points":1,"victory_points_threshold":75000}]
    , &systems);
    const first = systems[universe.findSystemById(30002957).?];
    try testing.expectEqualStrings("Amarr Empire", faction(first.occupier).name);
    try testing.expectEqualStrings("Minmatar Republic", faction(first.owner).name);
    try testing.expectEqual(@as(u8, 50), first.contested_percent);
    try testing.expectEqual(State.contested, first.state);
    const second = systems[universe.findSystemById(30005295).?];
    try testing.expectEqual(@as(u8, 100), second.contested_percent);
    try testing.expectEqual(State.vulnerable, second.state);
    try testing.expectEqual(NO_FACTION, systems[universe.findSystemById(30005296).?].occupier);
    try testing.expectEqual(NO_FACTION, systems[universe.findSystem("Jita").?].occupier);
}

test "apply fails on a malformed reply" {
    var systems: [universe.SYSTEM_COUNT]System = @splat(.{});
    try testing.expectError(error.SyntaxError, apply(testing.allocator, "[{not json", &systems));
}
