//! Where the boxes panels draw over themselves go, and how they look: tooltips, menus and their submenus; no I/O.
const std = @import("std");
const box_mod = @import("../util/box.zig");
const fixed_text = @import("../util/fixed_text.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");

const Box = box_mod.Box;
const FixedText = fixed_text.FixedText;

/// Around a tooltip's text, and how far it keeps from what it describes.
pub const TOOLTIP_PADDING: i32 = 6;
/// Between a popup's rows.
pub const POPUP_ROW_GAP: i32 = 6;
/// Between a popup's edge and its rows, so a lit row nearly fills the width.
const POPUP_PADDING: i32 = 3;
/// Between a row's edges and its text or arrow.
pub const POPUP_TEXT_INSET: i32 = 7;
/// Up from a row's usual place: a heading has the popup's padding above it and its rule below, so would sit low.
pub const POPUP_HEADING_LIFT: i32 = 2;
/// Beside a row's text, for the arrow and a clear gap before it.
pub const SUBMENU_ARROW_ROOM: i32 = 20;
const SUBMENU_ARROW_SIZE: i32 = 3;

// The colours below are 0xAARRGGBB, not premultiplied.
pub const TOOLTIP_FILL: u32 = 0xFF1E2024;
pub const POPUP_BORDER: u32 = 0xFF4A4D55;

/// A stretch of a row's text in its own colour, as byte offsets into it; a list's accents line up, flush right.
pub const Accent = struct {
    start: usize,
    end: usize,
    color: u32,
};

pub const PopupRow = struct {
    text: FixedText,
    color: u32,
    accent: ?Accent = null,
    has_submenu: bool = false,
    has_rule_below: bool = false,
};

/// Rows over a panel, running on into more columns if the area is too short.
pub const PopupGrid = struct {
    box: Box,
    row_count: usize,
    row_height: i32,
    column_width: i32,
    rows_per_column: i32,

    /// Beside `x`,`y`, like a tooltip; `row_height` must be above zero.
    pub fn init(area: Box, x: i32, y: i32, row_count: usize, column_width: i32, row_height: i32) PopupGrid {
        const shape = popupShape(area, row_count, column_width, row_height);
        const box = tooltipBox(area, x, y, shape.width, shape.height);
        return .{ .box = box, .row_count = row_count, .row_height = row_height, .column_width = column_width, .rows_per_column = shape.rows_per_column };
    }

    /// Against `parent`'s right side while there's room, else its left, with its first row at `row_top`; `row_height` must be above zero.
    pub fn beside(area: Box, parent: Box, row_top: i32, row_count: usize, column_width: i32, row_height: i32) PopupGrid {
        const shape = popupShape(area, row_count, column_width, row_height);
        const wanted_left = if (parent.right + shape.width <= area.right) parent.right else parent.left - shape.width;
        const left = std.math.clamp(wanted_left, area.left, @max(area.left, area.right - shape.width));
        const top = std.math.clamp(row_top - POPUP_PADDING, area.top, @max(area.top, area.bottom - shape.height));
        const box: Box = .{ .left = left, .top = top, .right = left + shape.width, .bottom = top + shape.height };
        return .{ .box = box, .row_count = row_count, .row_height = row_height, .column_width = column_width, .rows_per_column = shape.rows_per_column };
    }

    pub fn cell(self: PopupGrid, index: usize) Box {
        const signed_index: i32 = @intCast(index);
        const left = self.box.left + POPUP_PADDING + @divTrunc(signed_index, self.rows_per_column) * self.column_width;
        const top = self.box.top + POPUP_PADDING + @mod(signed_index, self.rows_per_column) * self.row_height;
        return .{ .left = left, .top = top, .right = left + self.column_width, .bottom = top + self.row_height };
    }

    /// Searched linearly, so it agrees with `cell`.
    pub fn rowAt(self: PopupGrid, x: i32, y: i32) ?usize {
        for (0..self.row_count) |index| {
            const box = self.cell(index);
            if (x >= box.left and x < box.right and y >= box.top and y < box.bottom) return index;
        }
        return null;
    }
};

const PopupShape = struct {
    rows_per_column: i32,
    width: i32,
    height: i32,
};

/// The row height that makes a one-row popup `box_height` tall.
pub fn rowHeightForBox(box_height: i32) i32 {
    return box_height - 2 * POPUP_PADDING;
}

/// Beside `x`,`y` while there's room, else on the other side; always inside `area`.
pub fn tooltipBox(area: Box, x: i32, y: i32, width: i32, height: i32) Box {
    const beside = x + TOOLTIP_PADDING * 2 + width;
    const left = if (beside <= area.right) x + TOOLTIP_PADDING * 2 else x - TOOLTIP_PADDING * 2 - width;
    const below = y + TOOLTIP_PADDING + height;
    const top = if (below <= area.bottom) y + TOOLTIP_PADDING else y - TOOLTIP_PADDING - height;
    const clamped_left = std.math.clamp(left, area.left, @max(area.left, area.right - width));
    const clamped_top = std.math.clamp(top, area.top, @max(area.top, area.bottom - height));
    return .{ .left = clamped_left, .top = clamped_top, .right = clamped_left + width, .bottom = clamped_top + height };
}

/// A chevron with its point at `right`,`y`.
pub fn drawSubmenuArrow(canvas: pixel_buffer.Canvas, right: i32, y: i32, arrow_color: u32) void {
    const left = right - SUBMENU_ARROW_SIZE;
    pixel_buffer.drawLine(canvas, left, y - SUBMENU_ARROW_SIZE, right, y, arrow_color);
    pixel_buffer.drawLine(canvas, right, y, left, y + SUBMENU_ARROW_SIZE, arrow_color);
}

fn popupShape(area: Box, row_count: usize, column_width: i32, row_height: i32) PopupShape {
    const signed_count: i32 = @intCast(@max(1, row_count));
    const rows_that_fit = @max(1, @divTrunc(area.bottom - area.top - 2 * POPUP_PADDING, row_height));
    const rows_per_column = @min(signed_count, rows_that_fit);
    const column_count = @divTrunc(signed_count - 1, rows_per_column) + 1;
    return .{
        .rows_per_column = rows_per_column,
        .width = column_count * column_width + 2 * POPUP_PADDING,
        .height = rows_per_column * row_height + 2 * POPUP_PADDING,
    };
}

const testing = std.testing;

const TEST_AREA: Box = .{ .left = 0, .top = 20, .right = 760, .bottom = 530 };

test "a popup too tall for its area runs on into another column" {
    const grid: PopupGrid = .init(.{ .left = 0, .top = 0, .right = 400, .bottom = 100 }, 10, 10, 12, 120, 20);
    try testing.expectEqual(@as(i32, 4), grid.rows_per_column);
    for (0..12) |index| {
        const box = grid.cell(index);
        try testing.expectEqual(@as(?usize, index), grid.rowAt(box.left, box.top));
    }
    try testing.expectEqual(grid.cell(0).top, grid.cell(4).top);
    try testing.expect(grid.cell(4).left > grid.cell(0).left);
}

test "rowHeightForBox gives a one-row popup the height asked for" {
    const grid: PopupGrid = .init(TEST_AREA, 100, 100, 1, 120, rowHeightForBox(24));
    try testing.expectEqual(@as(i32, 24), grid.box.bottom - grid.box.top);
}

test "a popup finds no row outside itself" {
    const grid: PopupGrid = .init(TEST_AREA, 100, 100, 3, 120, 20);
    try testing.expectEqual(@as(?usize, null), grid.rowAt(0, 0));
}

test "a submenu opens against its parent's right side, level with the row" {
    const parent: Box = .{ .left = 100, .top = 100, .right = 220, .bottom = 200 };
    const grid: PopupGrid = .beside(TEST_AREA, parent, 150, 3, 120, 20);
    try testing.expectEqual(parent.right, grid.box.left);
    try testing.expectEqual(@as(i32, 150), grid.cell(0).top);
}

test "a submenu with no room on the right opens on the left, and stays inside the area" {
    const parent: Box = .{ .left = 600, .top = 480, .right = 720, .bottom = 525 };
    const grid: PopupGrid = .beside(TEST_AREA, parent, 500, 4, 120, 20);
    try testing.expectEqual(parent.left, grid.box.right);
    try testing.expect(grid.box.bottom <= TEST_AREA.bottom);
}

test "tooltipBox stays inside the area, flipping away from the edges" {
    const left_side = tooltipBox(TEST_AREA, 100, 100, 200, 80);
    try testing.expect(left_side.left > 100);
    const right_side = tooltipBox(TEST_AREA, 750, 520, 200, 80);
    try testing.expect(right_side.right <= TEST_AREA.right);
    try testing.expect(right_side.bottom <= TEST_AREA.bottom);
    try testing.expect(right_side.left >= TEST_AREA.left);
}
