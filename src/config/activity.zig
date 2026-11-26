//! What the activity trackers measure and how often, and the travel left-behind check.
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");

const UPDATE_INTERVAL_MS = .{ 1000, 10000 };
// The thumbnails' and the client list's default rate colours, softened and kept off the accent presets.
pub const INCOMING_COLOR: u32 = 0xFFE05A4E;
pub const OUTGOING_COLOR: u32 = 0xFF68CA6B;
pub const MINING_COLOR: u32 = 0xFF7E98E7;
pub const BOUNTY_COLOR: u32 = 0xFFE1C747;

/// The tracker runs while the thumbnails or the client list show its rates; see Config.tracksCombat.
pub const CombatConfig = struct {
    window_seconds: u32 = 60,
    update_interval_ms: u32 = 1000,
    /// Comma-separated, case-insensitive weapon-name substrings whose hits count toward DPS but don't trigger the Taking Damage alert.
    damage_alert_excluded_weapons: []const u8 = "",

    pub const ranges = .{
        .window_seconds = .{ 5, 600 },
        .update_interval_ms = UPDATE_INTERVAL_MS,
    };
    pub const zero_means_default = .{"window_seconds"};

    pub fn validate(self: *CombatConfig) void {
        ranges_mod.clamp(CombatConfig, self);
    }

    pub const Wire = wire.Wire(CombatConfig);
};

pub const RateUnit = enum {
    minute,
    hour,

    pub fn seconds(self: RateUnit) f32 {
        return switch (self) {
            .minute => 60.0,
            .hour => 3600.0,
        };
    }

    /// After a rate's "/", as in "ISK/hr".
    pub fn suffix(self: RateUnit) []const u8 {
        return switch (self) {
            .minute => "min",
            .hour => "hr",
        };
    }
};

/// The tracker, and with it the Mining Idle and Stopped alerts, runs while the thumbnails or the client list show its rate; see Config.tracksMining.
pub const MiningConfig = struct {
    window_seconds: u32 = 60,
    update_interval_ms: u32 = 1000,
    idle_alert_window_seconds: u32 = 30,
    idle_alert_threshold: u32 = 1,
    stopped_alert_window_seconds: u32 = 60,
    /// The m3 rate's period; isk_rate_unit is the ISK rate's.
    m3_rate_unit: RateUnit = .hour,
    isk_rate_unit: RateUnit = .hour,

    pub const ranges = .{
        .window_seconds = .{ 30, 3600 },
        .update_interval_ms = UPDATE_INTERVAL_MS,
        .idle_alert_window_seconds = .{ 30, 600 },
        .stopped_alert_window_seconds = .{ 30, 3600 },
        .idle_alert_threshold = .{ 0, 60 },
    };
    pub const zero_means_default = .{ "window_seconds", "idle_alert_window_seconds", "stopped_alert_window_seconds" };

    pub fn validate(self: *MiningConfig) void {
        ranges_mod.clamp(MiningConfig, self);
    }

    pub const Wire = wire.Wire(MiningConfig);
};

/// Like Mining's ISK rate, without an m3 rate or ore table, since bounties already arrive in ISK; see Config.tracksBounty.
pub const BountyConfig = struct {
    window_seconds: u32 = 1200,
    update_interval_ms: u32 = 1000,
    isk_rate_unit: RateUnit = .hour,

    pub const ranges = .{
        .window_seconds = .{ 60, 3600 },
        .update_interval_ms = UPDATE_INTERVAL_MS,
    };
    pub const zero_means_default = .{"window_seconds"};

    pub fn validate(self: *BountyConfig) void {
        ranges_mod.clamp(BountyConfig, self);
    }

    pub const Wire = wire.Wire(BountyConfig);
};

/// Each client's CPU, RAM and VRAM, sampled while the thumbnails show them; see Config.tracksResources.
pub const ResourcesConfig = struct {
    update_interval_ms: u32 = 10000,

    pub const ranges = .{
        // A higher ceiling than the log-fed trackers': each refresh samples every client's CPU, RAM and VRAM.
        .update_interval_ms = .{ 1000, 60000 },
    };

    pub fn validate(self: *ResourcesConfig) void {
        ranges_mod.clamp(ResourcesConfig, self);
    }

    pub const Wire = wire.Wire(ResourcesConfig);
};

/// Each client's round trip to its server, pinged while the thumbnails show it; see Config.tracksPing.
pub const PingConfig = struct {
    update_interval_ms: u32 = 10000,

    pub const ranges = .{
        // Like ResourcesConfig's ceiling, since a ping rarely changes between samples.
        .update_interval_ms = .{ 1000, 60000 },
    };

    pub fn validate(self: *PingConfig) void {
        ranges_mod.clamp(PingConfig, self);
    }

    pub const Wire = wire.Wire(PingConfig);
};

pub const TravelThresholdMode = enum { percent, count };

pub const TravelConfig = struct {
    enabled: bool = false,
    window_seconds: u32 = 30,
    threshold_mode: TravelThresholdMode = .percent,
    threshold_percent: f32 = 50.0,
    threshold_count: u32 = 2,

    pub const ranges = .{
        .window_seconds = ranges_mod.WINDOW_SECONDS,
        .threshold_percent = .{ 1.0, 100.0 },
        .threshold_count = .{ 1, 50 },
    };
    pub const zero_means_default = .{"window_seconds"};

    pub fn validate(self: *TravelConfig) void {
        ranges_mod.clamp(TravelConfig, self);
    }
};
