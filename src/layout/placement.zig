//! Where each thumbnail goes: its thumbnail space's grid, its saved position, or the new-thumbnail row.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const types = @import("../config/types.zig");
const scout = @import("../clients/scout.zig");
const window = @import("../thumbnail/window.zig");
const monitors = @import("monitors.zig");
const region_grid = @import("region_grid.zig");
const spaces = @import("spaces.zig");
const log = @import("../log.zig");

const ThumbnailWindow = window.ThumbnailWindow;
const RegionFitGrid = region_grid.RegionFitGrid;
const RegionFitCap = region_grid.RegionFitCap;
const scalePixels = win32.scalePixels;
const dpiToScale = win32.dpiToScale;
const slog = log.Scoped("layout");

/// One active space's grid for a layout pass; sizes are physical pixels.
pub const SpaceCell = struct {
    region: win32.RECT,
    grid: RegionFitGrid,
    direction: types.RegionFitDirection,
    spacing: i32,

    pub fn position(self: SpaceCell, rank: usize) config_mod.Position {
        return region_grid.regionFitPositionForGrid(self.region, self.grid, rank, self.direction, self.spacing);
    }
};

/// Indexed like thumbnailSpaces; null for an inactive space.
pub const SpaceCells = [spaces.MAX_SPACES]?SpaceCell;

/// Read-only view over what thumbnail placement depends on: config plus the current thumbnail list (for counts and ranks).
pub const Layout = struct {
    config: *const config_mod.Config,
    thumbnails: []const ThumbnailWindow,

    /// Always null for the generic "not logged in" name, which never has a saved position of its own.
    fn savedPosition(self: Layout, character_name: []const u8) ?config_mod.Position {
        if (scout.isGenericCharacterName(character_name) or !self.config.display.honorSavedPositions) return null;
        return self.config.getCharacterPosition(character_name);
    }

    /// Ranks this thumbnail's slot in the left-to-right spawn row, which only hand-placed thumbnails with no saved position join.
    fn unpositionedIndex(self: Layout, up_to: usize) usize {
        var count: usize = 0;
        for (self.thumbnails[0..@min(up_to, self.thumbnails.len)]) |thumbnail| {
            if (self.savedPosition(thumbnail.character_name) != null) continue;
            if (spaces.spaceFor(self.config, thumbnail.character_name) != null) continue;
            count += 1;
        }
        return count;
    }

    pub fn spaceCounts(self: Layout) spaces.SpaceCounts {
        var counts: spaces.SpaceCounts = @splat(0);
        for (self.thumbnails) |thumbnail| {
            if (spaces.spaceFor(self.config, thumbnail.character_name)) |space_index| counts[space_index] += 1;
        }
        return counts;
    }

    /// Every active space's grid, sized for `counts` cells; the same for every thumbnail in a pass, so compute it once.
    pub fn spaceCells(self: Layout, counts: *const spaces.SpaceCounts) SpaceCells {
        var cells: SpaceCells = @splat(null);
        for (spaces.listed(self.config), 0..) |*space, i| {
            const region = spaces.activeRect(space) orelse continue;
            const grid = region_grid.calculateRegionFitGrid(region, counts[i], space.spacing, space.spacing, self.regionFitAspectRatio(), self.thumbnailSizeCap(region, space.limitToThumbnailSize));
            cells[i] = .{ .region = region, .grid = grid, .direction = space.direction, .spacing = space.spacing };
        }
        return cells;
    }

    /// A hand-placed thumbnail's spot: its saved position, else the next slot in the spawn row.
    pub fn calculateThumbnailPosition(
        self: Layout,
        character_name: []const u8,
        thumbnail_width: i32,
        thumbnail_height: i32,
        index: usize,
        monitor_bounds: ?win32.RECT,
        scale: f32,
    ) config_mod.Position {
        const display = &self.config.display;

        if (self.savedPosition(character_name)) |saved_position| {
            // Saved positions are absolute physical pixels (see saveThumbnailPosition), so scaling doesn't apply.
            slog.debug("Using saved position for {s}: ({}, {})", .{ character_name, saved_position.x, saved_position.y });
            return .{ .x = saved_position.x, .y = saved_position.y };
        }

        // Wraps to a new row once a row runs out of width, instead of overlapping.
        const slot = @as(i32, @intCast(self.unpositionedIndex(index)));
        const step_x = thumbnail_width + scalePixels(display.newThumbnailSpacing, scale);
        const step_y = thumbnail_height + scalePixels(display.newThumbnailSpacing, scale);

        const bounds = monitor_bounds orelse win32.virtualScreenRect();

        // startX/startY are monitor-relative when a monitor is configured, absolute otherwise.
        const start_x = scalePixels(display.startX, scale) + (if (monitor_bounds != null) bounds.left else 0);
        const start_y = scalePixels(display.startY, scale) + (if (monitor_bounds != null) bounds.top else 0);

        const columns_per_row = @max(@divTrunc(bounds.right - start_x, @max(step_x, 1)), 1);
        const row = @divTrunc(slot, columns_per_row);
        const column = @mod(slot, columns_per_row);
        slog.debug("Thumbnail #{} has no saved position, spawning at unpositioned slot {} (row {}, col {})", .{ index, slot, row, column });

        var position: config_mod.Position = .{ .x = start_x + column * step_x, .y = start_y + row * step_y };

        // Keeps a thumbnail from spawning fully off-screen; only bites once rows overflow the screen's height.
        const clamp_margin = 50;
        const monitor_suffix = if (monitor_bounds != null) " for monitor" else "";
        clampAxisWithWarn(&position.x, bounds.left - clamp_margin, bounds.right - thumbnail_width + clamp_margin, "X", "left", "right", monitor_suffix);
        clampAxisWithWarn(&position.y, bounds.top - clamp_margin, bounds.bottom - thumbnail_height + clamp_margin, "Y", "up", "down", monitor_suffix);

        return position;
    }

    /// Spaces always keep the configured thumbnail's shape.
    fn regionFitAspectRatio(self: Layout) f32 {
        return @as(f32, @floatFromInt(self.config.thumbnail.width)) / @as(f32, @floatFromInt(self.config.thumbnail.height));
    }

    /// In physical pixels, scaled for the space's own monitor rather than the app's; null unless `should_limit`.
    fn thumbnailSizeCap(self: Layout, region: win32.RECT, should_limit: bool) ?RegionFitCap {
        if (!should_limit) return null;
        const center: win32.POINT = .{ .x = @divTrunc(region.left + region.right, 2), .y = @divTrunc(region.top + region.bottom, 2) };
        const scale = dpiToScale(monitors.dpiForMonitor(win32.nearestMonitor(center)));
        return .{ .width = scalePixels(self.config.thumbnail.width, scale), .height = scalePixels(self.config.thumbnail.height, scale) };
    }
};

/// The cell grid this character's space uses, or null when it's placed by hand.
pub fn cellFor(config: *const config_mod.Config, cells: *const SpaceCells, character_name: []const u8) ?SpaceCell {
    const space_index = spaces.spaceFor(config, character_name) orelse return null;
    return cells[space_index];
}

fn clampAxisWithWarn(value: *i32, min: i32, max: i32, axis_label: []const u8, low_word: []const u8, high_word: []const u8, context: []const u8) void {
    if (value.* < min) {
        slog.warn("Thumbnail {s} position {} too far {s}{s}, clamping to {}", .{ axis_label, value.*, low_word, context, min });
        value.* = min;
    } else if (value.* > max) {
        slog.warn("Thumbnail {s} position {} too far {s}{s}, clamping to {}", .{ axis_label, value.*, high_word, context, max });
        value.* = max;
    }
}

const testing = std.testing;

/// Wide enough for four 200px thumbnails a row at the default 10px start and spacing.
const TEST_BOUNDS: win32.RECT = .{ .left = 0, .top = 0, .right = 1000, .bottom = 800 };
const TEST_WIDTH = 200;
const TEST_HEIGHT = 100;

fn testConfig() !config_mod.Config {
    return config_mod.Config.getDefaultsWithProfile(testing.allocator, "Test");
}

fn savePosition(config: *config_mod.Config, character_name: []const u8, x: i32, y: i32) !void {
    (try config.getOrCreateCharacter(character_name)).position = .{ .x = x, .y = y };
}

fn testThumbnail(character_name: []const u8) ThumbnailWindow {
    // Only placement's arithmetic reads the record; the handles never reach Win32.
    const sentinel: win32.HWND = @ptrFromInt(1);
    return .{
        .hwnd = sentinel,
        .text_hwnd = sentinel,
        .thumbnail_id = sentinel,
        .source_hwnd = sentinel,
        .is_eve_client = true,
        .character_name = character_name,
        .system_name = "",
        .auto_minimize = .{ .inactive_since = .{} },
        .cached_group_badge_label = "",
    };
}

fn spawnAt(config: *const config_mod.Config, thumbnails: []const ThumbnailWindow, character_name: []const u8, index: usize, bounds: win32.RECT) config_mod.Position {
    const layout: Layout = .{ .config = config, .thumbnails = thumbnails };
    return layout.calculateThumbnailPosition(character_name, TEST_WIDTH, TEST_HEIGHT, index, bounds, 1.0);
}

test "a saved position wins over the spawn row, and isn't scaled" {
    var config = try testConfig();
    defer config.deinit();
    try savePosition(&config, "Saved", 500, 600);
    const layout: Layout = .{ .config = &config, .thumbnails = &.{} };
    const position = layout.calculateThumbnailPosition("Saved", TEST_WIDTH, TEST_HEIGHT, 0, TEST_BOUNDS, 2.0);
    try testing.expectEqual(@as(i32, 500), position.x);
    try testing.expectEqual(@as(i32, 600), position.y);
}

test "the login-screen name never takes a saved position" {
    var config = try testConfig();
    defer config.deinit();
    try savePosition(&config, "EVE", 500, 600);
    const position = spawnAt(&config, &.{}, "EVE", 0, TEST_BOUNDS);
    try testing.expectEqual(@as(i32, 10), position.x);
    try testing.expectEqual(@as(i32, 10), position.y);
}

test "with saved positions not honored, a saved character spawns in the row" {
    var config = try testConfig();
    defer config.deinit();
    try savePosition(&config, "Saved", 500, 600);
    config.display.honorSavedPositions = false;
    const position = spawnAt(&config, &.{}, "Saved", 0, TEST_BOUNDS);
    try testing.expectEqual(@as(i32, 10), position.x);
}

test "each unplaced thumbnail takes the next slot, skipping ones with saved positions" {
    var config = try testConfig();
    defer config.deinit();
    try savePosition(&config, "Saved", 500, 600);
    const thumbnails = [_]ThumbnailWindow{ testThumbnail("First"), testThumbnail("Saved"), testThumbnail("Second") };
    const position = spawnAt(&config, &thumbnails, "Second", 2, TEST_BOUNDS);
    try testing.expectEqual(@as(i32, 10 + TEST_WIDTH + 10), position.x);
    try testing.expectEqual(@as(i32, 10), position.y);
}

test "the spawn row wraps once it runs out of width" {
    var config = try testConfig();
    defer config.deinit();
    const thumbnails = [_]ThumbnailWindow{ testThumbnail("A"), testThumbnail("B"), testThumbnail("C"), testThumbnail("D"), testThumbnail("E") };
    const position = spawnAt(&config, &thumbnails, "E", 4, TEST_BOUNDS);
    try testing.expectEqual(@as(i32, 10), position.x);
    try testing.expectEqual(@as(i32, 10 + TEST_HEIGHT + 10), position.y);
}

test "a spawn spot past the screen's bottom is clamped back near it" {
    var config = try testConfig();
    defer config.deinit();
    const short: win32.RECT = .{ .left = 0, .top = 0, .right = 1000, .bottom = 150 };
    const thumbnails = [_]ThumbnailWindow{ testThumbnail("A"), testThumbnail("B"), testThumbnail("C"), testThumbnail("D"), testThumbnail("E") };
    const position = spawnAt(&config, &thumbnails, "E", 4, short);
    try testing.expectEqual(@as(i32, short.bottom - TEST_HEIGHT + 50), position.y);
}

test "the spawn row starts relative to the chosen monitor" {
    var config = try testConfig();
    defer config.deinit();
    const second_monitor: win32.RECT = .{ .left = 1920, .top = 0, .right = 2920, .bottom = 800 };
    const position = spawnAt(&config, &.{}, "First", 0, second_monitor);
    try testing.expectEqual(@as(i32, 1930), position.x);
    try testing.expectEqual(@as(i32, 10), position.y);
}
