//! Where one region's systems, gates and name labels go inside a pixel area, on CCP's flattened map; no I/O.
const std = @import("std");
const universe = @import("universe.zig");

const RegionIndex = universe.RegionIndex;
const SystemIndex = universe.SystemIndex;

/// The most gates any region has; a test holds every region to it.
pub const MAX_EDGES = 300;
/// The most gates out of any region; a test holds every region to it.
pub const MAX_EXITS = 48;
/// Around the systems, for their labels and exits.
const MARGIN = 30;
const EXIT_LENGTH: f32 = 16;
const EXIT_LABEL_GAP = 3;
/// How far from a system its label sits, and the box its marker keeps clear of labels.
const NODE_CLEARANCE = 5;
/// Kept free on each side of a label, so two names on a line don't read as one.
const LABEL_SIDE_GAP = 2;
/// How close the cursor must come to a system or an exit, in pixels.
const HIT_RADIUS = 9;

/// In pixels, `right` and `bottom` exclusive.
pub const Box = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    fn overlaps(self: Box, other: Box) bool {
        return self.left < other.right and other.left < self.right and self.top < other.bottom and other.top < self.bottom;
    }

    fn contains(self: Box, other: Box) bool {
        return other.left >= self.left and other.top >= self.top and other.right <= self.right and other.bottom <= self.bottom;
    }
};

pub const Node = struct {
    system: SystemIndex,
    x: i32,
    y: i32,
    /// Null when no spot was free, which leaves the name to the hover tooltip.
    label: ?Box = null,
};

/// A gate between two systems shown, by their places in `nodes`.
pub const Edge = struct {
    first: u16,
    second: u16,
    /// Within one constellation.
    is_local: bool,
};

/// A gate out of the region, drawn as a short stub pointing at the system it leads to.
pub const Exit = struct {
    /// Its place in `nodes`.
    from: u16,
    destination: SystemIndex,
    region: RegionIndex,
    x: i32,
    y: i32,
    /// Null when no spot was free.
    label: ?Box = null,
};

/// One region laid out; rebuilt when the region or the panel's size changes.
pub const Layout = struct {
    region: RegionIndex = 0,
    area: Box = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    nodes: [universe.MAX_REGION_SYSTEMS]Node = undefined,
    node_count: usize = 0,
    edges: [MAX_EDGES]Edge = undefined,
    edge_count: usize = 0,
    exits: [MAX_EXITS]Exit = undefined,
    exit_count: usize = 0,

    /// Labels stay unplaced until placeLabels; gates past the limits are left out, which a test rules out for today's map.
    pub fn build(self: *Layout, region: RegionIndex, area: Box) void {
        self.region = region;
        self.area = area;
        self.node_count = 0;
        self.edge_count = 0;
        self.exit_count = 0;

        var bounds: Bounds = .{};
        for (0..universe.SYSTEM_COUNT) |index| {
            const system: SystemIndex = @intCast(index);
            const info = universe.systemInfo(system);
            if (info.region != region) continue;
            bounds.include(info);
            self.nodes[self.node_count] = .{ .system = system, .x = 0, .y = 0 };
            self.node_count += 1;
        }

        const fit = bounds.fitTo(area);
        for (self.nodes[0..self.node_count]) |*node| {
            const info = universe.systemInfo(node.system);
            node.x = fit.pixelX(info.x);
            node.y = fit.pixelY(info.y);
        }
        for (0..self.node_count) |index| self.addGates(@intCast(index), fit);
    }

    /// Greedily, the most connected systems first; `node_widths` and `exit_widths` are pixel widths in `nodes` and `exits` order.
    pub fn placeLabels(self: *Layout, node_widths: []const i32, exit_widths: []const i32, line_height: i32) void {
        var taken: [universe.MAX_REGION_SYSTEMS * 2 + MAX_EXITS * 2]Box = undefined;
        var taken_count: usize = 0;
        for (self.nodes[0..self.node_count]) |node| {
            taken[taken_count] = markerBox(node.x, node.y);
            taken_count += 1;
        }
        for (self.exits[0..self.exit_count]) |exit| {
            taken[taken_count] = markerBox(exit.x, exit.y);
            taken_count += 1;
        }

        var order: [universe.MAX_REGION_SYSTEMS]u16 = undefined;
        for (order[0..self.node_count], 0..) |*slot, index| slot.* = @intCast(index);
        std.mem.sort(u16, order[0..self.node_count], self, moreConnected);

        for (order[0..self.node_count]) |index| {
            const node = &self.nodes[index];
            node.label = self.claimSpot(&taken, &taken_count, node.x, node.y, node_widths[index], line_height);
        }
        for (self.exits[0..self.exit_count], exit_widths[0..self.exit_count]) |*exit, width| {
            exit.label = self.claimSpot(&taken, &taken_count, exit.x, exit.y, width, line_height);
        }
    }

    /// The nearest system within reach of the cursor.
    pub fn nodeAt(self: *const Layout, x: i32, y: i32) ?u16 {
        var nearest: ?u16 = null;
        var nearest_distance: i32 = HIT_RADIUS * HIT_RADIUS + 1;
        for (self.nodes[0..self.node_count], 0..) |node, index| {
            const distance = distanceSquared(x, y, node.x, node.y);
            if (distance < nearest_distance) {
                nearest_distance = distance;
                nearest = @intCast(index);
            }
        }
        return nearest;
    }

    /// The nearest exit within reach of the cursor.
    pub fn exitAt(self: *const Layout, x: i32, y: i32) ?u16 {
        var nearest: ?u16 = null;
        var nearest_distance: i32 = HIT_RADIUS * HIT_RADIUS + 1;
        for (self.exits[0..self.exit_count], 0..) |exit, index| {
            const distance = distanceSquared(x, y, exit.x, exit.y);
            if (distance < nearest_distance) {
                nearest_distance = distance;
                nearest = @intCast(index);
            }
        }
        return nearest;
    }

    /// Searched linearly: a region has at most a couple of hundred.
    pub fn nodeOf(self: *const Layout, system: SystemIndex) ?u16 {
        for (self.nodes[0..self.node_count], 0..) |node, index| {
            if (node.system == system) return @intCast(index);
        }
        return null;
    }

    fn addGates(self: *Layout, index: u16, fit: Fit) void {
        const node = self.nodes[index];
        const info = universe.systemInfo(node.system);
        var links = universe.neighbours(node.system);
        while (links.next()) |neighbour| {
            const other = universe.systemInfo(neighbour);
            if (other.region != self.region) {
                self.addExit(index, neighbour, other, fit);
                continue;
            }
            if (neighbour < node.system or self.edge_count == MAX_EDGES) continue;
            const second = self.nodeOf(neighbour) orelse continue;
            self.edges[self.edge_count] = .{ .first = index, .second = second, .is_local = other.constellation == info.constellation };
            self.edge_count += 1;
        }
    }

    fn addExit(self: *Layout, from: u16, destination: SystemIndex, other: universe.SystemInfo, fit: Fit) void {
        if (self.exit_count == MAX_EXITS) return;
        const node = self.nodes[from];
        const delta_x: f32 = @floatFromInt(fit.pixelX(other.x) - node.x);
        const delta_y: f32 = @floatFromInt(fit.pixelY(other.y) - node.y);
        const length = @sqrt(delta_x * delta_x + delta_y * delta_y);
        const step_x = if (length > 0) delta_x / length else 0;
        const step_y = if (length > 0) delta_y / length else -1;
        self.exits[self.exit_count] = .{
            .from = from,
            .destination = destination,
            .region = other.region,
            .x = node.x + @as(i32, @intFromFloat(@round(step_x * EXIT_LENGTH))),
            .y = node.y + @as(i32, @intFromFloat(@round(step_y * EXIT_LENGTH))),
        };
        self.exit_count += 1;
    }

    fn claimSpot(self: *const Layout, taken: []Box, taken_count: *usize, x: i32, y: i32, width: i32, line_height: i32) ?Box {
        const half_width = @divTrunc(width, 2);
        const half_height = @divTrunc(line_height, 2);
        const spots = [_]Box{
            .{ .left = x - half_width, .top = y + NODE_CLEARANCE, .right = x - half_width + width, .bottom = y + NODE_CLEARANCE + line_height },
            .{ .left = x - half_width, .top = y - NODE_CLEARANCE - line_height, .right = x - half_width + width, .bottom = y - NODE_CLEARANCE },
            .{ .left = x + NODE_CLEARANCE + EXIT_LABEL_GAP, .top = y - half_height, .right = x + NODE_CLEARANCE + EXIT_LABEL_GAP + width, .bottom = y - half_height + line_height },
            .{ .left = x - NODE_CLEARANCE - EXIT_LABEL_GAP - width, .top = y - half_height, .right = x - NODE_CLEARANCE - EXIT_LABEL_GAP, .bottom = y - half_height + line_height },
        };
        for (spots) |spot| {
            const clearance: Box = .{ .left = spot.left - LABEL_SIDE_GAP, .top = spot.top, .right = spot.right + LABEL_SIDE_GAP, .bottom = spot.bottom };
            if (!self.area.contains(spot) or overlapsAny(clearance, taken[0..taken_count.*])) continue;
            taken[taken_count.*] = clearance;
            taken_count.* += 1;
            return spot;
        }
        return null;
    }

    fn moreConnected(self: *const Layout, first: u16, second: u16) bool {
        const first_count = gateCount(self.nodes[first].system);
        const second_count = gateCount(self.nodes[second].system);
        if (first_count != second_count) return first_count > second_count;
        return first < second;
    }
};

/// The extent of a region's systems on CCP's map.
const Bounds = struct {
    min_x: i32 = std.math.maxInt(i32),
    min_y: i32 = std.math.maxInt(i32),
    max_x: i32 = std.math.minInt(i32),
    max_y: i32 = std.math.minInt(i32),

    fn include(self: *Bounds, info: universe.SystemInfo) void {
        self.min_x = @min(self.min_x, info.x);
        self.min_y = @min(self.min_y, info.y);
        self.max_x = @max(self.max_x, info.x);
        self.max_y = @max(self.max_y, info.y);
    }

    /// Keeps the map's proportions, centred; a lone system sits in the middle.
    fn fitTo(self: Bounds, area: Box) Fit {
        const room_x: f32 = @floatFromInt(@max(1, area.right - area.left - 2 * MARGIN));
        const room_y: f32 = @floatFromInt(@max(1, area.bottom - area.top - 2 * MARGIN));
        const span_x: f32 = @floatFromInt(self.max_x - self.min_x);
        const span_y: f32 = @floatFromInt(self.max_y - self.min_y);
        const scale_x = if (span_x > 0) room_x / span_x else std.math.inf(f32);
        const scale_y = if (span_y > 0) room_y / span_y else std.math.inf(f32);
        const smaller = @min(scale_x, scale_y);
        const scale = if (std.math.isInf(smaller)) 0 else smaller;
        return .{
            .scale = scale,
            .origin_x = self.min_x,
            .origin_y = self.min_y,
            .left = @as(f32, @floatFromInt(area.left)) + (@as(f32, @floatFromInt(area.right - area.left)) - span_x * scale) / 2,
            .top = @as(f32, @floatFromInt(area.top)) + (@as(f32, @floatFromInt(area.bottom - area.top)) - span_y * scale) / 2,
        };
    }
};

/// Map units to pixels.
const Fit = struct {
    scale: f32,
    origin_x: i32,
    origin_y: i32,
    left: f32,
    top: f32,

    fn pixelX(self: Fit, x: i16) i32 {
        return @intFromFloat(@round(self.left + @as(f32, @floatFromInt(@as(i32, x) - self.origin_x)) * self.scale));
    }

    fn pixelY(self: Fit, y: i16) i32 {
        return @intFromFloat(@round(self.top + @as(f32, @floatFromInt(@as(i32, y) - self.origin_y)) * self.scale));
    }
};

fn markerBox(x: i32, y: i32) Box {
    return .{ .left = x - NODE_CLEARANCE, .top = y - NODE_CLEARANCE, .right = x + NODE_CLEARANCE, .bottom = y + NODE_CLEARANCE };
}

fn overlapsAny(box: Box, others: []const Box) bool {
    for (others) |other| {
        if (box.overlaps(other)) return true;
    }
    return false;
}

fn gateCount(system: SystemIndex) usize {
    var links = universe.neighbours(system);
    var count: usize = 0;
    while (links.next() != null) count += 1;
    return count;
}

fn distanceSquared(from_x: i32, from_y: i32, to_x: i32, to_y: i32) i32 {
    const delta_x = from_x - to_x;
    const delta_y = from_y - to_y;
    return delta_x * delta_x + delta_y * delta_y;
}

const testing = std.testing;

const TEST_AREA: Box = .{ .left = 0, .top = 20, .right = 760, .bottom = 530 };
/// About a 10 px font's width for an average name.
const TEST_LABEL_WIDTH = 36;
const TEST_LINE_HEIGHT = 12;

fn regionNamed(name: []const u8) RegionIndex {
    for (0..universe.REGION_COUNT) |index| {
        const region: RegionIndex = @intCast(index);
        if (std.mem.eql(u8, universe.regionName(region), name)) return region;
    }
    unreachable;
}

test "every region's systems and gates fit their arrays, and stay inside the area" {
    var layout: Layout = .{};
    for (0..universe.REGION_COUNT) |index| {
        const region: RegionIndex = @intCast(index);
        layout.build(region, TEST_AREA);
        try testing.expect(layout.node_count > 0);

        var gate_count: usize = 0;
        var exit_count: usize = 0;
        for (layout.nodes[0..layout.node_count]) |node| {
            try testing.expect(node.x >= TEST_AREA.left and node.x < TEST_AREA.right);
            try testing.expect(node.y >= TEST_AREA.top and node.y < TEST_AREA.bottom);
            var links = universe.neighbours(node.system);
            while (links.next()) |neighbour| {
                if (universe.systemInfo(neighbour).region == region) gate_count += 1 else exit_count += 1;
            }
        }
        try testing.expect(gate_count / 2 <= MAX_EDGES);
        try testing.expect(exit_count <= MAX_EXITS);
        try testing.expectEqual(gate_count / 2, layout.edge_count);
        try testing.expectEqual(exit_count, layout.exit_count);
    }
}

test "a region's map keeps the shape of its gates" {
    var layout: Layout = .{};
    layout.build(regionNamed("The Forge"), TEST_AREA);
    const jita = layout.nodeOf(universe.findSystem("Jita").?).?;
    const perimeter = layout.nodeOf(universe.findSystem("Perimeter").?).?;
    const distance = distanceSquared(layout.nodes[jita].x, layout.nodes[jita].y, layout.nodes[perimeter].x, layout.nodes[perimeter].y);
    try testing.expect(distance > 0);
    try testing.expect(distance < 100 * 100);
    try testing.expect(layout.nodeOf(universe.findSystem("Amarr").?) == null);
}

test "a one-system region sits in the middle of the area" {
    var layout: Layout = .{};
    layout.build(regionNamed("Yasna Zakh"), TEST_AREA);
    try testing.expectEqual(@as(usize, 1), layout.node_count);
    try testing.expectEqual(@divTrunc(TEST_AREA.left + TEST_AREA.right, 2), layout.nodes[0].x);
    try testing.expectEqual(@divTrunc(TEST_AREA.top + TEST_AREA.bottom, 2), layout.nodes[0].y);
}

test "an exit names the region its gate leads to" {
    var layout: Layout = .{};
    layout.build(regionNamed("The Forge"), TEST_AREA);
    const perimeter = universe.findSystem("Perimeter").?;
    var has_exit = false;
    for (layout.exits[0..layout.exit_count]) |exit| {
        if (layout.nodes[exit.from].system != perimeter) continue;
        try testing.expect(exit.region != layout.region);
        has_exit = true;
    }
    try testing.expect(has_exit);
}

test "placed labels never overlap each other or a marker, and stay inside the area" {
    var layout: Layout = .{};
    const widths: [universe.MAX_REGION_SYSTEMS]i32 = @splat(TEST_LABEL_WIDTH);
    const exit_widths: [MAX_EXITS]i32 = @splat(TEST_LABEL_WIDTH);
    layout.build(regionNamed("Domain"), TEST_AREA);
    layout.placeLabels(&widths, &exit_widths, TEST_LINE_HEIGHT);

    var placed_count: usize = 0;
    for (layout.nodes[0..layout.node_count], 0..) |node, index| {
        const label = node.label orelse continue;
        placed_count += 1;
        try testing.expect(TEST_AREA.contains(label));
        for (layout.nodes[0..layout.node_count], 0..) |other, other_index| {
            try testing.expect(!label.overlaps(markerBox(other.x, other.y)));
            if (other_index != index) {
                if (other.label) |other_label| try testing.expect(!label.overlaps(other_label));
            }
        }
    }
    // The tightest region: most names still fit, and hover covers the rest.
    try testing.expect(placed_count * 2 > layout.node_count);
}

test "nodeAt finds a system within reach and nothing further off" {
    var layout: Layout = .{};
    layout.build(regionNamed("The Forge"), TEST_AREA);
    const node = layout.nodes[0];
    try testing.expectEqual(@as(?u16, 0), layout.nodeAt(node.x + 2, node.y - 2));
    try testing.expect(layout.nodeAt(TEST_AREA.left, TEST_AREA.top) == null);
}
