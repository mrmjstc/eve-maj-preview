//! The speech and sound a notification plays alongside its popup.
const std = @import("std");
const config = @import("../config.zig");
const rules = @import("rules.zig");
const tts = @import("tts.zig");
const sound = @import("sound.zig");
const log = @import("../log.zig");

const slog = log.Scoped("alert_effects");

/// Main thread only; session-only, never saved to the profile.
var g_is_muted = false;

pub fn isMuted() bool {
    return g_is_muted;
}

pub fn toggleMuted() void {
    g_is_muted = !g_is_muted;
    slog.info("Audio alerts {s}", .{if (g_is_muted) "muted" else "unmuted"});
}

/// Stops the speech or sound thread once no alert in `profile` uses it, whether or not alerts are muted.
pub fn releaseUnused(profile: *const config.Config) void {
    const settings = &profile.notifications;
    const chat_rules = profile.chatAlerts.items;
    const is_intel_muted = profile.intelPanel.muteSounds;
    if (!rules.hasAudibleAlert(settings, chat_rules, is_intel_muted, .speech)) tts.stopIfIdle();
    if (!rules.hasAudibleAlert(settings, chat_rules, is_intel_muted, .sound)) sound.stopIfIdle();
}

/// Speaks the popup's phrase and plays its sound unless muted; `is_minor` ones are dropped first when they back up.
pub fn play(notification_config: *const config.NotificationConfig, type_config: config.NotificationTypeConfig, text: []const u8, spoken_name: ?[]const u8, is_minor: bool) void {
    if (g_is_muted) return;
    playUnmuted(notification_config, type_config, text, spoken_name, is_minor);
}

/// play, ignoring the mute, for the config dialog's Test Notification.
pub fn playUnmuted(notification_config: *const config.NotificationConfig, type_config: config.NotificationTypeConfig, text: []const u8, spoken_name: ?[]const u8, is_minor: bool) void {
    if (type_config.tts_enabled) {
        tts.setVoiceSettings(notification_config.tts_volume, notification_config.tts_rate);
        if (spoken_name) |name| {
            var speak_buf: [256]u8 = undefined;
            const spoken = std.mem.print(&speak_buf, "{s}, {s}", .{ name, text }) catch |err| blk: {
                slog.warn("Failed to fit '{s}' into the spoken alert, speaking it without: {}", .{ name, err });
                break :blk text;
            };
            tts.speakAlert(spoken, notification_config.tts_max_waiting, is_minor);
        } else {
            tts.speakAlert(text, notification_config.tts_max_waiting, is_minor);
        }
    }

    if (type_config.sound_enabled) {
        if (type_config.sound_path) |path| {
            sound.playAlert(path, type_config.sound_volume, is_minor);
        }
    }
}
