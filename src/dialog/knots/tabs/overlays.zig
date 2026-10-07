//! The configuration window's Combat, Mining, Bounty and Resources tabs, whose texts are placed and styled on the Text Overlays tab's preview; main thread only.
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

const Rect = ui.component.Rect;
const Text = ui.component.Text;

/// Ores first, then ice, moon ores and gas.
const ORE_CATEGORIES = [_][]const u8{ "Ore", "Ice", "Moons", "Gas" };

pub fn showCombat(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Combat Overlay Settings", "Displays incoming and outgoing DPS below each thumbnail, calculated from EVE gamelogs. Requires chatlog monitoring to be enabled.", &style.section);
    const ref = session.profile().child("combat");
    try bind.toggle(context, ref, "enabled", "Enable Text Overlays");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.number(context, ref, "window_seconds", "Window", .{ .unit = "s" });
    try widgets.hintText(context, .src(@src()), "The rolling look-back period DPS is averaged over, not how often the number updates.");
    try bind.number(context, ref, "update_interval_ms", "Update Interval", .{ .ms_as_seconds = true, .unit = "s" });
    try bind.text(context, ref, "damage_alert_excluded_weapons", "Exclude Weapons", "e.g. Smartbomb, Warp Scrambler");
    try widgets.hintText(context, .src(@src()), "Case-insensitive, comma-separated name matches. Only suppresses the Taking Damage alert - excluded hits still count toward the DPS shown above.");
    try options.close(context);
    try section.close(context);
}

pub fn showMining(context: *ui.Frame) !void {
    const ref = session.profile().child("mining");
    const section = try widgets.openSection(context, "Mining Overlay Settings", "Displays m3 mined per second on each thumbnail, calculated from EVE gamelogs. Requires chatlog monitoring to be enabled.", &style.section);
    try bind.toggle(context, ref, "enabled", "Enable Text Overlays");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.number(context, ref, "window_seconds", "Window", .{ .unit = "s" });
    try widgets.hintText(context, .src(@src()), "The rolling look-back period the m3/s rate is averaged over, not how often the number updates.");
    try bind.number(context, ref, "update_interval_ms", "Update Interval", .{ .ms_as_seconds = true, .unit = "s" });
    try bind.toggle(context, ref, "show_isk_rate", "Show ISK Rate");
    try widgets.hintText(context, .src(@src()), "Valued using the prices set in Ore / Ice / Gas Prices below - fetch or fill those in first, or this reads 0.");
    const isk_rate = try widgets.openGroup(context, .src(@src()), ref.get("show_isk_rate"));
    try bind.choice(context, ref, "isk_rate_unit", "ISK Rate Unit");
    try isk_rate.close(context);
    try bind.toggle(context, ref, "show_prefix", "Show M: Prefix");
    try options.close(context);
    try section.close(context);

    const alerts = try widgets.openSection(context, "Alerts", "Notifications triggered by mining laser activity. Requires Text Overlays above to be enabled.", &style.section);
    const alert_options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try widgets.subheading(context, .src(@src()), "Laser Idle Alert");
    try widgets.hintText(context, .src(@src()), "Fires when fewer than Event Threshold mining hits occur within Detection Window - a slowdown, not full silence.");
    try bind.number(context, ref, "idle_alert_window_seconds", "Detection Window", .{ .unit = "s" });
    try bind.number(context, ref, "idle_alert_threshold", "Event Threshold", .{});
    try widgets.subheading(context, .src(@src()), "Mining Stopped Alert");
    try widgets.hintText(context, .src(@src()), "Fires once mining has been completely silent for the Silence Window; rearms as soon as mining resumes.");
    try bind.number(context, ref, "stopped_alert_window_seconds", "Silence Window", .{ .unit = "s" });
    try alert_options.close(context);
    try alerts.close(context);

    const prices_section = try widgets.openSection(context, "Ore / Ice / Gas Prices", "\"Fetch Prices\" pulls current Jita buy prices from EVE's market.", &style.section);
    try oreTable(context);
    const fetching = prices.isFetching();
    if (try widgets.glyphButton(context, .src(@src()), .refresh, "Fetch Prices", &style.full_width_button, fetching)) {
        if (host.fetchPrices()) status.show(.info, "Fetching {d} price(s)", .{prices.NAMES.len});
    }
    try prices_section.close(context);
}

/// Grouped by category; names are fixed, since mined-ore log lines are matched against them.
fn oreTable(context: *ui.Frame) !void {
    const table = Rect{ .key = .src(@src()), .style = &style.table };
    _ = try table.open(context);
    const header = Rect{ .key = .src(@src()), .style = &style.table_header };
    _ = try header.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "", .style = &style.table_category_cell });
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Name", .style = &style.table_heading_grow });
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Price (ISK)", .style = &style.table_heading_price });
    try header.close(context);

    var row_index: usize = 0;
    inline for (ORE_CATEGORIES) |category| {
        var is_first = true;
        for (config.DEFAULT_ORE_TABLE, 0..) |entry, catalog_index| {
            if (!std.mem.eql(u8, entry.category, category)) continue;
            const row = Rect{ .key = ui.Key.str("knots.ore.row").indexed(catalog_index), .style = if (is_first and row_index > 0) &style.table_row_separated else &style.table_row };
            _ = try row.open(context);
            try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.ore.category").indexed(catalog_index), .content = if (is_first) category else "", .style = &style.table_category_cell });
            try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.ore.name").indexed(catalog_index), .content = entry.name, .style = &style.table_name_cell });
            if (try bind.valueBox(context, ui.Key.str("knots.ore.price").indexed(catalog_index), orePrice(entry), &style.price_input)) |typed| {
                setOrePrice(entry.name, typed);
            }
            try row.close(context);
            is_first = false;
            row_index += 1;
        }
    }
    try table.close(context);
}

/// The saved override, or the catalogue's own price.
fn orePrice(entry: @TypeOf(config.DEFAULT_ORE_TABLE[0])) f64 {
    for (session.global().ptr.oreTable.items) |override| {
        if (std.mem.eql(u8, override.name, entry.name)) return override.price;
    }
    return entry.price;
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
    global.append("oreTable", .{});
    const added = global.item("oreTable", global.ptr.oreTable.items.len - 1);
    added.set("name", name);
    added.set("price", price);
}

pub fn showBounty(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Bounty Overlay Settings", "Displays ISK bounty payouts per minute/hour on each thumbnail, calculated from EVE gamelogs. Requires chatlog monitoring to be enabled.", &style.section);
    const ref = session.profile().child("bounty");
    try bind.toggle(context, ref, "enabled", "Enable Text Overlays");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.number(context, ref, "window_seconds", "Window", .{ .unit = "s" });
    try widgets.hintText(context, .src(@src()), "The rolling look-back period the ISK/s rate is averaged over, not how often the number updates.");
    try bind.number(context, ref, "update_interval_ms", "Update Interval", .{ .ms_as_seconds = true, .unit = "s" });
    try bind.choice(context, ref, "isk_rate_unit", "ISK Rate Unit");
    try bind.toggle(context, ref, "show_prefix", "Show ISK: Prefix");
    try options.close(context);
    try section.close(context);
}

pub fn showResources(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Resource Usage Overlay Settings", "Displays each client's CPU%, RAM, and VRAM usage on its thumbnail, sampled directly from Windows rather than from EVE's logs.", &style.section);
    const ref = session.profile().child("resources");
    try bind.toggle(context, ref, "enabled", "Enable Text Overlays");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.toggle(context, ref, "show_cpu", "Show CPU %");
    try widgets.hintText(context, .src(@src()), "That EVE client process's own usage, not total system CPU.");
    try bind.toggle(context, ref, "show_ram", "Show RAM");
    try bind.toggle(context, ref, "show_vram", "Show VRAM");
    try widgets.hintText(context, .src(@src()), "Only counts video memory that EVE client's own process has allocated, not the GPU's total usage.");
    try bind.number(context, ref, "update_interval_ms", "Update Interval", .{ .ms_as_seconds = true, .unit = "s" });
    try options.close(context);
    try section.close(context);
}
