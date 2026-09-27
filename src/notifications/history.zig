const win32 = @import("../platform/win32.zig");
const notification = @import("notification.zig");

/// Mirrors config.zig's DisplayConfig.NOTIF_PANEL_MAX_ROWS_MAX.
pub const CAPACITY = 30;

/// One past notification retained for the History Panel; fixed-size buffers avoid a heap allocation per notification.
pub const Entry = struct {
    source_hwnd: win32.HWND,
    notification_type: notification.NotificationType,
    character_name_buf: [64]u8 = undefined,
    character_name_len: u8 = 0,
    text_buf: [96]u8 = undefined,
    text_len: u8 = 0,
    timestamp_ms: win32.Ticks = .{},
    /// Resolved once at push time; a past entry's color is fixed once recorded, so history_panel.zig reads this instead of re-resolving from config every render tick.
    character_color: ?u32 = null,
    unmerged: bool = false,

    pub fn characterName(self: *const Entry) []const u8 {
        return self.character_name_buf[0..self.character_name_len];
    }

    pub fn text(self: *const Entry) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

/// Ring buffer of the last CAPACITY notifications shown, across all characters; newest overwrites oldest.
pub const NotificationHistory = struct {
    entries: [CAPACITY]Entry = undefined,
    head: usize = 0,
    count: usize = 0,
    /// Bumped on every change so the History Panel can cheaply detect one.
    revision: u32 = 0,

    pub fn push(self: *NotificationHistory, source_hwnd: win32.HWND, character_name: []const u8, notification_text: []const u8, notification_type: notification.NotificationType, character_color: ?u32) void {
        var entry: Entry = .{ .source_hwnd = source_hwnd, .notification_type = notification_type, .timestamp_ms = win32.Ticks.now(), .character_color = character_color };

        const name_n = @min(character_name.len, entry.character_name_buf.len);
        @memcpy(entry.character_name_buf[0..name_n], character_name[0..name_n]);
        entry.character_name_len = @intCast(name_n);

        const text_n = @min(notification_text.len, entry.text_buf.len);
        @memcpy(entry.text_buf[0..text_n], notification_text[0..text_n]);
        entry.text_len = @intCast(text_n);

        self.entries[self.head] = entry;
        self.head = (self.head + 1) % CAPACITY;
        if (self.count < CAPACITY) self.count += 1;
        self.revision +%= 1;
    }

    pub fn clear(self: *NotificationHistory) void {
        self.head = 0;
        self.count = 0;
        self.revision +%= 1;
    }

    /// Copies entries newest-first into `out`, capped to out.len.
    pub fn snapshot(self: *const NotificationHistory, out: []Entry) []Entry {
        const n = @min(self.count, out.len);
        for (out[0..n], 0..) |*slot, i| slot.* = self.entries[self.indexFromNewest(i)];
        return out[0..n];
    }

    /// `first`/`last` are newest-first indices, as returned by snapshot.
    pub fn unmergeRange(self: *NotificationHistory, first: usize, last: usize) void {
        var i = first;
        while (i <= last and i < self.count) : (i += 1) {
            self.entries[self.indexFromNewest(i)].unmerged = true;
        }
        self.revision +%= 1;
    }

    fn indexFromNewest(self: *const NotificationHistory, i: usize) usize {
        return (self.head + CAPACITY - 1 - i) % CAPACITY;
    }
};
