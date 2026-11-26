//! Upgrades older settings JSON before it's parsed, so the loaders and the profile importer see the current schema; no I/O.
const std = @import("std");
const values = @import("import/values.zig");
const spaces_mod = @import("spaces.zig");
const wire = @import("wire.zig");

const Value = std.json.Value;

/// Profiles from before this saved positions in DPI-unaware pixels.
pub const DPI_AWARE_VERSION = 2;
/// Profiles from before thumbnailSpaces kept one fit region and a not-logged-in space as display settings.
const SPACES_VERSION = 3;
/// Profiles from before this kept the client list's and panels' settings in display, each name prefixed.
const PANELS_VERSION = 4;
/// Profiles from before this saved the old default amber as the list's active colour and focused border, rather than following the accent.
const FOLLOWS_ACCENT_VERSION = 5;
/// Profiles from before this showed the client list's rates only while the thumbnails' overlay was on.
const LIST_RATES_VERSION = 6;
/// Profiles from before this kept the client list's position in display.startX/startY, the unplaced thumbnails' start.
const LIST_POSITION_VERSION = 7;
/// Profiles from before this kept settings with the view that first showed them; see regroupFromViews.
pub const REGROUP_VERSION = 8;

/// The amber both colours defaulted to before FOLLOWS_ACCENT_VERSION.
const OLD_ACCENT_DEFAULT: u32 = 0xFFD9A441;
/// Section and key of each colour that follows the accent when unset.
const ACCENT_FOLLOWERS = [_]struct { section: []const u8, key: []const u8 }{
    .{ .section = "listView", .key = "activeColor" },
    .{ .section = "thumbnail", .key = "borderColor" },
};

/// Each client list rate's switch, and the overlay section whose `enabled` it used to need.
const LIST_RATES = [_]struct { key: []const u8, overlay: []const u8 }{
    .{ .key = "showIncomingDps", .overlay = "combat" },
    .{ .key = "showOutgoingDps", .overlay = "combat" },
    .{ .key = "showMiningRate", .overlay = "mining" },
    .{ .key = "showBountyRate", .overlay = "bounty" },
};

/// The thumbnail.notifications keys that only style the thumbnail's alert text, which go to thumbnail.alertText; the rest go to notifications.
const ALERT_TEXT_KEYS = [_][]const u8{ "position", "offset_x", "offset_y", "font_name", "font_size", "font_weight", "bg_color" };

/// A tracker's section whose keys, all but `tracking`, move to thumbnail.`text`, its `enabled` as `shown`.
const TEXT_SPLITS = [_]TextSplit{
    .{ .section = "combat", .text = "combatText", .tracking = &.{ "window_seconds", "update_interval_ms", "damage_alert_excluded_weapons" } },
    .{ .section = "mining", .text = "miningText", .tracking = &.{ "window_seconds", "update_interval_ms", "idle_alert_window_seconds", "idle_alert_threshold", "stopped_alert_window_seconds", "m3_rate_unit", "isk_rate_unit" } },
    .{ .section = "bounty", .text = "bountyText", .tracking = &.{ "window_seconds", "update_interval_ms", "isk_rate_unit" } },
    .{ .section = "resources", .text = "resourcesText", .tracking = &.{"update_interval_ms"} },
    .{ .section = "ping", .text = "pingText", .tracking = &.{"update_interval_ms"} },
};

/// The History Panel's settings the Intel Panel used to follow, copied so it keeps looking the same.
const INTEL_LIST_KEYS = [_][]const u8{ "fontName", "fontSize", "fontWeight", "showTimestamp", "mergeEnabled", "mergeWindowSec" };

/// A display setting that moved into its own section under a new name.
const Move = struct { old: []const u8, section: []const u8, new: []const u8 };

const TextSplit = struct { section: []const u8, text: []const u8, tracking: []const []const u8 };

/// A setting that moved from one section to another under a new name.
const SectionMove = struct { from: []const u8, old: []const u8, to: []const u8, new: []const u8 };

const REGROUP_MOVES = [_]SectionMove{
    .{ .from = "mapPanel", .old = "intelShrinkSec", .to = "intel", .new = "shrinkSec" },
    .{ .from = "mapPanel", .old = "intelShowClear", .to = "intel", .new = "showClear" },
};

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
    followAccentFromOldDefault(root);
    try listRatesFromOverlays(arena, root);
    try listPositionFromStart(arena, root);
    try regroupFromViews(arena, root);
}

/// A profile's own chatlog section, from before Log Monitoring was shared by every profile; null when it has none.
pub fn profileChatlog(root: Value) ?Value {
    if (root != .object) return null;
    const section = root.object.get("chatlog") orelse return null;
    return if (section == .object) section else null;
}

/// The global settings already hold the shared chatlog section, so no profile's is taken.
pub fn hasSharedChatlog(global_root: Value) bool {
    return global_root == .object and global_root.object.contains("chatlog");
}

/// Unsets a colour still at the old default, so it follows the accent; one set by hand to anything else stays.
fn followAccentFromOldDefault(root: *Value) void {
    if (root.* != .object) return;
    const version = values.integerAt(root.*, "formatVersion") orelse 1;
    if (version >= FOLLOWS_ACCENT_VERSION) return;
    for (ACCENT_FOLLOWERS) |follower| {
        const section = root.object.getPtr(follower.section) orelse continue;
        if (section.* != .object) continue;
        const text = values.stringAt(section.*, follower.key) orelse continue;
        // Text that isn't a colour can't be the old default.
        const color = wire.parseHexColor(text) catch continue;
        if (color == OLD_ACCENT_DEFAULT) _ = section.object.orderedRemove(follower.key);
    }
}

/// Keeps each list rate shown only where its overlay was on; a hidden one is unset, as the switches now default to hidden.
fn listRatesFromOverlays(arena: std.mem.Allocator, root: *Value) !void {
    if (root.* != .object) return;
    const version = values.integerAt(root.*, "formatVersion") orelse 1;
    if (version >= LIST_RATES_VERSION) return;
    for (LIST_RATES) |rate| {
        const is_overlay_on = values.boolAt(root.object.get(rate.overlay), "enabled") orelse false;
        const was_shown = values.boolAt(root.object.get("listView"), rate.key) orelse true;
        if (is_overlay_on and was_shown) {
            const list_view = try sectionObject(arena, root, "listView") orelse return;
            try list_view.put(arena, rate.key, .{ .bool = true });
        } else if (root.object.getPtr("listView")) |list_view| {
            if (list_view.* == .object) _ = list_view.object.orderedRemove(rate.key);
        }
    }
}

/// Copies, not moves: startX/startY stay where unplaced thumbnails line up.
fn listPositionFromStart(arena: std.mem.Allocator, root: *Value) !void {
    if (root.* != .object) return;
    const version = values.integerAt(root.*, "formatVersion") orelse 1;
    if (version >= LIST_POSITION_VERSION) return;
    const display = root.object.get("display") orelse return;
    if (display != .object) return;
    if (values.get(display, "startX") == null and values.get(display, "startY") == null) return;
    const list_view = try sectionObject(arena, root, "listView") orelse return;
    try copy(arena, list_view, display, "startX", "x");
    try copy(arena, list_view, display, "startY", "y");
}

/// Moves settings out of the view that first showed them; one already in its new section wins, so a part-migrated profile migrates again.
fn regroupFromViews(arena: std.mem.Allocator, root: *Value) !void {
    if (root.* != .object) return;
    const version = values.integerAt(root.*, "formatVersion") orelse 1;
    if (version >= REGROUP_VERSION) return;
    try alertsFromThumbnail(arena, root);
    for (TEXT_SPLITS) |split| try textFromTracker(arena, root, split);
    for (REGROUP_MOVES) |move| {
        const value = values.get(root.object.get(move.from), move.old) orelse continue;
        const section = try sectionObject(arena, root, move.to) orelse continue;
        if (section.get(move.new) == null) try section.put(arena, move.new, value);
        // Looked up again, as making the new section can move the old one.
        if (root.object.getPtr(move.from)) |from| _ = from.object.orderedRemove(move.old);
    }
    const history_panel = root.object.get("historyPanel") orelse return;
    if (history_panel != .object) return;
    const intel_panel = try sectionObject(arena, root, "intelPanel") orelse return;
    for (INTEL_LIST_KEYS) |key| {
        const value = values.get(history_panel, key) orelse continue;
        if (intel_panel.get(key) == null) try intel_panel.put(arena, key, value);
    }
}

/// Splits thumbnail.notifications into notifications and thumbnail.alertText; a key already in its new section wins.
fn alertsFromThumbnail(arena: std.mem.Allocator, root: *Value) !void {
    const old = values.get(root.object.get("thumbnail"), "notifications") orelse return;
    if (old != .object) return;
    const behaviour = try sectionObject(arena, root, "notifications") orelse return;
    // Looked up after making notifications, which can move it.
    const thumbnail = root.object.getPtr("thumbnail") orelse return;
    const alert_text = try objectIn(arena, &thumbnail.object, "alertText") orelse return;
    var it = old.object.iterator();
    while (it.next()) |entry| {
        const section = if (isAlertTextKey(entry.key_ptr.*)) alert_text else behaviour;
        if (section.get(entry.key_ptr.*) == null) try section.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }
    _ = thumbnail.object.orderedRemove("notifications");
}

fn isAlertTextKey(key: []const u8) bool {
    return isListed(&ALERT_TEXT_KEYS, key);
}

/// Moves a rate text's keys out of its tracker's section into thumbnail; a key already there wins.
fn textFromTracker(arena: std.mem.Allocator, root: *Value, split: TextSplit) !void {
    const tracker = root.object.getPtr(split.section) orelse return;
    if (tracker.* != .object) return;
    var moved: std.ArrayList([]const u8) = .empty;
    var it = tracker.object.iterator();
    while (it.next()) |entry| {
        if (!isListed(split.tracking, entry.key_ptr.*)) try moved.append(arena, entry.key_ptr.*);
    }
    if (moved.items.len == 0) return;
    // Copied out first, as making the thumbnail section can move the tracker's.
    const old = tracker.*;
    const thumbnail = try sectionObject(arena, root, "thumbnail") orelse return;
    const text = try objectIn(arena, thumbnail, split.text) orelse return;
    for (moved.items) |key| {
        const new_key = if (std.mem.eql(u8, key, "enabled")) "shown" else key;
        if (text.get(new_key) == null) try text.put(arena, new_key, old.object.get(key).?);
    }
    const section = root.object.getPtr(split.section) orelse return;
    for (moved.items) |key| _ = section.object.orderedRemove(key);
}

fn isListed(list: []const []const u8, key: []const u8) bool {
    for (list) |listed| {
        if (std.mem.eql(u8, listed, key)) return true;
    }
    return false;
}

/// Moves the old fit region and not-logged-in space into thumbnailSpaces.
fn spacesFromDisplay(arena: std.mem.Allocator, root: *Value) !void {
    if (root.* != .object) return;
    const version = values.integerAt(root.*, "formatVersion") orelse 1;
    if (version >= SPACES_VERSION or root.object.get("thumbnailSpaces") != null) return;
    const display = root.object.get("display") orelse return;
    if (display != .object) return;

    var spaces: std.json.Array = .init(arena);
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
    return objectIn(arena, &root.object, name);
}

/// `name`'s object in `parent`, made if missing; null if it holds something else.
fn objectIn(arena: std.mem.Allocator, parent: *std.json.ObjectMap, name: []const u8) !?*std.json.ObjectMap {
    const entry = try parent.getOrPut(arena, name);
    if (!entry.found_existing) entry.value_ptr.* = .{ .object = .empty };
    if (entry.value_ptr.* != .object) return null;
    return &entry.value_ptr.object;
}

fn copy(arena: std.mem.Allocator, section: *std.json.ObjectMap, display: Value, from: []const u8, to: []const u8) !void {
    const value = values.get(display, from) orelse return;
    try section.put(arena, to, value);
}

const testing = std.testing;

fn migrated(arena: std.mem.Allocator, json: []const u8) !Value {
    var root = try std.json.parseFromSliceLeaky(Value, arena, json, .{});
    try profile(arena, &root);
    return root;
}

test "an old fit region becomes an enabled catch-all space, login-screen clients included, with its settings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
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
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
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
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":2,"display":{"layoutMode":"Custom","regionX":0,"regionY":0,"regionWidth":800,"regionHeight":400}}
    );
    const space = root.object.get("thumbnailSpaces").?.array.items[0];
    try testing.expectEqual(false, values.boolAt(space, "enabled").?);
}

test "a region missing a coordinate and a current profile are left alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
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
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":3,"display":{},"thumbnailSpaces":[{"name":"Off","enabled":false},{"name":"On"}]}
    );
    try testing.expectEqualStrings("ThumbnailSpaces", values.stringAt(root.object.get("display").?, "placementMode").?);
}

test "a saved placementMode, or no enabled space, is left alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
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
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
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

test "the old default amber is unset so it follows the accent, and a picked colour stays" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":4,"listView":{"activeColor":"0xFFD9A441"},"thumbnail":{"borderColor":"0xFF112233"}}
    );
    try testing.expect(values.get(root.object.get("listView").?, "activeColor") == null);
    try testing.expectEqualStrings("0xFF112233", values.stringAt(root.object.get("thumbnail").?, "borderColor").?);
}

test "a current profile's amber is a picked colour and stays" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":5,"listView":{"activeColor":"0xFFD9A441"}}
    );
    try testing.expectEqualStrings("0xFFD9A441", values.stringAt(root.object.get("listView").?, "activeColor").?);
}

test "an old profile's list rates stay shown only where their overlay was on" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":5,"combat":{"enabled":true},"mining":{"enabled":false},"listView":{"showOutgoingDps":false}}
    );
    const list_view = root.object.get("listView").?;
    try testing.expectEqual(true, values.boolAt(list_view, "showIncomingDps").?);
    try testing.expect(values.get(list_view, "showOutgoingDps") == null);
    try testing.expect(values.get(list_view, "showMiningRate") == null);
    try testing.expect(values.get(list_view, "showBountyRate") == null);
    const current = try migrated(arena.allocator(),
        \\{"formatVersion":6,"listView":{"showMiningRate":true}}
    );
    try testing.expectEqual(true, values.boolAt(current.object.get("listView").?, "showMiningRate").?);
}

test "an old profile's client list takes its position from the thumbnails' start position, and a current profile's is left alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":6,"display":{"startX":120,"startY":340}}
    );
    try testing.expectEqual(@as(i64, 120), values.integerAt(root.object.get("listView").?, "x").?);
    try testing.expectEqual(@as(i64, 340), values.integerAt(root.object.get("listView").?, "y").?);
    try testing.expectEqual(@as(i64, 120), values.integerAt(root.object.get("display").?, "startX").?);
    const current = try migrated(arena.allocator(),
        \\{"formatVersion":7,"display":{"startX":120},"listView":{"x":5}}
    );
    try testing.expectEqual(@as(i64, 5), values.integerAt(current.object.get("listView").?, "x").?);
}

test "a panel setting already in its section wins, and a current profile's display is left alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
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

test "an old profile's alerts split into notifications and thumbnail.alertText" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":7,"thumbnail":{"width":300,"notifications":{"enabled":false,"color":"0xFF112233","font_size":14,"bg_color":"0x80000000","tts_volume":40,"type_configs":{"FleetInvite":{"enabled":false}}}}}
    );
    const notifications = root.object.get("notifications").?;
    try testing.expectEqual(false, values.boolAt(notifications, "enabled").?);
    try testing.expectEqualStrings("0xFF112233", values.stringAt(notifications, "color").?);
    try testing.expectEqual(@as(i64, 40), values.integerAt(notifications, "tts_volume").?);
    try testing.expect(values.get(values.get(notifications, "type_configs"), "FleetInvite") != null);
    try testing.expect(values.get(notifications, "font_size") == null);
    const thumbnail = root.object.get("thumbnail").?;
    const alert_text = values.get(thumbnail, "alertText").?;
    try testing.expectEqual(@as(i64, 14), values.integerAt(alert_text, "font_size").?);
    try testing.expectEqualStrings("0x80000000", values.stringAt(alert_text, "bg_color").?);
    try testing.expect(values.get(alert_text, "color") == null);
    try testing.expect(values.get(thumbnail, "notifications") == null);
    try testing.expectEqual(@as(i64, 300), values.integerAt(thumbnail, "width").?);
}

test "an alert setting already in its new section wins, and a regrouped profile's thumbnail alerts are left alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const both = try migrated(arena.allocator(),
        \\{"formatVersion":7,"thumbnail":{"notifications":{"tts_volume":40,"font_size":14},"alertText":{"font_size":20}},"notifications":{"tts_volume":70}}
    );
    try testing.expectEqual(@as(i64, 70), values.integerAt(both.object.get("notifications").?, "tts_volume").?);
    try testing.expectEqual(@as(i64, 20), values.integerAt(values.get(both.object.get("thumbnail"), "alertText"), "font_size").?);
    const current = try migrated(arena.allocator(),
        \\{"formatVersion":8,"thumbnail":{"notifications":{"tts_volume":40}}}
    );
    try testing.expect(current.object.get("notifications") == null);
}

test "an old profile's combat and mining texts move to thumbnail, enabled as shown, and the tracking stays" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":7,"combat":{"enabled":true,"window_seconds":30,"incoming_font_size":16,"damage_alert_excluded_weapons":"Smartbomb"},
        \\"mining":{"enabled":true,"show_isk_rate":false,"m3_rate_unit":"minute","idle_alert_threshold":3,"offset_x":12}}
    );
    const thumbnail = root.object.get("thumbnail").?;
    const combat_text = values.get(thumbnail, "combatText").?;
    try testing.expectEqual(true, values.boolAt(combat_text, "shown").?);
    try testing.expectEqual(@as(i64, 16), values.integerAt(combat_text, "incoming_font_size").?);
    const combat = root.object.get("combat").?;
    try testing.expect(values.get(combat, "enabled") == null);
    try testing.expect(values.get(combat, "incoming_font_size") == null);
    try testing.expectEqual(@as(i64, 30), values.integerAt(combat, "window_seconds").?);
    try testing.expectEqualStrings("Smartbomb", values.stringAt(combat, "damage_alert_excluded_weapons").?);
    const mining_text = values.get(thumbnail, "miningText").?;
    try testing.expectEqual(false, values.boolAt(mining_text, "show_isk_rate").?);
    try testing.expectEqual(@as(i64, 12), values.integerAt(mining_text, "offset_x").?);
    const mining = root.object.get("mining").?;
    try testing.expectEqualStrings("minute", values.stringAt(mining, "m3_rate_unit").?);
    try testing.expectEqual(@as(i64, 3), values.integerAt(mining, "idle_alert_threshold").?);
    try testing.expect(values.get(mining, "show_isk_rate") == null);
}

test "an old profile's bounty, resources and ping texts move to thumbnail, keeping their sampling" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":7,"bounty":{"enabled":true,"isk_rate_unit":"minute","position":"Center"},
        \\"resources":{"enabled":true,"show_ram":false,"update_interval_ms":5000},"ping":{"enabled":true,"offset_y":30}}
    );
    const thumbnail = root.object.get("thumbnail").?;
    try testing.expectEqualStrings("Center", values.stringAt(values.get(thumbnail, "bountyText"), "position").?);
    try testing.expectEqualStrings("minute", values.stringAt(root.object.get("bounty"), "isk_rate_unit").?);
    const resources_text = values.get(thumbnail, "resourcesText").?;
    try testing.expectEqual(true, values.boolAt(resources_text, "shown").?);
    try testing.expectEqual(false, values.boolAt(resources_text, "show_ram").?);
    try testing.expectEqual(@as(i64, 5000), values.integerAt(root.object.get("resources"), "update_interval_ms").?);
    try testing.expectEqual(@as(i64, 30), values.integerAt(values.get(thumbnail, "pingText"), "offset_y").?);
    try testing.expect(values.get(root.object.get("ping"), "enabled") == null);
}

test "a rate text setting already in thumbnail wins over its tracker's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":7,"combat":{"enabled":true},"thumbnail":{"combatText":{"shown":false}}}
    );
    try testing.expectEqual(false, values.boolAt(values.get(root.object.get("thumbnail"), "combatText"), "shown").?);
    try testing.expect(values.get(root.object.get("combat"), "enabled") == null);
}

test "an old profile's intel pin settings move out of mapPanel, and a value already in intel wins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":7,"mapPanel":{"intelShrinkSec":120,"intelShowClear":false,"showIntel":true}}
    );
    try testing.expectEqual(@as(i64, 120), values.integerAt(root.object.get("intel").?, "shrinkSec").?);
    try testing.expectEqual(false, values.boolAt(root.object.get("intel").?, "showClear").?);
    try testing.expect(values.get(root.object.get("mapPanel").?, "intelShrinkSec") == null);
    try testing.expectEqual(true, values.boolAt(root.object.get("mapPanel").?, "showIntel").?);
    const both = try migrated(arena.allocator(),
        \\{"formatVersion":7,"mapPanel":{"intelShrinkSec":120},"intel":{"shrinkSec":60}}
    );
    try testing.expectEqual(@as(i64, 60), values.integerAt(both.object.get("intel").?, "shrinkSec").?);
    try testing.expect(values.get(both.object.get("mapPanel").?, "intelShrinkSec") == null);
}

test "a display-era intel setting reaches intel through mapPanel" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":3,"display":{"mapPanelIntelShrinkSec":45}}
    );
    try testing.expectEqual(@as(i64, 45), values.integerAt(root.object.get("intel").?, "shrinkSec").?);
}

test "the Intel Panel takes a copy of the History Panel's list settings, keeping any of its own" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":7,"historyPanel":{"fontSize":14,"showTimestamp":true,"mergeWindowSec":30,"maxRows":20},"intelPanel":{"mergeWindowSec":5}}
    );
    const intel_panel = root.object.get("intelPanel").?;
    try testing.expectEqual(@as(i64, 14), values.integerAt(intel_panel, "fontSize").?);
    try testing.expectEqual(true, values.boolAt(intel_panel, "showTimestamp").?);
    try testing.expectEqual(@as(i64, 5), values.integerAt(intel_panel, "mergeWindowSec").?);
    try testing.expect(values.get(intel_panel, "maxRows") == null);
    try testing.expectEqual(@as(i64, 14), values.integerAt(root.object.get("historyPanel").?, "fontSize").?);
}

test "a regrouped profile's intel settings are left alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try migrated(arena.allocator(),
        \\{"formatVersion":8,"mapPanel":{"intelShrinkSec":120},"historyPanel":{"fontSize":14}}
    );
    try testing.expect(root.object.get("intel") == null);
    try testing.expect(root.object.get("intelPanel") == null);
}

test "a profile's chatlog section is found, and nothing else passes for one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const with = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "{\"chatlog\":{\"enabled\":true}}", .{});
    try testing.expect(values.boolAt(profileChatlog(with).?, "enabled").?);
    const without = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "{\"chatlog\":true}", .{});
    try testing.expect(profileChatlog(without) == null);
}

test "global settings saved before Log Monitoring was shared have no chatlog section" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const older = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "{\"lastUsedProfile\":\"default.json\"}", .{});
    try testing.expect(!hasSharedChatlog(older));
    const newer = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "{\"chatlog\":{}}", .{});
    try testing.expect(hasSharedChatlog(newer));
}
