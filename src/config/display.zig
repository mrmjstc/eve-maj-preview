//! Layout, Client List, History Panel, Map Panel and Intel Panel settings.
const types = @import("types.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");

pub const DisplayConfig = struct {
    startX: i32 = 10,
    startY: i32 = 10,

    /// Gap between unplaced thumbnails, lined up from startX/startY instead of stacking.
    newThumbnailSpacing: i32 = 10,

    viewMode: types.ViewMode = .Thumbnails,
    listViewOrder: types.ListViewOrder = .ConfiguredCharacters,
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
    /// A notification type without a text colour of its own uses this.
    listViewNotificationColor: u32 = 0xFFFFFFFF,
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

    /// The notifInfoPanel fields are the History Panel's.
    showNotifInfoPanel: bool = false,
    notifInfoPanelX: i32 = 10,
    notifInfoPanelY: i32 = 250,
    notifInfoPanelWidth: i32 = 300,
    notifInfoPanelHeight: i32 = 400,
    rememberNotifInfoPanelPosition: bool = true,
    hideNotifInfoPanelWhenNoCharacters: bool = true,
    hideNotifInfoPanelWhenNoEveFocus: bool = false,
    notifInfoPanelHideDebounceMs: u32 = 500,
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
    notifInfoPanelShowChat: bool = true,
    notifInfoPanelShowGeneral: bool = true,

    /// The mapPanel fields are the Map Panel's.
    showMapPanel: bool = false,
    mapPanelX: i32 = 330,
    mapPanelY: i32 = 60,
    mapPanelWidth: i32 = 760,
    mapPanelHeight: i32 = 600,
    rememberMapPanelPosition: bool = true,
    hideMapPanelWhenNoCharacters: bool = false,
    hideMapPanelWhenNoEveFocus: bool = false,
    mapPanelHideDebounceMs: u32 = 500,
    mapPanelOpacity: u8 = 255,
    /// For the names on the map; its header, buttons and tooltips use the History Panel's font.
    mapPanelFontName: []const u8 = "Segoe UI",
    mapPanelFontSize: i32 = 10,
    mapPanelFontWeight: types.FontWeight = .Regular,
    /// CCP's region ID, which outlasts a map update; The Forge by default.
    mapPanelRegionId: u32 = 10000002,
    /// Opens the active client's region whenever it enters another.
    mapPanelFollowActive: bool = true,
    mapPanelMetric: types.MapMetric = .Security,
    /// Asks ESI for kills, jumps and sovereignty while the panel shows.
    mapPanelLiveStats: bool = true,
    /// Off only hides the pins, so turning it back on shows those still live.
    mapPanelShowIntel: bool = true,
    /// How long a new intel pin's halo takes to shrink to its resting size.
    mapPanelIntelShrinkSec: i32 = 60,
    /// Turns a pin yellow when intel calls its system clear; off, those messages leave pins alone.
    mapPanelIntelShowClear: bool = true,

    /// The intelPanel fields are the Intel Panel's; while it's on, every intel report lists there, and intel alerts leave the History Panel.
    showIntelPanel: bool = false,
    /// Draws it as a sidebar inside the Map Panel, which then decides its height, position and when it shows.
    intelPanelAttached: bool = true,
    intelPanelSide: types.PanelSide = .Right,
    intelPanelX: i32 = 1100,
    intelPanelY: i32 = 60,
    intelPanelWidth: i32 = 340,
    /// While detached.
    intelPanelHeight: i32 = 400,
    rememberIntelPanelPosition: bool = true,
    hideIntelPanelWhenNoCharacters: bool = false,
    hideIntelPanelWhenNoEveFocus: bool = false,
    intelPanelHideDebounceMs: u32 = 500,
    intelPanelOpacity: u8 = 255,
    /// Draws each row's system in its name colour, whatever the chat rule's color_system_name says.
    intelPanelColorSystemNames: bool = true,

    /// Manual ignores thumbnailSpaces, so every thumbnail is placed by hand.
    placementMode: types.PlacementMode = .Manual,
    hideThumbnailsDuringRegionSelect: bool = true,

    monitorIndex: ?u32 = null,
    useMonitorWorkArea: bool = true,

    honorSavedPositions: bool = true,

    const SCREEN_X = ranges_mod.SCREEN_X;
    const SCREEN_Y = ranges_mod.SCREEN_Y;
    const SPACING = .{ 0, 200 };
    pub const NOTIFICATION_PANEL_MAX_ROWS = .{ 1, 30 };

    pub const ranges = .{
        .startX = SCREEN_X,
        .startY = SCREEN_Y,
        .newThumbnailSpacing = SPACING,
        .notifInfoPanelX = SCREEN_X,
        .notifInfoPanelY = SCREEN_Y,
        .notifInfoPanelWidth = .{ 100, ranges_mod.MAX_WINDOW_WIDTH },
        .notifInfoPanelHeight = .{ 60, ranges_mod.MAX_WINDOW_HEIGHT },
        .notifInfoPanelMaxRows = NOTIFICATION_PANEL_MAX_ROWS,
        .notifInfoPanelMergeWindowSec = .{ 1, 300 },
        .notifInfoPanelFontSize = ranges_mod.FONT_SIZE,
        .notifInfoPanelOpacity = ranges_mod.OPACITY,
        .mapPanelX = SCREEN_X,
        .mapPanelY = SCREEN_Y,
        .mapPanelWidth = .{ 300, ranges_mod.MAX_WINDOW_WIDTH },
        .mapPanelHeight = .{ 240, ranges_mod.MAX_WINDOW_HEIGHT },
        .mapPanelFontSize = ranges_mod.FONT_SIZE,
        .mapPanelOpacity = ranges_mod.OPACITY,
        .mapPanelIntelShrinkSec = .{ 1, 900 },
        .monitorIndex = .{ 0, 9 },
        .listViewColumns = .{ 1, 6 },
        .listViewColumnWidth = .{ 120, 500 },
        .listViewFontSize = ranges_mod.FONT_SIZE,
        .listViewOpacity = ranges_mod.OPACITY,
        .listViewHideDebounceMs = .{ 0, 5000 },
        .notifInfoPanelHideDebounceMs = .{ 0, 5000 },
        .mapPanelHideDebounceMs = .{ 0, 5000 },
        .intelPanelX = SCREEN_X,
        .intelPanelY = SCREEN_Y,
        .intelPanelWidth = .{ 160, ranges_mod.MAX_WINDOW_WIDTH },
        .intelPanelHeight = .{ 120, ranges_mod.MAX_WINDOW_HEIGHT },
        .intelPanelHideDebounceMs = .{ 0, 5000 },
        .intelPanelOpacity = ranges_mod.OPACITY,
    };

    /// Whether intel lists in the Intel Panel rather than the History Panel: a sidebar needs the map to show in.
    pub fn routesIntelToPanel(self: *const DisplayConfig) bool {
        return self.showIntelPanel and (!self.intelPanelAttached or self.showMapPanel);
    }

    pub fn validate(self: *DisplayConfig) void {
        ranges_mod.clamp(DisplayConfig, self);
    }

    pub const Wire = wire.Wire(DisplayConfig);
};
