//! Decides whether a notification shows on a thumbnail, and puts it there with its sound, speech, history entry and recently-notified cycle entry.
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const state_mod = @import("../state.zig");
const painter_mod = @import("../painter.zig");
const window = @import("../thumbnail/window.zig");
const notification_mod = @import("notification.zig");
const notification_stack_mod = @import("stack.zig");
const alert_effects = @import("alert_effects.zig");
const log = @import("../log.zig");
const slog = log.scoped("painter");

const Painter = painter_mod.Painter;
const ThumbnailWindow = window.ThumbnailWindow;

const TEXT_MAX: usize = 128;
const TEST_PERMANENT_FALLBACK_MS: u32 = 5000;

/// Shows `n` on one client's thumbnail, subject to that type's notification settings.
pub fn notify(p: *Painter, source_hwnd: win32.HWND, n: notification_mod.Notification) void {
    const thumbnail = p.getThumbnailBySourceHwnd(source_hwnd) orelse {
        slog.debug("Window 0x{x} not found for notification update (thumbnail may not exist yet)", .{@intFromPtr(source_hwnd)});
        return;
    };
    var text_buf: [TEXT_MAX]u8 = undefined;
    const text = notification_mod.defaultText(n, &text_buf);
    const queued = queue(p, thumbnail, text, n.ntype, true) catch |err| {
        slog.err("Failed to show {s} notification for {s}: {}", .{ @tagName(n.ntype), thumbnail.character_name, err });
        return;
    };
    if (!queued) return;

    const settings = &p.config.thumbnail.notifications;
    const spoken_name: ?[]const u8 = if (settings.tts_speak_character_name and thumbnail.character_name.len > 0)
        (if (settings.tts_use_display_name) thumbnail.cached_display_name else thumbnail.character_name)
    else
        null;
    alert_effects.play(settings, settings.getTypeConfig(n.ntype), text, spoken_name);
}

/// Shows `n` on every thumbnail for a global user action; kept out of history, and sound/speech play once rather than per thumbnail.
pub fn notifyAll(p: *Painter, n: notification_mod.Notification) void {
    var text_buf: [TEXT_MAX]u8 = undefined;
    const text = notification_mod.defaultText(n, &text_buf);

    var shown = false;
    for (p.thumbnails.items) |*thumbnail| {
        const queued = queue(p, thumbnail, text, n.ntype, false) catch |err| {
            slog.err("Failed to show {s} notification for {s}: {}", .{ @tagName(n.ntype), thumbnail.character_name, err });
            continue;
        };
        shown = shown or queued;
    }
    const settings = &p.config.thumbnail.notifications;
    if (shown) alert_effects.play(settings, settings.getTypeConfig(n.ntype), text, null);
}

/// Applies the type's enable/mute/suppress/throttle rules and queues the notification; false if it was filtered out.
fn queue(p: *Painter, thumbnail: *ThumbnailWindow, text: []const u8, ntype: notification_mod.NotificationType, record_history: bool) !bool {
    const settings = &p.config.thumbnail.notifications;
    if (!settings.enabled) return false;
    if (p.config.isNotificationMuted(thumbnail.character_name)) return false;

    const type_config = settings.getTypeConfig(ntype);
    if (!type_config.enabled) return false;
    if (type_config.suppress_when_focused and thumbnail.isFocused(p.active_source_hwnd)) return false;

    const now = win32.Ticks.now();
    if (type_config.suppress_when_clicked and now.elapsedSince(thumbnail.last_click_time) < settings.suppress_click_duration_ms) return false;
    if (thumbnail.notifications.isThrottled(ntype, type_config.throttle_ms, now)) return false;
    thumbnail.notifications.markShown(ntype, now);

    push(p, thumbnail, .fromConfig(try p.allocator.dupe(u8, text), ntype, type_config, now, type_config.duration_ms));

    // Game events feed the "cycle to recently notified" queue; feedback on the user's own action must not.
    if (!notification_mod.isUserAction(ntype)) p.notified_queue.track(p.allocator, thumbnail.character_name);
    if (record_history) p.notification_history.push(thumbnail.source_hwnd, thumbnail.character_name, text, ntype, thumbnail.cached_character_color);

    slog.debug("Queued notification for {s}: [{s}] {s} (border_color_override: {?})", .{ thumbnail.character_name, @tagName(ntype), text, type_config.border_color });
    return true;
}

/// Config dialog's "Test Notification": shows `ntype` with sample fields, bypasses every suppression, force-shows hidden thumbnails for its duration, and skips history/cycle tracking; alerts play once rather than per thumbnail.
pub fn showTest(p: *Painter, ntype: notification_mod.NotificationType, type_config: config_mod.NotificationTypeConfig) !void {
    var text_buf: [TEXT_MAX]u8 = undefined;
    const text = notification_mod.defaultText(notification_mod.sample(ntype), &text_buf);
    const now = win32.Ticks.now();
    // A permanent (0) duration would never clear a test.
    const duration_ms = if (type_config.duration_ms == 0) TEST_PERMANENT_FALLBACK_MS else type_config.duration_ms;

    for (p.thumbnails.items) |*thumbnail| {
        push(p, thumbnail, .fromConfig(try p.allocator.dupe(u8, text), ntype, type_config, now, duration_ms));

        // The alert blocks re-hiding, so the thumbnail stays up until expire() restores it.
        if (!thumbnail.isVisible()) {
            if (thumbnail.test_restore_visibility == null) thumbnail.test_restore_visibility = thumbnail.visibility_state;
            thumbnail.setVisibility(.Visible);
            p.renderThumbnailLogged(thumbnail, "test notification show");
        }
    }

    alert_effects.play(&p.config.thumbnail.notifications, type_config, text, null);
}

/// Puts a thumbnail that a Test Notification force-showed back to its prior visibility.
fn restoreVisibilityAfterTest(p: *Painter, thumbnail: *ThumbnailWindow) void {
    const prior = thumbnail.test_restore_visibility orelse return;
    thumbnail.test_restore_visibility = null;

    // Focus or the setting may have changed during the test, in which case auto-hiding no longer applies.
    const restored: state_mod.VisibilityState = switch (prior) {
        .HiddenAutomatic => if (p.config.thumbnail.hideWhenNoEveFocus and !p.isEveWindowForeground()) .HiddenAutomatic else .Visible,
        else => prior,
    };
    thumbnail.setVisibility(restored);
    p.renderThumbnailLogged(thumbnail, "test notification restore");
}

fn push(p: *Painter, thumbnail: *ThumbnailWindow, entry: notification_stack_mod.ActiveNotification) void {
    thumbnail.notifications.push(p.allocator, entry);
    thumbnail.needs_render = true;
}

/// Removes click-dismissable notifications (clients/activation.zig's activate); returns whether anything was removed.
pub fn dismissClickSuppressed(p: *Painter, thumbnail: *ThumbnailWindow) bool {
    const removed_any = thumbnail.notifications.dismissClickSuppressed(p.allocator);
    if (removed_any) thumbnail.needs_render = true;
    return removed_any;
}

/// Drops every notification at once, as on logout.
pub fn clearAll(p: *Painter, thumbnail: *ThumbnailWindow) void {
    if (thumbnail.notifications.clear(p.allocator)) thumbnail.needs_render = true;
}

/// Clears expired notifications; call every tick.
pub fn expire(p: *Painter) void {
    const now = win32.Ticks.now();
    for (p.thumbnails.items) |*thumbnail| {
        if (thumbnail.notifications.expire(p.allocator, now)) thumbnail.needs_render = true;

        if (thumbnail.test_restore_visibility != null and thumbnail.notifications.isEmpty()) {
            restoreVisibilityAfterTest(p, thumbnail);
        }

        // Rendered each tick so the newest entry's on/off flash phases actually paint.
        if (thumbnail.notifications.newest()) |notif| {
            if (notif.isFlashing(now)) thumbnail.needs_render = true;
        }
    }
}
