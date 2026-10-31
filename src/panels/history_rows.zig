//! The rows of recent notifications the History and Intel panels list: which entries share one, and how they're drawn.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const display_mod = @import("../config/display.zig");
const notifications_mod = @import("../config/notifications.zig");
const notification = @import("../notifications/notification.zig");
const history = @import("../notifications/history.zig");
const history_look = @import("history_look.zig");
const list_look = @import("list_look.zig");
const panel_chrome = @import("panel_chrome.zig");
const panel_look = @import("panel_look.zig");

const DisplayConfig = display_mod.DisplayConfig;
const NotificationConfig = notifications_mod.NotificationConfig;

const INTEL_EMPTY_TEXT = "No intel yet";
/// Granularity of the timestamp text baked into the render signature, so it doesn't redraw every scan tick.
const TIMESTAMP_BUCKET_MS: u64 = 15_000;

/// `first`/`last` are newest-first history indices, equal unless merged.
pub const Row = struct {
    hwnd: win32.HWND,
    count: usize,
    first: usize,
    last: usize,
};

pub const BuildOptions = struct {
    /// Whose category filters apply; null lists every entry.
    filter: ?*const DisplayConfig = null,
    merges: bool,
    merge_window_ms: u64,
};

/// Where and how rows are drawn.
pub const Area = struct {
    left: i32 = 0,
    top: i32,
    row_height: i32,
    right: i32,
    shows_timestamp: bool,
    /// Off leaves only a merged row's count before the message.
    shows_names: bool = true,
    /// Off draws each entry's lead in the message's colour.
    shows_leads: bool = true,
};

/// The History Panel's merge settings, which the Intel Panel follows too; `filter` is BuildOptions.filter.
pub fn buildOptions(display: *const DisplayConfig, filter: ?*const DisplayConfig) BuildOptions {
    return .{ .filter = filter, .merges = display.notifInfoPanelMergeEnabled, .merge_window_ms = @as(u64, @intCast(@max(0, display.notifInfoPanelMergeWindowSec))) * std.time.ms_per_s };
}

pub fn intelRowHeight(display: *const DisplayConfig) i32 {
    return list_look.rowHeight(display.notifInfoPanelFontSize);
}

/// The Intel Panel's rows between `left` and `right`, from `top` down.
pub fn intelArea(display: *const DisplayConfig, left: i32, top: i32, right: i32) Area {
    return .{
        .left = left,
        .top = top,
        .row_height = intelRowHeight(display),
        .right = right - list_look.PADDING_X,
        .shows_timestamp = display.notifInfoPanelShowTimestamp,
        .shows_names = false,
        .shows_leads = display.intelPanelColorSystemNames,
    };
}

/// What the Intel Panel's rows depend on, for a render signature.
pub fn hashIntel(hasher: *std.hash.Wyhash, intel_history: *const history.NotificationHistory, entries: []const history.Entry, display: *const DisplayConfig, notifications: *const NotificationConfig) void {
    hasher.update(std.mem.asBytes(&intel_history.revision));
    hasher.update(std.mem.asBytes(&display.intelPanelColorSystemNames));
    hasher.update(std.mem.asBytes(&display.notifInfoPanelShowTimestamp));
    hasher.update(std.mem.asBytes(&display.notifInfoPanelMergeEnabled));
    hasher.update(std.mem.asBytes(&display.notifInfoPanelMergeWindowSec));
    hashEntries(hasher, entries, notifications, display.notifInfoPanelShowTimestamp);
}

/// Fills `rows` from `entries`, merging repeats, up to `capacity` rows; returns how many it filled.
pub fn build(rows: []Row, entries: []const history.Entry, capacity: usize, options: BuildOptions) usize {
    const row_limit = @min(capacity, rows.len);
    var shown_count: usize = 0;
    for (entries, 0..) |*entry, i| {
        if (options.filter) |display| {
            if (!history_look.showsCategory(display, notification.notificationCategory(entry.notification_type))) continue;
        }

        if (options.merges and shown_count > 0 and !entry.is_unmerged) {
            const row = &rows[shown_count - 1];
            const previous = &entries[row.last];
            if (!previous.is_unmerged and previous.notification_type == entry.notification_type and
                std.mem.eql(u8, previous.text(), entry.text()) and
                previous.timestamp.elapsedSince(entry.timestamp) <= options.merge_window_ms)
            {
                row.count += 1;
                row.last = i;
                continue;
            }
        }

        if (shown_count >= row_limit) break;
        rows[shown_count] = .{ .hwnd = entry.source_hwnd, .count = 1, .first = i, .last = i };
        shown_count += 1;
    }
    return shown_count;
}

/// What the rows' pixels depend on, for a panel's render signature.
pub fn hashEntries(hasher: *std.hash.Wyhash, entries: []const history.Entry, notifications: *const NotificationConfig, shows_timestamp: bool) void {
    const now = win32.Ticks.now();
    for (entries) |*entry| {
        hasher.update(entry.characterName());
        hasher.update(entry.text());
        hasher.update(std.mem.asBytes(&entry.is_unmerged));
        const name_color = entry.character_color orelse list_look.NAME;
        const message_color = messageColor(notifications, entry);
        hasher.update(std.mem.asBytes(&name_color));
        hasher.update(std.mem.asBytes(&message_color));
        if (entry.lead) |lead| hasher.update(std.mem.asBytes(&lead.color));
        if (shows_timestamp) {
            const bucket = now.elapsedSince(entry.timestamp) / TIMESTAMP_BUCKET_MS;
            hasher.update(std.mem.asBytes(&bucket));
        }
    }
}

pub fn draw(dc: win32.HDC, text: panel_chrome.Text, rows: []const Row, entries: []const history.Entry, notifications: *const NotificationConfig, area: Area) void {
    _ = win32.SelectObject(dc, text.name_font);
    const now = win32.Ticks.now();
    for (rows, 0..) |row, index| {
        const row_top = area.top + @as(i32, @intCast(index)) * area.row_height;
        drawRow(dc, text, entries, row, row_top, notifications, area, now);
    }
}

/// The Intel Panel's rows, or word that there are none yet.
pub fn drawIntel(dc: win32.HDC, text: panel_chrome.Text, rows: []const Row, entries: []const history.Entry, notifications: *const NotificationConfig, area: Area) void {
    if (rows.len == 0) {
        drawEmpty(dc, text, INTEL_EMPTY_TEXT, area);
    } else {
        draw(dc, text, rows, entries, notifications, area);
    }
}

/// In place of the rows, when there are none.
pub fn drawEmpty(dc: win32.HDC, text: panel_chrome.Text, message: []const u8, area: Area) void {
    _ = win32.SelectObject(dc, text.name_font);
    panel_chrome.drawLine(dc, message, area.left + list_look.PADDING_X, area.top + @divTrunc(area.row_height - text.name_height, 2), list_look.MUTED);
}

fn messageColor(notifications: *const NotificationConfig, entry: *const history.Entry) u32 {
    return entry.text_color orelse history_look.messageColor(notifications, entry.notification_type);
}

fn drawRow(dc: win32.HDC, text: panel_chrome.Text, entries: []const history.Entry, row: Row, row_top: i32, notifications: *const NotificationConfig, area: Area, now: win32.Ticks) void {
    const entry = &entries[row.first];
    const left = area.left + list_look.PADDING_X;
    const right = area.right;
    var message_right = right;
    if (area.shows_timestamp) {
        var time_buf: [panel_look.TIME_TEXT_MAX]u8 = undefined;
        const time_text = panel_look.relativeTime(&time_buf, now.elapsedSince(entry.timestamp));
        _ = win32.SelectObject(dc, text.small_font);
        const time_width = panel_chrome.textWidth(dc, time_text);
        panel_chrome.drawLine(dc, time_text, @max(left, right - time_width), row_top + @divTrunc(area.row_height - text.small_height, 2), list_look.MUTED);
        _ = win32.SelectObject(dc, text.name_font);
        message_right = right - time_width - history_look.TEXT_GAP;
    }

    const y = row_top + @divTrunc(area.row_height - text.name_height, 2);
    var message_x = left;
    const is_merged = row.count > 1;
    if (is_merged or area.shows_names) {
        var count_buf: [history_look.COUNT_TEXT_MAX]u8 = undefined;
        const name = if (is_merged) history_look.countText(&count_buf, row.count) else entry.characterName();
        const name_color = if (is_merged) list_look.MUTED else entry.character_color orelse list_look.NAME;
        const name_max = @divTrunc(@max(0, message_right - left) * history_look.NAME_MAX_PERCENT, 100);
        message_x += panel_chrome.drawFitted(dc, name, left, y, name_color, name_max) + history_look.TEXT_GAP;
        if (message_x >= message_right) return;
    }
    var message = entry.text();
    const shown_lead = if (area.shows_leads) entry.lead else null;
    if (shown_lead) |lead| {
        message_x += panel_chrome.drawFitted(dc, message[0..lead.length], message_x, y, lead.color, message_right - message_x);
        message = message[lead.length..];
        if (message_x >= message_right) return;
    }
    _ = panel_chrome.drawFitted(dc, message, message_x, y, messageColor(notifications, entry), message_right - message_x);
}
