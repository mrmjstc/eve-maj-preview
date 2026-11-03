//! Every region as a bubble where it lies in New Eden, joined where gates link them, for picking one; no I/O.
const std = @import("std");
const universe = @import("universe.zig");
const layout = @import("layout.zig");

const Box = layout.Box;
const RegionIndex = universe.RegionIndex;

/// The most pairs of regions joined by gates; a test holds today's map to it.
pub const MAX_LINKS = 180;
/// Around the bubbles, for their labels.
const MARGIN = 34;
const MIN_RADIUS: f32 = 3;
/// A bubble's area grows with its systems.
const RADIUS_PER_ROOT_SYSTEM: f32 = 0.4;
/// How close the cursor must come to a bubble, in pixels.
const HIT_RADIUS = 12;
const TAKEN_CAPACITY = universe.REGION_COUNT * 2;

pub const Bubble = struct {
    x: i32 = 0,
    y: i32 = 0,
    radius: f32 = 0,
    system_count: u16 = 0,
    /// Averaged over its systems, in the same tenths as SystemInfo.
    security_tenths: i8 = 0,
    /// Null when no spot was free, which leaves the name to the hover tooltip.
    label: ?Box = null,
};

/// Two regions a gate joins.
pub const Link = struct { first: RegionIndex, second: RegionIndex };

/// Rebuilt when the area changes.
pub const Overview = struct {
    /// By RegionIndex.
    bubbles: [universe.REGION_COUNT]Bubble = @splat(.{}),
    links: [MAX_LINKS]Link = undefined,
    link_count: usize = 0,
    area: Box = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

    /// Labels stay unplaced until placeLabels.
    pub fn build(self: *Overview, area: Box) void {
        self.* = .{ .area = area };
        const centers = centerPoints(self);
        self.fitBubbles(&centers);
        self.findLinks();
    }

    /// Greedily, the biggest regions first; `widths` are pixel widths by RegionIndex.
    pub fn placeLabels(self: *Overview, widths: []const i32, line_height: i32) void {
        var taken: [TAKEN_CAPACITY]Box = undefined;
        var taken_count: usize = 0;
        for (self.bubbles) |bubble| {
            taken[taken_count] = bubbleBox(bubble);
            taken_count += 1;
        }

        var order: [universe.REGION_COUNT]RegionIndex = undefined;
        for (&order, 0..) |*slot, index| slot.* = @intCast(index);
        std.mem.sort(RegionIndex, &order, self, isBigger);

        for (order) |region| {
            const bubble = &self.bubbles[region];
            const clearance: i32 = @intFromFloat(@ceil(bubble.radius) + 2);
            bubble.label = layout.claimSpot(self.area, &taken, &taken_count, bubble.x, bubble.y, widths[region], line_height, clearance);
        }
    }

    /// The nearest bubble within reach of the cursor, or the name under it.
    pub fn regionAt(self: *const Overview, x: i32, y: i32) ?RegionIndex {
        var nearest: ?RegionIndex = null;
        var nearest_distance: i32 = HIT_RADIUS * HIT_RADIUS + 1;
        for (self.bubbles, 0..) |bubble, index| {
            const delta_x = x - bubble.x;
            const delta_y = y - bubble.y;
            const distance = delta_x * delta_x + delta_y * delta_y;
            if (distance >= nearest_distance) continue;
            nearest_distance = distance;
            nearest = @intCast(index);
        }
        if (nearest != null) return nearest;
        for (self.bubbles, 0..) |bubble, index| {
            const label = bubble.label orelse continue;
            if (x >= label.left and x < label.right and y >= label.top and y < label.bottom) return @intCast(index);
        }
        return null;
    }

    fn fitBubbles(self: *Overview, centers: *const [universe.REGION_COUNT][2]f32) void {
        var min_x = std.math.inf(f32);
        var min_y = std.math.inf(f32);
        var max_x = -std.math.inf(f32);
        var max_y = -std.math.inf(f32);
        for (centers) |center| {
            min_x = @min(min_x, center[0]);
            max_x = @max(max_x, center[0]);
            min_y = @min(min_y, center[1]);
            max_y = @max(max_y, center[1]);
        }
        // Stretched to the area rather than kept in proportion, which fits about a dozen more names at the default size.
        const scale_x = @max(1, @as(f32, @floatFromInt(self.area.right - self.area.left - 2 * MARGIN))) / (max_x - min_x);
        const scale_y = @max(1, @as(f32, @floatFromInt(self.area.bottom - self.area.top - 2 * MARGIN))) / (max_y - min_y);
        const left: f32 = @floatFromInt(self.area.left + MARGIN);
        const top: f32 = @floatFromInt(self.area.top + MARGIN);
        for (&self.bubbles, centers) |*bubble, center| {
            bubble.x = @intFromFloat(@round(left + (center[0] - min_x) * scale_x));
            bubble.y = @intFromFloat(@round(top + (center[1] - min_y) * scale_y));
            bubble.radius = MIN_RADIUS + RADIUS_PER_ROOT_SYSTEM * @sqrt(@as(f32, @floatFromInt(bubble.system_count)));
        }
    }

    fn findLinks(self: *Overview) void {
        for (0..universe.SYSTEM_COUNT) |index| {
            const system: universe.SystemIndex = @intCast(index);
            const region = universe.systemInfo(system).region;
            var links = universe.neighbours(system);
            while (links.next()) |neighbour| {
                const other = universe.systemInfo(neighbour).region;
                if (other > region) self.addLink(region, other);
            }
        }
    }

    fn addLink(self: *Overview, first: RegionIndex, second: RegionIndex) void {
        for (self.links[0..self.link_count]) |link| {
            if (link.first == first and link.second == second) return;
        }
        if (self.link_count == MAX_LINKS) return;
        self.links[self.link_count] = .{ .first = first, .second = second };
        self.link_count += 1;
    }

    fn isBigger(self: *const Overview, first: RegionIndex, second: RegionIndex) bool {
        const first_count = self.bubbles[first].system_count;
        const second_count = self.bubbles[second].system_count;
        if (first_count != second_count) return first_count > second_count;
        return first < second;
    }
};

/// Each region's middle on CCP's map, counting its systems into `overview`.
fn centerPoints(overview: *Overview) [universe.REGION_COUNT][2]f32 {
    var totals: [universe.REGION_COUNT][2]f32 = @splat(.{ 0, 0 });
    var security_totals: [universe.REGION_COUNT]i32 = @splat(0);
    for (0..universe.SYSTEM_COUNT) |index| {
        const info = universe.systemInfo(@intCast(index));
        totals[info.region][0] += @floatFromInt(info.x);
        totals[info.region][1] += @floatFromInt(info.y);
        security_totals[info.region] += info.security_tenths;
        overview.bubbles[info.region].system_count += 1;
    }
    for (&totals, &overview.bubbles, security_totals) |*total, *bubble, security_total| {
        const count: i32 = @max(1, bubble.system_count);
        total[0] /= @floatFromInt(count);
        total[1] /= @floatFromInt(count);
        bubble.security_tenths = @intCast(@divTrunc(security_total, count));
    }
    return totals;
}

fn bubbleBox(bubble: Bubble) Box {
    const reach: i32 = @intFromFloat(@ceil(bubble.radius) + 1);
    return .{ .left = bubble.x - reach, .top = bubble.y - reach, .right = bubble.x + reach, .bottom = bubble.y + reach };
}

const testing = std.testing;

const TEST_AREA: Box = .{ .left = 0, .top = 0, .right = 760, .bottom = 540 };
/// About a 10 px font's width for an average region name.
const TEST_LABEL_WIDTH = 64;
const TEST_LINE_HEIGHT = 13;

fn regionNamed(name: []const u8) !RegionIndex {
    for (0..universe.REGION_COUNT) |index| {
        const region: RegionIndex = @intCast(index);
        if (std.mem.eql(u8, universe.regionName(region), name)) return region;
    }
    return error.TestExpectedRegion;
}

test "every region sits inside the area, and every gate between regions fits" {
    var overview: Overview = .{};
    overview.build(TEST_AREA);
    var system_total: usize = 0;
    for (overview.bubbles) |bubble| {
        try testing.expect(bubble.x >= TEST_AREA.left and bubble.x < TEST_AREA.right);
        try testing.expect(bubble.y >= TEST_AREA.top and bubble.y < TEST_AREA.bottom);
        system_total += bubble.system_count;
    }
    try testing.expectEqual(universe.SYSTEM_COUNT, system_total);
    try testing.expect(overview.link_count < MAX_LINKS);
}

test "a region's security is the average of its systems" {
    var overview: Overview = .{};
    overview.build(TEST_AREA);
    try testing.expect(overview.bubbles[try regionNamed("The Forge")].security_tenths > 0);
    try testing.expect(overview.bubbles[try regionNamed("Delve")].security_tenths < 0);
}

test "the overview joins neighbouring regions and not distant ones" {
    var overview: Overview = .{};
    overview.build(TEST_AREA);
    const forge = try regionNamed("The Forge");
    const lonetrek = try regionNamed("Lonetrek");
    const delve = try regionNamed("Delve");
    var has_near = false;
    var has_far = false;
    for (overview.links[0..overview.link_count]) |link| {
        if (link.first == @min(forge, lonetrek) and link.second == @max(forge, lonetrek)) has_near = true;
        if (link.first == @min(forge, delve) and link.second == @max(forge, delve)) has_far = true;
    }
    try testing.expect(has_near);
    try testing.expect(!has_far);
}

test "most names fit, and none overlaps another or a bubble" {
    var overview: Overview = .{};
    overview.build(TEST_AREA);
    const widths: [universe.REGION_COUNT]i32 = @splat(TEST_LABEL_WIDTH);
    overview.placeLabels(&widths, TEST_LINE_HEIGHT);

    var placed_count: usize = 0;
    for (overview.bubbles, 0..) |bubble, index| {
        const label = bubble.label orelse continue;
        placed_count += 1;
        try testing.expect(TEST_AREA.contains(label));
        for (overview.bubbles, 0..) |other, other_index| {
            if (other_index == index) continue;
            try testing.expect(!label.overlaps(bubbleBox(other)));
            if (other.label) |other_label| try testing.expect(!label.overlaps(other_label));
        }
    }
    try testing.expect(placed_count * 4 >= universe.REGION_COUNT * 3);
}

test "regionAt finds a bubble within reach and misses empty space" {
    var overview: Overview = .{};
    overview.build(TEST_AREA);
    const forge = try regionNamed("The Forge");
    const bubble = overview.bubbles[forge];
    try testing.expectEqual(@as(?RegionIndex, forge), overview.regionAt(bubble.x + 1, bubble.y - 1));
    try testing.expect(overview.regionAt(TEST_AREA.left, TEST_AREA.top) == null);
}
