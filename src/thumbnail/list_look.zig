//! The client list panel's look, shared by the panel and the config dialog's preview: its sizes, palette, colour rules and stat text; no I/O. The History Panel shares its palette and sizes.
const std = @import("std");
const types = @import("../config/types.zig");
const activity = @import("../config/activity.zig");
const display_mod = @import("../config/display.zig");
const color = @import("../util/color.zig");
const format = @import("../util/format.zig");

const DisplayConfig = display_mod.DisplayConfig;
const IndicatorStyle = types.ListIndicatorStyle;

pub const BOTTOM_PADDING: i32 = 4;
pub const PADDING_X: i32 = 10;
pub const BADGE_RADIUS: i32 = 3;
/// Between a row's indicator and its name.
pub const INDICATOR_GAP: i32 = 8;
pub const CORNER_RADIUS: usize = 4;
const MAX_COLUMNS: i32 = DisplayConfig.ranges.listViewColumns[1];
const MIN_HEADER_HEIGHT: i32 = 20;
const MIN_ROW_HEIGHT: i32 = 26;
/// Space around a line of text, so the default 13 px font keeps 26 px rows and a 20 px header.
const ROW_TEXT_PADDING: i32 = 8;
const HEADER_TEXT_PADDING: i32 = 5;
/// Fits headerText's longest result.
pub const HEADER_TEXT_MAX = 32;
/// Fits writeStat's longest result.
pub const STAT_TEXT_MAX = 24;

/// The header and right-hand slot are drawn this much smaller than the configured font.
const SMALL_FONT_STEP: i32 = 2;
const MIN_SMALL_FONT_SIZE: i32 = 8;
const ACTIVE_TINT_PERCENT = 12;
const ALERT_TINT_PERCENT = 16;
const ACTIVE_NAME_LIGHTEN_PERCENT = 40;

// Pixel colours (0xAARRGGBB, non-pre-multiplied).
pub const PANEL: u32 = 0xFF141518;
pub const BORDER: u32 = 0xFF6B6E75;
pub const DIVIDER: u32 = 0xFF2A2C30;
pub const NAME: u32 = 0xFFE8E6E1;
pub const MUTED: u32 = 0xFF8B8F96;
pub const BADGE_ALERT: u32 = 0xFFFF8833;
pub const BADGE_INACTIVE: u32 = 0xFF7FB3D9;
pub const BADGE_MINIMIZED: u32 = 0xFF3D5566;
pub const BADGE_EXCLUDED: u32 = 0xFF6B6E75;

/// What the right-hand slot shows besides a notification or the system, in the order it writes them.
pub const Stat = enum { incoming_dps, outgoing_dps, mining_rate, bounty_rate };
pub const STAT_COUNT = std.enums.values(Stat).len;

/// One stat in the right-hand slot: mining in m3 per minute, bounty in ISK per the configured period; null while still being measured.
pub const StatReading = struct {
    stat: Stat,
    value: ?f32,
    has_prefix: bool,
};

/// The panel's sizes for the current settings, in pixels.
pub const Metrics = struct {
    column_width: i32,
    header_height: i32,
    row_height: i32,
};

/// What decides whether and how a stat shows: the list's own settings, and its overlay's, which also runs its tracker.
pub const StatSettings = struct {
    display: *const DisplayConfig,
    combat: *const activity.CombatConfig,
    mining: *const activity.MiningConfig,
    bounty: *const activity.BountyConfig,
};

/// Where a row's name starts, from the panel's outer left edge.
pub fn textLeft(style: IndicatorStyle) i32 {
    return switch (style) {
        .Dot, .Square => PADDING_X + BADGE_RADIUS * 2 + INDICATOR_GAP,
        .None => PADDING_X,
    };
}

/// Rows and the header grow with the font so its text always fits.
pub fn metrics(display: *const DisplayConfig) Metrics {
    const font_size = display.listViewFontSize;
    return .{
        .column_width = display.listViewColumnWidth,
        .header_height = headerHeight(font_size),
        .row_height = rowHeight(font_size),
    };
}

/// A header whose text is drawn in smallFontSize(`font_size`); the History Panel's too.
pub fn headerHeight(font_size: i32) i32 {
    return @max(MIN_HEADER_HEIGHT, lineHeight(smallFontSize(font_size)) + HEADER_TEXT_PADDING);
}

/// A row whose main text is drawn at `font_size`; the History Panel's too.
pub fn rowHeight(font_size: i32) i32 {
    return @max(MIN_ROW_HEIGHT, lineHeight(font_size) + ROW_TEXT_PADDING);
}

/// Columns to lay `count` rows out in, row by row: the configured number, at most MAX_COLUMNS, and never more than there are rows.
pub fn effectiveColumns(configured: u32, count: usize) i32 {
    const clamped: i32 = @max(1, @min(MAX_COLUMNS, @as(i32, @intCast(configured))));
    if (count == 0) return clamped;
    return @min(clamped, @as(i32, @intCast(count)));
}

/// The header's and right-hand slot's font size.
pub fn smallFontSize(font_size: i32) i32 {
    return @max(MIN_SMALL_FONT_SIZE, font_size - SMALL_FONT_STEP);
}

/// The active row's background.
pub fn activeTint(active: u32) u32 {
    return color.mix(active, PANEL, ACTIVE_TINT_PERCENT);
}

/// An alerting row's background, from its notification's colour.
pub fn alertTint(alert: u32) u32 {
    return color.mix(alert, PANEL, ALERT_TINT_PERCENT);
}

/// The active row's name, for a character without a name colour of its own.
pub fn activeNameColor(active: u32) u32 {
    return color.lighten(active, ACTIVE_NAME_LIGHTEN_PERCENT);
}

pub fn headerText(buffer: *[HEADER_TEXT_MAX]u8, count: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "{d} {s}", .{ count, if (count == 1) "client" else "clients" }) catch unreachable;
}

pub fn showsStat(settings: StatSettings, stat: Stat) bool {
    const display = settings.display;
    return switch (stat) {
        .incoming_dps => settings.combat.enabled and display.listViewShowIncomingDps,
        .outgoing_dps => settings.combat.enabled and display.listViewShowOutgoingDps,
        .mining_rate => settings.mining.enabled and display.listViewShowMiningRate,
        .bounty_rate => settings.bounty.enabled and display.listViewShowBountyRate,
    };
}

pub fn hasPrefix(display: *const DisplayConfig, stat: Stat) bool {
    return switch (stat) {
        .incoming_dps => display.listViewShowIncomingPrefix,
        .outgoing_dps => display.listViewShowOutgoingPrefix,
        .mining_rate => display.listViewShowMiningPrefix,
        .bounty_rate => display.listViewShowBountyPrefix,
    };
}

pub fn statColor(display: *const DisplayConfig, stat: Stat) u32 {
    return switch (stat) {
        .incoming_dps => display.listViewIncomingDpsColor,
        .outgoing_dps => display.listViewOutgoingDpsColor,
        .mining_rate => display.listViewMiningRateColor,
        .bounty_rate => display.listViewBountyRateColor,
    };
}

/// One reading as the slot shows it, e.g. "IN:412"; a truncated result is still drawn, so the writer's overflow is ignored.
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
            writer.writeAll(format.formatIskAbbrev(&isk_buf, value)) catch {};
        },
    }
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

test "metrics keeps the minimum sizes for the default font and grows rows for a large one" {
    var display: DisplayConfig = .{};
    const default_sizes = metrics(&display);
    try std.testing.expectEqual(MIN_ROW_HEIGHT, default_sizes.row_height);
    try std.testing.expectEqual(MIN_HEADER_HEIGHT, default_sizes.header_height);
    display.listViewFontSize = 24;
    try std.testing.expect(metrics(&display).row_height > MIN_ROW_HEIGHT);
}

test "smallFontSize steps down but never below the minimum" {
    try std.testing.expectEqual(@as(i32, 11), smallFontSize(13));
    try std.testing.expectEqual(MIN_SMALL_FONT_SIZE, smallFontSize(6));
}

test "headerText counts a single client in the singular" {
    var buffer: [HEADER_TEXT_MAX]u8 = undefined;
    try std.testing.expectEqualStrings("1 client", headerText(&buffer, 1));
    try std.testing.expectEqualStrings("12 clients", headerText(&buffer, 12));
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

test "activeTint of the panel's own colour is the panel" {
    try std.testing.expectEqual(PANEL, activeTint(PANEL));
}
