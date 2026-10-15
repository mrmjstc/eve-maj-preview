//! What outlives a notification on its thumbnail: the history, the cycle-to-notified queue and the History Panel that lists them.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const history_mod = @import("history.zig");
const notified_queue_mod = @import("notified_queue.zig");
const dispatch = @import("dispatch.zig");
const history_panel = @import("../panels/history_panel.zig");

/// App owns it, so a thumbnail set rebuild keeps all three; main thread only.
pub const NotificationCenter = struct {
    /// What the History Panel lists.
    history: history_mod.NotificationHistory = .{},
    /// Who the cycle-to-notified hotkey visits.
    notified_queue: notified_queue_mod.NotifiedQueue = .{},
    panel: history_panel.HistoryPanel = .{},

    /// Creates the panel's window if `store`'s profile shows it.
    pub fn start(self: *NotificationCenter, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) void {
        self.panel = history_panel.HistoryPanel.init(allocator, store, instance);
    }

    pub fn deinit(self: *NotificationCenter, allocator: std.mem.Allocator) void {
        self.panel.deinit();
        self.notified_queue.deinit(allocator);
    }

    /// For the thumbnail set to record what it shows; valid as long as the center.
    pub fn records(self: *NotificationCenter) dispatch.Records {
        return .{ .history = &self.history, .notified_queue = &self.notified_queue };
    }

    /// Per tick: redraws the panel from the history, or hides it.
    pub fn update(self: *NotificationCenter, config: *const config_mod.Config, any_character_logged_in: bool) void {
        self.panel.update(&self.history, config, any_character_logged_in);
    }
};
