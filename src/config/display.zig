//! Where thumbnails start and are placed, which view shows, and on which monitor.
const types = @import("types.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");

pub const DisplayConfig = struct {
    startX: i32 = 10,
    startY: i32 = 10,

    /// Gap between unplaced thumbnails, lined up from startX/startY instead of stacking.
    newThumbnailSpacing: i32 = 10,

    viewMode: types.ViewMode = .Thumbnails,

    /// Manual ignores thumbnailSpaces, so every thumbnail is placed by hand.
    placementMode: types.PlacementMode = .Manual,
    hideThumbnailsDuringRegionSelect: bool = true,

    monitorIndex: ?u32 = null,
    useMonitorWorkArea: bool = true,

    honorSavedPositions: bool = true,

    const SPACING = .{ 0, 200 };

    pub const ranges = .{
        .startX = ranges_mod.SCREEN_X,
        .startY = ranges_mod.SCREEN_Y,
        .newThumbnailSpacing = SPACING,
        .monitorIndex = .{ 0, 9 },
    };

    pub fn validate(self: *DisplayConfig) void {
        ranges_mod.clamp(DisplayConfig, self);
    }

    pub const Wire = wire.Wire(DisplayConfig);
};
