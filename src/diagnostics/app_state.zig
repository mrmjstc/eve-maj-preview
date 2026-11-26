//! Gathers the state file's snapshot from the app's parts, and owns the recorders it reads of renders and alert sounds.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config = @import("../config.zig");
const roster = @import("../clients/roster.zig");
const window = @import("../thumbnail/window.zig");
const overlay = @import("../thumbnail/overlay.zig");
const alert_effects = @import("../notifications/alert_effects.zig");
const history_mod = @import("../notifications/history.zig");
const panel_chrome = @import("../panels/panel_chrome.zig");
const selected_font = @import("../util/selected_font.zig");
const state_file = @import("state_file.zig");

const Snapshot = state_file.Snapshot;

/// Made only while the state file is on.
pub const Recorders = struct {
    overlays: overlay.DrawnRecorder,
    panel_texts: panel_chrome.TextRecorder,
    plays: alert_effects.PlayCounts = .{},

    /// Installs itself where the overlays and panels record into, and destroy uninstalls it; App points the alert effects at `plays`.
    pub fn create(allocator: std.mem.Allocator) !*Recorders {
        const recorders = try allocator.create(Recorders);
        recorders.* = .{ .overlays = .init(allocator), .panel_texts = .init(allocator) };
        overlay.setRecorder(&recorders.overlays);
        panel_chrome.setRecorder(&recorders.panel_texts);
        return recorders;
    }

    pub fn destroy(self: *Recorders, allocator: std.mem.Allocator) void {
        overlay.setRecorder(null);
        panel_chrome.setRecorder(null);
        self.overlays.deinit();
        self.panel_texts.deinit();
        allocator.destroy(self);
    }
};

pub const Sources = struct {
    /// Borrowed for one capture.
    profile_name: []const u8,
    active_hwnd: ?win32.HWND,
    are_hotkeys_suspended: bool,
    /// Borrowed for one capture.
    excluded_characters: []const []const u8,
    /// Borrowed for one capture.
    hotkey_groups: []const config.HotkeyGroupConfig,
    /// Borrowed for one capture.
    thumbnails: []const window.ThumbnailWindow,
    /// Borrowed for one capture.
    clients: []const roster.Client,
    /// Borrowed for one capture.
    history: *const history_mod.NotificationHistory,
    /// Borrowed for one capture.
    intel_history: *const history_mod.NotificationHistory,
    /// Null for a panel whose window is closed.
    panel_hwnds: std.enums.EnumArray(Snapshot.PanelKind, ?win32.HWND),
    are_alerts_muted: bool,
    /// Borrowed for one capture; null when they couldn't be made, so no overlay, panel text or play counts are reported.
    recorders: ?*const Recorders,
};

/// Borrows from `sources` and `arena`, so publish it before either changes.
pub fn capture(arena: std.mem.Allocator, sources: Sources) !Snapshot {
    const thumbnails = try arena.alloc(Snapshot.Thumbnail, sources.thumbnails.len);
    for (sources.thumbnails, thumbnails) |*thumbnail, *entry| entry.* = .{
        .character_name = thumbnail.character_name,
        .hwnd = @intFromPtr(thumbnail.hwnd),
        .source_hwnd = @intFromPtr(thumbnail.source_hwnd),
        .visibility = thumbnail.visibility_state,
        .is_hidden_by_character = thumbnail.cached_is_thumbnail_hidden,
        .group_badge = thumbnail.cached_group_badge_label,
        .overlay = if (sources.recorders) |recorders| try overlaySnapshot(arena, thumbnail, &recorders.overlays) else null,
    };

    const groups = try arena.alloc(Snapshot.Group, sources.hotkey_groups.len);
    for (sources.hotkey_groups, groups) |*group, *entry| entry.* = .{ .name = group.name, .members = group.characters.items };

    const clients = try arena.alloc(Snapshot.Client, sources.clients.len);
    for (sources.clients, clients) |*client, *entry| {
        const active = client.notifications.items();
        const alerts = try arena.alloc(Snapshot.Alert, active.len);
        for (active, alerts) |*alert, *alert_entry| alert_entry.* = .{
            .notification_type = alert.notification_type,
            .text = alert.text,
            .shows_text = alert.shows_text,
            .shows_border = alert.shows_border,
            .flashes_border = alert.flashes_border,
            .border_color = alert.border_color_override,
            .text_color = alert.text_color_override,
        };
        entry.* = .{
            .character_name = client.character_name,
            .hwnd = @intFromPtr(client.hwnd),
            .system_name = client.system_name,
            .alerts = alerts,
            .incoming_dps = client.stats.incoming_dps,
            .outgoing_dps = client.stats.outgoing_dps,
            .mining_rate = client.stats.mining_rate,
            .mining_isk_rate = client.stats.mining_isk_rate,
            .bounty_isk_rate = client.stats.bounty_isk_rate,
        };
    }

    const play_counts: alert_effects.PlayCounts = if (sources.recorders) |recorders| recorders.plays else .{};
    return .{
        .profile = sources.profile_name,
        .active_hwnd = if (sources.active_hwnd) |hwnd| @intFromPtr(hwnd) else null,
        .are_hotkeys_suspended = sources.are_hotkeys_suspended,
        .excluded_characters = sources.excluded_characters,
        .groups = groups,
        .thumbnails = thumbnails,
        .clients = clients,
        .are_alerts_muted = sources.are_alerts_muted,
        .sounds_played = play_counts.sounds,
        .speeches_started = play_counts.speeches,
        .history = try historyEntries(arena, sources.history),
        .intel_history = try historyEntries(arena, sources.intel_history),
        .panels = try panelSnapshots(arena, sources),
    };
}

fn panelSnapshots(arena: std.mem.Allocator, sources: Sources) ![]const Snapshot.Panel {
    const recorders = sources.recorders orelse return &.{};
    var panels: std.ArrayList(Snapshot.Panel) = .empty;
    for (std.enums.values(Snapshot.PanelKind)) |kind| {
        const hwnd = sources.panel_hwnds.get(kind) orelse continue;
        try panels.append(arena, try panelSnapshot(arena, kind, hwnd, &recorders.panel_texts));
    }
    return panels.items;
}

/// Borrows from the thumbnail's render cache and `drawn_recorder`; null before its first render.
fn overlaySnapshot(arena: std.mem.Allocator, thumbnail: *const window.ThumbnailWindow, drawn_recorder: *const overlay.DrawnRecorder) !?Snapshot.Overlay {
    const settings = thumbnail.render_cache.settings orelse return null;
    const drawn = drawn_recorder.find(@intFromPtr(thumbnail.text_hwnd)) orelse return null;
    const drawn_texts = drawn.drawnTexts();
    const texts = try arena.alloc(Snapshot.Text, drawn_texts.len);
    for (drawn_texts, texts) |*drawn_text, *entry| entry.* = .{
        .element = @tagName(drawn_text.element),
        .text = drawn_text.text(),
        .box = snapshotBox(drawn_text.box),
        .color = drawn_text.color,
        .bg_color = drawn_text.bg_color,
        .font = if (drawn_text.font) |*font| snapshotFont(font) else null,
    };
    return .{
        .width = settings.overlay_width,
        .height = settings.overlay_height,
        .text_alpha = settings.overlay_alpha,
        .shows_border = settings.show_border,
        .border_width = settings.border_width,
        .border_color = settings.border_color,
        .border_style = settings.border_style,
        .shows_exclusion = settings.show_exclusion_overlay,
        .exclusion_style = settings.exclusion_overlay_style,
        .exclusion_color = settings.exclusion_overlay_color,
        .texts = texts,
        .notifications = if (drawn.notifications) |box| snapshotBox(box) else null,
        .notifications_bg_color = drawn.notifications_bg_color,
        .notification_color = drawn.notification_color,
        .connection_map = if (drawn.connection_map) |box| snapshotBox(box) else null,
    };
}

fn snapshotBox(box: overlay.DrawnBox) Snapshot.Box {
    return .{ .left = box.left, .top = box.top, .width = box.width, .height = box.height };
}

/// Borrows the face from `font`.
fn snapshotFont(font: *const selected_font.SelectedFont) Snapshot.Font {
    return .{ .face = font.face(), .weight = font.weight, .is_italic = font.is_italic, .height_px = font.height_px };
}

/// Newest first, at most state_file.HISTORY_LIMIT; borrows from copies in `arena`.
fn historyEntries(arena: std.mem.Allocator, source: *const history_mod.NotificationHistory) ![]Snapshot.HistoryEntry {
    const copies = source.snapshot(try arena.alloc(history_mod.Entry, state_file.HISTORY_LIMIT));
    const entries = try arena.alloc(Snapshot.HistoryEntry, copies.len);
    for (copies, entries) |*recorded, *entry| {
        entry.* = .{ .notification_type = recorded.notification_type, .character_name = recorded.characterName(), .text = recorded.text() };
    }
    return entries;
}

/// Borrows from `text_recorder`; no texts before the panel's first recorded render.
fn panelSnapshot(arena: std.mem.Allocator, kind: Snapshot.PanelKind, panel_hwnd: win32.HWND, text_recorder: *const panel_chrome.TextRecorder) !Snapshot.Panel {
    const hwnd = @intFromPtr(panel_hwnd);
    const record = text_recorder.find(hwnd) orelse return .{ .kind = kind, .hwnd = hwnd, .texts = &.{} };
    const recorded = record.items();
    const texts = try arena.alloc(Snapshot.PanelText, recorded.len);
    for (recorded, texts) |*text, *entry| entry.* = .{ .text = text.text(), .left = text.left, .top = text.top, .color = text.color, .font = if (text.font) |*font| snapshotFont(font) else null };
    return .{ .kind = kind, .hwnd = hwnd, .texts = texts };
}
