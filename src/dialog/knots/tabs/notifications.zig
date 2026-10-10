//! The configuration window's Notifications tab: the notification system, speech and travel mode; main thread only.
const ui = @import("ui");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

pub fn show(context: *ui.Frame) !void {
    const profile = session.profile();
    if (!profile.ptr.chatlog.enabled) {
        try widgets.notice(context, .src(@src()), "Notifications requires Log Monitoring enabled to read logs and trigger alerts.");
    }
    try system(context);
    try speech(context);
    try travel(context);
}

fn system(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Notification System", "Configure position, duration, and suppression behavior for event notifications.", &style.section);
    const ref = session.profile().child("thumbnail").child("notifications");
    try bind.toggle(context, ref, "enabled", "Enable Notifications");
    // Its placement and font are edited from its text on the Appearance tab's thumbnail preview.
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.number(context, ref, "suppress_click_duration_ms", "Click Suppress Duration", .{ .ms_as_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "Suppresses further notifications on a thumbnail for this long after you click it.");
    try bind.number(context, ref, "notified_cycle_retention_seconds", "Recently-Notified Cycle Retention", .{ .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How long a character stays in the \"recently notified\" cycle group after its last alert.");
    try options.close(context);
    try section.close(context);
}

fn speech(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Text-to-Speech", "Speak alerts aloud using the Windows system voice. Enable it per event with Speak Aloud on the Event Alerts tab.", &style.section);
    const ref = session.profile().child("thumbnail").child("notifications");
    // Speech only means something while notifications fire, so the section dims with them.
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.toggle(context, ref, "tts_speak_character_name", "Prefix Spoken Alerts with the Character Name");
    const display_name = try widgets.openGroup(context, .src(@src()), ref.get("tts_speak_character_name"));
    try bind.toggle(context, ref, "tts_use_display_name", "Speak Display Name Instead of Character Name");
    try display_name.close(context);
    try bind.slider(context, ref, "tts_volume", "Volume", .{ .display = .percent });
    try bind.slider(context, ref, "tts_rate", "Speed", .{});
    try widgets.hintText(context, .src(@src()), "0 is normal speaking speed; negative is slower, positive is faster.");
    try options.close(context);
    try section.close(context);
}

fn travel(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Travel Mode", "Detects when a tracked character falls behind while the rest of the group jumps together, and fires a notification. Runs automatically once enabled below - no manual start/stop needed. Border color, duration, and TTS for the alert are configured on the Event Alerts tab under \"Left Behind\".", &style.section);
    const ref = session.profile().child("travel");
    // Its only output is a notification.
    const notifications = try widgets.openGroup(context, .src(@src()), session.profile().ptr.thumbnail.notifications.enabled);
    try bind.toggle(context, ref, "enabled", "Enable Travel Mode");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.number(context, ref, "window_seconds", "Catch-Up Window", .{ .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How long a character can lag behind the group's jump before this fires.");
    try bind.choice(context, ref, "threshold_mode", "Group Size Threshold");
    try widgets.hintText(context, .src(@src()), "Minimum group size required before a straggler triggers an alert.");
    switch (ref.get("threshold_mode")) {
        .percent => try bind.number(context, ref, "threshold_percent", "Minimum Percentage", .{ .unit = "%" }),
        .count => try bind.number(context, ref, "threshold_count", "Minimum Count", .{}),
    }
    try options.close(context);
    try notifications.close(context);
    try section.close(context);
}
