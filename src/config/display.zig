//! Layout, Client List and History Panel settings.
const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");

pub const DisplayConfig = struct {
    startX: i32 = 10,
    startY: i32 = 10,

    /// Horizontal gap for thumbnails with no saved position, lined up left-to-right from startX/startY instead of stacking.
    newThumbnailSpacing: i32 = 10,

    viewMode: types.ViewMode = .Thumbnails,
    listViewOrder: types.ListViewOrder = .Tracked,
    rememberListViewPosition: bool = true,
    listViewOpacity: u8 = 255,
    listViewColumns: u32 = 1,
    listViewColumnWidth: i32 = 230,
    listViewFontName: []const u8 = "Segoe UI",
    listViewFontSize: i32 = 13,
    listViewFontWeight: types.FontWeight = .Regular,
    listViewIndicatorStyle: types.ListIndicatorStyle = .Dot,
    listViewShowSystemName: bool = true,
    listViewSystemNameColor: u32 = 0xFF8B8F96,
    listViewUseUniqueSystemColors: bool = false,
    listViewUseUniqueCharacterNameColors: bool = false,
    /// The active client's dot, row tint and name.
    listViewActiveColor: u32 = 0xFFD9A441,
    listViewUseUniqueActiveColors: bool = false,
    listViewShowNotifications: bool = true,
    listViewShowIncomingDps: bool = true,
    listViewShowIncomingPrefix: bool = true,
    listViewIncomingDpsColor: u32 = 0xFFFF4444,
    listViewShowOutgoingDps: bool = true,
    listViewShowOutgoingPrefix: bool = true,
    listViewOutgoingDpsColor: u32 = 0xFF44FF44,
    listViewShowMiningRate: bool = true,
    listViewShowMiningPrefix: bool = true,
    listViewMiningRateColor: u32 = 0xFF44AAFF,
    listViewShowBountyRate: bool = true,
    listViewShowBountyPrefix: bool = true,
    listViewBountyRateColor: u32 = 0xFFFFD700,
    listViewHideWhenNoEveFocus: bool = false,
    listViewHideDebounceMs: u32 = 500,

    /// The History Panel: a resizable list of recent notifications.
    showNotifInfoPanel: bool = false,
    notifInfoPanelX: i32 = 10,
    notifInfoPanelY: i32 = 250,
    notifInfoPanelWidth: i32 = 300,
    notifInfoPanelHeight: i32 = 400,
    rememberNotifInfoPanelPosition: bool = true,
    hideNotifInfoPanelWhenNoCharacters: bool = true,
    notifInfoPanelOpacity: u8 = 255,
    notifInfoPanelFontName: []const u8 = "Segoe UI",
    notifInfoPanelFontSize: i32 = 13,
    notifInfoPanelFontWeight: types.FontWeight = .Regular,
    notifInfoPanelMaxRows: i32 = 15,
    notifInfoPanelShowTimestamp: bool = false,
    notifInfoPanelMergeEnabled: bool = false,
    notifInfoPanelMergeWindowSec: i32 = 10,
    notifInfoPanelShowCategoryFilters: bool = true,
    notifInfoPanelShowFleet: bool = true,
    notifInfoPanelShowMining: bool = true,
    notifInfoPanelShowCombat: bool = true,
    notifInfoPanelShowNavigation: bool = true,
    notifInfoPanelShowGeneral: bool = true,

    /// Manual ignores thumbnailSpaces, so every thumbnail is placed by hand.
    placementMode: types.PlacementMode = .Manual,
    hideThumbnailsDuringRegionSelect: bool = true,

    monitorIndex: ?u32 = null,
    useMonitorWorkArea: bool = true,

    honorSavedPositions: bool = true,

    const SCREEN_X = ranges_mod.SCREEN_X;
    const SCREEN_Y = ranges_mod.SCREEN_Y;
    const SPACING = .{ 0, 200 };
    pub const NOTIF_PANEL_MAX_ROWS = .{ 1, 30 };

    pub const ranges = .{
        .startX = SCREEN_X,
        .startY = SCREEN_Y,
        .newThumbnailSpacing = SPACING,
        .notifInfoPanelX = SCREEN_X,
        .notifInfoPanelY = SCREEN_Y,
        .notifInfoPanelWidth = .{ 100, ranges_mod.MAX_WINDOW_WIDTH },
        .notifInfoPanelHeight = .{ 60, ranges_mod.MAX_WINDOW_HEIGHT },
        .notifInfoPanelMaxRows = NOTIF_PANEL_MAX_ROWS,
        .notifInfoPanelMergeWindowSec = .{ 1, 300 },
        .notifInfoPanelFontSize = ranges_mod.FONT_SIZE,
        .notifInfoPanelOpacity = ranges_mod.OPACITY,
        .monitorIndex = .{ 0, 9 },
        .listViewColumns = .{ 1, 6 },
        .listViewColumnWidth = .{ 120, 500 },
        .listViewFontSize = ranges_mod.FONT_SIZE,
        .listViewOpacity = ranges_mod.OPACITY,
        .listViewHideDebounceMs = .{ 0, 5000 },
    };

    pub fn validate(self: *DisplayConfig) void {
        ranges_mod.clamp(DisplayConfig, self);
    }

    pub const Wire = wire.Wire(DisplayConfig);
};
