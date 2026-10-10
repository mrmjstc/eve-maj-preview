//! The configuration window's Log Monitoring tab: where the chat and game logs are, and how often they're polled; main thread only.
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const host = @import("../host.zig");
const pickers = @import("../pickers.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const Button = ui.component.Button;
const Tooltip = ui.component.Tooltip;
const ChatlogRef = session.Ref(config.ChatlogConfig);

pub fn show(context: *ui.Frame) !void {
    const chatlog = session.profile().child("chatlog");
    try monitoring(context, chatlog);
    if (session.global().get("advancedMode")) try polling(context, chatlog);
}

fn monitoring(context: *ui.Frame, chatlog: ChatlogRef) !void {
    const section = try widgets.openSection(context, "Log Monitoring", "Watches EVE's chatlog and gamelog files to drive the DPS overlay, mining overlay, and system-location display. In EVE, enable Esc > Chat Channel Settings > Log chat to file so logs get written to disk.", &style.section);
    try bind.toggle(context, chatlog, "enabled", "Enable Log Monitoring");
    const options = try widgets.openGroup(context, .src(@src()), chatlog.get("enabled"));
    try directory(context, chatlog, "chatlogDir", "Chatlog Directory", "C:\\Users\\...\\Chatlogs", .chatlog_dir, "Select Chatlog Directory");
    try directory(context, chatlog, "gamelogDir", "Gamelog Directory", "C:\\Users\\...\\Gamelogs", .gamelog_dir, "Select Gamelog Directory");
    try options.close(context);
    try section.close(context);
}

/// A path box with a Browse button, whose folder picker sets the path once it closes; hovering the box shows a path too long for it.
fn directory(context: *ui.Frame, chatlog: ChatlogRef, comptime field: []const u8, label: []const u8, placeholder: []const u8, target: pickers.Target, title: []const u8) !void {
    const row = try widgets.openBinding(context, .str("knots.chatlog.dir:" ++ field), label);
    // Copied, since the box can replace the path before the tooltip draws it.
    const path = try context.arena().dupe(u8, chatlog.get(field));
    const tip: ?Tooltip = if (path.len > 0) .{ .key = .str("knots.chatlog.path:" ++ field), .content = path, .parts = .{ .popup = &style.path_tooltip } } else null;
    if (tip) |t| _ = try t.open(context);
    try bind.styledTextBox(context, chatlog, field, placeholder, &style.path_input);
    if (tip) |t| try t.close(context);
    if ((try context.interact(Button{ .key = .str("knots.chatlog.browse:" ++ field), .label = "Browse", .style = &style.plain_button })).clicked) {
        host.browseFolder(target, title);
    }
    try row.close(context);
}

fn polling(context: *ui.Frame, chatlog: ChatlogRef) !void {
    const section = try widgets.openSection(context, "Polling & Performance", "", &style.section);
    const options = try widgets.openGroup(context, .src(@src()), chatlog.get("enabled"));
    try bind.number(context, chatlog, "pollIntervalMs", "Poll Interval", .{ .ms_as_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How often each log file is checked for new lines, before any idle backoff kicks in.");
    try bind.number(context, chatlog, "idlePollThreshold", "Idle Threshold (polls)", .{});
    try widgets.hintText(context, .src(@src()), "Consecutive empty polls of a log file before its interval starts backing off.");
    try bind.number(context, chatlog, "maxPollMultiplier", "Max Poll Multiplier", .{});
    try widgets.hintText(context, .src(@src()), "Caps how much slower an idle file's interval can back off to; resets to 1x as soon as it has new lines again.");
    try options.close(context);
    try section.close(context);
}
