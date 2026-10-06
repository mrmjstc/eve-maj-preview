//! Upgrades an older profile's JSON before it's parsed, so the profile loader and the profile importer both see the current schema; no I/O.
const std = @import("std");
const values = @import("import/values.zig");

const Value = std.json.Value;

/// Profiles from before thumbnailSpaces kept one fit region and a not-logged-in space as display settings.
pub const SPACES_VERSION = 3;

/// Moves the old fit region and not-logged-in space into thumbnailSpaces; a profile already in the current schema is left alone.
pub fn profile(arena: std.mem.Allocator, root: *Value) !void {
    if (root.* != .object) return;
    const version = values.integerAt(root.*, "formatVersion") orelse 1;
    if (version >= SPACES_VERSION or root.object.get("thumbnailSpaces") != null) return;
    const display = root.object.get("display") orelse return;
    if (display != .object) return;

    var spaces = std.json.Array.init(arena);
    // First, so a client at the login screen keeps landing in its own space ahead of the catch-all.
    if (try rectFields(arena, display, "notLoggedInSpaceX", "notLoggedInSpaceY", "notLoggedInSpaceWidth", "notLoggedInSpaceHeight")) |fields| {
        var space = fields;
        try space.put(arena, "name", .{ .string = "Login Screen" });
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

test "an old fit region becomes an enabled catch-all space with its settings" {
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
    try testing.expectEqualStrings("Login Screen", values.stringAt(spaces[0], "name").?);
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
