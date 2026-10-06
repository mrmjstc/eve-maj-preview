//! Thumbnail spaces: screen regions that the thumbnails of chosen hotkey groups, or of clients at the login screen, auto-fit into.
const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");
const strings = @import("../util/strings.zig");

pub const ThumbnailSpace = struct {
    name: []const u8 = "",
    enabled: bool = true,
    /// Hotkey group names, since a group's id isn't saved; a character in any of them belongs here.
    groups: std.ArrayList([]const u8) = .empty,
    /// Holds clients still at the login screen, as if they were a group.
    holdsLoginScreen: bool = false,
    /// Characters no enabled space holds are added after this space's own, in the first space that has this on.
    takesUnassigned: bool = false,
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
