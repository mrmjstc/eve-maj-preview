//! Where each thumbnail goes: its thumbnail space's grid, its saved position, or the new-thumbnail row.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const types = @import("../config/types.zig");
const scout = @import("../clients/scout.zig");
const ThumbnailWindow = @import("../thumbnail/window.zig").ThumbnailWindow;
const monitors = @import("monitors.zig");
const spaces = @import("spaces.zig");
const log = @import("../log.zig");

const scalePixels = win32.scalePixels;
const dpiToScale = win32.dpiToScale;
const slog = log.scoped("layout");

/// box_width/box_height is the per-column/row share of the region, used only to pick the column count; cell_width/cell_height is the actual aspect-corrected thumbnail size used for positioning.
pub const RegionFitGrid = struct { columns: u32, rows: u32, box_width: i32, box_height: i32, cell_width: i32, cell_height: i32 };

pub const RegionFitCap = struct { width: i32, height: i32 };

/// One active space's grid for a layout pass; sizes are physical pixels.
pub const SpaceCell = struct {
    region: win32.RECT,
    grid: RegionFitGrid,
    direction: types.RegionFitDirection,
    spacing: i32,

    pub fn position(self: SpaceCell, rank: usize) config_mod.Position {
        return regionFitPositionForGrid(self.region, self.grid, rank, self.direction, self.spacing);
    }
};

/// Indexed like thumbnailSpaces; null for an inactive space.
pub const SpaceCells = [spaces.MAX_SPACES]?SpaceCell;

/// Read-only view over what thumbnail placement depends on: config plus the current thumbnail list (for counts and ranks).
pub const Layout = struct {
    config: *const config_mod.Config,
    thumbnails: []const ThumbnailWindow,

    /// Always false for the generic "not logged in" name, which never has a saved position of its own.
    fn hasSavedPosition(self: Layout, character_name: []const u8) bool {
        const cfg = &self.config.display;
        return !scout.isGenericCharacterName(character_name) and
            cfg.honorSavedPositions and
            self.config.getCharacterPosition(character_name) != null;
    }

    /// Ranks this thumbnail's slot in the left-to-right spawn row, which only hand-placed thumbnails with no saved position join.
    fn unpositionedIndex(self: Layout, up_to: usize) usize {
        var count: usize = 0;
        for (self.thumbnails[0..@min(up_to, self.thumbnails.len)]) |thumbnail| {
            if (self.hasSavedPosition(thumbnail.character_name)) continue;
            if (spaces.spaceFor(self.config, thumbnail.character_name) != null) continue;
            count += 1;
        }
        return count;
    }

    /// How many current thumbnails each space holds.
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
            const grid = calculateRegionFitGrid(region, counts[i], space.spacing, space.spacing, self.regionFitAspectRatio(), self.thumbnailSizeCap(region, space.limitToThumbnailSize));
            cells[i] = .{ .region = region, .grid = grid, .direction = space.direction, .spacing = space.spacing };
        }
        return cells;
    }

    /// A hand-placed thumbnail's spot: its saved position, else the next slot in the spawn row.
    pub fn calculateThumbnailPosition(
        self: Layout,
        character_name: []const u8,
        thumb_width: i32,
        thumb_height: i32,
        index: usize,
        monitor_bounds: ?win32.RECT,
        scale: f32,
    ) config_mod.Position {
        const cfg = &self.config.display;

        if (self.hasSavedPosition(character_name)) {
            // Saved positions are absolute physical pixels (see saveThumbnailPosition), so scaling doesn't apply.
            const saved_pos = self.config.getCharacterPosition(character_name).?;
            slog.debug("Using saved position for {s}: ({}, {})", .{ character_name, saved_pos.x, saved_pos.y });
            return .{ .x = saved_pos.x, .y = saved_pos.y };
        }

        // No saved position: flow left-to-right from startX/startY, wrapping to a new row instead of overlapping once a row runs out of width.
        const slot = @as(i32, @intCast(self.unpositionedIndex(index)));
        const step_x = thumb_width + scalePixels(cfg.newThumbnailSpacing, scale);
        const step_y = thumb_height + scalePixels(cfg.newThumbnailSpacing, scale);

        // Monitor bounds if one's configured, otherwise the real current virtual screen, not a guessed multi-monitor range.
        const bounds = monitor_bounds orelse win32.virtualScreenRect();

        // startX/startY are monitor-relative when a monitor is configured, absolute otherwise.
        const start_x = scalePixels(cfg.startX, scale) + (if (monitor_bounds != null) bounds.left else 0);
        const start_y = scalePixels(cfg.startY, scale) + (if (monitor_bounds != null) bounds.top else 0);

        const columns_per_row = @max(@divTrunc(bounds.right - start_x, @max(step_x, 1)), 1);
        const row = @divTrunc(slot, columns_per_row);
        const col = @mod(slot, columns_per_row);
        slog.debug("Thumbnail #{} has no saved position, spawning at unpositioned slot {} (row {}, col {})", .{ index, slot, row, col });

        var pos = config_mod.Position{ .x = start_x + col * step_x, .y = start_y + row * step_y };

        // Clamp to keep thumbnails from spawning fully off-screen, while still allowing edge placement; only bites once rows also overflow the screen's height.
        const clamp_margin = 50;
        const monitor_suffix = if (monitor_bounds != null) " for monitor" else "";
        clampAxisWithWarn(&pos.x, bounds.left - clamp_margin, bounds.right - thumb_width + clamp_margin, "X", "left", "right", monitor_suffix);
        clampAxisWithWarn(&pos.y, bounds.top - clamp_margin, bounds.bottom - thumb_height + clamp_margin, "Y", "up", "down", monitor_suffix);

        return pos;
    }

    /// Spaces always keep the configured thumbnail's shape; limitToThumbnailSize additionally caps its absolute size.
    fn regionFitAspectRatio(self: Layout) f32 {
        return @as(f32, @floatFromInt(self.config.thumbnail.width)) / @as(f32, @floatFromInt(self.config.thumbnail.height));
    }

    /// Physical-pixel cap on a space's cell size, DPI-scaled for the space's own monitor (which may differ from the app's configured monitor); null when `limit_enabled` is off.
    fn thumbnailSizeCap(self: Layout, region: win32.RECT, limit_enabled: bool) ?RegionFitCap {
        if (!limit_enabled) return null;
        const center = win32.POINT{ .x = @divTrunc(region.left + region.right, 2), .y = @divTrunc(region.top + region.bottom, 2) };
        const dpi = if (win32.nearestMonitor(center)) |monitor| monitors.getMonitorDpi(monitor) else monitors.defaultDpi();
        const scale = dpiToScale(dpi);
        return .{ .width = scalePixels(self.config.thumbnail.width, scale), .height = scalePixels(self.config.thumbnail.height, scale) };
    }

    /// A hand-placed thumbnail's size before DPI scaling: its own if set, else the configured one.
    pub fn configuredSize(self: Layout, character_name: []const u8) struct { width: i32, height: i32 } {
        const char_size = self.config.getCharacterSize(character_name) orelse return .{ .width = self.config.thumbnail.width, .height = self.config.thumbnail.height };
        return .{
            .width = char_size.width orelse self.config.thumbnail.width,
            .height = char_size.height orelse self.config.thumbnail.height,
        };
    }
};

/// The cell grid this character's space uses, or null when it's placed by hand.
pub fn cellFor(cfg: *const config_mod.Config, cells: *const SpaceCells, character_name: []const u8) ?SpaceCell {
    const space_index = spaces.spaceFor(cfg, character_name) orelse return null;
    return cells[space_index];
}

/// Grows one column or row at a time from a single full-region cell, whichever yields the bigger cell, so the grid grows incrementally instead of re-optimizing from scratch per count.
pub fn calculateRegionFitGrid(region: win32.RECT, count: usize, spacing_x: i32, spacing_y: i32, aspect_ratio: f32, max_cell: ?RegionFitCap) RegionFitGrid {
    const n: u32 = @intCast(@max(count, 1));
    const region_width = region.right - region.left;
    const region_height = region.bottom - region.top;

    // Under a size cap, growing either axis often yields the same capped cell size; break that tie toward whichever axis has more natural room, so one column/row fills up before a second one starts.
    const prefer_rows_on_tie = if (max_cell) |cap|
        regionFitAxisCapacity(region_height, spacing_y, cap.height) >= regionFitAxisCapacity(region_width, spacing_x, cap.width)
    else
        false;

    var columns: u32 = 1;
    var rows: u32 = 1;
    var grid = regionFitGridForDims(region_width, region_height, columns, rows, spacing_x, spacing_y, aspect_ratio, max_cell);

    while (columns * rows < n) {
        const grow_columns = regionFitGridForDims(region_width, region_height, columns + 1, rows, spacing_x, spacing_y, aspect_ratio, max_cell);
        const grow_rows = regionFitGridForDims(region_width, region_height, columns, rows + 1, spacing_x, spacing_y, aspect_ratio, max_cell);
        const area_columns = regionFitCellArea(grow_columns);
        const area_rows = regionFitCellArea(grow_rows);
        const take_columns = if (area_columns != area_rows) area_columns > area_rows else !prefer_rows_on_tie;
        if (take_columns) {
            columns += 1;
            grid = grow_columns;
        } else {
            rows += 1;
            grid = grow_rows;
        }
    }

    return grid;
}

/// The top-left of cell `index` once the grid fills in `direction`.
pub fn regionFitPositionForGrid(region: win32.RECT, grid: RegionFitGrid, index: usize, direction: types.RegionFitDirection, spacing: i32) config_mod.Position {
    const cell = regionFitColRow(direction, index, grid.columns, grid.rows);
    // Stride by cell size, not the wider box, so slack collects at the region's far edge instead of as gaps between thumbnails.
    return .{
        .x = region.left + cell.col * (grid.cell_width + spacing),
        .y = region.top + cell.row * (grid.cell_height + spacing),
    };
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

/// Floors at 1px (a Win32 API-validity floor, not a usability minimum).
fn fitAspect(box_width: i32, box_height: i32, aspect_ratio: f32) struct { width: i32, height: i32 } {
    if (box_width <= 0 or box_height <= 0) return .{ .width = 1, .height = 1 };

    var width = box_width;
    var height: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(width)) / aspect_ratio));
    if (height > box_height) {
        height = box_height;
        width = @intFromFloat(@round(@as(f32, @floatFromInt(height)) * aspect_ratio));
    }
    return .{ .width = @max(width, 1), .height = @max(height, 1) };
}

fn regionFitGridForDims(region_width: i32, region_height: i32, columns: u32, rows: u32, spacing_x: i32, spacing_y: i32, aspect_ratio: f32, max_cell: ?RegionFitCap) RegionFitGrid {
    const box_width = @max(@divTrunc(region_width - spacing_x * (@as(i32, @intCast(columns)) - 1), @as(i32, @intCast(columns))), 1);
    const box_height = @max(@divTrunc(region_height - spacing_y * (@as(i32, @intCast(rows)) - 1), @as(i32, @intCast(rows))), 1);
    const fit_width = if (max_cell) |cap| @min(box_width, cap.width) else box_width;
    const fit_height = if (max_cell) |cap| @min(box_height, cap.height) else box_height;
    const cell = fitAspect(fit_width, fit_height, aspect_ratio);
    return .{ .columns = columns, .rows = rows, .box_width = box_width, .box_height = box_height, .cell_width = cell.width, .cell_height = cell.height };
}

fn regionFitCellArea(grid: RegionFitGrid) i64 {
    return @as(i64, grid.cell_width) * @as(i64, grid.cell_height);
}

/// How many cap-sized cells fit along one axis; used only to break area ties under a size cap (see calculateRegionFitGrid).
fn regionFitAxisCapacity(dimension: i32, spacing: i32, cell_dimension: i32) u32 {
    return @intCast(@max(@divTrunc(dimension + spacing, cell_dimension + spacing), 1));
}

/// BTT/RTL directions stay within [0, rows/columns) since the region is fixed-size.
fn regionFitColRow(direction: types.RegionFitDirection, index: usize, columns: u32, rows: u32) struct { col: i32, row: i32 } {
    return switch (direction) {
        .RowFirst_RTL_TTB => .{ .col = @as(i32, @intCast(columns - 1)) - @as(i32, @intCast(index % columns)), .row = @intCast(index / columns) },
        .RowFirst_LTR_BTT => .{ .col = @intCast(index % columns), .row = @as(i32, @intCast(rows - 1)) - @as(i32, @intCast(index / columns)) },
        .RowFirst_RTL_BTT => .{ .col = @as(i32, @intCast(columns - 1)) - @as(i32, @intCast(index % columns)), .row = @as(i32, @intCast(rows - 1)) - @as(i32, @intCast(index / columns)) },
        .ColumnFirst_TTB_LTR => .{ .col = @intCast(index / rows), .row = @intCast(index % rows) },
        .ColumnFirst_BTT_LTR => .{ .col = @intCast(index / rows), .row = @as(i32, @intCast(rows - 1)) - @as(i32, @intCast(index % rows)) },
        .ColumnFirst_TTB_RTL => .{ .col = @as(i32, @intCast(columns - 1)) - @as(i32, @intCast(index / rows)), .row = @intCast(index % rows) },
        .ColumnFirst_BTT_RTL => .{ .col = @as(i32, @intCast(columns - 1)) - @as(i32, @intCast(index / rows)), .row = @as(i32, @intCast(rows - 1)) - @as(i32, @intCast(index % rows)) },
        .RowFirst_LTR_TTB => .{ .col = @intCast(index % columns), .row = @intCast(index / columns) },
    };
}

const testing = std.testing;

const WIDESCREEN: f32 = 16.0 / 9.0;

fn testRegion(width: i32, height: i32) win32.RECT {
    return .{ .left = 0, .top = 0, .right = width, .bottom = height };
}

test "calculateRegionFitGrid gives a single thumbnail the whole region" {
    const grid = calculateRegionFitGrid(testRegion(1600, 900), 1, 0, 0, WIDESCREEN, null);
    try testing.expectEqual(@as(u32, 1), grid.columns);
    try testing.expectEqual(@as(u32, 1), grid.rows);
    try testing.expectEqual(@as(i32, 1600), grid.cell_width);
    try testing.expectEqual(@as(i32, 900), grid.cell_height);
}

test "calculateRegionFitGrid lays four widescreen thumbnails out 2x2" {
    const grid = calculateRegionFitGrid(testRegion(1600, 900), 4, 0, 0, WIDESCREEN, null);
    try testing.expectEqual(@as(u32, 2), grid.columns);
    try testing.expectEqual(@as(u32, 2), grid.rows);
    try testing.expectEqual(@as(i32, 800), grid.cell_width);
    try testing.expectEqual(@as(i32, 450), grid.cell_height);
}

test "calculateRegionFitGrid fits every count without a spare row or column" {
    const region = testRegion(1920, 1080);
    const spacing = 8;
    for (1..25) |count| {
        const grid = calculateRegionFitGrid(region, count, spacing, spacing, WIDESCREEN, null);
        const columns: i32 = @intCast(grid.columns);
        const rows: i32 = @intCast(grid.rows);
        try testing.expect(grid.columns * grid.rows >= count);
        try testing.expect(grid.columns * grid.rows - @min(grid.columns, grid.rows) < count);
        try testing.expect(columns * grid.cell_width + (columns - 1) * spacing <= 1920);
        try testing.expect(rows * grid.cell_height + (rows - 1) * spacing <= 1080);
    }
}

test "calculateRegionFitGrid breaks a capped tie toward the axis with more room" {
    const cap: RegionFitCap = .{ .width = 400, .height = 225 };

    const tall = calculateRegionFitGrid(testRegion(800, 1800), 2, 0, 0, WIDESCREEN, cap);
    try testing.expectEqual(@as(u32, 1), tall.columns);
    try testing.expectEqual(@as(u32, 2), tall.rows);
    try testing.expectEqual(@as(i32, 400), tall.cell_width);

    const wide = calculateRegionFitGrid(testRegion(1800, 800), 2, 0, 0, WIDESCREEN, cap);
    try testing.expectEqual(@as(u32, 2), wide.columns);
    try testing.expectEqual(@as(u32, 1), wide.rows);
    try testing.expectEqual(@as(i32, 225), wide.cell_height);
}

test "fitAspect fits the box by its tighter side and never goes below 1px" {
    const wide = fitAspect(100, 10, WIDESCREEN);
    try testing.expectEqual(@as(i32, 18), wide.width);
    try testing.expectEqual(@as(i32, 10), wide.height);

    const tall = fitAspect(160, 900, WIDESCREEN);
    try testing.expectEqual(@as(i32, 160), tall.width);
    try testing.expectEqual(@as(i32, 90), tall.height);

    const empty = fitAspect(0, 10, WIDESCREEN);
    try testing.expectEqual(@as(i32, 1), empty.width);
    try testing.expectEqual(@as(i32, 1), empty.height);
    try testing.expectEqual(@as(i32, 1), fitAspect(-5, -5, WIDESCREEN).width);
}

test "regionFitColRow starts each direction in its own corner" {
    inline for (comptime std.enums.values(types.RegionFitDirection)) |direction| {
        // Expected (col, row) of index 0 and index 1 in a 3x2 grid.
        const expected: [2][2]i32 = switch (direction) {
            .RowFirst_LTR_TTB => .{ .{ 0, 0 }, .{ 1, 0 } },
            .RowFirst_RTL_TTB => .{ .{ 2, 0 }, .{ 1, 0 } },
            .RowFirst_LTR_BTT => .{ .{ 0, 1 }, .{ 1, 1 } },
            .RowFirst_RTL_BTT => .{ .{ 2, 1 }, .{ 1, 1 } },
            .ColumnFirst_TTB_LTR => .{ .{ 0, 0 }, .{ 0, 1 } },
            .ColumnFirst_TTB_RTL => .{ .{ 2, 0 }, .{ 2, 1 } },
            .ColumnFirst_BTT_LTR => .{ .{ 0, 1 }, .{ 0, 0 } },
            .ColumnFirst_BTT_RTL => .{ .{ 2, 1 }, .{ 2, 0 } },
        };
        for (expected, 0..) |cell, index| {
            const actual = regionFitColRow(direction, index, 3, 2);
            try testing.expectEqual(cell[0], actual.col);
            try testing.expectEqual(cell[1], actual.row);
        }
    }
}

test "regionFitColRow puts each index of a full grid in its own cell" {
    for (std.enums.values(types.RegionFitDirection)) |direction| {
        var seen: [6]bool = @splat(false);
        for (0..6) |index| {
            const cell = regionFitColRow(direction, index, 3, 2);
            try testing.expect(cell.col >= 0 and cell.col < 3 and cell.row >= 0 and cell.row < 2);
            const slot: usize = @intCast(cell.row * 3 + cell.col);
            try testing.expect(!seen[slot]);
            seen[slot] = true;
        }
    }
}

test "regionFitPositionForGrid strides by cell size plus spacing from the region's corner" {
    const region: win32.RECT = .{ .left = 100, .top = 50, .right = 1710, .bottom = 960 };
    const grid: RegionFitGrid = .{ .columns = 2, .rows = 2, .box_width = 800, .box_height = 450, .cell_width = 800, .cell_height = 450 };
    const bottom_right = regionFitPositionForGrid(region, grid, 3, .RowFirst_LTR_TTB, 10);
    try testing.expectEqual(@as(i32, 910), bottom_right.x);
    try testing.expectEqual(@as(i32, 510), bottom_right.y);
    const mirrored = regionFitPositionForGrid(region, grid, 3, .RowFirst_RTL_TTB, 10);
    try testing.expectEqual(@as(i32, 100), mirrored.x);
    try testing.expectEqual(@as(i32, 510), mirrored.y);
}
