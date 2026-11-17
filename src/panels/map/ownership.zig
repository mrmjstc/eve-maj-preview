//! Who holds the map's systems and regions, and the colour each holder takes; no I/O.
const std = @import("std");
const list_look = @import("../list_look.zig");
const look = @import("look.zig");
const universe = @import("../../map/universe.zig");
const layout = @import("../../map/layout.zig");
const stats = @import("../../map/stats.zig");
const holder_colors = @import("../../map/holder_colors.zig");
const faction_warfare = @import("../../map/faction_warfare.zig");

const LogoColors = holder_colors.LogoColors;
const Snapshot = stats.Snapshot;
const SystemIndex = universe.SystemIndex;

/// By a holder's rank on the map, for one with neither a faction's nor a logo's colour.
const HOLDER_COLORS = [_]u32{ 0xFF4F9DFF, 0xFFFF7A59, 0xFF54D18C, 0xFFE8C547, 0xFFC77DFF, 0xFF3FD0D8, 0xFFFF6FAE, 0xFF9CCB3B, 0xFFB08D6E, 0xFF8E9BFF };

/// A holder of systems in a region, into Snapshot.holder_ids.
pub const RankedHolder = struct { holder: u16, system_count: u16 };

/// Who holds the systems shown, most first; only these take the palette's colours.
pub const HolderRanks = struct {
    holders: [HOLDER_COLORS.len]RankedHolder = undefined,
    /// By place in `holders`: a faction's own, else its logo's, else the palette's next.
    colors: [HOLDER_COLORS.len]u32 = undefined,
    count: usize = 0,
    /// Systems held by anyone past the ranked.
    other_count: usize = 0,
    unclaimed_count: usize = 0,
    /// Borrowed for one render, for an unranked holder's own colour.
    snapshot: ?*const Snapshot = null,
    /// Borrowed for one render; null until the first logo colours arrive.
    logos: ?*const LogoColors = null,

    /// `logos` is null until the first logo colours arrive.
    pub fn fromNodes(snapshot: *const Snapshot, nodes: []const layout.Node, logos: ?*const LogoColors) HolderRanks {
        var held: [layout.MAX_NODES]u16 = undefined;
        for (nodes, held[0..nodes.len]) |node, *holder| holder.* = snapshot.systems[node.system].holder;
        return .fromHolders(snapshot, held[0..nodes.len], logos);
    }

    /// One holder per system or region in `held`, at most MAX_NODES; `logos` is null until the first logo colours arrive.
    pub fn fromHolders(snapshot: *const Snapshot, held: []const u16, logos: ?*const LogoColors) HolderRanks {
        var ranks: HolderRanks = .{ .snapshot = snapshot, .logos = logos };
        var tally: [layout.MAX_NODES]RankedHolder = undefined;
        var tally_count: usize = 0;
        counting: for (held) |holder| {
            if (holder == stats.NO_HOLDER) {
                ranks.unclaimed_count += 1;
                continue;
            }
            for (tally[0..tally_count]) |*counted| {
                if (counted.holder != holder) continue;
                counted.system_count += 1;
                continue :counting;
            }
            tally[tally_count] = .{ .holder = holder, .system_count = 1 };
            tally_count += 1;
        }
        std.mem.sort(RankedHolder, tally[0..tally_count], {}, holdsMore);
        ranks.count = @min(tally_count, ranks.holders.len);
        @memcpy(ranks.holders[0..ranks.count], tally[0..ranks.count]);
        for (tally[ranks.count..tally_count]) |counted| ranks.other_count += counted.system_count;
        var palette_index: usize = 0;
        for (ranks.holders[0..ranks.count], ranks.colors[0..ranks.count]) |ranked, *shade| {
            shade.* = holderColor(snapshot, ranked.holder, logos) orelse blk: {
                palette_index += 1;
                break :blk HOLDER_COLORS[palette_index - 1];
            };
        }
        return ranks;
    }

    /// An unranked holder keeps its faction's or logo's colour, else it's muted.
    pub fn colorOf(self: *const HolderRanks, holder: u16) u32 {
        if (holder == stats.NO_HOLDER) return look.HEAT_NONE;
        for (self.holders[0..self.count], self.colors[0..self.count]) |ranked, shade| {
            if (ranked.holder == holder) return shade;
        }
        const snapshot = self.snapshot orelse return list_look.MUTED;
        return holderColor(snapshot, holder, self.logos) orelse list_look.MUTED;
    }
};

/// Each region's holder of the most systems, NO_HOLDER where its unclaimed systems outnumber every holder's.
pub fn regionHolders(snapshot: *const Snapshot) [universe.REGION_COUNT]u16 {
    comptime std.debug.assert(universe.REGION_COUNT <= layout.MAX_NODES);
    // Sorted by region then holder, each run is one holder's systems in one region.
    var sort_keys: [universe.SYSTEM_COUNT]u32 = undefined;
    for (snapshot.systems, &sort_keys, 0..) |system_stats, *sort_key, system| {
        sort_key.* = @as(u32, universe.systemInfo(@intCast(system)).region) << 16 | system_stats.holder;
    }
    std.mem.sort(u32, &sort_keys, {}, std.sort.asc(u32));

    var holders: [universe.REGION_COUNT]u16 = @splat(stats.NO_HOLDER);
    var best_counts: [universe.REGION_COUNT]usize = @splat(0);
    var run_start: usize = 0;
    for (sort_keys, 0..) |sort_key, index| {
        if (index + 1 < sort_keys.len and sort_keys[index + 1] == sort_key) continue;
        const run_length = index + 1 - run_start;
        run_start = index + 1;
        const region = sort_key >> 16;
        // Strictly more, so a holder keeps a tie over NO_HOLDER, which sorts last.
        if (run_length <= best_counts[region]) continue;
        best_counts[region] = run_length;
        holders[region] = @truncate(sort_key);
    }
    return holders;
}

/// Each region's occupier of the most warzone systems, NO_FACTION for a region outside the warzones.
pub fn regionOccupiers(snapshot: *const Snapshot) [universe.REGION_COUNT]u8 {
    var counts: [universe.REGION_COUNT][faction_warfare.FACTIONS.len + 1]u16 = @splat(@splat(0));
    for (snapshot.warfare, 0..) |system, index| {
        if (system.occupier == faction_warfare.NO_FACTION) continue;
        counts[universe.systemInfo(@intCast(index)).region][system.occupier] += 1;
    }
    var occupiers: [universe.REGION_COUNT]u8 = @splat(faction_warfare.NO_FACTION);
    for (&occupiers, counts) |*occupier, region_counts| {
        var best: u16 = 0;
        for (region_counts[1..], 1..) |count, place| {
            if (count <= best) continue;
            best = count;
            occupier.* = @intCast(place);
        }
    }
    return occupiers;
}

/// A faction's own colour, or an alliance's logo's; null when neither is known.
fn holderColor(snapshot: *const Snapshot, holder: u16, logos: ?*const LogoColors) ?u32 {
    if (holder >= snapshot.holder_ids.items.len) return null;
    const id = snapshot.holder_ids.items[holder];
    if (holder_colors.factionColor(id)) |faction_color| return faction_color;
    const known = logos orelse return null;
    const logo_color = known.get(id) orelse return null;
    return if (logo_color == holder_colors.NO_COLOR) null else logo_color;
}

fn holdsMore(_: void, first: RankedHolder, second: RankedHolder) bool {
    if (first.system_count != second.system_count) return first.system_count > second.system_count;
    return first.holder < second.holder;
}

const testing = std.testing;

test "holders rank by systems held, past the colours sum up, and the unclaimed count apart" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    var nodes: [HOLDER_COLORS.len + 5]layout.Node = undefined;
    for (&nodes, 0..) |*node, index| {
        const system: SystemIndex = @intCast(index);
        node.* = .{ .system = system, .x = 0, .y = 0 };
        snapshot.systems[system].holder = @intCast(index);
    }
    snapshot.systems[0].holder = 7;
    snapshot.systems[1].holder = 7;
    snapshot.systems[2].holder = stats.NO_HOLDER;
    const ranks: HolderRanks = .fromNodes(&snapshot, &nodes, null);
    try testing.expectEqual(@as(u16, 7), ranks.holders[0].holder);
    try testing.expectEqual(@as(u16, 3), ranks.holders[0].system_count);
    try testing.expectEqual(HOLDER_COLORS.len, ranks.count);
    try testing.expectEqual(@as(usize, 1), ranks.unclaimed_count);
    try testing.expect(ranks.other_count > 0);
    try testing.expectEqual(HOLDER_COLORS[0], ranks.colorOf(7));
    try testing.expectEqual(look.HEAT_NONE, ranks.colorOf(stats.NO_HOLDER));
}

test "a holder is coloured as its faction, else its logo, else by the palette's next colour" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    // Guristas Pirates, an alliance with a logo colour, one whose logo had none, and one not yet looked at.
    const ids = [_]u32{ 500010, 99000001, 99000002, 99000003 };
    var nodes: [ids.len]layout.Node = undefined;
    for (&nodes, ids, 0..) |*node, id, index| {
        const system: SystemIndex = @intCast(index);
        node.* = .{ .system = system, .x = 0, .y = 0 };
        snapshot.systems[system].holder = @intCast(index);
        try snapshot.holder_ids.append(testing.allocator, id);
    }
    var logos: LogoColors = .{};
    logos.put(99000001, 0xFF123456);
    logos.put(99000002, holder_colors.NO_COLOR);
    const ranks: HolderRanks = .fromNodes(&snapshot, &nodes, &logos);
    try testing.expectEqual(holder_colors.factionColor(500010).?, ranks.colorOf(0));
    try testing.expectEqual(@as(u32, 0xFF123456), ranks.colorOf(1));
    try testing.expectEqual(HOLDER_COLORS[0], ranks.colorOf(2));
    try testing.expectEqual(HOLDER_COLORS[1], ranks.colorOf(3));
}

test "a holder past the ranked keeps its faction's colour" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    // Each ranked alliance holds two systems; Caldari State, last, holds one.
    var nodes: [2 * HOLDER_COLORS.len + 1]layout.Node = undefined;
    for (&nodes, 0..) |*node, index| {
        const system: SystemIndex = @intCast(index);
        node.* = .{ .system = system, .x = 0, .y = 0 };
        snapshot.systems[system].holder = @intCast(index / 2);
    }
    for (0..HOLDER_COLORS.len) |index| try snapshot.holder_ids.append(testing.allocator, 99000000 + @as(u32, @intCast(index)));
    try snapshot.holder_ids.append(testing.allocator, 500001);
    const ranks: HolderRanks = .fromNodes(&snapshot, &nodes, null);
    try testing.expectEqual(HOLDER_COLORS.len, ranks.count);
    try testing.expectEqual(holder_colors.factionColor(500001).?, ranks.colorOf(HOLDER_COLORS.len));
}

test "a region goes to the holder of most of its systems, and one nobody holds stays unclaimed" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    const region = universe.systemInfo(0).region;
    for (snapshot.systems, 0..) |*system_stats, system| {
        if (universe.systemInfo(@intCast(system)).region == region) system_stats.holder = 4;
    }
    snapshot.systems[0].holder = 2;
    const holders = regionHolders(&snapshot);
    try testing.expectEqual(@as(u16, 4), holders[region]);
    try testing.expectEqual(@as(u16, stats.NO_HOLDER), holders[(region + 1) % universe.REGION_COUNT]);
}
