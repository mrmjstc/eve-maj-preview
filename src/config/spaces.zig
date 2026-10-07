//! Thumbnail spaces: screen regions that the thumbnails of chosen hotkey groups, login-screen clients or unassigned characters auto-fit into.
const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");
const strings = @import("../util/strings.zig");

pub const LOGIN_SCREEN_NAME = "Login Screen";
pub const UNASSIGNED_NAME = "Unassigned Characters";

pub const ThumbnailSpace = struct {
    name: []const u8 = "",
    enabled: bool = true,
    /// Hotkey group names, since a group's id isn't saved; a character in any of them belongs here.
    groups: std.ArrayList([]const u8) = .empty,
    /// Marks the Login Screen space, which holds clients still at the login screen.
    holdsLoginScreen: bool = false,
    /// Marks the Unassigned Characters space, which holds characters no other active space holds.
    holdsUnassigned: bool = false,
    /// Characters no active space holds fill in after this space's own, in the first space with this on, unless the Unassigned Characters space is active.
    takesUnassigned: bool = false,
    /// Login-screen clients fill in last, in the first space with this on, unless the Login Screen space is active.
    takesLoginScreen: bool = false,
    x: ?i32 = null,
    y: ?i32 = null,
    width: ?i32 = null,
    height: ?i32 = null,
    direction: types.RegionFitDirection = .RowFirst_LTR_TTB,
    order: types.RegionFitOrder = .Characters,
    spacing: i32 = 0,
    /// Stops cells growing past the configured thumbnail size, leaving the rest of the region empty.
    limitToThumbnailSize: bool = false,
    /// Identifies this space to the config dialog while its name and position in the list change; 0 until assigned (see config/patch.zig).
    id: u32 = 0,

    pub const runtime_fields = .{"id"};

    pub const ranges = .{
        .x = ranges_mod.SCREEN_X,
        .y = ranges_mod.SCREEN_Y,
        .width = .{ 1, ranges_mod.SCREEN_X[1] - ranges_mod.SCREEN_X[0] },
        .height = .{ 1, ranges_mod.SCREEN_Y[1] - ranges_mod.SCREEN_Y[0] },
        .spacing = .{ 0, 200 },
    };

    /// Where `group_name` is in groups, or null when this space doesn't hold it.
    pub fn groupIndex(self: *const ThumbnailSpace, group_name: []const u8) ?usize {
        return strings.indexOfString(self.groups.items, group_name);
    }

    pub fn validate(self: *ThumbnailSpace) void {
        ranges_mod.clamp(ThumbnailSpace, self);
    }

    pub const Wire = wire.Wire(ThumbnailSpace);
};

/// Adds the Login Screen space first and the Unassigned Characters space second, both off, when they're missing, so every profile has both; returns whether it added either.
pub fn ensureSpecialSpaces(allocator: std.mem.Allocator, list: *std.ArrayList(ThumbnailSpace)) !bool {
    var added = false;
    if (!hasSpace(list.items, "holdsLoginScreen")) {
        const name = try allocator.dupe(u8, LOGIN_SCREEN_NAME);
        errdefer allocator.free(name);
        try list.insert(allocator, 0, .{ .name = name, .enabled = false, .holdsLoginScreen = true });
        added = true;
    }
    if (!hasSpace(list.items, "holdsUnassigned")) {
        const name = try allocator.dupe(u8, UNASSIGNED_NAME);
        errdefer allocator.free(name);
        try list.insert(allocator, @min(1, list.items.len), .{ .name = name, .enabled = false, .holdsUnassigned = true });
        added = true;
    }
    return added;
}

/// Moves the Login Screen space to the top and the Unassigned Characters space under it, keeping the rest in order; placement finds both by their mark, so only the list changes.
pub fn keepSpecialSpacesFirst(list: []ThumbnailSpace) void {
    var front: usize = 0;
    inline for (.{ "holdsLoginScreen", "holdsUnassigned" }) |mark| {
        if (indexOfSpace(list[front..], mark)) |offset| {
            std.mem.rotate(ThumbnailSpace, list[front .. front + offset + 1], offset);
            front += 1;
        }
    }
}

/// Only the first space marked as each special space keeps the mark, and a space is at most one of them.
pub fn keepOneOfEachSpecialSpace(list: []ThumbnailSpace) void {
    var has_login_screen = false;
    var has_unassigned = false;
    for (list) |*space| {
        if (space.holdsLoginScreen) {
            if (has_login_screen) space.holdsLoginScreen = false;
            has_login_screen = true;
            space.holdsUnassigned = false;
        }
        if (space.holdsUnassigned) {
            if (has_unassigned) space.holdsUnassigned = false;
            has_unassigned = true;
        }
    }
}

fn hasSpace(items: []const ThumbnailSpace, comptime mark: []const u8) bool {
    return indexOfSpace(items, mark) != null;
}

fn indexOfSpace(items: []const ThumbnailSpace, comptime mark: []const u8) ?usize {
    for (items, 0..) |space, i| {
        if (@field(space, mark)) return i;
    }
    return null;
}

const testing = std.testing;

test "a list missing the special spaces gets Login Screen first and Unassigned Characters second, both off" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var list: std.ArrayList(ThumbnailSpace) = .empty;
    try list.append(arena.allocator(), .{ .name = "Miners" });
    try testing.expect(try ensureSpecialSpaces(arena.allocator(), &list));
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expect(list.items[0].holdsLoginScreen and !list.items[0].enabled);
    try testing.expectEqualStrings(LOGIN_SCREEN_NAME, list.items[0].name);
    try testing.expect(list.items[1].holdsUnassigned and !list.items[1].enabled);
    try testing.expectEqualStrings(UNASSIGNED_NAME, list.items[1].name);
    try testing.expectEqualStrings("Miners", list.items[2].name);

    try testing.expect(!try ensureSpecialSpaces(arena.allocator(), &list));
    try testing.expectEqual(@as(usize, 3), list.items.len);
}

test "special spaces move to the top with the other spaces kept in order" {
    var list = [_]ThumbnailSpace{
        .{ .name = "A" },
        .{ .name = "Unassigned", .holdsUnassigned = true },
        .{ .name = "B" },
        .{ .name = "Login", .holdsLoginScreen = true },
        .{ .name = "C" },
    };
    keepSpecialSpacesFirst(&list);
    const expected = [_][]const u8{ "Login", "Unassigned", "A", "B", "C" };
    for (expected, list) |name, space| try testing.expectEqualStrings(name, space.name);
}

test "only the first space marked as each special space keeps the mark" {
    var list = [_]ThumbnailSpace{
        .{ .name = "A", .holdsLoginScreen = true, .holdsUnassigned = true },
        .{ .name = "B", .holdsLoginScreen = true },
        .{ .name = "C", .holdsUnassigned = true },
        .{ .name = "D", .holdsUnassigned = true },
    };
    keepOneOfEachSpecialSpace(&list);
    try testing.expect(list[0].holdsLoginScreen and !list[0].holdsUnassigned);
    try testing.expect(!list[1].holdsLoginScreen);
    try testing.expect(list[2].holdsUnassigned);
    try testing.expect(!list[3].holdsUnassigned);
}
