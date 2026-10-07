//! The speech and sound a notification plays alongside its popup.
const std = @import("std");
const config = @import("../config.zig");
const tts = @import("tts.zig");
const sound = @import("sound.zig");
const log = @import("../log.zig");

const slog = log.scoped("alert_effects");

/// Main thread only; session-only, never saved to the profile.
var g_muted = false;

pub fn isMuted() bool {
    return g_muted;
}

pub fn toggleMuted() void {
    g_muted = !g_muted;
    slog.info("Audio alerts {s}", .{if (g_muted) "muted" else "unmuted"});
}

/// Speaks the phrase the popup shows and plays its sound, unless muted; each has its own switch and volume.
pub fn play(notification_config: *const config.NotificationConfig, type_config: config.NotificationTypeConfig, text: []const u8, spoken_name: ?[]const u8) void {
    if (g_muted) return;
    playUnmuted(notification_config, type_config, text, spoken_name);
}

/// play, ignoring the mute, for the config dialog's Test Notification.
pub fn playUnmuted(notification_config: *const config.NotificationConfig, type_config: config.NotificationTypeConfig, text: []const u8, spoken_name: ?[]const u8) void {
    if (type_config.tts_enabled) {
        tts.setVoiceSettings(notification_config.tts_volume, notification_config.tts_rate);
        if (spoken_name) |name| {
            var speak_buf: [256]u8 = undefined;
            const spoken = std.mem.print(&speak_buf, "{s}, {s}", .{ name, text }) catch text;
            tts.speakAlert(spoken);
        } else {
            tts.speakAlert(text);
        }
    }

    if (type_config.sound_enabled) {
        if (type_config.sound_path) |path| {
            sound.playAlert(path, type_config.sound_volume);
        }
    }
}
