//! Upgrades an older profile's JSON before it's parsed, so the profile loader and the profile importer both see the current schema; no I/O.
const std = @import("std");
const values = @import("import/values.zig");
const spaces_mod = @import("spaces.zig");

const Value = std.json.Value;

/// Profiles from before this saved positions in DPI-unaware pixels.
pub const DPI_AWARE_VERSION = 2;
/// Profiles from before thumbnailSpaces kept one fit region and a not-logged-in space as display settings.
pub const SPACES_VERSION = 3;
/// Profiles from before this kept the client list's and panels' settings in display, each name prefixed.
pub const PANELS_VERSION = 4;

/// A display setting that moved into its own section under a new name.
const Move = struct { old: []const u8, section: []const u8, new: []const u8 };

const PANEL_MOVES = [_]Move{
    .{ .old = "listViewOrder", .section = "listView", .new = "order" },
    .{ .old = "rememberListViewPosition", .section = "listView", .new = "rememberPosition" },
    .{ .old = "listViewAlwaysOnTop", .section = "listView", .new = "alwaysOnTop" },
    .{ .old = "listViewOpacity", .section = "listView", .new = "opacity" },
    .{ .old = "listViewColumns", .section = "listView", .new = "columns" },
    .{ .old = "listViewColumnWidth", .section = "listView", .new = "columnWidth" },
    .{ .old = "listViewFontName", .section = "listView", .new = "fontName" },
    .{ .old = "listViewFontSize", .section = "listView", .new = "fontSize" },
    .{ .old = "listViewFontWeight", .section = "listView", .new = "fontWeight" },
    .{ .old = "listViewIndicatorStyle", .section = "listView", .new = "indicatorStyle" },
    .{ .old = "listViewShowSystemName", .section = "listView", .new = "showSystemName" },
    .{ .old = "listViewSystemNameColor", .section = "listView", .new = "systemNameColor" },
    .{ .old = "listViewUseUniqueSystemColors", .section = "listView", .new = "useUniqueSystemColors" },
    .{ .old = "listViewUseUniqueCharacterNameColors", .section = "listView", .new = "useUniqueCharacterNameColors" },
    .{ .old = "listViewActiveColor", .section = "listView", .new = "activeColor" },
    .{ .old = "listViewUseUniqueActiveColors", .section = "listView", .new = "useUniqueActiveColors" },
    .{ .old = "listViewShowNotifications", .section = "listView", .new = "showNotifications" },
    .{ .old = "listViewNotificationColor", .section = "listView", .new = "notificationColor" },
    .{ .old = "listViewShowIncomingDps", .section = "listView", .new = "showIncomingDps" },
    .{ .old = "listViewShowIncomingPrefix", .section = "listView", .new = "showIncomingPrefix" },
    .{ .old = "listViewIncomingDpsColor", .section = "listView", .new = "incomingDpsColor" },
    .{ .old = "listViewShowOutgoingDps", .section = "listView", .new = "showOutgoingDps" },
    .{ .old = "listViewShowOutgoingPrefix", .section = "listView", .new = "showOutgoingPrefix" },
    .{ .old = "listViewOutgoingDpsColor", .section = "listView", .new = "outgoingDpsColor" },
    .{ .old = "listViewShowMiningRate", .section = "listView", .new = "showMiningRate" },
    .{ .old = "listViewShowMiningPrefix", .section = "listView", .new = "showMiningPrefix" },
    .{ .old = "listViewMiningRateColor", .section = "listView", .new = "miningRateColor" },
    .{ .old = "listViewShowBountyRate", .section = "listView", .new = "showBountyRate" },
    .{ .old = "listViewShowBountyPrefix", .section = "listView", .new = "showBountyPrefix" },
    .{ .old = "listViewBountyRateColor", .section = "listView", .new = "bountyRateColor" },
    .{ .old = "listViewHideWhenNoEveFocus", .section = "listView", .new = "hideWhenNoEveFocus" },
    .{ .old = "listViewHideDebounceMs", .section = "listView", .new = "hideDebounceMs" },
    .{ .old = "showNotifInfoPanel", .section = "historyPanel", .new = "show" },
    .{ .old = "notifInfoPanelX", .section = "historyPanel", .new = "x" },
    .{ .old = "notifInfoPanelY", .section = "historyPanel", .new = "y" },
    .{ .old = "notifInfoPanelWidth", .section = "historyPanel", .new = "width" },
    .{ .old = "notifInfoPanelHeight", .section = "historyPanel", .new = "height" },
    .{ .old = "rememberNotifInfoPanelPosition", .section = "historyPanel", .new = "rememberPosition" },
    .{ .old = "notifInfoPanelAlwaysOnTop", .section = "historyPanel", .new = "alwaysOnTop" },
    .{ .old = "hideNotifInfoPanelWhenNoCharacters", .section = "historyPanel", .new = "hideWhenNoCharacters" },
    .{ .old = "hideNotifInfoPanelWhenNoEveFocus", .section = "historyPanel", .new = "hideWhenNoEveFocus" },
    .{ .old = "notifInfoPanelHideDebounceMs", .section = "historyPanel", .new = "hideDebounceMs" },
    .{ .old = "notifInfoPanelOpacity", .section = "historyPanel", .new = "opacity" },
    .{ .old = "notifInfoPanelFontName", .section = "historyPanel", .new = "fontName" },
    .{ .old = "notifInfoPanelFontSize", .section = "historyPanel", .new = "fontSize" },
    .{ .old = "notifInfoPanelFontWeight", .section = "historyPanel", .new = "fontWeight" },
    .{ .old = "notifInfoPanelMaxRows", .section = "historyPanel", .new = "maxRows" },
    .{ .old = "notifInfoPanelShowTimestamp", .section = "historyPanel", .new = "showTimestamp" },
    .{ .old = "notifInfoPanelMergeEnabled", .section = "historyPanel", .new = "mergeEnabled" },
    .{ .old = "notifInfoPanelMergeWindowSec", .section = "historyPanel", .new = "mergeWindowSec" },
    .{ .old = "notifInfoPanelShowCategoryFilters", .section = "historyPanel", .new = "showCategoryFilters" },
    .{ .old = "notifInfoPanelShowFleet", .section = "historyPanel", .new = "showFleet" },
    .{ .old = "notifInfoPanelShowMining", .section = "historyPanel", .new = "showMining" },
    .{ .old = "notifInfoPanelShowCombat", .section = "historyPanel", .new = "showCombat" },
    .{ .old = "notifInfoPanelShowNavigation", .section = "historyPanel", .new = "showNavigation" },
    .{ .old = "notifInfoPanelShowChat", .section = "historyPanel", .new = "showChat" },
    .{ .old = "notifInfoPanelShowGeneral", .section = "historyPanel", .new = "showGeneral" },
    .{ .old = "showMapPanel", .section = "mapPanel", .new = "show" },
    .{ .old = "mapPanelX", .section = "mapPanel", .new = "x" },
    .{ .old = "mapPanelY", .section = "mapPanel", .new = "y" },
    .{ .old = "mapPanelWidth", .section = "mapPanel", .new = "width" },
    .{ .old = "mapPanelHeight", .section = "mapPanel", .new = "height" },
    .{ .old = "mapPanelAlwaysOnTop", .section = "mapPanel", .new = "alwaysOnTop" },
    .{ .old = "rememberMapPanelPosition", .section = "mapPanel", .new = "rememberPosition" },
    .{ .old = "hideMapPanelWhenNoCharacters", .section = "mapPanel", .new = "hideWhenNoCharacters" },
    .{ .old = "hideMapPanelWhenNoEveFocus", .section = "mapPanel", .new = "hideWhenNoEveFocus" },
    .{ .old = "mapPanelHideDebounceMs", .section = "mapPanel", .new = "hideDebounceMs" },
    .{ .old = "mapPanelOpacity", .section = "mapPanel", .new = "opacity" },
    .{ .old = "mapPanelFontName", .section = "mapPanel", .new = "fontName" },
    .{ .old = "mapPanelFontSize", .section = "mapPanel", .new = "fontSize" },
    .{ .old = "mapPanelFontWeight", .section = "mapPanel", .new = "fontWeight" },
    .{ .old = "mapPanelRegionId", .section = "mapPanel", .new = "regionId" },
    .{ .old = "mapPanelExtraRegionId1", .section = "mapPanel", .new = "extraRegionId1" },
    .{ .old = "mapPanelExtraRegionId2", .section = "mapPanel", .new = "extraRegionId2" },
    .{ .old = "mapPanelExtraRegionId3", .section = "mapPanel", .new = "extraRegionId3" },
    .{ .old = "mapPanelFollowActive", .section = "mapPanel", .new = "followActive" },
    .{ .old = "mapPanelMetric", .section = "mapPanel", .new = "metric" },
    .{ .old = "mapPanelShowCharacterNames", .section = "mapPanel", .new = "showCharacterNames" },
    .{ .old = "mapPanelLiveStats", .section = "mapPanel", .new = "liveStats" },
    .{ .old = "mapPanelShowStorms", .section = "mapPanel", .new = "showStorms" },
    .{ .old = "mapPanelShowIncursions", .section = "mapPanel", .new = "showIncursions" },
    .{ .old = "mapPanelShowIntel", .section = "mapPanel", .new = "showIntel" },
    .{ .old = "mapPanelIntelShrinkSec", .section = "mapPanel", .new = "intelShrinkSec" },
    .{ .old = "mapPanelIntelShowClear", .section = "mapPanel", .new = "intelShowClear" },
    .{ .old = "mapPanelRoutePreference", .section = "mapPanel", .new = "routePreference" },
    .{ .old = "mapPanelRouteAnsiblex", .section = "mapPanel", .new = "routeAnsiblex" },
    .{ .old = "mapPanelRouteEveryWaypoint", .section = "mapPanel", .new = "routeEveryWaypoint" },
    .{ .old = "mapPanelRouteAvoidZone1", .section = "mapPanel", .new = "routeAvoidZone1" },
    .{ .old = "mapPanelRouteAvoidZone2", .section = "mapPanel", .new = "routeAvoidZone2" },
    .{ .old = "mapPanelRouteAvoidZone3", .section = "mapPanel", .new = "routeAvoidZone3" },
    .{ .old = "mapPanelRouteAvoidZone4", .section = "mapPanel", .new = "routeAvoidZone4" },
    .{ .old = "mapPanelRouteAvoidZone5", .section = "mapPanel", .new = "routeAvoidZone5" },
    .{ .old = "showIntelPanel", .section = "intelPanel", .new = "show" },
    .{ .old = "intelPanelAttached", .section = "intelPanel", .new = "attached" },
    .{ .old = "intelPanelSide", .section = "intelPanel", .new = "side" },
    .{ .old = "intelPanelX", .section = "intelPanel", .new = "x" },
    .{ .old = "intelPanelY", .section = "intelPanel", .new = "y" },
    .{ .old = "intelPanelWidth", .section = "intelPanel", .new = "width" },
    .{ .old = "intelPanelHeight", .section = "intelPanel", .new = "height" },
    .{ .old = "rememberIntelPanelPosition", .section = "intelPanel", .new = "rememberPosition" },
    .{ .old = "intelPanelAlwaysOnTop", .section = "intelPanel", .new = "alwaysOnTop" },
    .{ .old = "hideIntelPanelWhenNoCharacters", .section = "intelPanel", .new = "hideWhenNoCharacters" },
    .{ .old = "hideIntelPanelWhenNoEveFocus", .section = "intelPanel", .new = "hideWhenNoEveFocus" },
    .{ .old = "intelPanelHideDebounceMs", .section = "intelPanel", .new = "hideDebounceMs" },
    .{ .old = "intelPanelOpacity", .section = "intelPanel", .new = "opacity" },
    .{ .old = "intelPanelColorSystemNames", .section = "intelPanel", .new = "colorSystemNames" },
};

/// A profile already on the current schema is left alone.
pub fn profile(arena: std.mem.Allocator, root: *Value) !void {
    try spacesFromDisplay(arena, root);
    try placementModeFromSpaces(arena, root);
    try panelsFromDisplay(arena, root);
}

/// Moves the old fit region and not-logged-in space into thumbnailSpaces.
fn spacesFromDisplay(arena: std.mem.Allocator, root: *Value) !void {
    if (root.* != .object) return;
    const version = values.integerAt(root.*, "formatVersion") orelse 1;
    if (version >= SPACES_VERSION or root.object.get("thumbnailSpaces") != null) return;
    const display = root.object.get("display") orelse return;
    if (display != .object) return;

    var spaces = std.json.Array.init(arena);
    // First, so a client at the login screen keeps landing in its own space ahead of the catch-all.
    if (try rectFields(arena, display, "notLoggedInSpaceX", "notLoggedInSpaceY", "notLoggedInSpaceWidth", "notLoggedInSpaceHeight")) |fields| {
        var space = fields;
        try space.put(arena, "name", .{ .string = spaces_mod.LOGIN_SCREEN_NAME });
        try space.put(arena, "enabled", .{ .bool = values.boolAt(display, "notLoggedInSpaceEnabled") orelse false });
        try space.put(arena, "holdsLoginScreen", .{ .bool = true });
        try copy(arena, &space, display, "notLoggedInSpaceSpacing", "spacing");
        try copy(arena, &space, display, "notLoggedInSpaceLimitToThumbnailSize", "limitToThumbnailSize");
        try copy(arena, &space, display, "regionFitDirection", "direction");
        try spaces.append(.{ .object = space });
    }
    if (try rectFields(arena, display, "regionX", "regionY", "regionWidth", "regionHeight")) |fields| {
        var space = fields;
        const layout_mode = values.stringAt(display, "layoutMode") orelse "";
        try space.put(arena, "name", .{ .string = "Everyone" });
        try space.put(arena, "enabled", .{ .bool = std.mem.eql(u8, layout_mode, "RegionFit") });
        try space.put(arena, "takesUnassigned", .{ .bool = true });
        try space.put(arena, "takesLoginScreen", .{ .bool = true });
        try copy(arena, &space, display, "spacing", "spacing");
        try copy(arena, &space, display, "regionFitLimitToThumbnailSize", "limitToThumbnailSize");
        try copy(arena, &space, display, "regionFitDirection", "direction");
        try copy(arena, &space, display, "regionFitOrder", "order");
        try spaces.append(.{ .object = space });
    }
    if (spaces.items.len == 0) return;
    try root.object.put(arena, "thumbnailSpaces", .{ .array = spaces });
}

/// A new space object holding the region's x/y/width/height, or null unless all four are numbers.
fn rectFields(arena: std.mem.Allocator, display: Value, comptime x: []const u8, comptime y: []const u8, comptime width: []const u8, comptime height: []const u8) !?std.json.ObjectMap {
    const names = [_][]const u8{ x, y, width, height };
    const keys = [_][]const u8{ "x", "y", "width", "height" };
    var space: std.json.ObjectMap = .empty;
    for (names, keys) |name, key| {
        const value = values.integerAt(display, name) orelse return null;
        try space.put(arena, key, .{ .integer = value });
    }
    return space;
}

/// Before placementMode, any enabled space placed thumbnails, so a profile with one keeps them placed.
fn placementModeFromSpaces(arena: std.mem.Allocator, root: *Value) !void {
    if (root.* != .object) return;
    const spaces = root.object.get("thumbnailSpaces") orelse return;
    if (spaces != .array) return;
    const display = root.object.getPtr("display") orelse return;
    if (display.* != .object or display.object.get("placementMode") != null) return;
    for (spaces.array.items) |space| {
        if (!(values.boolAt(space, "enabled") orelse true)) continue;
        try display.object.put(arena, "placementMode", .{ .string = "ThumbnailSpaces" });
        return;
    }
}

/// Moves the client list's and panels' settings out of display; one already in its section wins.
fn panelsFromDisplay(arena: std.mem.Allocator, root: *Value) !void {
    if (root.* != .object) return;
    const version = values.integerAt(root.*, "formatVersion") orelse 1;
    if (version >= PANELS_VERSION) return;
    const display = root.object.get("display") orelse return;
    if (display != .object) return;
    for (PANEL_MOVES) |move| {
        const value = values.get(display, move.old) orelse continue;
        const section = try sectionObject(arena, root, move.section) orelse continue;
        if (section.get(move.new) == null) try section.put(arena, move.new, value);
    }
}

/// `name`'s object in `root`, made if missing; null if it holds something else.
fn sectionObject(arena: std.mem.Allocator, root: *Value, name: []const u8) !?*std.json.ObjectMap {
    const entry = try root.object.getOrPut(arena, name);
    if (!entry.found_existing) entry.value_ptr.* = .{ .object = .empty };
    if (entry.value_ptr.* != .object) return null;
    return &entry.value_ptr.object;
}

fn copy(arena: std.mem.Allocator, space: *std.json.ObjectMap, display: Value, from: []const u8, to: []const u8) !void {
    const value = values.get(display, from) orelse return;
    try space.put(arena, to, value);
}

const testing = std.testing;

fn migrated(arena: std.mem.Allocator, json: []const u8) !Value {
    var root = try std.json.parseFromSliceLeaky(Value, arena, json, .{});
    try profile(arena, &root);
    return root;
}

test "an old fit region becomes an enabled catch-all space, login-screen clients included, with its settings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":2,"display":{"layoutMode":"RegionFit","regionX":10,"regionY":20,"regionWidth":300,"regionHeight":200,
        \\"spacing":6,"regionFitOrder":"HotkeyGroups","regionFitDirection":"ColumnFirst_TTB_LTR","regionFitLimitToThumbnailSize":true}}
    );
    const spaces = root.object.get("thumbnailSpaces").?.array.items;
    try testing.expectEqual(@as(usize, 1), spaces.len);
    const space = spaces[0];
    try testing.expectEqualStrings("Everyone", values.stringAt(space, "name").?);
    try testing.expectEqual(true, values.boolAt(space, "enabled").?);
    try testing.expectEqual(true, values.boolAt(space, "takesUnassigned").?);
    try testing.expectEqual(true, values.boolAt(space, "takesLoginScreen").?);
    try testing.expectEqual(@as(i64, 300), values.integerAt(space, "width").?);
    try testing.expectEqual(@as(i64, 6), values.integerAt(space, "spacing").?);
    try testing.expectEqualStrings("HotkeyGroups", values.stringAt(space, "order").?);
    try testing.expectEqualStrings("ColumnFirst_TTB_LTR", values.stringAt(space, "direction").?);
    try testing.expectEqual(true, values.boolAt(space, "limitToThumbnailSize").?);
}

test "the not-logged-in space comes first and holds the login screen" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":2,"display":{"layoutMode":"RegionFit","regionX":0,"regionY":0,"regionWidth":800,"regionHeight":400,
        \\"notLoggedInSpaceEnabled":true,"notLoggedInSpaceX":900,"notLoggedInSpaceY":0,"notLoggedInSpaceWidth":200,"notLoggedInSpaceHeight":100,"notLoggedInSpaceSpacing":4}}
    );
    const spaces = root.object.get("thumbnailSpaces").?.array.items;
    try testing.expectEqual(@as(usize, 2), spaces.len);
    try testing.expectEqualStrings(spaces_mod.LOGIN_SCREEN_NAME, values.stringAt(spaces[0], "name").?);
    try testing.expectEqual(true, values.boolAt(spaces[0], "holdsLoginScreen").?);
    try testing.expectEqual(true, values.boolAt(spaces[0], "enabled").?);
    try testing.expectEqual(@as(i64, 900), values.integerAt(spaces[0], "x").?);
    try testing.expectEqual(@as(i64, 4), values.integerAt(spaces[0], "spacing").?);
    try testing.expectEqualStrings("Everyone", values.stringAt(spaces[1], "name").?);
}

test "a region drawn but left unused migrates as a disabled space" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":2,"display":{"layoutMode":"Custom","regionX":0,"regionY":0,"regionWidth":800,"regionHeight":400}}
    );
    const space = root.object.get("thumbnailSpaces").?.array.items[0];
    try testing.expectEqual(false, values.boolAt(space, "enabled").?);
}

test "a region missing a coordinate and a current profile are left alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const partial = try migrated(arena.allocator(),
        \\{"formatVersion":2,"display":{"layoutMode":"RegionFit","regionX":0,"regionY":0,"regionWidth":800}}
    );
    try testing.expect(partial.object.get("thumbnailSpaces") == null);
    const current = try migrated(arena.allocator(),
        \\{"formatVersion":3,"display":{"layoutMode":"RegionFit","regionX":0,"regionY":0,"regionWidth":800,"regionHeight":400}}
    );
    try testing.expect(current.object.get("thumbnailSpaces") == null);
}

test "a profile with an enabled space from before placementMode uses thumbnail spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":3,"display":{},"thumbnailSpaces":[{"name":"Off","enabled":false},{"name":"On"}]}
    );
    try testing.expectEqualStrings("ThumbnailSpaces", values.stringAt(root.object.get("display").?, "placementMode").?);
}

test "a saved placementMode, or no enabled space, is left alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const saved = try migrated(arena.allocator(),
        \\{"formatVersion":3,"display":{"placementMode":"Manual"},"thumbnailSpaces":[{"name":"On"}]}
    );
    try testing.expectEqualStrings("Manual", values.stringAt(saved.object.get("display").?, "placementMode").?);
    const disabled = try migrated(arena.allocator(),
        \\{"formatVersion":3,"display":{},"thumbnailSpaces":[{"name":"Off","enabled":false}]}
    );
    try testing.expect(values.get(disabled.object.get("display").?, "placementMode") == null);
}

test "the client list's and panels' display settings move into their own sections, renamed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":3,"display":{"startX":5,"listViewColumns":3,"showMapPanel":true,"mapPanelRouteAvoidZone2":true,
        \\"notifInfoPanelX":50,"rememberNotifInfoPanelPosition":false,"hideIntelPanelWhenNoEveFocus":true}}
    );
    try testing.expectEqual(@as(i64, 3), values.integerAt(root.object.get("listView").?, "columns").?);
    try testing.expectEqual(true, values.boolAt(root.object.get("mapPanel").?, "show").?);
    try testing.expectEqual(true, values.boolAt(root.object.get("mapPanel").?, "routeAvoidZone2").?);
    try testing.expectEqual(@as(i64, 50), values.integerAt(root.object.get("historyPanel").?, "x").?);
    try testing.expectEqual(false, values.boolAt(root.object.get("historyPanel").?, "rememberPosition").?);
    try testing.expectEqual(true, values.boolAt(root.object.get("intelPanel").?, "hideWhenNoEveFocus").?);
    try testing.expectEqual(@as(i64, 5), values.integerAt(root.object.get("display").?, "startX").?);
}

test "a panel setting already in its section wins, and a current profile's display is left alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const both = try migrated(arena.allocator(),
        \\{"formatVersion":3,"display":{"listViewColumns":3},"listView":{"columns":2}}
    );
    try testing.expectEqual(@as(i64, 2), values.integerAt(both.object.get("listView").?, "columns").?);
    const current = try migrated(arena.allocator(),
        \\{"formatVersion":4,"display":{"listViewColumns":3}}
    );
    try testing.expect(current.object.get("listView") == null);
}
