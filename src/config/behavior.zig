//! Scanning, snapping, click handling, auto-minimize, auto-move and exclusion settings.
const types = @import("../types.zig");
const ranges_mod = @import("ranges.zig");

pub const TimerConfig = struct {
    scanIntervalMs: u32 = 50,

    pub const ranges = .{
        .scanIntervalMs = .{ 50, 10000 },
    };

    pub fn validate(self: *TimerConfig) void {
        ranges_mod.clamp(TimerConfig, self);
    }
};

pub const SnappingConfig = struct {
    enabled: bool = true,
    threshold: i32 = 10,
    screenEdges: bool = true,
    thumbnailEdges: bool = true,
    ghostPositions: bool = true,
    showGhostPositionBorders: bool = true,

    pub const ranges = .{
        .threshold = .{ 0, 100 },
    };

    pub fn validate(self: *SnappingConfig) void {
        ranges_mod.clamp(SnappingConfig, self);
    }
};

pub const InteractionConfig = struct {
    enableDragging: bool = true,
    animationStyle: types.AnimationStyle = .NoAnimation,
    clickTrigger: types.ClickTrigger = .MouseDown,
    clickThrough: bool = false,
    hoverCursor: types.HoverCursor = .Default,
};

pub const AutoMinimizeConfig = struct {
    enabled: bool = false,
    delayMs: u32 = 5000,
    /// Keep the last-focused EVE client exempt from auto-minimize while EVE itself has no window focused.
    exemptLastActiveOnFocusLoss: bool = true,

    pub const ranges = .{
        .delayMs = .{ 0, 10000 },
    };

    pub fn validate(self: *AutoMinimizeConfig) void {
        ranges_mod.clamp(AutoMinimizeConfig, self);
    }
};

pub const AutoMovePositionConfig = struct {
    enabled: bool = false,
    moveOnStartup: bool = false,
    verifyIntervalMs: u32 = 2000,
    verifyCount: u8 = 6,

    pub const ranges = .{
        .verifyIntervalMs = .{ 250, 10000 },
        .verifyCount = .{ 0, 30 },
    };

    pub fn validate(self: *AutoMovePositionConfig) void {
        ranges_mod.clamp(AutoMovePositionConfig, self);
    }
};

pub const ExclusionConfig = struct {
    enableShiftClickExclude: bool = true,
    autoMinimizeExcluded: bool = false,
};

pub const CloseAllConfig = struct {
    excludeLoginScreenClients: bool = false,
};
