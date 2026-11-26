//! Decides whether a notification shows on a client, and puts it there with its sound, speech, history entry and recently-notified cycle entry.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const auto_colors_mod = @import("../clients/auto_colors.zig");
const roster = @import("../clients/roster.zig");
const history_mod = @import("history.zig");
const notified_queue_mod = @import("notified_queue.zig");
const notification_mod = @import("notification.zig");
const stack = @import("stack.zig");
const rules = @import("rules.zig");
const alert_effects_mod = @import("alert_effects.zig");
const universe = @import("../map/universe.zig");
const nearest_mod = @import("../map/nearest.zig");
const log = @import("../log.zig");

const AlertEffects = alert_effects_mod.AlertEffects;
const AutoColorStore = auto_colors_mod.AutoColorStore;
const Client = roster.Client;
const slog = log.Scoped("notification");

const TEST_PERMANENT_FALLBACK_MS: u32 = 5000;

/// Where a notification is recorded beyond its client.
pub const Records = struct {
    /// Borrowed from App's NotificationCenter.
    history: *history_mod.NotificationHistory,
    /// Borrowed from App's NotificationCenter.
    notified_queue: *notified_queue_mod.NotifiedQueue,
    /// Borrowed from App's NotificationCenter.
    shown_alert_group: *?u64,
    /// Borrowed from App's NotificationCenter.
    recorded_alert_group: *?u64,
};

const NearestClient = struct {
    client: *const Client,
    jumps: u8,
};

/// Intel lists every report, so assigning there would evict the colours thumbnails show.
const SystemColoring = enum { assign, known_only };

/// What showing a notification reads and records beyond the client itself; borrowed for one call.
pub const Context = struct {
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    auto_colors: *AutoColorStore,
    records: Records,
    alert_effects: *const AlertEffects,
    active_source_hwnd: ?win32.HWND,
};

/// Shows `notification` on one client under its type's or chat rule's settings; History lists it unless it's switched off.
pub fn notify(context: Context, client: *Client, notification: notification_mod.Notification) void {
    const settings = &context.config.notifications;
    const type_config = alertConfig(context.config, notification);
    var text_buf: [notification_mod.TEXT_MAX]u8 = undefined;
    const text = notification_mod.text(notification, type_config.customText(), client.character_name, &text_buf);
    const lead = if (type_config.color_system_name) systemLead(context, notification, text, .assign) else null;
    const now = win32.Ticks.now();
    const hold = holdFor(context, client, notification.notification_type, type_config, now);

    if (rules.isRecordedInHistory(hold)) record(context, client, notification, text, type_config, lead, now);
    if (hold != null) return;
    show(context, client, text, notification.notification_type, type_config, lead, now) catch |err| {
        slog.err("Failed to show {s} notification for '{s}': {}", .{ @tagName(notification.notification_type), client.character_name, err });
        return;
    };
    if (isAlertRepeat(context.records.shown_alert_group.*, notification.alert_group)) return;
    context.records.shown_alert_group.* = notification.alert_group;
    if (notification.notification_type == .ChatIntel and context.config.intelPanel.muteSounds) return;

    const spoken_name: ?[]const u8 = if (settings.tts_speak_character_name and client.character_name.len > 0)
        (if (settings.tts_use_display_name) client.display_name else client.character_name)
    else
        null;
    context.alert_effects.play(settings, type_config, text, spoken_name, notification_mod.notificationCategory(notification.notification_type) == .Chat);
}

/// Lists intel in `intel_history`, shown or not, measured from the nearest client; dropped with no client running.
pub fn listIntel(context: Context, intel_history: *history_mod.NotificationHistory, clients: []const Client, system: universe.SystemIndex, message: []const u8, is_clear: bool) void {
    var distances: universe.Distances = undefined;
    // Any range, and any EVE client, muted or not: the panel lists every report.
    universe.measureDistances(system, universe.UNREACHED - 1, &distances);
    var positions: [nearest_mod.MAX_POSITIONS]?universe.SystemIndex = undefined;
    const client_count = @min(clients.len, positions.len);
    for (clients[0..client_count], positions[0..client_count]) |*candidate, *position| {
        position.* = if (candidate.is_eve_client) universe.findSystem(candidate.system_name) else null;
    }
    // With none in reach, the first EVE client stands in, at 0 jumps, which the text leaves out.
    const nearest: NearestClient = if (nearest_mod.nearest(&distances, positions[0..client_count])) |found|
        .{ .client = &clients[found.first_index], .jumps = found.jumps }
    else
        .{ .client = firstEveClient(clients) orelse return, .jumps = 0 };
    const client = nearest.client;

    var jumps_buf: [3]u8 = undefined;
    // A u8 is at most three digits.
    const jumps = std.mem.print(&jumps_buf, "{d}", .{nearest.jumps}) catch unreachable;
    const notification: notification_mod.Notification = .{
        .notification_type = .ChatIntel,
        .target = universe.systemName(system),
        .message = message,
        .jumps = jumps,
    };
    var text_buf: [notification_mod.TEXT_MAX]u8 = undefined;
    const text = notification_mod.defaultText(notification, &text_buf);
    intel_history.push(.{
        .source_hwnd = client.hwnd,
        .character_name = client.character_name,
        .text = text,
        .notification_type = .ChatIntel,
        .timestamp = win32.Ticks.now(),
        .character_color = client.character_color,
        .lead = systemLead(context, notification, text, .known_only),
        .system = system,
        .intel = .{ .jumps = nearest.jumps, .is_clear = is_clear },
    });
}

/// Shows `notification` on every EVE client for a global user action; kept out of history, with its sound played once.
pub fn notifyAll(context: Context, clients: []Client, notification: notification_mod.Notification) void {
    const settings = &context.config.notifications;
    const type_config = settings.getTypeConfig(notification.notification_type);
    var text_buf: [notification_mod.TEXT_MAX]u8 = undefined;
    const text = notification_mod.text(notification, type_config.customText(), null, &text_buf);

    const now = win32.Ticks.now();
    var has_shown_any = false;
    for (clients) |*client| {
        if (!client.is_eve_client) continue;
        if (holdFor(context, client, notification.notification_type, type_config, now) != null) continue;
        show(context, client, text, notification.notification_type, type_config, null, now) catch |err| {
            slog.err("Failed to show {s} notification for '{s}': {}", .{ @tagName(notification.notification_type), client.character_name, err });
            continue;
        };
        has_shown_any = true;
    }
    if (has_shown_any) context.alert_effects.play(settings, type_config, text, null, false);
}

/// Bypasses every suppression, shows hidden thumbnails and skips history and cycle tracking; alerts play once, not per client.
pub fn showTest(context: Context, clients: []Client, notification_type: notification_mod.NotificationType, type_config: config_mod.NotificationTypeConfig) !void {
    const example = notification_mod.sample(notification_type);
    var text_buf: [notification_mod.TEXT_MAX]u8 = undefined;
    var spoken_buf: [notification_mod.TEXT_MAX]u8 = undefined;
    var spoken: ?[]const u8 = null;
    const now = win32.Ticks.now();
    // A permanent (0) duration would never clear a test.
    const duration_ms = if (type_config.duration_ms == 0) TEST_PERMANENT_FALLBACK_MS else type_config.duration_ms;

    for (clients) |*client| {
        if (!client.is_eve_client) continue;
        const character_name: ?[]const u8 = if (client.character_name.len > 0) client.character_name else notification_mod.SAMPLE_CHARACTER;
        const text = notification_mod.text(example, type_config.customText(), character_name, &text_buf);
        if (spoken == null) {
            @memcpy(spoken_buf[0..text.len], text);
            spoken = spoken_buf[0..text.len];
        }
        var entry: stack.ActiveNotification = .fromConfig(try context.allocator.dupe(u8, text), notification_type, type_config, now, duration_ms);
        entry.reveals_thumbnail = true;
        if (type_config.color_system_name) entry.lead = systemLead(context, example, text, .assign);
        push(context.allocator, client, entry);
    }

    const speech = spoken orelse notification_mod.text(example, type_config.customText(), notification_mod.SAMPLE_CHARACTER, &spoken_buf);
    context.alert_effects.playUnmuted(&context.config.notifications, type_config, speech, null, false);
}

/// Null when the text doesn't start with a system.
fn systemLead(context: Context, notification: notification_mod.Notification, text: []const u8, coloring: SystemColoring) ?notification_mod.Lead {
    const length = notification_mod.systemLeadLength(notification, text) orelse return null;
    const system_name = text[0..length];
    const color = switch (coloring) {
        .assign => context.auto_colors.systemNameColor(context.config, system_name),
        .known_only => context.auto_colors.knownSystemNameColor(context.config, system_name),
    };
    return .{ .length = length, .color = color };
}

fn firstEveClient(clients: []const Client) ?*const Client {
    for (clients) |*client| {
        if (client.is_eve_client) return client;
    }
    return null;
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
    return config.notifications.getTypeConfig(notification.notification_type);
}

fn holdFor(context: Context, client: *const Client, notification_type: notification_mod.NotificationType, type_config: config_mod.NotificationTypeConfig, now: win32.Ticks) ?rules.Hold {
    return rules.holdReason(&context.config.notifications, type_config, .{
        .is_muted = context.config.isNotificationMuted(client.character_name),
        .is_focused = client.hwnd == context.active_source_hwnd,
        .since_click_ms = now.elapsedSince(client.last_click_time),
        .is_throttled = client.notifications.isThrottled(notification_type, type_config.throttle_ms, now),
    });
}

/// Once per alert group, so other clients' copies aren't listed again.
fn record(context: Context, client: *const Client, notification: notification_mod.Notification, text: []const u8, type_config: config_mod.NotificationTypeConfig, lead: ?notification_mod.Lead, now: win32.Ticks) void {
    // Intel belongs to the Intel Panel and the map, which list every report through listIntel.
    if (notification.notification_type == .ChatIntel) return;
    if (isAlertRepeat(context.records.recorded_alert_group.*, notification.alert_group)) return;
    context.records.recorded_alert_group.* = notification.alert_group;
    // Null uses the type's own colour; only a chat rule sets its own.
    const text_color = if (notification.chat_rule_index != null) type_config.text_color else null;
    context.records.history.push(.{
        .source_hwnd = client.hwnd,
        .character_name = client.character_name,
        .text = text,
        .notification_type = notification.notification_type,
        .timestamp = now,
        .character_color = client.character_color,
        .text_color = text_color,
        .lead = lead,
    });
}

fn show(context: Context, client: *Client, text: []const u8, notification_type: notification_mod.NotificationType, type_config: config_mod.NotificationTypeConfig, lead: ?notification_mod.Lead, now: win32.Ticks) !void {
    client.notifications.markShown(notification_type, now);

    var entry: stack.ActiveNotification = .fromConfig(try context.allocator.dupe(u8, text), notification_type, type_config, now, type_config.duration_ms);
    entry.lead = lead;
    push(context.allocator, client, entry);

    // Game events feed the "cycle to recently notified" queue; feedback on the user's own action must not.
    if (!notification_mod.isUserAction(notification_type)) context.records.notified_queue.track(context.allocator, client.character_name, now);

    slog.debug("Queued notification for {s}: [{s}] {s} (border_color_override: {?})", .{ client.character_name, @tagName(notification_type), text, type_config.border_color });
}

fn push(allocator: std.mem.Allocator, client: *Client, entry: stack.ActiveNotification) void {
    client.notifications.push(allocator, entry);
    client.revision +%= 1;
}
