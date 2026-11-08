//! Client List, History Panel, Map Panel and Intel Panel settings, each its own profile section.
const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");

const SCREEN_X = ranges_mod.SCREEN_X;
const SCREEN_Y = ranges_mod.SCREEN_Y;
const HIDE_DEBOUNCE_MS = .{ 0, 5000 };

/// The client list's position is display.startX and startY.
pub const ListViewConfig = struct {
    order: types.ListViewOrder = .ConfiguredCharacters,
    rememberPosition: bool = true,
    alwaysOnTop: bool = true,
    opacity: u8 = 255,
    columns: u32 = 1,
    columnWidth: i32 = 230,
    fontName: []const u8 = "Segoe UI",
    fontSize: i32 = 13,
    fontWeight: types.FontWeight = .Regular,
    indicatorStyle: types.ListIndicatorStyle = .Dot,
    showSystemName: bool = true,
    systemNameColor: u32 = 0xFF8B8F96,
    useUniqueSystemColors: bool = false,
    useUniqueCharacterNameColors: bool = false,
    /// The active client's dot, row tint and name.
    activeColor: u32 = 0xFFD9A441,
    useUniqueActiveColors: bool = false,
    showNotifications: bool = true,
    /// A notification type without a text colour of its own uses this.
    notificationColor: u32 = 0xFFFFFFFF,
    showIncomingDps: bool = true,
    showIncomingPrefix: bool = true,
    incomingDpsColor: u32 = 0xFFFF4444,
    showOutgoingDps: bool = true,
    showOutgoingPrefix: bool = true,
    outgoingDpsColor: u32 = 0xFF44FF44,
    showMiningRate: bool = true,
    showMiningPrefix: bool = true,
    miningRateColor: u32 = 0xFF44AAFF,
    showBountyRate: bool = true,
    showBountyPrefix: bool = true,
    bountyRateColor: u32 = 0xFFFFD700,
    hideWhenNoEveFocus: bool = false,
    hideDebounceMs: u32 = 500,

    pub const ranges = .{
        .columns = .{ 1, 6 },
        .columnWidth = .{ 120, 500 },
        .fontSize = ranges_mod.FONT_SIZE,
        .opacity = ranges_mod.OPACITY,
        .hideDebounceMs = HIDE_DEBOUNCE_MS,
    };

    pub fn validate(self: *ListViewConfig) void {
        ranges_mod.clamp(ListViewConfig, self);
    }

    pub const Wire = wire.Wire(ListViewConfig);
};

/// The panel listing recent notifications.
pub const HistoryPanelConfig = struct {
    show: bool = false,
    x: i32 = 10,
    y: i32 = 250,
    width: i32 = 300,
    height: i32 = 400,
    rememberPosition: bool = true,
    alwaysOnTop: bool = true,
    hideWhenNoCharacters: bool = true,
    hideWhenNoEveFocus: bool = false,
    hideDebounceMs: u32 = 500,
    opacity: u8 = 255,
    /// Also the detached Intel Panel's, so the panels match.
    fontName: []const u8 = "Segoe UI",
    fontSize: i32 = 13,
    fontWeight: types.FontWeight = .Regular,
    maxRows: i32 = 15,
    showTimestamp: bool = false,
    mergeEnabled: bool = false,
    mergeWindowSec: i32 = 10,
    showCategoryFilters: bool = true,
    showFleet: bool = true,
    showMining: bool = true,
    showCombat: bool = true,
    showNavigation: bool = true,
    showChat: bool = true,
    showGeneral: bool = true,

    pub const MAX_ROWS = .{ 1, 30 };

    pub const ranges = .{
        .x = SCREEN_X,
        .y = SCREEN_Y,
        .width = .{ 100, ranges_mod.MAX_WINDOW_WIDTH },
        .height = .{ 60, ranges_mod.MAX_WINDOW_HEIGHT },
        .maxRows = MAX_ROWS,
        .mergeWindowSec = .{ 1, 300 },
        .fontSize = ranges_mod.FONT_SIZE,
        .opacity = ranges_mod.OPACITY,
        .hideDebounceMs = HIDE_DEBOUNCE_MS,
    };

    pub fn validate(self: *HistoryPanelConfig) void {
        ranges_mod.clamp(HistoryPanelConfig, self);
    }

    pub const Wire = wire.Wire(HistoryPanelConfig);
};

pub const MapPanelConfig = struct {
    show: bool = false,
    x: i32 = 330,
    y: i32 = 60,
    width: i32 = 760,
    height: i32 = 600,
    /// Keeps the map's window above others, game clients included.
    alwaysOnTop: bool = true,
    rememberPosition: bool = true,
    hideWhenNoCharacters: bool = false,
    hideWhenNoEveFocus: bool = false,
    hideDebounceMs: u32 = 500,
    opacity: u8 = 255,
    /// For the names on the map; its cards, buttons and tooltips use the configuration window's font.
    fontName: []const u8 = "Segoe UI",
    fontSize: i32 = 12,
    fontWeight: types.FontWeight = .Regular,
    /// The first region shown, by CCP's ID, which outlasts a map update; The Forge by default.
    regionId: u32 = 10000002,
    /// A second region shown beside regionId, by CCP's ID; 0 for none.
    extraRegionId1: u32 = 0,
    /// A third region shown, by CCP's ID; 0 for none.
    extraRegionId2: u32 = 0,
    /// A fourth region shown, by CCP's ID; 0 for none.
    extraRegionId3: u32 = 0,
    /// Opens the active client's region whenever it leaves those shown.
    followActive: bool = true,
    metric: types.MapMetric = .Security,
    /// Names the characters in a system beside it, as well as ringing it.
    showCharacterNames: bool = true,
    /// Asks ESI and EVE-Scout for the map's figures while the panel shows.
    liveStats: bool = true,
    /// Off only hides them; liveStats is what fetches them.
    showStorms: bool = true,
    /// Off only hides them; liveStats is what fetches them.
    showIncursions: bool = true,
    /// Off only hides them; liveStats is what fetches them.
    showSovTimers: bool = true,
    /// Thera's and Turnur's connections; off only hides them, and liveStats is what fetches them.
    showWormholes: bool = true,
    /// The Eve Stars account's Ansiblex gates; fetched only while shown, with a token.
    showAnsiblex: bool = true,
    /// zKillboard's live kills, followed only while shown.
    showKills: bool = true,
    /// How long a kill stays on the map and in the Kills list.
    killLifetimeMin: i32 = 30,
    /// Off only hides the pins, so turning it back on shows those still live.
    showIntel: bool = true,
    /// How long an intel pin shows, its halo shrinking all the while.
    intelShrinkSec: i32 = 300,
    /// Turns a pin yellow when intel calls its system clear; off, those messages leave pins alone.
    intelShowClear: bool = true,
    routePreference: types.RoutePreference = .Shorter,
    /// Plans routes through the Eve Stars account's Ansiblex gates.
    routeAnsiblex: bool = false,
    /// Sets every system on a route as a waypoint, so the game's autopilot settings can't change the way it flies.
    routeEveryWaypoint: bool = false,
    /// With routeAnsiblex: refuses gates landing within 5 ly of their alliance's capital.
    routeAvoidZone1: bool = false,
    /// With routeAnsiblex: refuses gates landing 5 to 10 ly from their alliance's capital.
    routeAvoidZone2: bool = false,
    /// With routeAnsiblex: refuses gates landing 10 to 15 ly from their alliance's capital.
    routeAvoidZone3: bool = false,
    /// With routeAnsiblex: refuses gates landing 15 to 20 ly from their alliance's capital.
    routeAvoidZone4: bool = false,
    /// With routeAnsiblex: refuses gates landing over 20 ly from their alliance's capital.
    routeAvoidZone5: bool = false,

    /// Also the smallest the map's window can be dragged to; the bars along the bottom keep clear of the zoom controls.
    pub const MIN_WIDTH = 520;
    /// Also the smallest the map's window can be dragged to; the Intel card's least rows keep clear of the map controls.
    pub const MIN_HEIGHT = 330;

    pub const ranges = .{
        .x = SCREEN_X,
        .y = SCREEN_Y,
        .width = .{ MIN_WIDTH, ranges_mod.MAX_WINDOW_WIDTH },
        .height = .{ MIN_HEIGHT, ranges_mod.MAX_WINDOW_HEIGHT },
        .fontSize = ranges_mod.FONT_SIZE,
        .opacity = ranges_mod.OPACITY,
        .intelShrinkSec = .{ 1, 900 },
        .killLifetimeMin = .{ 1, 120 },
        .hideDebounceMs = HIDE_DEBOUNCE_MS,
    };

    pub fn validate(self: *MapPanelConfig) void {
        ranges_mod.clamp(MapPanelConfig, self);
    }

    pub fn killLifetimeSeconds(self: *const MapPanelConfig) i64 {
        return @as(i64, @max(1, self.killLifetimeMin)) * std.time.s_per_min;
    }

    pub fn intelShrinkMs(self: *const MapPanelConfig) u64 {
        return @as(u64, @intCast(@max(0, self.intelShrinkSec))) * std.time.ms_per_s;
    }

    pub const Wire = wire.Wire(MapPanelConfig);
};

pub const IntelPanelConfig = struct {
    show: bool = false,
    /// Draws it as a card inside the Map Panel, which then decides its size, position and when it shows.
    attached: bool = true,
    x: i32 = 1100,
    y: i32 = 60,
    width: i32 = 340,
    /// While detached.
    height: i32 = 400,
    rememberPosition: bool = true,
    /// While detached; inside the map it follows mapPanel.alwaysOnTop.
    alwaysOnTop: bool = true,
    hideWhenNoCharacters: bool = false,
    hideWhenNoEveFocus: bool = false,
    hideDebounceMs: u32 = 500,
    opacity: u8 = 255,
    /// Draws each row's system in its name colour, whatever the chat rule's color_system_name says.
    colorSystemNames: bool = true,

    pub const ranges = .{
        .x = SCREEN_X,
        .y = SCREEN_Y,
        .width = .{ 160, ranges_mod.MAX_WINDOW_WIDTH },
        .height = .{ 120, ranges_mod.MAX_WINDOW_HEIGHT },
        .hideDebounceMs = HIDE_DEBOUNCE_MS,
        .opacity = ranges_mod.OPACITY,
    };

    pub fn validate(self: *IntelPanelConfig) void {
        ranges_mod.clamp(IntelPanelConfig, self);
    }

    pub const Wire = wire.Wire(IntelPanelConfig);
};
