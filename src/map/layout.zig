//! Where a few regions' systems, gates and name labels go inside a pixel area, on CCP's flattened map; no I/O.
const std = @import("std");
const universe = @import("universe.zig");
const wormholes = @import("wormholes.zig");
const box_mod = @import("../util/box.zig");

const RegionIndex = universe.RegionIndex;
const SystemIndex = universe.SystemIndex;
pub const Box = box_mod.Box;

/// The most regions shown at once, as names stop fitting past it.
pub const MAX_REGIONS = 4;
/// The most gates inside any region; a test holds every region to it.
pub const MAX_REGION_EDGES = 300;
/// The most gates out of any region; a test holds every region to it.
pub const MAX_REGION_EXITS = 48;
pub const MAX_NODES = universe.MAX_REGION_SYSTEMS * MAX_REGIONS;
/// A gate between two regions shown is an edge rather than an exit.
pub const MAX_EDGES = (MAX_REGION_EDGES + MAX_REGION_EXITS) * MAX_REGIONS;
pub const MAX_EXITS = MAX_REGION_EXITS * MAX_REGIONS;
/// Wormhole and Ansiblex stubs on the map at once; past the forty-odd wormholes both hubs have open across New Eden and the gates out of a coalition's busiest regions.
pub const MAX_PORTALS = 96;
/// Between regions shown together, in CCP's map units, where a gate inside a region is about 65 long.
const REGION_GAP: f32 = 160;
/// Packing stops sooner, once no two regions overlap.
const PACK_ROUNDS = 64;
/// Kept between a gate between regions and any other system it would run past, in pixels.
const BEND_CLEARANCE: f32 = 8;
/// A bent gate is drawn as this many straight pieces.
pub const CURVE_SEGMENTS = 16;
/// Between a region's systems and its name.
const REGION_LABEL_GAP = 4;
/// How many lines out from a region's side its name is tried, to clear the names of the systems along it.
const REGION_LABEL_STEPS = 3;
/// Best first: over the region, then under it, then inside its top and bottom.
const REGION_LABEL_SPOTS = regionLabelSpots();
/// Around the systems, for their labels and exits.
const MARGIN = 30;
const EXIT_LENGTH: f32 = 16;
const EXIT_LABEL_GAP = 3;
/// How far from a system its label sits at full fit, and the box its marker keeps clear of labels.
pub const NODE_CLEARANCE = 5;
/// The most gates freestStep weighs; no system has more than a dozen.
const MAX_LINKS = 16;
/// Kept free on each side of a label, so two names on a line don't read as one.
const LABEL_SIDE_GAP = 2;
/// Around a client tag's name inside its chip, and the room a system's or exit's name keeps.
pub const CHIP_PADDING_X = 5;
pub const CHIP_PADDING_Y = 2;
/// How close the cursor must come to a system or an exit, in pixels.
const HIT_RADIUS = 9;
/// The most boxes floating over the map that names keep clear of: its cards, bars and controls.
pub const MAX_COVERED = 10;
const TAKEN_CAPACITY = MAX_COVERED + MAX_NODES * 2 + (MAX_EXITS + MAX_PORTALS) * 2;
/// What covering a system, a name or a card costs a region's name, against one for each gate it crosses, so it crosses any number of gates first.
const COVERING_COST = 1000;
pub const MAX_ZOOM: f32 = 8;
/// In Layout.node_index, for a system with no node.
const NO_NODE = std.math.maxInt(u16);

/// Zoom and pan over the fitted map; the default shows all of it.
pub const View = struct {
    zoom: f32 = 1,
    pan_x: f32 = 0,
    pan_y: f32 = 0,

    pub fn isFitted(self: View) bool {
        return self.zoom == 1;
    }

    /// Scaled by `factor`, keeping the map's point under `x`,`y` where it is.
    pub fn zoomedAt(self: View, area: Box, x: i32, y: i32, factor: f32) View {
        const zoom = std.math.clamp(self.zoom * factor, 1, MAX_ZOOM);
        const from_center_x = @as(f32, @floatFromInt(x)) - centerOf(area.left, area.right);
        const from_center_y = @as(f32, @floatFromInt(y)) - centerOf(area.top, area.bottom);
        const change = zoom / self.zoom;
        const zoomed: View = .{
            .zoom = zoom,
            .pan_x = from_center_x - (from_center_x - self.pan_x) * change,
            .pan_y = from_center_y - (from_center_y - self.pan_y) * change,
        };
        return zoomed.clamped(area);
    }

    pub fn panned(self: View, area: Box, delta_x: f32, delta_y: f32) View {
        const moved: View = .{ .zoom = self.zoom, .pan_x = self.pan_x + delta_x, .pan_y = self.pan_y + delta_y };
        return moved.clamped(area);
    }

    /// So the map's edge can't pass the middle of the area, which leaves half the area to pan at full fit.
    fn clamped(self: View, area: Box) View {
        const reach_x = @as(f32, @floatFromInt(area.right - area.left)) * self.zoom / 2;
        const reach_y = @as(f32, @floatFromInt(area.bottom - area.top)) * self.zoom / 2;
        return .{ .zoom = self.zoom, .pan_x = std.math.clamp(self.pan_x, -reach_x, reach_x), .pan_y = std.math.clamp(self.pan_y, -reach_y, reach_y) };
    }
};

/// What toggling a region did.
pub const Toggle = union(enum) { added, removed, last, replaced: RegionIndex };

/// The regions a Layout shows, in the order they were picked.
pub const Regions = struct {
    items: [MAX_REGIONS]RegionIndex = undefined,
    count: usize = 0,

    pub fn one(region: RegionIndex) Regions {
        var regions: Regions = .{};
        regions.items[0] = region;
        regions.count = 1;
        return regions;
    }

    pub fn slice(self: *const Regions) []const RegionIndex {
        return self.items[0..self.count];
    }

    pub fn indexOf(self: *const Regions, region: RegionIndex) ?usize {
        return std.mem.indexOfScalar(RegionIndex, self.slice(), region);
    }

    pub fn contains(self: *const Regions, region: RegionIndex) bool {
        return self.indexOf(region) != null;
    }

    /// Whether it went in; a full set, or one already holding it, takes nothing.
    pub fn add(self: *Regions, region: RegionIndex) bool {
        if (self.count == MAX_REGIONS or self.contains(region)) return false;
        self.items[self.count] = region;
        self.count += 1;
        return true;
    }

    /// Never takes out the last one; a full set drops its earliest pick to make room.
    pub fn toggle(self: *Regions, region: RegionIndex) Toggle {
        if (self.indexOf(region)) |index| {
            if (self.count == 1) return .last;
            self.removeAt(index);
            return .removed;
        }
        if (self.add(region)) return .added;
        const dropped = self.items[0];
        self.removeAt(0);
        _ = self.add(region);
        return .{ .replaced = dropped };
    }

    fn removeAt(self: *Regions, index: usize) void {
        std.mem.copyForwards(RegionIndex, self.items[index .. self.count - 1], self.items[index + 1 .. self.count]);
        self.count -= 1;
    }
};

/// A place on CCP's flattened map, in its units.
pub const MapPoint = struct { x: i32, y: i32 };

/// What a gate's two systems share.
pub const GateKind = enum { within_constellation, within_region, between_regions };

pub const Node = struct {
    system: SystemIndex,
    x: i32,
    y: i32,
    /// Null when no spot was free, which leaves the name to the hover tooltip.
    label: ?Box = null,
};

/// A pixel on the area.
pub const PixelPoint = struct { x: i32, y: i32 };

/// How a system's name sits, where it differs from the rest: on more lines, or further off for a mark around the system.
pub const LabelShape = struct {
    line_count: u8 = 1,
    /// The least room from the system; the placers' own clearance when larger.
    clearance: i32 = 0,
};

/// A place to try a region's name, against the box around its systems.
const RegionLabelSpot = struct {
    side: Side,
    alignment: Alignment,
    /// Lines further out than the side itself.
    step: i32 = 0,

    const Side = enum { above, below, inside_top, inside_bottom };
    const Alignment = enum { center, start, end };

    fn place(self: RegionLabelSpot, around: Box, width: i32, line_height: i32) Box {
        const left = switch (self.alignment) {
            .center => @divTrunc(around.left + around.right - width, 2),
            .start => around.left,
            .end => around.right - width,
        };
        const top = switch (self.side) {
            .above => around.top - REGION_LABEL_GAP - (self.step + 1) * line_height,
            .below => around.bottom + REGION_LABEL_GAP + self.step * line_height,
            .inside_top => around.top + REGION_LABEL_GAP,
            .inside_bottom => around.bottom - REGION_LABEL_GAP - line_height,
        };
        return .{ .left = left, .top = top, .right = left + width, .bottom = top + line_height };
    }
};

/// A gate between two systems shown, by their places in `nodes`.
pub const Edge = struct {
    first_index: u16,
    second_index: u16,
    kind: GateKind,
    /// How far its curve's control point sits off its middle, in pixels to the left going first to second; 0 for straight.
    bend: f32 = 0,
};

/// A gate to a region not shown, drawn as a short stub pointing at the system it leads to.
pub const Exit = struct {
    /// Its place in `nodes`.
    from_index: u16,
    destination: SystemIndex,
    region: RegionIndex,
    x: i32,
    y: i32,
    /// Null when no spot was free.
    label: ?Box = null,
};

/// Where a portal leads: a wormhole hub, which isn't on the map, or the far end of an Ansiblex gate, which isn't shown.
pub const PortalTarget = union(enum) {
    hub: wormholes.Hub,
    system: SystemIndex,

    pub fn eql(self: PortalTarget, other: PortalTarget) bool {
        return switch (self) {
            .hub => |hub| other == .hub and other.hub == hub,
            .system => |system| other == .system and other.system == system,
        };
    }

    /// One number a target, for hashing without the union's padding.
    pub fn key(self: PortalTarget) u32 {
        return switch (self) {
            .hub => |hub| @backingInt(hub),
            .system => |system| @as(u32, system) + @as(u32, std.enums.values(wormholes.Hub).len),
        };
    }
};

/// A way off the map that isn't a gate, from a system shown, drawn as a short stub with where it leads, like an exit.
pub const Portal = struct {
    /// Its place in `nodes`.
    from_index: u16,
    target: PortalTarget,
    x: i32 = 0,
    y: i32 = 0,
    /// Null when no spot was free.
    label: ?Box = null,
};

/// A system with a way to `target`, for setPortals.
pub const PortalEnd = struct {
    system: SystemIndex,
    target: PortalTarget,
};

/// A few regions side by side, or a handful of systems around one, laid out; gathered again when the regions change, and placed again when the area or view does.
pub const Layout = struct {
    regions: Regions = .{},
    /// How far each region's diagram moved from CCP's place for it, by its place in `regions`.
    offsets: [MAX_REGIONS]MapPoint = @splat(.{ .x = 0, .y = 0 }),
    /// Around each region's systems, by its place in `regions`.
    region_areas: [MAX_REGIONS]Box = undefined,
    /// Each region's name, by its place in `regions`; null until placeRegionLabels, while one region shows, or with no room.
    region_labels: [MAX_REGIONS]?Box = @splat(null),
    area: Box = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    /// Only `build` honours it, and a system zoomed off the area stays in `nodes`, with no label.
    view: View = .{},
    nodes: [MAX_NODES]Node = undefined,
    node_count: usize = 0,
    edges: [MAX_EDGES]Edge = undefined,
    edge_count: usize = 0,
    exits: [MAX_EXITS]Exit = undefined,
    exit_count: usize = 0,
    /// The regions `nodes`, `edges` and `exits` were gathered for, which a pan or zoom keeps; null after buildAround.
    gathered: ?Regions = null,
    /// Each node's place on CCP's map, its region's diagram moved, by its place in `nodes`.
    points: [MAX_NODES]MapPoint = undefined,
    /// Around every node's point.
    bounds: Bounds = .{},
    /// Around each region's points, by its place in `regions`.
    region_bounds: [MAX_REGIONS]Bounds = @splat(.{}),
    /// Which way each exit points on CCP's map, as a unit step, by its place in `exits`.
    exit_steps: [MAX_EXITS]Vector = undefined,
    /// Set by setPortals, and dropped when the regions change.
    portals: [MAX_PORTALS]Portal = undefined,
    portal_count: usize = 0,
    /// Which way each portal points on CCP's map, as a unit step, by its place in `portals`.
    portal_steps: [MAX_PORTALS]Vector = undefined,
    /// Places in `nodes`, most connected first, for placeLabels.
    label_order: [MAX_NODES]u16 = undefined,
    /// Each system's place in `nodes`, or NO_NODE; a lookup, as the panel asks for it per client and mark each frame.
    node_index: [universe.SYSTEM_COUNT]u16 = @splat(NO_NODE),

    /// `regions` holds at least one; labels stay unplaced until placeLabels, and gates past the limits are left out, which a test rules out for today's map.
    pub fn build(self: *Layout, regions: Regions, area: Box) void {
        if (!self.hasGathered(regions)) self.gather(regions);
        self.region_labels = @splat(null);
        self.area = area;

        var fit = self.bounds.fitTo(area);
        fit.view = self.view;
        self.placeNodes(fit);
        for (self.region_bounds[0..regions.count], self.region_areas[0..regions.count]) |shown, *region_area| region_area.* = fit.boxOf(shown);
        // Only the long gates between regions run past other systems; a region's own diagram keeps clear of them.
        for (self.edges[0..self.edge_count]) |*edge| edge.bend = if (edge.kind == .between_regions) self.bendAround(edge.first_index, edge.second_index) else 0;
        self.placeExits();
        self.placePortals();
    }

    /// Replaces the portals with one a system and target among `ends`, those not shown left out; one to a hub points into the widest gap between its system's gates, and one to a system toward it on CCP's map, as an exit does; drops their labels until placeLabels.
    pub fn setPortals(self: *Layout, ends: []const PortalEnd) void {
        self.portal_count = 0;
        for (ends) |end| {
            if (self.portal_count == MAX_PORTALS) break;
            const from = self.nodeOf(end.system) orelse continue;
            if (self.hasPortal(from, end.target)) continue;
            self.portal_steps[self.portal_count] = switch (end.target) {
                .hub => self.freestStep(from),
                .system => |system| stepToward(universe.systemInfo(end.system), universe.systemInfo(system)),
            };
            self.portals[self.portal_count] = .{ .from_index = from, .target = end.target };
            self.portal_count += 1;
        }
        self.placePortals();
    }

    fn hasPortal(self: *const Layout, from: u16, target: PortalTarget) bool {
        for (self.portals[0..self.portal_count]) |portal| {
            if (portal.from_index == from and portal.target.eql(target)) return true;
        }
        return false;
    }

    /// Halfway across the widest gap between the ways its gates and portals already set leave the node at `from`, on CCP's map; up with none.
    fn freestStep(self: *const Layout, from: u16) Vector {
        var angles: [MAX_LINKS + MAX_PORTALS]f32 = undefined;
        var count: usize = 0;
        const info = universe.systemInfo(self.nodes[from].system);
        var links = universe.neighbours(self.nodes[from].system);
        while (links.next()) |neighbour| {
            if (count == MAX_LINKS) break;
            const other = universe.systemInfo(neighbour);
            const delta_x: f32 = @floatFromInt(@as(i32, other.x) - info.x);
            const delta_y: f32 = @floatFromInt(@as(i32, other.y) - info.y);
            if (delta_x == 0 and delta_y == 0) continue;
            angles[count] = std.math.atan2(delta_y, delta_x);
            count += 1;
        }
        for (self.portals[0..self.portal_count], self.portal_steps[0..self.portal_count]) |portal, step| {
            if (portal.from_index != from) continue;
            angles[count] = std.math.atan2(step[1], step[0]);
            count += 1;
        }
        if (count == 0) return .{ 0, -1 };
        std.mem.sort(f32, angles[0..count], {}, std.sort.asc(f32));
        // The gap past the last wraps round to the first.
        var best_start = angles[count - 1];
        var best_size = angles[0] + 2 * std.math.pi - angles[count - 1];
        for (angles[0 .. count - 1], angles[1..count]) |start, end| {
            if (end - start <= best_size) continue;
            best_start = start;
            best_size = end - start;
        }
        const middle = best_start + best_size / 2;
        return .{ @cos(middle), @sin(middle) };
    }

    /// The nearest portal within reach of the cursor.
    pub fn portalAt(self: *const Layout, x: i32, y: i32) ?u16 {
        var nearest: ?u16 = null;
        var nearest_distance: i32 = HIT_RADIUS * HIT_RADIUS + 1;
        for (self.portals[0..self.portal_count], 0..) |portal, index| {
            const distance = distanceSquared(x, y, portal.x, portal.y);
            if (distance < nearest_distance) {
                nearest_distance = distance;
                nearest = @intCast(index);
            }
        }
        return nearest;
    }

    /// The portal whose name, with its padding, is under the cursor; placed labels never overlap, so the first is the only one.
    pub fn portalLabelAt(self: *const Layout, x: i32, y: i32) ?u16 {
        for (self.portals[0..self.portal_count], 0..) |portal, index| {
            const label = portal.label orelse continue;
            if (chipBox(label).containsPoint(x, y)) return @intCast(index);
        }
        return null;
    }

    /// Each a short step from its system, like an exit.
    fn placePortals(self: *Layout) void {
        for (self.portals[0..self.portal_count], self.portal_steps[0..self.portal_count]) |*portal, step| {
            const node = self.nodes[portal.from_index];
            portal.x = node.x + @as(i32, @intFromFloat(@round(step[0] * EXIT_LENGTH)));
            portal.y = node.y + @as(i32, @intFromFloat(@round(step[1] * EXIT_LENGTH)));
            portal.label = null;
        }
    }

    /// Only the gates among `systems`, at least one of them: those in the first's region become nodes, in order, and the rest exits.
    pub fn buildAround(self: *Layout, systems: []const SystemIndex, area: Box) void {
        self.clearNodes();
        self.gathered = null;
        self.regions = .one(universe.systemInfo(systems[0]).region);
        self.offsets = @splat(.{ .x = 0, .y = 0 });
        self.region_labels = @splat(null);
        self.area = area;

        var bounds: Bounds = .{};
        for (systems) |system| {
            const info = universe.systemInfo(system);
            if (!self.regions.contains(info.region)) continue;
            const point = self.mapPoint(info);
            bounds.include(point);
            self.addNode(system, point);
        }
        const fit = bounds.fitTo(area);
        self.placeNodes(fit);
        self.region_areas[0] = fit.boxOf(bounds);
        for (0..self.node_count) |index| {
            var links = universe.neighbours(self.nodes[index].system);
            while (links.next()) |neighbour| {
                if (isListed(systems, neighbour)) self.addGate(@intCast(index), neighbour);
            }
        }
        self.placeExits();
        self.sortLabelOrder();
    }

    /// Greedily, the most connected systems first, then exits and portals, `clearance` from their systems, inside `label_area` and clear of `covered`, the first MAX_COVERED of what floats over the map; `node_widths`, `exit_widths` and `portal_widths` are pixel widths in `nodes`, `exits` and `portals` order; `node_shapes` is in `nodes` order, or empty for one line each.
    pub fn placeLabels(self: *Layout, label_area: Box, covered: []const Box, node_widths: []const i32, node_shapes: []const LabelShape, exit_widths: []const i32, portal_widths: []const i32, line_height: i32, clearance: i32) void {
        var taken: [TAKEN_CAPACITY]Box = undefined;
        var taken_count = takeCovered(&taken, covered);
        taken_count += self.takeMarkers(taken[taken_count..]);
        self.labelNodes(label_area, self.label_order[0..self.node_count], node_widths, node_shapes, line_height, clearance, &taken, &taken_count);
        self.labelExits(label_area, exit_widths, line_height, &taken, &taken_count);
        for (self.portals[0..self.portal_count], portal_widths[0..self.portal_count]) |*portal, width| {
            portal.label = claimSpot(label_area, &taken, &taken_count, portal.x, portal.y, width, line_height, NODE_CLEARANCE);
        }
    }

    /// Only while several regions show, after placeLabels: around each region, the first spot that touches no system, name, exit, gate or `covered` box, else the least crowded, inside `label_area`; `widths` are by place in `regions`.
    pub fn placeRegionLabels(self: *Layout, label_area: Box, covered: []const Box, widths: []const i32, line_height: i32) void {
        if (self.regions.count < 2) return;
        var taken: [TAKEN_CAPACITY + MAX_REGIONS]Box = undefined;
        var taken_count = takeCovered(&taken, covered);
        taken_count += self.takeMarkers(taken[taken_count..]);
        for (self.nodes[0..self.node_count]) |node| {
            taken[taken_count] = node.label orelse continue;
            taken_count += 1;
        }
        for (self.exits[0..self.exit_count]) |exit| {
            const label = exit.label orelse continue;
            taken[taken_count] = chipBox(label);
            taken_count += 1;
        }
        for (self.portals[0..self.portal_count]) |portal| {
            const label = portal.label orelse continue;
            taken[taken_count] = chipBox(label);
            taken_count += 1;
        }
        for (self.region_areas[0..self.regions.count], widths[0..self.regions.count], self.region_labels[0..self.regions.count]) |around, width, *region_label| {
            region_label.* = self.leastCrowdedSpot(label_area, around, width, line_height, taken[0..taken_count]);
            taken[taken_count] = region_label.* orelse continue;
            taken_count += 1;
        }
    }

    /// Null when no spot lies inside `label_area`.
    fn leastCrowdedSpot(self: *const Layout, label_area: Box, around: Box, width: i32, line_height: i32, taken: []const Box) ?Box {
        var best: ?Box = null;
        var best_crowding: usize = std.math.maxInt(usize);
        for (REGION_LABEL_SPOTS) |spot| {
            const box = spot.place(around, width, line_height);
            if (!label_area.contains(box)) continue;
            const crowding = self.crowdingAt(box, taken, best_crowding);
            if (crowding >= best_crowding) continue;
            best = box;
            best_crowding = crowding;
            if (crowding == 0) break;
        }
        return best;
    }

    /// What `box` touches, each of `taken` at COVERING_COST and each gate at one, counted up to `limit`, past which it can't win.
    fn crowdingAt(self: *const Layout, box: Box, taken: []const Box, limit: usize) usize {
        var count: usize = 0;
        for (taken) |other| {
            if (box.overlaps(other)) count += COVERING_COST;
        }
        for (self.exits[0..self.exit_count]) |exit| {
            if (count >= limit) return count;
            const node = self.nodes[exit.from_index];
            if (segmentCrosses(box, .{ .x = node.x, .y = node.y }, .{ .x = exit.x, .y = exit.y })) count += 1;
        }
        for (self.edges[0..self.edge_count]) |edge| {
            if (count >= limit) return count;
            const first = self.nodes[edge.first_index];
            const second = self.nodes[edge.second_index];
            // A curve strays at most half its bend off the line, and a pixel more in rounding.
            const stray: i32 = @as(i32, @intFromFloat(@ceil(@abs(edge.bend) / 2))) + 1;
            const reach: Box = .{ .left = @min(first.x, second.x) - stray, .top = @min(first.y, second.y) - stray, .right = @max(first.x, second.x) + stray, .bottom = @max(first.y, second.y) + stray };
            if (!box.overlaps(reach)) continue;
            var point_buffer: [CURVE_SEGMENTS + 1]PixelPoint = undefined;
            const points = self.edgePoints(edge, &point_buffer);
            for (points[0 .. points.len - 1], points[1..]) |from, to| {
                if (!segmentCrosses(box, from, to)) continue;
                count += 1;
                break;
            }
        }
        return count;
    }

    /// Like placeLabels inside the area the map fits to, first come first served along `order`, places in `nodes`; a node left out keeps no label.
    pub fn placeLabelsInOrder(self: *Layout, order: []const u16, node_widths: []const i32, exit_widths: []const i32, line_height: i32) void {
        var taken: [TAKEN_CAPACITY]Box = undefined;
        var taken_count = self.takeMarkers(&taken);
        self.labelNodes(self.area, order, node_widths, &.{}, line_height, NODE_CLEARANCE, &taken, &taken_count);
        self.labelExits(self.area, exit_widths, line_height, &taken, &taken_count);
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

    /// The system whose name is under the cursor; placed labels never overlap, so the first is the only one.
    pub fn labelAt(self: *const Layout, x: i32, y: i32) ?u16 {
        for (self.nodes[0..self.node_count], 0..) |node, index| {
            const label = node.label orelse continue;
            if (label.containsPoint(x, y)) return @intCast(index);
        }
        return null;
    }

    /// The exit whose name, with its padding, is under the cursor; placed labels never overlap, so the first is the only one.
    pub fn exitLabelAt(self: *const Layout, x: i32, y: i32) ?u16 {
        for (self.exits[0..self.exit_count], 0..) |exit, index| {
            const label = exit.label orelse continue;
            if (chipBox(label).containsPoint(x, y)) return @intCast(index);
        }
        return null;
    }

    /// The region whose name is under the cursor, else the one with the system nearest it; null with no systems.
    pub fn regionNear(self: *const Layout, x: i32, y: i32) ?RegionIndex {
        for (self.region_labels[0..self.regions.count], self.regions.slice()) |region_label, region| {
            const label = region_label orelse continue;
            if (label.containsPoint(x, y)) return region;
        }
        var nearest: ?RegionIndex = null;
        var nearest_distance: i64 = std.math.maxInt(i64);
        for (self.nodes[0..self.node_count]) |node| {
            // Wide, as a zoomed-in map puts far systems well off the area.
            const delta_x: i64 = node.x - x;
            const delta_y: i64 = node.y - y;
            const distance = delta_x * delta_x + delta_y * delta_y;
            if (distance < nearest_distance) {
                nearest_distance = distance;
                nearest = universe.systemInfo(node.system).region;
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

    pub fn nodeOf(self: *const Layout, system: SystemIndex) ?u16 {
        const index = self.node_index[system];
        return if (index == NO_NODE) null else index;
    }

    fn hasGathered(self: *const Layout, regions: Regions) bool {
        const gathered = self.gathered orelse return false;
        return std.mem.eql(RegionIndex, gathered.slice(), regions.slice());
    }

    /// The systems and gates among `regions`, and where each system sits on CCP's map, none of which a pan or zoom changes.
    fn gather(self: *Layout, regions: Regions) void {
        self.clearNodes();
        self.regions = regions;
        self.gathered = regions;
        self.offsets = packRegions(regions.slice());
        self.bounds = .{};
        self.region_bounds = @splat(.{});
        for (0..universe.SYSTEM_COUNT) |index| {
            const system: SystemIndex = @intCast(index);
            const info = universe.systemInfo(system);
            const slot = regions.indexOf(info.region) orelse continue;
            const point = self.mapPoint(info);
            self.bounds.include(point);
            self.region_bounds[slot].include(point);
            self.addNode(system, point);
        }
        for (0..self.node_count) |index| {
            var links = universe.neighbours(self.nodes[index].system);
            while (links.next()) |neighbour| self.addGate(@intCast(index), neighbour);
        }
        self.sortLabelOrder();
    }

    fn clearNodes(self: *Layout) void {
        for (self.nodes[0..self.node_count]) |node| self.node_index[node.system] = NO_NODE;
        self.node_count = 0;
        self.edge_count = 0;
        self.exit_count = 0;
        self.portal_count = 0;
    }

    /// A system listed twice keeps its first place for nodeOf.
    fn addNode(self: *Layout, system: SystemIndex, point: MapPoint) void {
        if (self.node_index[system] == NO_NODE) self.node_index[system] = @intCast(self.node_count);
        self.nodes[self.node_count] = .{ .system = system, .x = 0, .y = 0 };
        self.points[self.node_count] = point;
        self.node_count += 1;
    }

    fn sortLabelOrder(self: *Layout) void {
        const order = self.label_order[0..self.node_count];
        for (order, 0..) |*slot, index| slot.* = @intCast(index);
        std.mem.sort(u16, order, self, moreConnected);
    }

    /// Where a system sits once its region's diagram has moved; one outside `regions` stays at CCP's place.
    fn mapPoint(self: *const Layout, info: universe.SystemInfo) MapPoint {
        const offset = if (self.regions.indexOf(info.region)) |slot| self.offsets[slot] else MapPoint{ .x = 0, .y = 0 };
        return .{ .x = @as(i32, info.x) + offset.x, .y = @as(i32, info.y) + offset.y };
    }

    /// Clears their labels, which no longer fit where they moved to.
    fn placeNodes(self: *Layout, fit: Fit) void {
        for (self.nodes[0..self.node_count], self.points[0..self.node_count]) |*node, point| {
            node.x = fit.pixelX(point.x);
            node.y = fit.pixelY(point.y);
            node.label = null;
        }
    }

    /// Each a short step from its system, aimed on CCP's map rather than in pixels, so it still points the right way with no other system to scale by.
    fn placeExits(self: *Layout) void {
        for (self.exits[0..self.exit_count], self.exit_steps[0..self.exit_count]) |*exit, step| {
            const node = self.nodes[exit.from_index];
            exit.x = node.x + @as(i32, @intFromFloat(@round(step[0] * EXIT_LENGTH)));
            exit.y = node.y + @as(i32, @intFromFloat(@round(step[1] * EXIT_LENGTH)));
            exit.label = null;
        }
    }

    /// Returns how many it took.
    fn takeMarkers(self: *const Layout, taken: []Box) usize {
        var taken_count: usize = 0;
        for (self.nodes[0..self.node_count]) |node| {
            taken[taken_count] = markerBox(node.x, node.y);
            taken_count += 1;
        }
        for (self.exits[0..self.exit_count]) |exit| {
            taken[taken_count] = markerBox(exit.x, exit.y);
            taken_count += 1;
        }
        for (self.portals[0..self.portal_count]) |portal| {
            taken[taken_count] = markerBox(portal.x, portal.y);
            taken_count += 1;
        }
        return taken_count;
    }

    fn labelNodes(self: *Layout, label_area: Box, order: []const u16, node_widths: []const i32, node_shapes: []const LabelShape, line_height: i32, clearance: i32, taken: []Box, taken_count: *usize) void {
        for (order) |index| {
            const node = &self.nodes[index];
            const shape: LabelShape = if (node_shapes.len == 0) .{} else node_shapes[index];
            node.label = claimSpot(label_area, taken, taken_count, node.x, node.y, node_widths[index], line_height * shape.line_count, @max(clearance, shape.clearance));
        }
    }

    fn labelExits(self: *Layout, label_area: Box, exit_widths: []const i32, line_height: i32, taken: []Box, taken_count: *usize) void {
        for (self.exits[0..self.exit_count], exit_widths[0..self.exit_count]) |*exit, width| {
            exit.label = claimSpot(label_area, taken, taken_count, exit.x, exit.y, width, line_height, NODE_CLEARANCE);
        }
    }

    fn addGate(self: *Layout, index: u16, neighbour: SystemIndex) void {
        const system = self.nodes[index].system;
        const info = universe.systemInfo(system);
        const other = universe.systemInfo(neighbour);
        if (!self.regions.contains(other.region)) {
            self.addExit(index, neighbour, info, other);
            return;
        }
        // Each gate is seen from both ends, so only the lower system's end adds it.
        if (neighbour < system or self.edge_count == MAX_EDGES) return;
        const second = self.nodeOf(neighbour) orelse return;
        const kind: GateKind = if (other.region != info.region) .between_regions else if (other.constellation == info.constellation) .within_constellation else .within_region;
        self.edges[self.edge_count] = .{ .first_index = index, .second_index = second, .kind = kind };
        self.edge_count += 1;
    }

    /// The least bend, as Edge.bend, that keeps the line between two nodes BEND_CLEARANCE off every other system; one near either end is passed regardless.
    fn bendAround(self: *const Layout, first_index: u16, second_index: u16) f32 {
        const from = vectorOf(self.nodes[first_index]);
        const along = vectorOf(self.nodes[second_index]) - from;
        const length = @sqrt(@reduce(.Add, along * along));
        if (length == 0) return 0;
        const unit = along / @as(Vector, @splat(length));
        const left: Vector = .{ unit[1], -unit[0] };

        // A bend puts the curve 2·bend·progress·(1-progress) off the line, so each system in the way rules out one span of bends.
        var blocked: [MAX_NODES][2]f32 = undefined;
        var blocked_count: usize = 0;
        for (self.nodes[0..self.node_count], 0..) |node, index| {
            if (index == first_index or index == second_index) continue;
            const offset = vectorOf(node) - from;
            const side = @reduce(.Add, offset * left);
            if (@abs(side) >= BEND_CLEARANCE) continue;
            const past = @reduce(.Add, offset * unit);
            if (past < BEND_CLEARANCE or length - past < BEND_CLEARANCE) continue;
            const progress = past / length;
            const spread = 2 * progress * (1 - progress);
            blocked[blocked_count] = .{ (side - BEND_CLEARANCE) / spread, (side + BEND_CLEARANCE) / spread };
            blocked_count += 1;
        }

        // The least bend outside every span is straight, or one of their ends.
        var best: f32 = 0;
        var best_size = std.math.inf(f32);
        for (0..blocked_count * 2 + 1) |candidate_index| {
            const candidate = if (candidate_index == 0) 0 else blocked[(candidate_index - 1) / 2][(candidate_index - 1) % 2];
            if (@abs(candidate) >= best_size or isBlocked(blocked[0..blocked_count], candidate)) continue;
            best = candidate;
            best_size = @abs(candidate);
        }
        return best;
    }

    /// Along `edge` as straight pieces joining the points, curved by its bend; `buffer` holds what's returned.
    pub fn edgePoints(self: *const Layout, edge: Edge, buffer: *[CURVE_SEGMENTS + 1]PixelPoint) []const PixelPoint {
        const first = self.nodes[edge.first_index];
        const second = self.nodes[edge.second_index];
        buffer[0] = .{ .x = first.x, .y = first.y };
        if (edge.bend == 0) {
            buffer[1] = .{ .x = second.x, .y = second.y };
            return buffer[0..2];
        }
        for (buffer[1..], 1..) |*point, step| {
            const place = self.edgePlace(edge, @as(f32, @floatFromInt(step)) / CURVE_SEGMENTS);
            point.* = .{ .x = @intFromFloat(@round(place[0])), .y = @intFromFloat(@round(place[1])) };
        }
        return buffer;
    }

    /// Where `edge` is `progress` of the way along, from 0 to 1, in sub-pixels; bowed to its left by `bend`.
    pub fn edgePlace(self: *const Layout, edge: Edge, progress: f32) [2]f32 {
        const from = vectorOf(self.nodes[edge.first_index]);
        const along = vectorOf(self.nodes[edge.second_index]) - from;
        const length = @sqrt(@reduce(.Add, along * along));
        if (length == 0) return from;
        const left: Vector = .{ along[1] / length, -along[0] / length };
        return from + along * @as(Vector, @splat(progress)) + left * @as(Vector, @splat(2 * edge.bend * progress * (1 - progress)));
    }

    /// Placed by placeExits.
    fn addExit(self: *Layout, from: u16, destination: SystemIndex, info: universe.SystemInfo, other: universe.SystemInfo) void {
        if (self.exit_count == MAX_EXITS) return;
        self.exit_steps[self.exit_count] = stepToward(info, other);
        self.exits[self.exit_count] = .{ .from_index = from, .destination = destination, .region = other.region, .x = 0, .y = 0 };
        self.exit_count += 1;
    }

    fn moreConnected(self: *const Layout, first: u16, second: u16) bool {
        const first_count = gateCount(self.nodes[first].system);
        const second_count = gateCount(self.nodes[second].system);
        if (first_count != second_count) return first_count > second_count;
        return first < second;
    }
};

/// Two coordinates, for packing regions and bending gates.
const Vector = @Vector(2, f32);

/// The extent of systems on CCP's map.
const Bounds = struct {
    min_x: i32 = std.math.maxInt(i32),
    min_y: i32 = std.math.maxInt(i32),
    max_x: i32 = std.math.minInt(i32),
    max_y: i32 = std.math.minInt(i32),

    fn include(self: *Bounds, point: MapPoint) void {
        self.min_x = @min(self.min_x, point.x);
        self.min_y = @min(self.min_y, point.y);
        self.max_x = @max(self.max_x, point.x);
        self.max_y = @max(self.max_y, point.y);
    }

    fn center(self: Bounds) Vector {
        return .{ centerOf(self.min_x, self.max_x), centerOf(self.min_y, self.max_y) };
    }

    fn size(self: Bounds) Vector {
        return .{ @floatFromInt(self.max_x - self.min_x), @floatFromInt(self.max_y - self.min_y) };
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
            .center_x = centerOf(area.left, area.right),
            .center_y = centerOf(area.top, area.bottom),
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
    center_x: f32,
    center_y: f32,
    view: View = .{},

    fn pixelX(self: Fit, x: i32) i32 {
        const fitted = self.left + @as(f32, @floatFromInt(x - self.origin_x)) * self.scale;
        return @intFromFloat(@round(self.center_x + (fitted - self.center_x) * self.view.zoom + self.view.pan_x));
    }

    fn pixelY(self: Fit, y: i32) i32 {
        const fitted = self.top + @as(f32, @floatFromInt(y - self.origin_y)) * self.scale;
        return @intFromFloat(@round(self.center_y + (fitted - self.center_y) * self.view.zoom + self.view.pan_y));
    }

    fn boxOf(self: Fit, bounds: Bounds) Box {
        return .{ .left = self.pixelX(bounds.min_x), .top = self.pixelY(bounds.min_y), .right = self.pixelX(bounds.max_x), .bottom = self.pixelY(bounds.max_y) };
    }
};

/// Takes the first free spot around `x`,`y` at `clearance` from it, adding it to `taken`; null when none is free or inside `area`.
pub fn claimSpot(area: Box, taken: []Box, taken_count: *usize, x: i32, y: i32, width: i32, line_height: i32, clearance: i32) ?Box {
    const half_width = @divTrunc(width, 2);
    const half_height = @divTrunc(line_height, 2);
    const spots = [_]Box{
        .{ .left = x - half_width, .top = y + clearance, .right = x - half_width + width, .bottom = y + clearance + line_height },
        .{ .left = x - half_width, .top = y - clearance - line_height, .right = x - half_width + width, .bottom = y - clearance },
        .{ .left = x + clearance + EXIT_LABEL_GAP, .top = y - half_height, .right = x + clearance + EXIT_LABEL_GAP + width, .bottom = y - half_height + line_height },
        .{ .left = x - clearance - EXIT_LABEL_GAP - width, .top = y - half_height, .right = x - clearance - EXIT_LABEL_GAP, .bottom = y - half_height + line_height },
    };
    for (spots) |spot| {
        const padded: Box = .{ .left = spot.left - LABEL_SIDE_GAP, .top = spot.top, .right = spot.right + LABEL_SIDE_GAP, .bottom = spot.bottom };
        if (!area.contains(spot) or overlapsAny(padded, taken[0..taken_count.*])) continue;
        taken[taken_count.*] = padded;
        taken_count.* += 1;
        return spot;
    }
    return null;
}

/// A name's padded box: a client tag's chip, or the room a system's or exit's name keeps.
pub fn chipBox(label: Box) Box {
    return .{ .left = label.left - CHIP_PADDING_X, .top = label.top - CHIP_PADDING_Y, .right = label.right + CHIP_PADDING_X, .bottom = label.bottom + CHIP_PADDING_Y };
}

/// How far to move each of `regions`' diagrams, by its place there, so they sit REGION_GAP apart in the directions they lie in New Eden; CCP's own places leave them far apart.
fn packRegions(regions: []const RegionIndex) [MAX_REGIONS]MapPoint {
    var bounds: [MAX_REGIONS]Bounds = @splat(.{});
    for (0..universe.SYSTEM_COUNT) |index| {
        const info = universe.systemInfo(@intCast(index));
        const slot = std.mem.indexOfScalar(RegionIndex, regions, info.region) orelse continue;
        bounds[slot].include(.{ .x = info.x, .y = info.y });
    }
    var centers: [MAX_REGIONS]Vector = undefined;
    var middle: Vector = @splat(0);
    for (bounds[0..regions.len], centers[0..regions.len]) |shown, *region_center| {
        region_center.* = shown.center();
        middle += region_center.*;
    }
    middle /= @splat(@floatFromInt(@max(1, regions.len)));

    // Stacked to start, then pushed apart pair by pair along the line between their real places.
    var places: [MAX_REGIONS]Vector = @splat(middle);
    for (0..PACK_ROUNDS) |_| {
        var has_overlap = false;
        for (0..regions.len) |first| {
            for (first + 1..regions.len) |second| {
                const push = separation(bounds[first], bounds[second], places[second] - places[first], centers[second] - centers[first]) orelse continue;
                places[first] -= push * @as(Vector, @splat(0.5));
                places[second] += push * @as(Vector, @splat(0.5));
                has_overlap = true;
            }
        }
        if (!has_overlap) break;
    }

    var offsets: [MAX_REGIONS]MapPoint = @splat(.{ .x = 0, .y = 0 });
    for (places[0..regions.len], centers[0..regions.len], offsets[0..regions.len]) |place, region_center, *offset| {
        const shift = @round(place - region_center);
        offset.* = .{ .x = @intFromFloat(shift[0]), .y = @intFromFloat(shift[1]) };
    }
    return offsets;
}

/// The push along `direction` that clears two regions' boxes by REGION_GAP, `apart` being the second's place less the first's; null if they're clear.
fn separation(first: Bounds, second: Bounds, apart: Vector, direction: Vector) ?Vector {
    const needed = (first.size() + second.size()) * @as(Vector, @splat(0.5)) + @as(Vector, @splat(REGION_GAP));
    if (@abs(apart[0]) >= needed[0] or @abs(apart[1]) >= needed[1]) return null;
    const length = @sqrt(@reduce(.Add, direction * direction));
    const unit: Vector = if (length > 0) direction / @as(Vector, @splat(length)) else .{ 1, 0 };
    var distance = std.math.inf(f32);
    inline for (0..2) |axis| {
        if (unit[axis] != 0) distance = @min(distance, (needed[axis] - apart[axis] * std.math.sign(unit[axis])) / @abs(unit[axis]));
    }
    // A unit over, so rounding to whole units can't leave them short.
    return unit * @as(Vector, @splat(distance + 1));
}

fn centerOf(low: i32, high: i32) f32 {
    return @as(f32, @floatFromInt(low + high)) / 2;
}

fn markerBox(x: i32, y: i32) Box {
    return .{ .left = x - NODE_CLEARANCE, .top = y - NODE_CLEARANCE, .right = x + NODE_CLEARANCE, .bottom = y + NODE_CLEARANCE };
}

/// The first MAX_COVERED of `covered`, at the start of `taken`.
fn takeCovered(taken: []Box, covered: []const Box) usize {
    const count = @min(covered.len, MAX_COVERED);
    @memcpy(taken[0..count], covered[0..count]);
    return count;
}

fn overlapsAny(box: Box, others: []const Box) bool {
    for (others) |other| {
        if (box.overlaps(other)) return true;
    }
    return false;
}

fn regionLabelSpots() [(2 * REGION_LABEL_STEPS + 2) * 3]RegionLabelSpot {
    const alignments = std.enums.values(RegionLabelSpot.Alignment);
    var spots: [(2 * REGION_LABEL_STEPS + 2) * 3]RegionLabelSpot = undefined;
    var count: usize = 0;
    for ([_]RegionLabelSpot.Side{ .above, .below }) |side| {
        for (0..REGION_LABEL_STEPS) |step| {
            for (alignments) |alignment| {
                spots[count] = .{ .side = side, .alignment = alignment, .step = @intCast(step) };
                count += 1;
            }
        }
    }
    for ([_]RegionLabelSpot.Side{ .inside_top, .inside_bottom }) |side| {
        for (alignments) |alignment| {
            spots[count] = .{ .side = side, .alignment = alignment };
            count += 1;
        }
    }
    return spots;
}

/// Whether the segment touches `box`, by Liang-Barsky clipping.
fn segmentCrosses(box: Box, from: PixelPoint, to: PixelPoint) bool {
    const delta_x: f32 = @floatFromInt(to.x - from.x);
    const delta_y: f32 = @floatFromInt(to.y - from.y);
    // Each pair is how fast the segment heads out past one edge, and how far inside that edge it starts.
    const edges = [_][2]f32{
        .{ -delta_x, @floatFromInt(from.x - box.left) },
        .{ delta_x, @floatFromInt(box.right - from.x) },
        .{ -delta_y, @floatFromInt(from.y - box.top) },
        .{ delta_y, @floatFromInt(box.bottom - from.y) },
    };
    var enter: f32 = 0;
    var leave: f32 = 1;
    for (edges) |edge| {
        const heading = edge[0];
        const inside = edge[1];
        if (heading == 0) {
            if (inside < 0) return false;
            continue;
        }
        const ratio = inside / heading;
        if (heading < 0) enter = @max(enter, ratio) else leave = @min(leave, ratio);
        if (enter > leave) return false;
    }
    return true;
}

/// Strictly inside one of `spans`, so a bend at an end still clears its system.
fn isBlocked(spans: []const [2]f32, bend: f32) bool {
    for (spans) |span| {
        if (bend > span[0] and bend < span[1]) return true;
    }
    return false;
}

fn vectorOf(node: Node) Vector {
    return .{ @floatFromInt(node.x), @floatFromInt(node.y) };
}

fn isListed(systems: []const SystemIndex, system: SystemIndex) bool {
    for (systems) |listed| {
        if (listed == system) return true;
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

/// A unit step from `info` toward `other` on CCP's map; up when they share a place.
fn stepToward(info: universe.SystemInfo, other: universe.SystemInfo) Vector {
    const delta_x: f32 = @floatFromInt(@as(i32, other.x) - info.x);
    const delta_y: f32 = @floatFromInt(@as(i32, other.y) - info.y);
    const length = @sqrt(delta_x * delta_x + delta_y * delta_y);
    return if (length > 0) .{ delta_x / length, delta_y / length } else .{ 0, -1 };
}

const testing = std.testing;

const TEST_AREA: Box = .{ .left = 0, .top = 20, .right = 760, .bottom = 530 };
/// About a 10 px font's width for an average name.
const TEST_LABEL_WIDTH = 36;
const TEST_LINE_HEIGHT = 12;

fn regionNamed(name: []const u8) !RegionIndex {
    for (0..universe.REGION_COUNT) |index| {
        const region: RegionIndex = @intCast(index);
        if (std.mem.eql(u8, universe.regionName(region), name)) return region;
    }
    return error.TestExpectedRegion;
}

test "every region's systems and gates fit their arrays, and stay inside the area" {
    var layout: Layout = .{};
    for (0..universe.REGION_COUNT) |index| {
        const region: RegionIndex = @intCast(index);
        layout.build(.one(region), TEST_AREA);
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
        try testing.expect(gate_count / 2 <= MAX_REGION_EDGES);
        try testing.expect(exit_count <= MAX_REGION_EXITS);
        try testing.expectEqual(gate_count / 2, layout.edge_count);
        try testing.expectEqual(exit_count, layout.exit_count);
    }
}

test "a region's map keeps the shape of its gates" {
    var layout: Layout = .{};
    layout.build(.one(try regionNamed("The Forge")), TEST_AREA);
    const jita = layout.nodeOf(universe.findSystem("Jita").?).?;
    const perimeter = layout.nodeOf(universe.findSystem("Perimeter").?).?;
    const distance = distanceSquared(layout.nodes[jita].x, layout.nodes[jita].y, layout.nodes[perimeter].x, layout.nodes[perimeter].y);
    try testing.expect(distance > 0);
    try testing.expect(distance < 100 * 100);
    try testing.expect(layout.nodeOf(universe.findSystem("Amarr").?) == null);
}

test "rebuilding for a new view matches a layout built fresh for it" {
    var regions: Regions = .one(try regionNamed("Delve"));
    try testing.expect(regions.add(try regionNamed("Fountain")));
    var reused: Layout = .{};
    reused.build(regions, TEST_AREA);
    const view: View = (View{}).zoomedAt(TEST_AREA, 300, 200, 3).panned(TEST_AREA, -40, 25);
    reused.view = view;
    reused.build(regions, TEST_AREA);
    var fresh: Layout = .{ .view = view };
    fresh.build(regions, TEST_AREA);

    try testing.expectEqual(fresh.node_count, reused.node_count);
    try testing.expectEqualSlices(Node, fresh.nodes[0..fresh.node_count], reused.nodes[0..reused.node_count]);
    try testing.expectEqualSlices(Edge, fresh.edges[0..fresh.edge_count], reused.edges[0..reused.edge_count]);
    try testing.expectEqualSlices(Exit, fresh.exits[0..fresh.exit_count], reused.exits[0..reused.exit_count]);
}

test "switching regions forgets the systems no longer shown" {
    var layout: Layout = .{};
    layout.build(.one(try regionNamed("The Forge")), TEST_AREA);
    const jita = universe.findSystem("Jita").?;
    try testing.expect(layout.nodeOf(jita) != null);
    layout.build(.one(try regionNamed("Domain")), TEST_AREA);
    try testing.expect(layout.nodeOf(jita) == null);
    try testing.expect(layout.nodeOf(universe.findSystem("Amarr").?) != null);
}

test "a one-system region sits in the middle of the area" {
    var layout: Layout = .{};
    layout.build(.one(try regionNamed("Yasna Zakh")), TEST_AREA);
    try testing.expectEqual(@as(usize, 1), layout.node_count);
    try testing.expectEqual(@divTrunc(TEST_AREA.left + TEST_AREA.right, 2), layout.nodes[0].x);
    try testing.expectEqual(@divTrunc(TEST_AREA.top + TEST_AREA.bottom, 2), layout.nodes[0].y);
}

test "an exit names the region its gate leads to" {
    var layout: Layout = .{};
    layout.build(.one(try regionNamed("The Forge")), TEST_AREA);
    const perimeter = universe.findSystem("Perimeter").?;
    var has_exit = false;
    for (layout.exits[0..layout.exit_count]) |exit| {
        if (layout.nodes[exit.from_index].system != perimeter) continue;
        try testing.expect(!layout.regions.contains(exit.region));
        has_exit = true;
    }
    try testing.expect(has_exit);
}

test "a lone region keeps CCP's place" {
    const offsets = packRegions(&.{try regionNamed("The Forge")});
    try testing.expectEqual(MapPoint{ .x = 0, .y = 0 }, offsets[0]);
}

test "regions shown together clear each other by the gap, on the sides they lie in New Eden" {
    const regions = [_]RegionIndex{ try regionNamed("Delve"), try regionNamed("Fountain"), try regionNamed("Querious"), try regionNamed("Period Basis") };
    const offsets = packRegions(&regions);
    var bounds: [regions.len]Bounds = @splat(.{});
    for (0..universe.SYSTEM_COUNT) |index| {
        const info = universe.systemInfo(@intCast(index));
        const slot = std.mem.indexOfScalar(RegionIndex, &regions, info.region) orelse continue;
        bounds[slot].include(.{ .x = info.x, .y = info.y });
    }
    for (0..regions.len) |first| {
        for (first + 1..regions.len) |second| {
            const real = bounds[second].center() - bounds[first].center();
            const shift: Vector = .{ @floatFromInt(offsets[second].x - offsets[first].x), @floatFromInt(offsets[second].y - offsets[first].y) };
            const apart = real + shift;
            const needed = (bounds[first].size() + bounds[second].size()) * @as(Vector, @splat(0.5)) + @as(Vector, @splat(REGION_GAP));
            try testing.expect(@abs(apart[0]) >= needed[0] or @abs(apart[1]) >= needed[1]);
            const real_sides: [2]f32 = real;
            const apart_sides: [2]f32 = apart;
            const axis: usize = if (@abs(real_sides[0]) > @abs(real_sides[1])) 0 else 1;
            try testing.expectEqual(std.math.sign(real_sides[axis]), std.math.sign(apart_sides[axis]));
        }
    }
}

test "a gate between two regions shown is an edge rather than an exit" {
    const dodixie = universe.findSystem("Dodixie").?;
    const meves = universe.findSystem("Meves").?;
    var regions: Regions = .one(universe.systemInfo(dodixie).region);
    try testing.expect(regions.add(universe.systemInfo(meves).region));
    var layout: Layout = .{};
    layout.build(regions, TEST_AREA);
    for (layout.exits[0..layout.exit_count]) |exit| try testing.expect(exit.destination != meves);
    const dodixie_index = layout.nodeOf(dodixie).?;
    const meves_index = layout.nodeOf(meves).?;
    var has_edge = false;
    for (layout.edges[0..layout.edge_count]) |edge| {
        const joins = (edge.first_index == dodixie_index and edge.second_index == meves_index) or (edge.first_index == meves_index and edge.second_index == dodixie_index);
        if (!joins) continue;
        try testing.expectEqual(GateKind.between_regions, edge.kind);
        has_edge = true;
    }
    try testing.expect(has_edge);
}

test "a gate with nothing in its way stays straight" {
    var layout: Layout = .{};
    layout.nodes[0] = .{ .system = 0, .x = 0, .y = 0 };
    layout.nodes[1] = .{ .system = 1, .x = 100, .y = 0 };
    layout.nodes[2] = .{ .system = 2, .x = 50, .y = 40 };
    layout.node_count = 3;
    try testing.expectEqual(@as(f32, 0), layout.bendAround(0, 1));
}

test "a gate bends around a system in its way, to the nearer side and by no more than it must" {
    var layout: Layout = .{};
    layout.nodes[0] = .{ .system = 0, .x = 0, .y = 0 };
    layout.nodes[1] = .{ .system = 1, .x = 100, .y = 0 };
    // Just below the line, so passing above it bends least.
    layout.nodes[2] = .{ .system = 2, .x = 50, .y = 2 };
    layout.node_count = 3;
    const bend = layout.bendAround(0, 1);
    try testing.expectEqual(@as(f32, 12), bend);

    var point_buffer: [CURVE_SEGMENTS + 1]PixelPoint = undefined;
    const points = layout.edgePoints(.{ .first_index = 0, .second_index = 1, .kind = .between_regions, .bend = bend }, &point_buffer);
    try testing.expectEqual(PixelPoint{ .x = 0, .y = 0 }, points[0]);
    try testing.expectEqual(PixelPoint{ .x = 100, .y = 0 }, points[points.len - 1]);
    try testing.expectEqual(PixelPoint{ .x = 50, .y = -6 }, points[CURVE_SEGMENTS / 2]);
}

test "a gate goes round the side that bends least when systems crowd the other" {
    var layout: Layout = .{};
    layout.nodes[0] = .{ .system = 0, .x = 0, .y = 0 };
    layout.nodes[1] = .{ .system = 1, .x = 100, .y = 0 };
    layout.nodes[2] = .{ .system = 2, .x = 50, .y = 0 };
    layout.nodes[3] = .{ .system = 3, .x = 50, .y = -6 };
    layout.node_count = 4;
    // Up has to clear the one above as well, a bend of 28, so down's 16 wins.
    try testing.expectEqual(@as(f32, -16), layout.bendAround(0, 1));
}

test "a segment crosses a box it passes through, and not one it misses" {
    const box: Box = .{ .left = 10, .top = 10, .right = 20, .bottom = 20 };
    try testing.expect(segmentCrosses(box, .{ .x = 0, .y = 15 }, .{ .x = 30, .y = 15 }));
    try testing.expect(segmentCrosses(box, .{ .x = 12, .y = 12 }, .{ .x = 14, .y = 14 }));
    try testing.expect(!segmentCrosses(box, .{ .x = 0, .y = 0 }, .{ .x = 30, .y = 5 }));
    try testing.expect(segmentCrosses(box, .{ .x = 0, .y = 30 }, .{ .x = 30, .y = 0 }));
    try testing.expect(!segmentCrosses(box, .{ .x = 0, .y = 15 }, .{ .x = 5, .y = 15 }));
}

test "region names stay inside the area and clear of each other, and a lone region has none" {
    const widths: [MAX_NODES]i32 = @splat(TEST_LABEL_WIDTH);
    const exit_widths: [MAX_EXITS]i32 = @splat(TEST_LABEL_WIDTH);
    const region_widths: [MAX_REGIONS]i32 = @splat(90);
    var regions: Regions = .one(try regionNamed("Delve"));
    var layout: Layout = .{};
    layout.build(regions, TEST_AREA);
    layout.placeLabels(TEST_AREA, &.{}, &widths, &.{}, &exit_widths, &.{}, TEST_LINE_HEIGHT, NODE_CLEARANCE);
    layout.placeRegionLabels(TEST_AREA, &.{}, &region_widths, 24);
    try testing.expect(layout.region_labels[0] == null);

    try testing.expect(regions.add(try regionNamed("Fountain")));
    try testing.expect(regions.add(try regionNamed("Querious")));
    layout.build(regions, TEST_AREA);
    layout.placeLabels(TEST_AREA, &.{}, &widths, &.{}, &exit_widths, &.{}, TEST_LINE_HEIGHT, NODE_CLEARANCE);
    layout.placeRegionLabels(TEST_AREA, &.{}, &region_widths, 24);
    for (layout.region_labels[0..regions.count], 0..) |region_label, index| {
        const label = region_label.?;
        try testing.expect(TEST_AREA.contains(label));
        for (layout.region_labels[index + 1 .. regions.count]) |other| try testing.expect(!label.overlaps(other.?));
        for (layout.nodes[0..layout.node_count]) |node| {
            if (node.label) |name| try testing.expect(!label.overlaps(name));
        }
    }
}

test "the four largest regions together fit the arrays and the area" {
    var sizes: [universe.REGION_COUNT]usize = @splat(0);
    for (0..universe.SYSTEM_COUNT) |index| sizes[universe.systemInfo(@intCast(index)).region] += 1;
    var regions: Regions = .{};
    for (0..MAX_REGIONS) |_| {
        var largest: RegionIndex = 0;
        for (sizes, 0..) |count, index| {
            if (count > sizes[largest] and !regions.contains(@intCast(index))) largest = @intCast(index);
        }
        try testing.expect(regions.add(largest));
        sizes[largest] = 0;
    }
    var layout: Layout = .{};
    layout.build(regions, TEST_AREA);
    for (layout.nodes[0..layout.node_count]) |node| {
        try testing.expect(node.x >= TEST_AREA.left and node.x < TEST_AREA.right);
        try testing.expect(node.y >= TEST_AREA.top and node.y < TEST_AREA.bottom);
    }
}

test "toggling a region adds it and takes it out, but never the last one" {
    var regions: Regions = .one(0);
    try testing.expectEqual(Toggle.last, regions.toggle(0));
    try testing.expectEqual(Toggle.added, regions.toggle(1));
    try testing.expectEqual(Toggle.added, regions.toggle(2));
    try testing.expectEqual(Toggle.removed, regions.toggle(1));
    try testing.expectEqualSlices(RegionIndex, &.{ 0, 2 }, regions.slice());
}

test "toggling a region into a full set drops the earliest pick" {
    var regions: Regions = .one(0);
    for (1..MAX_REGIONS) |region| _ = regions.toggle(@intCast(region));
    try testing.expectEqual(Toggle{ .replaced = 0 }, regions.toggle(9));
    try testing.expectEqualSlices(RegionIndex, &.{ 1, 2, 3, 9 }, regions.slice());
}

test "placed labels never overlap each other or a marker, and stay inside the area" {
    var layout: Layout = .{};
    const widths: [universe.MAX_REGION_SYSTEMS]i32 = @splat(TEST_LABEL_WIDTH);
    const exit_widths: [MAX_EXITS]i32 = @splat(TEST_LABEL_WIDTH);
    layout.build(.one(try regionNamed("Domain")), TEST_AREA);
    layout.placeLabels(TEST_AREA, &.{}, &widths, &.{}, &exit_widths, &.{}, TEST_LINE_HEIGHT, NODE_CLEARANCE);

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

test "a label sits at the clearance it's given" {
    var layout: Layout = .{};
    const widths = [_]i32{TEST_LABEL_WIDTH};
    layout.buildAround(&.{universe.findSystem("Jita").?}, TEST_AREA);
    layout.placeLabels(TEST_AREA, &.{}, &widths, &.{}, &.{}, &.{}, TEST_LINE_HEIGHT, 20);
    try testing.expectEqual(layout.nodes[0].y + 20, layout.nodes[0].label.?.top);
}

test "a label's shape gives it more lines and more room from its system" {
    var layout: Layout = .{};
    const widths = [_]i32{TEST_LABEL_WIDTH};
    layout.buildAround(&.{universe.findSystem("Jita").?}, TEST_AREA);
    layout.placeLabels(TEST_AREA, &.{}, &widths, &.{.{ .line_count = 2, .clearance = 30 }}, &.{}, &.{}, TEST_LINE_HEIGHT, 20);
    const label = layout.nodes[0].label.?;
    try testing.expectEqual(layout.nodes[0].y + 30, label.top);
    try testing.expectEqual(2 * TEST_LINE_HEIGHT, label.bottom - label.top);
}

test "a label keeps clear of what covers the map" {
    var layout: Layout = .{};
    const widths = [_]i32{TEST_LABEL_WIDTH};
    layout.buildAround(&.{universe.findSystem("Jita").?}, TEST_AREA);
    layout.placeLabels(TEST_AREA, &.{}, &widths, &.{}, &.{}, &.{}, TEST_LINE_HEIGHT, 20);
    const first_spot = layout.nodes[0].label.?;
    layout.placeLabels(TEST_AREA, &.{first_spot}, &widths, &.{}, &.{}, &.{}, TEST_LINE_HEIGHT, 20);
    try testing.expect(!layout.nodes[0].label.?.overlaps(first_spot));
}

test "buildAround keeps its systems in order, joined by the gates among them alone" {
    var layout: Layout = .{};
    const jita = universe.findSystem("Jita").?;
    const perimeter = universe.findSystem("Perimeter").?;
    layout.buildAround(&.{ jita, perimeter }, TEST_AREA);
    try testing.expectEqual(@as(usize, 2), layout.node_count);
    try testing.expectEqual(jita, layout.nodes[0].system);
    try testing.expectEqual(perimeter, layout.nodes[1].system);
    try testing.expectEqual(@as(usize, 1), layout.edge_count);
    try testing.expectEqual(@as(usize, 0), layout.exit_count);
}

test "buildAround makes a listed system over the border an exit, and ignores other gates" {
    var layout: Layout = .{};
    const dodixie = universe.findSystem("Dodixie").?;
    const meves = universe.findSystem("Meves").?;
    layout.buildAround(&.{ dodixie, meves }, TEST_AREA);
    try testing.expectEqual(@as(usize, 1), layout.node_count);
    try testing.expectEqual(@as(usize, 0), layout.edge_count);
    try testing.expectEqual(@as(usize, 1), layout.exit_count);
    try testing.expectEqual(meves, layout.exits[0].destination);
    // Meves lies down and left of Dodixie, which a lone system has no scale to show.
    try testing.expect(layout.exits[0].x < layout.nodes[0].x);
    try testing.expect(layout.exits[0].y > layout.nodes[0].y);
}

test "placeLabelsInOrder serves the first in its order, and skips those left out" {
    var layout: Layout = .{};
    const jita = universe.findSystem("Jita").?;
    const perimeter = universe.findSystem("Perimeter").?;
    layout.buildAround(&.{ jita, perimeter }, TEST_AREA);
    const widths = [_]i32{ TEST_LABEL_WIDTH, TEST_LABEL_WIDTH };
    layout.placeLabelsInOrder(&.{1}, &widths, &.{}, TEST_LINE_HEIGHT);
    try testing.expect(layout.nodes[1].label != null);
    try testing.expect(layout.nodes[0].label == null);
}

test "nodeAt finds a system within reach and nothing further off" {
    var layout: Layout = .{};
    layout.build(.one(try regionNamed("The Forge")), TEST_AREA);
    const node = layout.nodes[0];
    try testing.expectEqual(@as(?u16, 0), layout.nodeAt(node.x + 2, node.y - 2));
    try testing.expect(layout.nodeAt(TEST_AREA.left, TEST_AREA.top) == null);
}

test "regionNear gives the region of the system nearest the cursor, however far off" {
    var layout: Layout = .{};
    const forge = try regionNamed("The Forge");
    const domain = try regionNamed("Domain");
    layout.build(.one(forge), TEST_AREA);
    try testing.expectEqual(@as(?RegionIndex, forge), layout.regionNear(TEST_AREA.left, TEST_AREA.top));
    var regions: Regions = .one(forge);
    _ = regions.add(domain);
    layout.build(regions, TEST_AREA);
    for (layout.nodes[0..layout.node_count]) |node| {
        try testing.expectEqual(@as(?RegionIndex, universe.systemInfo(node.system).region), layout.regionNear(node.x, node.y));
    }
}

test "zooming keeps the map's point under the cursor" {
    var layout: Layout = .{};
    layout.build(.one(try regionNamed("The Forge")), TEST_AREA);
    const node = layout.nodes[0];
    layout.view = layout.view.zoomedAt(TEST_AREA, node.x, node.y, 2);
    layout.build(.one(try regionNamed("The Forge")), TEST_AREA);
    try testing.expect(@abs(layout.nodes[0].x - node.x) <= 1);
    try testing.expect(@abs(layout.nodes[0].y - node.y) <= 1);
}

test "the view stops at full fit and at its largest zoom" {
    try testing.expect((View{}).zoomedAt(TEST_AREA, 100, 100, 0.5).isFitted());
    try testing.expectEqual(MAX_ZOOM, (View{ .zoom = 7 }).zoomedAt(TEST_AREA, 100, 100, 4).zoom);
}

test "zooming back out to full fit keeps the map within half the area of its place" {
    const zoomed = (View{}).zoomedAt(TEST_AREA, 40, 60, 4);
    const fitted = zoomed.zoomedAt(TEST_AREA, 700, 500, 0.25);
    try testing.expect(fitted.isFitted());
    try testing.expect(@abs(fitted.pan_x) <= 380);
    try testing.expect(@abs(fitted.pan_y) <= 255);
}

test "panning reaches half the area at full fit, and more as the map zooms" {
    try testing.expectEqual(@as(f32, 50), (View{}).panned(TEST_AREA, 50, 50).pan_x);
    try testing.expectEqual(@as(f32, -380), (View{}).panned(TEST_AREA, -9999, 0).pan_x);
    const zoomed: View = .{ .zoom = 2 };
    try testing.expectEqual(@as(f32, 760), zoomed.panned(TEST_AREA, 9999, 0).pan_x);
}

test "a system zoomed off the area loses its label" {
    var layout: Layout = .{};
    layout.view = (View{}).zoomedAt(TEST_AREA, TEST_AREA.left, TEST_AREA.top, MAX_ZOOM);
    layout.build(.one(try regionNamed("The Forge")), TEST_AREA);
    const widths: [universe.MAX_REGION_SYSTEMS]i32 = @splat(TEST_LABEL_WIDTH);
    const exit_widths: [MAX_EXITS]i32 = @splat(TEST_LABEL_WIDTH);
    layout.placeLabels(TEST_AREA, &.{}, &widths, &.{}, &exit_widths, &.{}, TEST_LINE_HEIGHT, NODE_CLEARANCE);
    for (layout.nodes[0..layout.node_count]) |node| {
        if (!TEST_AREA.contains(.{ .left = node.x, .top = node.y, .right = node.x, .bottom = node.y })) try testing.expect(node.label == null);
    }
}

test "exitLabelAt finds an exit by its padded name, and not past it" {
    var layout: Layout = .{};
    layout.exits[0] = .{ .from_index = 0, .destination = 1, .region = 0, .x = 0, .y = 0 };
    layout.exits[1] = .{ .from_index = 0, .destination = 2, .region = 0, .x = 0, .y = 0, .label = .{ .left = 10, .top = 10, .right = 50, .bottom = 20 } };
    layout.exit_count = 2;
    try testing.expectEqual(@as(?u16, 1), layout.exitLabelAt(10 - CHIP_PADDING_X, 20 + CHIP_PADDING_Y - 1));
    try testing.expectEqual(@as(?u16, 1), layout.exitLabelAt(50 + CHIP_PADDING_X - 1, 10 - CHIP_PADDING_Y));
    try testing.expect(layout.exitLabelAt(50 + CHIP_PADDING_X, 15) == null);
    try testing.expect(layout.exitLabelAt(30, 20 + CHIP_PADDING_Y) == null);
}

test "labelAt finds a system by its name, and not past the label" {
    var layout: Layout = .{};
    layout.nodes[0] = .{ .system = 0, .x = 0, .y = 0 };
    layout.nodes[1] = .{ .system = 1, .x = 0, .y = 0, .label = .{ .left = 10, .top = 10, .right = 50, .bottom = 20 } };
    layout.node_count = 2;
    try testing.expectEqual(@as(?u16, 1), layout.labelAt(10, 19));
    try testing.expect(layout.labelAt(50, 15) == null);
}

test "a portal points between its system's gates, once a hub, and only for a system shown" {
    var layout: Layout = .{};
    layout.build(.one(try regionNamed("The Forge")), TEST_AREA);
    const obe = universe.findSystem("Obe").?;
    layout.setPortals(&.{ .{ .system = obe, .target = .{ .hub = .thera } }, .{ .system = obe, .target = .{ .hub = .thera } }, .{ .system = universe.findSystem("Amarr").?, .target = .{ .hub = .thera } } });
    try testing.expectEqual(@as(usize, 1), layout.portal_count);
    const step = layout.portal_steps[0];
    const info = universe.systemInfo(obe);
    var links = universe.neighbours(obe);
    while (links.next()) |neighbour| {
        const other = universe.systemInfo(neighbour);
        const toward: Vector = .{ @floatFromInt(@as(i32, other.x) - info.x), @floatFromInt(@as(i32, other.y) - info.y) };
        const unit = toward / @as(Vector, @splat(@sqrt(@reduce(.Add, toward * toward))));
        // Pointing at a gate would draw the stub over it.
        try testing.expect(@reduce(.Add, unit * step) < 0.95);
    }
    layout.build(.one(try regionNamed("Domain")), TEST_AREA);
    try testing.expectEqual(@as(usize, 0), layout.portal_count);
}
