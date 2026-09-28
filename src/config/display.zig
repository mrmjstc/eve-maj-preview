//! Layout, Client List and History Panel settings.
const std = @import("std");
const types = @import("../types.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");

pub const DisplayConfig = struct {
    startX: i32 = 10,
    startY: i32 = 10,
    spacing: i32 = 0,

    /// Horizontal gap for thumbnails with no saved position, lined up left-to-right from startX/startY instead of stacking.
    newThumbnailSpacing: i32 = 10,

    viewMode: types.ViewMode = .Thumbnails,
    listViewOrder: types.ListViewOrder = .Tracked,
    rememberListViewPosition: bool = true,
    listViewOpacity: u8 = 255,
    listViewColumns: u32 = 1,
    listViewFontName: []const u8 = "Segoe UI",
    listViewFontSize: i32 = 13,
    listViewFontWeight: types.FontWeight = .Regular,

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

    layoutMode: types.LayoutMode = .Custom,
    regionFitDirection: types.RegionFitDirection = .RowFirst_LTR_TTB,

    regionX: ?i32 = null,
    regionY: ?i32 = null,
    regionWidth: ?i32 = null,
    regionHeight: ?i32 = null,
    regionFitOrder: types.RegionFitOrder = .Characters,
    regionFitReorderLoggedOut: bool = true,
    hideThumbnailsDuringRegionSelect: bool = true,
    regionFitLimitToThumbnailSize: bool = false,

    notLoggedInSpaceEnabled: bool = false,
    notLoggedInSpaceX: ?i32 = null,
    notLoggedInSpaceY: ?i32 = null,
    notLoggedInSpaceWidth: ?i32 = null,
    notLoggedInSpaceHeight: ?i32 = null,
    notLoggedInSpaceSpacing: i32 = 0,
    notLoggedInSpaceLimitToThumbnailSize: bool = false,
    notLoggedInSpaceHideThumbnailsDuringRegionSelect: bool = true,

    monitorIndex: ?u32 = null,
    useMonitorWorkArea: bool = true,

    honorSavedPositions: bool = true,

    const SCREEN_X = ranges_mod.SCREEN_X;
    const SCREEN_Y = ranges_mod.SCREEN_Y;
    const REGION_WIDTH = .{ 1, SCREEN_X[1] - SCREEN_X[0] };
    const REGION_HEIGHT = .{ 1, SCREEN_Y[1] - SCREEN_Y[0] };
    const SPACING = .{ 0, 500 };
    pub const NOTIF_PANEL_MAX_ROWS = .{ 1, 30 };

    pub const ranges = .{
        .startX = SCREEN_X,
        .startY = SCREEN_Y,
        .spacing = SPACING,
        .newThumbnailSpacing = SPACING,
        .notLoggedInSpaceSpacing = SPACING,
        .notifInfoPanelX = SCREEN_X,
        .notifInfoPanelY = SCREEN_Y,
        .notifInfoPanelWidth = .{ 100, ranges_mod.MAX_WINDOW_WIDTH },
        .notifInfoPanelHeight = .{ 60, ranges_mod.MAX_WINDOW_HEIGHT },
        .notifInfoPanelMaxRows = NOTIF_PANEL_MAX_ROWS,
        .notifInfoPanelMergeWindowSec = .{ 1, 300 },
        .notifInfoPanelFontSize = ranges_mod.FONT_SIZE,
        .notifInfoPanelOpacity = ranges_mod.OPACITY,
        .regionX = SCREEN_X,
        .regionY = SCREEN_Y,
        .regionWidth = REGION_WIDTH,
        .regionHeight = REGION_HEIGHT,
        .notLoggedInSpaceX = SCREEN_X,
        .notLoggedInSpaceY = SCREEN_Y,
        .notLoggedInSpaceWidth = REGION_WIDTH,
        .notLoggedInSpaceHeight = REGION_HEIGHT,
        .monitorIndex = .{ 0, 9 },
        .listViewColumns = .{ 1, 15 },
        .listViewFontSize = ranges_mod.FONT_SIZE,
        .listViewOpacity = ranges_mod.OPACITY,
    };

    pub fn validate(self: *DisplayConfig) void {
        ranges_mod.clamp(DisplayConfig, self);
    }

    /// Changed by the running app rather than the dialog, so a preview revert keeps them.
    pub const live_fields = .{
        "startX",
        "startY",
        "notifInfoPanelX",
        "notifInfoPanelY",
        "showNotifInfoPanel",
        "notifInfoPanelShowFleet",
        "notifInfoPanelShowMining",
        "notifInfoPanelShowCombat",
        "notifInfoPanelShowNavigation",
        "notifInfoPanelShowGeneral",
    };

    /// Won't compile for a field missing from `live_fields`, so a revert can't silently undo a runtime change.
    pub fn setLive(self: *DisplayConfig, comptime field: []const u8, value: @FieldType(DisplayConfig, field)) void {
        if (comptime !isLiveField(field)) @compileError(field ++ " is changed at runtime, so it must be listed in DisplayConfig.live_fields");
        @field(self, field) = value;
    }

    fn isLiveField(comptime field: []const u8) bool {
        inline for (live_fields) |live| {
            if (comptime std.mem.eql(u8, live, field)) return true;
        }
        return false;
    }

    pub const Wire = wire.Wire(DisplayConfig);
};
