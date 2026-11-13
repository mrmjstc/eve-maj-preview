//! The client list panel's look, shared with its config preview and the History Panel: sizes, palette, colour rules and stat text; no I/O.
const std = @import("std");
const types = @import("../config/types.zig");
const activity = @import("../config/activity.zig");
const panels = @import("../config/panels.zig");
const color = @import("../util/color.zig");
const format = @import("../util/format.zig");
const palette = @import("palette.zig");
const panel_header = @import("panel_header.zig");

const ListViewConfig = panels.ListViewConfig;
const IndicatorStyle = types.ListIndicatorStyle;

pub const BOTTOM_PADDING: i32 = 4;
pub const PADDING_X: i32 = palette.PADDING_X;
pub const BADGE_RADIUS: i32 = 3;
/// The active or an alerting row's dot, which glows.
pub const LIT_BADGE_RADIUS: i32 = 4;
/// How far a lit dot's glow reaches past it.
pub const GLOW_WIDTH: i32 = 3;
/// Between a row's indicator and its name.
pub const INDICATOR_GAP: i32 = 8;
/// Between a row's name and its right-hand slot.
pub const SLOT_GAP: i32 = 8;
/// Between a system's name and its security.
pub const SECURITY_GAP: i32 = 5;
/// Between the readings on a row's stats line.
pub const STAT_GAP: i32 = 8;
/// A name keeps this much room however long the right-hand slot's text.
pub const MIN_NAME_WIDTH: i32 = 60;
/// Between a row's name and its stats line.
pub const LINE_GAP: i32 = 1;
pub const PILL_PADDING_X: i32 = 6;
pub const PILL_RADIUS: usize = palette.RADIUS;
/// A system's heading over its rows, while they're grouped.
pub const GROUP_HEADING_HEIGHT: i32 = 24;
/// Between a heading's parts and its rule.
pub const GROUP_HEADING_GAP: i32 = 6;
/// The heading over clients whose system isn't known.
pub const NO_SYSTEM_TEXT = "NO SYSTEM";
pub const CORNER_RADIUS: usize = palette.WINDOW_RADIUS;
const MAX_COLUMNS: i32 = ListViewConfig.ranges.columns[1];
const MIN_ROW_HEIGHT: i32 = 26;
/// Space around a line of text, so a 13 px font just fills the 26 px minimum row.
const ROW_TEXT_PADDING: i32 = 8;
/// Space around a row's name and stats line together.
const STATS_ROW_PADDING: i32 = 6;
pub const HEADER_TEXT = "Clients";
/// Fits countText's longest result.
pub const COUNT_TEXT_MAX = 24;
/// Fits writeStat's longest result.
pub const STAT_TEXT_MAX = 24;

/// The right-hand slot and stats line are drawn this much smaller than the configured font.
const SMALL_FONT_STEP: i32 = 2;
const MIN_SMALL_FONT_SIZE: i32 = 8;
const ACTIVE_TINT_PERCENT = 12;
const ALERT_TINT_PERCENT = 8;
const GLOW_PERCENT = 25;
const PILL_FILL_PERCENT = 18;
const PILL_BORDER_PERCENT = 45;

// The colours below are 0xAARRGGBB, not premultiplied.
pub const PANEL: u32 = palette.BG;
pub const BORDER: u32 = palette.CARD_BORDER;
pub const DIVIDER: u32 = palette.DIVIDER;
pub const NAME: u32 = palette.TEXT;
/// The active row's name, for a character without a name colour of its own.
pub const ACTIVE_NAME: u32 = 0xFFFFFFFF;
pub const MUTED: u32 = palette.MUTED;
pub const ROW_HOVER: u32 = palette.ROW_HOVER;
pub const BADGE_ALERT: u32 = palette.ERROR;
pub const BADGE_INACTIVE: u32 = palette.BORDER_STRONG;
pub const BADGE_MINIMIZED: u32 = palette.BORDER;
pub const BADGE_EXCLUDED: u32 = palette.SURFACE_ALT;
pub const STAT_COUNT = std.enums.values(Stat).len;

/// A rate a row can show under its name, in the order it writes them.
pub const Stat = enum { incoming_dps, outgoing_dps, mining_rate, bounty_rate };

/// Mining in m3 per minute, bounty in ISK per the configured period; null while still being measured.
pub const StatReading = struct {
    stat: Stat,
    value: ?f32,
    has_prefix: bool,
};

/// In pixels.
pub const Metrics = struct {
    column_width: i32,
    header_height: i32,
    row_height: i32,
    /// Every line of rows while the list shows stats.
    stats_row_height: i32,
};

/// The list's own settings and its overlay's, which also runs the tracker.
pub const StatSettings = struct {
    list_settings: *const ListViewConfig,
    combat: *const activity.CombatConfig,
    mining: *const activity.MiningConfig,
    bounty: *const activity.BountyConfig,
};

/// Where a row's name starts, from the panel's outer left edge.
pub fn textLeft(style: IndicatorStyle) i32 {
    return switch (style) {
        .Dot, .Square => PADDING_X + LIT_BADGE_RADIUS * 2 + INDICATOR_GAP,
        .None => PADDING_X,
    };
}

/// Rows grow with the font so its text always fits; the header is the same in every panel.
pub fn metrics(list_settings: *const ListViewConfig) Metrics {
    return .{
        .column_width = list_settings.columnWidth,
        .header_height = panel_header.HEIGHT,
        .row_height = rowHeight(list_settings.fontSize),
        .stats_row_height = statsRowHeight(list_settings.fontSize),
    };
}

/// A row whose main text is drawn at `font_size`; the History Panel's too.
pub fn rowHeight(font_size: i32) i32 {
    return @max(MIN_ROW_HEIGHT, lineHeight(font_size) + ROW_TEXT_PADDING);
}

/// The configured count, capped at MAX_COLUMNS and at `row_count`.
pub fn effectiveColumns(configured: u32, row_count: usize) i32 {
    const clamped: i32 = @max(1, @min(MAX_COLUMNS, @as(i32, @intCast(configured))));
    if (row_count == 0) return clamped;
    return @min(clamped, @as(i32, @intCast(row_count)));
}

/// The right-hand slot's and stats line's font size.
pub fn smallFontSize(font_size: i32) i32 {
    return @max(MIN_SMALL_FONT_SIZE, font_size - SMALL_FONT_STEP);
}

/// The active row's background.
pub fn activeTint(active_color: u32) u32 {
    return color.mix(active_color, PANEL, ACTIVE_TINT_PERCENT);
}

/// An alerting row's background, from its notification's colour.
pub fn alertTint(alert_color: u32) u32 {
    return color.mix(alert_color, PANEL, ALERT_TINT_PERCENT);
}

/// The halo round a lit dot on `background`.
pub fn glowColor(dot_color: u32, background: u32) u32 {
    return color.mix(dot_color, background, GLOW_PERCENT);
}

/// Behind a notification on its row, from the notification's colour.
pub fn pillFill(alert_color: u32) u32 {
    return color.mix(alert_color, PANEL, PILL_FILL_PERCENT);
}

pub fn pillBorder(alert_color: u32) u32 {
    return color.mix(alert_color, PANEL, PILL_BORDER_PERCENT);
}

/// Positions into `names`, each a row's system in display order, so rows sharing one sit together: the biggest group first, ties by first appearance, rows with none last; each group keeps its rows' order.
pub fn systemGroupOrder(allocator: std.mem.Allocator, names: []const []const u8) ![]usize {
    const Group = struct {
        name: []const u8,
        count: usize,
        first: usize,

        fn before(_: void, first_group: @This(), second_group: @This()) bool {
            if ((first_group.name.len == 0) != (second_group.name.len == 0)) return second_group.name.len == 0;
            if (first_group.count != second_group.count) return first_group.count > second_group.count;
            return first_group.first < second_group.first;
        }
    };
    var groups: std.ArrayList(Group) = .empty;
    defer groups.deinit(allocator);
    for (names, 0..) |name, index| {
        for (groups.items) |*group| {
            if (std.mem.eql(u8, group.name, name)) {
                group.count += 1;
                break;
            }
        } else try groups.append(allocator, .{ .name = name, .count = 1, .first = index });
    }
    std.sort.insertion(Group, groups.items, {}, Group.before);

    const order = try allocator.alloc(usize, names.len);
    var next: usize = 0;
    for (groups.items) |group| {
        for (names, 0..) |name, index| {
            if (!std.mem.eql(u8, name, group.name)) continue;
            order[next] = index;
            next += 1;
        }
    }
    return order;
}

/// The header's count of clients.
pub fn countText(buffer: *[COUNT_TEXT_MAX]u8, count: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{count}) catch unreachable;
}

pub fn showsStat(settings: StatSettings, stat: Stat) bool {
    const list_settings = settings.list_settings;
    return switch (stat) {
        .incoming_dps => settings.combat.enabled and list_settings.showIncomingDps,
        .outgoing_dps => settings.combat.enabled and list_settings.showOutgoingDps,
        .mining_rate => settings.mining.enabled and list_settings.showMiningRate,
        .bounty_rate => settings.bounty.enabled and list_settings.showBountyRate,
    };
}

/// Rows keep a line for stats while this holds.
pub fn showsAnyStat(settings: StatSettings) bool {
    for (std.enums.values(Stat)) |stat| {
        if (showsStat(settings, stat)) return true;
    }
    return false;
}

pub fn hasPrefix(list_settings: *const ListViewConfig, stat: Stat) bool {
    return switch (stat) {
        .incoming_dps => list_settings.showIncomingPrefix,
        .outgoing_dps => list_settings.showOutgoingPrefix,
        .mining_rate => list_settings.showMiningPrefix,
        .bounty_rate => list_settings.showBountyPrefix,
    };
}

pub fn statColor(list_settings: *const ListViewConfig, stat: Stat) u32 {
    return switch (stat) {
        .incoming_dps => list_settings.incomingDpsColor,
        .outgoing_dps => list_settings.outgoingDpsColor,
        .mining_rate => list_settings.miningRateColor,
        .bounty_rate => list_settings.bountyRateColor,
    };
}

/// E.g. "IN:412"; overflow is ignored, since a truncated result is still drawn.
pub fn writeStat(writer: *std.Io.Writer, reading: StatReading) void {
    if (reading.has_prefix) writer.writeAll(prefix(reading.stat)) catch {};
    const value = reading.value orelse {
        writer.writeAll("??") catch {};
        return;
    };
    switch (reading.stat) {
        .incoming_dps, .outgoing_dps => writer.print("{d:.0}", .{value}) catch {},
        .mining_rate => if (value < 10.0) writer.print("{d:.1}", .{value}) catch {} else writer.print("{d:.0}", .{value}) catch {},
        .bounty_rate => {
            var isk_buf: [16]u8 = undefined;
            writer.writeAll(format.formatIskAbbreviated(&isk_buf, value)) catch {};
        },
    }
}

/// A name at `font_size` with a stats line under it.
fn statsRowHeight(font_size: i32) i32 {
    return @max(rowHeight(font_size), lineHeight(font_size) + LINE_GAP + lineHeight(smallFontSize(font_size)) + STATS_ROW_PADDING);
}

/// About as tall as Windows lays out a line at `font_size` px.
fn lineHeight(font_size: i32) i32 {
    return @divTrunc(font_size * 4 + 2, 3);
}

fn prefix(stat: Stat) []const u8 {
    return switch (stat) {
        .incoming_dps => "IN:",
        .outgoing_dps => "OUT:",
        .mining_rate => "M:",
        .bounty_rate => "ISK:",
    };
}

test "textLeft starts the name at the padding when there's no indicator" {
    try std.testing.expectEqual(PADDING_X, textLeft(.None));
    try std.testing.expect(textLeft(.Dot) > textLeft(.None));
}

test "effectiveColumns caps at the row count and the maximum" {
    try std.testing.expectEqual(@as(i32, 3), effectiveColumns(5, 3));
    try std.testing.expectEqual(MAX_COLUMNS, effectiveColumns(15, 20));
    try std.testing.expectEqual(@as(i32, 1), effectiveColumns(0, 4));
}

test "metrics keeps the minimum row for the default font and grows rows for a large one" {
    var list_settings: ListViewConfig = .{};
    const default_sizes = metrics(&list_settings);
    try std.testing.expectEqual(MIN_ROW_HEIGHT, default_sizes.row_height);
    try std.testing.expectEqual(panel_header.HEIGHT, default_sizes.header_height);
    list_settings.fontSize = 24;
    try std.testing.expect(metrics(&list_settings).row_height > MIN_ROW_HEIGHT);
}

test "a row with stats is taller than one without" {
    try std.testing.expect(statsRowHeight(13) > rowHeight(13));
    try std.testing.expect(statsRowHeight(24) > rowHeight(24));
}

test "smallFontSize steps down but never below the minimum" {
    try std.testing.expectEqual(@as(i32, 11), smallFontSize(13));
    try std.testing.expectEqual(MIN_SMALL_FONT_SIZE, smallFontSize(6));
}

test "countText is the bare number" {
    var buffer: [COUNT_TEXT_MAX]u8 = undefined;
    try std.testing.expectEqualStrings("12", countText(&buffer, 12));
}

test "writeStat adds the prefix, rounds by stat and marks an unmeasured reading" {
    var buffer: [STAT_TEXT_MAX]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writeStat(&writer, .{ .stat = .incoming_dps, .value = 412.4, .has_prefix = true });
    try std.testing.expectEqualStrings("IN:412", writer.buffered());

    writer = .fixed(&buffer);
    writeStat(&writer, .{ .stat = .mining_rate, .value = 4.24, .has_prefix = true });
    try std.testing.expectEqualStrings("M:4.2", writer.buffered());

    writer = .fixed(&buffer);
    writeStat(&writer, .{ .stat = .outgoing_dps, .value = null, .has_prefix = false });
    try std.testing.expectEqualStrings("??", writer.buffered());
}

test "systemGroupOrder puts the biggest system first and clients without one last" {
    const names = [_][]const u8{ "Jita", "", "Dodixie", "Dodixie", "Jita", "Dodixie", "Amarr" };
    const order = try systemGroupOrder(std.testing.allocator, &names);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3, 5, 0, 4, 6, 1 }, order);
}

test "activeTint of the panel's own colour is the panel" {
    try std.testing.expectEqual(PANEL, activeTint(PANEL));
}
