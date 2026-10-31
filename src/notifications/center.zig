//! What outlives a notification on its thumbnail: the histories, the cycle-to-notified queue and the panels that list them.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const history_mod = @import("history.zig");
const notified_queue_mod = @import("notified_queue.zig");
const dispatch = @import("dispatch.zig");
const history_panel = @import("../panels/history_panel.zig");
const intel_panel = @import("../panels/intel_panel.zig");
const panel_look = @import("../panels/panel_look.zig");

/// App owns it, so a thumbnail set rebuild keeps it all; main thread only.
pub const NotificationCenter = struct {
    /// What the History Panel lists.
    history: history_mod.NotificationHistory = .{},
    /// Every intel report, for the Intel Panel to list.
    intel_history: history_mod.NotificationHistory = .{},
    /// Who the cycle-to-notified hotkey visits.
    notified_queue: notified_queue_mod.NotifiedQueue = .{},
    panel: history_panel.HistoryPanel = .{},
    intel_panel: intel_panel.IntelPanel = .{},
    /// The latest alert group to show, so its other copies stay silent.
    shown_alert_group: ?u64 = null,

    /// Creates the panels' windows if `store`'s profile shows them.
    pub fn start(self: *NotificationCenter, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) void {
        self.panel = history_panel.HistoryPanel.init(allocator, store, instance);
        self.intel_panel = intel_panel.IntelPanel.init(allocator, store, instance);
    }

    pub fn deinit(self: *NotificationCenter, allocator: std.mem.Allocator) void {
        self.panel.deinit();
        self.intel_panel.deinit();
        self.notified_queue.deinit(allocator);
    }

    /// For the thumbnail set to record what it shows; valid as long as the center.
    pub fn records(self: *NotificationCenter) dispatch.Records {
        return .{ .history = &self.history, .intel_history = &self.intel_history, .notified_queue = &self.notified_queue, .shown_alert_group = &self.shown_alert_group };
    }

    /// Matches the panels to the profile, after a change made in the config dialog or by a new profile.
    pub fn sync(self: *NotificationCenter, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) void {
        self.panel.sync(allocator, store, instance);
        self.intel_panel.sync(allocator, store, instance);
    }

    /// Per tick: redraws the panels from their histories, or hides them.
    pub fn update(self: *NotificationCenter, config: *const config_mod.Config, presence: panel_look.Presence) void {
        self.panel.update(&self.history, config, presence);
        self.intel_panel.update(&self.intel_history, config, presence);
    }

    pub fn clearHistories(self: *NotificationCenter) void {
        self.history.clear();
        self.intel_history.clear();
    }
};
