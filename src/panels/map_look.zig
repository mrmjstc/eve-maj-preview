//! The Map Panel's look: its sizes, footer buttons, map markers, legend, and tooltip and menu text; no I/O.
const std = @import("std");
const types = @import("../config/types.zig");
const display_mod = @import("../config/display.zig");
const list_look = @import("list_look.zig");
const panel_look = @import("panel_look.zig");
const popup_look = @import("popup_look.zig");
const universe = @import("../map/universe.zig");
const jump_range = @import("../map/jump_range.zig");
const storms_mod = @import("../map/storms.zig");
const incursions_mod = @import("../map/incursions.zig");
const layout = @import("../map/layout.zig");
const search = @import("../map/search.zig");
const stats_mod = @import("../map/stats.zig");
const evestars = @import("../map/evestars.zig");
const color = @import("../util/color.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");
const utf8 = @import("../util/utf8.zig");

const Box = layout.Box;
const DisplayConfig = display_mod.DisplayConfig;
const Incursions = incursions_mod.Incursions;
const MapMetric = types.MapMetric;
const RegionIndex = universe.RegionIndex;
const RoutePreference = types.RoutePreference;
const SystemIndex = universe.SystemIndex;
const SystemStats = stats_mod.SystemStats;
const Snapshot = stats_mod.Snapshot;
const Storms = storms_mod.Storms;

/// The most lines a tooltip holds, for a system with everything to report, two overlapping storms included.
pub const TOOLTIP_MAX_LINES = 13;
/// Fits a line's longest text, cut to size past that.
pub const TOOLTIP_LINE_MAX = 128;
/// So the results don't resize as names come and go.
pub const SEARCH_WIDTH: i32 = 280;
const SEARCH_BOX_WIDTH: i32 = 180;
/// Kept clear above the fitted map, for the region's name and figures.
pub const TITLE_BAND: i32 = 46;
pub const TITLE_FONT_SIZE: i32 = 20;
/// Between the map's edges and the title and legend.
pub const OVERLAY_MARGIN: i32 = 10;
/// Inside a legend.
pub const OVERLAY_PADDING: i32 = 6;
const NODE_RADIUS: f32 = 3.5;
/// The dark edge that lifts a marker off the gates running into it.
const MARKER_RIM: f32 = 1.5;
/// Markers grow more slowly than the map, and stop at this.
const MAX_MARKER_SCALE: f32 = 1.8;
/// A soft disc behind each held system, so an alliance's space reads as one patch.
const HOLDER_PATCH_RADIUS: f32 = 22;
const HOLDER_PATCH_ALPHA: u8 = 34;
/// From a system in jump range to its diamond's points, before the marker scale; clear of a hover's ring.
const RANGE_MARK_SIZE: f32 = 9;
/// How far a storm's or incursion's area spreads around its systems and gates, before the marker scale.
const AREA_RADIUS: f32 = 18;
const AREA_ALPHA: u8 = 30;
/// Added over an area, so a storm's core or an incursion's staging system reads stronger.
const AREA_CORE_ALPHA: u8 = 46;
const AREA_RIM_ALPHA: u8 = 170;
const AREA_RIM_THICKNESS = 2;
/// How much of a storm's colour its periphery's gates keep, over a plain gate's.
const STORM_PERIPHERY_PERCENT = 45;
const GRID_SPACING: i32 = 36;
const MAP_CONTROL_SIZE: i32 = 24;
const MAP_CONTROL_GAP: i32 = 4;
const MAP_GLYPH_SIZE: i32 = 5;
/// From this zoom there's room to show a system's security beside its name.
const SECURITY_LABEL_ZOOM: f32 = 2;
/// Before what follows a system's name.
pub const LABEL_SUFFIX_GAP: i32 = 4;
pub const LEGEND_RAMP_WIDTH: i32 = 120;
const LEGEND_RAMP_HEIGHT: i32 = 6;
pub const LEGEND_SWATCH_SIZE: i32 = 8;
/// Between a client's tag and its system's marker.
const CLIENT_TAG_OFFSET: i32 = 14;
const CLIENT_TAG_GAP: i32 = 2;
/// The tag's colour bar, and the room left beside it.
pub const CLIENT_TAG_BAR: i32 = 2;
pub const CLIENT_TAG_PADDING: i32 = 5;
/// Below a legend's title and scale.
const LEGEND_MAX_ROWS = 6;
/// The rows of a range's legend left to name regions, past its total and what the rest sum to.
const RANGE_LEGEND_REGIONS = LEGEND_MAX_ROWS - 2;
/// How much bigger the busiest system's marker is than a quiet one's; kept small so a selected ring stays off its name.
const HEAT_RADIUS_GROWTH: f32 = 1.5;
/// Just outside a client's ring, so neither hides the other.
const INTEL_HALO_RADIUS: f32 = 11;
const INTEL_HALO_PEAK_RADIUS: f32 = 28;
/// Around a marked system's marker.
pub const RING_GAP: f32 = 3;
pub const RING_THICKNESS: f32 = 1.5;
/// The selected system's ring, heavier than a hover's so the two read apart.
pub const FOCUS_RING_THICKNESS: f32 = 2.5;
/// Around the selected system's ring.
pub const FOCUS_OUTLINE_THICKNESS: f32 = 3;
const EXIT_RADIUS: f32 = 2;
/// Half the width of the cross over an avoided system.
const AVOID_MARK_SIZE: i32 = 5;
/// Past this, a line of who's in a system stops naming them.
const MAX_CHARACTERS_NAMED = 4;
/// Fits securityText's longest result.
pub const SECURITY_TEXT_MAX = 8;
/// Lifts -1.0 from 1.7:1 to 4.3:1 against a popup's fill.
const SECURITY_TEXT_LIGHTEN_PERCENT = 40;
/// A region's size, in its tooltip and its summary.
const SYSTEMS_FORMAT = "{d} systems";
/// What a legend sums up past the ones it names.
const OTHERS_FORMAT = "Others ({d})";
/// Between a search result's parts.
const HIT_GAP = "  ";

// The colours below are 0xAARRGGBB, not premultiplied.
pub const BACKGROUND: u32 = 0xFF0E0F12;
const GRID_DOT: u32 = 0xFF1D1F24;
pub const TITLE: u32 = 0xFFC9CCD2;
/// A name with nothing happening at it, a step below the bright NAME those with something do.
pub const LABEL: u32 = 0xFFA9ACB3;
pub const EDGE_LOCAL: u32 = 0xFF5B5F69;
pub const EDGE_CROSS: u32 = 0xFF6E5A7A;
pub const EDGE_HOVER: u32 = 0xFFD5D7DC;
pub const EXIT: u32 = 0xFFC7A95C;
const EXIT_CHIP: u32 = 0xFF2B2517;
const INTEL: u32 = 0xFFFF4B3E;
const INTEL_CLEAR: u32 = 0xFFFFD23F;
/// Reads through every marker colour, and is apart from intel's red and yellow.
const AVOID: u32 = 0xFFFFFFFF;
pub const FOCUS: u32 = 0xFFE8E6E1;
/// The selected system's outline and name chip.
pub const FOCUS_MARK: u32 = 0xFF3A3D45;
/// Magenta, which no security, heat or intel colour comes near.
pub const RANGE: u32 = 0xFFFF4FD8;
/// Dims what a jump range doesn't reach, a step below HEAT_NONE's quiet system.
pub const OUT_OF_RANGE: u32 = 0xFF26282D;
const STORM_ELECTRIC: u32 = 0xFF3FE0E0;
const STORM_EXOTIC: u32 = 0xFFB58CFF;
const STORM_GAMMA: u32 = 0xFF66E07F;
const STORM_PLASMA: u32 = 0xFFFF9D45;
/// Chartreuse, the widest gap left between the storms' and intel's colours.
pub const INCURSION: u32 = 0xFFB5F23A;
const HEAT_NONE: u32 = 0xFF3A3C42;
const HEAT_LOW: u32 = 0xFFD9A441;
const HEAT_HIGH: u32 = 0xFFFF3B30;
/// EVE's own colours, by shown security in tenths from 0 up.
const SECURITY_COLORS = [_]u32{ 0xFFF00000, 0xFFD73000, 0xFFF04800, 0xFFF06000, 0xFFD77700, 0xFFEFEF00, 0xFF8FEF2F, 0xFF00F000, 0xFF00EF47, 0xFF48F0C0, 0xFF2FEFEF };
/// Where null security ends at -1.0, a darker red than 0.0's: EVE paints it all one red, which says nothing across a null region.
const DEEPEST_NULL: u32 = 0xFF8E0A12;
/// From -1.0 up to 1.0.
const SECURITY_SCALE = securityScale();
const HEAT_RAMP = [_]u32{ HEAT_LOW, color.mix(HEAT_HIGH, HEAT_LOW, 33), color.mix(HEAT_HIGH, HEAT_LOW, 66), HEAT_HIGH };
/// By a holder's rank in the region, so its largest are always told apart.
const HOLDER_COLORS = [_]u32{ 0xFF4F9DFF, 0xFFFF7A59, 0xFF54D18C, 0xFFE8C547, 0xFFC77DFF, 0xFF3FD0D8, 0xFFFF6FAE, 0xFF9CCB3B, 0xFFB08D6E, 0xFF8E9BFF };

/// In the footer, left to right.
pub const Button = enum { regions, security, kills, npc_kills, jumps, sovereignty, storms, incursions, follow };
pub const BUTTON_ORDER = std.enums.values(Button);

/// On the map's top right, top to bottom.
pub const MapControl = enum { zoom_in, zoom_out, fit, always_on_top };

pub const HitLabel = struct {
    text: evestars.Text,
    /// Null for a region, which has none.
    security: ?popup_look.Accent = null,
};

/// The panel's sizes for the current settings, in pixels; its width and height are the configured ones.
pub const Metrics = struct {
    header_height: i32,
    footer_height: i32,
};

/// A holder of systems in a region, into Snapshot.holder_ids.
pub const RankedHolder = struct { holder: u16, system_count: u16 };

/// Who holds a region's systems, most first; only these get colours of their own.
pub const HolderRanks = struct {
    holders: [HOLDER_COLORS.len]RankedHolder = undefined,
    count: usize = 0,
    /// Systems held by anyone past the ranked.
    other_count: usize = 0,
    unclaimed_count: usize = 0,

    pub fn fromNodes(snapshot: *const Snapshot, nodes: []const layout.Node) HolderRanks {
        var ranks: HolderRanks = .{};
        var tally: [universe.MAX_REGION_SYSTEMS]RankedHolder = undefined;
        var tally_count: usize = 0;
        counting: for (nodes) |node| {
            const holder = snapshot.systems[node.system].holder;
            if (holder == stats_mod.NO_HOLDER) {
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
        return ranks;
    }

    pub fn colorOf(self: *const HolderRanks, holder: u16) u32 {
        if (holder == stats_mod.NO_HOLDER) return HEAT_NONE;
        for (self.holders[0..self.count], 0..) |ranked, index| {
            if (ranked.holder == holder) return HOLDER_COLORS[index];
        }
        return list_look.MUTED;
    }
};

/// A region's figures for the last hour.
pub const RegionTotals = struct {
    ship_kills: u32 = 0,
    npc_kills: u32 = 0,
    jumps: u32 = 0,

    pub fn fromNodes(snapshot: *const Snapshot, nodes: []const layout.Node) RegionTotals {
        var totals: RegionTotals = .{};
        for (nodes) |node| {
            const stats = snapshot.systems[node.system];
            totals.ship_kills += stats.ship_kills;
            totals.npc_kills += stats.npc_kills;
            totals.jumps += stats.jumps;
        }
        return totals;
    }
};

/// What the map's colours mean, drawn in its bottom left.
pub const Legend = struct {
    title: evestars.Text,
    /// Empty for none; static.
    ramp: []const u32 = &.{},
    ramp_low: evestars.Text = .{},
    ramp_high: evestars.Text = .{},
    rows: [LEGEND_MAX_ROWS]Row = undefined,
    row_count: usize = 0,

    pub const Row = struct { swatch: u32, text: evestars.Text };

    fn add(self: *Legend, swatch: u32, text: evestars.Text) void {
        if (self.row_count == LEGEND_MAX_ROWS) return;
        self.rows[self.row_count] = .{ .swatch = swatch, .text = text };
        self.row_count += 1;
    }
};

/// What a system's tooltip reports; its slices are borrowed for the call.
pub const SystemFacts = struct {
    system: SystemIndex,
    /// Null until the first fetch.
    stats: ?*const Snapshot = null,
    characters: []const []const u8 = &.{},
    /// Null without a live intel pin.
    intel_message: ?[]const u8 = null,
    intel_age_ms: u64 = 0,
    is_avoided: bool = false,
    /// Null with no jump range showing.
    reach: ?*const jump_range.Reach = null,
    /// Null while they're hidden or unknown.
    storms: ?*const Storms = null,
    /// Null while they're hidden or unknown.
    incursions: ?*const Incursions = null,
};

/// Lines of text; owns them, so it can be measured and then drawn.
pub const Tooltip = struct {
    lines: [TOOLTIP_MAX_LINES][TOOLTIP_LINE_MAX]u8 = undefined,
    lengths: [TOOLTIP_MAX_LINES]usize = undefined,
    line_count: usize = 0,
    /// The first line's colour.
    title_color: u32 = list_look.NAME,

    pub fn line(self: *const Tooltip, index: usize) []const u8 {
        return self.lines[index][0..self.lengths[index]];
    }

    /// Per hover, and bounded: a long line is cut, which the reader can see.
    fn add(self: *Tooltip, comptime format: []const u8, args: anytype) void {
        if (self.line_count == TOOLTIP_MAX_LINES) return;
        var writer: std.Io.Writer = .fixed(&self.lines[self.line_count]);
        writer.print(format, args) catch {};
        const written = writer.buffered();
        self.lengths[self.line_count] = utf8.prefixLength(written, if (written.len == TOOLTIP_LINE_MAX) TOOLTIP_LINE_MAX - 1 else written.len);
        self.line_count += 1;
    }
};

pub fn metrics(display: *const DisplayConfig) Metrics {
    const header_height = panel_look.headerHeight(display);
    return .{ .header_height = header_height, .footer_height = panel_look.footerHeight(header_height) };
}

pub fn buttonLabel(button: Button) []const u8 {
    return switch (button) {
        .regions => "Regions",
        .security => "Sec",
        .kills => "Kills",
        .npc_kills => "NPC",
        .jumps => "Jumps",
        .sovereignty => "Sov",
        .storms => "Storms",
        .incursions => "Incursions",
        .follow => "Follow",
    };
}

pub fn buttonAt(width: i32, x: i32) ?Button {
    const index = panel_look.buttonIndexAt(width, BUTTON_ORDER.len, x) orelse return null;
    return BUTTON_ORDER[index];
}

/// What pressing `button` shows on the map; null for one that does something else.
pub fn metricOf(button: Button) ?MapMetric {
    return switch (button) {
        .security => .Security,
        .kills => .ShipKills,
        .npc_kills => .NpcKills,
        .jumps => .Jumps,
        .sovereignty => .Sovereignty,
        .regions, .storms, .incursions, .follow => null,
    };
}

pub fn incursionStateName(state: incursions_mod.State) []const u8 {
    return switch (state) {
        .established => "Established",
        .mobilizing => "Mobilizing",
        .withdrawing => "Withdrawing",
    };
}

pub fn stormName(kind: storms_mod.Kind) []const u8 {
    return switch (kind) {
        .electric => "Electric",
        .exotic => "Exotic",
        .gamma => "Gamma Ray",
        .plasma => "Plasma",
    };
}

pub fn stormColor(kind: storms_mod.Kind) u32 {
    return switch (kind) {
        .electric => STORM_ELECTRIC,
        .exotic => STORM_EXOTIC,
        .gamma => STORM_GAMMA,
        .plasma => STORM_PLASMA,
    };
}

pub fn stormEdgeColor(mark: storms_mod.EdgeMark) u32 {
    const shade = stormColor(mark.kind);
    return if (mark.is_core) shade else color.mix(shade, EDGE_LOCAL, STORM_PERIPHERY_PERCENT);
}

/// Zero for what colours by the system rather than its traffic.
pub fn metricValue(metric: MapMetric, stats: SystemStats) u32 {
    return switch (metric) {
        .Security, .Sovereignty => 0,
        .ShipKills => @as(u32, stats.ship_kills) + stats.pod_kills,
        .NpcKills => stats.npc_kills,
        .Jumps => stats.jumps,
    };
}

/// EVE's scale from 0.0 up, carried on through null security so a region's depths show.
pub fn securityColor(security_tenths: i8) u32 {
    if (security_tenths >= 0) return SECURITY_COLORS[@intCast(@min(security_tenths, SECURITY_COLORS.len - 1))];
    const depth: u32 = @min(@abs(@as(i32, security_tenths)), 10);
    return color.mix(DEEPEST_NULL, SECURITY_COLORS[0], depth * 10);
}

/// For text on the dark panels: `securityColor`, lightened below high security, whose reds and oranges are too dark to read.
pub fn securityTextColor(security_tenths: i8) u32 {
    const shade = securityColor(security_tenths);
    return if (security_tenths >= universe.HIGH_SECURITY_TENTHS) shade else color.lighten(shade, SECURITY_TEXT_LIGHTEN_PERCENT);
}

/// How much bigger a zoom makes a marker.
pub fn markerScale(zoom: f32) f32 {
    return @min(MAX_MARKER_SCALE, @sqrt(zoom));
}

/// How far a system's name sits from it, moving out as the marker grows so selecting a system never needs to move it.
pub fn labelClearance(zoom: f32) i32 {
    return layout.NODE_CLEARANCE + @as(i32, @intFromFloat(@ceil(NODE_RADIUS * (markerScale(zoom) - 1))));
}

pub fn showsSecurityLabel(zoom: f32) bool {
    return zoom >= SECURITY_LABEL_ZOOM;
}

/// The dark gap makes crossing gates read as passing behind.
pub fn drawMarker(canvas: pixel_buffer.Canvas, x: i32, y: i32, radius: f32, marker_color: u32) void {
    pixel_buffer.fillCircle(canvas, x, y, radius + MARKER_RIM, BACKGROUND);
    pixel_buffer.fillCircle(canvas, x, y, radius, marker_color);
}

pub fn drawHolderPatch(canvas: pixel_buffer.Canvas, x: i32, y: i32, scale: f32, holder_color: u32) void {
    pixel_buffer.fillCircle(canvas, x, y, HOLDER_PATCH_RADIUS * scale, color.withAlpha(holder_color, HOLDER_PATCH_ALPHA));
}

/// A diamond, as every other mark on the map is round; drawn twice over, one pixel in, as a single line is too thin to find.
pub fn drawRangeMark(canvas: pixel_buffer.Canvas, x: i32, y: i32, scale: f32) void {
    const size: i32 = @intFromFloat(RANGE_MARK_SIZE * scale);
    for ([_]i32{ size, size - 1 }) |reach| {
        pixel_buffer.drawLine(canvas, x - reach, y, x, y - reach, RANGE);
        pixel_buffer.drawLine(canvas, x, y - reach, x + reach, y, RANGE);
        pixel_buffer.drawLine(canvas, x + reach, y, x, y + reach, RANGE);
        pixel_buffer.drawLine(canvas, x, y + reach, x - reach, y, RANGE);
    }
}

pub fn areaRadius(scale: f32) f32 {
    return AREA_RADIUS * scale;
}

/// A flat tint with a hard rim, so a storm or incursion reads as one front rather than as Sov's soft patches.
pub fn drawArea(canvas: pixel_buffer.Canvas, mask: *const pixel_buffer.Mask, shade: u32) void {
    pixel_buffer.fillMask(canvas, mask, color.withAlpha(shade, AREA_ALPHA));
    pixel_buffer.outlineMask(canvas, mask, AREA_RIM_THICKNESS, color.withAlpha(shade, AREA_RIM_ALPHA));
}

pub fn drawAreaCore(canvas: pixel_buffer.Canvas, mask: *const pixel_buffer.Mask, shade: u32) void {
    pixel_buffer.fillMask(canvas, mask, color.withAlpha(shade, AREA_CORE_ALPHA));
}

/// Dots that move with the map, so a drag shows even over an empty stretch.
pub fn drawGrid(canvas: pixel_buffer.Canvas, area: Box, view: layout.View) void {
    const start_x = area.left + @mod(@as(i32, @intFromFloat(view.pan_x)), GRID_SPACING);
    const start_y = area.top + @mod(@as(i32, @intFromFloat(view.pan_y)), GRID_SPACING);
    var y = start_y;
    while (y < area.bottom) : (y += GRID_SPACING) {
        var x = start_x;
        while (x < area.right) : (x += GRID_SPACING) {
            pixel_buffer.fillRect(canvas, @intCast(x), @intCast(y), 1, 1, GRID_DOT);
        }
    }
}

/// Behind an exit's name, reading as a door out rather than one more system.
pub fn drawExitChip(canvas: pixel_buffer.Canvas, label: Box, is_hovered: bool) void {
    fillLabelChip(canvas, label, if (is_hovered) color.lighten(EXIT_CHIP, 12) else EXIT_CHIP);
}

/// Behind the selected system's name.
pub fn drawFocusChip(canvas: pixel_buffer.Canvas, label: Box) void {
    fillLabelChip(canvas, label, FOCUS_MARK);
}

/// The background of what floats over the map, so the map controls, search box and legend stay matched.
pub fn drawOverlayButton(canvas: pixel_buffer.Canvas, box: Box, is_hovered: bool) void {
    pixel_buffer.fillRoundedRect(canvas, @intCast(box.left), @intCast(box.top), @intCast(box.right - box.left), @intCast(box.bottom - box.top), panel_look.BUTTON_RADIUS, if (is_hovered) EDGE_LOCAL else panel_look.BUTTON_ON);
}

pub fn drawMapControlGlyph(canvas: pixel_buffer.Canvas, box: Box, control: MapControl, is_always_on_top: bool) void {
    const x = @divTrunc(box.left + box.right, 2);
    const y = @divTrunc(box.top + box.bottom, 2);
    const glyph_color = list_look.NAME;
    switch (control) {
        .zoom_in => {
            pixel_buffer.drawLine(canvas, x - MAP_GLYPH_SIZE, y, x + MAP_GLYPH_SIZE, y, glyph_color);
            pixel_buffer.drawLine(canvas, x, y - MAP_GLYPH_SIZE, x, y + MAP_GLYPH_SIZE, glyph_color);
        },
        .zoom_out => pixel_buffer.drawLine(canvas, x - MAP_GLYPH_SIZE, y, x + MAP_GLYPH_SIZE, y, glyph_color),
        .fit => pixel_buffer.drawRectOutline(canvas, x - MAP_GLYPH_SIZE, y - MAP_GLYPH_SIZE, @intCast(2 * MAP_GLYPH_SIZE + 1), @intCast(2 * MAP_GLYPH_SIZE + 1), 1, glyph_color),
        .always_on_top => drawPin(canvas, x, y, is_always_on_top, glyph_color),
    }
}

/// The scale's colours side by side, `line_height` tall around their middle.
pub fn drawRamp(canvas: pixel_buffer.Canvas, left: i32, top: i32, line_height: i32, ramp: []const u32) void {
    const count: i32 = @intCast(ramp.len);
    const y = top + @divTrunc(line_height - LEGEND_RAMP_HEIGHT, 2);
    for (ramp, 0..) |shade, index| {
        const signed_index: i32 = @intCast(index);
        const from = left + @divTrunc(LEGEND_RAMP_WIDTH * signed_index, count);
        const to = left + @divTrunc(LEGEND_RAMP_WIDTH * (signed_index + 1), count);
        pixel_buffer.fillRect(canvas, @intCast(from), @intCast(y), @intCast(to - from), @intCast(LEGEND_RAMP_HEIGHT), shade);
    }
}

/// Beside the marker at `x`,`y`, moved along until it's clear of `taken`; null when it can't stay inside `area`.
pub fn clientTagBox(area: Box, x: i32, y: i32, width: i32, height: i32, taken: []const Box) ?Box {
    const right_left = x + CLIENT_TAG_OFFSET;
    const left = if (right_left + width <= area.right) right_left else x - CLIENT_TAG_OFFSET - width;
    var top = y - @divTrunc(height, 2);
    for (0..taken.len + 1) |_| {
        const box: Box = .{ .left = left, .top = top, .right = left + width, .bottom = top + height };
        if (!area.contains(box)) return null;
        for (taken) |other| {
            if (box.overlaps(other)) break;
        } else return box;
        top += height + CLIENT_TAG_GAP;
    }
    return null;
}

pub fn mapControlBox(area: Box, control: MapControl) Box {
    const index: i32 = @backingInt(control);
    const right = area.right - OVERLAY_MARGIN;
    const top = area.top + OVERLAY_MARGIN + index * (MAP_CONTROL_SIZE + MAP_CONTROL_GAP);
    return .{ .left = right - MAP_CONTROL_SIZE, .top = top, .right = right, .bottom = top + MAP_CONTROL_SIZE };
}

pub fn mapControlAt(area: Box, x: i32, y: i32) ?MapControl {
    for (std.enums.values(MapControl)) |control| {
        const box = mapControlBox(area, control);
        if (x >= box.left and x < box.right and y >= box.top and y < box.bottom) return control;
    }
    return null;
}

/// How warm `value` looks beside the region's busiest, `peak`; a square root, so a quiet system isn't lost next to Jita.
pub fn heatColor(value: u32, peak: u32) u32 {
    if (value == 0 or peak == 0) return HEAT_NONE;
    const percent: u32 = @intFromFloat(heatShare(value, peak) * 100);
    return color.mix(HEAT_HIGH, HEAT_LOW, percent);
}

pub fn markerRadius(value: u32, peak: u32) f32 {
    if (value == 0 or peak == 0) return NODE_RADIUS;
    return NODE_RADIUS + heatShare(value, peak) * HEAT_RADIUS_GROWTH;
}

/// At its largest when new, shrinking evenly to its resting size over `shrink_ms`.
pub fn intelHaloRadius(age_ms: u64, shrink_ms: u64) f32 {
    if (age_ms >= shrink_ms) return INTEL_HALO_RADIUS;
    const share_left = @as(f32, @floatFromInt(shrink_ms - age_ms)) / @as(f32, @floatFromInt(shrink_ms));
    return INTEL_HALO_RADIUS + (INTEL_HALO_PEAK_RADIUS - INTEL_HALO_RADIUS) * share_left;
}

pub fn intelColor(is_clear: bool) u32 {
    return if (is_clear) INTEL_CLEAR else INTEL;
}

pub fn drawIntelHalo(canvas: pixel_buffer.Canvas, x: i32, y: i32, radius: f32, is_clear: bool, freshness_percent: u64) void {
    pixel_buffer.fillCircle(canvas, x, y, radius, intelHaloColor(is_clear, freshness_percent));
    pixel_buffer.drawRing(canvas, x, y, radius, RING_THICKNESS, intelRimColor(is_clear, freshness_percent));
}

/// The stub from a system to where its gate out of the region points.
pub fn drawExit(canvas: pixel_buffer.Canvas, node: layout.Node, exit: layout.Exit, exit_color: u32) void {
    pixel_buffer.drawLine(canvas, node.x, node.y, exit.x, exit.y, exit_color);
    pixel_buffer.fillCircle(canvas, exit.x, exit.y, EXIT_RADIUS, exit_color);
}

/// A cross, which reads through whatever colour the marker under it has.
pub fn drawAvoidMark(canvas: pixel_buffer.Canvas, x: i32, y: i32) void {
    pixel_buffer.drawLine(canvas, x - AVOID_MARK_SIZE, y - AVOID_MARK_SIZE, x + AVOID_MARK_SIZE, y + AVOID_MARK_SIZE, AVOID);
    pixel_buffer.drawLine(canvas, x - AVOID_MARK_SIZE, y + AVOID_MARK_SIZE, x + AVOID_MARK_SIZE, y - AVOID_MARK_SIZE, AVOID);
}

pub fn systemTooltip(facts: SystemFacts) Tooltip {
    var tooltip: Tooltip = .{};
    const info = universe.systemInfo(facts.system);
    tooltip.title_color = securityTextColor(info.security_tenths);
    var security_buf: [SECURITY_TEXT_MAX]u8 = undefined;
    tooltip.add("{s}  {s}", .{ universe.systemName(facts.system), securityText(&security_buf, info.security_tenths) });
    tooltip.add("{s} / {s}", .{ universe.regionName(info.region), universe.constellationName(info.constellation) });

    if (facts.stats) |snapshot| {
        const stats = snapshot.systems[facts.system];
        if (snapshot.has_kills) tooltip.add("Last hour: {d} ships, {d} pods, {d} NPCs", .{ stats.ship_kills, stats.pod_kills, stats.npc_kills });
        if (snapshot.has_jumps) tooltip.add("Last hour: {d} jumps", .{stats.jumps});
        if (snapshot.holderName(facts.system)) |holder| tooltip.add("Held by {s}", .{holder});
    }
    tooltip.add("{d} stations, {d} planets", .{ info.station_count, info.planet_count });
    if (facts.is_avoided) tooltip.add("Routes avoid this system", .{});
    if (facts.reach) |reach| addRange(&tooltip, reach, facts.system);
    if (facts.storms) |storms| addStorms(&tooltip, storms, facts.system);
    if (facts.incursions) |incursions| addIncursion(&tooltip, incursions, facts.system);

    addCharacters(&tooltip, facts.characters);
    if (facts.intel_message) |message| {
        var age_buf: [panel_look.TIME_TEXT_MAX]u8 = undefined;
        tooltip.add("Intel {s}: {s}", .{ panel_look.relativeTime(&age_buf, facts.intel_age_ms), message });
    }
    return tooltip;
}

/// `reach` is null with no jump range showing, and `storms` and `incursions` while they're hidden or unknown.
pub fn regionTooltip(region: RegionIndex, system_count: usize, client_count: usize, reach: ?*const jump_range.Reach, storms: ?*const Storms, incursions: ?*const Incursions) Tooltip {
    var tooltip: Tooltip = .{};
    tooltip.add("{s}", .{universe.regionName(region)});
    tooltip.add(SYSTEMS_FORMAT, .{system_count});
    if (client_count > 0) tooltip.add("{d} {s} here", .{ client_count, if (client_count == 1) "character" else "characters" });
    if (reach) |shown| tooltip.add("{d} in jump range", .{shown.region_counts[region]});
    if (storms) |reported| {
        for (reported.slice()) |*storm| {
            if (universe.systemInfo(storm.center).region == region) tooltip.add("{s} Storm at {s}", .{ stormName(storm.kind), universe.systemName(storm.center) });
        }
    }
    if (incursions) |reported| {
        for (reported.slice()) |*incursion| {
            if (universe.systemInfo(incursion.staging).region == region) tooltip.add("Incursion staging at {s}", .{universe.systemName(incursion.staging)});
        }
    }
    return tooltip;
}

pub fn regionSummary(system_count: usize, totals: ?RegionTotals) evestars.Text {
    const known = totals orelse return .print(SYSTEMS_FORMAT, .{system_count});
    return .print("{d} systems, {d} ship kills, {d} NPC kills, {d} jumps last hour", .{ system_count, known.ship_kills, known.npc_kills, known.jumps });
}

pub fn securityLegend() Legend {
    return .{ .title = .print("Security", .{}), .ramp = &SECURITY_SCALE, .ramp_low = .print("-1.0", .{}), .ramp_high = .print("1.0", .{}) };
}

pub fn heatLegend(metric: MapMetric, peak: u32, has_stats: bool) Legend {
    var legend: Legend = .{ .title = .print("{s}, last hour", .{switch (metric) {
        .Security, .Sovereignty => "",
        .ShipKills => "Ship kills",
        .NpcKills => "NPC kills",
        .Jumps => "Jumps",
    }}) };
    if (!has_stats) {
        legend.add(HEAT_NONE, .print("Waiting for figures", .{}));
    } else if (peak == 0) {
        legend.add(HEAT_NONE, .print("None in this region", .{}));
    } else {
        legend.ramp = &HEAT_RAMP;
        legend.ramp_low = .print("1", .{});
        legend.ramp_high = .print("{d}", .{peak});
    }
    return legend;
}

/// Null `snapshot` until the first fetch.
pub fn sovereigntyLegend(ranks: *const HolderRanks, snapshot: ?*const Snapshot) Legend {
    var legend: Legend = .{ .title = .print("Sovereignty", .{}) };
    const stats = snapshot orelse {
        legend.add(HEAT_NONE, .print("Waiting for figures", .{}));
        return legend;
    };
    const named_count = @min(ranks.count, LEGEND_MAX_ROWS - 2);
    for (ranks.holders[0..named_count], 0..) |ranked, index| {
        const name = stats.holder_names.items[ranked.holder];
        legend.add(HOLDER_COLORS[index], .print("{s} ({d})", .{ if (name.len > 0) name else "Unknown", ranked.system_count }));
    }
    var other_count = ranks.other_count;
    for (ranks.holders[named_count..ranks.count]) |ranked| other_count += ranked.system_count;
    if (other_count > 0) legend.add(list_look.MUTED, .print(OTHERS_FORMAT, .{other_count}));
    if (ranks.unclaimed_count > 0) legend.add(HEAT_NONE, .print("Unclaimed ({d})", .{ranks.unclaimed_count}));
    return legend;
}

/// The regions it reaches, most systems first, as the map shows only one of them.
pub fn rangeLegend(reach: *const jump_range.Reach) Legend {
    var legend: Legend = .{ .title = .print("{s} from {s}", .{ jump_range.shipName(reach.ship), universe.systemName(reach.origin) }) };
    const range = jump_range.rangeLightYears(reach.ship);
    if (reach.count == 0) {
        legend.add(OUT_OF_RANGE, .print("No systems within {d:.1} ly", .{range}));
        return legend;
    }
    legend.add(RANGE, .print("{d} systems within {d:.1} ly", .{ reach.count, range }));

    var order: [universe.REGION_COUNT]RegionIndex = undefined;
    for (&order, 0..) |*region, index| region.* = @intCast(index);
    std.mem.sort(RegionIndex, &order, reach, reachesMore);
    var named_count: usize = 0;
    for (order[0..RANGE_LEGEND_REGIONS]) |region| {
        const count = reach.region_counts[region];
        if (count == 0) break;
        legend.add(RANGE, .print("{s} ({d})", .{ universe.regionName(region), count }));
        named_count += count;
    }
    if (named_count < reach.count) legend.add(list_look.MUTED, .print(OTHERS_FORMAT, .{reach.count - named_count}));
    return legend;
}

/// The storms reaching any of `nodes`, credited as EVE-Scout's terms aren't stated; null with none.
pub fn stormLegend(storms: *const Storms, nodes: []const layout.Node) ?Legend {
    var legend: Legend = .{ .title = .print("Storms (EVE-Scout)", .{}) };
    for (storms.slice()) |*storm| {
        for (nodes) |node| {
            if (storm.zoneOf(node.system) == null) continue;
            legend.add(stormColor(storm.kind), .print("{s}: {s}, {d}h ago", .{ stormName(storm.kind), universe.systemName(storm.center), storm.hours_in_system }));
            break;
        }
    }
    return if (legend.row_count > 0) legend else null;
}

/// The incursions reaching any of `nodes`; null with none.
pub fn incursionLegend(incursions: *const Incursions, nodes: []const layout.Node) ?Legend {
    var legend: Legend = .{ .title = .print("Incursions", .{}) };
    for (incursions.slice()) |*incursion| {
        for (nodes) |node| {
            if (!incursion.infested.isSet(node.system)) continue;
            legend.add(INCURSION, .print("{s}: {s}, {d}% influence", .{ universe.systemName(incursion.staging), incursionStateName(incursion.state), incursion.influence_percent }));
            break;
        }
    }
    return if (legend.row_count > 0) legend else null;
}

pub fn regionRangeColor(systems_in_range: u16) u32 {
    return if (systems_in_range > 0) RANGE else OUT_OF_RANGE;
}

/// A ship's row on the menu.
pub fn rangeLabel(ship: jump_range.Ship) evestars.Text {
    return .print("{s}" ++ HIT_GAP ++ "{d:.1} ly", .{ jump_range.shipName(ship), jump_range.rangeLightYears(ship) });
}

/// `name` is the first of those in a system, and the others follow as a count.
pub fn clientTagText(name: []const u8, other_count: usize) evestars.Text {
    return if (other_count > 0) .print("{s} +{d}", .{ name, other_count }) else .print("{s}", .{name});
}

/// As the game shows it, e.g. "0.5" or "-0.4"; `buffer` holds what's returned.
pub fn securityText(buffer: *[SECURITY_TEXT_MAX]u8, security_tenths: i8) []const u8 {
    const magnitude = @abs(security_tenths);
    const sign = if (security_tenths < 0) "-" else "";
    return std.fmt.bufPrint(buffer, "{s}{d}.{d}", .{ sign, magnitude / 10, magnitude % 10 }) catch unreachable;
}

/// The system a gate out of the region leads to, and the region it's in.
pub fn exitLabel(exit: layout.Exit) evestars.Text {
    return .print("{s} - {s}", .{ universe.systemName(exit.destination), universe.regionName(exit.region) });
}

pub fn exitTooltip(from: SystemIndex, destination: SystemIndex) Tooltip {
    var tooltip: Tooltip = .{};
    tooltip.add("{s}", .{universe.regionName(universe.systemInfo(destination).region)});
    tooltip.add("{s} to {s}", .{ universe.systemName(from), universe.systemName(destination) });
    return tooltip;
}

pub fn mapControlTooltip(control: MapControl, is_always_on_top: bool) Tooltip {
    var tooltip: Tooltip = .{};
    switch (control) {
        .zoom_in => tooltip.add("Zoom in", .{}),
        .zoom_out => tooltip.add("Zoom out", .{}),
        .fit => tooltip.add("Reset zoom", .{}),
        .always_on_top => tooltip.add("Always on Top: {s}", .{if (is_always_on_top) "On" else "Off"}),
    }
    return tooltip;
}

/// Beside the top zoom control and as tall, narrowing with `area`, the map, to leave the map room.
pub fn searchBox(area: Box) Box {
    const width = @min(SEARCH_BOX_WIDTH, @divTrunc(area.right - area.left, 3));
    const zoom_in = mapControlBox(area, .zoom_in);
    const right = zoom_in.left - MAP_CONTROL_GAP;
    return .{ .left = right - width, .top = zoom_in.top, .right = right, .bottom = zoom_in.bottom };
}

pub fn targetLabel(target: *const evestars.Target) evestars.Text {
    const name = target.name.slice();
    return switch (target.kind) {
        .group => .print("{s} ({d})", .{ name, target.character_count }),
        .character => if (target.can_send) .print("{s}", .{name}) else .print("{s} (can't send)", .{name}),
    };
}

pub fn targetColor(target: *const evestars.Target) u32 {
    return if (target.can_send) list_look.NAME else list_look.MUTED;
}

pub fn allLabel(character_count: usize) evestars.Text {
    return .print("All ({d})", .{character_count});
}

pub fn preferenceLabel(preference: RoutePreference) evestars.Text {
    return .print("Prefer: {s}", .{switch (preference) {
        .Shorter => "Shorter",
        .Safer => "Safer",
        .LessSecure => "Less Secure",
    }});
}

pub fn ansiblexLabel(uses_ansiblex: bool) evestars.Text {
    return .print("Ansiblex: {s}", .{if (uses_ansiblex) "On" else "Off"});
}

pub fn waypointsLabel(sets_every_waypoint: bool) evestars.Text {
    return .print("Waypoints: {s}", .{if (sets_every_waypoint) "Every System" else "Fewest"});
}

pub fn avoidLabel(is_avoided: bool) evestars.Text {
    return .print("{s}", .{if (is_avoided) "Stop Avoiding" else "Avoid System"});
}

/// What a click moves `preference` on to, round in the game's order.
pub fn nextPreference(preference: RoutePreference) RoutePreference {
    return switch (preference) {
        .Shorter => .Safer,
        .Safer => .LessSecure,
        .LessSecure => .Shorter,
    };
}

pub fn hitLabel(hit: search.Hit) HitLabel {
    const system = switch (hit) {
        .region => |region| return .{ .text = .print("{s}" ++ HIT_GAP ++ "Region", .{universe.regionName(region)}) },
        .system => |system| system,
    };
    const info = universe.systemInfo(system);
    const name = universe.systemName(system);
    var security_buf: [SECURITY_TEXT_MAX]u8 = undefined;
    const security = securityText(&security_buf, info.security_tenths);
    const start = name.len + HIT_GAP.len;
    return .{
        .text = .print("{s}" ++ HIT_GAP ++ "{s}" ++ HIT_GAP ++ "{s}", .{ name, security, universe.regionName(info.region) }),
        .security = .{ .start = start, .end = start + security.len, .color = securityTextColor(info.security_tenths) },
    };
}

pub fn noticeTooltip(notice: *const evestars.Notice) Tooltip {
    var tooltip: Tooltip = .{ .title_color = if (notice.is_failure) INTEL else list_look.NAME };
    for (0..notice.line_count) |index| tooltip.add("{s}", .{notice.line(index)});
    return tooltip;
}

/// A pushpin around `x`,`y`.
fn drawPin(canvas: pixel_buffer.Canvas, x: i32, y: i32, is_solid: bool, pin_color: u32) void {
    const top = y - MAP_GLYPH_SIZE;
    const collar = y - 1;
    pixel_buffer.drawLine(canvas, x - 3, top, x + 3, top, pin_color);
    if (is_solid) {
        pixel_buffer.fillRect(canvas, @intCast(x - 2), @intCast(top), 5, @intCast(collar - top), pin_color);
    } else {
        pixel_buffer.drawLine(canvas, x - 2, top, x - 2, collar, pin_color);
        pixel_buffer.drawLine(canvas, x + 2, top, x + 2, collar, pin_color);
    }
    pixel_buffer.drawLine(canvas, x - 4, collar, x + 4, collar, pin_color);
    pixel_buffer.drawLine(canvas, x, collar, x, y + MAP_GLYPH_SIZE, pin_color);
}

fn fillLabelChip(canvas: pixel_buffer.Canvas, label: Box, chip_color: u32) void {
    const left = @max(0, label.left - layout.EXIT_CHIP_PADDING);
    pixel_buffer.fillRoundedRect(canvas, @intCast(left), @intCast(@max(0, label.top)), @intCast(label.right + layout.EXIT_CHIP_PADDING - left), @intCast(label.bottom - label.top), panel_look.BUTTON_RADIUS, chip_color);
}

/// A pin's halo fill, fainter as it ages; kept faint so lines and names read through it.
fn intelHaloColor(is_clear: bool, freshness_percent: u64) u32 {
    const alpha: u8 = @intCast(15 + freshness_percent * 30 / 100);
    return color.withAlpha(intelColor(is_clear), alpha);
}

/// The rim that makes a pin's halo stand out, fainter as it ages.
fn intelRimColor(is_clear: bool, freshness_percent: u64) u32 {
    const alpha: u8 = @intCast(60 + freshness_percent * 195 / 100);
    return color.withAlpha(intelColor(is_clear), alpha);
}

fn securityScale() [21]u32 {
    var scale: [21]u32 = undefined;
    for (&scale, 0..) |*shade, index| {
        const tenths: i8 = @as(i8, @intCast(index)) - 10;
        shade.* = securityColor(tenths);
    }
    return scale;
}

fn holdsMore(_: void, first: RankedHolder, second: RankedHolder) bool {
    if (first.system_count != second.system_count) return first.system_count > second.system_count;
    return first.holder < second.holder;
}

fn reachesMore(reach: *const jump_range.Reach, first: RegionIndex, second: RegionIndex) bool {
    const first_count = reach.region_counts[first];
    const second_count = reach.region_counts[second];
    if (first_count != second_count) return first_count > second_count;
    return first < second;
}

/// Distances to two places, as one just past the range would round to it at one.
fn addRange(tooltip: *Tooltip, reach: *const jump_range.Reach, system: SystemIndex) void {
    if (system == reach.origin) {
        tooltip.add("{s} jump range from here", .{jump_range.shipName(reach.ship)});
        return;
    }
    const distance = jump_range.distanceLightYears(reach.origin, system);
    const origin = universe.systemName(reach.origin);
    if (reach.includes(system)) {
        tooltip.add("{d:.2} ly from {s}", .{ distance, origin });
    } else if (jump_range.acceptsJumps(system)) {
        tooltip.add("{d:.2} ly from {s}, out of range", .{ distance, origin });
    } else {
        tooltip.add("{d:.2} ly from {s}, no cyno possible", .{ distance, origin });
    }
}

/// One line a storm, as overlapping ones both apply.
fn addStorms(tooltip: *Tooltip, storms: *const Storms, system: SystemIndex) void {
    for (storms.slice()) |*storm| {
        const zone = storm.zoneOf(system) orelse continue;
        const name = stormName(storm.kind);
        const center = universe.systemName(storm.center);
        switch (zone) {
            .center => tooltip.add("{s} Storm centered here, reported {d}h ago", .{ name, storm.hours_in_system }),
            .core => tooltip.add("{s} Storm core, centered on {s}", .{ name, center }),
            .periphery => tooltip.add("{s} Storm periphery, centered on {s}", .{ name, center }),
        }
    }
}

/// A constellation holds one incursion at most, so the first found is the only one.
fn addIncursion(tooltip: *Tooltip, incursions: *const Incursions, system: SystemIndex) void {
    for (incursions.slice()) |*incursion| {
        if (!incursion.infested.isSet(system)) continue;
        const state = incursionStateName(incursion.state);
        if (incursion.staging == system) {
            tooltip.add("Incursion staging here: {s}, {d}% influence", .{ state, incursion.influence_percent });
        } else {
            tooltip.add("Incursion staged from {s}: {s}, {d}% influence", .{ universe.systemName(incursion.staging), state, incursion.influence_percent });
        }
        return;
    }
}

fn heatShare(value: u32, peak: u32) f32 {
    return @sqrt(@as(f32, @floatFromInt(@min(value, peak))) / @as(f32, @floatFromInt(peak)));
}

fn addCharacters(tooltip: *Tooltip, characters: []const []const u8) void {
    if (characters.len == 0) return;
    if (characters.len > MAX_CHARACTERS_NAMED) {
        tooltip.add("{d} characters here", .{characters.len});
        return;
    }
    var names_buf: [TOOLTIP_LINE_MAX]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&names_buf);
    for (characters, 0..) |name, index| {
        writer.print("{s}{s}", .{ if (index == 0) "" else ", ", name }) catch {};
    }
    tooltip.add("Here: {s}", .{writer.buffered()});
}

const testing = std.testing;

const TEST_AREA: Box = .{ .left = 0, .top = 20, .right = 760, .bottom = 530 };
const STORM_REPLY =
    \\[{"observation_type":"gamma_a","observation_category":"storm","hours_in_system":17,"system_id":30000439}]
;
const INCURSION_REPLY =
    \\[{"infested_solar_systems":[30000142,30000144],"influence":0.5,"staging_solar_system_id":30000142,"state":"mobilizing"}]
;

test "metricValue counts pods with ships, and Security counts nothing" {
    const stats: SystemStats = .{ .ship_kills = 3, .pod_kills = 2, .npc_kills = 40, .jumps = 9 };
    try testing.expectEqual(@as(u32, 5), metricValue(.ShipKills, stats));
    try testing.expectEqual(@as(u32, 40), metricValue(.NpcKills, stats));
    try testing.expectEqual(@as(u32, 9), metricValue(.Jumps, stats));
    try testing.expectEqual(@as(u32, 0), metricValue(.Security, stats));
}

test "buttonAt finds every button and misses the gaps" {
    for (BUTTON_ORDER, 0..) |button, index| {
        const span = panel_look.buttonSpan(600, BUTTON_ORDER.len, index);
        try testing.expectEqual(@as(?Button, button), buttonAt(600, span.left));
    }
    try testing.expectEqual(@as(?Button, null), buttonAt(600, 0));
}

test "the search box sits beside the top zoom control at its height, and narrows with the map" {
    const wide = searchBox(TEST_AREA);
    const zoom_in = mapControlBox(TEST_AREA, .zoom_in);
    try testing.expectEqual(SEARCH_BOX_WIDTH, wide.right - wide.left);
    try testing.expectEqual(zoom_in.left - MAP_CONTROL_GAP, wide.right);
    try testing.expectEqual(zoom_in.top, wide.top);
    try testing.expectEqual(zoom_in.bottom, wide.bottom);
    const narrow = searchBox(.{ .left = 0, .top = 0, .right = 300, .bottom = 200 });
    try testing.expectEqual(@as(i32, 100), narrow.right - narrow.left);
}

test "a target's label says why it may not get the route" {
    var target: evestars.Target = .{ .id = 1, .name = .print("Alpha", .{}), .kind = .character };
    try testing.expectEqualStrings("Alpha", targetLabel(&target).slice());
    target.can_send = false;
    try testing.expectEqualStrings("Alpha (can't send)", targetLabel(&target).slice());
    target.kind = .group;
    target.character_count = 4;
    try testing.expectEqualStrings("Alpha (4)", targetLabel(&target).slice());
}

test "the route preference comes back round to where it started" {
    try testing.expectEqualStrings("Prefer: Less Secure", preferenceLabel(nextPreference(.Safer)).slice());
    try testing.expectEqual(RoutePreference.Shorter, nextPreference(nextPreference(nextPreference(.Shorter))));
}

test "a search result names the system, its security and its region" {
    try testing.expectEqualStrings("Jita  0.9  The Forge", hitLabel(.{ .system = universe.findSystem("Jita").? }).text.slice());
}

test "a search result's accent covers its security alone" {
    const hit = hitLabel(.{ .system = universe.findSystem("Jita").? });
    const accent = hit.security.?;
    try testing.expectEqualStrings("0.9", hit.text.slice()[accent.start..accent.end]);
    try testing.expectEqual(SECURITY_COLORS[9], accent.color);
}

test "a region's search result says it's a region" {
    const hit = hitLabel(.{ .region = 0 });
    try testing.expect(std.mem.endsWith(u8, hit.text.slice(), "  Region"));
    try testing.expect(hit.security == null);
}

test "securityColor keeps EVE's scale from 0.0 up" {
    try testing.expectEqual(SECURITY_COLORS[0], securityColor(0));
    try testing.expectEqual(SECURITY_COLORS[5], securityColor(5));
    try testing.expectEqual(SECURITY_COLORS[10], securityColor(10));
    try testing.expectEqual(SECURITY_COLORS[10], securityColor(14));
}

test "securityColor tells null security's depths apart" {
    try testing.expectEqual(DEEPEST_NULL | 0xFF000000, securityColor(-10));
    try testing.expect(securityColor(-1) != securityColor(-5));
    try testing.expect(securityColor(-5) != securityColor(-10));
    try testing.expectEqual(securityColor(-10), securityColor(-12));
}

test "security text lightens only what's below high security" {
    try testing.expectEqual(securityColor(5), securityTextColor(5));
    try testing.expectEqual(securityColor(9), securityTextColor(9));
    try testing.expect(securityTextColor(4) != securityColor(4));
    try testing.expect(securityTextColor(-10) != securityColor(-10));
}

test "the security scale runs from -1.0 to 1.0" {
    try testing.expectEqual(securityColor(-10), SECURITY_SCALE[0]);
    try testing.expectEqual(securityColor(0), SECURITY_SCALE[10]);
    try testing.expectEqual(securityColor(10), SECURITY_SCALE[20]);
}

test "markers grow slower than the map, and stop" {
    try testing.expectEqual(@as(f32, 1), markerScale(1));
    try testing.expect(markerScale(2) < 2);
    try testing.expectEqual(MAX_MARKER_SCALE, markerScale(8));
}

test "names move out only as far as a marker grows" {
    try testing.expectEqual(@as(i32, layout.NODE_CLEARANCE), labelClearance(1));
    try testing.expectEqual(@as(i32, layout.NODE_CLEARANCE + 3), labelClearance(layout.MAX_ZOOM));
}

test "the always on top control's tooltip gives its state" {
    try testing.expectEqualStrings("Always on Top: On", mapControlTooltip(.always_on_top, true).line(0));
    try testing.expectEqualStrings("Always on Top: Off", mapControlTooltip(.always_on_top, false).line(0));
}

test "the map controls stack in the top right, and each finds itself" {
    for (std.enums.values(MapControl)) |control| {
        const box = mapControlBox(TEST_AREA, control);
        try testing.expect(TEST_AREA.contains(box));
        try testing.expectEqual(@as(?MapControl, control), mapControlAt(TEST_AREA, box.left, box.top));
    }
    try testing.expectEqual(@as(?MapControl, null), mapControlAt(TEST_AREA, TEST_AREA.left, TEST_AREA.top));
}

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
    snapshot.systems[2].holder = stats_mod.NO_HOLDER;
    const ranks: HolderRanks = .fromNodes(&snapshot, &nodes);
    try testing.expectEqual(@as(u16, 7), ranks.holders[0].holder);
    try testing.expectEqual(@as(u16, 3), ranks.holders[0].system_count);
    try testing.expectEqual(HOLDER_COLORS.len, ranks.count);
    try testing.expectEqual(@as(usize, 1), ranks.unclaimed_count);
    try testing.expect(ranks.other_count > 0);
    try testing.expectEqual(HOLDER_COLORS[0], ranks.colorOf(7));
    try testing.expectEqual(HEAT_NONE, ranks.colorOf(stats_mod.NO_HOLDER));
}

test "the sovereignty legend sums up what it doesn't name" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    var ranks: HolderRanks = .{ .count = HOLDER_COLORS.len, .unclaimed_count = 2 };
    for (&ranks.holders, 0..) |*ranked, index| {
        ranked.* = .{ .holder = @intCast(index), .system_count = 3 };
        try snapshot.holder_ids.append(testing.allocator, @intCast(index));
        try snapshot.holder_names.append(testing.allocator, "");
    }
    const legend = sovereigntyLegend(&ranks, &snapshot);
    try testing.expectEqual(@as(usize, LEGEND_MAX_ROWS), legend.row_count);
    try testing.expectEqualStrings("Unknown (3)", legend.rows[0].text.slice());
    try testing.expectEqualStrings("Others (18)", legend.rows[LEGEND_MAX_ROWS - 2].text.slice());
    try testing.expectEqualStrings("Unclaimed (2)", legend.rows[LEGEND_MAX_ROWS - 1].text.slice());
}

test "a heat legend says why it has no scale" {
    try testing.expectEqualStrings("Waiting for figures", heatLegend(.ShipKills, 0, false).rows[0].text.slice());
    try testing.expectEqualStrings("None in this region", heatLegend(.ShipKills, 0, true).rows[0].text.slice());
    const legend = heatLegend(.Jumps, 40, true);
    try testing.expectEqualStrings("Jumps, last hour", legend.title.slice());
    try testing.expectEqualStrings("40", legend.ramp_high.slice());
}

test "a region's summary leaves out figures it doesn't have" {
    try testing.expectEqualStrings("93 systems", regionSummary(93, null).slice());
    try testing.expectEqualStrings("93 systems, 1 ship kills, 2 NPC kills, 3 jumps last hour", regionSummary(93, .{ .ship_kills = 1, .npc_kills = 2, .jumps = 3 }).slice());
}

test "a client tag sits beside its marker, flips at the edge, and steps clear of another" {
    const beside = clientTagBox(TEST_AREA, 100, 100, 60, 14, &.{}).?;
    try testing.expect(beside.left > 100);
    const flipped = clientTagBox(TEST_AREA, 750, 100, 60, 14, &.{}).?;
    try testing.expect(flipped.right < 750);
    const stepped = clientTagBox(TEST_AREA, 100, 100, 60, 14, &.{beside}).?;
    try testing.expect(!stepped.overlaps(beside));
    try testing.expect(clientTagBox(TEST_AREA, 100, TEST_AREA.top, 60, 14, &.{}) == null);
}

test "an exit's label names the system it leads to and its region" {
    const jita = universe.findSystem("Jita").?;
    const exit: layout.Exit = .{ .from_index = 0, .destination = jita, .region = universe.systemInfo(jita).region, .x = 0, .y = 0 };
    try testing.expectEqualStrings("Jita - The Forge", exitLabel(exit).slice());
}

test "a client tag counts the others in the system" {
    try testing.expectEqualStrings("Alpha", clientTagText("Alpha", 0).slice());
    try testing.expectEqualStrings("Alpha +2", clientTagText("Alpha", 2).slice());
}

test "heat grows with the value and rests on the quiet colour at zero" {
    try testing.expectEqual(HEAT_NONE, heatColor(0, 100));
    try testing.expectEqual(HEAT_NONE, heatColor(0, 0));
    try testing.expectEqual(HEAT_HIGH | 0xFF000000, heatColor(100, 100));
    try testing.expect(markerRadius(100, 100) > markerRadius(1, 100));
    try testing.expectEqual(NODE_RADIUS, markerRadius(0, 100));
}

test "an intel halo shrinks from its peak and then rests" {
    try testing.expectEqual(INTEL_HALO_PEAK_RADIUS, intelHaloRadius(0, 60_000));
    const halfway = intelHaloRadius(30_000, 60_000);
    try testing.expectApproxEqAbs((INTEL_HALO_PEAK_RADIUS + INTEL_HALO_RADIUS) / 2, halfway, 0.01);
    try testing.expectEqual(INTEL_HALO_RADIUS, intelHaloRadius(60_000, 60_000));
    try testing.expectEqual(INTEL_HALO_RADIUS, intelHaloRadius(120_000, 60_000));
    try testing.expectEqual(INTEL_HALO_RADIUS, intelHaloRadius(0, 0));
}

test "a system's tooltip reports what's known about it" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    const jita = universe.findSystem("Jita").?;
    try snapshot.applyKills("[{\"npc_kills\":40,\"pod_kills\":2,\"ship_kills\":7,\"system_id\":30000142}]");

    const tooltip = systemTooltip(.{ .system = jita, .stats = &snapshot, .characters = &.{"Bravo"}, .intel_message = "hostile", .intel_age_ms = 300_000 });
    try testing.expectEqualStrings("Jita  0.9", tooltip.line(0));
    try testing.expectEqualStrings("The Forge / Kimotoro", tooltip.line(1));
    try testing.expectEqualStrings("Last hour: 7 ships, 2 pods, 40 NPCs", tooltip.line(2));
    try testing.expectEqualStrings("Here: Bravo", tooltip.line(4));
    try testing.expectEqualStrings("Intel 5m ago: hostile", tooltip.line(5));
}

test "a tooltip without stats leaves those lines out" {
    const tooltip = systemTooltip(.{ .system = universe.findSystem("Jita").? });
    try testing.expectEqual(@as(usize, 3), tooltip.line_count);
}

test "a system's tooltip says when routes avoid it" {
    const tooltip = systemTooltip(.{ .system = universe.findSystem("Jita").?, .is_avoided = true });
    try testing.expectEqualStrings("Routes avoid this system", tooltip.line(tooltip.line_count - 1));
}

test "many characters are counted rather than named" {
    const names = [_][]const u8{ "A", "B", "C", "D", "E" };
    const tooltip = systemTooltip(.{ .system = universe.findSystem("Jita").?, .characters = &names });
    try testing.expectEqualStrings("5 characters here", tooltip.line(tooltip.line_count - 1));
}

test "a system's tooltip says how far it is from a jump range's origin, and why it's out" {
    const origin = universe.findSystem("1DQ1-A").?;
    const titan: jump_range.Reach = .measure(origin, .titan);
    try testing.expectEqualStrings("Titan jump range from here", systemTooltip(.{ .system = origin, .reach = &titan }).line(3));
    try testing.expectEqualStrings("0.51 ly from 1DQ1-A", systemTooltip(.{ .system = universe.findSystem("8WA-Z6").?, .reach = &titan }).line(3));
    try testing.expectEqualStrings("6.46 ly from 1DQ1-A, out of range", systemTooltip(.{ .system = universe.findSystem("UEXO-Z").?, .reach = &titan }).line(3));
    const lowsec: jump_range.Reach = .measure(universe.findSystem("Amamake").?, .titan);
    try testing.expectEqualStrings("0.86 ly from Amamake, no cyno possible", systemTooltip(.{ .system = universe.findSystem("Osoggur").?, .reach = &lowsec }).line(3));
}

test "a range's legend gives the total, the biggest regions and sums up the rest" {
    const reach: jump_range.Reach = .measure(universe.findSystem("1DQ1-A").?, .jump_freighter);
    const legend = rangeLegend(&reach);
    try testing.expectEqualStrings("Jump Freighter from 1DQ1-A", legend.title.slice());
    try testing.expect(std.mem.endsWith(u8, legend.rows[0].text.slice(), " systems within 10.0 ly"));
    try testing.expect(legend.row_count >= 2);
    try testing.expect(legend.row_count <= LEGEND_MAX_ROWS);
}

test "a range with nothing in it says so" {
    var reach: jump_range.Reach = .{ .origin = universe.findSystem("Jita").?, .ship = .titan };
    reach.count = 0;
    try testing.expectEqualStrings("No systems within 6.0 ly", rangeLegend(&reach).rows[0].text.slice());
}

test "a ship's menu row gives its range" {
    try testing.expectEqualStrings("Black Ops  8.0 ly", rangeLabel(.black_ops).slice());
    try testing.expectEqualStrings("Command Carrier  7.5 ly", rangeLabel(.command_carrier).slice());
}

test "a region's tooltip counts what's in jump range only while one shows" {
    const reach: jump_range.Reach = .measure(universe.findSystem("1DQ1-A").?, .titan);
    const region = universe.systemInfo(reach.origin).region;
    try testing.expectEqual(@as(usize, 2), regionTooltip(region, 10, 0, null, null, null).line_count);
    try testing.expectEqual(@as(usize, 3), regionTooltip(region, 10, 0, &reach, null, null).line_count);
}

test "a system's tooltip names the storm over it and how it stands" {
    const storms: Storms = try .parse(testing.allocator, STORM_REPLY);
    const center = storms.storms[0].center;
    var links = universe.neighbours(center);
    try testing.expectEqualStrings("Gamma Ray Storm centered here, reported 17h ago", systemTooltip(.{ .system = center, .storms = &storms }).line(3));
    try testing.expectEqualStrings("Gamma Ray Storm core, centered on OEG-K9", systemTooltip(.{ .system = links.next().?, .storms = &storms }).line(3));
    try testing.expectEqual(@as(usize, 3), systemTooltip(.{ .system = universe.findSystem("Jita").?, .storms = &storms }).line_count);
}

test "a region's tooltip names the storms centred in it" {
    const storms: Storms = try .parse(testing.allocator, STORM_REPLY);
    const region = universe.systemInfo(storms.storms[0].center).region;
    try testing.expectEqualStrings("Gamma Ray Storm at OEG-K9", regionTooltip(region, 10, 0, null, &storms, null).line(2));
}

test "the storm legend lists what reaches the map, and is absent without any" {
    const storms: Storms = try .parse(testing.allocator, STORM_REPLY);
    const nearby = [_]layout.Node{.{ .system = storms.storms[0].center, .x = 0, .y = 0 }};
    try testing.expectEqualStrings("Gamma Ray: OEG-K9, 17h ago", stormLegend(&storms, &nearby).?.rows[0].text.slice());
    const distant = [_]layout.Node{.{ .system = universe.findSystem("Jita").?, .x = 0, .y = 0 }};
    try testing.expect(stormLegend(&storms, &distant) == null);
}

test "a storm's periphery gates are fainter than its core's" {
    const core = stormEdgeColor(.{ .kind = .plasma, .is_core = true });
    try testing.expectEqual(STORM_PLASMA, core);
    try testing.expect(stormEdgeColor(.{ .kind = .plasma, .is_core = false }) != core);
}

test "a system's tooltip says how it stands in an incursion" {
    const incursions: Incursions = try .parse(testing.allocator, INCURSION_REPLY);
    const jita = universe.findSystem("Jita").?;
    try testing.expectEqualStrings("Incursion staging here: Mobilizing, 50% influence", systemTooltip(.{ .system = jita, .incursions = &incursions }).line(3));
    try testing.expectEqualStrings("Incursion staged from Jita: Mobilizing, 50% influence", systemTooltip(.{ .system = universe.findSystemById(30000144).?, .incursions = &incursions }).line(3));
    try testing.expectEqual(@as(usize, 3), systemTooltip(.{ .system = universe.findSystem("Amarr").?, .incursions = &incursions }).line_count);
}

test "a region's tooltip names the incursions staging in it" {
    const incursions: Incursions = try .parse(testing.allocator, INCURSION_REPLY);
    const region = universe.systemInfo(incursions.incursions[0].staging).region;
    try testing.expectEqualStrings("Incursion staging at Jita", regionTooltip(region, 10, 0, null, null, &incursions).line(2));
}

test "the incursion legend lists what reaches the map, and is absent without any" {
    const incursions: Incursions = try .parse(testing.allocator, INCURSION_REPLY);
    const nearby = [_]layout.Node{.{ .system = incursions.incursions[0].staging, .x = 0, .y = 0 }};
    try testing.expectEqualStrings("Jita: Mobilizing, 50% influence", incursionLegend(&incursions, &nearby).?.rows[0].text.slice());
    const distant = [_]layout.Node{.{ .system = universe.findSystem("Amarr").?, .x = 0, .y = 0 }};
    try testing.expect(incursionLegend(&incursions, &distant) == null);
}

test "a long intel line is cut to its buffer" {
    const message: [TOOLTIP_LINE_MAX * 2]u8 = @splat('x');
    const tooltip = systemTooltip(.{ .system = universe.findSystem("Jita").?, .intel_message = &message });
    try testing.expectEqual(TOOLTIP_LINE_MAX - 1, tooltip.line(tooltip.line_count - 1).len);
}

test "securityText reads as the game shows it" {
    var buffer: [SECURITY_TEXT_MAX]u8 = undefined;
    try testing.expectEqualStrings("0.5", securityText(&buffer, 5));
    try testing.expectEqualStrings("1.0", securityText(&buffer, 10));
    try testing.expectEqualStrings("-0.4", securityText(&buffer, -4));
}
