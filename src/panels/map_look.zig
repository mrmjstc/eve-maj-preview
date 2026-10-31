//! The Map Panel's look: its sizes, footer buttons, region picker, map markers and tooltip text; no I/O.
const std = @import("std");
const types = @import("../config/types.zig");
const display_mod = @import("../config/display.zig");
const list_look = @import("list_look.zig");
const panel_look = @import("panel_look.zig");
const universe = @import("../map/universe.zig");
const layout = @import("../map/layout.zig");
const stats_mod = @import("../map/stats.zig");
const evestars = @import("../map/evestars.zig");
const color = @import("../util/color.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");
const utf8 = @import("../util/utf8.zig");

const Box = layout.Box;
const DisplayConfig = display_mod.DisplayConfig;
const MapMetric = types.MapMetric;
const RegionIndex = universe.RegionIndex;
const SystemIndex = universe.SystemIndex;
const SystemStats = stats_mod.SystemStats;
const Snapshot = stats_mod.Snapshot;

/// The most lines a tooltip holds, for a system with everything to report.
pub const TOOLTIP_MAX_LINES = 9;
/// Around a tooltip's text, and how far it keeps from what it describes.
pub const TOOLTIP_PADDING: i32 = 6;
/// Fits a line's longest text, cut to size past that.
pub const TOOLTIP_LINE_MAX = 128;
/// Between a popup's rows.
pub const POPUP_ROW_GAP: i32 = 4;
/// So the results don't resize as names come and go.
pub const SEARCH_WIDTH: i32 = 280;
const SEARCH_BOX_WIDTH: i32 = 180;
/// Between the search box and the map's edges.
const SEARCH_BOX_MARGIN: i32 = 6;
const PICKER_LINE_PADDING: i32 = 4;
const NODE_RADIUS: f32 = 3.5;
/// How much bigger the busiest system's marker is than a quiet one's.
const HEAT_RADIUS_GROWTH: f32 = 3;
/// Just outside a client's ring, so neither hides the other.
const INTEL_HALO_RADIUS: f32 = 11;
const INTEL_HALO_PEAK_RADIUS: f32 = 28;
/// Around a marked system's marker.
pub const RING_GAP: f32 = 3;
pub const RING_THICKNESS: f32 = 1.5;
const EXIT_RADIUS: f32 = 2;
/// Past this, a line of who's in a system stops naming them.
const MAX_CHARACTERS_NAMED = 4;
/// Fits securityText's longest result.
const SECURITY_TEXT_MAX = 8;
/// Between a search result's parts.
const HIT_GAP = "  ";

// The colours below are 0xAARRGGBB, not premultiplied.
pub const EDGE_LOCAL: u32 = 0xFF4A4D55;
pub const EDGE_CROSS: u32 = 0xFF6E5A7A;
pub const EDGE_HOVER: u32 = 0xFFB9BCC4;
pub const EXIT: u32 = 0xFFA08A4E;
const INTEL: u32 = 0xFFFF4B3E;
const INTEL_CLEAR: u32 = 0xFFFFD23F;
pub const FOCUS: u32 = 0xFFE8E6E1;
pub const TOOLTIP_FILL: u32 = 0xFF1E2024;
const HEAT_NONE: u32 = 0xFF3A3C42;
const HEAT_LOW: u32 = 0xFFD9A441;
const HEAT_HIGH: u32 = 0xFFFF3B30;
/// EVE's own colours, by shown security in tenths from 0 up.
const SECURITY_COLORS = [_]u32{ 0xFFF00000, 0xFFD73000, 0xFFF04800, 0xFFF06000, 0xFFD77700, 0xFFEFEF00, 0xFF8FEF2F, 0xFF00F000, 0xFF00EF47, 0xFF48F0C0, 0xFF2FEFEF };

/// In the footer, left to right.
pub const Button = enum { regions, security, kills, npc_kills, jumps, follow };
pub const BUTTON_ORDER = std.enums.values(Button);

/// A stretch of a row's text in its own colour, as byte offsets into it.
pub const Accent = struct {
    start: usize,
    end: usize,
    color: u32,
};

pub const HitLabel = struct {
    text: evestars.Text,
    security: Accent,
};

/// The panel's sizes for the current settings, in pixels; its width and height are the configured ones.
pub const Metrics = struct {
    header_height: i32,
    footer_height: i32,
};

/// The regions in a grid filling `area`, read down each column.
pub const PickerGrid = struct {
    area: Box,
    column_count: i32,
    row_count: i32,

    /// As few columns as let every name have a line of `line_height`.
    pub fn init(area: Box, line_height: i32) PickerGrid {
        const region_count: i32 = universe.REGION_COUNT;
        const height = @max(1, area.bottom - area.top);
        const rows_that_fit = @max(1, @divTrunc(height, line_height + PICKER_LINE_PADDING));
        const column_count = std.math.divCeil(i32, region_count, rows_that_fit) catch unreachable;
        const row_count = std.math.divCeil(i32, region_count, column_count) catch unreachable;
        return .{ .area = area, .column_count = column_count, .row_count = row_count };
    }

    pub fn cell(self: PickerGrid, region: RegionIndex) Box {
        const column = @divTrunc(@as(i32, region), self.row_count);
        const row = @mod(@as(i32, region), self.row_count);
        const width = self.area.right - self.area.left;
        const height = self.area.bottom - self.area.top;
        return .{
            .left = self.area.left + @divTrunc(width * column, self.column_count),
            .top = self.area.top + @divTrunc(height * row, self.row_count),
            .right = self.area.left + @divTrunc(width * (column + 1), self.column_count),
            .bottom = self.area.top + @divTrunc(height * (row + 1), self.row_count),
        };
    }

    /// Searched linearly, so it agrees with `cell` however its edges round.
    pub fn regionAt(self: PickerGrid, x: i32, y: i32) ?RegionIndex {
        for (0..universe.REGION_COUNT) |index| {
            const region: RegionIndex = @intCast(index);
            const box = self.cell(region);
            if (x >= box.left and x < box.right and y >= box.top and y < box.bottom) return region;
        }
        return null;
    }
};

/// Rows over the map, running on into more columns if the area is too short: the destination menu and search results.
pub const PopupGrid = struct {
    box: Box,
    row_count: usize,
    row_height: i32,
    column_width: i32,
    rows_per_column: i32,

    /// Beside `x`,`y`, like a tooltip; `row_height` must be above zero.
    pub fn init(area: Box, x: i32, y: i32, row_count: usize, column_width: i32, row_height: i32) PopupGrid {
        const signed_count: i32 = @intCast(@max(1, row_count));
        const rows_that_fit = @max(1, @divTrunc(area.bottom - area.top - 2 * TOOLTIP_PADDING, row_height));
        const rows_per_column = @min(signed_count, rows_that_fit);
        const column_count = std.math.divCeil(i32, signed_count, rows_per_column) catch unreachable;
        const box = tooltipBox(area, x, y, column_count * column_width + 2 * TOOLTIP_PADDING, rows_per_column * row_height + 2 * TOOLTIP_PADDING);
        return .{ .box = box, .row_count = row_count, .row_height = row_height, .column_width = column_width, .rows_per_column = rows_per_column };
    }

    pub fn cell(self: PopupGrid, index: usize) Box {
        const signed_index: i32 = @intCast(index);
        const left = self.box.left + TOOLTIP_PADDING + @divTrunc(signed_index, self.rows_per_column) * self.column_width;
        const top = self.box.top + TOOLTIP_PADDING + @mod(signed_index, self.rows_per_column) * self.row_height;
        return .{ .left = left, .top = top, .right = left + self.column_width, .bottom = top + self.row_height };
    }

    /// Searched linearly, so it agrees with `cell`.
    pub fn rowAt(self: PopupGrid, x: i32, y: i32) ?usize {
        for (0..self.row_count) |index| {
            const box = self.cell(index);
            if (x >= box.left and x < box.right and y >= box.top and y < box.bottom) return index;
        }
        return null;
    }
};

/// What a system's tooltip reports; its slices are borrowed for the call.
pub const SystemFacts = struct {
    system: SystemIndex,
    /// Null until the first fetch.
    stats: ?*const Snapshot = null,
    /// The active client, for how far away the system is.
    active_character: ?[]const u8 = null,
    /// Null when the active client's system isn't known or doesn't connect.
    jumps_from_active: ?u8 = null,
    /// Characters in the system.
    characters: []const []const u8 = &.{},
    /// Null without a live intel pin.
    intel_message: ?[]const u8 = null,
    intel_age_ms: u64 = 0,
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
        .security => "Security",
        .kills => "Kills",
        .npc_kills => "NPC",
        .jumps => "Jumps",
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
        .regions, .follow => null,
    };
}

/// Zero for Security, which colours by the system rather than its traffic.
pub fn metricValue(metric: MapMetric, stats: SystemStats) u32 {
    return switch (metric) {
        .Security => 0,
        .ShipKills => @as(u32, stats.ship_kills) + stats.pod_kills,
        .NpcKills => stats.npc_kills,
        .Jumps => stats.jumps,
    };
}

pub fn securityColor(security_tenths: i8) u32 {
    return SECURITY_COLORS[@intCast(std.math.clamp(security_tenths, 0, SECURITY_COLORS.len - 1))];
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

pub fn systemTooltip(facts: SystemFacts) Tooltip {
    var tooltip: Tooltip = .{};
    const info = universe.systemInfo(facts.system);
    tooltip.title_color = securityColor(info.security_tenths);
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

    if (facts.active_character) |name| {
        if (facts.jumps_from_active) |jumps| {
            if (jumps > 0) tooltip.add("{d} {s} from {s}", .{ jumps, if (jumps == 1) "jump" else "jumps", name });
        }
    }
    addCharacters(&tooltip, facts.characters);
    if (facts.intel_message) |message| {
        var age_buf: [panel_look.TIME_TEXT_MAX]u8 = undefined;
        tooltip.add("Intel {s}: {s}", .{ panel_look.relativeTime(&age_buf, facts.intel_age_ms), message });
    }
    return tooltip;
}

pub fn exitTooltip(from: SystemIndex, destination: SystemIndex) Tooltip {
    var tooltip: Tooltip = .{};
    tooltip.add("{s}", .{universe.regionName(universe.systemInfo(destination).region)});
    tooltip.add("{s} to {s}", .{ universe.systemName(from), universe.systemName(destination) });
    tooltip.add("Click to open", .{});
    return tooltip;
}

/// In the bottom right of `area`, the map, narrowing with it to leave the map room.
pub fn searchBox(area: Box, height: i32) Box {
    const width = @min(SEARCH_BOX_WIDTH, @divTrunc(area.right - area.left, 3));
    const right = area.right - SEARCH_BOX_MARGIN;
    const bottom = area.bottom - SEARCH_BOX_MARGIN;
    return .{ .left = right - width, .top = bottom - height, .right = right, .bottom = bottom };
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

pub fn hitLabel(system: SystemIndex) HitLabel {
    const info = universe.systemInfo(system);
    const name = universe.systemName(system);
    var security_buf: [SECURITY_TEXT_MAX]u8 = undefined;
    const security = securityText(&security_buf, info.security_tenths);
    const start = name.len + HIT_GAP.len;
    return .{
        .text = .print("{s}" ++ HIT_GAP ++ "{s}" ++ HIT_GAP ++ "{s}", .{ name, security, universe.regionName(info.region) }),
        .security = .{ .start = start, .end = start + security.len, .color = securityColor(info.security_tenths) },
    };
}

pub fn noticeTooltip(notice: *const evestars.Notice) Tooltip {
    var tooltip: Tooltip = .{ .title_color = if (notice.is_failure) INTEL else list_look.NAME };
    for (0..notice.line_count) |index| tooltip.add("{s}", .{notice.line(index)});
    return tooltip;
}

/// Beside `x`,`y` while there's room, else on the other side; always inside `area`.
pub fn tooltipBox(area: Box, x: i32, y: i32, width: i32, height: i32) Box {
    const beside = x + TOOLTIP_PADDING * 2 + width;
    const left = if (beside <= area.right) x + TOOLTIP_PADDING * 2 else x - TOOLTIP_PADDING * 2 - width;
    const below = y + TOOLTIP_PADDING + height;
    const top = if (below <= area.bottom) y + TOOLTIP_PADDING else y - TOOLTIP_PADDING - height;
    const clamped_left = std.math.clamp(left, area.left, @max(area.left, area.right - width));
    const clamped_top = std.math.clamp(top, area.top, @max(area.top, area.bottom - height));
    return .{ .left = clamped_left, .top = clamped_top, .right = clamped_left + width, .bottom = clamped_top + height };
}

/// As the game shows it, e.g. "0.5" or "-0.4".
fn securityText(buffer: *[SECURITY_TEXT_MAX]u8, security_tenths: i8) []const u8 {
    const magnitude = @abs(security_tenths);
    const sign = if (security_tenths < 0) "-" else "";
    return std.fmt.bufPrint(buffer, "{s}{d}.{d}", .{ sign, magnitude / 10, magnitude % 10 }) catch unreachable;
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

test "the search box sits in the map's bottom right, and narrows with it" {
    const wide = searchBox(TEST_AREA, 24);
    try testing.expectEqual(SEARCH_BOX_WIDTH, wide.right - wide.left);
    try testing.expectEqual(TEST_AREA.right - SEARCH_BOX_MARGIN, wide.right);
    try testing.expectEqual(TEST_AREA.bottom - SEARCH_BOX_MARGIN, wide.bottom);
    try testing.expectEqual(@as(i32, 24), wide.bottom - wide.top);
    const narrow = searchBox(.{ .left = 0, .top = 0, .right = 300, .bottom = 200 }, 24);
    try testing.expectEqual(@as(i32, 100), narrow.right - narrow.left);
}

test "a popup too tall for its area runs on into another column" {
    const grid: PopupGrid = .init(.{ .left = 0, .top = 0, .right = 400, .bottom = 100 }, 10, 10, 12, 120, 20);
    try testing.expectEqual(@as(i32, 4), grid.rows_per_column);
    for (0..12) |index| {
        const box = grid.cell(index);
        try testing.expectEqual(@as(?usize, index), grid.rowAt(box.left, box.top));
    }
    try testing.expectEqual(grid.cell(0).top, grid.cell(4).top);
    try testing.expect(grid.cell(4).left > grid.cell(0).left);
}

test "a popup finds no row outside itself" {
    const grid: PopupGrid = .init(TEST_AREA, 100, 100, 3, 120, 20);
    try testing.expectEqual(@as(?usize, null), grid.rowAt(0, 0));
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

test "a search result names the system, its security and its region" {
    try testing.expectEqualStrings("Jita  0.9  The Forge", hitLabel(universe.findSystem("Jita").?).text.slice());
}

test "a search result's accent covers its security alone" {
    const hit = hitLabel(universe.findSystem("Jita").?);
    try testing.expectEqualStrings("0.9", hit.text.slice()[hit.security.start..hit.security.end]);
    try testing.expectEqual(SECURITY_COLORS[9], hit.security.color);
}

test "securityColor keeps every reading on the scale" {
    try testing.expectEqual(SECURITY_COLORS[0], securityColor(-10));
    try testing.expectEqual(SECURITY_COLORS[5], securityColor(5));
    try testing.expectEqual(SECURITY_COLORS[10], securityColor(10));
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

test "the picker grid holds every region and finds each from its own cell" {
    const grid: PickerGrid = .init(TEST_AREA, 14);
    for (0..universe.REGION_COUNT) |index| {
        const region: RegionIndex = @intCast(index);
        const cell = grid.cell(region);
        try testing.expect(cell.left >= TEST_AREA.left and cell.right <= TEST_AREA.right);
        try testing.expect(cell.top >= TEST_AREA.top and cell.bottom <= TEST_AREA.bottom);
        try testing.expectEqual(@as(?RegionIndex, region), grid.regionAt(cell.left, cell.top));
        try testing.expectEqual(@as(?RegionIndex, region), grid.regionAt(cell.right - 1, cell.bottom - 1));
    }
}

test "a short area spreads the regions over more columns" {
    const tall: PickerGrid = .init(TEST_AREA, 14);
    const short: PickerGrid = .init(.{ .left = 0, .top = 0, .right = 300, .bottom = 60 }, 14);
    try testing.expect(short.column_count > tall.column_count);
    try testing.expectEqual(@as(?RegionIndex, null), tall.regionAt(-1, 30));
}

test "a system's tooltip reports what's known about it" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    const jita = universe.findSystem("Jita").?;
    try snapshot.applyKills("[{\"npc_kills\":40,\"pod_kills\":2,\"ship_kills\":7,\"system_id\":30000142}]");

    const tooltip = systemTooltip(.{ .system = jita, .stats = &snapshot, .active_character = "Alpha", .jumps_from_active = 1, .characters = &.{"Bravo"}, .intel_message = "hostile", .intel_age_ms = 300_000 });
    try testing.expectEqualStrings("Jita  0.9", tooltip.line(0));
    try testing.expectEqualStrings("The Forge / Kimotoro", tooltip.line(1));
    try testing.expectEqualStrings("Last hour: 7 ships, 2 pods, 40 NPCs", tooltip.line(2));
    try testing.expectEqualStrings("1 jump from Alpha", tooltip.line(4));
    try testing.expectEqualStrings("Here: Bravo", tooltip.line(5));
    try testing.expectEqualStrings("Intel 5m ago: hostile", tooltip.line(6));
}

test "a tooltip without stats leaves those lines out, and doesn't report zero jumps" {
    const tooltip = systemTooltip(.{ .system = universe.findSystem("Jita").?, .active_character = "Alpha", .jumps_from_active = 0 });
    try testing.expectEqual(@as(usize, 3), tooltip.line_count);
}

test "many characters are counted rather than named" {
    const names = [_][]const u8{ "A", "B", "C", "D", "E" };
    const tooltip = systemTooltip(.{ .system = universe.findSystem("Jita").?, .characters = &names });
    try testing.expectEqualStrings("5 characters here", tooltip.line(tooltip.line_count - 1));
}

test "a long intel line is cut to its buffer" {
    const message: [TOOLTIP_LINE_MAX * 2]u8 = @splat('x');
    const tooltip = systemTooltip(.{ .system = universe.findSystem("Jita").?, .intel_message = &message });
    try testing.expectEqual(TOOLTIP_LINE_MAX - 1, tooltip.line(tooltip.line_count - 1).len);
}

test "tooltipBox stays inside the area, flipping away from the edges" {
    const left_side = tooltipBox(TEST_AREA, 100, 100, 200, 80);
    try testing.expect(left_side.left > 100);
    const right_side = tooltipBox(TEST_AREA, 750, 520, 200, 80);
    try testing.expect(right_side.right <= TEST_AREA.right);
    try testing.expect(right_side.bottom <= TEST_AREA.bottom);
    try testing.expect(right_side.left >= TEST_AREA.left);
}

test "securityText reads as the game shows it" {
    var buffer: [SECURITY_TEXT_MAX]u8 = undefined;
    try testing.expectEqualStrings("0.5", securityText(&buffer, 5));
    try testing.expectEqualStrings("1.0", securityText(&buffer, 10));
    try testing.expectEqualStrings("-0.4", securityText(&buffer, -4));
}
