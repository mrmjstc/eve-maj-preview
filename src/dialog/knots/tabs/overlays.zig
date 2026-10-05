//! The configuration window's Combat, Mining, Bounty and Resources tabs, one per overlay; main thread only.
const ui = @import("ui");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const overlay_text = @import("overlay_text.zig");

pub fn showCombat(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Combat Overlay Settings", "Displays incoming and outgoing DPS below each thumbnail, calculated from EVE gamelogs. Requires chatlog monitoring to be enabled.", .profile, &style.section);
    const ref = session.profile().child("combat");
    try bind.toggle(context, ref, "enabled", "Enable Text Overlays");
    try bind.number(context, ref, "window_seconds", "Window (seconds)", .{});
    try widgets.hintText(context, .src(@src()), "The rolling look-back period DPS is averaged over, not how often the number updates.");
    try bind.number(context, ref, "update_interval_ms", "Update Interval (s)", .{ .ms_as_seconds = true });
    try bind.text(context, ref, "damage_alert_excluded_weapons", "Exclude Weapons", "e.g. Smartbomb, Drone");
    try widgets.hintText(context, .src(@src()), "Case-insensitive, comma-separated name matches. Only suppresses the Taking Damage alert - excluded hits still count toward the DPS shown above.");

    try widgets.subheading(context, .src(@src()), "Incoming Damage");
    try bind.toggle(context, ref, "show_incoming", "Show Incoming Damage");
    try bind.toggle(context, ref, "incoming_show_prefix", "Show IN: Prefix");
    try overlay_text.show(context, ref, .snakeCase("incoming_", true));

    try widgets.subheading(context, .src(@src()), "Outgoing Damage");
    try bind.toggle(context, ref, "show_outgoing", "Show Outgoing Damage");
    try bind.toggle(context, ref, "outgoing_show_prefix", "Show OUT: Prefix");
    try overlay_text.show(context, ref, .snakeCase("outgoing_", true));
    try section.close(context);
}

pub fn showMining(context: *ui.Frame) !void {
    const ref = session.profile().child("mining");
    const section = try widgets.openSection(context, "Mining Overlay Settings", "Displays m3 mined per second on each thumbnail, calculated from EVE gamelogs. Requires chatlog monitoring to be enabled.", .profile, &style.section);
    try bind.toggle(context, ref, "enabled", "Enable Text Overlays");
    try bind.number(context, ref, "window_seconds", "Window (seconds)", .{});
    try widgets.hintText(context, .src(@src()), "The rolling look-back period the m3/s rate is averaged over, not how often the number updates.");
    try bind.number(context, ref, "update_interval_ms", "Update Interval (s)", .{ .ms_as_seconds = true });
    try overlay_text.show(context, ref, .snakeCase("", true));
    try bind.toggle(context, ref, "show_isk_rate", "Show ISK Rate");
    try widgets.hintText(context, .src(@src()), "Valued using the prices set in Ore / Ice / Gas Prices below - fetch or fill those in first, or this reads 0.");
    try bind.choice(context, ref, "isk_rate_unit", "ISK Rate Unit");
    try bind.toggle(context, ref, "show_prefix", "Show M: Prefix");
    try section.close(context);

    const alerts = try widgets.openSection(context, "Alerts", "Notifications triggered by mining laser activity. Requires Text Overlays above to be enabled.", .profile, &style.section);
    try widgets.subheading(context, .src(@src()), "Laser Idle Alert");
    try widgets.hintText(context, .src(@src()), "Fires when fewer than Event Threshold mining hits occur within Detection Window - a slowdown, not full silence.");
    try bind.number(context, ref, "idle_alert_window_seconds", "Detection Window (seconds)", .{});
    try bind.number(context, ref, "idle_alert_threshold", "Event Threshold", .{});
    try widgets.subheading(context, .src(@src()), "Mining Stopped Alert");
    try widgets.hintText(context, .src(@src()), "Fires once mining has been completely silent for the Silence Window; rearms as soon as mining resumes.");
    try bind.number(context, ref, "stopped_alert_window_seconds", "Silence Window (seconds)", .{});
    try alerts.close(context);

    const prices = try widgets.openSection(context, "Ore / Ice / Gas Prices", "\"Fetch Prices\" pulls current Jita buy prices from EVE's market.", .global, &style.section);
    try widgets.notPorted(context, .src(@src()), "the ore price table");
    try prices.close(context);
}

pub fn showBounty(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Bounty Overlay Settings", "Displays ISK bounty payouts per minute/hour on each thumbnail, calculated from EVE gamelogs. Requires chatlog monitoring to be enabled.", .profile, &style.section);
    const ref = session.profile().child("bounty");
    try bind.toggle(context, ref, "enabled", "Enable Text Overlays");
    try bind.number(context, ref, "window_seconds", "Window (seconds)", .{});
    try widgets.hintText(context, .src(@src()), "The rolling look-back period the ISK/s rate is averaged over, not how often the number updates.");
    try bind.number(context, ref, "update_interval_ms", "Update Interval (s)", .{ .ms_as_seconds = true });
    try overlay_text.show(context, ref, .snakeCase("", true));
    try bind.choice(context, ref, "isk_rate_unit", "ISK Rate Unit");
    try bind.toggle(context, ref, "show_prefix", "Show ISK: Prefix");
    try section.close(context);
}

pub fn showResources(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Resource Usage Overlay Settings", "Displays each client's CPU%, RAM, and VRAM usage on its thumbnail, sampled directly from Windows rather than from EVE's logs.", .profile, &style.section);
    const ref = session.profile().child("resources");
    try bind.toggle(context, ref, "enabled", "Enable Text Overlays");
    try bind.toggle(context, ref, "show_cpu", "Show CPU %");
    try widgets.hintText(context, .src(@src()), "That EVE client process's own usage, not total system CPU.");
    try bind.toggle(context, ref, "show_ram", "Show RAM");
    try bind.toggle(context, ref, "show_vram", "Show VRAM");
    try widgets.hintText(context, .src(@src()), "Only counts video memory that EVE client's own process has allocated, not the GPU's total usage.");
    try bind.number(context, ref, "update_interval_ms", "Update Interval (s)", .{ .ms_as_seconds = true });
    try overlay_text.show(context, ref, .snakeCase("", true));
    try section.close(context);
}
