//! The recent notifications the History and Intel panels list.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const notification = @import("notification.zig");
const template = @import("template.zig");
const universe = @import("../map/universe.zig");
const config = @import("../config.zig");

/// Both panels list from this many; the History Panel's maxRows can't ask for more.
pub const CAPACITY = 30;

comptime {
    if (config.HistoryPanelConfig.MAX_ROWS[1] > CAPACITY) @compileError("historyPanel.maxRows reaches past the history's CAPACITY");
}

/// What an intel report's entry knows besides its text.
pub const IntelFacts = struct {
    /// From the nearest client.
    jumps: u8,
    /// The report calls its system clear.
    is_clear: bool,
};

/// One past notification a panel lists; fixed-size buffers avoid a heap allocation per notification.
pub const Entry = struct {
    source_hwnd: win32.HWND,
    notification_type: notification.NotificationType,
    character_name_buf: [64]u8 = undefined,
    character_name_length: u8 = 0,
    text_buf: [96]u8 = undefined,
    text_length: u8 = 0,
    timestamp: win32.Ticks = .{},
    /// Fixed at push time, so the panel doesn't re-resolve it every render.
    character_color: ?u32 = null,
    /// A chat rule's own text colour, which its type's settings don't hold.
    text_color: ?u32 = null,
    /// Within text().
    lead: ?notification.Lead = null,
    /// The system an Intel Panel row opens on the map.
    system: ?universe.SystemIndex = null,
    /// Intel only.
    intel: ?IntelFacts = null,

    pub fn characterName(self: *const Entry) []const u8 {
        return self.character_name_buf[0..self.character_name_length];
    }

    pub fn text(self: *const Entry) []const u8 {
        return self.text_buf[0..self.text_length];
    }
};

/// What push records.
pub const NewEntry = struct {
    source_hwnd: win32.HWND,
    /// Borrowed for the call; push copies it.
    character_name: []const u8,
    /// Borrowed for the call; push copies it.
    text: []const u8,
    notification_type: notification.NotificationType,
    timestamp: win32.Ticks,
    character_color: ?u32 = null,
    text_color: ?u32 = null,
    /// Within `text`.
    lead: ?notification.Lead = null,
    system: ?universe.SystemIndex = null,
    intel: ?IntelFacts = null,
};

/// Ring buffer of the last CAPACITY notifications shown, across all characters; newest overwrites oldest.
pub const NotificationHistory = struct {
    entries: [CAPACITY]Entry = undefined,
    head: usize = 0,
    entry_count: usize = 0,
    /// Bumped on every change so a panel can cheaply detect one.
    revision: u32 = 0,

    pub fn push(self: *NotificationHistory, new_entry: NewEntry) void {
        var entry: Entry = .{
            .source_hwnd = new_entry.source_hwnd,
            .notification_type = new_entry.notification_type,
            .timestamp = new_entry.timestamp,
            .character_color = new_entry.character_color,
            .text_color = new_entry.text_color,
            .system = new_entry.system,
            .intel = new_entry.intel,
        };

        const name_length = @min(new_entry.character_name.len, entry.character_name_buf.len);
        @memcpy(entry.character_name_buf[0..name_length], new_entry.character_name[0..name_length]);
        entry.character_name_length = @intCast(name_length);

        entry.text_length = @intCast(template.oneLine(new_entry.text, &entry.text_buf).len);
        if (new_entry.lead) |shown| entry.lead = .{ .length = @min(shown.length, entry.text_length), .color = shown.color };

        self.entries[self.head] = entry;
        self.head = (self.head + 1) % CAPACITY;
        if (self.entry_count < CAPACITY) self.entry_count += 1;
        self.revision +%= 1;
    }

    pub fn clear(self: *NotificationHistory) void {
        self.head = 0;
        self.entry_count = 0;
        self.revision +%= 1;
    }

    /// Copies entries newest-first into `out`, capped to out.len.
    pub fn snapshot(self: *const NotificationHistory, out: []Entry) []Entry {
        const copy_count = @min(self.entry_count, out.len);
        for (out[0..copy_count], 0..) |*slot, i| slot.* = self.entries[self.indexFromNewest(i)];
        return out[0..copy_count];
    }

    /// `index` is a newest-first index, as returned by snapshot; null past the last entry.
    pub fn entryFromNewest(self: *const NotificationHistory, index: usize) ?*const Entry {
        return if (index < self.entry_count) &self.entries[self.indexFromNewest(index)] else null;
    }

    fn indexFromNewest(self: *const NotificationHistory, newest_index: usize) usize {
        return (self.head + CAPACITY - 1 - newest_index) % CAPACITY;
    }
};

const testing = std.testing;

fn pushText(history: *NotificationHistory, text: []const u8, timestamp_ms: u64) void {
    history.push(.{
        .source_hwnd = @ptrFromInt(1),
        .character_name = "Alpha",
        .text = text,
        .notification_type = .FleetInvite,
        .timestamp = .{ .ms = timestamp_ms },
    });
}

test "snapshot lists entries newest first" {
    var history: NotificationHistory = .{};
    pushText(&history, "first", 1);
    pushText(&history, "second", 2);
    pushText(&history, "third", 3);

    var out: [CAPACITY]Entry = undefined;
    const entries = history.snapshot(&out);
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("third", entries[0].text());
    try testing.expectEqualStrings("second", entries[1].text());
    try testing.expectEqualStrings("first", entries[2].text());
    try testing.expectEqual(@as(u64, 3), entries[0].timestamp.ms);
}

test "past CAPACITY each push overwrites the oldest entry" {
    var history: NotificationHistory = .{};
    var text_buf: [8]u8 = undefined;
    for (0..CAPACITY + 3) |i| pushText(&history, std.mem.print(&text_buf, "{d}", .{i}) catch unreachable, i);

    var out: [CAPACITY]Entry = undefined;
    const entries = history.snapshot(&out);
    try testing.expectEqual(@as(usize, CAPACITY), entries.len);
    try testing.expectEqualStrings(std.mem.print(&text_buf, "{d}", .{CAPACITY + 2}) catch unreachable, entries[0].text());
    try testing.expectEqualStrings("3", entries[CAPACITY - 1].text());
}

test "snapshot copies no more than its buffer holds, newest first" {
    var history: NotificationHistory = .{};
    pushText(&history, "old", 1);
    pushText(&history, "new", 2);

    var out: [1]Entry = undefined;
    const entries = history.snapshot(&out);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("new", entries[0].text());
}

test "entryFromNewest counts from the newest and is null past the last entry" {
    var history: NotificationHistory = .{};
    pushText(&history, "old", 1);
    pushText(&history, "new", 2);

    try testing.expectEqualStrings("new", history.entryFromNewest(0).?.text());
    try testing.expectEqualStrings("old", history.entryFromNewest(1).?.text());
    try testing.expect(history.entryFromNewest(2) == null);
}

test "clear empties the history and bumps its revision" {
    var history: NotificationHistory = .{};
    pushText(&history, "gone", 1);
    const revision = history.revision;
    history.clear();

    var out: [CAPACITY]Entry = undefined;
    try testing.expectEqual(@as(usize, 0), history.snapshot(&out).len);
    try testing.expect(history.revision != revision);
}

test "push cuts a long name and text to fit, flattens line breaks, and keeps the lead within the text" {
    var history: NotificationHistory = .{};
    const long_name: [70]u8 = @splat('N');
    const long_text = "line one\nline two " ++ @as([100]u8, @splat('x'));
    history.push(.{
        .source_hwnd = @ptrFromInt(1),
        .character_name = &long_name,
        .text = long_text,
        .notification_type = .FleetInvite,
        .timestamp = .{ .ms = 1 },
        .lead = .{ .length = 500, .color = 0xFF00FF00 },
    });

    const entry = history.entryFromNewest(0).?;
    try testing.expectEqualStrings(long_name[0..64], entry.characterName());
    try testing.expectEqual(@as(usize, 96), entry.text().len);
    try testing.expect(std.mem.startsWith(u8, entry.text(), "line one line two "));
    try testing.expectEqual(@as(usize, 96), entry.lead.?.length);
    try testing.expectEqual(@as(u32, 0xFF00FF00), entry.lead.?.color);
}
