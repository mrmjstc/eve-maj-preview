//! The configuration window's Notifications tab: the notification system, speech and travel mode; main thread only.
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const NotificationRef = session.Ref(config.NotificationConfig);

/// TTS Speed's steps as SAPI rates, -10 to 10, where every 10 steps speaks three times as fast.
const SPEEDS = [_]Speed{
    .{ .label = "Slow", .rate = -2 },
    .{ .label = "Normal", .rate = 0 },
    .{ .label = "Fast", .rate = 2 },
};
const SPEED_LABELS = blk: {
    var labels: [SPEEDS.len][]const u8 = undefined;
    for (SPEEDS, &labels) |step, *label| label.* = step.label;
    break :blk labels;
};

const Speed = struct { label: []const u8, rate: i8 };

pub fn show(context: *ui.Frame) !void {
    const profile = session.profile();
    if (!profile.ptr.chatlog.enabled) {
        try widgets.noticeWithButton(context, .src(@src()), "Without Log Monitoring, only alerts for your own actions, like Profile Switch, are shown.", "Go to Log Files", .log_monitoring);
    }
    try system(context);
    try speech(context);
    try travel(context);
}

fn system(context: *ui.Frame) !void {
    const ref = session.profile().child("thumbnail").child("notifications");
    const section = try widgets.openSection(context, "Notification System", "Alerts for game events like fleet invites. Set each one up on the Events tab.", &style.section);
    try bind.toggle(context, ref, "enabled", "Enable Notification System");
    // Its placement and font are edited from its text on the Thumbnails tab's thumbnail preview.
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.number(context, ref, "suppress_click_duration_ms", "Quiet After Click", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "No alerts for a character this long after you click it.");
    try bind.number(context, ref, "notified_cycle_retention_seconds", "Keep in Notified Cycle For", .{ .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How long after an alert a character stays in Notified Characters cycling.");
    try options.close(context);
    try section.close(context);
}

fn speech(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Text-to-Speech", "Reads alerts aloud. Turn it on per event with Speak Aloud on the Events tab.", &style.section);
    const ref = session.profile().child("thumbnail").child("notifications");
    // Speech only means something while notifications fire, so the section dims with them.
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.toggle(context, ref, "tts_speak_character_name", "Prefix Spoken Alerts with the Character Name");
    try widgets.hintText(context, .src(@src()), "So you know which character an alert is about.");
    const display_name = try widgets.openNestedGroup(context, .src(@src()), ref.get("tts_speak_character_name"));
    try bind.toggle(context, ref, "tts_use_display_name", "Speak Display Name Instead of Character Name");
    try widgets.hintText(context, .src(@src()), "Uses the Display Name set on the Characters tab.");
    try display_name.close(context);
    try bind.slider(context, ref, "tts_volume", "Volume", .{ .display = .percent });
    try widgets.hintText(context, .src(@src()), "Only affects spoken alerts.");
    try speed(context, ref);
    try widgets.hintText(context, .src(@src()), "Slow is about 20% slower than Normal, and Fast about 25% faster.");
    try bind.number(context, ref, "tts_max_waiting", "Max Alerts Waiting to Speak", .{ .unit = "alerts", .singular_unit = "alert" });
    try widgets.hintText(context, .src(@src()), "Past this, the oldest waiting alert is skipped so new ones aren't delayed.");
    try options.close(context);
    try section.close(context);
}

/// Named steps rather than the raw rate; a rate saved between steps shows the nearest one until another is picked.
fn speed(context: *ui.Frame, ref: NotificationRef) !void {
    const row = try widgets.openBinding(context, .str("knots.notifications.tts_speed"), "Speed");
    const current: i8 = ref.get("tts_rate");
    var nearest: usize = 0;
    for (SPEEDS, 0..) |step, index| {
        if (@abs(@as(i16, step.rate) - current) < @abs(@as(i16, SPEEDS[nearest].rate) - current)) nearest = index;
    }
    if (try widgets.segmented(context, .str("knots.notifications.tts_speed.steps"), &SPEED_LABELS, nearest)) |picked| ref.set("tts_rate", SPEEDS[picked].rate);
    try row.close(context);
}

fn travel(context: *ui.Frame) !void {
    const ref = session.profile().child("travel");
    // Its only output is a notification.
    const are_notifications_enabled = session.profile().ptr.thumbnail.notifications.enabled;
    const section = try widgets.openSection(context, "Travel Mode", "Alerts when a character misses its group's jump (Left Behind on the Events tab).", &style.section);
    const notifications = try widgets.openGroup(context, .src(@src()), are_notifications_enabled);
    try bind.toggle(context, ref, "enabled", "Enable Travel Mode");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.number(context, ref, "window_seconds", "Catch-Up Window", .{ .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How long a character can fall behind before the alert.");
    try bind.segmented(context, ref, "threshold_mode", "Group Size Threshold", &.{ "Percentage", "Count" });
    try widgets.hintText(context, .src(@src()), "How big the group must be before anyone counts as left behind.");
    switch (ref.get("threshold_mode")) {
        .percent => {
            try bind.number(context, ref, "threshold_percent", "Minimum Percentage", .{ .unit = "%" });
            try widgets.hintText(context, .src(@src()), "How much of the group must jump together.");
        },
        .count => {
            try bind.number(context, ref, "threshold_count", "Minimum Count", .{ .unit = "characters", .singular_unit = "character" });
            try widgets.hintText(context, .src(@src()), "How many characters must jump together.");
        },
    }
    try options.close(context);
    try notifications.close(context);
    try section.close(context);
}
