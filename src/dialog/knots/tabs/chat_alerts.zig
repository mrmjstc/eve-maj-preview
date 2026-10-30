//! The configuration window's Chat Alerts tab: rules for which chat messages raise an alert; main thread only.
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const search = @import("../search.zig");
const event_alerts = @import("event_alerts.zig");
const lang = @import("../../../lang/lang.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const ProfileRef = session.Ref(config.Config);

const UNNAMED = "New Chat Alert";

var g_selected_index: usize = 0;

pub fn show(context: *ui.Frame) !void {
    const profile = session.profile();
    const is_enabled = profile.ptr.thumbnail.notifications.enabled;
    if (!is_enabled) {
        try widgets.noticeWithButton(context, .src(@src()), "Chat Alerts requires Notification System switched on in the Notifications tab.", "Go to Notifications", .notifications);
    } else if (!profile.ptr.chatlog.enabled) {
        try widgets.noticeWithButton(context, .src(@src()), "Chat Alerts read EVE's chat logs, so they need Log Monitoring.", "Go to Log Monitoring", .log_monitoring);
    }
    const section = try widgets.openSection(context, "Chat Alerts", "Alert on messages in the chat channels you choose.", &style.fill_section);
    const options = try widgets.openFillGroup(context, .src(@src()), is_enabled);
    const rule_count = profile.ptr.chatAlerts.items.len;
    if (rule_count == 0) {
        try emptyState(context, profile);
    } else {
        // The list can shrink while the window is open, e.g. on a profile switch.
        if (g_selected_index >= rule_count) g_selected_index = rule_count - 1;
        const master_detail = Rect{ .key = .src(@src()), .style = &style.master_detail_fill };
        _ = try master_detail.open(context);
        try roster(context, profile);
        try detail(context, profile, g_selected_index);
        try master_detail.close(context);
    }
    try options.close(context);
    try section.close(context);
}

/// Instead of the list and details, until there's a rule.
fn emptyState(context: *ui.Frame, profile: ProfileRef) !void {
    const state = try widgets.openEmptyState(context, .str("knots.chat_alerts.empty"), "No chat alerts yet", "Get alerted to intel near your clients, or to words you choose.");
    if (try widgets.glyphButton(context, .str("knots.chat_alerts.empty.add"), .add, "Add Chat Alert", &style.add_button, false)) addRule(profile);
    try state.close(context);
}

fn addRule(profile: ProfileRef) void {
    const added = profile.append("chatAlerts", .{}) orelse return;
    g_selected_index = added.index;
}

fn roster(context: *ui.Frame, profile: ProfileRef) !void {
    const list = try widgets.openRoster(context, .str("knots.chat_alerts.roster"), &style.roster, true);
    for (profile.ptr.chatAlerts.items, 0..) |entry, index| {
        const is_selected = index == g_selected_index;
        const row = Button{ .key = ui.Key.str("knots.chat_alerts.row").indexed(index), .style = if (is_selected) &style.roster_row_selected else &style.roster_row };
        if ((try widgets.openRosterRow(context, row)).clicked and !is_selected) {
            g_selected_index = index;
            context.requestRedraw();
        }
        try context.e(Rect{ .key = ui.Key.str("knots.chat_alerts.dot").indexed(index), .style = if (entry.enabled) &style.event_dot_on else &style.event_dot_off });
        const name = try rowName(context, profile, index);
        try context.e(Text{
            .selectable = false,
            .key = ui.Key.str("knots.chat_alerts.name").indexed(index),
            .content = name,
            .style = if (is_selected) &style.roster_name_selected else &style.roster_name,
        });
        try widgets.fitRosterRow(context, name, style.EVENT_DOT_SIZE, "");
        try row.close(context);
    }
    if (try list.close(context, .{ .add_label = "Add Chat Alert" }) == .add) addRule(profile);
}

fn rowName(context: *ui.Frame, profile: ProfileRef, index: usize) ![]const u8 {
    const name = try bind.liveText(context, profile.item("chatAlerts", index), "name");
    return if (name.len > 0) name else lang.text(UNNAMED);
}

fn detail(context: *ui.Frame, profile: ProfileRef, index: usize) !void {
    const entry = profile.item("chatAlerts", index);
    const alert = entry.child("alert");
    const notification_type = entry.get("kind").notificationType();
    var is_enabled: bool = entry.get("enabled");
    const stack = try widgets.openScrollPane(context, .str("knots.chat_alerts.detail"), style.detail_scroll);
    const previous_rows = widgets.useDetailRows();
    defer widgets.restoreRows(previous_rows);

    const header = try widgets.openDetailHeader(context, .src(@src()));
    const name_label = lang.text("Name");
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = name_label, .style = try widgets.detailLabelStyle(context, name_label) });
    try bind.textBox(context, entry, "name", "e.g. Home intel");
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("\u{25B6} Test"), .disabled = !is_enabled, .style = &style.plain_button })).clicked) {
        event_alerts.testAlert(notification_type, alert.ptr.*);
    }
    const removed = try widgets.confirmButton(context, ui.Key.str("knots.chat_alerts.remove").indexed(index), "Remove", "Confirm", &style.plain_button, &style.confirm_button);
    try header.close(context);

    if (try widgets.switchRow(context, ui.Key.str("knots.chat_alerts.enabled").indexed(index), "Enabled", &is_enabled)) entry.set("enabled", is_enabled);
    try widgets.hintText(context, .src(@src()), "Turns this rule on or off.");
    try widgets.separator(context, .str("knots.chat_alerts.separator.enabled"));

    const rest = try widgets.openGroup(context, .src(@src()), is_enabled);
    const matching = try widgets.openFieldGroup(context, .str("knots.chat_alerts.matching"), "Matching");
    try bind.segmented(context, entry, "kind", "Type", &.{ "Intel", "Keyword" });
    try widgets.hintText(context, .src(@src()), switch (entry.get("kind")) {
        .intel => "Alerts when a message names a system near one of your clients, on the nearest client.",
        .keyword => "Alerts when a message holds one of your words.",
    });

    try bind.styledText(context, entry, "channels", "Channels", "e.g. *.imperium, Fleet", &style.custom_text_input);
    try widgets.hintText(context, .src(@src()), "Separate channel names with commas. Wildcards: * any text, ? one character, # one digit. Only these channels are read.");

    switch (entry.get("kind")) {
        .intel => {
            try bind.number(context, entry, "max_jumps", "Max Jumps", .{ .unit = "jumps", .singular_unit = "jump" });
            try widgets.hintText(context, .src(@src()), "How far a named system can be from a client; 0 means only the same system.");
        },
        .keyword => {
            try bind.styledText(context, entry, "keywords", "Keywords", "e.g. bubble, gate camp", &style.custom_text_input);
            try widgets.hintText(context, .src(@src()), "Separate words or phrases with commas. Whole words only; case doesn't matter.");
        },
    }

    try bind.styledText(context, entry, "exclude", "Exclude", "e.g. clr, nv", &style.custom_text_input);
    try widgets.hintText(context, .src(@src()), "A message holding any of these never alerts for this rule.");
    try matching.close(context);
    try widgets.separator(context, .str("knots.chat_alerts.separator.matching"));

    const timing = try widgets.openFieldGroup(context, .str("knots.chat_alerts.timing"), "Timing");
    try bind.number(context, alert, "duration_ms", "Duration", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How long the alert shows; 0 keeps it until dismissed.");
    try bind.number(context, entry, "cooldown_ms", "Cooldown", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "The same system or keyword stays quiet for this long.");
    try timing.close(context);
    try widgets.separator(context, .str("knots.chat_alerts.separator.timing"));

    // The search's index draws every tab in one frame, and Event Alerts' own alert settings already give it these words.
    if (!search.needsIndex()) try event_alerts.alertSettings(context, alert, notification_type, .rule_sound_file, index);
    try rest.close(context);
    try stack.close(context);

    if (removed) {
        profile.remove("chatAlerts", index);
        g_selected_index = @min(index, profile.ptr.chatAlerts.items.len -| 1);
    }
}
