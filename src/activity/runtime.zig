//! The profile's live activity trackers, and the throttled push of their values into the thumbnail set.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const set = @import("../thumbnail/set.zig");
const stats_mod = @import("stats.zig");
const roster_mod = @import("../clients/roster.zig");
const scout = @import("../clients/scout.zig");
const chatlog = @import("../chatlog.zig");
const notifier_mod = @import("../notifications/notifier.zig");
const tracker_mod = @import("tracker.zig");
const resources_mod = @import("resources.zig");
const ping_mod = @import("ping.zig");
const schedule = @import("../util/schedule.zig");
const log = @import("../log.zig");

const ThumbnailSet = set.ThumbnailSet;
const ActivityStats = stats_mod.ActivityStats;
const Roster = roster_mod.Roster;
const Config = config_mod.Config;
const Notifier = notifier_mod.Notifier;
const slog = log.Scoped("activity");

/// Independent of the overlay refresh, and also the cap when an alert's throttle is 0.
const ALERT_CHECK_INTERVAL_MS: u64 = 1000;

/// What each throttled push in one tick shares.
const TickContext = struct {
    roster: *Roster,
    windows: []const scout.EveWindow,
    /// The tick's start.
    now: win32.Ticks,
    tick_interval_ms: u64,
};

pub const Trackers = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Owned; the chatlog worker feeds it under its own lock.
    combat: ?*tracker_mod.CombatTracker = null,
    /// Owned; the chatlog worker feeds it under its own lock.
    mining: ?*tracker_mod.MiningTracker = null,
    /// Owned; the chatlog worker feeds it under its own lock.
    bounty: ?*tracker_mod.BountyTracker = null,
    /// Owned; main thread only.
    resources: ?*resources_mod.ResourceTracker = null,
    /// Owned; main thread only.
    ping: ?*ping_mod.PingTracker = null,
    last_dps_update: win32.Ticks = .{},
    last_mining_update: win32.Ticks = .{},
    last_bounty_update: win32.Ticks = .{},
    last_resource_update: win32.Ticks = .{},
    last_ping_update: win32.Ticks = .{},
    last_alert_check: win32.Ticks = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Trackers {
        return .{ .allocator = allocator, .io = io };
    }

    /// Keeps enabled trackers' history; without `monitor`, the log-fed trackers are dropped.
    pub fn setup(self: *Trackers, config: *const Config, monitor: ?*chatlog.ChatlogMonitor) void {
        // Checked before reconcile, which can free a tracker the worker still reads.
        if (monitor) |active_monitor| {
            if (!active_monitor.isWorkerStopped("trackers")) return;
        }
        const has_monitor = monitor != null;
        self.reconcile(tracker_mod.CombatTracker, &self.combat, has_monitor and config.tracksCombat(), config.combat.window_seconds, "Combat DPS");
        self.reconcile(tracker_mod.MiningTracker, &self.mining, has_monitor and config.tracksMining(), config.mining.window_seconds, "Mining rate");
        self.reconcile(tracker_mod.BountyTracker, &self.bounty, has_monitor and config.tracksBounty(), config.bounty.window_seconds, "Bounty rate");
        self.setupSampler(resources_mod.ResourceTracker, &self.resources, config.resources.enabled, "Resource usage");
        self.setupSampler(ping_mod.PingTracker, &self.ping, config.ping.enabled, "Ping");

        if (monitor) |active_monitor| active_monitor.setTrackers(self.combat, self.mining, self.bounty);
    }

    /// Doesn't log, since it runs in shutdown defers that may race process exit.
    pub fn deinit(self: *Trackers) void {
        self.destroy(tracker_mod.CombatTracker, &self.combat, null);
        self.destroy(tracker_mod.MiningTracker, &self.mining, null);
        self.destroy(tracker_mod.BountyTracker, &self.bounty, null);
        self.destroy(resources_mod.ResourceTracker, &self.resources, null);
        self.destroy(ping_mod.PingTracker, &self.ping, null);
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

    /// For the trackers that sample the OS rather than read the logs.
    fn setupSampler(self: *Trackers, comptime T: type, slot: *?*T, is_enabled: bool, label: []const u8) void {
        if (!is_enabled) {
            self.destroy(T, slot, null);
            return;
        }
        if (slot.* != null) return;
        const tracker = self.allocator.create(T) catch |err| {
            slog.err("Failed to create {s} tracker: {}", .{ label, err });
            return;
        };
        tracker.* = T.init(self.allocator);
        slot.* = tracker;
        slog.debug("{s} tracking enabled", .{label});
    }

    fn destroy(self: *Trackers, comptime T: type, slot: *?*T, label: ?[]const u8) void {
        const tracker = slot.* orelse return;
        slot.* = null;
        tracker.deinit();
        self.allocator.destroy(tracker);
        if (label) |name| slog.debug("Cleaned up {s} tracker", .{name});
    }

    /// `now` is the tick's start, so the schedule holds however long the work takes.
    pub fn tick(self: *Trackers, config: *const Config, windows: []const scout.EveWindow, now: win32.Ticks, tick_interval_ms: u64, thumbnail_set: ?*ThumbnailSet, notifier: *const Notifier) void {
        const context: TickContext = .{ .roster = notifier.roster, .windows = windows, .now = now, .tick_interval_ms = tick_interval_ms };
        if (self.combat) |t| pushThrottled(tracker_mod.CombatTracker, pushDps, t, context, &self.last_dps_update, config.combat.update_interval_ms);
        if (self.mining) |t| pushThrottled(tracker_mod.MiningTracker, pushMining, t, context, &self.last_mining_update, config.mining.update_interval_ms);
        if (self.bounty) |t| pushThrottled(tracker_mod.BountyTracker, pushBounty, t, context, &self.last_bounty_update, config.bounty.update_interval_ms);

        if (schedule.isDue(now.elapsedSince(self.last_alert_check), ALERT_CHECK_INTERVAL_MS, tick_interval_ms)) {
            self.last_alert_check = now;
            self.checkAlerts(notifier, config, windows, now);
        }

        self.setupSampler(resources_mod.ResourceTracker, &self.resources, config.resources.enabled, "Resource usage");
        if (self.resources) |tracker| {
            if (schedule.isDue(now.elapsedSince(self.last_resource_update), config.resources.update_interval_ms, tick_interval_ms)) {
                self.last_resource_update = now;
                pushResources(tracker, notifier.roster, windows, now);
            }
        }

        self.setupSampler(ping_mod.PingTracker, &self.ping, config.ping.enabled, "Ping");
        if (self.ping) |tracker| {
            var has_changed = tracker.poll();
            if (schedule.isDue(now.elapsedSince(self.last_ping_update), config.ping.update_interval_ms, tick_interval_ms)) {
                self.last_ping_update = now;
                tracker.sample(windows);
                has_changed = true;
            }
            if (has_changed) pushPing(tracker, notifier.roster, windows);
        }

        if (thumbnail_set) |active_set| active_set.renderDirtyThumbnails(null);
    }

    fn checkAlerts(self: *const Trackers, notifier: *const Notifier, config: *const Config, windows: []const scout.EveWindow, now: win32.Ticks) void {
        const idle_window_ms: u64 = @as(u64, config.mining.idle_alert_window_seconds) * std.time.ms_per_s;
        const stopped_window_ms: u64 = @as(u64, config.mining.stopped_alert_window_seconds) * std.time.ms_per_s;
        for (windows) |eve_window| {
            if (self.combat) |combat| {
                if (combat.query(eve_window.character_name, tracker_mod.CombatWindow.checkDamageAlert, .{}, false)) notifier.notify(eve_window.hwnd, .{ .notification_type = .TakingDamage });
            }
            if (self.mining) |mining| {
                if (mining.query(eve_window.character_name, tracker_mod.MiningWindow.checkIdleAlert, .{ now, idle_window_ms, config.mining.idle_alert_threshold }, false)) {
                    notifier.notify(eve_window.hwnd, .{ .notification_type = .MiningIdle });
                }
                if (mining.query(eve_window.character_name, tracker_mod.MiningWindow.checkStoppedAlert, .{ now, stopped_window_ms }, false)) {
                    notifier.notify(eve_window.hwnd, .{ .notification_type = .MiningStopped });
                }
            }
        }
    }
};

fn pushThrottled(comptime T: type, comptime per_window: fn (*T, *Roster, scout.EveWindow, win32.Ticks) void, tracker: *T, context: TickContext, last_update: *win32.Ticks, interval_ms: u32) void {
    if (!schedule.isDue(context.now.elapsedSince(last_update.*), interval_ms, context.tick_interval_ms)) return;
    last_update.* = context.now;

    for (context.windows) |eve_window| {
        per_window(tracker, context.roster, eve_window, context.now);
    }
}

fn pushDps(tracker: *tracker_mod.CombatTracker, roster: *Roster, eve_window: scout.EveWindow, now: win32.Ticks) void {
    const dps = tracker.query(eve_window.character_name, tracker_mod.CombatWindow.computeDps, .{now}, .{ .incoming = 0.0, .outgoing = 0.0 });
    roster.updateStats(eve_window.hwnd, ActivityStats.setDps, .{ dps.incoming, dps.outgoing });
}

fn pushMining(tracker: *tracker_mod.MiningTracker, roster: *Roster, eve_window: scout.EveWindow, now: win32.Ticks) void {
    const rates = tracker.query(eve_window.character_name, tracker_mod.MiningWindow.computeRates, .{now}, .{ .m3 = 0.0, .isk = 0.0 });
    roster.updateStats(eve_window.hwnd, ActivityStats.setMining, .{ rates.m3, rates.isk });
}

fn pushBounty(tracker: *tracker_mod.BountyTracker, roster: *Roster, eve_window: scout.EveWindow, now: win32.Ticks) void {
    const isk_rate = tracker.query(eve_window.character_name, tracker_mod.BountyWindow.computeIskRate, .{now}, 0.0);
    roster.updateStats(eve_window.hwnd, ActivityStats.setBounty, .{isk_rate});
}

fn pushResources(tracker: *resources_mod.ResourceTracker, roster: *Roster, windows: []const scout.EveWindow, now: win32.Ticks) void {
    tracker.sampleAll(windows, now);
    for (windows) |eve_window| {
        const stats = tracker.getStats(eve_window.process_id);
        roster.updateStats(eve_window.hwnd, ActivityStats.setResources, .{ stats.cpu_percent, stats.ram_mb, stats.vram_mb, stats.has_vram });
    }
}

fn pushPing(tracker: *const ping_mod.PingTracker, roster: *Roster, windows: []const scout.EveWindow) void {
    for (windows) |eve_window| {
        const ping = tracker.pingOf(eve_window.process_id);
        roster.updateStats(eve_window.hwnd, ActivityStats.setPing, .{ ping.is_connected, ping.rtt_ms });
    }
}
