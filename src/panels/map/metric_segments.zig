//! Which metrics each of the map's metric bar segments shows, and the value a metric reads from a system; no I/O.
const std = @import("std");
const types = @import("../../config/types.zig");
const stats_mod = @import("../../map/stats.zig");

const MapMetric = types.MapMetric;
const SystemStats = stats_mod.SystemStats;

/// Left to right.
pub const SEGMENT_ORDER = std.enums.values(MetricSegment);

/// A button in the bar along the map's bottom; one with a second metric flips to it when clicked again.
pub const MetricSegment = enum { security, kills, npc, jumps, sovereignty, faction_warfare };

/// What `segment` shows while `current` is the map's metric: that, if it's the segment's, else the segment's first.
pub fn shownMetric(segment: MetricSegment, current: MapMetric) MapMetric {
    return if (segmentOf(current) == segment) current else segmentMetrics(segment)[0];
}

pub fn segmentOf(metric: MapMetric) MetricSegment {
    return switch (metric) {
        .Security => .security,
        .ShipKills, .PodKills => .kills,
        .NpcKills, .NpcDelta => .npc,
        .Jumps => .jumps,
        .Sovereignty => .sovereignty,
        .FactionWarfare => .faction_warfare,
    };
}

/// A click on the segment showing `current` moves on to its next metric; on any other, picks that segment's first.
pub fn metricAfterClick(current: MapMetric, segment: MetricSegment) MapMetric {
    const metrics = segmentMetrics(segment);
    const index = std.mem.findScalar(MapMetric, metrics, current) orelse return metrics[0];
    return metrics[(index + 1) % metrics.len];
}

/// Those the span bar sums over a longer span; NPC delta is ESI's change on the hour, so it isn't one.
pub fn isSpannedMetric(metric: MapMetric) bool {
    return switch (metric) {
        .ShipKills, .PodKills, .NpcKills, .Jumps => true,
        .Security, .NpcDelta, .Sovereignty, .FactionWarfare => false,
    };
}

/// Zero for what colours by the system rather than its traffic.
pub fn metricValue(metric: MapMetric, stats: SystemStats) u32 {
    return switch (metric) {
        .Security, .Sovereignty, .FactionWarfare => 0,
        .ShipKills => stats.ship_kills,
        .PodKills => stats.pod_kills,
        .NpcKills => stats.npc_kills,
        .NpcDelta => @abs(stats.npc_delta),
        .Jumps => stats.jumps,
    };
}

/// What a segment shows, the one a first click picks first.
fn segmentMetrics(segment: MetricSegment) []const MapMetric {
    return switch (segment) {
        .security => &.{.Security},
        .kills => &.{ .ShipKills, .PodKills },
        .npc => &.{ .NpcKills, .NpcDelta },
        .jumps => &.{.Jumps},
        .sovereignty => &.{.Sovereignty},
        .faction_warfare => &.{.FactionWarfare},
    };
}

const testing = std.testing;

test "metricValue counts ships and pods apart, and Security counts nothing" {
    const stats: SystemStats = .{ .ship_kills = 3, .pod_kills = 2, .npc_kills = 40, .jumps = 9 };
    try testing.expectEqual(@as(u32, 3), metricValue(.ShipKills, stats));
    try testing.expectEqual(@as(u32, 2), metricValue(.PodKills, stats));
    try testing.expectEqual(@as(u32, 40), metricValue(.NpcKills, stats));
    try testing.expectEqual(@as(u32, 9), metricValue(.Jumps, stats));
    try testing.expectEqual(@as(u32, 0), metricValue(.Security, stats));
}

test "every metric sits in its own segment's list" {
    for (std.enums.values(MapMetric)) |metric| {
        try testing.expect(std.mem.findScalar(MapMetric, segmentMetrics(segmentOf(metric)), metric) != null);
    }
}

test "a segment shows the map's metric while it's that segment's, and its first otherwise" {
    try testing.expectEqual(MapMetric.NpcDelta, shownMetric(.npc, .NpcDelta));
    try testing.expectEqual(MapMetric.NpcKills, shownMetric(.npc, .Jumps));
    try testing.expectEqual(MapMetric.Security, shownMetric(.security, .Security));
}

test "a second click on a segment flips to its other metric, and another segment starts at its first" {
    try testing.expectEqual(MapMetric.ShipKills, metricAfterClick(.Security, .kills));
    try testing.expectEqual(MapMetric.PodKills, metricAfterClick(.ShipKills, .kills));
    try testing.expectEqual(MapMetric.ShipKills, metricAfterClick(.PodKills, .kills));
    try testing.expectEqual(MapMetric.Jumps, metricAfterClick(.Jumps, .jumps));
    try testing.expectEqual(MapMetric.Jumps, metricAfterClick(.PodKills, .jumps));
}

test "only the traffic metrics a span sums take the span bar" {
    try testing.expect(isSpannedMetric(.ShipKills));
    try testing.expect(isSpannedMetric(.Jumps));
    try testing.expect(!isSpannedMetric(.NpcDelta));
    try testing.expect(!isSpannedMetric(.Security));
}
