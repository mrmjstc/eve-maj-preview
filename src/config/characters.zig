//! Per-character overrides and the helpers that rank characters by the configured list.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const wire = @import("wire.zig");
const key_list = @import("key_list.zig");
const ranges_mod = @import("ranges.zig");
const thumbnail = @import("thumbnail.zig");

const KeyList = key_list.KeyList;
const ThumbnailConfig = thumbnail.ThumbnailConfig;

pub const Position = struct {
    x: i32,
    y: i32,

    /// For positions saved by a DPI-unaware process (old saves, EVE-O/EVE-X/EVE-APM imports).
    pub fn scaleFromLegacyDpiUnaware(self: Position) Position {
        const scale = win32.dpiToScale(win32.dpiForPoint(.{ .x = self.x, .y = self.y }));
        return .{ .x = win32.scalePixels(self.x, scale), .y = win32.scalePixels(self.y, scale) };
    }
};

pub const WindowSize = struct {
    width: i32,
    height: i32,
};

pub const CharacterBorderColorsConfig = struct {
    activeBorderColor: ?u32 = null,
    inactiveBorderColor: ?u32 = null,

    pub const Wire = wire.Wire(CharacterBorderColorsConfig);
};

pub const CharacterThumbnailSizeConfig = struct {
    width: ?i32 = null,
    height: ?i32 = null,

    pub const ranges = .{
        .width = ThumbnailConfig.WIDTH,
        .height = ThumbnailConfig.HEIGHT,
    };

    pub fn validate(self: *CharacterThumbnailSizeConfig) void {
        ranges_mod.clamp(CharacterThumbnailSizeConfig, self);
    }
};

pub const CharacterConfig = struct {
    name: []const u8 = "",
    position: ?Position = null,
    windowPosition: ?Position = null,
    /// Saved with windowPosition, for the config dialog's preview; null on positions saved before sizes were.
    windowSize: ?WindowSize = null,
    borderColors: ?CharacterBorderColorsConfig = null,
    nameColor: ?u32 = null,
    thumbnailSize: ?CharacterThumbnailSizeConfig = null,
    displayName: ?[]const u8 = null,
    hotkey: KeyList = .empty,
    excludeFromMinimize: bool = false,
    excludeFromCloseAll: bool = false,
    excludeFromAutoMove: bool = false,
    hideThumbnail: bool = false,
    notificationsMuted: bool = false,
    opacity: ?u8 = null,
    /// The dialog's handle across renames and reorders; 0 until assigned (see config/patch.zig).
    id: u32 = 0,

    pub const runtime_fields = .{"id"};

    pub const ranges = .{
        .opacity = ranges_mod.OPACITY,
    };

    /// ThumbnailConfig.validate() skips these overrides, and a negative size would panic as a usize.
    pub fn validate(self: *CharacterConfig) void {
        ranges_mod.clamp(CharacterConfig, self);
    }

    pub const Wire = wire.Wire(CharacterConfig);
};

/// Name -> first index in the configured Characters list, for ranking thumbnails; caller owns the map.
pub fn buildCharacterOrderMap(characters: []const CharacterConfig, allocator: std.mem.Allocator) !std.StringHashMap(usize) {
    var map: std.StringHashMap(usize) = .init(allocator);
    errdefer map.deinit();
    for (characters, 0..) |character, i| {
        const entry = try map.getOrPut(character.name);
        if (!entry.found_existing) entry.value_ptr.* = i;
    }
    return map;
}

/// Names missing from order_map sort last; ties fall back to array position.
pub fn orderMapLessThan(order_map: *const std.StringHashMap(usize), a_name: []const u8, b_name: []const u8, a_index: usize, b_index: usize) bool {
    const a_order = order_map.get(a_name);
    const b_order = order_map.get(b_name);
    if (a_order) |a_rank| {
        if (b_order) |b_rank| {
            if (a_rank != b_rank) return a_rank < b_rank;
        } else return true;
    } else if (b_order != null) return false;
    return a_index < b_index;
}

const testing = std.testing;

test "buildCharacterOrderMap keeps each name's first index" {
    const characters = [_]CharacterConfig{ .{ .name = "B" }, .{ .name = "A" }, .{ .name = "B" } };
    var order_map = try buildCharacterOrderMap(&characters, testing.allocator);
    defer order_map.deinit();
    try testing.expectEqual(@as(?usize, 0), order_map.get("B"));
    try testing.expectEqual(@as(?usize, 1), order_map.get("A"));
}

test "orderMapLessThan ranks listed names by the list, then unlisted ones last by array position" {
    const characters = [_]CharacterConfig{ .{ .name = "B" }, .{ .name = "A" } };
    var order_map = try buildCharacterOrderMap(&characters, testing.allocator);
    defer order_map.deinit();
    try testing.expect(orderMapLessThan(&order_map, "B", "A", 5, 0));
    try testing.expect(orderMapLessThan(&order_map, "A", "Z", 9, 0));
    try testing.expect(!orderMapLessThan(&order_map, "Z", "A", 0, 9));
    try testing.expect(orderMapLessThan(&order_map, "Y", "Z", 0, 1));
    try testing.expect(!orderMapLessThan(&order_map, "Z", "Y", 1, 0));
}
