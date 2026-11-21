//! Shows notifications on the roster's clients, whether or not a thumbnail set is built.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const auto_colors_mod = @import("../clients/auto_colors.zig");
const roster_mod = @import("../clients/roster.zig");
const dispatch = @import("dispatch.zig");
const notification_mod = @import("notification.zig");
const universe = @import("../map/universe.zig");
const log = @import("../log.zig");

const AutoColorStore = auto_colors_mod.AutoColorStore;
const Roster = roster_mod.Roster;
const slog = log.Scoped("notification");

/// App.notifier makes one; a copy is only pointers into App, which outlives it. Main thread only.
pub const Notifier = struct {
    allocator: std.mem.Allocator,
    /// Borrowed from App's ProfileStore: the live profile.
    config: *const config_mod.Config,
    /// Borrowed from App.
    auto_colors: *AutoColorStore,
    records: dispatch.Records,
    /// Borrowed from App.
    roster: *Roster,

    /// Subject to that type's notification settings.
    pub fn notify(self: *const Notifier, hwnd: win32.HWND, notification: notification_mod.Notification) void {
        const client = self.roster.mutableByHwnd(hwnd) orelse {
            slog.debug("No client for window 0x{x} to notify", .{@intFromPtr(hwnd)});
            return;
        };
        dispatch.notify(self.context(), client, notification);
    }

    /// For a global user action: kept out of history, and its sound and speech play once.
    pub fn notifyAll(self: *const Notifier, notification: notification_mod.Notification) void {
        dispatch.notifyAll(self.context(), self.roster.clients.items, notification);
    }

    /// For the Intel Panel, which lists every report; `message` is copied.
    pub fn listIntel(self: *const Notifier, system: universe.SystemIndex, message: []const u8, is_clear: bool) void {
        dispatch.listIntel(self.context(), self.roster.clients.items, system, message, is_clear);
    }

    pub fn showTest(self: *const Notifier, notification_type: notification_mod.NotificationType, type_config: config_mod.NotificationTypeConfig) !void {
        try dispatch.showTest(self.context(), self.roster.clients.items, notification_type, type_config);
    }

    fn context(self: *const Notifier) dispatch.Context {
        return .{ .allocator = self.allocator, .config = self.config, .auto_colors = self.auto_colors, .records = self.records, .active_source_hwnd = self.roster.active_hwnd };
    }
};
