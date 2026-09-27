const std = @import("std");
const config_mod = @import("../config.zig");
const tts = @import("tts.zig");
const sound = @import("sound.zig");

/// Speaks the same phrase the visual notification shows and plays its sound; both are self-contained, with no global master switch or shared volume.
pub fn play(notif_config: *const config_mod.NotificationConfig, type_config: config_mod.NotificationTypeConfig, text: []const u8, spoken_name: ?[]const u8) void {
    if (type_config.tts_enabled) {
        tts.setVoiceSettings(notif_config.tts_volume, notif_config.tts_rate);
        if (spoken_name) |name| {
            var speak_buf: [256]u8 = undefined;
            const spoken = std.fmt.bufPrint(&speak_buf, "{s}, {s}", .{ name, text }) catch text;
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
