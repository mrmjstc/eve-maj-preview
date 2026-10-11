//! The grid a thumbnail space lays its cells out in; no I/O.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const characters = @import("../config/characters.zig");
const types = @import("../config/types.zig");

const Position = characters.Position;

/// box_width/box_height is the per-column/row share of the region, used only to pick the column count; cell_width/cell_height is the actual aspect-corrected thumbnail size used for positioning.
pub const RegionFitGrid = struct { columns: u32, rows: u32, box_width: i32, box_height: i32, cell_width: i32, cell_height: i32 };

pub const RegionFitCap = struct { width: i32, height: i32 };

/// Grows one column or row at a time from a single full-region cell, whichever yields the bigger cell, so the grid grows incrementally instead of re-optimizing from scratch per count.
pub fn calculateRegionFitGrid(region: win32.RECT, count: usize, spacing_x: i32, spacing_y: i32, aspect_ratio: f32, max_cell: ?RegionFitCap) RegionFitGrid {
    const cell_count: u32 = @intCast(@max(count, 1));
    const region_width = region.right - region.left;
    const region_height = region.bottom - region.top;

    // Under a cap both axes often tie; prefer the one with more room so a column or row fills first.
    const prefers_rows_on_tie = if (max_cell) |cap|
        regionFitAxisCapacity(region_height, spacing_y, cap.height) >= regionFitAxisCapacity(region_width, spacing_x, cap.width)
    else
        false;

    var columns: u32 = 1;
    var rows: u32 = 1;
    var grid = regionFitGridForSize(region_width, region_height, columns, rows, spacing_x, spacing_y, aspect_ratio, max_cell);

    while (columns * rows < cell_count) {
        const grow_columns = regionFitGridForSize(region_width, region_height, columns + 1, rows, spacing_x, spacing_y, aspect_ratio, max_cell);
        const grow_rows = regionFitGridForSize(region_width, region_height, columns, rows + 1, spacing_x, spacing_y, aspect_ratio, max_cell);
        const area_columns = regionFitCellArea(grow_columns);
        const area_rows = regionFitCellArea(grow_rows);
        const grows_columns = if (area_columns != area_rows) area_columns > area_rows else !prefers_rows_on_tie;
        if (grows_columns) {
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
pub fn regionFitPositionForGrid(region: win32.RECT, grid: RegionFitGrid, index: usize, direction: types.RegionFitDirection, spacing: i32) Position {
    const cell = regionFitColumnRow(direction, index, grid.columns, grid.rows);
    // Stride by cell size, not the wider box, so slack collects at the region's far edge instead of as gaps between thumbnails.
    return .{
        .x = region.left + cell.column * (grid.cell_width + spacing),
        .y = region.top + cell.row * (grid.cell_height + spacing),
    };
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

fn regionFitGridForSize(region_width: i32, region_height: i32, columns: u32, rows: u32, spacing_x: i32, spacing_y: i32, aspect_ratio: f32, max_cell: ?RegionFitCap) RegionFitGrid {
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
fn regionFitColumnRow(direction: types.RegionFitDirection, index: usize, columns: u32, rows: u32) struct { column: i32, row: i32 } {
    return switch (direction) {
        .RowFirst_RTL_TTB => .{ .column = @as(i32, @intCast(columns - 1)) - @as(i32, @intCast(index % columns)), .row = @intCast(index / columns) },
        .RowFirst_LTR_BTT => .{ .column = @intCast(index % columns), .row = @as(i32, @intCast(rows - 1)) - @as(i32, @intCast(index / columns)) },
        .RowFirst_RTL_BTT => .{ .column = @as(i32, @intCast(columns - 1)) - @as(i32, @intCast(index % columns)), .row = @as(i32, @intCast(rows - 1)) - @as(i32, @intCast(index / columns)) },
        .ColumnFirst_TTB_LTR => .{ .column = @intCast(index / rows), .row = @intCast(index % rows) },
        .ColumnFirst_BTT_LTR => .{ .column = @intCast(index / rows), .row = @as(i32, @intCast(rows - 1)) - @as(i32, @intCast(index % rows)) },
        .ColumnFirst_TTB_RTL => .{ .column = @as(i32, @intCast(columns - 1)) - @as(i32, @intCast(index / rows)), .row = @intCast(index % rows) },
        .ColumnFirst_BTT_RTL => .{ .column = @as(i32, @intCast(columns - 1)) - @as(i32, @intCast(index / rows)), .row = @as(i32, @intCast(rows - 1)) - @as(i32, @intCast(index % rows)) },
        .RowFirst_LTR_TTB => .{ .column = @intCast(index % columns), .row = @intCast(index / columns) },
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

test "regionFitColumnRow starts each direction in its own corner" {
    inline for (comptime std.enums.values(types.RegionFitDirection)) |direction| {
        // Expected (column, row) of index 0 and index 1 in a 3x2 grid.
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
            const actual = regionFitColumnRow(direction, index, 3, 2);
            try testing.expectEqual(cell[0], actual.column);
            try testing.expectEqual(cell[1], actual.row);
        }
    }
}

test "regionFitColumnRow puts each index of a full grid in its own cell" {
    for (std.enums.values(types.RegionFitDirection)) |direction| {
        var seen: [6]bool = @splat(false);
        for (0..6) |index| {
            const cell = regionFitColumnRow(direction, index, 3, 2);
            try testing.expect(cell.column >= 0 and cell.column < 3 and cell.row >= 0 and cell.row < 2);
            const slot: usize = @intCast(cell.row * 3 + cell.column);
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
