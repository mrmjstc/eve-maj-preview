//! The rows of recent notifications the History and Intel panels list: which entries share one, and how they're drawn.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const panels = @import("../config/panels.zig");
const notifications_mod = @import("../config/notifications.zig");
const notification = @import("../notifications/notification.zig");
const history = @import("../notifications/history.zig");
const universe = @import("../map/universe.zig");
const glyphs = @import("glyphs.zig");
const history_look = @import("history_look.zig");
const list_look = @import("list_look.zig");
const palette = @import("palette.zig");
const panel_chrome = @import("panel_chrome.zig");
const panel_look = @import("panel_look.zig");
const box_mod = @import("../util/box.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");

const Box = box_mod.Box;
const Canvas = pixel_buffer.Canvas;
const HistoryPanelConfig = panels.HistoryPanelConfig;
const IntelPanelConfig = panels.IntelPanelConfig;
const NotificationConfig = notifications_mod.NotificationConfig;

pub const INTEL_EMPTY_TEXT = "No intel yet";
/// Granularity of the timestamp text baked into the render signature, so it doesn't redraw every scan tick.
const TIMESTAMP_BUCKET_MS: u64 = 15_000;
/// Fits every character a merged row can name, ", " apart.
const NAMES_TEXT_MAX = history.CAPACITY * 16;

/// `first_index` and `last_index` are newest-first history indices, equal unless merged.
pub const Row = struct {
    hwnd: win32.HWND,
    count: usize,
    first_index: usize,
    last_index: usize,
};

pub const BuildOptions = struct {
    /// Whose category filters apply; null lists every entry.
    filter: ?*const HistoryPanelConfig = null,
    merges: bool,
    merge_window_ms: u64,
};

/// Where a two-line row is drawn, from its top-left text corner to `right`.
pub const StackedArea = struct {
    left: i32,
    top: i32,
    right: i32,
    line_gap: i32,
    shows_timestamp: bool,
    /// Off draws the first line in the name colour rather than the lead's.
    shows_leads: bool,
};

/// A History Panel row's fonts, and the heights of the lines they draw.
pub const HistoryText = struct {
    /// Bold, for the name.
    name_font: win32.HFONT,
    message_font: win32.HFONT,
    small_font: win32.HFONT,
    name_height: i32,
    small_height: i32,
};

/// The characters a merged row stands for, each once, ", " apart; newest first.
pub const Names = struct {
    buffer: [NAMES_TEXT_MAX]u8 = undefined,
    length: usize = 0,
    count: usize = 0,
    /// Borrows from the entries; the one name while `count` is 1.
    only: []const u8 = "",

    pub fn text(self: *const Names) []const u8 {
        return self.buffer[0..self.length];
    }
};

/// Where an expanded row's names break onto lines.
pub const NameLines = struct {
    /// Byte ranges into Names.text(), start then end.
    spans: [history_look.MAX_NAME_LINES][2]usize = undefined,
    count: usize = 0,
};

/// Where a History row is drawn and the state it shows.
pub const HistoryPlace = struct {
    /// The whole row, across the panel.
    box: Box,
    /// The first line's, as tall as a folded row.
    line_height: i32,
    is_new: bool,
    is_hovered: bool,
    shows_timestamp: bool,
    /// A merged row's characters; null for one entry.
    names: ?*const Names = null,
    /// Set while expanded.
    name_lines: ?NameLines = null,
};

/// The History Panel's merge settings, which the Intel Panel follows too; `filter` is BuildOptions.filter.
pub fn buildOptions(history_settings: *const HistoryPanelConfig, filter: ?*const HistoryPanelConfig) BuildOptions {
    return .{ .filter = filter, .merges = history_settings.mergeEnabled, .merge_window_ms = @as(u64, @intCast(@max(0, history_settings.mergeWindowSec))) * std.time.ms_per_s };
}

/// What the Intel Panel's rows depend on, for a render signature.
pub fn hashIntel(hasher: *std.hash.Wyhash, intel_history: *const history.NotificationHistory, entries: []const history.Entry, history_settings: *const HistoryPanelConfig, intel_settings: *const IntelPanelConfig, notifications: *const NotificationConfig) void {
    hasher.update(std.mem.asBytes(&intel_history.revision));
    hasher.update(std.mem.asBytes(&intel_settings.colorSystemNames));
    hasher.update(std.mem.asBytes(&history_settings.showTimestamp));
    hasher.update(std.mem.asBytes(&history_settings.mergeEnabled));
    hasher.update(std.mem.asBytes(&history_settings.mergeWindowSec));
    hashEntries(hasher, entries, notifications, history_settings.showTimestamp);
}

/// Fills `rows` from `entries`, merging repeats, up to `capacity` rows; returns how many it filled.
pub fn build(rows: []Row, entries: []const history.Entry, capacity: usize, options: BuildOptions) usize {
    const row_limit = @min(capacity, rows.len);
    var shown_count: usize = 0;
    for (entries, 0..) |*entry, i| {
        if (options.filter) |filter| {
            if (!history_look.showsCategory(filter, notification.notificationCategory(entry.notification_type))) continue;
        }

        if (options.merges and shown_count > 0) {
            const row = &rows[shown_count - 1];
            const previous = &entries[row.last_index];
            if (previous.notification_type == entry.notification_type and
                std.mem.eql(u8, previous.text(), entry.text()) and
                previous.timestamp.elapsedSince(entry.timestamp) <= options.merge_window_ms)
            {
                row.count += 1;
                row.last_index = i;
                continue;
            }
        }

        if (shown_count >= row_limit) break;
        rows[shown_count] = .{ .hwnd = entry.source_hwnd, .count = 1, .first_index = i, .last_index = i };
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

/// The row's lead, else its system, over the rest of its message, with its distance, any merged count and its age on the first line.
pub fn drawStacked(dc: win32.HDC, text: panel_chrome.Text, entries: []const history.Entry, row: Row, notifications: *const NotificationConfig, area: StackedArea, now: win32.Ticks) void {
    const entry = &entries[row.first_index];
    var message = entry.text();
    var heading: []const u8 = message;
    var heading_color = list_look.NAME;
    var distance: []const u8 = "";
    if (entry.lead) |lead| {
        heading = message[0..lead.length];
        if (area.shows_leads) heading_color = lead.color;
        const after_system = history_look.splitAfterSystem(message[lead.length..]);
        distance = after_system.distance;
        message = after_system.message;
    } else if (entry.system) |system| {
        heading = universe.systemName(system);
    } else {
        message = "";
    }

    var heading_right = area.right;
    _ = win32.SelectObject(dc, text.small_font);
    const small_top = area.top + @divTrunc(text.name_height - text.small_height, 2);
    if (area.shows_timestamp) {
        var time_buf: [panel_look.TIME_TEXT_MAX]u8 = undefined;
        drawMutedBefore(dc, panel_look.relativeTime(&time_buf, now.elapsedSince(entry.timestamp)), area.left, &heading_right, small_top);
    }
    if (row.count > 1) {
        var count_buf: [history_look.COUNT_TEXT_MAX]u8 = undefined;
        drawMutedBefore(dc, history_look.mergedText(&count_buf, row.count), area.left, &heading_right, small_top);
    }

    _ = win32.SelectObject(dc, text.name_font);
    const heading_width = panel_chrome.drawFitted(dc, heading, area.left, area.top, heading_color, heading_right - area.left);
    if (distance.len > 0) {
        const distance_left = area.left + heading_width + history_look.TEXT_GAP;
        _ = win32.SelectObject(dc, text.small_font);
        _ = panel_chrome.drawFitted(dc, distance, distance_left, small_top, list_look.MUTED, heading_right - distance_left);
        _ = win32.SelectObject(dc, text.name_font);
    }
    if (message.len == 0) return;
    _ = panel_chrome.drawFitted(dc, message, area.left, area.top + text.name_height + area.line_gap, messageColor(notifications, entry), area.right - area.left);
}

/// The distinct characters of `row`'s entries; any that won't fit the buffer are left out.
pub fn mergedNames(entries: []const history.Entry, row: Row) Names {
    var names: Names = .{};
    const first = &entries[row.first_index];
    for (entries[row.first_index .. row.last_index + 1]) |*entry| {
        if (entry.notification_type != first.notification_type or !std.mem.eql(u8, entry.text(), first.text())) continue;
        const name = entry.characterName();
        if (containsName(names.text(), name)) continue;
        const separator = if (names.length == 0) "" else ", ";
        if (names.length + separator.len + name.len > names.buffer.len) break;
        @memcpy(names.buffer[names.length..][0..separator.len], separator);
        names.length += separator.len;
        @memcpy(names.buffer[names.length..][0..name.len], name);
        names.length += name.len;
        names.count += 1;
        if (names.count == 1) names.only = name;
    }
    return names;
}

/// Breaks after a name's comma where the line would pass `width`; the small font must be selected.
pub fn wrapNames(dc: win32.HDC, names: []const u8, width: i32) NameLines {
    var lines: NameLines = .{};
    var start: usize = 0;
    while (start < names.len and lines.count < history_look.MAX_NAME_LINES) {
        var end = names.len;
        const is_last_line = lines.count + 1 == history_look.MAX_NAME_LINES;
        if (!is_last_line and panel_chrome.wideTextWidth(dc, names[start..]) > width) {
            end = start;
            var search = start;
            while (std.mem.findPos(u8, names, search, ", ")) |separator| {
                if (panel_chrome.wideTextWidth(dc, names[start .. separator + 1]) > width) break;
                end = separator + 1;
                search = separator + 2;
            }
            // A name too long for a line by itself takes the line, cut short.
            if (end == start) end = if (std.mem.findPos(u8, names, start, ", ")) |separator| separator + 1 else names.len;
        }
        lines.spans[lines.count] = .{ start, end };
        lines.count += 1;
        start = end;
        while (start < names.len and names[start] == ' ') start += 1;
    }
    return lines;
}

/// A row `line_height` tall, plus `name_line_count` lines of names under it.
pub fn historyRowHeight(line_height: i32, small_height: i32, name_line_count: usize) i32 {
    if (name_line_count == 0) return line_height;
    return line_height + @as(i32, @intCast(name_line_count)) * (small_height + history_look.NAME_LINE_GAP) + history_look.NAMES_PADDING_BOTTOM;
}

/// Its category's glyph, who it's from, its message, a merged row's count and its age, then an expanded row's names.
pub fn drawHistoryRow(canvas: Canvas, dc: win32.HDC, text: HistoryText, entries: []const history.Entry, row: Row, notifications: *const NotificationConfig, place: HistoryPlace, now: win32.Ticks) void {
    const entry = &entries[row.first_index];
    const row_box = place.box;
    if (place.is_hovered) pixel_buffer.fillRect(canvas, @intCast(row_box.left), @intCast(row_box.top), @intCast(row_box.right - row_box.left), @intCast(row_box.bottom - row_box.top), list_look.ROW_HOVER);

    const category = notification.notificationCategory(entry.notification_type);
    const left = row_box.left + history_look.PADDING_X;
    const right = row_box.right - history_look.PADDING_X;
    const tile_top = row_box.top + @divTrunc(place.line_height - history_look.TILE_SIZE, 2);
    pixel_buffer.fillRoundedRect(canvas, @intCast(left), @intCast(tile_top), @intCast(history_look.TILE_SIZE), @intCast(history_look.TILE_SIZE), history_look.TILE_RADIUS, history_look.tileColor(category));
    const glyph_inset = @divTrunc(history_look.TILE_SIZE - history_look.TILE_GLYPH_SIZE, 2);
    glyphs.drawSized(canvas, history_look.categoryGlyph(category), history_look.TILE_GLYPH_SIZE, left + glyph_inset, tile_top + glyph_inset, history_look.categoryColor(category));

    const text_left = left + history_look.TILE_SIZE + history_look.TILE_GAP;
    const small_y = row_box.top + @divTrunc(place.line_height - text.small_height, 2);
    _ = win32.SelectObject(dc, text.small_font);
    var message_right = right;
    if (place.shows_timestamp) {
        var time_buf: [panel_look.TIME_TEXT_MAX]u8 = undefined;
        drawMutedBefore(dc, panel_look.relativeTime(&time_buf, now.elapsedSince(entry.timestamp)), text_left, &message_right, small_y);
    }
    var merged_buf: [history_look.COUNT_TEXT_MAX]u8 = undefined;
    const merged = if (row.count > 1) history_look.mergedText(&merged_buf, row.count) else "";
    const merged_width = if (merged.len > 0) panel_chrome.wideTextWidth(dc, merged) + 2 * history_look.MERGED_PADDING_X + history_look.TEXT_GAP else 0;

    const y = row_box.top + @divTrunc(place.line_height - text.name_height, 2);
    var who_buf: [history_look.COUNT_TEXT_MAX]u8 = undefined;
    const is_crowd = if (place.names) |names| names.count > 1 else false;
    const who = if (place.names) |names| (if (is_crowd) history_look.clientsText(&who_buf, names.count) else names.only) else entry.characterName();
    const plain_name_color = if (place.is_new) list_look.ACTIVE_NAME else list_look.NAME;
    const name_color = if (is_crowd) plain_name_color else entry.character_color orelse plain_name_color;
    const name_max = @divTrunc(@max(0, message_right - merged_width - text_left) * history_look.NAME_MAX_PERCENT, 100);
    _ = win32.SelectObject(dc, text.name_font);
    var x = text_left + panel_chrome.drawFitted(dc, who, text_left, y, name_color, name_max) + history_look.TEXT_GAP;

    _ = win32.SelectObject(dc, text.message_font);
    const message_end = message_right - merged_width;
    var message = entry.text();
    if (entry.lead) |lead| {
        x += panel_chrome.drawFitted(dc, message[0..lead.length], x, y, lead.color, message_end - x);
        message = message[lead.length..];
    }
    if (x < message_end) x += panel_chrome.drawFitted(dc, message, x, y, messageColor(notifications, entry), message_end - x);

    if (merged.len > 0) {
        _ = win32.SelectObject(dc, text.small_font);
        const pill_left = @min(x, message_end) + history_look.TEXT_GAP;
        const pill_width = merged_width - history_look.TEXT_GAP;
        pixel_buffer.fillRoundedRect(canvas, @intCast(pill_left), @intCast(small_y - 1), @intCast(pill_width), @intCast(text.small_height + 2), history_look.MERGED_RADIUS, palette.SURFACE);
        panel_chrome.drawWideLine(dc, merged, pill_left + history_look.MERGED_PADDING_X, small_y, palette.TEXT_SECONDARY);
    }

    const names = place.names orelse return;
    const name_lines = place.name_lines orelse return;
    _ = win32.SelectObject(dc, text.small_font);
    for (name_lines.spans[0..name_lines.count], 0..) |span, index| {
        const line_top = row_box.top + place.line_height + @as(i32, @intCast(index)) * (text.small_height + history_look.NAME_LINE_GAP);
        _ = panel_chrome.drawFitted(dc, names.text()[span[0]..span[1]], text_left, line_top, list_look.MUTED, right - text_left);
    }
}

/// "EARLIER" and a rule across, from `top`; `font` is the header's small font.
pub fn drawEarlier(canvas: Canvas, dc: win32.HDC, font: win32.HFONT, top: i32, panel_width: i32) void {
    _ = win32.SelectObject(dc, font);
    const text_height = panel_chrome.lineHeight(dc);
    const left = history_look.PADDING_X;
    const right = panel_width - history_look.PADDING_X;
    const text_width = panel_chrome.drawFitted(dc, history_look.EARLIER_TEXT, left, top + @divTrunc(history_look.EARLIER_HEIGHT - text_height, 2), list_look.MUTED, right - left);
    const rule_left = left + text_width + history_look.EARLIER_RULE_GAP;
    if (rule_left < right) pixel_buffer.fillRect(canvas, @intCast(rule_left), @intCast(top + @divTrunc(history_look.EARLIER_HEIGHT, 2)), @intCast(right - rule_left), 1, list_look.DIVIDER);
}

/// Flush against `right`, no further left than `left`, then moves `right` past it and a gap; UTF-8.
fn drawMutedBefore(dc: win32.HDC, text: []const u8, left: i32, right: *i32, top: i32) void {
    right.* -= panel_chrome.wideTextWidth(dc, text);
    panel_chrome.drawWideLine(dc, text, @max(left, right.*), top, list_look.MUTED);
    right.* -= history_look.TEXT_GAP;
}

/// Whole names only, in a ", " list.
fn containsName(names: []const u8, name: []const u8) bool {
    var parts = std.mem.splitSequence(u8, names, ", ");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}

fn messageColor(notifications: *const NotificationConfig, entry: *const history.Entry) u32 {
    return entry.text_color orelse history_look.messageColor(notifications, entry.notification_type);
}
