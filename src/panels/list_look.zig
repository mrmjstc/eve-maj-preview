//! The client list panel's look, shared with its config preview and the History Panel: sizes, palette, colour rules and stat text; no I/O.
const std = @import("std");
const types = @import("../config/types.zig");
const activity = @import("../config/activity.zig");
const panels = @import("../config/panels.zig");
const characters = @import("../config/characters.zig");
const color = @import("../util/color.zig");
const format = @import("../util/format.zig");
const strings = @import("../util/strings.zig");
const palette = @import("palette.zig");
const panel_header = @import("panel_header.zig");

const ListViewConfig = panels.ListViewConfig;
const CharacterConfig = characters.CharacterConfig;
const IndicatorStyle = types.ListIndicatorStyle;
const RateUnit = activity.RateUnit;

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
/// Before the totals footer's readings.
pub const TOTALS_TEXT = "TOTAL";
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

/// Mining in m3 and bounty in ISK, per `unit`.
pub const StatReading = struct {
    stat: Stat,
    value: f32,
    has_prefix: bool,
    /// Written after the value as " m3/min" or " ISK/hr"; null for DPS.
    unit: ?RateUnit = null,
};

/// In pixels.
pub const Metrics = struct {
    column_width: i32,
    header_height: i32,
    row_height: i32,
    /// Every line of rows while the list shows stats.
    stats_row_height: i32,
    /// The totals line under the rows.
    footer_height: i32,
};

/// The list's own settings, and the overlays' whose rate units it follows.
pub const StatSettings = struct {
    list_settings: *const ListViewConfig,
    mining: *const activity.MiningConfig,
    bounty: *const activity.BountyConfig,
};

/// One stat summed over the rows showing it.
pub const Total = struct {
    sum: f32 = 0,
    row_count: usize = 0,

    fn add(self: *Total, value: f32) void {
        self.sum += value;
        self.row_count += 1;
    }
};

/// In Stat order.
pub const Totals = [STAT_COUNT]Total;

/// What the row order and layout read of each client, for one render.
pub const RowNames = struct {
    /// Borrows from the roster.
    display_name: []const u8,
    /// Borrows from the roster.
    character_name: []const u8,
    /// Borrows from the roster; empty while unknown.
    system_name: []const u8,
};

pub const OrderSettings = struct {
    order: types.ListViewOrder,
    /// The profile's characters, whose order ConfiguredCharacters follows.
    configured: []const CharacterConfig,
    groups_by_system: bool,
};

/// A line of a render: a system's heading, or rows side by side.
pub const Line = struct {
    top: i32,
    bottom: i32,
    /// Into the rows.
    first_row_index: usize,
    row_count: usize,
    /// Over the `row_count` rows from `first_row_index`, rather than those rows.
    is_heading: bool = false,
};

pub const LineSettings = struct {
    columns: usize,
    groups_by_system: bool,
    /// Where the first line starts.
    top: i32,
    row_height: i32,
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
        .footer_height = rowHeight(smallFontSize(list_settings.fontSize)),
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

/// Positions into `names` grouped by system: biggest group first, ties by first seen, rows with none last; each keeps its order.
pub fn systemGroupOrder(allocator: std.mem.Allocator, names: []const []const u8) ![]usize {
    const Group = struct {
        name: []const u8,
        count: usize,
        first_index: usize,

        fn before(_: void, first: @This(), second: @This()) bool {
            if ((first.name.len == 0) != (second.name.len == 0)) return second.name.len == 0;
            if (first.count != second.count) return first.count > second.count;
            return first.first_index < second.first_index;
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
        } else try groups.append(allocator, .{ .name = name, .count = 1, .first_index = index });
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

/// Sorts `rows`, indices into `names`: Alphabetical by display then character name, ConfiguredCharacters by the profile's list with others last.
pub fn orderRows(allocator: std.mem.Allocator, rows: []usize, names: []const RowNames, settings: OrderSettings) !void {
    const AlphabeticalContext = struct {
        names: []const RowNames,

        fn lessThan(context: @This(), first_index: usize, second_index: usize) bool {
            const first = &context.names[first_index];
            const second = &context.names[second_index];
            switch (strings.naturalOrder(first.display_name, second.display_name)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
            switch (strings.naturalOrder(first.character_name, second.character_name)) {
                .lt => return true,
                .gt => return false,
                .eq => return first_index < second_index,
            }
        }
    };
    const ConfiguredContext = struct {
        names: []const RowNames,
        order_map: *const std.StringHashMap(usize),

        fn lessThan(context: @This(), first_index: usize, second_index: usize) bool {
            return characters.orderMapLessThan(context.order_map, context.names[first_index].character_name, context.names[second_index].character_name, first_index, second_index);
        }
    };

    switch (settings.order) {
        .Tracked => {},
        .Alphabetical => std.sort.pdq(usize, rows, AlphabeticalContext{ .names = names }, AlphabeticalContext.lessThan),
        .ConfiguredCharacters => {
            // Built once per sort, not per comparison.
            var order_map = try characters.buildCharacterOrderMap(settings.configured, allocator);
            defer order_map.deinit();
            std.sort.pdq(usize, rows, ConfiguredContext{ .names = names, .order_map = &order_map }, ConfiguredContext.lessThan);
        },
    }
    if (settings.groups_by_system) try groupRows(allocator, rows, names);
}

/// Fills `lines` for `rows`, indices into `names` in display order, with a heading over each system's rows while grouped; returns the last line's bottom.
pub fn layOutLines(allocator: std.mem.Allocator, lines: *std.ArrayList(Line), rows: []const usize, names: []const RowNames, settings: LineSettings) !i32 {
    lines.clearRetainingCapacity();
    var top = settings.top;
    var first_index: usize = 0;
    while (first_index < rows.len) {
        var group_end = rows.len;
        if (settings.groups_by_system) {
            const system_name = names[rows[first_index]].system_name;
            group_end = first_index + 1;
            while (group_end < rows.len and std.mem.eql(u8, names[rows[group_end]].system_name, system_name)) group_end += 1;
            try lines.append(allocator, .{ .top = top, .bottom = top + GROUP_HEADING_HEIGHT, .first_row_index = first_index, .row_count = group_end - first_index, .is_heading = true });
            top += GROUP_HEADING_HEIGHT;
        }
        var line_first_index = first_index;
        while (line_first_index < group_end) {
            const line_end = @min(line_first_index + settings.columns, group_end);
            try lines.append(allocator, .{ .top = top, .bottom = top + settings.row_height, .first_row_index = line_first_index, .row_count = line_end - line_first_index });
            top += settings.row_height;
            line_first_index = line_end;
        }
        first_index = group_end;
    }
    return top;
}

/// The header's count of clients.
pub fn countText(buffer: *[COUNT_TEXT_MAX]u8, count: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{count}) catch unreachable;
}

pub fn showsStat(settings: StatSettings, stat: Stat) bool {
    const list_settings = settings.list_settings;
    return switch (stat) {
        .incoming_dps => list_settings.showIncomingDps,
        .outgoing_dps => list_settings.showOutgoingDps,
        .mining_rate => list_settings.showMiningRate,
        .bounty_rate => list_settings.showBountyRate,
    };
}

/// Rows keep a line for stats while this holds.
pub fn showsAnyStat(settings: StatSettings) bool {
    for (std.enums.values(Stat)) |stat| {
        if (showsStat(settings, stat)) return true;
    }
    return false;
}

/// The list keeps a totals line under its rows while this holds.
pub fn showsTotals(settings: StatSettings) bool {
    return settings.list_settings.showTotals and showsAnyStat(settings);
}

/// Adds a row's readings to `totals`.
pub fn addReadings(totals: *Totals, readings: []const StatReading) void {
    for (readings) |reading| totals[@backingInt(reading.stat)].add(reading.value);
}

/// Each stat some row shows, in writing order.
pub fn totalReadings(settings: StatSettings, totals: *const Totals, out: *[STAT_COUNT]StatReading) []const StatReading {
    var reading_count: usize = 0;
    for (std.enums.values(Stat), totals) |stat, total| {
        if (total.row_count == 0) continue;
        out[reading_count] = .{
            .stat = stat,
            .value = total.sum,
            .has_prefix = hasPrefix(settings.list_settings, stat),
            .unit = rateUnit(settings, stat),
        };
        reading_count += 1;
    }
    return out[0..reading_count];
}

/// The overlay's period, which the list follows; null for DPS, always per second.
pub fn rateUnit(settings: StatSettings, stat: Stat) ?RateUnit {
    return switch (stat) {
        .incoming_dps, .outgoing_dps => null,
        .mining_rate => settings.mining.m3_rate_unit,
        .bounty_rate => settings.bounty.isk_rate_unit,
    };
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

/// E.g. "IN:412" or "M:1,284 m3/hr", as the thumbnails write it; overflow is ignored, since a truncated result is still drawn.
pub fn writeStat(writer: *std.Io.Writer, reading: StatReading) void {
    if (reading.has_prefix) writer.writeAll(prefix(reading.stat)) catch {};
    var number_buf: [24]u8 = undefined;
    switch (reading.stat) {
        .incoming_dps, .outgoing_dps => writer.print("{d:.0}", .{reading.value}) catch {},
        .mining_rate => writer.writeAll(format.formatMinedVolume(&number_buf, reading.value)) catch {},
        .bounty_rate => writer.writeAll(format.formatIskAbbreviated(&number_buf, reading.value)) catch {},
    }
    if (reading.unit) |unit| writer.print(" {s}/{s}", .{ quantity(reading.stat), unit.suffix() }) catch {};
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

/// What a rate counts, before its period.
fn quantity(stat: Stat) []const u8 {
    return switch (stat) {
        .incoming_dps, .outgoing_dps => "HP",
        .mining_rate => "m3",
        .bounty_rate => "ISK",
    };
}

/// Reorders `rows` so clients in one system sit together, as systemGroupOrder ranks them.
fn groupRows(allocator: std.mem.Allocator, rows: []usize, names: []const RowNames) !void {
    const systems = try allocator.alloc([]const u8, rows.len);
    defer allocator.free(systems);
    for (rows, systems) |row, *system| system.* = names[row].system_name;
    const order = try systemGroupOrder(allocator, systems);
    defer allocator.free(order);
    const sorted = try allocator.dupe(usize, rows);
    defer allocator.free(sorted);
    for (order, rows) |position, *row| row.* = sorted[position];
}

const testing = std.testing;
const TEST_LIST_SETTINGS: ListViewConfig = .{};
const TEST_MINING: activity.MiningConfig = .{};
const TEST_BOUNTY: activity.BountyConfig = .{};
const TEST_STAT_SETTINGS: StatSettings = .{ .list_settings = &TEST_LIST_SETTINGS, .mining = &TEST_MINING, .bounty = &TEST_BOUNTY };

fn testNames(display_name: []const u8, character_name: []const u8, system_name: []const u8) RowNames {
    return .{ .display_name = display_name, .character_name = character_name, .system_name = system_name };
}

test "textLeft starts the name at the padding when there's no indicator" {
    try testing.expectEqual(PADDING_X, textLeft(.None));
    try testing.expect(textLeft(.Dot) > textLeft(.None));
}

test "effectiveColumns caps at the row count and the maximum" {
    try testing.expectEqual(@as(i32, 3), effectiveColumns(5, 3));
    try testing.expectEqual(MAX_COLUMNS, effectiveColumns(15, 20));
    try testing.expectEqual(@as(i32, 1), effectiveColumns(0, 4));
}

test "metrics keeps the minimum row for the default font and grows rows for a large one" {
    var list_settings: ListViewConfig = .{};
    const default_sizes = metrics(&list_settings);
    try testing.expectEqual(MIN_ROW_HEIGHT, default_sizes.row_height);
    try testing.expectEqual(panel_header.HEIGHT, default_sizes.header_height);
    list_settings.fontSize = 24;
    try testing.expect(metrics(&list_settings).row_height > MIN_ROW_HEIGHT);
}

test "a row with stats is taller than one without" {
    try testing.expect(statsRowHeight(13) > rowHeight(13));
    try testing.expect(statsRowHeight(24) > rowHeight(24));
}

test "smallFontSize steps down but never below the minimum" {
    try testing.expectEqual(@as(i32, 11), smallFontSize(13));
    try testing.expectEqual(MIN_SMALL_FONT_SIZE, smallFontSize(6));
}

test "countText is the bare number" {
    var buffer: [COUNT_TEXT_MAX]u8 = undefined;
    try testing.expectEqualStrings("12", countText(&buffer, 12));
}

test "writeStat adds the prefix and rounds by stat" {
    var buffer: [STAT_TEXT_MAX]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writeStat(&writer, .{ .stat = .incoming_dps, .value = 412.4, .has_prefix = true });
    try testing.expectEqualStrings("IN:412", writer.buffered());

    writer = .fixed(&buffer);
    writeStat(&writer, .{ .stat = .mining_rate, .value = 4.24, .has_prefix = true });
    try testing.expectEqualStrings("M:4.2", writer.buffered());

    writer = .fixed(&buffer);
    writeStat(&writer, .{ .stat = .outgoing_dps, .value = 87, .has_prefix = false });
    try testing.expectEqualStrings("87", writer.buffered());
}

test "writeStat groups mined volume and ends a rate with its period" {
    var buffer: [STAT_TEXT_MAX]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writeStat(&writer, .{ .stat = .mining_rate, .value = 1284, .has_prefix = true, .unit = .hour });
    try testing.expectEqualStrings("M:1,284 m3/hr", writer.buffered());

    writer = .fixed(&buffer);
    writeStat(&writer, .{ .stat = .bounty_rate, .value = 200_000, .has_prefix = false, .unit = .minute });
    try testing.expectEqualStrings("200k ISK/min", writer.buffered());
}

test "totalReadings sums the rows showing each stat, in the overlay's period" {
    var totals: Totals = @splat(.{});
    addReadings(&totals, &.{ .{ .stat = .incoming_dps, .value = 100, .has_prefix = true }, .{ .stat = .mining_rate, .value = 40, .has_prefix = true } });
    addReadings(&totals, &.{.{ .stat = .incoming_dps, .value = 25, .has_prefix = true }});
    var out: [STAT_COUNT]StatReading = undefined;
    const readings = totalReadings(TEST_STAT_SETTINGS, &totals, &out);
    try testing.expectEqual(@as(usize, 2), readings.len);
    try testing.expectEqual(@as(f32, 125), readings[0].value);
    try testing.expectEqual(@as(f32, 40), readings[1].value);
    try testing.expectEqual(@as(?RateUnit, TEST_MINING.m3_rate_unit), readings[1].unit);
}

test "systemGroupOrder puts the biggest system first and clients without one last" {
    const names = [_][]const u8{ "Jita", "", "Dodixie", "Dodixie", "Jita", "Dodixie", "Amarr" };
    const order = try systemGroupOrder(testing.allocator, &names);
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(usize, &.{ 2, 3, 5, 0, 4, 6, 1 }, order);
}

test "alphabetical order goes by display name in natural order, then character name" {
    const names = [_]RowNames{ testNames("Client 10", "A", ""), testNames("client 2", "B", ""), testNames("Client 10", "0", "") };
    var rows = [_]usize{ 0, 1, 2 };
    try orderRows(testing.allocator, &rows, &names, .{ .order = .Alphabetical, .configured = &.{}, .groups_by_system = false });
    try testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, &rows);
}

test "configured order follows the profile's list and puts the rest last, as tracked" {
    const names = [_]RowNames{ testNames("x", "Unlisted", ""), testNames("x", "Bravo", ""), testNames("x", "Alpha", "") };
    const configured = [_]CharacterConfig{ .{ .name = "Alpha" }, .{ .name = "Bravo" } };
    var rows = [_]usize{ 0, 1, 2 };
    try orderRows(testing.allocator, &rows, &names, .{ .order = .ConfiguredCharacters, .configured = &configured, .groups_by_system = false });
    try testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, &rows);
}

test "grouping by system keeps each group's order and puts a heading over it" {
    const names = [_]RowNames{ testNames("a", "a", "Jita"), testNames("b", "b", "Amarr"), testNames("c", "c", "Jita") };
    var rows = [_]usize{ 0, 1, 2 };
    try orderRows(testing.allocator, &rows, &names, .{ .order = .Tracked, .configured = &.{}, .groups_by_system = true });
    try testing.expectEqualSlices(usize, &.{ 0, 2, 1 }, &rows);

    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(testing.allocator);
    const bottom = try layOutLines(testing.allocator, &lines, &rows, &names, .{ .columns = 2, .groups_by_system = true, .top = 10, .row_height = 30 });
    try testing.expectEqual(@as(usize, 4), lines.items.len);
    try testing.expect(lines.items[0].is_heading);
    try testing.expectEqual(@as(usize, 2), lines.items[1].row_count);
    try testing.expect(lines.items[2].is_heading);
    try testing.expectEqual(@as(i32, 10 + 2 * GROUP_HEADING_HEIGHT + 2 * 30), bottom);
}

test "ungrouped rows fill lines of the column count" {
    const names = [_]RowNames{ testNames("a", "a", ""), testNames("b", "b", ""), testNames("c", "c", "") };
    const rows = [_]usize{ 0, 1, 2 };
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(testing.allocator);
    _ = try layOutLines(testing.allocator, &lines, &rows, &names, .{ .columns = 2, .groups_by_system = false, .top = 0, .row_height = 30 });
    try testing.expectEqual(@as(usize, 2), lines.items.len);
    try testing.expectEqual(@as(usize, 1), lines.items[1].row_count);
}

test "activeTint of the panel's own colour is the panel" {
    try testing.expectEqual(PANEL, activeTint(PANEL));
}
