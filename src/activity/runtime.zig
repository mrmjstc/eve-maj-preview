//! The profile's live activity trackers, and the throttled push of their values into the painter.
const std = @import("std");
const config = @import("../config.zig");
const painter_mod = @import("../painter.zig");
const scout = @import("../clients/scout.zig");
const chatlog = @import("../chatlog.zig");
const tracker_mod = @import("tracker.zig");
const resources_mod = @import("resources.zig");
const log = @import("../log.zig");

const Painter = painter_mod.Painter;
const Config = config.Config;
const slog = log.scoped("activity");

/// Independent of the overlay refresh, and also the cap when an alert's throttle is 0.
const ALERT_CHECK_INTERVAL_MS: i64 = 1000;

pub const Trackers = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    combat: ?*tracker_mod.CombatTracker = null,
    mining: ?*tracker_mod.MiningTracker = null,
    bounty: ?*tracker_mod.BountyTracker = null,
    resources: ?*resources_mod.ResourceTracker = null,
    last_dps_update_ms: i64 = 0,
    last_mining_update_ms: i64 = 0,
    last_bounty_update_ms: i64 = 0,
    last_resource_update_ms: i64 = 0,
    last_alert_check_ms: i64 = 0,

    /// Matches the trackers to `cfg`, keeping each one that stays enabled with its history, and hands them to `monitor`, whose worker thread must be stopped.
    /// Fail-soft: a tracker that can't be created is logged and left off rather than aborting startup or a reload.
    pub fn setup(self: *Trackers, cfg: *const Config, monitor: ?*chatlog.ChatlogMonitor) void {
        self.reconcile(tracker_mod.CombatTracker, &self.combat, cfg.combat.enabled, cfg.combat.window_seconds, "Combat DPS");
        self.reconcile(tracker_mod.MiningTracker, &self.mining, cfg.mining.enabled, cfg.mining.window_seconds, "Mining rate");
        self.reconcile(tracker_mod.BountyTracker, &self.bounty, cfg.bounty.enabled, cfg.bounty.window_seconds, "Bounty rate");
        self.setupResources(cfg.resources.enabled);

        if (monitor) |m| {
            m.combat_tracker = self.combat;
            m.mining_tracker = self.mining;
            m.bounty_tracker = self.bounty;
            m.setDamageAlertExcludedWeapons(cfg.combat.damage_alert_excluded_weapons);
        }
    }

    /// Doesn't log, since it runs in shutdown defers that may race process exit.
    pub fn deinit(self: *Trackers) void {
        self.destroy(tracker_mod.CombatTracker, &self.combat, null);
        self.destroy(tracker_mod.MiningTracker, &self.mining, null);
        self.destroy(tracker_mod.BountyTracker, &self.bounty, null);
        self.destroy(resources_mod.ResourceTracker, &self.resources, null);
    }

    fn reconcile(self: *Trackers, comptime T: type, slot: *?*T, enabled: bool, window_seconds: u32, label: []const u8) void {
        if (!enabled) {
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

    fn setupResources(self: *Trackers, enabled: bool) void {
        if (!enabled) {
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

    fn destroy(self: *Trackers, comptime T: type, slot: *?*T, kind: ?[]const u8) void {
        const tracker = slot.* orelse return;
        slot.* = null;
        tracker.deinit();
        self.allocator.destroy(tracker);
        if (kind) |k| slog.debug("Cleaned up {s} tracker", .{k});
    }

    /// Pushes each enabled tracker's values into the painter at its configured interval, and checks alerts every ALERT_CHECK_INTERVAL_MS.
    pub fn tick(self: *Trackers, cfg: *const Config, windows: []const scout.EveWindow, now_ms: i64) void {
        if (self.combat) |t| pushThrottled(tracker_mod.CombatTracker, pushDps, t, cfg, windows, now_ms, &self.last_dps_update_ms, cfg.combat.update_interval_ms);
        if (self.mining) |t| pushThrottled(tracker_mod.MiningTracker, pushMining, t, cfg, windows, now_ms, &self.last_mining_update_ms, cfg.mining.update_interval_ms);
        if (self.bounty) |t| pushThrottled(tracker_mod.BountyTracker, pushBounty, t, cfg, windows, now_ms, &self.last_bounty_update_ms, cfg.bounty.update_interval_ms);

        if (now_ms - self.last_alert_check_ms >= ALERT_CHECK_INTERVAL_MS) {
            self.last_alert_check_ms = now_ms;
            self.checkAlerts(cfg, windows, now_ms);
        }

        self.setupResources(cfg.resources.enabled);
        if (self.resources) |t| {
            if (now_ms - self.last_resource_update_ms >= @as(i64, @intCast(cfg.resources.update_interval_ms))) {
                self.last_resource_update_ms = now_ms;
                pushResources(t, windows, now_ms);
            }
        }
    }

    fn checkAlerts(self: *const Trackers, cfg: *const Config, windows: []const scout.EveWindow, now_ms: i64) void {
        const painter = painter_mod.g_painter_ptr orelse return;
        const idle_window_ms: i64 = @as(i64, cfg.mining.idle_alert_window_seconds) * std.time.ms_per_s;
        const stopped_window_ms: i64 = @as(i64, cfg.mining.stopped_alert_window_seconds) * std.time.ms_per_s;
        for (windows) |eve_window| {
            if (self.combat) |combat| {
                if (combat.checkDamageAlert(eve_window.character_name)) painter.notify(eve_window.hwnd, .{ .ntype = .TakingDamage });
            }
            if (self.mining) |mining| {
                if (mining.checkIdleAlert(eve_window.character_name, now_ms, idle_window_ms, cfg.mining.idle_alert_threshold)) {
                    painter.notify(eve_window.hwnd, .{ .ntype = .MiningIdle });
                }
                if (mining.checkStoppedAlert(eve_window.character_name, now_ms, stopped_window_ms)) {
                    painter.notify(eve_window.hwnd, .{ .ntype = .MiningStopped });
                }
            }
        }
    }
};

/// Also throttles refreshAll, since nothing reads the rates more often than this pushes them.
fn pushThrottled(
    comptime T: type,
    comptime perWindow: fn (*T, *Painter, *const Config, scout.EveWindow, i64) void,
    tracker: *T,
    cfg: *const Config,
    windows: []const scout.EveWindow,
    now_ms: i64,
    last_update_ms: *i64,
    interval_ms: anytype,
) void {
    if (now_ms - last_update_ms.* < @as(i64, @intCast(interval_ms))) return;
    last_update_ms.* = now_ms;

    _ = tracker.refreshAll(now_ms);

    const painter = painter_mod.g_painter_ptr orelse return;
    for (windows) |eve_window| {
        perWindow(tracker, painter, cfg, eve_window, now_ms);
    }
    painter.renderDirtyThumbnails(null);
}

fn pushDps(tracker: *tracker_mod.CombatTracker, painter: *Painter, _: *const Config, eve_window: scout.EveWindow, _: i64) void {
    const dps = tracker.getDps(eve_window.character_name);
    painter.updateDpsForCharacter(eve_window.hwnd, dps.incoming, dps.outgoing);
}

fn pushMining(tracker: *tracker_mod.MiningTracker, painter: *Painter, _: *const Config, eve_window: scout.EveWindow, _: i64) void {
    painter.updateMiningForCharacter(eve_window.hwnd, tracker.getRate(eve_window.character_name), tracker.getIskRate(eve_window.character_name));
}

fn pushBounty(tracker: *tracker_mod.BountyTracker, painter: *Painter, _: *const Config, eve_window: scout.EveWindow, _: i64) void {
    painter.updateBountyForCharacter(eve_window.hwnd, tracker.getIskRate(eve_window.character_name));
}

fn pushResources(tracker: *resources_mod.ResourceTracker, windows: []const scout.EveWindow, now_ms: i64) void {
    tracker.sampleAll(windows, now_ms);

    const painter = painter_mod.g_painter_ptr orelse return;
    for (windows) |eve_window| {
        const stats = tracker.getStats(eve_window.process_id);
        painter.updateResourceStatsForCharacter(eve_window.hwnd, stats.cpu_percent, stats.ram_mb, stats.vram_mb, stats.has_vram);
    }
    painter.renderDirtyThumbnails(null);
}
