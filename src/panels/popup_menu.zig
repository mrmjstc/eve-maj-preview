//! A menu with two levels of submenu, drawn inside a panel as TrackPopupMenu needs a foreground the panels never take.
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const glyphs = @import("glyphs.zig");
const panel_chrome = @import("panel_chrome.zig");
const popup_look = @import("popup_look.zig");
const box = @import("../util/box.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");

const Box = box.Box;
const PopupGrid = popup_look.PopupGrid;
const PopupRow = popup_look.PopupRow;

/// A row under the cursor.
pub const Hit = union(enum) { main: usize, submenu: usize, nested: usize };

pub const Fonts = struct {
    chrome: panel_chrome.Text,
    /// A `.title` row's, the same height as `chrome`'s name font.
    title: win32.HFONT,
    /// A `.heading` row's, the same height as `chrome`'s small font; semibold, as the dialog's menu captions are.
    heading: win32.HFONT,
};

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
    /// Every list's ticks, as the panels' menus draw them in the accent.
    check_color: u32,
    /// So a list doesn't resize as its rows come and go.
    min_column_width: i32 = 0,
    lit_row: ?usize = null,
    /// Set, the main list is drawn like the dialog's suggestions under a field, with its lit row in this colour; else it's a menu.
    flat_lit_color: ?u32 = null,
    /// Of the main list's rows instead of a menu's, unless its text needs more.
    row_height: ?i32 = null,
    submenu: ?Submenu = null,
    /// A submenu of `submenu`, which it needs.
    nested: ?Submenu = null,
};

/// How a list's rows are laid out.
const Kind = enum {
    /// Check, text, value and arrow columns, like the dialog's menus.
    menu,
    /// Text alone, its accents lined up flush right.
    list,
};

/// What a list lights: its lit row, in `lit_color`, and its ticks.
const BoxColors = struct { lit_row: ?usize, lit_color: u32, check_color: u32 };

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
    pub fn draw(self: *PopupMenu, bitmap: *const gdi_overlay.OverlayBitmap, fonts: Fonts, area: Box, anchor: win32.POINT, options: DrawOptions) void {
        const main_kind: Kind = if (options.flat_lit_color == null) .menu else .list;
        const main_row_height = if (options.row_height) |wanted| @max(wanted, fonts.chrome.name_height) else popup_look.MENU_ROW_HEIGHT;
        const main_width = columnWidth(bitmap.mem_dc, fonts, options.rows, options.min_column_width, main_kind);

        const grid: PopupGrid = .init(area, anchor.x, anchor.y, options.rows.len, main_width, main_row_height);
        self.main = grid;
        self.submenu = null;
        self.nested = null;
        const main_lit_color = options.flat_lit_color orelse popup_look.MENU_LIT;
        drawBox(bitmap, fonts, &grid, options.rows, .{ .lit_row = options.lit_row, .lit_color = main_lit_color, .check_color = options.check_color }, main_kind);

        const submenu = options.submenu orelse return;
        const submenu_grid = drawBeside(bitmap, fonts, area, &grid, &submenu, options.check_color);
        self.submenu = submenu_grid;

        const nested = options.nested orelse return;
        self.nested = drawBeside(bitmap, fonts, area, &submenu_grid, &nested, options.check_color);
    }
};

fn drawBeside(bitmap: *const gdi_overlay.OverlayBitmap, fonts: Fonts, area: Box, parent: *const PopupGrid, submenu: *const Submenu, check_color: u32) PopupGrid {
    const row_top = parent.cell(submenu.parent_index).top;
    const width = columnWidth(bitmap.mem_dc, fonts, submenu.rows, 0, .menu);
    const grid: PopupGrid = .beside(area, parent.box, row_top, submenu.rows.len, width, popup_look.MENU_ROW_HEIGHT);
    drawBox(bitmap, fonts, &grid, submenu.rows, .{ .lit_row = submenu.lit_row, .lit_color = popup_look.MENU_LIT, .check_color = check_color }, .menu);
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

/// Leaves `dc` holding the name font.
fn columnWidth(dc: win32.HDC, fonts: Fonts, rows: []const PopupRow, min_width: i32, kind: Kind) i32 {
    const text = fonts.chrome;
    var column_width = min_width;
    const arrow_room = arrowRoom(rows);
    switch (kind) {
        .list => {
            _ = win32.SelectObject(dc, text.name_font);
            const columns = accentColumns(dc, rows);
            column_width = @max(column_width, columns.lead + columns.accent + columns.tail + 2 * popup_look.POPUP_TEXT_INSET);
            for (rows) |*row| column_width = @max(column_width, panel_chrome.wideTextWidth(dc, row.text.slice()) + 2 * popup_look.POPUP_TEXT_INSET);
        },
        .menu => for (rows) |*row| {
            _ = win32.SelectObject(dc, rowFont(fonts, row.role));
            var width = menuTextLeft(row.role) + panel_chrome.wideTextWidth(dc, row.text.slice()) + rightRoom(row.role, arrow_room);
            if (row.accent != null) width += popup_look.MENU_PART_GAP;
            if (row.value.length > 0) {
                _ = win32.SelectObject(dc, text.small_font);
                width += panel_chrome.wideTextWidth(dc, row.value.slice()) + valueGap(row.role);
            }
            column_width = @max(column_width, width);
        },
    }
    _ = win32.SelectObject(dc, text.name_font);
    return column_width;
}

/// The box and its lit row, rules, arrows and ticks go on the canvas first, as GDI's text lands on top.
fn drawBox(bitmap: *const gdi_overlay.OverlayBitmap, fonts: Fonts, grid: *const PopupGrid, rows: []const PopupRow, colors: BoxColors, kind: Kind) void {
    const text = fonts.chrome;
    _ = win32.GdiFlush();
    const canvas = bitmap.canvas();
    popup_look.drawPopupBox(canvas, grid.box);
    if (colors.lit_row) |lit| {
        if (lit < rows.len and rows[lit].role == .item) {
            const cell = grid.cell(lit);
            pixel_buffer.fillRoundedRect(canvas, @intCast(cell.left), @intCast(cell.top), @intCast(cell.right - cell.left), @intCast(cell.bottom - cell.top), popup_look.ROW_RADIUS, colors.lit_color);
        }
    }
    for (rows, 0..) |*row, index| {
        const cell = grid.cell(index);
        const middle = cell.top + @divTrunc(cell.bottom - cell.top, 2);
        if (row.has_rule_below) pixel_buffer.fillRect(canvas, @intCast(cell.left), @intCast(cell.bottom - 1), @intCast(cell.right - cell.left), 1, popup_look.MENU_RULE);
        if (row.has_submenu) popup_look.drawSubmenuArrow(canvas, cell.right - popup_look.MENU_RIGHT_INSET, middle, popup_look.MENU_MUTED);
        if (row.is_checked) popup_look.drawCheck(canvas, cell.left + popup_look.MENU_CHECK_LEFT, middle, colors.check_color);
        if (row.glyph) |glyph| glyphs.draw(canvas, glyph, cell.left + popup_look.MENU_CHECK_LEFT, middle - @divTrunc(glyphs.SIZE, 2), row.color);
    }

    const dc = bitmap.mem_dc;
    switch (kind) {
        .list => {
            _ = win32.SelectObject(dc, text.name_font);
            const columns = accentColumns(dc, rows);
            for (rows, 0..) |*row, index| {
                const cell = grid.cell(index);
                const y = cell.top + @divTrunc(cell.bottom - cell.top - text.name_height, 2);
                drawListRow(dc, row, cell.left + popup_look.POPUP_TEXT_INSET, y, cell.right - cell.left - 2 * popup_look.POPUP_TEXT_INSET, columns);
            }
        },
        .menu => {
            const arrow_room = arrowRoom(rows);
            for (rows, 0..) |*row, index| drawMenuRow(dc, fonts, row, grid.cell(index), arrow_room);
        },
    }
    _ = win32.SelectObject(dc, text.name_font);
}

/// Its text past the check mark's column, its accent after it, and any value flush right before `arrow_room`.
fn drawMenuRow(dc: win32.HDC, fonts: Fonts, row: *const PopupRow, cell: Box, arrow_room: i32) void {
    const text = fonts.chrome;
    const left = cell.left + menuTextLeft(row.role);
    const height = cell.bottom - cell.top;
    if (row.role == .heading) {
        _ = win32.SelectObject(dc, fonts.heading);
        _ = panel_chrome.drawFitted(dc, row.text.slice(), left, cell.top + @divTrunc(height - text.small_height, 2), popup_look.MENU_MUTED, cell.right - popup_look.MENU_RIGHT_INSET - left);
        return;
    }
    var text_right = cell.right - rightRoom(row.role, arrow_room);
    if (row.value.length > 0) {
        _ = win32.SelectObject(dc, text.small_font);
        const value_width = panel_chrome.wideTextWidth(dc, row.value.slice());
        panel_chrome.drawWideLine(dc, row.value.slice(), text_right - value_width, cell.top + @divTrunc(height - text.small_height, 2), popup_look.MENU_MUTED);
        text_right -= value_width + valueGap(row.role);
    }
    _ = win32.SelectObject(dc, rowFont(fonts, row.role));
    const top = cell.top + @divTrunc(height - text.name_height, 2);
    const label = row.text.slice();
    const accent = row.accent orelse {
        _ = panel_chrome.drawFitted(dc, label, left, top, row.color, text_right - left);
        return;
    };
    const lead_width = panel_chrome.drawFitted(dc, label[0..accent.start], left, top, row.color, text_right - left);
    const accent_left = left + lead_width + popup_look.MENU_PART_GAP;
    _ = panel_chrome.drawFitted(dc, label[accent.start..accent.end], accent_left, top, accent.color, text_right - accent_left);
}

fn rowFont(fonts: Fonts, role: popup_look.RowRole) win32.HFONT {
    return switch (role) {
        .item => fonts.chrome.name_font,
        .heading => fonts.heading,
        .title => fonts.title,
    };
}

/// A title's value runs out to the arrows' points, as it has no arrow of its own.
fn rightRoom(role: popup_look.RowRole, arrow_room: i32) i32 {
    return switch (role) {
        .item, .heading => popup_look.MENU_RIGHT_INSET + arrow_room,
        .title => popup_look.MENU_RIGHT_INSET,
    };
}

fn valueGap(role: popup_look.RowRole) i32 {
    return switch (role) {
        .item, .heading => popup_look.MENU_PART_GAP,
        .title => popup_look.MENU_TITLE_VALUE_GAP,
    };
}

/// A title starts in the check mark's column, as nothing sits beside it.
fn menuTextLeft(role: popup_look.RowRole) i32 {
    return switch (role) {
        .item, .heading => popup_look.MENU_TEXT_LEFT,
        .title => popup_look.MENU_CHECK_LEFT,
    };
}

/// Kept on every row of a list with a submenu, so its values line up, and on none of one without.
fn arrowRoom(rows: []const PopupRow) i32 {
    for (rows) |*row| {
        if (row.has_submenu) return popup_look.MENU_ARROW_ROOM + popup_look.MENU_PART_GAP;
    }
    return 0;
}

fn drawListRow(dc: win32.HDC, row: *const PopupRow, x: i32, y: i32, max_width: i32, columns: AccentColumns) void {
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
