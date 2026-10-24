//! The configuration window's Mining tab: the mining overlay's tuning, its alerts and the ore prices; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const host = @import("../host.zig");
const prices = @import("../prices.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const lang = @import("../../../lang/lang.zig");

const Rect = ui.component.Rect;
const Button = ui.component.Button;
const Text = ui.component.Text;

/// Ores first, then ice, moon ores and gas.
const ORE_CATEGORIES = [_][]const u8{ "Ore", "Ice", "Moons", "Gas" };

/// Not saved: the table starts hidden each time the window opens.
var g_is_table_shown = false;

pub fn show(context: *ui.Frame) !void {
    try chatlogNotice(context);
    const ref = session.profile().child("mining");
    const section = try widgets.openSection(context, "Mining Overlay", "Displays m3 mined per minute on each thumbnail, calculated from EVE gamelogs.", &style.section);
    try bind.toggle(context, ref, "enabled", "Enable Mining Overlay");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.number(context, ref, "window_seconds", "Averaging Window", .{ .unit = "s" });
    try widgets.hintText(context, .src(@src()), "The mining rate is averaged over this time.");
    try bind.number(context, ref, "update_interval_ms", "Update Interval", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How often the number on the thumbnail changes.");
    try bind.toggle(context, ref, "show_isk_rate", "Show ISK Rate");
    try widgets.hintText(context, .src(@src()), "Uses the prices below; fetch or enter them first.");
    const isk_rate = try widgets.openNestedGroup(context, .src(@src()), ref.get("show_isk_rate"));
    try bind.segmented(context, ref, "isk_rate_unit", "ISK Rate Unit", &.{ "Per Minute", "Per Hour" });
    try widgets.hintText(context, .src(@src()), "Shows ISK earned per minute or per hour.");
    try isk_rate.close(context);
    try bind.toggle(context, ref, "show_prefix", "Show M: Prefix");
    try widgets.hintText(context, .src(@src()), "Puts M: before the rate so it's easy to tell apart.");
    try options.close(context);
    try section.close(context);

    const alerts = try widgets.openSection(context, "Alerts", "Alerts from mining laser activity. Needs Mining Overlay switched on.", &style.section);
    const alert_options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try widgets.subheading(context, .src(@src()), "Mining Idle Alert");
    try widgets.hintText(context, .src(@src()), "Alerts when mining slows, not just when it stops.");
    try bind.number(context, ref, "idle_alert_window_seconds", "Detection Window", .{ .unit = "s" });
    try widgets.hintText(context, .src(@src()), "The time mining cycles are counted over.");
    try bind.number(context, ref, "idle_alert_threshold", "Minimum Cycles", .{ .unit = "cycles", .singular_unit = "cycle" });
    try widgets.hintText(context, .src(@src()), "Fewer mining cycles than this in the window counts as slow.");
    try widgets.subheading(context, .src(@src()), "Mining Stopped Alert");
    try widgets.hintText(context, .src(@src()), "Alerts once all mining has stopped.");
    try bind.number(context, ref, "stopped_alert_window_seconds", "Silence Window", .{ .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How long without mining before the alert.");
    try alert_options.close(context);
    try alerts.close(context);

    const prices_section = try widgets.openSection(context, "Ore / Ice / Gas Prices", "\"Fetch Prices\" pulls current Jita buy prices from EVE's market.", &style.section);
    try priceControls(context);
    if (g_is_table_shown) {
        const inset = Rect{ .key = .src(@src()), .style = &style.inset_column };
        _ = try inset.open(context);
        try oreTable(context);
        try inset.close(context);
    }
    try prices_section.close(context);
}

/// Saved with the fetched prices, so discarding them discards it too.
pub fn stampPricesFetched() void {
    session.global().set("orePricesFetchedAtSeconds", std.Io.Timestamp.now(session.runningApp().io, .real).toSeconds());
}

/// Global settings only hold prices that differ from the catalogue's.
pub fn setOrePrice(name: []const u8, price: f64) void {
    const global = session.global();
    for (global.ptr.oreTable.items, 0..) |override, index| {
        if (std.mem.eql(u8, override.name, name)) return global.item("oreTable", index).set("price", price);
    }
    for (config.DEFAULT_ORE_TABLE) |entry| {
        if (std.mem.eql(u8, entry.name, name) and entry.price == price) return;
    }
    const added = global.append("oreTable", .{}) orelse return;
    added.set("name", name);
    added.set("price", price);
}

/// Grouped by category, two ores to a row; names are fixed, since mined-ore log lines are matched against them.
fn oreTable(context: *ui.Frame) !void {
    const table = Rect{ .key = .src(@src()), .style = &style.table };
    _ = try table.open(context);
    const header = Rect{ .key = .src(@src()), .style = &style.table_header };
    _ = try header.open(context);
    for (0..2) |column| {
        const cell = Rect{ .key = ui.Key.str("knots.ore.heading").indexed(column), .style = &style.table_cell };
        _ = try cell.open(context);
        try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.ore.heading_name").indexed(column), .content = lang.text("Name"), .style = &style.table_heading_grow });
        try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.ore.heading_price").indexed(column), .content = lang.text("Price (ISK)"), .style = &style.table_heading_price });
        try cell.close(context);
    }
    try header.close(context);

    for (ORE_CATEGORIES, 0..) |category, category_index| {
        const band = Rect{ .key = ui.Key.str("knots.ore.band").indexed(category_index), .style = if (category_index > 0) &style.table_band_separated else &style.table_band };
        _ = try band.open(context);
        try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.ore.category").indexed(category_index), .content = lang.text(category), .style = &style.table_category_label });
        try band.close(context);
        try oreRows(context, category);
    }
    try table.close(context);
}

fn oreRows(context: *ui.Frame, category: []const u8) !void {
    var catalog_indices: [config.DEFAULT_ORE_TABLE.len]usize = undefined;
    var ore_count: usize = 0;
    for (config.DEFAULT_ORE_TABLE, 0..) |entry, catalog_index| {
        if (!std.mem.eql(u8, entry.category, category)) continue;
        catalog_indices[ore_count] = catalog_index;
        ore_count += 1;
    }
    var left_index: usize = 0;
    while (left_index < ore_count) : (left_index += 2) {
        const left_catalog_index = catalog_indices[left_index];
        const row = Rect{ .key = ui.Key.str("knots.ore.row").indexed(left_catalog_index), .style = &style.table_row };
        _ = try row.open(context);
        try oreCell(context, left_catalog_index);
        if (left_index + 1 < ore_count) {
            try oreCell(context, catalog_indices[left_index + 1]);
        } else {
            // Holds the lone ore to the left half, in line with the column above.
            try context.e(Rect{ .key = ui.Key.str("knots.ore.filler").indexed(left_catalog_index), .style = &style.table_cell });
        }
        try row.close(context);
    }
}

fn oreCell(context: *ui.Frame, catalog_index: usize) !void {
    const entry = config.DEFAULT_ORE_TABLE[catalog_index];
    const cell = Rect{ .key = ui.Key.str("knots.ore.cell").indexed(catalog_index), .style = &style.table_cell };
    _ = try cell.open(context);
    try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.ore.name").indexed(catalog_index), .content = entry.name, .style = &style.table_name_cell });
    if (try bind.valueBox(context, ui.Key.str("knots.ore.price").indexed(catalog_index), orePrice(entry), &style.price_input)) |typed| {
        setOrePrice(entry.name, typed);
    }
    try cell.close(context);
}

/// The saved override, or the catalogue's own price.
fn orePrice(entry: config.OreEntry) f64 {
    for (session.global().ptr.oreTable.items) |override| {
        if (std.mem.eql(u8, override.name, entry.name)) return override.price;
    }
    return entry.price;
}

fn priceControls(context: *ui.Frame) !void {
    const row = Rect{ .key = .src(@src()), .style = &style.button_row };
    _ = try row.open(context);
    const fetched_at_seconds = session.global().get("orePricesFetchedAtSeconds");
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = try fetchedLabel(context.arena(), fetched_at_seconds), .style = &style.hint });
    const toggle_label = if (g_is_table_shown) "Hide Prices" else "Show Prices";
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text(toggle_label), .style = &style.plain_button })).clicked) {
        g_is_table_shown = !g_is_table_shown;
    }
    if (try widgets.glyphButton(context, .src(@src()), .refresh, "Fetch Prices", &style.add_button, prices.isFetching())) {
        if (host.fetchPrices()) status.show(.info, "Fetching {n} price(s)", .{ .n = prices.NAMES.len });
    }
    try row.close(context);
}

/// In EVE time (UTC), the clock players already go by.
fn fetchedLabel(arena: std.mem.Allocator, fetched_at_seconds: i64) ![]const u8 {
    if (fetched_at_seconds <= 0) return lang.text("Prices never fetched");
    const day = std.time.epoch.EpochSeconds{ .secs = @intCast(fetched_at_seconds) };
    const year_day = day.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = day.getDaySeconds();
    const date = try std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
    });
    return lang.format(arena, "Last fetched {date} EVE time", .{ .date = date });
}

fn chatlogNotice(context: *ui.Frame) !void {
    if (session.profile().ptr.chatlog.enabled) return;
    try widgets.noticeWithButton(context, .str("knots.mining.chatlog"), "The Mining overlay requires Log Monitoring enabled to read logs.", "Go to Log Files", .log_monitoring);
}
