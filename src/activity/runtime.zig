//! The profile's live activity trackers, and the throttled push of their values into the thumbnail set.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const set = @import("../thumbnail/set.zig");
const window = @import("../thumbnail/window.zig");
const scout = @import("../clients/scout.zig");
const chatlog = @import("../chatlog.zig");
const tracker_mod = @import("tracker.zig");
const resources_mod = @import("resources.zig");
const schedule = @import("../util/schedule.zig");
const log = @import("../log.zig");

const ThumbnailSet = set.ThumbnailSet;
const ActivityStats = window.ActivityStats;
const Config = config_mod.Config;
const slog = log.Scoped("activity");

/// Independent of the overlay refresh, and also the cap when an alert's throttle is 0.
const ALERT_CHECK_INTERVAL_MS: u64 = 1000;

pub const Trackers = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    combat: ?*tracker_mod.CombatTracker = null,
    mining: ?*tracker_mod.MiningTracker = null,
    bounty: ?*tracker_mod.BountyTracker = null,
    resources: ?*resources_mod.ResourceTracker = null,
    last_dps_update: win32.Ticks = .{},
    last_mining_update: win32.Ticks = .{},
    last_bounty_update: win32.Ticks = .{},
    last_resource_update: win32.Ticks = .{},
    last_alert_check: win32.Ticks = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Trackers {
        return .{ .allocator = allocator, .io = io };
    }

    /// Matches the trackers to `config`, keeping enabled ones' history, and hands them to `monitor` (worker stopped); without one, the log-fed trackers are dropped, and one that can't be created is logged and left off.
    pub fn setup(self: *Trackers, config: *const Config, monitor: ?*chatlog.ChatlogMonitor) void {
        const has_monitor = monitor != null;
        self.reconcile(tracker_mod.CombatTracker, &self.combat, has_monitor and config.combat.enabled, config.combat.window_seconds, "Combat DPS");
        self.reconcile(tracker_mod.MiningTracker, &self.mining, has_monitor and config.mining.enabled, config.mining.window_seconds, "Mining rate");
        self.reconcile(tracker_mod.BountyTracker, &self.bounty, has_monitor and config.bounty.enabled, config.bounty.window_seconds, "Bounty rate");
        self.setupResources(config.resources.enabled);

        if (monitor) |active_monitor| {
            active_monitor.setTrackers(self.combat, self.mining, self.bounty);
            active_monitor.setDamageAlertExcludedWeapons(config.combat.damage_alert_excluded_weapons);
        }
    }

    /// Doesn't log, since it runs in shutdown defers that may race process exit.
    pub fn deinit(self: *Trackers) void {
        self.destroy(tracker_mod.CombatTracker, &self.combat, null);
        self.destroy(tracker_mod.MiningTracker, &self.mining, null);
        self.destroy(tracker_mod.BountyTracker, &self.bounty, null);
        self.destroy(resources_mod.ResourceTracker, &self.resources, null);
    }

    fn reconcile(self: *Trackers, comptime T: type, slot: *?*T, is_enabled: bool, window_seconds: u32, label: []const u8) void {
        if (!is_enabled) {
            self.destroy(T, slot, label);
            slog.debug("{s} tracking disabled", .{label});
            return;
        }
        if (slot.*) |tracker| {
            tracker.setWindowSeconds(window_seconds);
            slog.debug("{s} tracking kept ({d}s window)", .{ label, window_seconds });
            return;
        }
        const tracker = self.allocator.create(T) catch |err| {
            slog.err("Failed to create {s} tracker: {}", .{ label, err });
            return;
        };
        tracker.* = T.init(self.allocator, self.io, window_seconds);
        slot.* = tracker;
        slog.debug("{s} tracking enabled ({d}s window)", .{ label, window_seconds });
    }

    fn setupResources(self: *Trackers, is_enabled: bool) void {
        if (!is_enabled) {
            self.destroy(resources_mod.ResourceTracker, &self.resources, null);
            return;
        }
        if (self.resources != null) return;
        const tracker = self.allocator.create(resources_mod.ResourceTracker) catch |err| {
            slog.err("Failed to create resource tracker: {}", .{err});
            return;
        };
        tracker.* = resources_mod.ResourceTracker.init(self.allocator);
        self.resources = tracker;
        slog.debug("Resource usage tracking enabled", .{});
    }

    fn destroy(self: *Trackers, comptime T: type, slot: *?*T, label: ?[]const u8) void {
        const tracker = slot.* orelse return;
        slot.* = null;
        tracker.deinit();
        self.allocator.destroy(tracker);
        if (label) |name| slog.debug("Cleaned up {s} tracker", .{name});
    }

    /// Pushes enabled trackers' values to `thumbnail_set` at their intervals, checks alerts, then redraws once; `now` is the tick's start, so the schedule holds however long the work takes.
    pub fn tick(self: *Trackers, config: *const Config, windows: []const scout.EveWindow, now: win32.Ticks, tick_interval_ms: u64, thumbnail_set: ?*ThumbnailSet) void {
        if (self.combat) |t| pushThrottled(tracker_mod.CombatTracker, pushDps, t, thumbnail_set, config, windows, now, tick_interval_ms, &self.last_dps_update, config.combat.update_interval_ms);
        if (self.mining) |t| pushThrottled(tracker_mod.MiningTracker, pushMining, t, thumbnail_set, config, windows, now, tick_interval_ms, &self.last_mining_update, config.mining.update_interval_ms);
        if (self.bounty) |t| pushThrottled(tracker_mod.BountyTracker, pushBounty, t, thumbnail_set, config, windows, now, tick_interval_ms, &self.last_bounty_update, config.bounty.update_interval_ms);

        if (schedule.isDue(now.elapsedSince(self.last_alert_check), ALERT_CHECK_INTERVAL_MS, tick_interval_ms)) {
            self.last_alert_check = now;
            if (thumbnail_set) |active_set| self.checkAlerts(active_set, config, windows, now);
        }

        self.setupResources(config.resources.enabled);
        if (self.resources) |tracker| {
            if (schedule.isDue(now.elapsedSince(self.last_resource_update), config.resources.update_interval_ms, tick_interval_ms)) {
                self.last_resource_update = now;
                pushResources(tracker, thumbnail_set, windows, now);
            }
        }

        if (thumbnail_set) |active_set| active_set.renderDirtyThumbnails(null);
    }

    fn checkAlerts(self: *const Trackers, thumbnail_set: *ThumbnailSet, config: *const Config, windows: []const scout.EveWindow, now: win32.Ticks) void {
        const idle_window_ms: u64 = @as(u64, config.mining.idle_alert_window_seconds) * std.time.ms_per_s;
        const stopped_window_ms: u64 = @as(u64, config.mining.stopped_alert_window_seconds) * std.time.ms_per_s;
        for (windows) |eve_window| {
            if (self.combat) |combat| {
                if (combat.query(eve_window.character_name, tracker_mod.CombatWindow.checkDamageAlert, .{}, false)) thumbnail_set.notify(eve_window.hwnd, .{ .notification_type = .TakingDamage });
            }
            if (self.mining) |mining| {
                if (mining.query(eve_window.character_name, tracker_mod.MiningWindow.checkIdleAlert, .{ now, idle_window_ms, config.mining.idle_alert_threshold }, false)) {
                    thumbnail_set.notify(eve_window.hwnd, .{ .notification_type = .MiningIdle });
                }
                if (mining.query(eve_window.character_name, tracker_mod.MiningWindow.checkStoppedAlert, .{ now, stopped_window_ms }, false)) {
                    thumbnail_set.notify(eve_window.hwnd, .{ .notification_type = .MiningStopped });
                }
            }
        }
    }
};

fn pushThrottled(
    comptime T: type,
    comptime per_window: fn (*T, *ThumbnailSet, *const Config, scout.EveWindow, win32.Ticks) void,
    tracker: *T,
    thumbnail_set: ?*ThumbnailSet,
    config: *const Config,
    windows: []const scout.EveWindow,
    now: win32.Ticks,
    tick_interval_ms: u64,
    last_update: *win32.Ticks,
    interval_ms: u32,
) void {
    if (!schedule.isDue(now.elapsedSince(last_update.*), interval_ms, tick_interval_ms)) return;
    last_update.* = now;

    const active_set = thumbnail_set orelse return;
    for (windows) |eve_window| {
        per_window(tracker, active_set, config, eve_window, now);
    }
}

fn pushDps(tracker: *tracker_mod.CombatTracker, thumbnail_set: *ThumbnailSet, _: *const Config, eve_window: scout.EveWindow, now: win32.Ticks) void {
    const dps = tracker.query(eve_window.character_name, tracker_mod.CombatWindow.computeDps, .{now}, .{ .incoming = 0.0, .outgoing = 0.0 });
    thumbnail_set.updateStats(eve_window.hwnd, ActivityStats.setDps, .{ dps.incoming, dps.outgoing });
}

fn pushMining(tracker: *tracker_mod.MiningTracker, thumbnail_set: *ThumbnailSet, _: *const Config, eve_window: scout.EveWindow, now: win32.Ticks) void {
    const rates = tracker.query(eve_window.character_name, tracker_mod.MiningWindow.computeRates, .{now}, .{ .m3 = 0.0, .isk = 0.0 });
    thumbnail_set.updateStats(eve_window.hwnd, ActivityStats.setMining, .{ rates.m3, rates.isk });
}

fn pushBounty(tracker: *tracker_mod.BountyTracker, thumbnail_set: *ThumbnailSet, _: *const Config, eve_window: scout.EveWindow, now: win32.Ticks) void {
    const isk_rate = tracker.query(eve_window.character_name, tracker_mod.BountyWindow.computeIskRate, .{now}, 0.0);
    thumbnail_set.updateStats(eve_window.hwnd, ActivityStats.setBounty, .{isk_rate});
}

fn pushResources(tracker: *resources_mod.ResourceTracker, thumbnail_set: ?*ThumbnailSet, windows: []const scout.EveWindow, now: win32.Ticks) void {
    tracker.sampleAll(windows, now);

    const active_set = thumbnail_set orelse return;
    for (windows) |eve_window| {
        const stats = tracker.getStats(eve_window.process_id);
        active_set.updateStats(eve_window.hwnd, ActivityStats.setResources, .{ stats.cpu_percent, stats.ram_mb, stats.vram_mb, stats.has_vram });
    }
}
