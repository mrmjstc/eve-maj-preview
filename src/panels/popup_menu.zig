//! A menu with two levels of submenu, drawn inside a panel as TrackPopupMenu needs a foreground the panels never take.
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const panel_chrome = @import("panel_chrome.zig");
const panel_look = @import("panel_look.zig");
const popup_look = @import("popup_look.zig");
const box_mod = @import("../util/box.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");

const Box = box_mod.Box;
const PopupGrid = popup_look.PopupGrid;
const PopupRow = popup_look.PopupRow;

/// A row under the cursor.
pub const Hit = union(enum) { main: usize, submenu: usize, nested: usize };

pub const Submenu = struct {
    /// Borrowed for the draw.
    rows: []const PopupRow,
    /// The row of the list before it that it hangs off.
    parent_index: usize,
    lit_row: ?usize = null,
};

pub const DrawOptions = struct {
    /// Borrowed for the draw.
    rows: []const PopupRow,
    /// So a list doesn't resize as its rows come and go.
    min_column_width: i32 = 0,
    lit_row: ?usize = null,
    /// Set, the main list is rounded and borderless like a panel button, with its lit row in this colour.
    flat_lit_color: ?u32 = null,
    /// Of the main list's rows instead of the usual height, unless its text needs more.
    row_height: ?i32 = null,
    submenu: ?Submenu = null,
    /// A submenu of `submenu`, which it needs.
    nested: ?Submenu = null,
};

/// The widest of each part of a list's rows with accents, which sets where those parts line up.
const AccentColumns = struct {
    lead: i32 = 0,
    accent: i32 = 0,
    tail: i32 = 0,
};

/// Where the rows were last drawn, so a click finds what the user saw; the caller keeps what's open and what its rows do.
pub const PopupMenu = struct {
    main: ?PopupGrid = null,
    submenu: ?PopupGrid = null,
    nested: ?PopupGrid = null,

    pub fn clear(self: *PopupMenu) void {
        self.main = null;
        self.submenu = null;
        self.nested = null;
    }

    /// The deepest list first, as each can lie over the one before.
    pub fn hitAt(self: *const PopupMenu, x: i32, y: i32) ?Hit {
        if (self.nested) |grid| {
            if (grid.rowAt(x, y)) |row_index| return .{ .nested = row_index };
        }
        if (self.submenu) |grid| {
            if (grid.rowAt(x, y)) |row_index| return .{ .submenu = row_index };
        }
        const grid = self.main orelse return null;
        const row_index = grid.rowAt(x, y) orelse return null;
        return .{ .main = row_index };
    }

    /// Measures the rows here, so hit testing goes by this render; inside `area`, beside `anchor`.
    pub fn draw(self: *PopupMenu, bitmap: *const gdi_overlay.OverlayBitmap, text: panel_chrome.Text, area: Box, anchor: win32.POINT, options: DrawOptions) void {
        const dc = bitmap.mem_dc;
        _ = win32.SelectObject(dc, text.name_font);
        const row_height = text.name_height + popup_look.POPUP_ROW_GAP;
        const main_row_height = if (options.row_height) |wanted| @max(wanted, text.name_height) else row_height;

        const grid: PopupGrid = .init(area, anchor.x, anchor.y, options.rows.len, columnWidth(dc, options.rows, options.min_column_width), main_row_height);
        self.main = grid;
        self.submenu = null;
        self.nested = null;
        drawBox(bitmap, &grid, options.rows, options.lit_row, options.flat_lit_color, @divTrunc(main_row_height - text.name_height, 2));

        const submenu = options.submenu orelse return;
        const submenu_grid = drawBeside(bitmap, area, &grid, &submenu, row_height);
        self.submenu = submenu_grid;

        const nested = options.nested orelse return;
        self.nested = drawBeside(bitmap, area, &submenu_grid, &nested, row_height);
    }
};

fn drawBeside(bitmap: *const gdi_overlay.OverlayBitmap, area: Box, parent: *const PopupGrid, submenu: *const Submenu, row_height: i32) PopupGrid {
    const row_top = parent.cell(submenu.parent_index).top;
    const grid: PopupGrid = .beside(area, parent.box, row_top, submenu.rows.len, columnWidth(bitmap.mem_dc, submenu.rows, 0), row_height);
    drawBox(bitmap, &grid, submenu.rows, submenu.lit_row, null, @divTrunc(popup_look.POPUP_ROW_GAP, 2));
    return grid;
}

fn accentColumns(dc: win32.HDC, rows: []const PopupRow) AccentColumns {
    var columns: AccentColumns = .{};
    for (rows) |*row| {
        const accent = row.accent orelse continue;
        const text = row.text.slice();
        columns.lead = @max(columns.lead, panel_chrome.wideTextWidth(dc, text[0..accent.start]));
        columns.accent = @max(columns.accent, panel_chrome.wideTextWidth(dc, text[accent.start..accent.end]));
        columns.tail = @max(columns.tail, panel_chrome.wideTextWidth(dc, text[accent.end..]));
    }
    return columns;
}

fn columnWidth(dc: win32.HDC, rows: []const PopupRow, min_width: i32) i32 {
    const columns = accentColumns(dc, rows);
    var column_width = @max(min_width, columns.lead + columns.accent + columns.tail + 2 * popup_look.POPUP_TEXT_INSET);
    for (rows) |*row| {
        const arrow_room = if (row.has_submenu) popup_look.SUBMENU_ARROW_ROOM else 0;
        column_width = @max(column_width, panel_chrome.wideTextWidth(dc, row.text.slice()) + 2 * popup_look.POPUP_TEXT_INSET + arrow_room);
    }
    return column_width;
}

/// `text_inset` is from a row's top to its text.
fn drawBox(bitmap: *const gdi_overlay.OverlayBitmap, grid: *const PopupGrid, rows: []const PopupRow, lit_row: ?usize, flat_lit_color: ?u32, text_inset: i32) void {
    _ = win32.GdiFlush();
    const canvas = bitmap.canvas();
    const box = grid.box;
    if (flat_lit_color == null) {
        pixel_buffer.fillRect(canvas, @intCast(box.left), @intCast(box.top), @intCast(box.right - box.left), @intCast(box.bottom - box.top), popup_look.TOOLTIP_FILL);
        pixel_buffer.drawRectOutline(canvas, box.left, box.top, @intCast(box.right - box.left), @intCast(box.bottom - box.top), 1, popup_look.POPUP_BORDER);
    } else {
        pixel_buffer.fillRoundedRect(canvas, @intCast(box.left), @intCast(box.top), @intCast(box.right - box.left), @intCast(box.bottom - box.top), panel_look.BUTTON_RADIUS, panel_look.BUTTON_ON);
    }
    if (lit_row) |lit| {
        if (lit < rows.len) {
            const cell = grid.cell(lit);
            if (flat_lit_color) |lit_color| {
                pixel_buffer.fillRoundedRect(canvas, @intCast(cell.left), @intCast(cell.top), @intCast(cell.right - cell.left), @intCast(cell.bottom - cell.top), panel_look.BUTTON_RADIUS, lit_color);
            } else {
                pixel_buffer.fillRect(canvas, @intCast(cell.left), @intCast(cell.top), @intCast(cell.right - cell.left), @intCast(cell.bottom - cell.top), panel_look.BUTTON_ON);
            }
        }
    }
    for (rows, 0..) |*row, index| {
        const cell = grid.cell(index);
        if (row.has_rule_below) pixel_buffer.fillRect(canvas, @intCast(box.left + 1), @intCast(cell.bottom - 1), @intCast(box.right - box.left - 2), 1, popup_look.POPUP_BORDER);
        if (row.has_submenu) popup_look.drawSubmenuArrow(canvas, cell.right - popup_look.POPUP_TEXT_INSET, cell.top + @divTrunc(cell.bottom - cell.top, 2), row.color);
    }
    const columns = accentColumns(bitmap.mem_dc, rows);
    for (rows, 0..) |*row, index| {
        const cell = grid.cell(index);
        const is_heading = index == 0 and row.has_rule_below;
        const y = cell.top + text_inset - if (is_heading) popup_look.POPUP_HEADING_LIFT else 0;
        drawRow(bitmap.mem_dc, row, cell.left + popup_look.POPUP_TEXT_INSET, y, cell.right - cell.left - 2 * popup_look.POPUP_TEXT_INSET, columns);
    }
}

fn drawRow(dc: win32.HDC, row: *const PopupRow, x: i32, y: i32, max_width: i32, columns: AccentColumns) void {
    const text = row.text.slice();
    const accent = row.accent orelse {
        _ = panel_chrome.drawFitted(dc, text, x, y, row.color, max_width);
        return;
    };
    const accent_text = text[accent.start..accent.end];
    const tail_x_offset = columns.lead + columns.accent;
    _ = panel_chrome.drawFitted(dc, text[0..accent.start], x, y, row.color, columns.lead);
    _ = panel_chrome.drawFitted(dc, accent_text, x + tail_x_offset - panel_chrome.wideTextWidth(dc, accent_text), y, accent.color, columns.accent);
    _ = panel_chrome.drawFitted(dc, text[accent.end..], x + tail_x_offset, y, row.color, max_width - tail_x_offset);
}
