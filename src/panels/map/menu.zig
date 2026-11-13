//! The Map Panel's menus: right-click on a system or region, and Layers; their rows and submenus, and what pressing each asks for; no I/O.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const types = @import("../../config/types.zig");
const glyphs = @import("../glyphs.zig");
const list_look = @import("../list_look.zig");
const popup_look = @import("../popup_look.zig");
const look = @import("look.zig");
const text = @import("text.zig");
const universe = @import("../../map/universe.zig");
const jump_range = @import("../../map/jump_range.zig");
const evestars = @import("../../map/evestars.zig");
const system_links = @import("../../map/system_links.zig");
const fixed_text = @import("../../util/fixed_text.zig");

const FixedText = fixed_text.FixedText;
const PopupRow = popup_look.PopupRow;
const RegionIndex = universe.RegionIndex;
const RoutePreference = types.RoutePreference;
const SystemIndex = universe.SystemIndex;
const Targets = evestars.Targets;

/// The destination submenu's rows: the route's heading and settings, then the sending heading, "All", each group, and "Individual" for the characters.
const ROUTE_HEADING_ROW = 0;
const PREFERENCE_ROW = 1;
const ANSIBLEX_ROW = 2;
const WAYPOINTS_ROW = 3;
const SEND_HEADING_ROW = 4;
const ALL_ROW = 5;
pub const MAX_ROWS = ALL_ROW + 1 + evestars.MAX_TARGETS;
const ROWS = [_]Row{ .heading, .set_destination, .open_site, .jump_range, .avoid_system, .copy_name };
/// With Eve Stars off or no token, nothing can be sent.
const ROWS_WITHOUT_EVE_STARS = [_]Row{ .heading, .open_site, .jump_range, .copy_name };

const Row = enum { heading, set_destination, open_site, jump_range, avoid_system, copy_name };

/// A menu row's submenu.
pub const Branch = enum { destination, sites, jump_range };

/// One of the menu's lists: its own rows, a row's submenu, or the characters beside "Individual".
pub const Level = union(enum) { main, branch: Branch, characters };

/// What the rows show and do, besides the menu itself.
pub const Context = struct {
    has_eve_stars: bool,
    /// Borrowed for one call.
    targets: *const Targets,
    /// The characters are still being fetched.
    is_loading: bool = false,
    /// A jump range is showing, which adds "Off" to its submenu.
    has_reach: bool = false,
    /// Routes avoid the menu's system.
    is_avoided: bool = false,
    preference: RoutePreference = .Shorter,
    uses_ansiblex: bool = false,
    sets_every_waypoint: bool = false,
};

/// What pressing a row asks for.
pub const Action = union(enum) {
    none,
    avoid_system,
    copy_name,
    open_site: system_links.Site,
    /// Null turns the range off.
    show_range: ?jump_range.Ship,
    cycle_preference,
    toggle_ansiblex,
    toggle_waypoints,
    send_to_all,
    /// Into Targets.slice().
    send: usize,

    /// The route's settings change in place, leaving the menu open for the send.
    pub fn closesMenu(self: Action) bool {
        return switch (self) {
            .none, .cycle_preference, .toggle_ansiblex, .toggle_waypoints => false,
            .avoid_system, .copy_name, .open_site, .show_range, .send_to_all, .send => true,
        };
    }
};

/// Opened by right-clicking a system.
pub const Menu = struct {
    system: SystemIndex,
    anchor: win32.POINT,
    /// Null while no submenu is open.
    branch: ?Branch = null,
    /// The characters are open beside the destination submenu's "Individual".
    shows_characters: bool = false,

    /// Opens the submenu of the row at `row_index`; the heading leaves what's open alone.
    pub fn followRow(self: *Menu, has_eve_stars: bool, row_index: usize) void {
        const rows = shownRows(has_eve_stars);
        if (row_index >= rows.len) return;
        switch (rows[row_index]) {
            .heading => {},
            .set_destination => self.branch = .destination,
            .open_site => {
                self.branch = .sites;
                self.shows_characters = false;
            },
            .jump_range => {
                self.branch = .jump_range;
                self.shows_characters = false;
            },
            .avoid_system, .copy_name => {
                self.branch = null;
                self.shows_characters = false;
            },
        }
    }

    /// Opens the characters for "Individual", and closes them for any other row.
    pub fn followSubmenuRow(self: *Menu, targets: *const Targets, row_index: usize) void {
        const branch = self.branch orelse return;
        if (branch != .destination) return;
        self.shows_characters = row_index == individualRow(targets);
    }

    pub fn pressRow(self: *Menu, has_eve_stars: bool, row_index: usize) Action {
        self.followRow(has_eve_stars, row_index);
        const rows = shownRows(has_eve_stars);
        if (row_index >= rows.len) return .none;
        return switch (rows[row_index]) {
            .heading, .set_destination, .open_site, .jump_range => .none,
            .avoid_system => .avoid_system,
            .copy_name => .copy_name,
        };
    }

    /// A row past a list that has since shrunk asks for nothing.
    pub fn pressSubmenuRow(self: *Menu, context: Context, row_index: usize) Action {
        self.followSubmenuRow(context.targets, row_index);
        const branch = self.branch orelse return .none;
        return switch (branch) {
            .destination => destinationAction(context.targets, row_index),
            .sites => if (row_index < system_links.SITES.len) .{ .open_site = system_links.SITES[row_index] } else .none,
            .jump_range => {
                if (row_index >= rangeRowCount(context.has_reach)) return .none;
                return .{ .show_range = if (row_index < jump_range.SHIPS.len) jump_range.SHIPS[row_index] else null };
            },
        };
    }

    /// `buffer` holds what's returned.
    pub fn fill(self: *const Menu, context: Context, level: Level, buffer: *[MAX_ROWS]PopupRow) []const PopupRow {
        const row_count = rowCount(context, level);
        for (buffer[0..row_count], 0..) |*row, index| row.* = self.rowAt(context, level, index);
        return buffer[0..row_count];
    }

    /// The main row that's lit, if any: the hovered one past the heading, else the one an open submenu hangs off.
    pub fn litRow(self: *const Menu, has_eve_stars: bool, hovered_index: ?usize) ?usize {
        if (hovered_index) |index| {
            if (index > 0) return index;
        }
        const branch = self.branch orelse return null;
        return branchRowIndex(has_eve_stars, branch);
    }

    /// An open "Individual" stays lit while the cursor is among its characters; "All" isn't lit with no one to send to.
    pub fn litSubmenuRow(self: *const Menu, targets: *const Targets, branch: Branch, hovered_index: ?usize) ?usize {
        const index = hovered_index orelse return if (self.shows_characters) individualRow(targets) else null;
        if (branch == .destination and index == ALL_ROW and targets.count == 0) return null;
        return index;
    }

    pub fn hash(self: *const Menu, hasher: *std.hash.Wyhash) void {
        hasher.update(std.mem.asBytes(&self.system));
        hasher.update(std.mem.asBytes(&self.anchor.x));
        hasher.update(std.mem.asBytes(&self.anchor.y));
        if (self.branch) |branch| hasher.update(std.mem.asBytes(&branch));
        hasher.update(std.mem.asBytes(&self.shows_characters));
    }

    fn rowAt(self: *const Menu, context: Context, level: Level, index: usize) PopupRow {
        return switch (level) {
            .main => self.mainRow(context, index),
            .branch => |branch| branchRow(context, branch, index),
            .characters => targetRow(&context.targets.slice()[context.targets.groupCount() + index]),
        };
    }

    fn mainRow(self: *const Menu, context: Context, index: usize) PopupRow {
        return switch (shownRows(context.has_eve_stars)[index]) {
            .heading => headingRow(self.system),
            .set_destination => .{ .text = .print("Set Destination", .{}), .glyph = .set_destination, .has_submenu = true },
            .open_site => .{ .text = .print("Open", .{}), .glyph = .open_window, .has_submenu = true },
            .jump_range => .{ .text = .print("Jump Range", .{}), .glyph = .jump_range, .has_submenu = true },
            .avoid_system => .{ .text = avoidLabel(context.is_avoided), .glyph = .avoid },
            .copy_name => .{ .text = .print("Copy Name", .{}), .glyph = .copy },
        };
    }
};

/// Opened by right-clicking a region in New Eden, a region's name, or empty map.
pub const RegionMenu = struct {
    region: RegionIndex,
    anchor: win32.POINT,

    /// The heading, then a row a site.
    const ROW_COUNT = 1 + system_links.SITES.len;

    /// Null for the heading, or a row past the list.
    pub fn siteAt(_: *const RegionMenu, row_index: usize) ?system_links.Site {
        if (row_index == 0 or row_index >= ROW_COUNT) return null;
        return system_links.SITES[row_index - 1];
    }

    /// `buffer` holds what's returned.
    pub fn fill(self: *const RegionMenu, buffer: *[MAX_ROWS]PopupRow) []const PopupRow {
        buffer[0] = .{ .text = .print("{s}", .{universe.regionName(self.region)}), .color = list_look.MUTED, .role = .heading, .has_rule_below = true };
        for (buffer[1..ROW_COUNT], system_links.SITES) |*row, site| row.* = .{ .text = .print("Open in {s}", .{system_links.siteName(site)}), .glyph = siteGlyph(site) };
        return buffer[0..ROW_COUNT];
    }

    /// The hovered row, past the heading.
    pub fn litRow(_: *const RegionMenu, hovered_index: ?usize) ?usize {
        const index = hovered_index orelse return null;
        return if (index > 0) index else null;
    }

    pub fn hash(self: *const RegionMenu, hasher: *std.hash.Wyhash) void {
        hasher.update(std.mem.asBytes(&self.region));
        hasher.update(std.mem.asBytes(&self.anchor.x));
        hasher.update(std.mem.asBytes(&self.anchor.y));
    }
};

/// Opened from the Layers button; pressing a row turns its layer on or off and leaves the menu open.
pub const LayersMenu = struct {
    anchor: win32.POINT,

    /// Null past the list.
    pub fn layerAt(_: *const LayersMenu, row_index: usize) ?look.Layer {
        if (row_index >= look.LAYER_ORDER.len) return null;
        return look.LAYER_ORDER[row_index];
    }

    /// `shown` is by LAYER_ORDER; `buffer` holds what's returned.
    pub fn fill(_: *const LayersMenu, shown: [look.LAYER_ORDER.len]bool, buffer: *[MAX_ROWS]PopupRow) []const PopupRow {
        for (buffer[0..look.LAYER_ORDER.len], look.LAYER_ORDER, shown) |*row, layer, is_shown| {
            row.* = .{ .text = .print("{s}", .{text.layerLabel(layer)}), .is_checked = is_shown };
        }
        return buffer[0..look.LAYER_ORDER.len];
    }

    pub fn hash(self: *const LayersMenu, hasher: *std.hash.Wyhash) void {
        hasher.update(std.mem.asBytes(&self.anchor.x));
        hasher.update(std.mem.asBytes(&self.anchor.y));
    }
};

/// The main row `branch` hangs off.
pub fn branchRowIndex(has_eve_stars: bool, branch: Branch) usize {
    const row: Row = switch (branch) {
        .destination => .set_destination,
        .sites => .open_site,
        .jump_range => .jump_range,
    };
    // The token can go while the menu's open, taking its row along.
    return std.mem.indexOfScalar(Row, shownRows(has_eve_stars), row) orelse 0;
}

/// A character listed beside "Individual"; one past the list asks for nothing.
pub fn pressCharacterRow(targets: *const Targets, row_index: usize) Action {
    const group_count = targets.groupCount();
    if (row_index >= targets.count - group_count) return .none;
    return .{ .send = group_count + row_index };
}

/// Null with no characters to list.
pub fn individualRow(targets: *const Targets) ?usize {
    const group_count = targets.groupCount();
    return if (targets.count > group_count) ALL_ROW + 1 + group_count else null;
}

/// What a click moves `preference` on to, round in the game's order.
pub fn nextPreference(preference: RoutePreference) RoutePreference {
    return switch (preference) {
        .Shorter => .Safer,
        .Safer => .LessSecure,
        .LessSecure => .Shorter,
    };
}

fn rowCount(context: Context, level: Level) usize {
    return switch (level) {
        .main => shownRows(context.has_eve_stars).len,
        .branch => |branch| switch (branch) {
            .destination => destinationRowCount(context.targets),
            .sites => system_links.SITES.len,
            .jump_range => rangeRowCount(context.has_reach),
        },
        .characters => context.targets.count - context.targets.groupCount(),
    };
}

fn shownRows(has_eve_stars: bool) []const Row {
    return if (has_eve_stars) &ROWS else &ROWS_WITHOUT_EVE_STARS;
}

fn destinationAction(targets: *const Targets, row_index: usize) Action {
    switch (row_index) {
        ROUTE_HEADING_ROW, SEND_HEADING_ROW => return .none,
        PREFERENCE_ROW => return .cycle_preference,
        ANSIBLEX_ROW => return .toggle_ansiblex,
        WAYPOINTS_ROW => return .toggle_waypoints,
        else => {},
    }
    const send_index = row_index - ALL_ROW;
    if (targets.count == 0 or send_index > targets.groupCount()) return .none;
    return if (send_index == 0) .send_to_all else .{ .send = send_index - 1 };
}

fn destinationRowCount(targets: *const Targets) usize {
    if (individualRow(targets)) |row_index| return row_index + 1;
    return ALL_ROW + 1 + targets.count;
}

/// One a ship, then "Off" while a range shows.
fn rangeRowCount(has_reach: bool) usize {
    return jump_range.SHIPS.len + @intFromBool(has_reach);
}

/// ALL_ROW is a status line while there are no targets.
fn branchRow(context: Context, branch: Branch, index: usize) PopupRow {
    switch (branch) {
        .sites => return siteRow(system_links.SITES[index]),
        .jump_range => return rangeRow(index),
        .destination => {},
    }
    switch (index) {
        ROUTE_HEADING_ROW => return sectionRow("ROUTE"),
        PREFERENCE_ROW => return preferenceRow(context.preference),
        ANSIBLEX_ROW => return .{ .text = .print("Use Ansiblex Gates", .{}), .is_checked = context.uses_ansiblex },
        WAYPOINTS_ROW => return .{ .text = .print("Every System as Waypoint", .{}), .is_checked = context.sets_every_waypoint, .has_rule_below = true },
        SEND_HEADING_ROW => return sectionRow("SEND TO"),
        else => {},
    }
    const targets = context.targets.slice();
    if (targets.len == 0) return .{ .text = .print("{s}", .{if (context.is_loading) "Loading..." else "No characters"}), .color = list_look.MUTED };
    if (index == ALL_ROW) {
        const character_count = context.targets.sendableCharacterCount();
        return .{ .text = .print("All", .{}), .value = .print("{d}", .{character_count}), .color = if (character_count > 0) list_look.NAME else list_look.MUTED, .glyph = .group };
    }
    if (index == individualRow(context.targets)) return .{ .text = .print("Individual", .{}), .glyph = .person, .has_submenu = true };
    return targetRow(&targets[index - ALL_ROW - 1]);
}

/// Past the ships is the "Off" row.
fn rangeRow(index: usize) PopupRow {
    if (index == jump_range.SHIPS.len) return .{ .text = .print("Off", .{}), .glyph = .off };
    return shipRow(jump_range.SHIPS[index]);
}

/// A ship's row, with its range as the value.
fn shipRow(ship: jump_range.Ship) PopupRow {
    return .{ .text = .print("{s}", .{jump_range.shipName(ship)}), .value = .print("{d:.1} ly", .{jump_range.rangeLightYears(ship)}), .glyph = shipGlyph(ship) };
}

/// The overview bracket the game gives its hull; the game has none of their own for command carriers, lancers or black ops.
fn shipGlyph(ship: jump_range.Ship) glyphs.Glyph {
    return switch (ship) {
        .titan => .titan,
        .jump_freighter => .freighter,
        .carrier, .command_carrier => .carrier,
        .dreadnought, .lancer_dreadnought => .dreadnought,
        .black_ops => .battleship,
    };
}

/// The system, its security and region, over the rows, as its tooltip's title shows them.
fn headingRow(system: SystemIndex) PopupRow {
    const info = universe.systemInfo(system);
    const name = universe.systemName(system);
    var security_buffer: [text.SECURITY_TEXT_MAX]u8 = undefined;
    const security = text.securityText(&security_buffer, info.security_tenths);
    return .{
        .text = .print("{s}{s}", .{ name, security }),
        .accent = .{ .start = name.len, .end = name.len + security.len, .color = look.securityTextColor(info.security_tenths) },
        .value = .print("{s}", .{universe.regionName(info.region)}),
        .role = .title,
        .has_rule_below = true,
    };
}

fn sectionRow(comptime label: []const u8) PopupRow {
    return .{ .text = .print(label, .{}), .color = list_look.MUTED, .role = .heading };
}

/// A group's size, or why a character may not get the route, as the value.
fn targetRow(target: *const evestars.Target) PopupRow {
    const name = target.name.slice();
    const color = if (target.can_send) list_look.NAME else list_look.MUTED;
    return switch (target.kind) {
        .group => .{ .text = .print("{s}", .{name}), .value = .print("{d}", .{target.character_count}), .color = color, .glyph = .group },
        .character => .{ .text = .print("{s}", .{name}), .value = if (target.can_send) .{} else .print("can't send", .{}), .color = color, .glyph = .person },
    };
}

/// The preference, with the others as the value in the order clicks reach them.
fn preferenceRow(preference: RoutePreference) PopupRow {
    const next = nextPreference(preference);
    return .{ .text = .print("{s}", .{preferenceName(preference)}), .value = .print("{s}, {s}", .{ preferenceName(next), preferenceName(nextPreference(next)) }), .glyph = .route };
}

fn siteRow(site: system_links.Site) PopupRow {
    return .{ .text = .print("{s}", .{system_links.siteName(site)}), .glyph = siteGlyph(site) };
}

fn siteGlyph(site: system_links.Site) glyphs.Glyph {
    return switch (site) {
        .dotlan => .map,
        .zkillboard => .crosshair,
        .eve_stars => .star,
    };
}

fn preferenceName(preference: RoutePreference) []const u8 {
    return switch (preference) {
        .Shorter => "Shorter",
        .Safer => "Safer",
        .LessSecure => "Less Secure",
    };
}

fn avoidLabel(is_avoided: bool) FixedText {
    return .print("{s}", .{if (is_avoided) "Stop Avoiding" else "Avoid System"});
}

const testing = std.testing;

fn testMenu() Menu {
    return .{ .system = universe.findSystem("Jita").?, .anchor = .{ .x = 0, .y = 0 } };
}

/// The groups first, as Eve Stars lists them.
fn testTargets(group_count: usize, character_count: usize) Targets {
    var targets: Targets = .{};
    for (0..group_count + character_count) |index| {
        targets.items[index] = .{ .id = index, .name = .print("Target {d}", .{index}), .kind = if (index < group_count) .group else .character };
    }
    targets.count = group_count + character_count;
    return targets;
}

test "without Eve Stars the menu drops its destination and avoid rows, and the submenus follow their rows" {
    const context: Context = .{ .has_eve_stars = false, .targets = &.{} };
    try testing.expectEqual(@as(usize, 4), rowCount(context, .main));
    try testing.expectEqual(@as(usize, 1), branchRowIndex(false, .sites));
    try testing.expectEqual(@as(usize, 2), branchRowIndex(false, .jump_range));
    try testing.expectEqual(@as(usize, 0), branchRowIndex(false, .destination));
    try testing.expectEqual(@as(usize, 1), branchRowIndex(true, .destination));
    try testing.expectEqual(@as(usize, 3), branchRowIndex(true, .jump_range));
}

test "hovering a row opens its submenu, and the heading leaves what's open alone" {
    var menu = testMenu();
    menu.followRow(true, 1);
    try testing.expectEqual(@as(?Branch, .destination), menu.branch);
    menu.followRow(true, 0);
    try testing.expectEqual(@as(?Branch, .destination), menu.branch);
    menu.followRow(true, 5);
    try testing.expectEqual(@as(?Branch, null), menu.branch);
}

test "pressing Avoid or Copy Name asks for it, while a row with a submenu only opens it" {
    var menu = testMenu();
    try testing.expectEqual(Action.none, menu.pressRow(true, 1));
    try testing.expectEqual(@as(?Branch, .destination), menu.branch);
    try testing.expectEqual(Action.avoid_system, menu.pressRow(true, 4));
    try testing.expectEqual(Action.copy_name, menu.pressRow(false, 3));
    try testing.expectEqual(Action.none, menu.pressRow(true, 99));
}

test "the destination submenu sends to all, then each group, and Individual opens the characters" {
    const targets = testTargets(2, 2);
    const context: Context = .{ .has_eve_stars = true, .targets = &targets };
    var menu = testMenu();
    menu.branch = .destination;
    try testing.expectEqual(Action.send_to_all, menu.pressSubmenuRow(context, ALL_ROW));
    try testing.expectEqual(Action{ .send = 0 }, menu.pressSubmenuRow(context, ALL_ROW + 1));
    try testing.expectEqual(Action{ .send = 1 }, menu.pressSubmenuRow(context, ALL_ROW + 2));
    try testing.expect(!menu.shows_characters);
    try testing.expectEqual(Action.none, menu.pressSubmenuRow(context, ALL_ROW + 3));
    try testing.expect(menu.shows_characters);
    try testing.expectEqual(@as(usize, ALL_ROW + 4), rowCount(context, .{ .branch = .destination }));
    try testing.expectEqual(Action{ .send = 3 }, pressCharacterRow(&targets, 1));
    try testing.expectEqual(Action.none, pressCharacterRow(&targets, 2));
}

test "without groups every character is listed straight under All" {
    const targets = testTargets(0, 2);
    const context: Context = .{ .has_eve_stars = true, .targets = &targets };
    try testing.expectEqual(@as(?usize, ALL_ROW + 1), individualRow(&targets));
    try testing.expectEqual(@as(usize, ALL_ROW + 2), rowCount(context, .{ .branch = .destination }));
}

test "the route's settings change in place, leaving the menu open for the send" {
    const targets = testTargets(1, 1);
    const context: Context = .{ .has_eve_stars = true, .targets = &targets };
    var menu = testMenu();
    menu.branch = .destination;
    const settings = [_]Action{ .cycle_preference, .toggle_ansiblex, .toggle_waypoints };
    for (settings, PREFERENCE_ROW..) |expected, row_index| {
        const action = menu.pressSubmenuRow(context, row_index);
        try testing.expectEqual(expected, action);
        try testing.expect(!action.closesMenu());
    }
    try testing.expect(menu.pressSubmenuRow(context, ALL_ROW).closesMenu());
    try testing.expectEqual(Action.none, menu.pressSubmenuRow(context, ROUTE_HEADING_ROW));
    try testing.expectEqual(Action.none, menu.pressSubmenuRow(context, SEND_HEADING_ROW));
}

test "with no one to send to, All is a status line that sends nothing and isn't lit" {
    const targets: Targets = .{};
    var menu = testMenu();
    menu.branch = .destination;
    const context: Context = .{ .has_eve_stars = true, .targets = &targets };
    try testing.expectEqual(Action.none, menu.pressSubmenuRow(context, ALL_ROW));
    try testing.expectEqual(@as(usize, ALL_ROW + 1), rowCount(context, .{ .branch = .destination }));
    var buffer: [MAX_ROWS]PopupRow = undefined;
    try testing.expectEqualStrings("No characters", menu.fill(context, .{ .branch = .destination }, &buffer)[ALL_ROW].text.slice());
    const loading: Context = .{ .has_eve_stars = true, .targets = &targets, .is_loading = true };
    try testing.expectEqualStrings("Loading...", menu.fill(loading, .{ .branch = .destination }, &buffer)[ALL_ROW].text.slice());
    try testing.expectEqual(@as(?usize, null), menu.litSubmenuRow(&targets, .destination, ALL_ROW));
}

test "the jump range submenu offers Off only while a range shows" {
    var menu = testMenu();
    menu.branch = .jump_range;
    const hidden: Context = .{ .has_eve_stars = true, .targets = &.{} };
    const shown: Context = .{ .has_eve_stars = true, .targets = &.{}, .has_reach = true };
    try testing.expectEqual(jump_range.SHIPS.len, rowCount(hidden, .{ .branch = .jump_range }));
    try testing.expectEqual(jump_range.SHIPS.len + 1, rowCount(shown, .{ .branch = .jump_range }));
    try testing.expectEqual(Action.none, menu.pressSubmenuRow(hidden, jump_range.SHIPS.len));
    try testing.expectEqual(Action{ .show_range = null }, menu.pressSubmenuRow(shown, jump_range.SHIPS.len));
    try testing.expectEqual(Action{ .show_range = jump_range.SHIPS[0] }, menu.pressSubmenuRow(hidden, 0));
}

test "a site past the list asks for nothing" {
    var menu = testMenu();
    menu.branch = .sites;
    const context: Context = .{ .has_eve_stars = true, .targets = &.{} };
    try testing.expectEqual(Action{ .open_site = system_links.SITES[0] }, menu.pressSubmenuRow(context, 0));
    try testing.expectEqual(Action.none, menu.pressSubmenuRow(context, system_links.SITES.len));
}

test "an open submenu's row stays lit, and an open Individual stays lit among its characters" {
    const targets = testTargets(1, 2);
    var menu = testMenu();
    try testing.expectEqual(@as(?usize, null), menu.litRow(true, 0));
    menu.followRow(true, 2);
    try testing.expectEqual(@as(?usize, 2), menu.litRow(true, null));
    try testing.expectEqual(@as(?usize, 4), menu.litRow(true, 4));
    menu.followRow(true, 1);
    menu.followSubmenuRow(&targets, ALL_ROW + 2);
    try testing.expect(menu.shows_characters);
    try testing.expectEqual(individualRow(&targets), menu.litSubmenuRow(&targets, .destination, null));
}

test "a target's row says why it may not get the route, and a group's gives its size" {
    var target: evestars.Target = .{ .id = 1, .name = .print("Alpha", .{}), .kind = .character };
    try testing.expectEqualStrings("Alpha", targetRow(&target).text.slice());
    try testing.expectEqualStrings("", targetRow(&target).value.slice());
    target.can_send = false;
    try testing.expectEqualStrings("can't send", targetRow(&target).value.slice());
    target.kind = .group;
    target.character_count = 4;
    try testing.expectEqualStrings("4", targetRow(&target).value.slice());
}

test "the route preference comes back round to where it started, its row naming the others in order" {
    const row = preferenceRow(.Safer);
    try testing.expectEqualStrings("Safer", row.text.slice());
    try testing.expectEqualStrings("Less Secure, Shorter", row.value.slice());
    try testing.expectEqual(RoutePreference.Shorter, nextPreference(nextPreference(nextPreference(.Shorter))));
}

test "a ship's menu row gives its range as the value" {
    const row = shipRow(.black_ops);
    try testing.expectEqualStrings("Black Ops", row.text.slice());
    try testing.expectEqualStrings("8.0 ly", row.value.slice());
}

test "the region menu's rows past its heading open each site" {
    const menu: RegionMenu = .{ .region = 0, .anchor = .{ .x = 0, .y = 0 } };
    try testing.expectEqual(@as(?system_links.Site, null), menu.siteAt(0));
    try testing.expectEqual(@as(?system_links.Site, system_links.SITES[0]), menu.siteAt(1));
    try testing.expectEqual(@as(?system_links.Site, null), menu.siteAt(RegionMenu.ROW_COUNT));
    var buffer: [MAX_ROWS]PopupRow = undefined;
    try testing.expectEqualStrings("Open in Dotlan", menu.fill(&buffer)[1].text.slice());
    try testing.expectEqual(@as(?usize, null), menu.litRow(0));
}

test "the menu's heading gives the system's security and region" {
    const row = headingRow(universe.findSystem("Jita").?);
    const accent = row.accent.?;
    try testing.expectEqualStrings("Jita", row.text.slice()[0..accent.start]);
    try testing.expectEqualStrings("0.9", row.text.slice()[accent.start..accent.end]);
    try testing.expectEqualStrings("The Forge", row.value.slice());
}
