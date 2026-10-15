//! Decides whether a notification shows on a thumbnail, and puts it there with its sound, speech, history entry and recently-notified cycle entry.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const window = @import("../thumbnail/window.zig");
const history_mod = @import("history.zig");
const notified_queue_mod = @import("notified_queue.zig");
const notification_mod = @import("notification.zig");
const stack = @import("stack.zig");
const rules = @import("rules.zig");
const alert_effects = @import("alert_effects.zig");
const log = @import("../log.zig");

const ThumbnailWindow = window.ThumbnailWindow;
const slog = log.Scoped("notification");

const TEST_PERMANENT_FALLBACK_MS: u32 = 5000;

/// Where a shown notification is recorded beyond its thumbnail; both live in App's NotificationCenter.
pub const Records = struct {
    history: *history_mod.NotificationHistory,
    notified_queue: *notified_queue_mod.NotifiedQueue,
};

/// What showing a notification reads and records beyond the thumbnail itself; borrowed for one call.
pub const Context = struct {
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    records: Records,
    active_source_hwnd: ?win32.HWND,
};

/// Shows `notification` on one client's thumbnail, subject to that type's notification settings.
pub fn notify(context: Context, thumbnail: *ThumbnailWindow, notification: notification_mod.Notification) void {
    const settings = &context.config.thumbnail.notifications;
    const type_config = settings.getTypeConfig(notification.notification_type);
    var text_buf: [notification_mod.TEXT_MAX]u8 = undefined;
    const text = notification_mod.text(notification, type_config.customText(), thumbnail.character_name, &text_buf);
    const queued = queue(context, thumbnail, text, notification.notification_type, true) catch |err| {
        slog.err("Failed to show {s} notification for '{s}': {}", .{ @tagName(notification.notification_type), thumbnail.character_name, err });
        return;
    };
    if (!queued) return;

    const spoken_name: ?[]const u8 = if (settings.tts_speak_character_name and thumbnail.character_name.len > 0)
        (if (settings.tts_use_display_name) thumbnail.cached_display_name else thumbnail.character_name)
    else
        null;
    alert_effects.play(settings, type_config, text, spoken_name);
}

/// Shows `notification` on every EVE client's thumbnail for a global user action; kept out of history, and sound/speech play once rather than per thumbnail.
pub fn notifyAll(context: Context, thumbnails: []ThumbnailWindow, notification: notification_mod.Notification) void {
    const settings = &context.config.thumbnail.notifications;
    const type_config = settings.getTypeConfig(notification.notification_type);
    var text_buf: [notification_mod.TEXT_MAX]u8 = undefined;
    const text = notification_mod.text(notification, type_config.customText(), null, &text_buf);

    var has_shown_any = false;
    for (thumbnails) |*thumbnail| {
        if (!thumbnail.is_eve_client) continue;
        const queued = queue(context, thumbnail, text, notification.notification_type, false) catch |err| {
            slog.err("Failed to show {s} notification for '{s}': {}", .{ @tagName(notification.notification_type), thumbnail.character_name, err });
            continue;
        };
        has_shown_any = has_shown_any or queued;
    }
    if (has_shown_any) alert_effects.play(settings, type_config, text, null);
}

/// Config dialog's "Test Notification": shows `notification_type` with sample fields on every EVE client, bypasses every suppression, force-shows hidden thumbnails for its duration, and skips history/cycle tracking; alerts play once rather than per thumbnail.
pub fn showTest(context: Context, thumbnails: []ThumbnailWindow, notification_type: notification_mod.NotificationType, type_config: config_mod.NotificationTypeConfig) !void {
    const example = notification_mod.sample(notification_type);
    var text_buf: [notification_mod.TEXT_MAX]u8 = undefined;
    var spoken_buf: [notification_mod.TEXT_MAX]u8 = undefined;
    var spoken: ?[]const u8 = null;
    const now = win32.Ticks.now();
    // A permanent (0) duration would never clear a test.
    const duration_ms = if (type_config.duration_ms == 0) TEST_PERMANENT_FALLBACK_MS else type_config.duration_ms;

    for (thumbnails) |*thumbnail| {
        if (!thumbnail.is_eve_client) continue;
        const character_name: ?[]const u8 = if (thumbnail.character_name.len > 0) thumbnail.character_name else notification_mod.SAMPLE_CHARACTER;
        const text = notification_mod.text(example, type_config.customText(), character_name, &text_buf);
        if (spoken == null) {
            @memcpy(spoken_buf[0..text.len], text);
            spoken = spoken_buf[0..text.len];
        }
        var entry: stack.ActiveNotification = .fromConfig(try context.allocator.dupe(u8, text), notification_type, type_config, now, duration_ms);
        entry.reveals_thumbnail = true;
        push(context.allocator, thumbnail, entry);
    }

    const speech = spoken orelse notification_mod.text(example, type_config.customText(), notification_mod.SAMPLE_CHARACTER, &spoken_buf);
    alert_effects.playUnmuted(&context.config.thumbnail.notifications, type_config, speech, null);
}

/// Removes click-dismissable notifications (control/activation.zig's activate); returns whether anything was removed.
pub fn dismissClickSuppressed(allocator: std.mem.Allocator, thumbnail: *ThumbnailWindow) bool {
    const removed_any = thumbnail.notifications.dismissClickSuppressed(allocator);
    if (removed_any) thumbnail.needs_render = true;
    return removed_any;
}

/// Drops every notification at once, as on logout.
pub fn clearAll(allocator: std.mem.Allocator, thumbnail: *ThumbnailWindow) void {
    if (thumbnail.notifications.clear(allocator)) thumbnail.needs_render = true;
}

/// Drops the notifications read from the logs, as once log monitoring is off.
pub fn clearLogDriven(allocator: std.mem.Allocator, thumbnail: *ThumbnailWindow) void {
    if (thumbnail.notifications.dismissLogDriven(allocator)) thumbnail.needs_render = true;
}

/// Clears expired notifications; call every tick.
pub fn expire(allocator: std.mem.Allocator, thumbnails: []ThumbnailWindow) void {
    const now = win32.Ticks.now();
    for (thumbnails) |*thumbnail| {
        if (thumbnail.notifications.expire(allocator, now)) thumbnail.needs_render = true;

        // Rendered each tick so the newest entry's on/off flash phases actually paint.
        if (thumbnail.notifications.newest()) |newest| {
            if (newest.isFlashing(now)) thumbnail.needs_render = true;
        }
    }
}

/// Applies the type's enable/mute/suppress/throttle rules and queues the notification; false if it was filtered out.
fn queue(context: Context, thumbnail: *ThumbnailWindow, text: []const u8, notification_type: notification_mod.NotificationType, should_record_history: bool) !bool {
    const settings = &context.config.thumbnail.notifications;
    const type_config = settings.getTypeConfig(notification_type);
    const now = win32.Ticks.now();
    if (rules.holdReason(settings, type_config, .{
        .is_muted = context.config.isNotificationMuted(thumbnail.character_name),
        .is_focused = thumbnail.isFocused(context.active_source_hwnd),
        .since_click_ms = now.elapsedSince(thumbnail.last_click_time),
        .is_throttled = thumbnail.notifications.isThrottled(notification_type, type_config.throttle_ms, now),
    }) != null) return false;
    thumbnail.notifications.markShown(notification_type, now);

    push(context.allocator, thumbnail, .fromConfig(try context.allocator.dupe(u8, text), notification_type, type_config, now, type_config.duration_ms));

    // Game events feed the "cycle to recently notified" queue; feedback on the user's own action must not.
    if (!notification_mod.isUserAction(notification_type)) context.records.notified_queue.track(context.allocator, thumbnail.character_name);
    if (should_record_history) context.records.history.push(thumbnail.source_hwnd, thumbnail.character_name, text, notification_type, thumbnail.cached_character_color);

    slog.debug("Queued notification for {s}: [{s}] {s} (border_color_override: {?})", .{ thumbnail.character_name, @tagName(notification_type), text, type_config.border_color });
    return true;
}

fn push(allocator: std.mem.Allocator, thumbnail: *ThumbnailWindow, entry: stack.ActiveNotification) void {
    thumbnail.notifications.push(allocator, entry);
    thumbnail.needs_render = true;
}
