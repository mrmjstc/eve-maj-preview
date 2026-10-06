//! Which thumbnail space each character's thumbnail belongs to, and its cell within that space; no I/O.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const scout = @import("../clients/scout.zig");
const strings = @import("../util/strings.zig");

const Config = config_mod.Config;
const ThumbnailSpace = config_mod.ThumbnailSpace;

/// Spaces past this are ignored, so per-space state fits in fixed arrays.
pub const MAX_SPACES = 32;

/// How many thumbnails each space holds, indexed like thumbnailSpaces.
pub const SpaceCounts = [MAX_SPACES]usize;

/// Each thumbnail's space and cell for one layout pass.
pub const Assignment = struct {
    /// Per name: index into thumbnailSpaces, or null when it's placed by hand.
    space_of: []?usize,
    /// Per name: its cell within its space; unused when placed by hand.
    rank: []usize,
    counts: SpaceCounts = @splat(0),

    pub fn deinit(self: *Assignment, allocator: std.mem.Allocator) void {
        allocator.free(self.space_of);
        allocator.free(self.rank);
    }
};

const RankContext = struct {
    cfg: *const Config,
    space: *const ThumbnailSpace,
    names: []const []const u8,
    order_map: *const std.StringHashMap(usize),

    /// The space's own characters, then unassigned ones it took, then login-screen clients it took.
    fn tier(context: RankContext, name: []const u8) u2 {
        const space = context.space;
        if (scout.isGenericCharacterName(name)) return if (space.holdsLoginScreen) 0 else 2;
        return if (space.holdsUnassigned or holdsGroupOf(context.cfg, space, name)) 0 else 1;
    }

    fn lessThan(context: RankContext, a_index: usize, b_index: usize) bool {
        const a_name = context.names[a_index];
        const b_name = context.names[b_index];
        const a_tier = context.tier(a_name);
        const b_tier = context.tier(b_name);
        if (a_tier != b_tier) return a_tier < b_tier;
        return config_mod.orderMapLessThan(context.order_map, a_name, b_name, a_index, b_index);
    }
};

pub fn rect(space: *const ThumbnailSpace) ?win32.RECT {
    const x = space.x orelse return null;
    const y = space.y orelse return null;
    const width = space.width orelse return null;
    const height = space.height orelse return null;
    return .{ .left = x, .top = y, .right = x + width, .bottom = y + height };
}

/// The rectangle of a space that places thumbnails: enabled, with its region drawn.
pub fn activeRect(space: *const ThumbnailSpace) ?win32.RECT {
    if (!space.enabled) return null;
    return rect(space);
}

pub fn isActive(space: *const ThumbnailSpace) bool {
    return activeRect(space) != null;
}

/// The spaces layout considers, in list order; none in Manual placement mode.
pub fn listed(cfg: *const Config) []const ThumbnailSpace {
    switch (cfg.display.placementMode) {
        .Manual => return &.{},
        .ThumbnailSpaces => {},
    }
    const items = cfg.thumbnailSpaces.items;
    return items[0..@min(items.len, MAX_SPACES)];
}

pub fn anyActive(cfg: *const Config) bool {
    for (listed(cfg)) |*space| {
        if (isActive(space)) return true;
    }
    return false;
}

/// Where login-screen clients go: the Login Screen space when it's active, else the first active space taking them; null when they're placed by hand.
pub fn loginScreenSpaceIn(items: []const ThumbnailSpace) ?usize {
    return firstActiveWith(items, "holdsLoginScreen") orelse firstActiveWith(items, "takesLoginScreen");
}

/// Where characters no active space holds go: the Unassigned Characters space when it's active, else the first active space taking them; null when they're placed by hand.
pub fn unassignedSpaceIn(items: []const ThumbnailSpace) ?usize {
    return firstActiveWith(items, "holdsUnassigned") orelse firstActiveWith(items, "takesUnassigned");
}

/// The first active space holding one of this character's hotkey groups, else where unassigned characters go; null when it's placed by hand.
pub fn spaceFor(cfg: *const Config, character_name: []const u8) ?usize {
    const items = listed(cfg);
    if (scout.isGenericCharacterName(character_name)) return loginScreenSpaceIn(items);
    for (items, 0..) |*space, i| {
        if (isActive(space) and holdsGroupOf(cfg, space, character_name)) return i;
    }
    return unassignedSpaceIn(items);
}

/// The first active space holding hotkey group `group_name`; a space later in the list that also holds it doesn't get its characters.
pub fn groupSpaceIn(items: []const ThumbnailSpace, group_name: []const u8) ?usize {
    for (items, 0..) |*space, i| {
        if (isActive(space) and space.groupIndex(group_name) != null) return i;
    }
    return null;
}

/// Caller frees with Assignment.deinit.
pub fn assign(allocator: std.mem.Allocator, cfg: *const Config, names: []const []const u8) !Assignment {
    const space_of = try allocator.alloc(?usize, names.len);
    errdefer allocator.free(space_of);
    const rank = try allocator.alloc(usize, names.len);
    errdefer allocator.free(rank);
    @memset(rank, 0);

    var assignment: Assignment = .{ .space_of = space_of, .rank = rank };
    for (names, space_of) |name, *of| {
        of.* = spaceFor(cfg, name);
        if (of.*) |space_index| assignment.counts[space_index] += 1;
    }

    const members = try allocator.alloc(usize, names.len);
    defer allocator.free(members);
    for (listed(cfg), 0..) |*space, space_index| {
        if (assignment.counts[space_index] == 0) continue;
        var count: usize = 0;
        for (space_of, 0..) |of, i| {
            if ((of orelse continue) != space_index) continue;
            members[count] = i;
            count += 1;
        }
        var order_map = try orderMap(allocator, cfg, space);
        defer order_map.deinit();
        const context: RankContext = .{ .cfg = cfg, .space = space, .names = names, .order_map = &order_map };
        std.sort.pdq(usize, members[0..count], context, RankContext.lessThan);
        for (members[0..count], 0..) |name_index, cell| rank[name_index] = cell;
    }
    return assignment;
}

fn firstActiveWith(items: []const ThumbnailSpace, comptime flag: []const u8) ?usize {
    for (items, 0..) |*space, i| {
        if (isActive(space) and @field(space, flag)) return i;
    }
    return null;
}

/// Whether one of this space's hotkey groups lists the character.
fn holdsGroupOf(cfg: *const Config, space: *const ThumbnailSpace, character_name: []const u8) bool {
    for (cfg.hotkeyGroups.items) |group| {
        if (space.groupIndex(group.name) == null) continue;
        if (strings.indexOfString(group.characters.items, character_name) != null) return true;
    }
    return false;
}

/// The space's own groups rank ahead of the rest under HotkeyGroups, so its members fill in that group order.
fn orderMap(allocator: std.mem.Allocator, cfg: *const Config, space: *const ThumbnailSpace) !std.StringHashMap(usize) {
    switch (space.order) {
        .Characters => return config_mod.buildCharacterOrderMap(cfg.characters.items, allocator),
        .HotkeyGroups => {
            var map = std.StringHashMap(usize).init(allocator);
            errdefer map.deinit();
            var next: usize = 0;
            for ([_]bool{ true, false }) |own_groups| {
                for (cfg.hotkeyGroups.items) |group| {
                    if ((space.groupIndex(group.name) != null) != own_groups) continue;
                    for (group.characters.items) |name| {
                        const entry = try map.getOrPut(name);
                        if (entry.found_existing) continue;
                        entry.value_ptr.* = next;
                        next += 1;
                    }
                }
            }
            return map;
        },
    }
}

const testing = std.testing;

const LOGIN_SCREEN = "EVE";

fn testConfig(groups: []config_mod.HotkeyGroupConfig, spaces: []ThumbnailSpace) Config {
    return .{ .allocator = testing.allocator, .profile_name = "", .display = .{ .placementMode = .ThumbnailSpaces }, .hotkeyGroups = .fromOwnedSlice(groups), .thumbnailSpaces = .fromOwnedSlice(spaces) };
}

fn testSpace(name: []const u8, groups: []const []const u8) ThumbnailSpace {
    return .{ .name = name, .groups = .fromOwnedSlice(@constCast(groups)), .x = 0, .y = 0, .width = 800, .height = 600 };
}

fn testGroup(name: []const u8, characters: []const []const u8) config_mod.HotkeyGroupConfig {
    return .{ .name = name, .characters = .fromOwnedSlice(@constCast(characters)) };
}

test "a character goes to the space holding its group, the rest to the space taking unassigned characters" {
    var groups = [_]config_mod.HotkeyGroupConfig{testGroup("Miners", &.{ "Miner A", "Miner B" })};
    var spaces = [_]ThumbnailSpace{ testSpace("Mining", &.{"Miners"}), testSpace("Everyone", &.{}) };
    spaces[1].takesUnassigned = true;
    const cfg = testConfig(&groups, &spaces);

    try testing.expectEqual(@as(?usize, 0), spaceFor(&cfg, "Miner B"));
    try testing.expectEqual(@as(?usize, 1), spaceFor(&cfg, "Hauler"));
    try testing.expectEqual(@as(?usize, null), spaceFor(&cfg, LOGIN_SCREEN));
}

test "login-screen clients go to the first active space taking them" {
    var spaces = [_]ThumbnailSpace{ testSpace("Off", &.{}), testSpace("Fleet", &.{}), testSpace("Mining", &.{}) };
    spaces[0].takesLoginScreen = true;
    spaces[0].enabled = false;
    spaces[1].takesLoginScreen = true;
    spaces[2].takesLoginScreen = true;
    const cfg = testConfig(&.{}, &spaces);

    try testing.expectEqual(@as(?usize, 1), spaceFor(&cfg, LOGIN_SCREEN));
    try testing.expectEqual(@as(?usize, null), spaceFor(&cfg, "Pilot"));
}

test "an active Unassigned Characters space wins over spaces taking unassigned characters" {
    var spaces = [_]ThumbnailSpace{ testSpace("Fleet", &.{}), testSpace("Unassigned Characters", &.{}) };
    spaces[0].takesUnassigned = true;
    spaces[1].holdsUnassigned = true;
    const cfg = testConfig(&.{}, &spaces);

    try testing.expectEqual(@as(?usize, 1), spaceFor(&cfg, "Pilot"));
    spaces[1].enabled = false;
    try testing.expectEqual(@as(?usize, 0), spaceFor(&cfg, "Pilot"));
}

test "in Manual placement mode every character is placed by hand" {
    var groups = [_]config_mod.HotkeyGroupConfig{testGroup("Miners", &.{"Miner A"})};
    var spaces = [_]ThumbnailSpace{testSpace("Mining", &.{"Miners"})};
    spaces[0].takesUnassigned = true;
    var cfg = testConfig(&groups, &spaces);
    cfg.display.placementMode = .Manual;

    try testing.expectEqual(@as(?usize, null), spaceFor(&cfg, "Miner A"));
    try testing.expectEqual(@as(?usize, null), spaceFor(&cfg, "Hauler"));
    try testing.expect(!anyActive(&cfg));
}

test "with no space taking unassigned characters they're placed by hand" {
    var groups = [_]config_mod.HotkeyGroupConfig{testGroup("Miners", &.{"Miner A"})};
    var spaces = [_]ThumbnailSpace{testSpace("Mining", &.{"Miners"})};
    const cfg = testConfig(&groups, &spaces);

    try testing.expectEqual(@as(?usize, null), spaceFor(&cfg, "Hauler"));
    try testing.expectEqual(@as(?usize, null), spaceFor(&cfg, LOGIN_SCREEN));
}

test "a character in two spaces' groups goes to the first space in the list" {
    var groups = [_]config_mod.HotkeyGroupConfig{ testGroup("Miners", &.{ "Pilot", "Miner" }), testGroup("Scouts", &.{"Pilot"}) };
    var spaces = [_]ThumbnailSpace{ testSpace("Scouting", &.{"Scouts"}), testSpace("Mining", &.{"Miners"}) };
    const cfg = testConfig(&groups, &spaces);

    try testing.expectEqual(@as(?usize, 0), spaceFor(&cfg, "Pilot"));
    try testing.expectEqual(@as(?usize, 1), spaceFor(&cfg, "Miner"));
}

test "a group goes to the first active space holding it" {
    var spaces = [_]ThumbnailSpace{ testSpace("Off", &.{"Miners"}), testSpace("Mining", &.{"Miners"}), testSpace("More Mining", &.{"Miners"}) };
    spaces[0].enabled = false;

    try testing.expectEqual(@as(?usize, 1), groupSpaceIn(&spaces, "Miners"));
    try testing.expectEqual(@as(?usize, null), groupSpaceIn(&spaces, "Scouts"));
}

test "a disabled space or one with no region is skipped" {
    var groups = [_]config_mod.HotkeyGroupConfig{testGroup("Miners", &.{"Miner"})};
    var spaces = [_]ThumbnailSpace{ testSpace("Off", &.{"Miners"}), testSpace("No region", &.{"Miners"}) };
    spaces[0].enabled = false;
    spaces[1].width = null;
    const cfg = testConfig(&groups, &spaces);

    try testing.expectEqual(@as(?usize, null), spaceFor(&cfg, "Miner"));
    try testing.expect(!anyActive(&cfg));
}

test "login-screen clients go to the Login Screen space ahead of a space taking them" {
    var spaces = [_]ThumbnailSpace{ testSpace("Everyone", &.{}), testSpace("Login Screen", &.{}) };
    spaces[0].takesUnassigned = true;
    spaces[0].takesLoginScreen = true;
    spaces[1].holdsLoginScreen = true;
    const cfg = testConfig(&.{}, &spaces);

    try testing.expectEqual(@as(?usize, 1), spaceFor(&cfg, LOGIN_SCREEN));
    try testing.expectEqual(@as(?usize, 0), spaceFor(&cfg, "Pilot"));
}

test "a space fills with its own characters, then unassigned ones, then login-screen clients" {
    var groups = [_]config_mod.HotkeyGroupConfig{testGroup("Miners", &.{"Miner"})};
    var spaces = [_]ThumbnailSpace{testSpace("Mining", &.{"Miners"})};
    spaces[0].takesUnassigned = true;
    spaces[0].takesLoginScreen = true;
    const cfg = testConfig(&groups, &spaces);

    var assignment = try assign(testing.allocator, &cfg, &.{ LOGIN_SCREEN, "Hauler", "Miner" });
    defer assignment.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), assignment.counts[0]);
    try testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, assignment.rank);
}

test "hotkey group order fills by the space's own groups in hotkey group list order" {
    var groups = [_]config_mod.HotkeyGroupConfig{ testGroup("Other", &.{"Third"}), testGroup("A", &.{"First"}), testGroup("B", &.{ "Second", "Third" }) };
    var spaces = [_]ThumbnailSpace{testSpace("Fleet", &.{ "B", "A" })};
    spaces[0].order = .HotkeyGroups;
    const cfg = testConfig(&groups, &spaces);

    var assignment = try assign(testing.allocator, &cfg, &.{ "Third", "Second", "First" });
    defer assignment.deinit(testing.allocator);
    try testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, assignment.rank);
}

test "character order fills by the Characters list" {
    var characters = [_]config_mod.CharacterConfig{ .{ .name = "Beta" }, .{ .name = "Alpha" } };
    var spaces = [_]ThumbnailSpace{testSpace("Everyone", &.{})};
    spaces[0].takesUnassigned = true;
    var cfg = testConfig(&.{}, &spaces);
    cfg.characters = .fromOwnedSlice(&characters);

    var assignment = try assign(testing.allocator, &cfg, &.{ "Alpha", "Beta" });
    defer assignment.deinit(testing.allocator);
    try testing.expectEqualSlices(usize, &.{ 1, 0 }, assignment.rank);
}

test "a character no space takes is left unassigned" {
    const cfg = testConfig(&.{}, &.{});
    var assignment = try assign(testing.allocator, &cfg, &.{"Pilot"});
    defer assignment.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, null), assignment.space_of[0]);
}
