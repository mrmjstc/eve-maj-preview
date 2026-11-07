//! The Map Panel's look: its sizes, colours, footer buttons, map markers, and where its parts sit; no I/O.
const std = @import("std");
const types = @import("../../config/types.zig");
const panels = @import("../../config/panels.zig");
const list_look = @import("../list_look.zig");
const panel_look = @import("../panel_look.zig");
const universe = @import("../../map/universe.zig");
const storms = @import("../../map/storms.zig");
const layout = @import("../../map/layout.zig");
const stats_mod = @import("../../map/stats.zig");
const holder_colors = @import("../../map/holder_colors.zig");
const color = @import("../../util/color.zig");
const pixel_buffer = @import("../../util/pixel_buffer.zig");

const Box = layout.Box;
const HistoryPanelConfig = panels.HistoryPanelConfig;
const LogoColors = holder_colors.LogoColors;
const MapMetric = types.MapMetric;
const PanelSide = types.PanelSide;
const SystemIndex = universe.SystemIndex;
const SystemStats = stats_mod.SystemStats;
const Snapshot = stats_mod.Snapshot;

/// So the results don't resize as names come and go.
pub const SEARCH_WIDTH: i32 = 280;
const SEARCH_BOX_WIDTH: i32 = 180;
/// Kept clear above the fitted map, for the title and figures.
const TITLE_BAND: i32 = 46;
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
/// The least from a marker's centre to its client tag.
const CLIENT_TAG_OFFSET: i32 = 14;
const CLIENT_TAG_GAP: i32 = 2;
/// Each way from beside its marker; further than this, a tag no longer reads as its system's.
const CLIENT_TAG_STEPS = 3;
/// The least of a tag's lead left showing between its marker's rings and its chip.
const CLIENT_TAG_LEAD = 4;
/// How much of the client's colour tints its tag's chip, stronger than an exit's so it reads as a person.
const CLIENT_TAG_TINT_PERCENT = 30;
/// How much bigger the busiest system's marker is than a quiet one's; kept small so a selected ring stays off its name.
const HEAT_RADIUS_GROWTH: f32 = 1.5;
/// Just outside a client's ring, so neither hides the other; before the marker scale.
const INTEL_HALO_RADIUS: f32 = 11;
/// Before the marker scale.
const INTEL_HALO_PEAK_RADIUS: f32 = 20;
/// Around a marked system's marker.
pub const RING_GAP: f32 = 3;
pub const RING_THICKNESS: f32 = 1.5;
/// The selected system's ring, heavier than a hover's so the two read apart.
pub const FOCUS_RING_THICKNESS: f32 = 2.5;
/// Around the selected system's ring.
pub const FOCUS_OUTLINE_THICKNESS: f32 = 3;
pub const FOCUS_BORDER = 1;
const EXIT_RADIUS: f32 = 2;
/// Half the width of the cross over an avoided system.
const AVOID_MARK_SIZE: i32 = 5;
/// Lifts -1.0 from 1.7:1 to 4.3:1 against a popup's fill.
const SECURITY_TEXT_LIGHTEN_PERCENT = 40;

// The colours below are 0xAARRGGBB, not premultiplied.
pub const BACKGROUND: u32 = 0xFF0E0F12;
const GRID_DOT: u32 = 0xFF1D1F24;
pub const TITLE: u32 = 0xFFC9CCD2;
/// Each region's name beside its part of a map showing several, muted so it reads as a heading rather than a system.
pub const REGION_NAME: u32 = 0xFF6A7080;
/// A name with nothing happening at it, a step below the bright NAME those with something do.
pub const LABEL: u32 = 0xFFA9ACB3;
pub const EDGE_LOCAL: u32 = 0xFF5B5F69;
const EDGE_CROSS: u32 = 0xFF6E5A7A;
pub const EDGE_HOVER: u32 = 0xFFD5D7DC;
pub const EXIT: u32 = 0xFFC7A95C;
const EXIT_CHIP: u32 = 0xFF2B2517;
pub const INTEL: u32 = 0xFFFF4B3E;
const INTEL_CLEAR: u32 = 0xFFFFD23F;
/// Reads through every marker colour, and is apart from intel's red and yellow.
const AVOID: u32 = 0xFFFFFFFF;
pub const FOCUS: u32 = 0xFFE8E6E1;
/// Fills the selected system's disc and name chip, inside a FOCUS border.
pub const FOCUS_MARK: u32 = 0xFF3A3D45;
/// Behind the search's selected text.
pub const SEARCH_SELECTION: u32 = 0xFF34507A;
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
pub const HEAT_NONE: u32 = 0xFF3A3C42;
const HEAT_LOW: u32 = 0xFFD9A441;
const HEAT_HIGH: u32 = 0xFFFF3B30;
/// EVE's own colours, by shown security in tenths from 0 up.
const SECURITY_COLORS = [_]u32{ 0xFFF00000, 0xFFD73000, 0xFFF04800, 0xFFF06000, 0xFFD77700, 0xFFEFEF00, 0xFF8FEF2F, 0xFF00F000, 0xFF00EF47, 0xFF48F0C0, 0xFF2FEFEF };
/// Where null security ends at -1.0, a darker red than 0.0's: EVE paints it all one red, which says nothing across a null region.
const DEEPEST_NULL: u32 = 0xFF8E0A12;
/// From -1.0 up to 1.0.
pub const SECURITY_SCALE = securityScale();
pub const HEAT_RAMP = [_]u32{ HEAT_LOW, color.mix(HEAT_HIGH, HEAT_LOW, 33), color.mix(HEAT_HIGH, HEAT_LOW, 66), HEAT_HIGH };
/// By a holder's rank on the map, for one with neither a faction's nor a logo's colour.
const HOLDER_COLORS = [_]u32{ 0xFF4F9DFF, 0xFFFF7A59, 0xFF54D18C, 0xFFE8C547, 0xFFC77DFF, 0xFF3FD0D8, 0xFFFF6FAE, 0xFF9CCB3B, 0xFFB08D6E, 0xFF8E9BFF };

/// In the footer, left to right.
pub const Button = enum { regions, security, kills, npc_kills, jumps, sovereignty, storms, incursions, follow };
pub const BUTTON_ORDER = std.enums.values(Button);

/// On the map's top right, top to bottom.
pub const MapControl = enum { zoom_in, zoom_out, fit, always_on_top };

/// The panel's sizes for the current settings, in pixels; its width and height are the configured ones.
pub const Metrics = struct {
    header_height: i32,
    footer_height: i32,
};

/// Where the panel's parts sit, in its client area.
pub const Areas = struct {
    /// Above the footer.
    inner: Box,
    /// Null while the Intel Panel isn't inside the map.
    sidebar: ?Box,
    /// The map's part of the panel, beside any sidebar, leaving a line for the divider.
    body: Box,
    /// What the map fits itself to, below the title.
    map: Box,
    search_box: Box,

    /// `sidebar_width` is 0 while the Intel Panel isn't inside the map.
    pub fn init(width: i32, height: i32, footer_height: i32, sidebar_width: i32, side: PanelSide) Areas {
        const inner: Box = .{ .left = 0, .top = 0, .right = width, .bottom = @max(0, height - footer_height) };
        var body = inner;
        var sidebar: ?Box = null;
        if (sidebar_width > 0) switch (side) {
            .Left => {
                sidebar = .{ .left = inner.left, .top = inner.top, .right = inner.left + sidebar_width, .bottom = inner.bottom };
                body.left = inner.left + sidebar_width + 1;
            },
            .Right => {
                sidebar = .{ .left = inner.right - sidebar_width, .top = inner.top, .right = inner.right, .bottom = inner.bottom };
                body.right = inner.right - sidebar_width - 1;
            },
        };
        var map = body;
        map.top = @min(body.bottom, body.top + TITLE_BAND);
        return .{ .inner = inner, .sidebar = sidebar, .body = body, .map = map, .search_box = searchBox(body) };
    }
};

/// A holder of systems in a region, into Snapshot.holder_ids.
pub const RankedHolder = struct { holder: u16, system_count: u16 };

/// Who holds the systems shown, most first; only these get colours of their own.
pub const HolderRanks = struct {
    holders: [HOLDER_COLORS.len]RankedHolder = undefined,
    /// By place in `holders`: a faction's own, else its logo's, else the palette's by rank.
    colors: [HOLDER_COLORS.len]u32 = undefined,
    count: usize = 0,
    /// Systems held by anyone past the ranked.
    other_count: usize = 0,
    unclaimed_count: usize = 0,

    /// `logos` is null until the first logo colours arrive.
    pub fn fromNodes(snapshot: *const Snapshot, nodes: []const layout.Node, logos: ?*const LogoColors) HolderRanks {
        var ranks: HolderRanks = .{};
        var tally: [layout.MAX_NODES]RankedHolder = undefined;
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
        for (ranks.holders[0..ranks.count], ranks.colors[0..ranks.count], 0..) |ranked, *shade, rank| {
            shade.* = holderColor(snapshot, ranked.holder, logos) orelse HOLDER_COLORS[rank];
        }
        return ranks;
    }

    pub fn colorOf(self: *const HolderRanks, holder: u16) u32 {
        if (holder == stats_mod.NO_HOLDER) return HEAT_NONE;
        for (self.holders[0..self.count], self.colors[0..self.count]) |ranked, shade| {
            if (ranked.holder == holder) return shade;
        }
        return list_look.MUTED;
    }
};

pub fn metrics(history_settings: *const HistoryPanelConfig) Metrics {
    const header_height = panel_look.headerHeight(history_settings);
    return .{ .header_height = header_height, .footer_height = panel_look.footerHeight(header_height) };
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

pub fn stormColor(kind: storms.Kind) u32 {
    return switch (kind) {
        .electric => STORM_ELECTRIC,
        .exotic => STORM_EXOTIC,
        .gamma => STORM_GAMMA,
        .plasma => STORM_PLASMA,
    };
}

pub fn stormEdgeColor(mark: storms.EdgeMark) u32 {
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

/// Behind the selected system's marker and name, as one shape with a light border so it stands off a dark map.
pub fn drawFocusMark(canvas: pixel_buffer.Canvas, x: i32, y: i32, radius: f32, label: ?Box) void {
    pixel_buffer.fillCircle(canvas, x, y, radius + FOCUS_BORDER, FOCUS);
    if (label) |box| fillLabelChip(canvas, .{ .left = box.left - FOCUS_BORDER, .top = box.top - FOCUS_BORDER, .right = box.right + FOCUS_BORDER, .bottom = box.bottom + FOCUS_BORDER }, FOCUS);
    pixel_buffer.fillCircle(canvas, x, y, radius, FOCUS_MARK);
    if (label) |box| fillLabelChip(canvas, box, FOCUS_MARK);
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

/// From a marker's centre to its client tag; `reach` is how far the rings around the marker go.
pub fn clientTagOffset(reach: f32) i32 {
    return @max(CLIENT_TAG_OFFSET, @as(i32, @intFromFloat(@ceil(reach))) + CLIENT_TAG_LEAD);
}

/// Like an exit: a chip tinted in the client's colour, led to from just outside the rings `reach` around the marker at `x`,`y`.
pub fn drawClientTag(canvas: pixel_buffer.Canvas, x: i32, y: i32, reach: f32, box: Box, tag_color: u32) void {
    const to_x = if (box.left > x) box.left else box.right - 1;
    const to_y = @divTrunc(box.top + box.bottom, 2);
    const delta_x: f32 = @floatFromInt(to_x - x);
    const delta_y: f32 = @floatFromInt(to_y - y);
    const length = @sqrt(delta_x * delta_x + delta_y * delta_y);
    if (length > reach) {
        const from_x = x + @as(i32, @intFromFloat(@round(delta_x * reach / length)));
        const from_y = y + @as(i32, @intFromFloat(@round(delta_y * reach / length)));
        pixel_buffer.drawLine(canvas, from_x, from_y, to_x, to_y, tag_color);
    }
    pixel_buffer.fillRoundedRect(canvas, @intCast(box.left), @intCast(box.top), @intCast(box.right - box.left), @intCast(box.bottom - box.top), panel_look.BUTTON_RADIUS, color.mix(tag_color, BACKGROUND, CLIENT_TAG_TINT_PERCENT));
}

/// `offset` from the marker at `x`,`y`, stepped up then down, further each time, until it's clear of `taken`, as names mostly sit below; null when no step inside `area` is.
pub fn clientTagBox(area: Box, x: i32, y: i32, offset: i32, width: i32, height: i32, taken: []const Box) ?Box {
    const right_left = x + offset;
    const left = if (right_left + width <= area.right) right_left else x - offset - width;
    const centred_top = y - @divTrunc(height, 2);
    const step = height + CLIENT_TAG_GAP;
    for (0..2 * CLIENT_TAG_STEPS + 1) |attempt| {
        const distance: i32 = @intCast((attempt + 1) / 2);
        const top = if (attempt % 2 == 1) centred_top - distance * step else centred_top + distance * step;
        const box: Box = .{ .left = left, .top = top, .right = left + width, .bottom = top + height };
        if (!area.contains(box)) continue;
        for (taken) |other| {
            if (box.overlaps(other)) break;
        } else return box;
    }
    return null;
}

/// As far around a system's name as a chip behind it reaches, the selected one's border included.
pub fn labelChipBox(label: Box) Box {
    const chip = layout.chipBox(label);
    return .{ .left = chip.left - FOCUS_BORDER, .top = chip.top - FOCUS_BORDER, .right = chip.right + FOCUS_BORDER, .bottom = chip.bottom + FOCUS_BORDER };
}

pub fn mapControlBox(area: Box, control: MapControl) Box {
    const index: i32 = @backingInt(control);
    const right = area.right - OVERLAY_MARGIN;
    const top = area.top + OVERLAY_MARGIN + index * (MAP_CONTROL_SIZE + MAP_CONTROL_GAP);
    return .{ .left = right - MAP_CONTROL_SIZE, .top = top, .right = right, .bottom = top + MAP_CONTROL_SIZE };
}

pub fn mapControlAt(area: Box, x: i32, y: i32) ?MapControl {
    for (std.enums.values(MapControl)) |control| {
        if (mapControlBox(area, control).containsPoint(x, y)) return control;
    }
    return null;
}

/// How warm `value` looks beside the busiest system shown, `peak`; a square root, so a quiet system isn't lost next to Jita.
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

/// A gate between regions takes an exit's colour, as it's the same gate with both ends shown.
pub fn edgeColor(kind: layout.GateKind) u32 {
    return switch (kind) {
        .within_constellation => EDGE_LOCAL,
        .within_region => EDGE_CROSS,
        .between_regions => EXIT,
    };
}

/// The stub from a system to where its gate to a region not shown points.
pub fn drawExit(canvas: pixel_buffer.Canvas, node: layout.Node, exit: layout.Exit, exit_color: u32) void {
    pixel_buffer.drawLine(canvas, node.x, node.y, exit.x, exit.y, exit_color);
    pixel_buffer.fillCircle(canvas, exit.x, exit.y, EXIT_RADIUS, exit_color);
}

/// A cross, which reads through whatever colour the marker under it has.
pub fn drawAvoidMark(canvas: pixel_buffer.Canvas, x: i32, y: i32) void {
    pixel_buffer.drawLine(canvas, x - AVOID_MARK_SIZE, y - AVOID_MARK_SIZE, x + AVOID_MARK_SIZE, y + AVOID_MARK_SIZE, AVOID);
    pixel_buffer.drawLine(canvas, x - AVOID_MARK_SIZE, y + AVOID_MARK_SIZE, x + AVOID_MARK_SIZE, y - AVOID_MARK_SIZE, AVOID);
}

pub fn regionRangeColor(systems_in_range: u16) u32 {
    return if (systems_in_range > 0) RANGE else OUT_OF_RANGE;
}

/// Beside the top zoom control and as tall, narrowing with `area`, the map, to leave the map room.
pub fn searchBox(area: Box) Box {
    const width = @min(SEARCH_BOX_WIDTH, @divTrunc(area.right - area.left, 3));
    const zoom_in = mapControlBox(area, .zoom_in);
    const right = zoom_in.left - MAP_CONTROL_GAP;
    return .{ .left = right - width, .top = zoom_in.top, .right = right, .bottom = zoom_in.bottom };
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
    const chip = layout.chipBox(label);
    const left = @max(0, chip.left);
    const top = @max(0, chip.top);
    pixel_buffer.fillRoundedRect(canvas, @intCast(left), @intCast(top), @intCast(chip.right - left), @intCast(chip.bottom - top), panel_look.BUTTON_RADIUS, chip_color);
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

fn heatShare(value: u32, peak: u32) f32 {
    return @sqrt(@as(f32, @floatFromInt(@min(value, peak))) / @as(f32, @floatFromInt(peak)));
}

const testing = std.testing;

const TEST_AREA: Box = .{ .left = 0, .top = 20, .right = 760, .bottom = 530 };

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

test "without a sidebar the map's body fills the panel above the footer" {
    const areas: Areas = .init(800, 600, 30, 0, .Right);
    try testing.expectEqual(@as(?Box, null), areas.sidebar);
    try testing.expectEqual(Box{ .left = 0, .top = 0, .right = 800, .bottom = 570 }, areas.body);
    try testing.expectEqual(Box{ .left = 0, .top = TITLE_BAND, .right = 800, .bottom = 570 }, areas.map);
    try testing.expectEqual(searchBox(areas.body), areas.search_box);
}

test "a sidebar takes its side of the panel, leaving a line for the divider" {
    const right: Areas = .init(800, 600, 30, 200, .Right);
    try testing.expectEqual(@as(?Box, .{ .left = 600, .top = 0, .right = 800, .bottom = 570 }), right.sidebar);
    try testing.expectEqual(@as(i32, 599), right.body.right);
    const left: Areas = .init(800, 600, 30, 200, .Left);
    try testing.expectEqual(@as(?Box, .{ .left = 0, .top = 0, .right = 200, .bottom = 570 }), left.sidebar);
    try testing.expectEqual(@as(i32, 201), left.body.left);
    try testing.expectEqual(searchBox(left.body), left.search_box);
}

test "a panel shorter than its footer and title keeps empty areas rather than inverted ones" {
    const areas: Areas = .init(400, 20, 30, 0, .Right);
    try testing.expectEqual(@as(i32, 0), areas.inner.bottom);
    try testing.expectEqual(@as(i32, 0), areas.map.top);
    try testing.expectEqual(@as(i32, 0), areas.map.bottom);
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
    const ranks: HolderRanks = .fromNodes(&snapshot, &nodes, null);
    try testing.expectEqual(@as(u16, 7), ranks.holders[0].holder);
    try testing.expectEqual(@as(u16, 3), ranks.holders[0].system_count);
    try testing.expectEqual(HOLDER_COLORS.len, ranks.count);
    try testing.expectEqual(@as(usize, 1), ranks.unclaimed_count);
    try testing.expect(ranks.other_count > 0);
    try testing.expectEqual(HOLDER_COLORS[0], ranks.colorOf(7));
    try testing.expectEqual(HEAT_NONE, ranks.colorOf(stats_mod.NO_HOLDER));
}

test "a holder is coloured as its faction, else its logo, else by its rank" {
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
    try testing.expectEqual(HOLDER_COLORS[2], ranks.colorOf(2));
    try testing.expectEqual(HOLDER_COLORS[3], ranks.colorOf(3));
}

test "a client tag sits beside its marker, flips at the edge, and steps clear of another" {
    const beside = clientTagBox(TEST_AREA, 100, 100, CLIENT_TAG_OFFSET, 60, 14, &.{}).?;
    try testing.expect(beside.left > 100);
    const flipped = clientTagBox(TEST_AREA, 750, 100, CLIENT_TAG_OFFSET, 60, 14, &.{}).?;
    try testing.expect(flipped.right < 750);
    const stepped = clientTagBox(TEST_AREA, 100, 100, CLIENT_TAG_OFFSET, 60, 14, &.{beside}).?;
    try testing.expect(!stepped.overlaps(beside));
    try testing.expect(clientTagBox(.{ .left = 0, .top = 0, .right = 200, .bottom = 10 }, 100, 5, CLIENT_TAG_OFFSET, 60, 14, &.{}) == null);
}

test "a client tag blocked beside its marker tries above before below" {
    const beside = clientTagBox(TEST_AREA, 100, 100, CLIENT_TAG_OFFSET, 60, 14, &.{}).?;
    const stepped = clientTagBox(TEST_AREA, 100, 100, CLIENT_TAG_OFFSET, 60, 14, &.{beside}).?;
    try testing.expect(stepped.bottom <= beside.top);
    const below = clientTagBox(TEST_AREA, 100, TEST_AREA.top + 4, CLIENT_TAG_OFFSET, 60, 14, &.{}).?;
    try testing.expect(below.top > TEST_AREA.top + 4);
}

test "a client tag steps out past wide rings, and never closer than usual" {
    try testing.expectEqual(CLIENT_TAG_OFFSET, clientTagOffset(2));
    try testing.expectEqual(@as(i32, 16 + CLIENT_TAG_LEAD), clientTagOffset(15.5));
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

test "a storm's periphery gates are fainter than its core's" {
    const core = stormEdgeColor(.{ .kind = .plasma, .is_core = true });
    try testing.expectEqual(STORM_PLASMA, core);
    try testing.expect(stormEdgeColor(.{ .kind = .plasma, .is_core = false }) != core);
}
