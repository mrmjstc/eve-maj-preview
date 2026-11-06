//! The Map Panel's right-click menu on a system: its rows and submenus, and what pressing each asks for; no I/O.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const types = @import("../../config/types.zig");
const list_look = @import("../list_look.zig");
const popup_look = @import("../popup_look.zig");
const universe = @import("../../map/universe.zig");
const jump_range = @import("../../map/jump_range.zig");
const evestars = @import("../../map/evestars.zig");
const system_links = @import("../../map/system_links.zig");
const fixed_text = @import("../../util/fixed_text.zig");

const FixedText = fixed_text.FixedText;
const PopupRow = popup_look.PopupRow;
const RoutePreference = types.RoutePreference;
const SystemIndex = universe.SystemIndex;
const Targets = evestars.Targets;

/// The destination submenu's rows: the route's settings, "All", each group, then "Individual" for the characters.
const PREFERENCE_ROW = 0;
const ANSIBLEX_ROW = 1;
const WAYPOINTS_ROW = 2;
const ALL_ROW = 3;
pub const MAX_ROWS = ALL_ROW + 1 + evestars.MAX_TARGETS;
const ROWS = [_]Row{ .heading, .set_destination, .open_site, .jump_range, .avoid_system, .copy_name };
/// With Eve Stars off or no token, nothing can be sent.
const ROWS_WITHOUT_EVE_STARS = [_]Row{ .heading, .open_site, .jump_range, .copy_name };

pub const Row = enum { heading, set_destination, open_site, jump_range, avoid_system, copy_name };

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
            .heading => .{ .text = .print("{s}", .{universe.systemName(self.system)}), .color = list_look.MUTED, .has_rule_below = true },
            .set_destination => .{ .text = .print("Set Destination", .{}), .color = list_look.NAME, .has_submenu = true },
            .open_site => .{ .text = .print("Open", .{}), .color = list_look.NAME, .has_submenu = true },
            .jump_range => .{ .text = .print("Jump Range", .{}), .color = list_look.NAME, .has_submenu = true },
            .avoid_system => .{ .text = avoidLabel(context.is_avoided), .color = list_look.NAME },
            .copy_name => .{ .text = .print("Copy Name", .{}), .color = list_look.NAME },
        };
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
        .sites => return .{ .text = .print("{s}", .{system_links.siteName(system_links.SITES[index])}), .color = list_look.NAME },
        .jump_range => return rangeRow(index),
        .destination => {},
    }
    switch (index) {
        PREFERENCE_ROW => return .{ .text = preferenceLabel(context.preference), .color = list_look.NAME },
        ANSIBLEX_ROW => return .{ .text = ansiblexLabel(context.uses_ansiblex), .color = list_look.NAME },
        WAYPOINTS_ROW => return .{ .text = waypointsLabel(context.sets_every_waypoint), .color = list_look.NAME, .has_rule_below = true },
        else => {},
    }
    const targets = context.targets.slice();
    if (targets.len == 0) return .{ .text = .print("{s}", .{if (context.is_loading) "Loading..." else "No characters"}), .color = list_look.MUTED };
    if (index == ALL_ROW) {
        const character_count = context.targets.sendableCharacterCount();
        return .{ .text = allLabel(character_count), .color = if (character_count > 0) list_look.NAME else list_look.MUTED };
    }
    if (index == individualRow(context.targets)) return .{ .text = .print("Individual", .{}), .color = list_look.NAME, .has_submenu = true };
    return targetRow(&targets[index - ALL_ROW - 1]);
}

/// Past the ships is the "Off" row.
fn rangeRow(index: usize) PopupRow {
    if (index == jump_range.SHIPS.len) return .{ .text = .print("Off", .{}), .color = list_look.NAME };
    return .{ .text = rangeLabel(jump_range.SHIPS[index]), .color = list_look.NAME };
}

fn targetRow(target: *const evestars.Target) PopupRow {
    return .{ .text = targetLabel(target), .color = targetColor(target) };
}

/// A ship's row on the menu.
fn rangeLabel(ship: jump_range.Ship) FixedText {
    return .print("{s}" ++ popup_look.POPUP_PART_GAP ++ "{d:.1} ly", .{ jump_range.shipName(ship), jump_range.rangeLightYears(ship) });
}

fn targetLabel(target: *const evestars.Target) FixedText {
    const name = target.name.slice();
    return switch (target.kind) {
        .group => .print("{s} ({d})", .{ name, target.character_count }),
        .character => if (target.can_send) .print("{s}", .{name}) else .print("{s} (can't send)", .{name}),
    };
}

fn targetColor(target: *const evestars.Target) u32 {
    return if (target.can_send) list_look.NAME else list_look.MUTED;
}

fn allLabel(character_count: usize) FixedText {
    return .print("All ({d})", .{character_count});
}

fn preferenceLabel(preference: RoutePreference) FixedText {
    return .print("Prefer: {s}", .{switch (preference) {
        .Shorter => "Shorter",
        .Safer => "Safer",
        .LessSecure => "Less Secure",
    }});
}

fn ansiblexLabel(uses_ansiblex: bool) FixedText {
    return .print("Ansiblex: {s}", .{if (uses_ansiblex) "On" else "Off"});
}

fn waypointsLabel(sets_every_waypoint: bool) FixedText {
    return .print("Waypoints: {s}", .{if (sets_every_waypoint) "Every System" else "Fewest"});
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
    for (settings, 0..) |expected, row_index| {
        const action = menu.pressSubmenuRow(context, row_index);
        try testing.expectEqual(expected, action);
        try testing.expect(!action.closesMenu());
    }
    try testing.expect(menu.pressSubmenuRow(context, ALL_ROW).closesMenu());
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

test "a target's label says why it may not get the route" {
    var target: evestars.Target = .{ .id = 1, .name = .print("Alpha", .{}), .kind = .character };
    try testing.expectEqualStrings("Alpha", targetLabel(&target).slice());
    target.can_send = false;
    try testing.expectEqualStrings("Alpha (can't send)", targetLabel(&target).slice());
    target.kind = .group;
    target.character_count = 4;
    try testing.expectEqualStrings("Alpha (4)", targetLabel(&target).slice());
}

test "the route preference comes back round to where it started" {
    try testing.expectEqualStrings("Prefer: Less Secure", preferenceLabel(nextPreference(.Safer)).slice());
    try testing.expectEqual(RoutePreference.Shorter, nextPreference(nextPreference(nextPreference(.Shorter))));
}

test "a ship's menu row gives its range" {
    try testing.expectEqualStrings("Black Ops  8.0 ly", rangeLabel(.black_ops).slice());
    try testing.expectEqualStrings("Command Carrier  7.5 ly", rangeLabel(.command_carrier).slice());
}
