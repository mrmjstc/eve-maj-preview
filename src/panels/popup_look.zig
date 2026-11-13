//! Where the boxes panels draw over themselves go, and how they look: tooltips, menus and their submenus; no I/O.
const std = @import("std");
const glyphs = @import("glyphs.zig");
const palette = @import("palette.zig");
const box_mod = @import("../util/box.zig");
const fixed_text = @import("../util/fixed_text.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");

const Box = box_mod.Box;
const FixedText = fixed_text.FixedText;

/// Around a tooltip's text, and how far it keeps from what it describes.
pub const TOOLTIP_PADDING: i32 = 6;
/// Between a popup's edge and its rows, so a lit row nearly fills the width.
const POPUP_PADDING: i32 = palette.MENU_PADDING;
/// From a popup's left edge to a `.title` row's text; a detailed tooltip's title sits there too.
pub const TITLE_INSET_X: i32 = POPUP_PADDING + MENU_CHECK_LEFT;
/// Between a list's row edges and its text.
pub const POPUP_TEXT_INSET: i32 = 7;
/// A menu row's height, the dialog's control height.
pub const MENU_ROW_HEIGHT: i32 = palette.CONTROL_HEIGHT;
/// From a menu row's left edge to its check mark's column.
pub const MENU_CHECK_LEFT: i32 = 8;
/// Holds a glyph or a check mark.
const MENU_CHECK_WIDTH: i32 = glyphs.SIZE;
/// From a menu row's left edge to its text, past the check mark's column, so checked and unchecked rows line up.
pub const MENU_TEXT_LEFT: i32 = MENU_CHECK_LEFT + MENU_CHECK_WIDTH + MENU_PART_GAP;
/// From a menu row's right edge to its arrow's point.
pub const MENU_RIGHT_INSET: i32 = 10;
/// For a submenu's arrow, at a menu row's right, kept on every row of a list with one so the values line up.
pub const MENU_ARROW_ROOM: i32 = 12;
/// Between a menu row's parts: its check, text, value and arrow.
pub const MENU_PART_GAP: i32 = 8;
/// Before a title's value, as before a tooltip's aside.
pub const MENU_TITLE_VALUE_GAP: i32 = 16;
/// Where chevron_right's point sits across its glyph.
const CHEVRON_RIGHT_TIP: i32 = 10;
/// Between a row's parts, e.g. a search result's name, security and region.
pub const POPUP_PART_GAP = "  ";

/// A popup's corners.
const BOX_RADIUS: usize = palette.RADIUS;
/// A lit row's corners, as the dialog's menu rows.
pub const ROW_RADIUS: usize = palette.RADIUS;

// The colours below are 0xAARRGGBB, not premultiplied, and the dialog's menu's, so every popup looks alike.
const MENU_FILL: u32 = palette.PANEL;
const MENU_BORDER: u32 = palette.BORDER_STRONG;
pub const MENU_LIT: u32 = palette.SURFACE;
/// Between a menu's groups of rows.
pub const MENU_RULE: u32 = palette.BORDER;
/// A menu's headings, values and arrows.
pub const MENU_MUTED: u32 = palette.MUTED;

/// A stretch of a row's text in its own colour, as byte offsets into it; a list's accents line up, flush right.
pub const Accent = struct {
    start: usize,
    end: usize,
    color: u32,
};

pub const RowRole = enum {
    item,
    /// A section's label rather than something to press: small and muted.
    heading,
    /// What the menu is about, like a tooltip's title: its own font, with its accent and value.
    title,
};

pub const PopupRow = struct {
    text: FixedText,
    color: u32 = palette.TEXT,
    /// A menu row's ends its text, set a gap after the rest.
    accent: ?Accent = null,
    /// A menu row's, flush right in the small font; empty for none.
    value: FixedText = .{},
    /// A menu row's icon, in the check mark's column and its text's colour.
    glyph: ?glyphs.Glyph = null,
    is_checked: bool = false,
    role: RowRole = .item,
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

/// From a popup's top edge to a `.title` row's text in a font `name_height` tall.
pub fn titleInsetY(name_height: i32) i32 {
    return POPUP_PADDING + @divTrunc(MENU_ROW_HEIGHT - name_height, 2);
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

/// A rounded box with a one-pixel border, as the dialog draws its tooltips, menus and cards.
pub fn drawBorderedBox(canvas: pixel_buffer.Canvas, box: Box, radius: usize, fill: u32, border: u32) void {
    if (box.left < 0 or box.top < 0 or box.right - box.left < 2 or box.bottom - box.top < 2) return;
    pixel_buffer.fillRoundedRect(canvas, @intCast(box.left), @intCast(box.top), @intCast(box.right - box.left), @intCast(box.bottom - box.top), radius, border);
    pixel_buffer.fillRoundedRect(canvas, @intCast(box.left + 1), @intCast(box.top + 1), @intCast(box.right - box.left - 2), @intCast(box.bottom - box.top - 2), radius -| 1, fill);
}

/// A menu's or tooltip's box, as the dialog draws both.
pub fn drawPopupBox(canvas: pixel_buffer.Canvas, box: Box) void {
    drawBorderedBox(canvas, box, BOX_RADIUS, MENU_FILL, MENU_BORDER);
}

/// A tick filling the check mark's column from `left`, around `y`.
pub fn drawCheck(canvas: pixel_buffer.Canvas, left: i32, y: i32, check_color: u32) void {
    glyphs.draw(canvas, .check, left, y - @divTrunc(glyphs.SIZE, 2), check_color);
}

/// A chevron with its point at `right`,`y`.
pub fn drawSubmenuArrow(canvas: pixel_buffer.Canvas, right: i32, y: i32, arrow_color: u32) void {
    glyphs.draw(canvas, .chevron_right, right - CHEVRON_RIGHT_TIP, y - @divTrunc(glyphs.SIZE, 2), arrow_color);
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
