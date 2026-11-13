//! The Map Panel's look: its sizes, colours, footer buttons, map markers, and where its parts sit; no I/O.
const std = @import("std");
const types = @import("../../config/types.zig");
const panels = @import("../../config/panels.zig");
const list_look = @import("../list_look.zig");
const palette = @import("../palette.zig");
const popup_look = @import("../popup_look.zig");
const segmented = @import("../segmented.zig");
const glyphs = @import("../glyphs.zig");
const universe = @import("../../map/universe.zig");
const storms = @import("../../map/storms.zig");
const layout = @import("../../map/layout.zig");
const stats_mod = @import("../../map/stats.zig");
const holder_colors = @import("../../map/holder_colors.zig");
const faction_warfare = @import("../../map/faction_warfare.zig");
const wormholes = @import("../../map/wormholes.zig");
const color = @import("../../util/color.zig");
const pixel_buffer = @import("../../util/pixel_buffer.zig");

const Box = layout.Box;
const LogoColors = holder_colors.LogoColors;
const MapMetric = types.MapMetric;
const SystemIndex = universe.SystemIndex;
const SystemStats = stats_mod.SystemStats;
const Snapshot = stats_mod.Snapshot;

/// The search box and pin side by side, and the cards under them.
const SIDE_COLUMN_WIDTH: i32 = 210;
/// As wide as the column, so the results don't resize as names come and go.
pub const SEARCH_WIDTH: i32 = SIDE_COLUMN_WIDTH;
pub const SEARCH_RESULTS_GAP: i32 = 4;
/// From the search box's left edge to its text, past the magnifier.
pub const SEARCH_TEXT_INSET: i32 = 30;
/// From the search box's left edge to its magnifier's middle, halfway to its text.
const SEARCH_GLYPH_X: i32 = SEARCH_TEXT_INSET / 2;
pub const TITLE_FONT_SIZE: i32 = 16;
/// Between the window's edges and the cards floating over the map.
pub const CARD_MARGIN: i32 = 12;
/// Between two cards side by side, and below a stack.
pub const CARD_GAP: i32 = 6;
const CARD_BORDER_WIDTH: i32 = 1;
const TOGGLE_GAP: i32 = 2;
pub const TOGGLE_PADDING_X: i32 = 10;
/// Room for a toggle's dot or icon, and the gap before its name.
pub const TOGGLE_MARK_ROOM: i32 = 13 + 7;
/// The divider before Follow, with a margin either side.
const TOGGLE_DIVIDER_ROOM: i32 = 5;
/// From a toggle's padding to its mark's middle, about half the mark's 13 px.
const TOGGLE_MARK_X: i32 = 6;
/// How much shorter the divider before Follow is than the bar's inside, at each end.
const TOGGLE_DIVIDER_INSET: i32 = 4;
pub const TITLE_PADDING_X: i32 = 12;
const TITLE_PADDING_TOP: i32 = 7;
const TITLE_PADDING_BOTTOM: i32 = 8;
pub const TITLE_LINE_GAP: i32 = 2;
/// Above and below the rule under a detailed tooltip's title.
pub const TOOLTIP_HEADER_GAP: i32 = 6;
pub const TOOLTIP_ROW_GAP: i32 = 3;
/// After a tooltip's widest label.
pub const TOOLTIP_LABEL_GAP: i32 = 12;
/// Between a tooltip's title and its accent.
pub const TOOLTIP_PART_GAP: i32 = 8;
/// The least room between a tooltip's title and its aside.
pub const TOOLTIP_ASIDE_GAP: i32 = 16;
/// From the title's end to its chevron's middle.
pub const CHEVRON_OFFSET: i32 = 12;
const CHEVRON_SIZE: i32 = 4;
pub const LEGEND_PADDING_X: i32 = 12;
/// Above and below each of the legend card's sections.
pub const LEGEND_PADDING_Y: i32 = 8;
pub const LEGEND_HEADING_GAP: i32 = 4;
pub const LEGEND_ROW_GAP: i32 = 5;
/// Between a row's swatch and name, and a ramp's ends and its colours.
pub const LEGEND_SWATCH_GAP: i32 = 8;
/// The least between a row's name and its value.
pub const LEGEND_VALUE_GAP: i32 = 16;
/// Between a heading's letters, so the small capitals read as a label.
pub const LEGEND_HEADING_SPACING: i32 = 1;
/// From a card's sides to its row dividers and a lit row's edges, as on the dialog's cards.
const ROW_INSET: i32 = 6;
pub const MAX_INTEL_ROWS = 6;
/// A list card's rows; past what the tallest window fits.
pub const MAX_LIST_ROWS = 32;
/// Above and below a list card row's one line.
const LIST_ROW_PADDING_Y: i32 = 4;
const MIN_INTEL_ROWS = 2;
/// Taller than a bar, as it heads a card.
const INTEL_HEADER_EXTRA: i32 = 4;
pub const INTEL_PADDING_X: i32 = palette.PADDING_X;
pub const INTEL_PADDING_Y: i32 = 8;
const NODE_RADIUS: f32 = 3.5;
/// The dark edge that lifts a marker off the gates running into it.
const MARKER_RIM: f32 = 1.5;
/// Markers grow more slowly than the map, and stop at this.
const MAX_MARKER_SCALE: f32 = 1.8;
/// From a system in jump range to its diamond's points, before the marker scale; clear of a hover's ring.
const RANGE_MARK_SIZE: f32 = 9;
/// From a system with a sov timer to its square's sides, before the marker scale; the jump range diamond's size, as a square looks larger.
const TIMER_MARK_SIZE: f32 = 7;
/// Between a sov timer's square and its system's name.
const TIMER_LABEL_GAP = 3;
/// Each corner of an upcoming timer's square.
const TIMER_CORNER_LENGTH: f32 = 3;
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
/// From this zoom there's room to show a system's security beside its name.
const SECURITY_LABEL_ZOOM: f32 = 1.5;
/// Before what follows a system's name.
pub const LABEL_SUFFIX_GAP: i32 = 4;
pub const LEGEND_RAMP_WIDTH: i32 = 120;
const LEGEND_RAMP_HEIGHT: i32 = 6;
pub const LEGEND_SWATCH_SIZE: i32 = 10;
const LEGEND_SWATCH_RADIUS: usize = palette.SMALL_RADIUS;
/// How much of an area swatch's colour tints its fill inside the rim.
const LEGEND_AREA_TINT_PERCENT = 25;
/// The least from a marker's centre to its client tag.
const CLIENT_TAG_OFFSET: i32 = 14;
const CLIENT_TAG_GAP: i32 = 2;
/// Each way from beside its marker; further than this, a tag no longer reads as its system's.
const CLIENT_TAG_STEPS = 3;
/// The least of a tag's lead left showing between its marker's rings and its name.
const CLIENT_TAG_LEAD = 4;
/// How much bigger the busiest system's marker is than a quiet one's; kept small so a selected ring stays off its name.
const HEAT_RADIUS_GROWTH: f32 = 1.5;
/// Just outside a client's ring, so neither hides the other; before the marker scale.
const INTEL_HALO_RADIUS: f32 = 11;
/// Before the marker scale.
const INTEL_HALO_PEAK_RADIUS: f32 = 20;
/// How long a ripple's one ring takes to spread and fade, for a new pin, a kill or a ping.
const RIPPLE_MS: u64 = 600;
/// Before the marker scale; the ring starts inside the new halo and ends well past it.
const RIPPLE_START_RADIUS: f32 = 10;
const RIPPLE_END_RADIUS: f32 = 52;
const RIPPLE_THICKNESS: f32 = 2;
/// Around a marked system's marker.
pub const RING_GAP: f32 = 3;
pub const RING_THICKNESS: f32 = 1.5;
/// The selected system's ring, heavier than a hover's so the two read apart.
pub const FOCUS_RING_THICKNESS: f32 = 2.5;
/// Around the selected system's ring.
pub const FOCUS_OUTLINE_THICKNESS: f32 = 3;
const EXIT_RADIUS: f32 = 2;
/// From a system to the middle of its kill mark, up and to the right, before the marker scale.
const KILL_MARK_OFFSET: f32 = 8;
/// Half the kill mark's height, before the marker scale.
const KILL_MARK_SIZE: f32 = 3.5;
/// A kill's mark just before it leaves the map, against 255 when new.
const KILL_MIN_ALPHA = 70;
/// Between the tabs' names in the side card's header.
pub const CARD_TAB_GAP: i32 = 14;
/// Along a portal's stub, with as many gaps between them.
const PORTAL_DASHES = 3;
const PORTAL_RING_RADIUS: f32 = 3;
/// Half the width of the cross over an avoided system.
const AVOID_MARK_SIZE: i32 = 5;
/// Lifts -1.0 from 1.7:1 to 4.3:1 against a popup's fill.
const SECURITY_TEXT_LIGHTEN_PERCENT = 40;

// The colours below are 0xAARRGGBB, not premultiplied; the greys come from the palette, so the map stays as warm as the cards over it.
pub const BACKGROUND: u32 = palette.BG;
const GRID_DOT: u32 = palette.PANEL;
/// Each region's name beside its part of a map showing several, muted so it reads as a heading rather than a system.
pub const REGION_NAME: u32 = palette.BORDER_STRONG;
/// A name with nothing happening at it, a step below the bright NAME those with something do.
pub const LABEL: u32 = palette.HINT_TEXT;
pub const EDGE_LOCAL: u32 = color.mix(palette.BORDER_STRONG, palette.BORDER, 60);
const EDGE_CROSS: u32 = 0xFF6E5A7A;
pub const EDGE_HOVER: u32 = color.mix(palette.TEXT, palette.TEXT_SECONDARY, 50);
/// Pale sand, kept off the accent's amber.
pub const EXIT: u32 = 0xFFD3C49C;
pub const INTEL: u32 = 0xFFFF4B3E;
const INTEL_CLEAR: u32 = 0xFFFFD23F;
/// Reads through every marker colour, and is apart from intel's red and yellow.
const AVOID: u32 = 0xFFFFFFFF;
pub const PING: u32 = 0xFFFFFFFF;
pub const FOCUS: u32 = palette.TEXT;
/// Fills the selected system's disc.
const FOCUS_MARK: u32 = color.mix(palette.BORDER, palette.CARD_BORDER, 50);
pub const FOCUS_NAME: u32 = 0xFFFFFFFF;
/// Behind the search's selected text.
pub const SEARCH_SELECTION: u32 = 0xFF34507A;
/// Everything over the map, cards included, like the dialog's controls.
const CONTROL_FILL: u32 = segmented.BAR_FILL;
const CONTROL_BORDER: u32 = segmented.BAR_BORDER;
const CONTROL_HOVER: u32 = palette.SURFACE_ALT;
/// Between the zoom controls and the intel card's rows, before Follow, and under a tooltip's title.
const CONTROL_DIVIDER: u32 = palette.BORDER;
/// Behind a hovered intel report, as behind a hovered segment.
const SEGMENT_HOVER: u32 = segmented.HOVER;
/// The map controls' glyphs, as a segment's label.
const SEGMENT_TEXT: u32 = segmented.TEXT;
/// A toggle that's off, the placeholder, and the cards' icons.
pub const CARD_MUTED: u32 = palette.MUTED;
/// Magenta, which no security, heat or intel colour comes near.
pub const RANGE: u32 = 0xFFFF4FD8;
/// Dims what a jump range doesn't reach, a step below HEAT_NONE's quiet system.
pub const OUT_OF_RANGE: u32 = palette.ROW_HOVER;
const STORM_ELECTRIC: u32 = 0xFF3FE0E0;
const STORM_EXOTIC: u32 = 0xFFB58CFF;
const STORM_GAMMA: u32 = 0xFF66E07F;
const STORM_PLASMA: u32 = 0xFFFF9D45;
/// Chartreuse, the widest gap left between the storms' and intel's colours.
pub const INCURSION: u32 = 0xFFB5F23A;
/// Sky blue, clear of the storms' cyan and intel's red and yellow; its square shape does the rest.
pub const SOV_TIMER: u32 = 0xFF5CB8FF;
/// Periwinkle, for Thera's and Turnur's stubs; dashed, so it reads apart from an exit's sand.
pub const WORMHOLE: u32 = 0xFF9AA4FF;
/// Deep orange, between intel's red and the plasma storm's orange; its triangle sets it apart from both.
pub const KILL: u32 = 0xFFFF6E40;
/// Mint, for Ansiblex gates; dashed and arched, so they read apart from the storms' green areas.
pub const ANSIBLEX: u32 = 0xFF4ED8A8;
/// An Ansiblex arc's bend against its length.
const BRIDGE_BEND_SHARE: f32 = 0.2;
/// In pixels, so a long arc gets as many dashes for its length as a short one.
const BRIDGE_DASH_LENGTH: f32 = 8;
const BRIDGE_GAP_LENGTH: f32 = 6;
/// Finer than the gates' curves, as each dash takes the slope of the piece it's on.
const BRIDGE_SAMPLES = 64;
/// Brighter than the gates so a quiet system's dot shows, but below LABEL.
pub const HEAT_NONE: u32 = color.mix(palette.MUTED, palette.BORDER_STRONG, 50);
const HEAT_LOW: u32 = palette.CAUTION;
const HEAT_HIGH: u32 = 0xFFFF3B30;
/// EVE's own colours, by shown security in tenths from 0 up.
const SECURITY_COLORS = [_]u32{ 0xFFF00000, 0xFFD73000, 0xFFF04800, 0xFFF06000, 0xFFD77700, 0xFFEFEF00, 0xFF8FEF2F, 0xFF00F000, 0xFF00EF47, 0xFF48F0C0, 0xFF2FEFEF };
/// Where null security ends at -1.0, a darker red than 0.0's: EVE paints it all one red, which says nothing across a null region.
const DEEPEST_NULL: u32 = 0xFF8E0A12;
/// From -1.0 up to 1.0.
pub const SECURITY_SCALE = securityScale();
/// Where NPC kills fell on the hour, against HEAT_LOW and HEAT_HIGH where they rose.
const DROP_LOW: u32 = 0xFF6FA8DC;
const DROP_HIGH: u32 = 0xFF3D6FF2;
/// From the steepest fall to the steepest rise.
pub const DELTA_RAMP = [_]u32{ DROP_HIGH, DROP_LOW, HEAT_NONE, HEAT_LOW, HEAT_HIGH };
pub const HEAT_RAMP = [_]u32{ HEAT_LOW, color.mix(HEAT_HIGH, HEAT_LOW, 33), color.mix(HEAT_HIGH, HEAT_LOW, 66), HEAT_HIGH };
/// How much of its occupier's colour a warzone system keeps with nothing contested; the rest comes in as it's contested.
const WARFARE_CALM_PERCENT = 35;
/// From a calm warzone system to a fully contested one, in a neutral colour as each faction has its own.
pub const WARFARE_RAMP = [_]u32{ color.mix(list_look.NAME, HEAT_NONE, WARFARE_CALM_PERCENT), color.mix(list_look.NAME, HEAT_NONE, 67), list_look.NAME };
/// By a holder's rank on the map, for one with neither a faction's nor a logo's colour.
const HOLDER_COLORS = [_]u32{ 0xFF4F9DFF, 0xFFFF7A59, 0xFF54D18C, 0xFFE8C547, 0xFFC77DFF, 0xFF3FD0D8, 0xFFFF6FAE, 0xFF9CCB3B, 0xFFB08D6E, 0xFF8E9BFF };

/// Left to right.
pub const SEGMENT_ORDER = std.enums.values(MetricSegment);
const NO_BOX: Box = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

pub const TOGGLE_ORDER = std.enums.values(Toggle);

pub const LAYER_ORDER = std.enums.values(Layer);

/// A button in the bar along the map's bottom; one with a second metric flips to it when clicked again.
pub const MetricSegment = enum { security, kills, npc, jumps, sovereignty, faction_warfare };
/// In the bar along the map's bottom, left to right; Follow sits past a divider, as it moves the map rather than showing more on it.
pub const Toggle = enum { layers, follow };
/// What the Layers menu turns on and off, top to bottom.
pub const Layer = enum { storms, incursions, sov_timers, wormholes, ansiblex, kills, intel, names };

/// What the side card lists: the Intel Panel's reports, or zKillboard's kills.
pub const CardTab = enum { intel, kills };
/// A ripple's ring at one moment.
pub const Ripple = struct {
    /// Before the marker scale.
    radius: f32,
    alpha: u8,
};

/// The zoom controls stack in the bottom right, top to bottom, with the always on top pin alone above them.
pub const MapControl = enum { zoom_in, zoom_out, fit, always_on_top };

/// Where the panel's parts sit, in its client area.
pub const Areas = struct {
    /// The whole client area.
    body: Box,
    /// What the map fits itself to, clear of the cards along the top and bottom; centred across the panel, so the Intel card floats over it.
    map: Box,
    search_box: Box,
    /// Of a bar, the search box and each map control.
    card_height: i32,
    /// As wide as the search box, which it sits under; 0 while the Intel card isn't shown.
    intel_width: i32,

    pub fn init(width: i32, height: i32, card_height: i32, has_intel_card: bool) Areas {
        const body: Box = .{ .left = 0, .top = 0, .right = width, .bottom = @max(0, height) };
        const search_box = searchBox(body, card_height);
        const intel_width = if (has_intel_card) body.right - CARD_MARGIN - search_box.left else 0;
        // About as tall as the title card.
        const top = @min(body.bottom, body.top + CARD_MARGIN + card_height + CARD_GAP);
        const left = @min(body.right, body.left + 2 * CARD_MARGIN);
        const map: Box = .{
            .left = left,
            .top = top,
            .right = @max(left, body.right - 2 * CARD_MARGIN),
            // Above the toggle bar stacked on the metric bar.
            .bottom = @max(top, body.bottom - CARD_MARGIN - 2 * card_height - 2 * CARD_GAP),
        };
        return .{ .body = body, .map = map, .search_box = search_box, .card_height = card_height, .intel_width = intel_width };
    }

    pub fn mapControlBox(self: Areas, control: MapControl) Box {
        const right = self.body.right - CARD_MARGIN;
        const size = self.card_height;
        const from_bottom: i32 = switch (control) {
            .fit => 1,
            .zoom_out => 2,
            .zoom_in => 3,
            .always_on_top => 4,
        };
        const gap = if (control == .always_on_top) CARD_GAP else 0;
        const top = self.body.bottom - CARD_MARGIN - from_bottom * size - gap;
        return .{ .left = right - size, .top = top, .right = right, .bottom = top + size };
    }

    /// Below the search box.
    pub fn intelTop(self: Areas) i32 {
        return self.search_box.bottom + CARD_MARGIN;
    }

    /// Where the cards in the right column must end, clear of the map controls.
    pub fn sideBottom(self: Areas) i32 {
        return self.mapControlBox(.always_on_top).top - CARD_GAP;
    }

    pub fn zoomStack(self: Areas) Box {
        const first = self.mapControlBox(.zoom_in);
        return .{ .left = first.left, .top = first.top, .right = first.right, .bottom = self.mapControlBox(.fit).bottom };
    }

    pub fn mapControlAt(self: Areas, x: i32, y: i32) ?MapControl {
        for (std.enums.values(MapControl)) |control| {
            if (self.mapControlBox(control).containsPoint(x, y)) return control;
        }
        return null;
    }
};

/// The Intel card, below the search box and clear of the map controls.
pub const IntelCard = struct {
    box: Box,
    /// Pressing it collapses the card to just this, or opens it again.
    header: Box,
    /// By place in the map state's intel_rows or kill_rows, as `tab` says; only the first row_count are set.
    rows: [MAX_INTEL_ROWS]Box = @splat(NO_BOX),
    row_count: usize = 0,
    is_collapsed: bool,
    tab: CardTab = .intel,
    /// Each tab's name in the header, by CardTab, while both can show; empty boxes otherwise.
    tabs: [std.enums.values(CardTab).len]Box = @splat(NO_BOX),

    /// How many rows fit above `bottom`, at least MIN_INTEL_ROWS so a short window still shows some, and at most MAX_INTEL_ROWS.
    pub fn capacity(top: i32, bottom: i32, header_height: i32, row_height: i32) usize {
        const rows_top = top + header_height;
        const room = bottom - rows_top;
        return @intCast(std.math.clamp(@divTrunc(@max(0, room), row_height), MIN_INTEL_ROWS, MAX_INTEL_ROWS));
    }

    /// `row_count` rows below the header, or the header alone while collapsed; with no rows it keeps one row's room to say so.
    pub fn init(areas: Areas, top: i32, header_height: i32, row_height: i32, row_count: usize, is_collapsed: bool) IntelCard {
        const right = areas.body.right - CARD_MARGIN;
        const left = right - areas.intel_width;
        var card: IntelCard = .{ .box = undefined, .header = .{ .left = left, .top = top, .right = right, .bottom = top + header_height }, .is_collapsed = is_collapsed };
        card.row_count = if (is_collapsed) 0 else @min(row_count, MAX_INTEL_ROWS);
        for (card.rows[0..card.row_count], 0..) |*row, index| {
            const row_top = card.header.bottom + @as(i32, @intCast(index)) * row_height;
            row.* = .{ .left = left, .top = row_top, .right = right, .bottom = row_top + row_height };
        }
        const shown_rows: i32 = if (is_collapsed) 0 else @intCast(@max(1, card.row_count));
        card.box = .{ .left = left, .top = top, .right = right, .bottom = card.header.bottom + shown_rows * row_height };
        return card;
    }

    pub fn tabAt(self: *const IntelCard, x: i32, y: i32) ?CardTab {
        for (std.enums.values(CardTab), self.tabs) |tab, box| {
            if (box.containsPoint(x, y)) return tab;
        }
        return null;
    }

    pub fn hasTabs(self: *const IntelCard) bool {
        return self.tabs[0].right > self.tabs[0].left;
    }

    pub fn rowAt(self: *const IntelCard, x: i32, y: i32) ?usize {
        for (self.rows[0..self.row_count], 0..) |row, index| {
            if (row.containsPoint(x, y)) return index;
        }
        return null;
    }
};

/// A collapsible list in the right column, below the Intel card and clear of the map controls: Thera and Turnur, which scrolls past what fits, or the sov timers.
pub const ListCard = struct {
    box: Box,
    /// Pressing it collapses the card to just this, or opens it again.
    header: Box,
    /// The rows showing, from the list's scroll on; only the first row_count are set.
    rows: [MAX_LIST_ROWS]Box = @splat(NO_BOX),
    row_count: usize = 0,
    /// How many rows fit, which the list scrolls by.
    visible_count: usize = 0,
    is_collapsed: bool,
    /// Each hub's name in the header, by Hub; unset on the sov timer card.
    tabs: [std.enums.values(wormholes.Hub).len]Box = @splat(NO_BOX),

    /// From `top` down to `bottom`, as many rows as fit, at least one to say there are none; up to `row_count` of them hold entries.
    pub fn init(areas: Areas, top: i32, bottom: i32, header_height: i32, row_height: i32, row_count: usize, is_collapsed: bool) ListCard {
        const right = areas.body.right - CARD_MARGIN;
        const left = right - areas.intel_width;
        var card: ListCard = .{ .box = undefined, .header = .{ .left = left, .top = top, .right = right, .bottom = top + header_height }, .is_collapsed = is_collapsed };
        const fitting: usize = @intCast(std.math.clamp(@divTrunc(@max(0, bottom - card.header.bottom), row_height), 1, MAX_LIST_ROWS));
        card.visible_count = fitting;
        card.row_count = if (is_collapsed) 0 else @min(row_count, fitting);
        for (card.rows[0..card.row_count], 0..) |*row, index| {
            const row_top = card.header.bottom + @as(i32, @intCast(index)) * row_height;
            row.* = .{ .left = left, .top = row_top, .right = right, .bottom = row_top + row_height };
        }
        const shown_rows: i32 = if (is_collapsed) 0 else @intCast(@max(1, card.row_count));
        card.box = .{ .left = left, .top = top, .right = right, .bottom = card.header.bottom + shown_rows * row_height };
        return card;
    }

    pub fn tabAt(self: *const ListCard, x: i32, y: i32) ?wormholes.Hub {
        for (std.enums.values(wormholes.Hub), self.tabs) |hub, box| {
            if (box.containsPoint(x, y)) return hub;
        }
        return null;
    }

    pub fn rowAt(self: *const ListCard, x: i32, y: i32) ?usize {
        for (self.rows[0..self.row_count], 0..) |row, index| {
            if (row.containsPoint(x, y)) return index;
        }
        return null;
    }
};

/// What the cards sized to their text need measured, in pixels, each in the font it's drawn in.
pub const ChromeText = struct {
    title_width: i32,
    title_height: i32,
    /// Each segment's shown label.
    metric_widths: [SEGMENT_ORDER.len]i32,
    toggle_widths: [TOGGLE_ORDER.len]i32,
    /// The legends' card, which a centred toggle bar keeps clear of; 0 without one.
    legend_width: i32 = 0,
};

/// Where the cards sized to their text sit; empty until a render measures them.
pub const Chrome = struct {
    title: Box = NO_BOX,
    metric_bar: Box = NO_BOX,
    metrics: [SEGMENT_ORDER.len]Box = @splat(NO_BOX),
    toggle_bar: Box = NO_BOX,
    toggles: [TOGGLE_ORDER.len]Box = @splat(NO_BOX),

    /// The title in the top left, clear of the search; along the bottom, the toggle bar on the metric bar, each centred, or both kept to the left where centring either would meet the legends or crowd the zoom controls.
    pub fn init(areas: Areas, text: ChromeText) Chrome {
        var chrome: Chrome = .{};
        const body = areas.body;
        const left = body.left + CARD_MARGIN;
        const top = body.top + CARD_MARGIN;
        const title_content = text.title_width + CHEVRON_OFFSET + CHEVRON_SIZE;
        const title_right = @min(left + title_content + 2 * TITLE_PADDING_X, areas.search_box.left - CARD_GAP);
        chrome.title = .{ .left = left, .top = top, .right = @max(left, title_right), .bottom = top + TITLE_PADDING_TOP + text.title_height + TITLE_PADDING_BOTTOM };

        var metric_widths: [SEGMENT_ORDER.len]i32 = undefined;
        for (&metric_widths, text.metric_widths) |*width, text_width| width.* = segmented.buttonWidth(text_width);
        const metric_width = segmented.barWidth(&metric_widths, segmented.GAP, 0);
        var toggle_widths: [TOGGLE_ORDER.len]i32 = undefined;
        for (&toggle_widths, text.toggle_widths) |*width, text_width| width.* = text_width + TOGGLE_MARK_ROOM + 2 * TOGGLE_PADDING_X;
        const toggle_width = segmented.barWidth(&toggle_widths, TOGGLE_GAP, TOGGLE_DIVIDER_ROOM);

        const metric_centred = body.left + @divTrunc(body.right - body.left - metric_width, 2);
        const toggle_centred = body.left + @divTrunc(body.right - body.left - toggle_width, 2);
        const legend_right = if (text.legend_width > 0) left + text.legend_width + CARD_GAP else left;
        // Kept left rather than pushing the legends up a row; a control's width to spare before the zoom controls, as crowding them reads as misplaced.
        const right_limit = areas.zoomStack().left - CARD_GAP - areas.card_height;
        const is_centred = @min(metric_centred, toggle_centred) >= legend_right and @max(metric_centred + metric_width, toggle_centred + toggle_width) <= right_limit;
        const metric_left = if (is_centred) metric_centred else left;
        const toggle_left = if (is_centred) toggle_centred else left;

        const metric_bottom = body.bottom - CARD_MARGIN;
        chrome.metric_bar = .{ .left = metric_left, .top = metric_bottom - areas.card_height, .right = metric_left + metric_width, .bottom = metric_bottom };
        segmented.placeButtons(chrome.metric_bar, &metric_widths, segmented.GAP, null, 0, &chrome.metrics);
        const toggle_bottom = chrome.metric_bar.top - CARD_GAP;
        chrome.toggle_bar = .{ .left = toggle_left, .top = toggle_bottom - areas.card_height, .right = toggle_left + toggle_width, .bottom = toggle_bottom };
        segmented.placeButtons(chrome.toggle_bar, &toggle_widths, TOGGLE_GAP, @backingInt(Toggle.follow), TOGGLE_DIVIDER_ROOM, &chrome.toggles);
        return chrome;
    }

    /// Around both bars along the bottom, which the legends keep clear of.
    pub fn bottomBars(self: *const Chrome) Box {
        return .{
            .left = @min(self.metric_bar.left, self.toggle_bar.left),
            .top = self.toggle_bar.top,
            .right = @max(self.metric_bar.right, self.toggle_bar.right),
            .bottom = self.metric_bar.bottom,
        };
    }

    pub fn segmentAt(self: *const Chrome, x: i32, y: i32) ?MetricSegment {
        for (SEGMENT_ORDER, self.metrics) |segment, box| {
            if (box.containsPoint(x, y)) return segment;
        }
        return null;
    }

    pub fn toggleAt(self: *const Chrome, x: i32, y: i32) ?Toggle {
        for (TOGGLE_ORDER, self.toggles) |toggle, box| {
            if (box.containsPoint(x, y)) return toggle;
        }
        return null;
    }

    /// Over a bar's padding, which takes clicks so they don't fall through to the map.
    pub fn hasBarAt(self: *const Chrome, x: i32, y: i32) bool {
        return self.metric_bar.containsPoint(x, y) or self.toggle_bar.containsPoint(x, y);
    }

    /// Halfway between Follow and the toggle before it.
    pub fn toggleDividerX(self: *const Chrome) i32 {
        const follow = @backingInt(Toggle.follow);
        return @divTrunc(self.toggles[follow - 1].right + self.toggles[follow].left, 2);
    }
};

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
        if (holder == stats_mod.NO_HOLDER) return HEAT_NONE;
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

    var holders: [universe.REGION_COUNT]u16 = @splat(stats_mod.NO_HOLDER);
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

pub fn intelHeaderHeight(card_height: i32) i32 {
    return card_height + INTEL_HEADER_EXTRA;
}

/// Two lines, the system over the message.
pub fn intelRowHeight(line_height: i32) i32 {
    return 2 * INTEL_PADDING_Y + 2 * line_height + TITLE_LINE_GAP;
}

/// The card, its header's chevron, and dividers under the header and between rows, set in like the dialog's; a hovered row or header lit.
pub fn drawIntelCard(canvas: pixel_buffer.Canvas, card: *const IntelCard, hovered_row: ?usize, is_header_hovered: bool) void {
    drawCard(canvas, card.box);
    const inner_left = card.box.left + ROW_INSET;
    const inner_right = card.box.right - ROW_INSET;
    if (is_header_hovered) fillBox(canvas, rowHighlight(card.header, inner_left, inner_right), segmented.RADIUS, SEGMENT_HOVER);
    if (hovered_row) |index| {
        if (index < card.row_count) fillBox(canvas, rowHighlight(card.rows[index], inner_left, inner_right), segmented.RADIUS, SEGMENT_HOVER);
    }
    if (!card.is_collapsed) drawDivider(canvas, inner_left, inner_right, card.header.bottom - 1);
    for (card.rows[0..card.row_count -| 1]) |row| drawDivider(canvas, inner_left, inner_right, row.bottom - 1);
    drawChevron(canvas, card.header.right - INTEL_PADDING_X - CHEVRON_SIZE, @divTrunc(card.header.top + card.header.bottom, 2), !card.is_collapsed);
}

pub fn listRowHeight(line_height: i32) i32 {
    return line_height + 2 * LIST_ROW_PADDING_Y;
}

/// The card, its header's chevron and the divider under the header; a hovered row or header lit.
pub fn drawListCard(canvas: pixel_buffer.Canvas, card: *const ListCard, hovered_row: ?usize, is_header_hovered: bool) void {
    drawCard(canvas, card.box);
    const inner_left = card.box.left + ROW_INSET;
    const inner_right = card.box.right - ROW_INSET;
    if (is_header_hovered) fillBox(canvas, rowHighlight(card.header, inner_left, inner_right), segmented.RADIUS, SEGMENT_HOVER);
    if (hovered_row) |index| {
        if (index < card.row_count) fillBox(canvas, rowHighlight(card.rows[index], inner_left, inner_right), segmented.RADIUS, SEGMENT_HOVER);
    }
    if (!card.is_collapsed) drawDivider(canvas, inner_left, inner_right, card.header.bottom - 1);
    drawChevron(canvas, card.header.right - INTEL_PADDING_X - CHEVRON_SIZE, @divTrunc(card.header.top + card.header.bottom, 2), !card.is_collapsed);
}

pub fn isLayerShown(map_settings: *const panels.MapPanelConfig, layer: Layer) bool {
    return switch (layer) {
        .storms => map_settings.showStorms,
        .incursions => map_settings.showIncursions,
        .sov_timers => map_settings.showSovTimers,
        .wormholes => map_settings.showWormholes,
        .ansiblex => map_settings.showAnsiblex,
        .kills => map_settings.showKills,
        .intel => map_settings.showIntel,
        .names => map_settings.showCharacterNames,
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
    const index = std.mem.indexOfScalar(MapMetric, metrics, current) orelse return metrics[0];
    return metrics[(index + 1) % metrics.len];
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

/// Its occupier's colour, the stronger the further it's contested; HEAT_NONE outside a warzone.
pub fn warfareColor(system: faction_warfare.System) u32 {
    if (system.occupier == faction_warfare.NO_FACTION) return HEAT_NONE;
    const shade = factionColorOf(system.occupier);
    const percent = WARFARE_CALM_PERCENT + @as(u32, system.contested_percent) * (100 - WARFARE_CALM_PERCENT) / 100;
    return color.mix(shade, HEAT_NONE, percent);
}

/// `place` is an occupier or owner, past NO_FACTION.
pub fn factionColorOf(place: u8) u32 {
    return holder_colors.factionColor(faction_warfare.faction(place).id) orelse list_look.MUTED;
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

/// From a system with a sov timer to where its name may start, past the timer's square.
pub fn timerLabelClearance(zoom: f32) i32 {
    return @as(i32, @intFromFloat(@ceil(TIMER_MARK_SIZE * markerScale(zoom)))) + TIMER_LABEL_GAP;
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

/// Behind the selected system's marker.
pub fn drawFocusMark(canvas: pixel_buffer.Canvas, x: i32, y: i32, radius: f32) void {
    pixel_buffer.fillCircle(canvas, x, y, radius, FOCUS_MARK);
}

/// A card holding text, the Intel card or a legend, drawn like the bars so the map's controls match.
pub fn drawCard(canvas: pixel_buffer.Canvas, box: Box) void {
    drawControl(canvas, box, CONTROL_FILL, null);
}

/// A one-pixel line across a card at `y`, between its rows or under a heading.
pub fn drawDivider(canvas: pixel_buffer.Canvas, left: i32, right: i32, y: i32) void {
    fillBox(canvas, .{ .left = left, .top = y, .right = right, .bottom = y + 1 }, 0, CONTROL_DIVIDER);
}

/// The title, like the dialog's profile menu button; `accent` is set while it's hovered or its list is open.
pub fn drawTitleCard(canvas: pixel_buffer.Canvas, box: Box, accent: ?u32) void {
    drawControl(canvas, box, CONTROL_FILL, accent);
}

/// The search box, like the dialog's text fields; `accent` is set while it's hovered or has the keyboard.
pub fn drawSearchCard(canvas: pixel_buffer.Canvas, box: Box, is_open: bool, accent: ?u32) void {
    drawControl(canvas, box, CONTROL_FILL, accent);
    const y = @divTrunc(box.top + box.bottom, 2);
    drawGlyphAt(canvas, .search, box.left + SEARCH_GLYPH_X, y, if (is_open) SEGMENT_TEXT else CARD_MUTED);
}

/// The always on top pin, like the dialog's icon buttons; `hover_accent` is set while it's hovered.
pub fn drawPinButton(canvas: pixel_buffer.Canvas, box: Box, is_always_on_top: bool, hover_accent: ?u32) void {
    drawControl(canvas, box, if (hover_accent != null) CONTROL_HOVER else CONTROL_FILL, hover_accent);
    drawMapControlGlyph(canvas, box, .always_on_top, is_always_on_top);
}

/// Layers gets two stacked sheets, lit while its menu is open; Follow a crosshair in the active client's colour, grey while it's off.
pub fn drawToggleMark(canvas: pixel_buffer.Canvas, box: Box, toggle: Toggle, is_on: bool, active_color: u32) void {
    const x = box.left + TOGGLE_PADDING_X + TOGGLE_MARK_X;
    const y = @divTrunc(box.top + box.bottom, 2);
    switch (toggle) {
        .follow => drawGlyphAt(canvas, .crosshair, x, y, if (is_on) active_color else CARD_MUTED),
        .layers => drawGlyphAt(canvas, .layers, x, y, if (is_on) list_look.NAME else CARD_MUTED),
    }
}

/// Between Follow and the toggles before it.
pub fn drawToggleDivider(canvas: pixel_buffer.Canvas, bar: Box, x: i32) void {
    const inset = segmented.BAR_INSET + TOGGLE_DIVIDER_INSET;
    fillBox(canvas, .{ .left = x, .top = bar.top + inset, .right = x + 1, .bottom = bar.bottom - inset }, 0, CONTROL_DIVIDER);
}

/// Points down while what it heads is closed, or up while it's open.
pub fn drawChevron(canvas: pixel_buffer.Canvas, x: i32, y: i32, is_open: bool) void {
    drawGlyphAt(canvas, if (is_open) .chevron_up else .chevron_down, x, y, CARD_MUTED);
}

/// The zoom controls as one control, with dividers between them and the hovered one lit like a bar's segment.
pub fn drawZoomStack(canvas: pixel_buffer.Canvas, areas: Areas, hovered: ?MapControl) void {
    drawControl(canvas, areas.zoomStack(), CONTROL_FILL, null);
    for ([_]MapControl{ .zoom_in, .zoom_out, .fit }) |control| {
        const box = areas.mapControlBox(control);
        const inner = insetBox(box, CARD_BORDER_WIDTH);
        if (hovered == control) segmented.fillButton(canvas, insetBox(box, segmented.BAR_INSET), SEGMENT_HOVER);
        if (control != .fit) drawDivider(canvas, inner.left, inner.right, box.bottom - 1);
        drawMapControlGlyph(canvas, box, control, false);
    }
}

/// A legend row's swatch, `line_height` tall around its middle: solid like a marker, or tinted inside a rim like an area.
pub fn drawLegendSwatch(canvas: pixel_buffer.Canvas, left: i32, top: i32, line_height: i32, shade: u32, is_area: bool) void {
    const swatch_top = top + @divTrunc(line_height - LEGEND_SWATCH_SIZE, 2);
    const swatch: Box = .{ .left = left, .top = swatch_top, .right = left + LEGEND_SWATCH_SIZE, .bottom = swatch_top + LEGEND_SWATCH_SIZE };
    if (is_area) {
        popup_look.drawBorderedBox(canvas, swatch, LEGEND_SWATCH_RADIUS, color.mix(shade, CONTROL_FILL, LEGEND_AREA_TINT_PERCENT), shade);
    } else {
        fillBox(canvas, swatch, LEGEND_SWATCH_RADIUS, shade);
    }
}

/// Between the legend card's sections, at `y`, set in like the Intel card's.
pub fn drawLegendDivider(canvas: pixel_buffer.Canvas, card: Box, y: i32) void {
    drawDivider(canvas, card.left + ROW_INSET, card.right - ROW_INSET, y);
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

/// From just outside the rings `reach` around the marker at `x`,`y` to its tag's `box`.
pub fn drawClientLead(canvas: pixel_buffer.Canvas, x: i32, y: i32, reach: f32, box: Box, tag_color: u32) void {
    const to_x = if (box.left > x) box.left else box.right - 1;
    const to_y = @divTrunc(box.top + box.bottom, 2);
    const delta_x: f32 = @floatFromInt(to_x - x);
    const delta_y: f32 = @floatFromInt(to_y - y);
    const length = @sqrt(delta_x * delta_x + delta_y * delta_y);
    if (length <= reach) return;
    const from_x = x + @as(i32, @intFromFloat(@round(delta_x * reach / length)));
    const from_y = y + @as(i32, @intFromFloat(@round(delta_y * reach / length)));
    pixel_buffer.drawLine(canvas, from_x, from_y, to_x, to_y, tag_color);
}

/// `offset` from the marker at `x`,`y`, stepped up then down, further each time, until its chip is clear of `taken`, as names mostly sit below; null when no step inside `area` is.
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
        if (!layout.chipBox(box).overlapsAny(taken)) return box;
    }
    return null;
}

/// How warm `value` looks beside the busiest system shown, `peak`; a square root, so a quiet system isn't lost next to Jita.
pub fn heatColor(value: u32, peak: u32) u32 {
    if (value == 0 or peak == 0) return HEAT_NONE;
    const percent: u32 = @intFromFloat(heatShare(value, peak) * 100);
    return color.mix(HEAT_HIGH, HEAT_LOW, percent);
}

/// Warm where NPC kills rose on the hour, cool where they fell, by the largest change shown, `peak`.
pub fn deltaColor(delta: i32, peak: u32) u32 {
    if (delta == 0 or peak == 0) return HEAT_NONE;
    if (delta > 0) return heatColor(@intCast(delta), peak);
    const percent: u32 = @intFromFloat(heatShare(@abs(delta), peak) * 100);
    return color.mix(DROP_HIGH, DROP_LOW, percent);
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

/// Null once `age_ms` reaches RIPPLE_MS; eased out, so the ring slows as it fades.
pub fn rippleAt(age_ms: u64) ?Ripple {
    if (age_ms >= RIPPLE_MS) return null;
    const progress = @as(f32, @floatFromInt(age_ms)) / @as(f32, @floatFromInt(RIPPLE_MS));
    const eased = 1 - (1 - progress) * (1 - progress);
    return .{
        .radius = RIPPLE_START_RADIUS + (RIPPLE_END_RADIUS - RIPPLE_START_RADIUS) * eased,
        .alpha = @intFromFloat(255 * (1 - progress)),
    };
}

/// The view that pans a ping at `x`,`y` to the middle of the map left of the cards, when its ring would spread under `covered` or past the panel; null when it shows whole already.
pub fn revealedView(view: layout.View, areas: Areas, covered: []const Box, x: i32, y: i32) ?layout.View {
    const reach: i32 = @intFromFloat(@ceil(RIPPLE_END_RADIUS * markerScale(view.zoom)));
    const ring: Box = .{ .left = x - reach, .top = y - reach, .right = x + reach, .bottom = y + reach };
    if (!ring.overlapsAny(covered) and areas.body.contains(ring)) return null;
    const free_right = if (areas.intel_width > 0) @max(areas.map.left, areas.search_box.left - CARD_GAP) else areas.map.right;
    const target_x = @divTrunc(areas.map.left + free_right, 2);
    const target_y = @divTrunc(areas.map.top + areas.map.bottom, 2);
    return view.panned(areas.map, @floatFromInt(target_x - x), @floatFromInt(target_y - y));
}

pub fn drawRipple(canvas: pixel_buffer.Canvas, x: i32, y: i32, ripple: Ripple, scale: f32, ring_color: u32) void {
    pixel_buffer.drawRing(canvas, x, y, ripple.radius * scale, RIPPLE_THICKNESS, color.withAlpha(ring_color, ripple.alpha));
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

/// Dashed, so it doesn't read as a gate, ending in a ring for the wormhole.
pub fn drawPortal(canvas: pixel_buffer.Canvas, node: layout.Node, portal: layout.Portal, portal_color: u32) void {
    const delta_x: f32 = @floatFromInt(portal.x - node.x);
    const delta_y: f32 = @floatFromInt(portal.y - node.y);
    for (0..PORTAL_DASHES) |dash| {
        const start: f32 = @as(f32, @floatFromInt(2 * dash)) / (2 * PORTAL_DASHES - 1);
        const end: f32 = @as(f32, @floatFromInt(2 * dash + 1)) / (2 * PORTAL_DASHES - 1);
        pixel_buffer.drawLine(canvas, node.x + @as(i32, @intFromFloat(@round(delta_x * start))), node.y + @as(i32, @intFromFloat(@round(delta_y * start))), node.x + @as(i32, @intFromFloat(@round(delta_x * end))), node.y + @as(i32, @intFromFloat(@round(delta_y * end))), portal_color);
    }
    pixel_buffer.drawRing(canvas, portal.x, portal.y, PORTAL_RING_RADIUS, RING_THICKNESS, portal_color);
}

/// An Ansiblex gate between two systems shown, arched off the gates' straight lines and dashed; one gate each way draws the same arc.
pub fn drawBridge(canvas: pixel_buffer.Canvas, map_layout: *const layout.Layout, first_index: u16, second_index: u16, bridge_color: u32) void {
    const low = @min(first_index, second_index);
    const high = @max(first_index, second_index);
    const delta_x: f32 = @floatFromInt(map_layout.nodes[high].x - map_layout.nodes[low].x);
    const delta_y: f32 = @floatFromInt(map_layout.nodes[high].y - map_layout.nodes[low].y);
    const edge: layout.Edge = .{ .first_index = low, .second_index = high, .kind = .between_regions, .bend = @sqrt(delta_x * delta_x + delta_y * delta_y) * BRIDGE_BEND_SHARE };
    var points: [BRIDGE_SAMPLES + 1][2]f32 = undefined;
    for (&points, 0..) |*point, step| point.* = map_layout.edgePlace(edge, @as(f32, @floatFromInt(step)) / BRIDGE_SAMPLES);
    drawDashed(canvas, &points, bridge_color);
}

/// A small triangle up and to the right of the system, pointing at it, fading as `freshness_percent` falls.
pub fn drawKillMark(canvas: pixel_buffer.Canvas, x: i32, y: i32, scale: f32, freshness_percent: u8) void {
    const alpha: u8 = @intCast(KILL_MIN_ALPHA + (255 - KILL_MIN_ALPHA) * @as(u32, @min(freshness_percent, 100)) / 100);
    const shade = color.withAlpha(KILL, alpha);
    const offset: i32 = @intFromFloat(KILL_MARK_OFFSET * scale);
    const size: i32 = @intFromFloat(@max(2, KILL_MARK_SIZE * scale));
    const middle_x = x + offset;
    const middle_y = y - offset;
    var row: i32 = -size;
    while (row <= size) : (row += 1) {
        const half = @divTrunc(size - row, 2);
        pixel_buffer.drawLine(canvas, middle_x - half, middle_y + row, middle_x + half, middle_y + row, shade);
    }
}

/// A cross, which reads through whatever colour the marker under it has.
pub fn drawAvoidMark(canvas: pixel_buffer.Canvas, x: i32, y: i32) void {
    pixel_buffer.drawLine(canvas, x - AVOID_MARK_SIZE, y - AVOID_MARK_SIZE, x + AVOID_MARK_SIZE, y + AVOID_MARK_SIZE, AVOID);
    pixel_buffer.drawLine(canvas, x - AVOID_MARK_SIZE, y + AVOID_MARK_SIZE, x + AVOID_MARK_SIZE, y - AVOID_MARK_SIZE, AVOID);
}

/// A square, as every other mark on the map is round or a diamond: its corners only until the timer starts, then whole; drawn twice over, one pixel in, as a single line is too thin to find.
pub fn drawTimerMark(canvas: pixel_buffer.Canvas, x: i32, y: i32, scale: f32, has_started: bool) void {
    const size: i32 = @intFromFloat(TIMER_MARK_SIZE * scale);
    const corner: i32 = if (has_started) size else @intFromFloat(TIMER_CORNER_LENGTH * scale);
    for ([_]i32{ size, size - 1 }) |reach| {
        for ([_]i32{ -1, 1 }) |side_x| {
            for ([_]i32{ -1, 1 }) |side_y| {
                const corner_x = x + side_x * reach;
                const corner_y = y + side_y * reach;
                pixel_buffer.drawLine(canvas, corner_x, corner_y, corner_x - side_x * corner, corner_y, SOV_TIMER);
                pixel_buffer.drawLine(canvas, corner_x, corner_y, corner_x, corner_y - side_y * corner, SOV_TIMER);
            }
        }
    }
}

pub fn regionRangeColor(systems_in_range: u16) u32 {
    return if (systems_in_range > 0) RANGE else OUT_OF_RANGE;
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

fn drawMapControlGlyph(canvas: pixel_buffer.Canvas, box: Box, control: MapControl, is_always_on_top: bool) void {
    const x = @divTrunc(box.left + box.right, 2);
    const y = @divTrunc(box.top + box.bottom, 2);
    switch (control) {
        .zoom_in => drawGlyphAt(canvas, .add, x, y, SEGMENT_TEXT),
        .zoom_out => drawGlyphAt(canvas, .minus, x, y, SEGMENT_TEXT),
        .fit => drawGlyphAt(canvas, .fit, x, y, SEGMENT_TEXT),
        .always_on_top => drawGlyphAt(canvas, .pin, x, y, if (is_always_on_top) SEGMENT_TEXT else CARD_MUTED),
    }
}

/// Dashes carry on across the corners between `points`.
fn drawDashed(canvas: pixel_buffer.Canvas, points: []const [2]f32, line_color: u32) void {
    if (points.len < 2) return;
    var is_dash = true;
    var run_left = BRIDGE_DASH_LENGTH;
    for (points[0 .. points.len - 1], points[1..]) |from, to| {
        const delta_x = to[0] - from[0];
        const delta_y = to[1] - from[1];
        const length = @sqrt(delta_x * delta_x + delta_y * delta_y);
        if (length == 0) continue;
        var travelled: f32 = 0;
        while (length - travelled > run_left) {
            const next = travelled + run_left;
            if (is_dash) drawPart(canvas, from, delta_x / length, delta_y / length, travelled, next, line_color);
            travelled = next;
            is_dash = !is_dash;
            run_left = if (is_dash) BRIDGE_DASH_LENGTH else BRIDGE_GAP_LENGTH;
        }
        if (is_dash) drawPart(canvas, from, delta_x / length, delta_y / length, travelled, length, line_color);
        run_left -= length - travelled;
    }
}

/// From `start` to `end` pixels along the direction `unit_x`, `unit_y` out of `from`.
fn drawPart(canvas: pixel_buffer.Canvas, from: [2]f32, unit_x: f32, unit_y: f32, start: f32, end: f32, line_color: u32) void {
    pixel_buffer.drawLineExact(canvas, from[0] + unit_x * start, from[1] + unit_y * start, from[0] + unit_x * end, from[1] + unit_y * end, line_color);
}

/// Top right, narrowing with `body`, the map, to leave the map room.
fn searchBox(body: Box, card_height: i32) Box {
    const width = @min(SIDE_COLUMN_WIDTH, @divTrunc(body.right - body.left, 3));
    const right = body.right - CARD_MARGIN;
    const top = body.top + CARD_MARGIN;
    return .{ .left = right - width, .top = top, .right = right, .bottom = top + card_height };
}

/// A lit row's fill: between `left` and `right`, and clear of the dividers above and below.
fn rowHighlight(row: Box, left: i32, right: i32) Box {
    return .{ .left = left, .top = row.top + 2, .right = right, .bottom = row.bottom - 3 };
}

/// Its border takes `accent` while lit, as the dialog's controls do on hover.
fn drawControl(canvas: pixel_buffer.Canvas, box: Box, fill: u32, accent: ?u32) void {
    popup_look.drawBorderedBox(canvas, box, palette.RADIUS, fill, accent orelse CONTROL_BORDER);
}

fn insetBox(box: Box, by: i32) Box {
    return .{ .left = box.left + by, .top = box.top + by, .right = box.right - by, .bottom = box.bottom - by };
}

/// Skipped while `box` is empty or reaches off the canvas's top or left, which the pixel calls can't take.
fn fillBox(canvas: pixel_buffer.Canvas, box: Box, radius: usize, fill: u32) void {
    if (box.left < 0 or box.top < 0 or box.right <= box.left or box.bottom <= box.top) return;
    pixel_buffer.fillRoundedRect(canvas, @intCast(box.left), @intCast(box.top), @intCast(box.right - box.left), @intCast(box.bottom - box.top), radius, fill);
}

/// Centred on `x`,`y`.
fn drawGlyphAt(canvas: pixel_buffer.Canvas, glyph: glyphs.Glyph, x: i32, y: i32, glyph_color: u32) void {
    glyphs.draw(canvas, glyph, x - @divTrunc(glyphs.SIZE, 2), y - @divTrunc(glyphs.SIZE, 2), glyph_color);
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

fn testChromeText(title_width: i32) ChromeText {
    return .{ .title_width = title_width, .title_height = 20, .metric_widths = @splat(40), .toggle_widths = @splat(50) };
}

test "metricValue counts ships and pods apart, and Security counts nothing" {
    const stats: SystemStats = .{ .ship_kills = 3, .pod_kills = 2, .npc_kills = 40, .jumps = 9 };
    try testing.expectEqual(@as(u32, 3), metricValue(.ShipKills, stats));
    try testing.expectEqual(@as(u32, 2), metricValue(.PodKills, stats));
    try testing.expectEqual(@as(u32, 40), metricValue(.NpcKills, stats));
    try testing.expectEqual(@as(u32, 9), metricValue(.Jumps, stats));
    try testing.expectEqual(@as(u32, 0), metricValue(.Security, stats));
}

test "a warzone system grows stronger in its occupier's colour as it's contested" {
    try testing.expectEqual(HEAT_NONE, warfareColor(.{}));
    const calm = warfareColor(.{ .occupier = 1 });
    const contested = warfareColor(.{ .occupier = 1, .contested_percent = 100 });
    try testing.expectEqual(factionColorOf(1), contested);
    try testing.expect(calm != contested and calm != HEAT_NONE);
}

test "a rise in NPC kills is warm, a fall cool, and none quiet" {
    try testing.expectEqual(HEAT_NONE, deltaColor(0, 10));
    try testing.expectEqual(HEAT_HIGH, deltaColor(10, 10));
    try testing.expectEqual(DROP_HIGH, deltaColor(-10, 10));
}

test "every metric sits in its own segment's list" {
    for (std.enums.values(MapMetric)) |metric| {
        try testing.expect(std.mem.indexOfScalar(MapMetric, segmentMetrics(segmentOf(metric)), metric) != null);
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

test "the search box spans the side column top right, and narrows with the map" {
    const wide: Areas = .init(800, 600, 22, false);
    try testing.expectEqual(SIDE_COLUMN_WIDTH, wide.search_box.right - wide.search_box.left);
    try testing.expectEqual(wide.mapControlBox(.fit).right, wide.search_box.right);
    try testing.expectEqual(wide.body.top + CARD_MARGIN, wide.search_box.top);
    const narrow: Areas = .init(300, 200, 22, false);
    try testing.expectEqual(@as(i32, 100), narrow.search_box.right - narrow.search_box.left);
}

test "at the smallest window the cards keep clear of each other and the controls" {
    // Geist's sizes at the panel's fonts: the widest region's title, the metric labels in semibold, and the toggles'.
    const text: ChromeText = .{ .title_width = 169, .title_height = 22, .metric_widths = .{ 49, 26, 58, 39, 22, 18 }, .toggle_widths = .{ 44, 37 } };
    const width = panels.MapPanelConfig.MIN_WIDTH;
    const height = panels.MapPanelConfig.MIN_HEIGHT;
    const areas: Areas = .init(width, height, palette.CONTROL_HEIGHT, true);
    const chrome: Chrome = .init(areas, text);
    const zoom = areas.zoomStack();
    try testing.expect(chrome.toggle_bar.right <= zoom.left - CARD_GAP);
    try testing.expect(chrome.metric_bar.right <= zoom.left - CARD_GAP);
    try testing.expectEqual(chrome.metric_bar.top - CARD_GAP, chrome.toggle_bar.bottom);
    const card: IntelCard = .init(areas, areas.intelTop(), intelHeaderHeight(areas.card_height), intelRowHeight(17), MIN_INTEL_ROWS, false);
    try testing.expect(card.box.bottom <= areas.mapControlBox(.always_on_top).top - CARD_GAP);
    try testing.expect(chrome.title.right <= areas.search_box.left - CARD_GAP);
}

test "the map's body fills the panel, and the map keeps clear of the top and bottom cards" {
    const areas: Areas = .init(800, 600, 22, false);
    try testing.expectEqual(Box{ .left = 0, .top = 0, .right = 800, .bottom = 600 }, areas.body);
    try testing.expect(areas.map.top >= areas.search_box.bottom);
    try testing.expect(areas.map.bottom <= areas.body.bottom - CARD_MARGIN - 2 * areas.card_height - CARD_GAP);
}

test "the map stays centred across the panel while the Intel card shows" {
    const areas: Areas = .init(800, 600, 22, true);
    try testing.expectEqual(areas.map.left - areas.body.left, areas.body.right - areas.map.right);
    try testing.expectEqual(Areas.init(800, 600, 22, false).map, areas.map);
}

test "the Intel card spans the search box" {
    for ([_]i32{ 300, 800, 1200 }) |width| {
        const areas: Areas = .init(width, 600, 22, true);
        const card: IntelCard = .init(areas, areas.intelTop(), intelHeaderHeight(areas.card_height), intelRowHeight(14), 3, false);
        try testing.expectEqual(areas.search_box.left, card.box.left);
        try testing.expectEqual(areas.search_box.right, card.box.right);
    }
}

test "the Intel card fits what it can above the map controls, between two and six rows" {
    const row_height = intelRowHeight(14);
    const tall: Areas = .init(800, 1200, 22, true);
    try testing.expectEqual(@as(usize, MAX_INTEL_ROWS), IntelCard.capacity(tall.intelTop(), tall.sideBottom(), intelHeaderHeight(tall.card_height), row_height));
    const short: Areas = .init(800, 240, 22, true);
    try testing.expectEqual(@as(usize, MIN_INTEL_ROWS), IntelCard.capacity(short.intelTop(), short.sideBottom(), intelHeaderHeight(short.card_height), row_height));
    const fitting: Areas = .init(800, 600, 22, true);
    const capacity = IntelCard.capacity(fitting.intelTop(), fitting.sideBottom(), intelHeaderHeight(fitting.card_height), row_height);
    const card: IntelCard = .init(fitting, fitting.intelTop(), intelHeaderHeight(fitting.card_height), row_height, capacity, false);
    try testing.expect(card.box.bottom <= fitting.mapControlBox(.always_on_top).top - CARD_GAP);
}

test "a list card fits rows down to its bottom, and an empty one keeps a row to say so" {
    const areas: Areas = .init(800, 600, 22, true);
    const card: ListCard = .init(areas, 300, 500, 26, 20, 40, false);
    try testing.expectEqual(@as(usize, 8), card.visible_count);
    try testing.expectEqual(@as(usize, 8), card.row_count);
    try testing.expect(card.box.bottom <= 500);
    try testing.expectEqual(@as(?usize, 1), card.rowAt(card.rows[1].left, card.rows[1].top));
    const empty: ListCard = .init(areas, 300, 500, 26, 20, 0, false);
    try testing.expectEqual(empty.header.bottom + 20, empty.box.bottom);
}

test "a collapsed Intel card is its header alone, and an empty one keeps a row to say so" {
    const areas: Areas = .init(800, 600, 22, true);
    const header_height = intelHeaderHeight(areas.card_height);
    const collapsed: IntelCard = .init(areas, areas.intelTop(), header_height, 40, 4, true);
    try testing.expectEqual(collapsed.header, collapsed.box);
    try testing.expectEqual(@as(usize, 0), collapsed.row_count);
    const empty: IntelCard = .init(areas, areas.intelTop(), header_height, 40, 0, false);
    try testing.expectEqual(empty.header.bottom + 40, empty.box.bottom);
    const listed: IntelCard = .init(areas, areas.intelTop(), header_height, 40, 3, false);
    try testing.expectEqual(@as(?usize, 2), listed.rowAt(listed.rows[2].left, listed.rows[2].top));
    try testing.expectEqual(@as(?usize, null), listed.rowAt(listed.header.left, listed.header.top));
}

test "a panel shorter than its cards keeps empty areas rather than inverted ones" {
    const areas: Areas = .init(400, 20, 22, false);
    try testing.expectEqual(@as(i32, 20), areas.body.bottom);
    try testing.expectEqual(areas.map.top, areas.map.bottom);
}

test "the metric bar is centred along the bottom, and each segment finds its metric" {
    const areas: Areas = .init(1000, 700, 22, false);
    const chrome: Chrome = .init(areas, testChromeText(80));
    try testing.expectEqual(areas.body.bottom - CARD_MARGIN, chrome.metric_bar.bottom);
    try testing.expectApproxEqAbs(@as(f32, 500), @as(f32, @floatFromInt(chrome.metric_bar.left + chrome.metric_bar.right)) / 2, 1);
    for (SEGMENT_ORDER, chrome.metrics) |segment, box| {
        try testing.expect(chrome.metric_bar.contains(box));
        try testing.expectEqual(@as(?MetricSegment, segment), chrome.segmentAt(box.left, box.top));
    }
    try testing.expectEqual(@as(?MetricSegment, null), chrome.segmentAt(chrome.metric_bar.left, chrome.metric_bar.top));
    try testing.expect(chrome.hasBarAt(chrome.metric_bar.left, chrome.metric_bar.top));
}

test "the title card stops short of the search box" {
    const areas: Areas = .init(700, 700, 22, false);
    const chrome: Chrome = .init(areas, testChromeText(2000));
    try testing.expectEqual(areas.search_box.left - CARD_GAP, chrome.title.right);
}

test "the toggle bar sits on the metric bar clear of the zoom controls, with Follow past its divider" {
    const areas: Areas = .init(560, 700, 22, false);
    const chrome: Chrome = .init(areas, testChromeText(80));
    try testing.expectEqual(chrome.metric_bar.top - CARD_GAP, chrome.toggle_bar.bottom);
    try testing.expectEqual(Box{ .left = @min(chrome.metric_bar.left, chrome.toggle_bar.left), .top = chrome.toggle_bar.top, .right = @max(chrome.metric_bar.right, chrome.toggle_bar.right), .bottom = chrome.metric_bar.bottom }, chrome.bottomBars());
    try testing.expect(chrome.toggle_bar.right <= areas.zoomStack().left - CARD_GAP);
    for (TOGGLE_ORDER, chrome.toggles) |toggle, box| try testing.expectEqual(@as(?Toggle, toggle), chrome.toggleAt(box.left, box.top));
    const divider = chrome.toggleDividerX();
    try testing.expect(divider > chrome.toggles[@backingInt(Toggle.layers)].right);
    try testing.expect(divider < chrome.toggles[@backingInt(Toggle.follow)].left);
}

test "the bottom bars are centred with room to spare, and keep to the left together without it" {
    const wide: Areas = .init(1000, 700, 22, false);
    const centred: Chrome = .init(wide, testChromeText(80));
    try testing.expect(@abs(wide.body.right - centred.toggle_bar.right - centred.toggle_bar.left) <= 1);
    try testing.expect(@abs(wide.body.right - centred.metric_bar.right - centred.metric_bar.left) <= 1);
    const narrow: Chrome = .init(.init(300, 700, 22, false), testChromeText(80));
    try testing.expectEqual(CARD_MARGIN, narrow.toggle_bar.left);
    try testing.expectEqual(CARD_MARGIN, narrow.metric_bar.left);
}

test "the bottom bars keep to the left until centring both clears the legends" {
    const areas: Areas = .init(1000, 700, 22, false);
    var text = testChromeText(80);
    text.legend_width = 200;
    try testing.expect(Chrome.init(areas, text).metric_bar.left >= CARD_MARGIN + text.legend_width + CARD_GAP);
    text.legend_width = 400;
    const crowded: Chrome = .init(areas, text);
    try testing.expectEqual(CARD_MARGIN, crowded.metric_bar.left);
    try testing.expectEqual(CARD_MARGIN, crowded.toggle_bar.left);
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

test "the zoom controls stack bottom right, the pin alone above them, and each finds itself" {
    const areas: Areas = .init(800, 600, 22, false);
    for (std.enums.values(MapControl)) |control| {
        const box = areas.mapControlBox(control);
        try testing.expect(areas.body.contains(box));
        try testing.expectEqual(@as(?MapControl, control), areas.mapControlAt(box.left, box.top));
    }
    try testing.expectEqual(areas.body.bottom - CARD_MARGIN, areas.mapControlBox(.fit).bottom);
    try testing.expectEqual(areas.mapControlBox(.zoom_in).bottom, areas.mapControlBox(.zoom_out).top);
    try testing.expectEqual(areas.zoomStack().top - CARD_GAP, areas.mapControlBox(.always_on_top).bottom);
    try testing.expectEqual(@as(?MapControl, null), areas.mapControlAt(0, 0));
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
    try testing.expectEqual(@as(u16, stats_mod.NO_HOLDER), holders[(region + 1) % universe.REGION_COUNT]);
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

test "a client tag keeps its chip's padding from a name, not just its text" {
    const beside = clientTagBox(TEST_AREA, 100, 100, CLIENT_TAG_OFFSET, 60, 14, &.{}).?;
    const name: Box = .{ .left = beside.left, .top = beside.bottom + 1, .right = beside.right, .bottom = beside.bottom + 15 };
    const moved = clientTagBox(TEST_AREA, 100, 100, CLIENT_TAG_OFFSET, 60, 14, &.{name}).?;
    try testing.expect(!std.meta.eql(moved, beside));
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

test "a new pin's ripple spreads and fades once, then is gone" {
    const start = rippleAt(0).?;
    try testing.expectEqual(RIPPLE_START_RADIUS, start.radius);
    try testing.expectEqual(@as(u8, 255), start.alpha);
    const later = rippleAt(RIPPLE_MS / 2).?;
    try testing.expect(later.radius > start.radius and later.radius < RIPPLE_END_RADIUS);
    try testing.expect(later.alpha < start.alpha);
    try testing.expectEqual(@as(?Ripple, null), rippleAt(RIPPLE_MS));
}

test "a ping under the side cards pans left of them, and one in the clear stays put" {
    const areas: Areas = .init(800, 600, 30, true);
    const card: Box = .{ .left = areas.search_box.left, .top = areas.intelTop(), .right = areas.body.right - CARD_MARGIN, .bottom = 400 };
    const covered = [_]Box{card};
    try testing.expectEqual(@as(?layout.View, null), revealedView(.{}, areas, &covered, 200, 300));
    const moved = revealedView(.{}, areas, &covered, card.left + 20, 300).?;
    const moved_x = card.left + 20 + @as(i32, @intFromFloat(moved.pan_x));
    try testing.expect(moved_x < card.left - CARD_GAP);
}

test "a storm's periphery gates are fainter than its core's" {
    const core = stormEdgeColor(.{ .kind = .plasma, .is_core = true });
    try testing.expectEqual(STORM_PLASMA, core);
    try testing.expect(stormEdgeColor(.{ .kind = .plasma, .is_core = false }) != core);
}
