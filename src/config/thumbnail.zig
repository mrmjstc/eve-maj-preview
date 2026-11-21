//! Thumbnail appearance, per-state visuals included.
const types = @import("types.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");
const activity = @import("activity.zig");
const connections = @import("../map/connections.zig");
const color_mod = @import("../util/color.zig");

const BORDER_WIDTH = .{ 1, 50 };
/// How much of the border colour a blankDimsBorder fill keeps over black.
const BLANK_BORDER_PERCENT = 25;

/// Where and how a thumbnail draws its alerts; what they say and their colour are notifications'.
pub const AlertTextStyle = struct {
    position: types.TextPosition = .Center,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    font_name: []const u8 = types.DEFAULT_FONT,
    font_size: i32 = types.DEFAULT_FONT_SIZE,
    font_weight: types.FontWeight = .Regular,
    bg_color: u32 = 0xE6000000,

    pub const ranges = .{
        .offset_x = ranges_mod.TEXT_OFFSET,
        .offset_y = ranges_mod.TEXT_OFFSET,
        .font_size = ranges_mod.FONT_SIZE,
    };

    pub fn validate(self: *AlertTextStyle) void {
        ranges_mod.clamp(AlertTextStyle, self);
    }

    pub const Wire = wire.Wire(AlertTextStyle);
};

/// The incoming and outgoing DPS texts; combat holds what the tracker measures.
pub const CombatTextStyle = struct {
    shown: bool = false,
    show_incoming: bool = true,
    show_outgoing: bool = true,
    incoming_color: u32 = activity.INCOMING_COLOR,
    outgoing_color: u32 = activity.OUTGOING_COLOR,
    incoming_bg_color: u32 = 0xE6000000,
    outgoing_bg_color: u32 = 0xE6000000,
    incoming_font_size: i32 = types.DEFAULT_FONT_SIZE,
    incoming_font_name: []const u8 = types.DEFAULT_FONT,
    incoming_font_weight: types.FontWeight = .Regular,
    outgoing_font_size: i32 = types.DEFAULT_FONT_SIZE,
    outgoing_font_name: []const u8 = types.DEFAULT_FONT,
    outgoing_font_weight: types.FontWeight = .Regular,
    incoming_position: types.TextPosition = .TopCenter,
    outgoing_position: types.TextPosition = .TopCenter,
    incoming_offset_x: i32 = 0,
    incoming_offset_y: i32 = 0,
    outgoing_offset_x: i32 = 0,
    outgoing_offset_y: i32 = 24,
    incoming_show_prefix: bool = true,
    outgoing_show_prefix: bool = true,

    pub const ranges = .{
        .incoming_font_size = ranges_mod.FONT_SIZE,
        .outgoing_font_size = ranges_mod.FONT_SIZE,
        .incoming_offset_x = ranges_mod.TEXT_OFFSET,
        .incoming_offset_y = ranges_mod.TEXT_OFFSET,
        .outgoing_offset_x = ranges_mod.TEXT_OFFSET,
        .outgoing_offset_y = ranges_mod.TEXT_OFFSET,
    };

    pub fn validate(self: *CombatTextStyle) void {
        ranges_mod.clamp(CombatTextStyle, self);
    }

    pub const Wire = wire.Wire(CombatTextStyle);
};

/// The mining rate text; mining holds what the tracker measures and the rates' units.
pub const MiningTextStyle = struct {
    shown: bool = false,
    /// A second line, priced from the ore table.
    show_isk_rate: bool = true,
    color: u32 = activity.MINING_COLOR,
    bg_color: u32 = 0xE6000000,
    font_size: i32 = types.DEFAULT_FONT_SIZE,
    font_name: []const u8 = types.DEFAULT_FONT,
    font_weight: types.FontWeight = .Regular,
    position: types.TextPosition = .BottomRight,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    show_prefix: bool = true,

    pub const ranges = .{
        .font_size = ranges_mod.FONT_SIZE,
        .offset_x = ranges_mod.TEXT_OFFSET,
        .offset_y = ranges_mod.TEXT_OFFSET,
    };

    pub fn validate(self: *MiningTextStyle) void {
        ranges_mod.clamp(MiningTextStyle, self);
    }

    pub const Wire = wire.Wire(MiningTextStyle);
};

/// The bounty rate text; bounty holds what the tracker measures and the rate's unit.
pub const BountyTextStyle = struct {
    shown: bool = false,
    color: u32 = activity.BOUNTY_COLOR,
    bg_color: u32 = 0xE6000000,
    font_size: i32 = types.DEFAULT_FONT_SIZE,
    font_name: []const u8 = types.DEFAULT_FONT,
    font_weight: types.FontWeight = .Regular,
    position: types.TextPosition = .TopRight,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    show_prefix: bool = true,

    pub const ranges = .{
        .font_size = ranges_mod.FONT_SIZE,
        .offset_x = ranges_mod.TEXT_OFFSET,
        .offset_y = ranges_mod.TEXT_OFFSET,
    };

    pub fn validate(self: *BountyTextStyle) void {
        ranges_mod.clamp(BountyTextStyle, self);
    }

    pub const Wire = wire.Wire(BountyTextStyle);
};

/// The CPU, RAM and VRAM text; resources holds how often they're sampled.
pub const ResourcesTextStyle = struct {
    shown: bool = false,
    show_cpu: bool = true,
    show_ram: bool = true,
    show_vram: bool = true,
    color: u32 = 0xFFFFFFFF,
    bg_color: u32 = 0xE6000000,
    font_size: i32 = types.DEFAULT_FONT_SIZE,
    font_name: []const u8 = types.DEFAULT_FONT,
    font_weight: types.FontWeight = .Regular,
    position: types.TextPosition = .LeftCenter,
    offset_x: i32 = 0,
    offset_y: i32 = 0,

    pub const ranges = .{
        .font_size = ranges_mod.FONT_SIZE,
        .offset_x = ranges_mod.TEXT_OFFSET,
        .offset_y = ranges_mod.TEXT_OFFSET,
    };

    pub fn validate(self: *ResourcesTextStyle) void {
        ranges_mod.clamp(ResourcesTextStyle, self);
    }

    pub const Wire = wire.Wire(ResourcesTextStyle);
};

/// The ping text; ping holds how often clients are pinged.
pub const PingTextStyle = struct {
    shown: bool = false,
    color: u32 = 0xFFFFFFFF,
    bg_color: u32 = 0xE6000000,
    font_size: i32 = types.DEFAULT_FONT_SIZE,
    font_name: []const u8 = types.DEFAULT_FONT,
    font_weight: types.FontWeight = .Regular,
    position: types.TextPosition = .RightCenter,
    offset_x: i32 = 0,
    offset_y: i32 = 24,

    pub const ranges = .{
        .font_size = ranges_mod.FONT_SIZE,
        .offset_x = ranges_mod.TEXT_OFFSET,
        .offset_y = ranges_mod.TEXT_OFFSET,
    };

    pub fn validate(self: *PingTextStyle) void {
        ranges_mod.clamp(PingTextStyle, self);
    }

    pub const Wire = wire.Wire(PingTextStyle);
};

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

    /// Off skips the DWM preview, leaving a blankFill under the overlay.
    showLivePreview: bool = true,
    blankThumbnailColor: u32 = 0xFF000000,
    /// Fills blank thumbnails with a dark shade of each one's focused border colour, in place of blankThumbnailColor.
    blankDimsBorder: bool = false,

    showBorderWhenFocused: bool = true,
    borderWidth: u8 = 2,
    /// Null follows accentColor, see Config.focusedBorderColor.
    borderColor: ?u32 = null,
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
    characterNameFontName: []const u8 = types.DEFAULT_FONT,
    characterNameFontSize: i32 = types.DEFAULT_FONT_SIZE,
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
    systemNameFontName: []const u8 = types.DEFAULT_FONT,
    systemNameFontSize: i32 = types.DEFAULT_FONT_SIZE,
    systemNameFontWeight: types.FontWeight = .Regular,
    showQuickGroupBadge: bool = true,
    quickGroupBadgeColor: u32 = 0xFF44FF44,
    quickGroupBadgeBgColor: u32 = 0xE6000000,
    quickGroupBadgePosition: types.TextPosition = .RightCenter,
    quickGroupBadgeOffsetX: i32 = 0,
    quickGroupBadgeOffsetY: i32 = 0,
    quickGroupBadgeFontName: []const u8 = types.DEFAULT_FONT,
    quickGroupBadgeFontSize: i32 = types.DEFAULT_FONT_SIZE,
    quickGroupBadgeFontWeight: types.FontWeight = .Regular,
    showSessionTimer: bool = false,
    sessionTimerColor: u32 = 0xFFFFFF,
    sessionTimerBgColor: u32 = 0xE6000000,
    sessionTimerPosition: types.TextPosition = .RightCenter,
    sessionTimerOffsetX: i32 = 0,
    sessionTimerOffsetY: i32 = -24,
    sessionTimerFontName: []const u8 = types.DEFAULT_FONT,
    sessionTimerFontSize: i32 = types.DEFAULT_FONT_SIZE,
    sessionTimerFontWeight: types.FontWeight = .Regular,
    exclusionOverlayStyle: types.ExclusionOverlayStyle = .X,
    exclusionOverlayColor: u32 = 0x33A62222,
    alertText: AlertTextStyle = .{},
    combatText: CombatTextStyle = .{},
    miningText: MiningTextStyle = .{},
    bountyText: BountyTextStyle = .{},
    resourcesText: ResourcesTextStyle = .{},
    pingText: PingTextStyle = .{},
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

    /// A blank thumbnail's fill when its character has no colour of its own.
    pub fn blankFill(self: *const ThumbnailConfig, active_border_color: u32) u32 {
        if (!self.blankDimsBorder) return self.blankThumbnailColor;
        return color_mod.mix(active_border_color, 0xFF000000, BLANK_BORDER_PERCENT);
    }

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
