const std = @import("std");
const win32 = @import("../win32.zig");
const notification = @import("notification.zig");
const config_mod = @import("../config.zig");

/// Kept small since the overlay is drawn onto a small thumbnail bitmap.
pub const CAPACITY: usize = 3;

const FLASH_PHASE_MS: u64 = 150;
const FLASH_CYCLES: u64 = 4;
const FLASH_TOTAL_MS: u64 = FLASH_PHASE_MS * FLASH_CYCLES * 2;

pub const ActiveNotification = struct {
    text: []const u8,
    notification_type: notification.NotificationType,
    start_time: win32.Ticks,
    duration_ms: u32,
    suppress_when_focused: bool,
    suppress_when_clicked: bool,
    border_color_override: ?u32 = null,
    text_color_override: ?u32 = null,
    show_border: bool = true,
    flash_border: bool = false,

    /// `owned_text` must come from the allocator later passed to the stack, which frees it on removal.
    pub fn fromConfig(owned_text: []const u8, ntype: notification.NotificationType, type_config: config_mod.NotificationTypeConfig, now: win32.Ticks, duration_ms: u32) ActiveNotification {
        return .{
            .text = owned_text,
            .notification_type = ntype,
            .start_time = now,
            .duration_ms = duration_ms,
            .suppress_when_focused = type_config.suppress_when_focused,
            .suppress_when_clicked = type_config.suppress_when_clicked,
            .border_color_override = type_config.border_color,
            .text_color_override = type_config.text_color,
            .show_border = type_config.show_border,
            .flash_border = type_config.flash_border,
        };
    }

    pub fn isFlashing(self: ActiveNotification, now: win32.Ticks) bool {
        return self.show_border and self.flash_border and now.elapsedSince(self.start_time) < FLASH_TOTAL_MS;
    }

    /// Whether the border is in an off phase; false once flashing ends and the border settles steady-on.
    pub fn isFlashOff(self: ActiveNotification, now: win32.Ticks) bool {
        if (!self.isFlashing(now)) return false;
        return (now.elapsedSince(self.start_time) / FLASH_PHASE_MS) % 2 == 1;
    }
};

/// One thumbnail's on-screen notifications, newest first; owns each entry's text.
pub const NotificationStack = struct {
    entries: [CAPACITY]ActiveNotification = undefined,
    len: usize = 0,
    /// Suppressed attempts don't update this, so throttle_ms anchors to the last one actually displayed.
    last_shown_by_type: std.enums.EnumArray(notification.NotificationType, win32.Ticks) = .initFill(.{}),

    pub fn items(self: *const NotificationStack) []const ActiveNotification {
        return self.entries[0..self.len];
    }

    pub fn isEmpty(self: *const NotificationStack) bool {
        return self.len == 0;
    }

    /// Governs the thumbnail's Alert border; older entries only add text lines.
    pub fn newest(self: *const NotificationStack) ?ActiveNotification {
        return if (self.len > 0) self.entries[0] else null;
    }

    pub fn isThrottled(self: *const NotificationStack, ntype: notification.NotificationType, throttle_ms: u32, now: win32.Ticks) bool {
        if (throttle_ms == 0) return false;
        const last = self.last_shown_by_type.get(ntype);
        return !last.isZero() and now.elapsedSince(last) < throttle_ms;
    }

    pub fn markShown(self: *NotificationStack, ntype: notification.NotificationType, now: win32.Ticks) void {
        self.last_shown_by_type.set(ntype, now);
    }

    /// Inserts at the front, replacing any entry of the same type (bump-to-top) and evicting the oldest once full.
    pub fn push(self: *NotificationStack, allocator: std.mem.Allocator, entry: ActiveNotification) void {
        for (self.entries[0..self.len], 0..) |existing, i| {
            if (existing.notification_type == entry.notification_type) {
                self.removeAt(allocator, i);
                break;
            }
        }
        if (self.len == CAPACITY) self.removeAt(allocator, CAPACITY - 1);

        @memmove(self.entries[1 .. self.len + 1], self.entries[0..self.len]);
        self.entries[0] = entry;
        self.len += 1;
    }

    /// Returns whether anything was removed.
    pub fn dismissClickSuppressed(self: *NotificationStack, allocator: std.mem.Allocator) bool {
        const Ctx = struct {
            fn shouldRemove(_: @This(), entry: ActiveNotification) bool {
                return entry.suppress_when_clicked;
            }
        };
        return self.removeIf(allocator, Ctx{});
    }

    /// Returns whether anything expired; duration_ms == 0 means permanent.
    pub fn expire(self: *NotificationStack, allocator: std.mem.Allocator, now: win32.Ticks) bool {
        const Ctx = struct {
            now: win32.Ticks,
            fn shouldRemove(ctx: @This(), entry: ActiveNotification) bool {
                return entry.duration_ms > 0 and ctx.now.elapsedSince(entry.start_time) >= entry.duration_ms;
            }
        };
        return self.removeIf(allocator, Ctx{ .now = now });
    }

    /// Frees every entry's text without resetting the stack; for teardown, where the owning thumbnail is discarded.
    pub fn deinit(self: *const NotificationStack, allocator: std.mem.Allocator) void {
        for (self.items()) |entry| allocator.free(entry.text);
    }

    /// Returns whether anything was removed.
    pub fn clear(self: *NotificationStack, allocator: std.mem.Allocator) bool {
        self.deinit(allocator);
        const had_any = self.len > 0;
        self.len = 0;
        return had_any;
    }

    fn removeAt(self: *NotificationStack, allocator: std.mem.Allocator, index: usize) void {
        allocator.free(self.entries[index].text);
        @memmove(self.entries[index .. self.len - 1], self.entries[index + 1 .. self.len]);
        self.len -= 1;
    }

    fn removeIf(self: *NotificationStack, allocator: std.mem.Allocator, ctx: anytype) bool {
        var write: usize = 0;
        for (0..self.len) |read| {
            const entry = self.entries[read];
            if (ctx.shouldRemove(entry)) {
                allocator.free(entry.text);
                continue;
            }
            self.entries[write] = entry;
            write += 1;
        }
        const removed_any = write < self.len;
        self.len = write;
        return removed_any;
    }
};
