//! The configuration window's Notifications tab; main thread only.
const ui = @import("ui");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const overlay_text = @import("overlay_text.zig");

pub fn show(context: *ui.Frame) !void {
    const profile = session.profile();
    if (!profile.ptr.chatlog.enabled) {
        try widgets.notice(context, .src(@src()), "Notifications requires Log Monitoring enabled to read logs and trigger alerts.");
    }
    try system(context);
    try speech(context);
    try eventAlerts(context);
    try historyPanel(context);
    try travel(context);
}

fn system(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Notification System", "Configure position, duration, and suppression behavior for event notifications.", .profile, &style.section);
    const ref = session.profile().child("thumbnail").child("notifications");
    try bind.toggle(context, ref, "enabled", "Enable Notifications");
    try overlay_text.show(context, ref, .snakeCase("", false));
    try bind.number(context, ref, "suppress_click_duration_ms", "Click Suppress Duration (s)", .{ .ms_as_seconds = true });
    try widgets.hintText(context, .src(@src()), "Suppresses further notifications on a thumbnail for this long after you click it.");
    try bind.number(context, ref, "notified_cycle_retention_seconds", "Recently-Notified Cycle Retention (s)", .{});
    try widgets.hintText(context, .src(@src()), "How long a character stays in the \"recently notified\" cycle group after its last alert.");
    try section.close(context);
}

fn speech(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Text-to-Speech", "Speak alerts aloud using the Windows system voice. Enable individual event types below in the \"TTS\" column.", .profile, &style.section);
    const ref = session.profile().child("thumbnail").child("notifications");
    try bind.toggle(context, ref, "tts_speak_character_name", "Prefix Spoken Alerts with the Character Name");
    try bind.toggle(context, ref, "tts_use_display_name", "Speak Display Name Instead of Character Name");
    try widgets.hintText(context, .src(@src()), "Only takes effect while Prefix Spoken Alerts with the Character Name is also on.");
    try bind.slider(context, ref, "tts_volume", "Volume", .{});
    try bind.slider(context, ref, "tts_rate", "Speed", .{});
    try widgets.hintText(context, .src(@src()), "0 is normal speaking speed; negative is slower, positive is faster.");
    try section.close(context);
}

fn eventAlerts(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Event Alerts", "Per-event notification, suppression, speech, and border behavior. Select an event on the left to edit it.", .profile, &style.section);
    try widgets.notPorted(context, .src(@src()), "the per-event settings");
    try section.close(context);
}

fn historyPanel(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "History Panel", "A draggable, resizable panel showing recent notification history. Click a row to jump to that character.", .profile, &style.section);
    const ref = session.profile().child("display");
    try bind.toggle(context, ref, "showNotifInfoPanel", "Show History Panel");
    try bind.number(context, ref, "notifInfoPanelWidth", "Panel Width (px)", .{});
    try bind.number(context, ref, "notifInfoPanelHeight", "Panel Height (px)", .{});
    try bind.number(context, ref, "notifInfoPanelMaxRows", "Max History Rows", .{});
    try bind.slider(context, ref, "notifInfoPanelOpacity", "Panel Opacity", .{ .display = .percent_of_255 });

    try widgets.subheading(context, .src(@src()), "Font");
    try bind.fontName(context, ref, "notifInfoPanelFontName", "Font Name");
    try bind.number(context, ref, "notifInfoPanelFontSize", "Font Size (px)", .{});
    try bind.choice(context, ref, "notifInfoPanelFontWeight", "Font Weight");

    try widgets.subheading(context, .src(@src()), "Behavior");
    try bind.toggle(context, ref, "rememberNotifInfoPanelPosition", "Remember History Panel Position");
    try bind.toggle(context, ref, "hideNotifInfoPanelWhenNoCharacters", "Hide Panel When No Characters Are Logged In");
    try bind.toggle(context, ref, "notifInfoPanelShowTimestamp", "Show Relative Timestamps");
    try widgets.hintText(context, .src(@src()), "Shows times like \"5m ago\" instead of a fixed clock time.");
    try bind.toggle(context, ref, "notifInfoPanelShowCategoryFilters", "Show Category Filters");
    try widgets.hintText(context, .src(@src()), "Adds filter buttons for each notification category to the panel.");
    try bind.toggle(context, ref, "notifInfoPanelMergeEnabled", "Merge Repeated Notifications");
    try widgets.hintText(context, .src(@src()), "Combines identical notifications fired back to back into one row with a +N count. Click a merged row to expand it.");
    try bind.number(context, ref, "notifInfoPanelMergeWindowSec", "Merge Window (seconds)", .{});
    try section.close(context);
}

fn travel(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Travel Mode", "Detects when a tracked character falls behind while the rest of the group jumps together, and fires a notification. Runs automatically once enabled below - no manual start/stop needed.", .profile, &style.section);
    const ref = session.profile().child("travel");
    try bind.toggle(context, ref, "enabled", "Enable Travel Mode");
    try bind.number(context, ref, "window_seconds", "Catch-Up Window (seconds)", .{});
    try widgets.hintText(context, .src(@src()), "How long a character can lag behind the group's jump before this fires.");
    try bind.choice(context, ref, "threshold_mode", "Group Size Threshold");
    try widgets.hintText(context, .src(@src()), "Minimum group size required before a straggler triggers an alert.");
    switch (ref.get("threshold_mode")) {
        .percent => try bind.number(context, ref, "threshold_percent", "Minimum Percentage", .{}),
        .count => try bind.number(context, ref, "threshold_count", "Minimum Count", .{}),
    }
    try section.close(context);
}
