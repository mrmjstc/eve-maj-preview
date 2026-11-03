//! Thumbnail appearance, per-state visuals included.
const types = @import("types.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");
const notifications_mod = @import("notifications.zig");
const connections = @import("../map/connections.zig");

const NotificationConfig = notifications_mod.NotificationConfig;

const BORDER_WIDTH = .{ 1, 50 };

/// Decided live by ThumbnailWindow.effectiveRenderState, never saved.
pub const ThumbnailState = enum {
    inactive,
    active,
    alert,
    minimized,
    dragging,
};

pub const StateVisualConfig = struct {
    borderWidth: ?u8 = null,
    borderColor: ?u32 = null,
    borderStyle: ?types.BorderStyle = null,
    textColor: ?u32 = null,
    textBgColor: ?u32 = null,
    showBorder: ?bool = null,
    showThumbnail: ?bool = null,

    pub const ranges = .{
        .borderWidth = BORDER_WIDTH,
    };

    pub fn validate(self: *StateVisualConfig) void {
        ranges_mod.clamp(StateVisualConfig, self);
    }

    pub const Wire = wire.Wire(StateVisualConfig);
};

pub const ThumbnailConfig = struct {
    width: i32 = 282,
    height: i32 = 158,

    showBorderWhenFocused: bool = true,
    borderWidth: u8 = 2,
    borderColor: u32 = 0xFFD9A441,
    borderStyle: types.BorderStyle = .Solid,
    showBorderWhenInactive: bool = false,
    inactiveBorderWidth: u8 = 2,
    inactiveBorderColor: u32 = 0xFF606060,
    inactiveBorderStyle: types.BorderStyle = .Solid,
    showText: bool = true,
    showCharacterName: bool = true,
    showSystemName: bool = false,
    /// Replaces the system name with a map of the systems a few gates out.
    showSystemConnections: bool = false,
    systemConnectionJumps: u8 = 1,
    systemConnectionMapWidth: i32 = 180,
    systemConnectionMapHeight: i32 = 140,
    showSystemConnectionIntel: bool = true,
    characterNameColor: u32 = 0xFFFFFF,
    characterNameBgColor: u32 = 0xE6000000,
    useUniqueCharacterNameColors: bool = false,
    useUniqueCharacterBorderColors: bool = false,
    characterNameFontName: []const u8 = "Segoe UI",
    characterNameFontSize: i32 = 12,
    characterNameFontWeight: types.FontWeight = .Regular,
    useUniqueSystemColors: bool = false,
    systemNameColor: u32 = 0xFFFFFF,
    systemNameBgColor: u32 = 0xE6000000,
    characterNamePosition: types.TextPosition = .TopLeft,
    characterNameOffsetX: i32 = 0,
    characterNameOffsetY: i32 = 0,
    systemNamePosition: types.TextPosition = .BottomLeft,
    systemNameOffsetX: i32 = 0,
    systemNameOffsetY: i32 = 0,
    systemNameFontName: []const u8 = "Segoe UI",
    systemNameFontSize: i32 = 12,
    systemNameFontWeight: types.FontWeight = .Regular,
    showQuickGroupBadge: bool = true,
    quickGroupBadgeColor: u32 = 0xFF44FF44,
    quickGroupBadgeBgColor: u32 = 0xE6000000,
    quickGroupBadgePosition: types.TextPosition = .RightCenter,
    quickGroupBadgeOffsetX: i32 = 0,
    quickGroupBadgeOffsetY: i32 = 0,
    quickGroupBadgeFontName: []const u8 = "Segoe UI",
    quickGroupBadgeFontSize: i32 = 12,
    quickGroupBadgeFontWeight: types.FontWeight = .Regular,
    showSessionTimer: bool = false,
    sessionTimerColor: u32 = 0xFFFFFF,
    sessionTimerBgColor: u32 = 0xE6000000,
    sessionTimerPosition: types.TextPosition = .RightCenter,
    sessionTimerOffsetX: i32 = 0,
    sessionTimerOffsetY: i32 = -24,
    sessionTimerFontName: []const u8 = "Segoe UI",
    sessionTimerFontSize: i32 = 12,
    sessionTimerFontWeight: types.FontWeight = .Regular,
    exclusionOverlayStyle: types.ExclusionOverlayStyle = .X,
    exclusionOverlayColor: u32 = 0x33A62222,
    notifications: NotificationConfig = .{},
    thumbnailOpacity: u8 = 255,
    applyOpacityToOverlayTexts: bool = true,
    activeThumbnailHidden: bool = false,
    hideWhenNoEveFocus: bool = false,
    hideDebounceMs: u32 = 500,

    /// Only `active` leaves showThumbnail null, meaning "use activeThumbnailHidden".
    active: StateVisualConfig = .{ .showThumbnail = null },
    inactive: StateVisualConfig = .{ .showThumbnail = true },
    alert: StateVisualConfig = .{ .showThumbnail = true },
    minimized: StateVisualConfig = .{ .showThumbnail = true },
    dragging: StateVisualConfig = .{ .showThumbnail = true },

    pub fn getStateConfig(self: *const ThumbnailConfig, state: ThumbnailState) StateVisualConfig {
        return switch (state) {
            .active => self.active,
            .inactive => self.inactive,
            .alert => self.alert,
            .minimized => self.minimized,
            .dragging => self.dragging,
        };
    }

    pub const WIDTH = .{ 50, ranges_mod.MAX_WINDOW_WIDTH };
    pub const HEIGHT = .{ 50, ranges_mod.MAX_WINDOW_HEIGHT };

    pub const ranges = .{
        .width = WIDTH,
        .height = HEIGHT,
        .borderWidth = BORDER_WIDTH,
        .inactiveBorderWidth = BORDER_WIDTH,
        .characterNameFontSize = ranges_mod.FONT_SIZE,
        .systemNameFontSize = ranges_mod.FONT_SIZE,
        .quickGroupBadgeFontSize = ranges_mod.FONT_SIZE,
        .sessionTimerFontSize = ranges_mod.FONT_SIZE,
        .thumbnailOpacity = ranges_mod.OPACITY,
        .characterNameOffsetX = ranges_mod.TEXT_OFFSET,
        .characterNameOffsetY = ranges_mod.TEXT_OFFSET,
        .systemNameOffsetX = ranges_mod.TEXT_OFFSET,
        .systemNameOffsetY = ranges_mod.TEXT_OFFSET,
        .systemConnectionJumps = .{ 1, connections.MAX_JUMPS },
        .systemConnectionMapWidth = .{ 80, ranges_mod.MAX_WINDOW_WIDTH },
        .systemConnectionMapHeight = .{ 60, ranges_mod.MAX_WINDOW_HEIGHT },
        .quickGroupBadgeOffsetX = ranges_mod.TEXT_OFFSET,
        .quickGroupBadgeOffsetY = ranges_mod.TEXT_OFFSET,
        .sessionTimerOffsetX = ranges_mod.TEXT_OFFSET,
        .sessionTimerOffsetY = ranges_mod.TEXT_OFFSET,
        .hideDebounceMs = .{ 0, 5000 },
    };

    pub fn validate(self: *ThumbnailConfig) void {
        ranges_mod.clamp(ThumbnailConfig, self);
    }

    pub const Wire = wire.Wire(ThumbnailConfig);
};
