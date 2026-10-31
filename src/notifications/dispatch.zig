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
const universe = @import("../map/universe.zig");
const log = @import("../log.zig");

const ThumbnailWindow = window.ThumbnailWindow;
const slog = log.Scoped("notification");

const TEST_PERMANENT_FALLBACK_MS: u32 = 5000;

/// Where a shown notification is recorded beyond its thumbnail; all live in App's NotificationCenter.
pub const Records = struct {
    history: *history_mod.NotificationHistory,
    intel_history: *history_mod.NotificationHistory,
    notified_queue: *notified_queue_mod.NotifiedQueue,
    shown_alert_group: *?u64,
};

const NearestClient = struct {
    thumbnail: *const ThumbnailWindow,
    jumps: u8,
};

const HistoryRecord = struct {
    /// Null uses the type's own colour.
    text_color: ?u32 = null,
};

/// What showing a notification reads and records beyond the thumbnail itself; borrowed for one call.
pub const Context = struct {
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    auto_colors: *config_mod.AutoColorStore,
    records: Records,
    active_source_hwnd: ?win32.HWND,
};

/// Shows `notification` on one client's thumbnail, subject to its type's notification settings, or its chat rule's.
pub fn notify(context: Context, thumbnail: *ThumbnailWindow, notification: notification_mod.Notification) void {
    const settings = &context.config.thumbnail.notifications;
    const type_config = alertConfig(context.config, notification);
    var text_buf: [notification_mod.TEXT_MAX]u8 = undefined;
    const text = notification_mod.text(notification, type_config.customText(), thumbnail.character_name, &text_buf);
    const history_text_color = if (notification.chat_rule_index != null) type_config.text_color else null;
    const is_repeat = isAlertRepeat(context.records.shown_alert_group.*, notification.alert_group);
    const history_record: ?HistoryRecord = if (is_repeat) null else .{ .text_color = history_text_color };
    const lead = if (type_config.color_system_name) systemLead(context, notification, text) else null;
    const queued = queue(context, thumbnail, text, notification.notification_type, type_config, lead, history_record) catch |err| {
        slog.err("Failed to show {s} notification for '{s}': {}", .{ @tagName(notification.notification_type), thumbnail.character_name, err });
        return;
    };
    if (!queued or is_repeat) return;
    context.records.shown_alert_group.* = notification.alert_group;

    const spoken_name: ?[]const u8 = if (settings.tts_speak_character_name and thumbnail.character_name.len > 0)
        (if (settings.tts_use_display_name) thumbnail.cached_display_name else thumbnail.character_name)
    else
        null;
    alert_effects.play(settings, type_config, text, spoken_name, notification_mod.notificationCategory(notification.notification_type) == .Chat);
}

/// Lists an intel report in the Intel Panel, measured from the client nearest it; dropped with no client running.
pub fn listIntel(context: Context, thumbnails: []const ThumbnailWindow, system: universe.SystemIndex, message: []const u8) void {
    if (!context.config.display.routesIntelToPanel()) return;
    var distances: universe.Distances = undefined;
    universe.measureDistances(system, universe.UNREACHED - 1, &distances);
    const nearest = nearestClient(thumbnails, &distances) orelse return;

    var jumps_buf: [3]u8 = undefined;
    // A u8 is at most three digits.
    const jumps = std.mem.print(&jumps_buf, "{d}", .{nearest.jumps}) catch unreachable;
    const notification: notification_mod.Notification = .{ .notification_type = .ChatIntel, .target = universe.systemName(system), .message = message, .jumps = jumps };
    var text_buf: [notification_mod.TEXT_MAX]u8 = undefined;
    const text = notification_mod.defaultText(notification, &text_buf);
    context.records.intel_history.push(nearest.thumbnail.source_hwnd, nearest.thumbnail.character_name, text, .ChatIntel, nearest.thumbnail.cached_character_color, null, systemLead(context, notification, text), system);
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
        const queued = queue(context, thumbnail, text, notification.notification_type, type_config, null, null) catch |err| {
            slog.err("Failed to show {s} notification for '{s}': {}", .{ @tagName(notification.notification_type), thumbnail.character_name, err });
            continue;
        };
        has_shown_any = has_shown_any or queued;
    }
    if (has_shown_any) alert_effects.play(settings, type_config, text, null, false);
}

/// Bypasses every suppression, shows hidden thumbnails and skips history and cycle tracking; alerts play once, not per thumbnail.
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
        if (type_config.color_system_name) entry.lead = systemLead(context, example, text);
        push(context.allocator, thumbnail, entry);
    }

    const speech = spoken orelse notification_mod.text(example, type_config.customText(), notification_mod.SAMPLE_CHARACTER, &spoken_buf);
    alert_effects.playUnmuted(&context.config.thumbnail.notifications, type_config, speech, null, false);
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

/// Null when the text doesn't start with a system.
fn systemLead(context: Context, notification: notification_mod.Notification, text: []const u8) ?notification_mod.Lead {
    const length = notification_mod.systemLeadLength(notification, text) orelse return null;
    return .{ .length = length, .color = context.auto_colors.systemNameColor(context.config, text[0..length]) };
}

/// A client whose system isn't known counts as `universe.UNREACHED` away, and reads as here: 0 jumps, which the text leaves out.
fn nearestClient(thumbnails: []const ThumbnailWindow, distances: *const universe.Distances) ?NearestClient {
    var nearest: ?*const ThumbnailWindow = null;
    var nearest_jumps: u8 = universe.UNREACHED;
    for (thumbnails) |*thumbnail| {
        if (!thumbnail.is_eve_client) continue;
        const jumps = if (universe.findSystem(thumbnail.system_name)) |system| distances[system] else universe.UNREACHED;
        if (nearest != null and jumps >= nearest_jumps) continue;
        nearest = thumbnail;
        nearest_jumps = jumps;
    }
    const thumbnail = nearest orelse return null;
    return .{ .thumbnail = thumbnail, .jumps = if (nearest_jumps == universe.UNREACHED) 0 else nearest_jumps };
}

fn isAlertRepeat(shown_group: ?u64, alert_group: ?u64) bool {
    const shown = shown_group orelse return false;
    const group = alert_group orelse return false;
    return shown == group;
}

/// A rule removed since the alert was raised falls back to the type's settings.
fn alertConfig(config: *const config_mod.Config, notification: notification_mod.Notification) config_mod.NotificationTypeConfig {
    const chat_rules = config.chatAlerts.items;
    if (notification.chat_rule_index) |index| {
        if (index < chat_rules.len) return chat_rules[index].alert;
    }
    return config.thumbnail.notifications.getTypeConfig(notification.notification_type);
}

/// Applies `type_config`'s enable/mute/suppress/throttle rules and queues the notification, kept out of history if `history_record` is null; false if it was filtered out.
fn queue(context: Context, thumbnail: *ThumbnailWindow, text: []const u8, notification_type: notification_mod.NotificationType, type_config: config_mod.NotificationTypeConfig, lead: ?notification_mod.Lead, history_record: ?HistoryRecord) !bool {
    const settings = &context.config.thumbnail.notifications;
    const now = win32.Ticks.now();
    if (rules.holdReason(settings, type_config, .{
        .is_muted = context.config.isNotificationMuted(thumbnail.character_name),
        .is_focused = thumbnail.isFocused(context.active_source_hwnd),
        .since_click_ms = now.elapsedSince(thumbnail.last_click_time),
        .is_throttled = thumbnail.notifications.isThrottled(notification_type, type_config.throttle_ms, now),
    }) != null) return false;
    thumbnail.notifications.markShown(notification_type, now);

    var entry: stack.ActiveNotification = .fromConfig(try context.allocator.dupe(u8, text), notification_type, type_config, now, type_config.duration_ms);
    entry.lead = lead;
    push(context.allocator, thumbnail, entry);

    // Game events feed the "cycle to recently notified" queue; feedback on the user's own action must not.
    if (!notification_mod.isUserAction(notification_type)) context.records.notified_queue.track(context.allocator, thumbnail.character_name);
    // The Intel Panel lists every report itself, through listIntel.
    const is_listed_as_intel = notification_type == .ChatIntel and context.config.display.routesIntelToPanel();
    if (history_record) |record| {
        if (!is_listed_as_intel) context.records.history.push(thumbnail.source_hwnd, thumbnail.character_name, text, notification_type, thumbnail.cached_character_color, record.text_color, lead, null);
    }

    slog.debug("Queued notification for {s}: [{s}] {s} (border_color_override: {?})", .{ thumbnail.character_name, @tagName(notification_type), text, type_config.border_color });
    return true;
}

fn push(allocator: std.mem.Allocator, thumbnail: *ThumbnailWindow, entry: stack.ActiveNotification) void {
    thumbnail.notifications.push(allocator, entry);
    thumbnail.needs_render = true;
}
