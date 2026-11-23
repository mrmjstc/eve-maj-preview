//! How the map's markers and gates take their colour from the metric shown; no I/O.
const std = @import("std");
const types = @import("../../config/types.zig");
const look = @import("look.zig");
const metric_segments = @import("metric_segments.zig");
const ownership = @import("ownership.zig");
const universe = @import("../../map/universe.zig");
const layout_mod = @import("../../map/layout.zig");
const stats_mod = @import("../../map/stats.zig");
const faction_warfare = @import("../../map/faction_warfare.zig");
const security = @import("../../map/security.zig");

const Layout = layout_mod.Layout;
const MapMetric = types.MapMetric;
const Snapshot = stats_mod.Snapshot;
const SystemIndex = universe.SystemIndex;
const SystemStats = stats_mod.SystemStats;
const TrafficSpan = types.TrafficSpan;

/// What's measured once a frame for colouring the map.
pub const MapPaint = struct {
    metric: MapMetric,
    /// By SystemIndex, what `metric` reads; null while none have come.
    traffic: ?[]const SystemStats,
    /// What Eve Stars summed `traffic` over; null for ESI's last hour.
    span: ?TrafficSpan,
    /// The busiest system shown by `metric`, which heat is measured against.
    peak: u32,
    holders: ownership.HolderRanks,
    /// Borrowed for one render; null until ESI's first figures arrive.
    stats: ?*const Snapshot,

    /// `value` is what `metric` reads for `system`.
    pub fn markerColor(self: *const MapPaint, system: SystemIndex, value: u32) u32 {
        return switch (self.metric) {
            .Security => security.securityColor(universe.systemInfo(system).security_tenths),
            .ShipKills, .PodKills, .NpcKills, .Jumps => look.heatColor(value, self.peak),
            .NpcDelta => if (self.stats) |stats| look.deltaColor(stats.systems[system].npc_delta, self.peak) else look.HEAT_NONE,
            .Sovereignty => self.holders.colorOf(if (self.stats) |stats| stats.systems[system].holder else stats_mod.NO_HOLDER),
            .FactionWarfare => if (self.stats) |stats| look.warfareColor(stats.warfare[system]) else look.HEAT_NONE,
        };
    }

    /// Null outside Sovereignty and Faction Warfare, or unless one holder or occupier has both ends, so a grey gate marks where two meet.
    pub fn holderEdgeColor(self: *const MapPaint, first: SystemIndex, second: SystemIndex) ?u32 {
        const stats = self.stats orelse return null;
        if (self.metric == .FactionWarfare) {
            const occupier = stats.warfare[first].occupier;
            if (occupier == faction_warfare.NO_FACTION or occupier != stats.warfare[second].occupier) return null;
            return look.factionColorOf(occupier);
        }
        if (self.metric != .Sovereignty) return null;
        const holder = stats.systems[first].holder;
        if (holder == stats_mod.NO_HOLDER or holder != stats.systems[second].holder) return null;
        return self.holders.colorOf(holder);
    }
};

/// The busiest of `layout`'s systems by `metric`, which heat is measured against.
pub fn peakValue(layout: *const Layout, traffic: ?[]const SystemStats, metric: MapMetric) u32 {
    const systems = traffic orelse return 0;
    var peak: u32 = 0;
    for (layout.nodes[0..layout.node_count]) |node| peak = @max(peak, metric_segments.metricValue(metric, systems[node.system]));
    return peak;
}

const testing = std.testing;

fn testPaint(metric: MapMetric, snapshot: ?*const Snapshot, holders: ownership.HolderRanks) MapPaint {
    return .{ .metric = metric, .traffic = null, .span = null, .peak = 10, .holders = holders, .stats = snapshot };
}

test "the peak is the busiest system on the map, and zero before any figures" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    var layout: Layout = .{};
    layout.nodes[0] = .{ .system = 0, .x = 0, .y = 0 };
    layout.nodes[1] = .{ .system = 1, .x = 0, .y = 0 };
    layout.node_count = 2;
    snapshot.systems[0].jumps = 4;
    snapshot.systems[1].jumps = 9;
    // Busier, but not on the map.
    snapshot.systems[2].jumps = 500;
    try testing.expectEqual(@as(u32, 9), peakValue(&layout, snapshot.systems, .Jumps));
    try testing.expectEqual(@as(u32, 0), peakValue(&layout, null, .Jumps));
}

test "markers that need ESI's figures stay quiet until they come" {
    try testing.expectEqual(look.HEAT_NONE, testPaint(.NpcDelta, null, .{}).markerColor(0, 5));
    try testing.expectEqual(look.HEAT_NONE, testPaint(.FactionWarfare, null, .{}).markerColor(0, 5));
}

test "a sovereignty marker takes its holder's colour" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    snapshot.systems[0].holder = 3;
    snapshot.systems[1].holder = stats_mod.NO_HOLDER;
    const held = [_]u16{ 3, stats_mod.NO_HOLDER };
    const paint = testPaint(.Sovereignty, &snapshot, .fromHolders(&snapshot, &held, null));
    try testing.expectEqual(paint.holders.colorOf(3), paint.markerColor(0, 0));
    try testing.expectEqual(look.HEAT_NONE, paint.markerColor(1, 0));
}

test "a gate takes its holder's colour only when one holder has both ends" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    snapshot.systems[0].holder = 3;
    snapshot.systems[1].holder = 3;
    snapshot.systems[2].holder = 4;
    const held = [_]u16{ 3, 3, 4 };
    const paint = testPaint(.Sovereignty, &snapshot, .fromHolders(&snapshot, &held, null));
    try testing.expectEqual(paint.holders.colorOf(3), paint.holderEdgeColor(0, 1).?);
    try testing.expect(paint.holderEdgeColor(1, 2) == null);
    // Unclaimed at both ends.
    try testing.expect(paint.holderEdgeColor(3, 4) == null);
    try testing.expect(testPaint(.Jumps, &snapshot, paint.holders).holderEdgeColor(0, 1) == null);
}

test "a warzone gate takes its occupier's colour only when one faction holds both ends" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    snapshot.warfare[0].occupier = 1;
    snapshot.warfare[1].occupier = 1;
    snapshot.warfare[2].occupier = 2;
    const paint = testPaint(.FactionWarfare, &snapshot, .{});
    try testing.expectEqual(look.factionColorOf(1), paint.holderEdgeColor(0, 1).?);
    try testing.expect(paint.holderEdgeColor(1, 2) == null);
    try testing.expect(paint.holderEdgeColor(3, 4) == null);
}
