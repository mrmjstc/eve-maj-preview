//! Whether a notification shows on a thumbnail, whether History lists it, and whether any can be heard; no I/O.
const std = @import("std");
const notifications = @import("../config/notifications.zig");
const chat_alerts = @import("../config/chat_alerts.zig");
const notification = @import("notification.zig");

const ChatAlertConfig = chat_alerts.ChatAlertConfig;
const NotificationConfig = notifications.NotificationConfig;
const NotificationTypeConfig = notifications.NotificationTypeConfig;
const NotificationType = notification.NotificationType;

/// Why a notification is held back.
pub const Hold = enum { notifications_off, character_muted, type_off, focused, recently_clicked, throttled };

pub const AudioEffect = enum { speech, sound };

pub const Situation = struct {
    is_muted: bool,
    is_focused: bool,
    /// Since the thumbnail was last clicked; large when it never was.
    since_click_ms: u64,
    /// Shown too recently for the type's throttle.
    is_throttled: bool,
};

/// Null when it shows; checked in order, so the first rule that holds it back is the one reported.
pub fn holdReason(settings: *const NotificationConfig, type_config: NotificationTypeConfig, situation: Situation) ?Hold {
    if (!settings.enabled) return .notifications_off;
    if (situation.is_muted) return .character_muted;
    if (!type_config.enabled) return .type_off;
    if (type_config.suppress_when_focused and situation.is_focused) return .focused;
    if (type_config.suppress_when_clicked and situation.since_click_ms < settings.suppress_click_duration_ms) return .recently_clicked;
    if (situation.is_throttled) return .throttled;
    return null;
}

/// Only switching notifications, the character or its type off keeps it out of History.
pub fn isRecordedInHistory(hold: ?Hold) bool {
    const reason = hold orelse return true;
    return switch (reason) {
        .notifications_off, .character_muted, .type_off => false,
        .focused, .recently_clicked, .throttled => true,
    };
}

/// Whether an alert holdReason can let through plays `effect`; a character's mute doesn't count, as another may not be muted.
/// `is_intel_muted`: the Intel Panel's mute, which silences chat intel.
pub fn hasAudibleAlert(settings: *const NotificationConfig, chat_rules: []const ChatAlertConfig, is_intel_muted: bool, effect: AudioEffect) bool {
    if (!settings.enabled) return false;
    for (std.enums.values(NotificationType)) |notification_type| {
        if (notification_type == .ChatIntel and is_intel_muted) continue;
        const type_config = settings.getTypeConfig(notification_type);
        if (type_config.enabled and plays(&type_config, effect)) return true;
    }
    for (chat_rules) |*rule| {
        if (!rule.enabled or !rule.alert.enabled) continue;
        if (rule.kind == .intel and is_intel_muted) continue;
        if (plays(&rule.alert, effect)) return true;
    }
    return false;
}

fn plays(type_config: *const NotificationTypeConfig, effect: AudioEffect) bool {
    return switch (effect) {
        .speech => type_config.tts_enabled,
        .sound => type_config.sound_enabled and type_config.sound_path != null,
    };
}

const testing = std.testing;

/// Nothing about the thumbnail holds a notification back.
fn quiet() Situation {
    return .{ .is_muted = false, .is_focused = false, .since_click_ms = 1_000_000, .is_throttled = false };
}

/// quiet() with one fact changed.
fn with(comptime field: []const u8, value: anytype) Situation {
    var situation = quiet();
    @field(situation, field) = value;
    return situation;
}

test "a notification shows when nothing holds it back" {
    try testing.expectEqual(null, holdReason(&.{}, .{}, quiet()));
}

test "the notification switch, a muted character and a turned-off type each hold it back" {
    try testing.expectEqual(Hold.notifications_off, holdReason(&.{ .enabled = false }, .{}, quiet()).?);
    try testing.expectEqual(Hold.character_muted, holdReason(&.{}, .{}, with("is_muted", true)).?);
    try testing.expectEqual(Hold.type_off, holdReason(&.{}, .{ .enabled = false }, quiet()).?);
}

test "focus holds it back only for a type set to suppress while focused" {
    try testing.expectEqual(null, holdReason(&.{}, .{ .suppress_when_focused = false }, with("is_focused", true)));
    try testing.expectEqual(Hold.focused, holdReason(&.{}, .{ .suppress_when_focused = true }, with("is_focused", true)).?);
}

test "a click holds it back until the suppress-after-click time has passed" {
    const settings: NotificationConfig = .{ .suppress_click_duration_ms = 2000 };
    const type_config: NotificationTypeConfig = .{ .suppress_when_clicked = true };
    try testing.expectEqual(Hold.recently_clicked, holdReason(&settings, type_config, with("since_click_ms", 1999)).?);
    try testing.expectEqual(null, holdReason(&settings, type_config, with("since_click_ms", 2000)));
    try testing.expectEqual(null, holdReason(&settings, .{ .suppress_when_clicked = false }, with("since_click_ms", 0)));
}

test "a throttled type is held back" {
    try testing.expectEqual(Hold.throttled, holdReason(&.{}, .{}, with("is_throttled", true)).?);
}

test "with several rules applying, the first in order is reported" {
    const everything: Situation = .{ .is_muted = true, .is_focused = true, .since_click_ms = 0, .is_throttled = true };
    const suppressing: NotificationTypeConfig = .{ .suppress_when_focused = true, .suppress_when_clicked = true };
    try testing.expectEqual(Hold.notifications_off, holdReason(&.{ .enabled = false }, suppressing, everything).?);
    try testing.expectEqual(Hold.character_muted, holdReason(&.{}, suppressing, everything).?);
    try testing.expectEqual(Hold.focused, holdReason(&.{}, suppressing, with("is_focused", true)).?);
}

test "history records a notification held back only by focus, a click or its throttle" {
    try testing.expect(isRecordedInHistory(null));
    try testing.expect(isRecordedInHistory(.focused));
    try testing.expect(isRecordedInHistory(.recently_clicked));
    try testing.expect(isRecordedInHistory(.throttled));
}

test "history leaves out a notification that was switched off" {
    try testing.expect(!isRecordedInHistory(.notifications_off));
    try testing.expect(!isRecordedInHistory(.character_muted));
    try testing.expect(!isRecordedInHistory(.type_off));
}

test "speech and sound count only for alert types that can still fire" {
    var settings: NotificationConfig = .{};
    settings.type_configs.map.getPtr(.FleetInvite).* = .{ .tts_enabled = true, .enabled = false };
    settings.type_configs.map.getPtr(.Docking).* = .{ .sound_enabled = true };
    try testing.expect(!hasAudibleAlert(&settings, &.{}, false, .speech));
    try testing.expect(!hasAudibleAlert(&settings, &.{}, false, .sound));

    settings.type_configs.map.getPtr(.FleetInvite).enabled = true;
    try testing.expect(hasAudibleAlert(&settings, &.{}, false, .speech));
    settings.enabled = false;
    try testing.expect(!hasAudibleAlert(&settings, &.{}, false, .speech));
}

test "a turned-off chat rule is silent, and the Intel Panel's mute silences intel rules but not keyword ones" {
    const speaking: NotificationTypeConfig = .{ .tts_enabled = true };
    try testing.expect(!hasAudibleAlert(&.{}, &.{.{ .enabled = false, .alert = speaking }}, false, .speech));
    try testing.expect(!hasAudibleAlert(&.{}, &.{.{ .kind = .intel, .alert = speaking }}, true, .speech));
    try testing.expect(hasAudibleAlert(&.{}, &.{.{ .kind = .keyword, .alert = speaking }}, true, .speech));
}
