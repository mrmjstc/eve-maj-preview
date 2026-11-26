//! The General tab's Log Monitoring sections: where the chat and game logs are, and how often they're polled; main thread only.
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const host = @import("../host.zig");
const pickers = @import("../pickers.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const lang = @import("../../../lang/lang.zig");
const window_mod = @import("../window.zig");

const Button = ui.component.Button;
const Tooltip = ui.component.Tooltip;
const ChatlogRef = session.Ref(config.ChatlogConfig);
const Window = window_mod.Window;

const DirectoryRow = struct {
    field: []const u8,
    label: []const u8,
    placeholder: []const u8,
    target: pickers.Target,
    title: []const u8,
    hint: []const u8,
};

pub fn show(window: *Window, context: *ui.Frame) !void {
    const chatlog = window.session.global().child("chatlog");
    try monitoring(window, context, chatlog);
    if (window.session.global().get("advancedMode")) try polling(window, context, chatlog);
}

fn monitoring(window: *Window, context: *ui.Frame, chatlog: ChatlogRef) !void {
    const section = try window.widgets.openSharedSection(context, "Log Monitoring", "Reads EVE's logs for systems, alerts, and combat, mining and bounty rates.", &style.section);
    try window.bind.toggle(context, chatlog, "enabled", "Enable Log Monitoring");
    const options = try window.widgets.openGroup(context, .src(@src()), chatlog.get("enabled"));
    try directory(window, context, chatlog, .{
        .field = "chatlogDir",
        .label = "Chatlog Directory",
        .placeholder = "C:\\Users\\...\\Chatlogs",
        .target = .chatlog_dir,
        .title = "Select Chatlog Directory",
        .hint = "Usually Documents\\EVE\\logs\\Chatlogs. In EVE, enable Esc > Chat Channel Settings > Log chat to file.",
    });
    try directory(window, context, chatlog, .{
        .field = "gamelogDir",
        .label = "Gamelog Directory",
        .placeholder = "C:\\Users\\...\\Gamelogs",
        .target = .gamelog_dir,
        .title = "Select Gamelog Directory",
        .hint = "Usually Documents\\EVE\\logs\\Gamelogs.",
    });
    try options.close(context);
    try section.close(context);
}

/// Browse's picker sets the path once it closes; hovering shows a path too long for the box.
fn directory(window: *Window, context: *ui.Frame, chatlog: ChatlogRef, comptime row_settings: DirectoryRow) !void {
    const field = row_settings.field;
    const row = try window.widgets.openBinding(context, .str("knots.chatlog.dir:" ++ field), row_settings.label);
    // Copied, since the box can replace the path before the tooltip draws it.
    const path = try context.arena().dupe(u8, chatlog.get(field));
    const tip: ?Tooltip = if (path.len > 0) .{
        .key = .str("knots.chatlog.path:" ++ field),
        .content = path,
        .parts = .{ .popup = &style.path_tooltip },
    } else null;
    if (tip) |t| _ = try t.open(context);
    try window.bind.styledTextBox(context, chatlog, field, row_settings.placeholder, &style.path_input);
    if (tip) |t| try t.close(context);
    if ((try context.interact(Button{ .key = .str("knots.chatlog.browse:" ++ field), .label = lang.text("Browse"), .style = &style.plain_button })).clicked) {
        window.host.browseFolder(row_settings.target, row_settings.title);
    }
    try row.close(context);
    try window.widgets.hintText(context, .str("knots.chatlog.dir.hint:" ++ field), row_settings.hint);
}

fn polling(window: *Window, context: *ui.Frame, chatlog: ChatlogRef) !void {
    const section = try window.widgets.openSharedSection(context, "Polling & Performance", "How often the logs are read, and how a quiet log is read less often.", &style.section);
    const options = try window.widgets.openGroup(context, .src(@src()), chatlog.get("enabled"));
    try window.bind.number(context, chatlog, "pollIntervalMs", "Poll Interval", .{ .shows_seconds = true, .unit = "s" });
    try window.widgets.hintText(context, .src(@src()), "How often logs are checked for new lines.");
    try window.bind.number(context, chatlog, "idlePollThreshold", "Polls Before Idle", .{ .unit = "polls", .singular_unit = "poll" });
    try window.widgets.hintText(context, .src(@src()), "Checks with nothing new before a quiet log is checked less often.");
    try window.bind.number(context, chatlog, "maxPollMultiplier", "Max Poll Multiplier", .{ .unit = "\u{00D7}" });
    try window.widgets.hintText(context, .src(@src()), "How much less often a quiet log can be checked.");
    try options.close(context);
    try section.close(context);
}
