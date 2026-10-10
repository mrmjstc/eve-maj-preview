//! Per-character overrides and the helpers that rank characters by the configured list.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const wire = @import("wire.zig");
const key_list = @import("key_list.zig");
const ranges_mod = @import("ranges.zig");
const ThumbnailConfig = @import("thumbnail.zig").ThumbnailConfig;

const KeyList = key_list.KeyList;

pub const Position = struct {
    x: i32,
    y: i32,

    /// For positions saved by a DPI-unaware process (old saves, EVE-O/EVE-X/EVE-APM imports).
    pub fn scaleFromLegacyDpiUnaware(self: Position) Position {
        const scale = win32.dpiToScale(win32.dpiForPoint(.{ .x = self.x, .y = self.y }));
        return .{ .x = win32.scalePixels(self.x, scale), .y = win32.scalePixels(self.y, scale) };
    }
};

/// A saved EVE client window's size, kept beside its windowPosition.
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
    /// Identifies this entry to the config dialog while its name and position in the list change; 0 until assigned (see config/patch.zig).
    id: u32 = 0,

    pub const runtime_fields = .{"id"};

    pub const ranges = .{
        .opacity = ranges_mod.OPACITY,
    };

    /// ThumbnailConfig.validate() doesn't reach these overrides, and a negative size would panic once narrowed to usize downstream.
    pub fn validate(self: *CharacterConfig) void {
        ranges_mod.clamp(CharacterConfig, self);
    }

    pub const Wire = wire.Wire(CharacterConfig);
};

/// Name -> first index in the configured Characters list, for ranking thumbnails; caller owns the map.
pub fn buildCharacterOrderMap(characters: []const CharacterConfig, allocator: std.mem.Allocator) !std.StringHashMap(usize) {
    var map = std.StringHashMap(usize).init(allocator);
    errdefer map.deinit();
    for (characters, 0..) |character, i| {
        const gop = try map.getOrPut(character.name);
        if (!gop.found_existing) gop.value_ptr.* = i;
    }
    return map;
}

/// Ranks a_name/b_name by order_map, falling back to array position for ties or names absent from order_map (which always sort last).
pub fn orderMapLessThan(order_map: *const std.StringHashMap(usize), a_name: []const u8, b_name: []const u8, a_index: usize, b_index: usize) bool {
    const a_order = order_map.get(a_name);
    const b_order = order_map.get(b_name);
    if (a_order) |ao| {
        if (b_order) |bo| {
            if (ao != bo) return ao < bo;
        } else return true;
    } else if (b_order != null) return false;
    return a_index < b_index;
}
