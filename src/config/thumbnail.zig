//! Thumbnail appearance, per-state visuals included.
const std = @import("std");
const types = @import("types.zig");
const state_mod = @import("../thumbnail/state.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");
const NotificationConfig = @import("notifications.zig").NotificationConfig;

const BORDER_WIDTH = .{ 1, 50 };

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
    width: i32 = 200,
    height: i32 = 112,

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
    showQuickGroupBadge: bool = false,
    quickGroupBadgeColor: u32 = 0xFF44FF44,
    quickGroupBadgeBgColor: u32 = 0xE6000000,
    quickGroupBadgePosition: types.TextPosition = .RightCenter,
    quickGroupBadgeOffsetX: i32 = 0,
    quickGroupBadgeOffsetY: i32 = 0,
    quickGroupBadgeFontName: []const u8 = "Segoe UI",
    quickGroupBadgeFontSize: i32 = 12,
    quickGroupBadgeFontWeight: types.FontWeight = .Regular,
    exclusionOverlayStyle: types.ExclusionOverlayStyle = .X,
    exclusionOverlayColor: u32 = 0x33A62222,
    notifications: NotificationConfig = .{},
    thumbnailOpacity: u8 = 255,
    applyOpacityToOverlayTexts: bool = false,
    activeThumbnailHidden: bool = false,
    hideWhenNoEveFocus: bool = false,
    hideDebounceMs: u32 = 500,

    /// Defaults set here (not at declaration alone) so null on `active` means "use activeThumbnailHidden" instead of a fixed true/false.
    active: StateVisualConfig = .{ .showThumbnail = null },
    inactive: StateVisualConfig = .{ .showThumbnail = true },
    alert: StateVisualConfig = .{ .showThumbnail = true },
    minimized: StateVisualConfig = .{ .showThumbnail = true },
    dragging: StateVisualConfig = .{ .showThumbnail = true },

    pub fn getStateConfig(self: *const ThumbnailConfig, state: state_mod.ThumbnailState) StateVisualConfig {
        return switch (state) {
            .Active => self.active,
            .Inactive => self.inactive,
            .Alert => self.alert,
            .Minimized => self.minimized,
            .Dragging => self.dragging,
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
        .thumbnailOpacity = ranges_mod.OPACITY,
        .characterNameOffsetX = ranges_mod.TEXT_OFFSET,
        .characterNameOffsetY = ranges_mod.TEXT_OFFSET,
        .systemNameOffsetX = ranges_mod.TEXT_OFFSET,
        .systemNameOffsetY = ranges_mod.TEXT_OFFSET,
        .quickGroupBadgeOffsetX = ranges_mod.TEXT_OFFSET,
        .quickGroupBadgeOffsetY = ranges_mod.TEXT_OFFSET,
        .hideDebounceMs = .{ 0, 5000 },
    };

    pub fn validate(self: *ThumbnailConfig) void {
        ranges_mod.clamp(ThumbnailConfig, self);
    }

    pub const Wire = wire.Wire(ThumbnailConfig);
};
