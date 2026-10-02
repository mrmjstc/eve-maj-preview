//! Combat, mining, bounty and resource overlays, and the travel left-behind check.
const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");

/// Refresh-rate bounds for Combat, Mining and Bounty; Resources sets its own.
const UPDATE_INTERVAL_MS = .{ 1000, 10000 };

pub const CombatConfig = struct {
    enabled: bool = false,
    window_seconds: u32 = 60,
    show_incoming: bool = true,
    show_outgoing: bool = true,
    incoming_color: u32 = 0xFFFF4444,
    outgoing_color: u32 = 0xFF44FF44,
    incoming_bg_color: u32 = 0xE6000000,
    outgoing_bg_color: u32 = 0xE6000000,
    incoming_font_size: i32 = 12,
    incoming_font_name: []const u8 = "Segoe UI",
    incoming_font_weight: types.FontWeight = .Regular,
    outgoing_font_size: i32 = 12,
    outgoing_font_name: []const u8 = "Segoe UI",
    outgoing_font_weight: types.FontWeight = .Regular,
    update_interval_ms: u32 = 1000,
    incoming_position: types.TextPosition = .TopCenter,
    outgoing_position: types.TextPosition = .BottomCenter,
    incoming_offset_x: i32 = 0,
    incoming_offset_y: i32 = 0,
    outgoing_offset_x: i32 = 0,
    outgoing_offset_y: i32 = 0,
    incoming_show_prefix: bool = true,
    outgoing_show_prefix: bool = true,
    /// Comma-separated, case-insensitive weapon-name substrings whose hits count toward DPS but don't trigger the Taking Damage alert.
    damage_alert_excluded_weapons: []const u8 = "",

    pub const ranges = .{
        .window_seconds = .{ 5, 600 },
        .incoming_font_size = ranges_mod.FONT_SIZE,
        .outgoing_font_size = ranges_mod.FONT_SIZE,
        .update_interval_ms = UPDATE_INTERVAL_MS,
        .incoming_offset_x = ranges_mod.TEXT_OFFSET,
        .incoming_offset_y = ranges_mod.TEXT_OFFSET,
        .outgoing_offset_x = ranges_mod.TEXT_OFFSET,
        .outgoing_offset_y = ranges_mod.TEXT_OFFSET,
    };
    pub const zero_means_default = .{"window_seconds"};

    pub fn validate(self: *CombatConfig) void {
        ranges_mod.clamp(CombatConfig, self);
    }

    pub const Wire = wire.Wire(CombatConfig);
};

pub const IskRateUnit = enum { minute, hour };

pub const MiningConfig = struct {
    enabled: bool = false,
    window_seconds: u32 = 60,
    color: u32 = 0xFF44AAFF,
    bg_color: u32 = 0xE6000000,
    font_size: i32 = 12,
    font_name: []const u8 = "Segoe UI",
    font_weight: types.FontWeight = .Regular,
    update_interval_ms: u32 = 1000,
    position: types.TextPosition = .BottomRight,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    idle_alert_window_seconds: u32 = 30,
    idle_alert_threshold: u32 = 1,
    stopped_alert_window_seconds: u32 = 60,
    show_isk_rate: bool = true,
    isk_rate_unit: IskRateUnit = .hour,
    show_prefix: bool = true,

    pub const ranges = .{
        .window_seconds = .{ 30, 3600 },
        .font_size = ranges_mod.FONT_SIZE,
        .update_interval_ms = UPDATE_INTERVAL_MS,
        .idle_alert_window_seconds = .{ 30, 600 },
        .stopped_alert_window_seconds = .{ 30, 3600 },
        .offset_x = ranges_mod.TEXT_OFFSET,
        .offset_y = ranges_mod.TEXT_OFFSET,
        .idle_alert_threshold = .{ 0, 60 },
    };
    pub const zero_means_default = .{ "window_seconds", "idle_alert_window_seconds", "stopped_alert_window_seconds" };

    pub fn validate(self: *MiningConfig) void {
        ranges_mod.clamp(MiningConfig, self);
    }

    pub const Wire = wire.Wire(MiningConfig);
};

/// Like Mining's ISK rate, without an m3 rate or ore table, since bounties already arrive in ISK.
pub const BountyConfig = struct {
    enabled: bool = false,
    window_seconds: u32 = 1200,
    color: u32 = 0xFFFFD700,
    bg_color: u32 = 0xE6000000,
    font_size: i32 = 12,
    font_name: []const u8 = "Segoe UI",
    font_weight: types.FontWeight = .Regular,
    update_interval_ms: u32 = 1000,
    position: types.TextPosition = .TopRight,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    isk_rate_unit: IskRateUnit = .hour,
    show_prefix: bool = true,

    pub const ranges = .{
        .window_seconds = .{ 60, 3600 },
        .font_size = ranges_mod.FONT_SIZE,
        .update_interval_ms = UPDATE_INTERVAL_MS,
        .offset_x = ranges_mod.TEXT_OFFSET,
        .offset_y = ranges_mod.TEXT_OFFSET,
    };
    pub const zero_means_default = .{"window_seconds"};

    pub fn validate(self: *BountyConfig) void {
        ranges_mod.clamp(BountyConfig, self);
    }

    pub const Wire = wire.Wire(BountyConfig);
};

/// Per-process CPU/RAM/VRAM overlay; single combined label like BountyConfig, no alert machinery - see activity/resources.zig.
pub const ResourcesConfig = struct {
    enabled: bool = false,
    show_cpu: bool = true,
    show_ram: bool = true,
    show_vram: bool = true,
    color: u32 = 0xFFFFFFFF,
    bg_color: u32 = 0xE6000000,
    font_size: i32 = 12,
    font_name: []const u8 = "Segoe UI",
    font_weight: types.FontWeight = .Regular,
    update_interval_ms: u32 = 10000,
    position: types.TextPosition = .LeftCenter,
    offset_x: i32 = 0,
    offset_y: i32 = 0,

    pub const ranges = .{
        .font_size = ranges_mod.FONT_SIZE,
        // A higher ceiling than the other overlays: each refresh samples every client's CPU, RAM and VRAM.
        .update_interval_ms = .{ 1000, 60000 },
        .offset_x = ranges_mod.TEXT_OFFSET,
        .offset_y = ranges_mod.TEXT_OFFSET,
    };

    pub fn validate(self: *ResourcesConfig) void {
        ranges_mod.clamp(ResourcesConfig, self);
    }

    pub const Wire = wire.Wire(ResourcesConfig);
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
