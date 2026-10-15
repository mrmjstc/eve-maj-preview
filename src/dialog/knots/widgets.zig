//! The configuration window's layout pieces and low-level controls, which show the text they're given in the chosen language; main thread only.
const std = @import("std");
const ui = @import("ui");
const style = @import("style.zig");
const glyphs = @import("glyphs.zig");
const search = @import("search.zig");
const lang = @import("../../lang/lang.zig");
const color_convert = @import("color_convert.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Canvas = ui.component.Canvas;
const SliderInput = ui.component.SliderInput;
const ColorPicker = ui.component.ColorPicker;
const Checkbox = ui.component.Checkbox;
const Button = ui.component.Button;
const TextInput = ui.component.TextInput;
const Tooltip = ui.component.Tooltip;
const Dialog = ui.component.Dialog;

/// Most row tooltips a frame holds; past this a row's hint is dropped.
const MAX_ROW_HINTS = 128;
/// A row's tooltip around its label is keyed as the row's own key indexed by this.
const ROW_TOOLTIP_INDEX = 12;
/// Dialog keys its panel as its own key indexed by this.
const DIALOG_PANEL_INDEX = 2;
/// Kept between a popover and the window's edges.
const POPOVER_MARGIN: f32 = 8;
const POPOVER_GAP: f32 = 8;
/// Between a menu and the button it drops from.
const MENU_GAP: f32 = 4;
/// accentChoices keys each preset as its own key indexed past this, clear of its other parts.
const ACCENT_PRESET_INDEX = 10;
/// Until the popover has been laid out once.
const POPOVER_HEIGHT_GUESS: f32 = 480;
/// Movement under this is a click, not a drag; matches knots' own click slop (press_drag_threshold_sq).
pub const DRAG_THRESHOLD = 8;
/// How long a confirm button waits for its second click.
const CONFIRM_TIMEOUT_MS = 2000;
/// A row's divider wrapper is keyed as the row's own key indexed by this.
const ROW_DIVIDER_INDEX = 10;
/// Past any roster's height; layout clamps a scroll offset to the content, so this lands on the last row.
const SCROLL_TO_END: f32 = 1e9;
/// A dropdown's widest; longer names are clipped rather than stretching the row.
const SELECT_MAX_WIDTH: f32 = 300;
/// rowSelect's floor: as wide as the widest single-row dropdown's options need, "Mouse Down (Instant)".
const SELECT_MIN_WIDTH: f32 = 170;
/// Space between a dropdown's longest option and its arrow.
const SELECT_ARROW_GAP: f32 = 12;

/// A laid-out element's rectangle, in window coordinates.
pub const Box = @FieldType(ui.State.Measured, "box");

/// Hints by the hash of the row they explain; searched linearly, since a tab has only a few dozen.
const RowHints = struct {
    rows: [MAX_ROW_HINTS]u64 = undefined,
    /// English, translated when drawn; borrows the caller's string literal.
    contents: [MAX_ROW_HINTS][]const u8 = undefined,
    count: usize = 0,

    /// False once full.
    fn append(self: *RowHints, row: u64, content: []const u8) bool {
        if (self.count == MAX_ROW_HINTS) return false;
        self.rows[self.count] = row;
        self.contents[self.count] = content;
        self.count += 1;
        return true;
    }

    fn find(self: *const RowHints, row: u64) ?[]const u8 {
        const index = std.mem.indexOfScalar(u64, self.rows[0..self.count], row) orelse return null;
        return self.contents[index];
    }
};

/// A disabled group's controls are inert; closing it veils them so they read as off.
pub const Group = struct {
    key: ui.Key,
    rect: Rect,
    is_enabled: bool,

    pub fn close(self: Group, context: *ui.Frame) !void {
        if (!self.is_enabled) {
            const ui_state = context.ui();
            ui_state.inert_depth -= 1;
            const measured = ui_state.state.get(.measured, self.key.hash()) orelse {
                try self.rect.close(context);
                return;
            };
            const veil = try context.arena().create(ui.Style);
            veil.* = style.group_veil.with(.{
                .width = .fixed(measured.box.w()),
                .height = .fixed(measured.box.h()),
            });
            // Not a button, so hovering still reaches the labels' tooltips under it.
            try context.e(Rect{ .key = self.key.indexed(1), .style = veil });
        }
        try self.rect.close(context);
    }
};

/// Lit while hovered; closing it ends the row.
pub const Row = struct {
    rect: Rect,
    /// Holds the divider above the row, so the row's highlight doesn't take in the gap.
    divider: ?Rect,
    /// The row's own space, e.g. its label, was clicked rather than a control in it.
    is_clicked: bool,

    pub fn close(self: Row, context: *ui.Frame) !void {
        try self.rect.close(context);
        if (self.divider) |divider| try divider.close(context);
    }
};

/// What openSection and openSwitchedSection return; the caller closes it.
pub const Section = struct {
    rect: Rect,
    /// The header's switch was flipped this frame.
    is_flipped: bool = false,

    pub fn close(self: Section, context: *ui.Frame) !void {
        g_open_section = null;
        g_last_labelled_row = null;
        try self.rect.close(context);
    }
};

/// What openScrollPane returns; closing it closes the pane and its content column.
pub const ScrollPane = struct {
    pane: Rect,
    content: Rect,

    pub fn close(self: ScrollPane, context: *ui.Frame) !void {
        try self.content.close(context);
        try self.pane.close(context);
    }
};

/// What openEmptyState returns; closing it ends its button row and itself.
pub const EmptyState = struct {
    state: Rect,
    actions: Rect,

    pub fn close(self: EmptyState, context: *ui.Frame) !void {
        try self.actions.close(context);
        try self.state.close(context);
    }
};

/// What openFieldGroup returns; closing it puts back the row settings it replaced.
pub const FieldGroup = struct {
    row: Rect,
    column: Rect,
    was_aligned: bool,
    was_in_field_group: bool,

    pub fn close(self: FieldGroup, context: *ui.Frame) !void {
        g_is_aligned = self.was_aligned;
        g_is_in_field_group = self.was_in_field_group;
        try self.column.close(context);
        try self.row.close(context);
    }
};

/// What openRoster returns: the caller draws its rows, then close draws the footer.
pub const Roster = struct {
    key: ui.Key,
    frame: Rect,
    rows: ScrollPane,

    /// The column holding the rows inside their scroll pane, for ReorderList.liftedStyle.
    pub fn rowsKey(self: Roster) ui.Key {
        return self.paneKey().indexed(1);
    }

    fn paneKey(self: Roster) ui.Key {
        return self.key.indexed(1);
    }

    /// Closes the rows, then draws the footer every master list shares; returns which of its buttons was clicked.
    pub fn close(self: Roster, context: *ui.Frame, footer: RosterFooter) !RosterAction {
        try self.rows.close(context);
        try fitRoster(context, footer);
        const bar = Rect{ .key = self.key.indexed(2), .style = &style.roster_footer };
        _ = try bar.open(context);
        var action: RosterAction = .none;
        search.captureText(lang.text(footer.add_label));
        if (try glyphButton(context, self.key.indexed(3), .add, footer.add_label, &style.roster_add, footer.is_add_disabled)) action = .add;
        if (footer.has_open_clients and try addOpenClientsButton(context, self.key.indexed(4), &style.icon_button)) action = .add_open_clients;
        try bar.close(context);
        try self.frame.close(context);
        // Added rows go last; scrolled to on the next frame, once they're drawn.
        if (action != .none) {
            g_scroll_to_end = self.paneKey().hash();
            context.requestRedraw();
        }
        return action;
    }
};

pub const RosterFooter = struct {
    /// e.g. "Add Character"; the button draws its own add glyph.
    add_label: []const u8,
    is_add_disabled: bool = false,
    has_open_clients: bool = false,
};

pub const RosterAction = enum { none, add, add_open_clients };

/// openSearchedRoster's search box.
const RosterSearch = struct { query: *std.ArrayList(u8), placeholder: []const u8 };

/// A section's on/off switch, in its header; an unavailable one is drawn inert.
pub const SectionSwitch = struct { is_on: *bool, is_available: bool = true };

/// What useDetailRows replaced.
pub const RowSettings = struct { is_aligned: bool, label_style: *const ui.Style };

/// Shown faded rather than hidden, so a preview's text that's turned off can still be clicked to turn it back on.
pub const TextOptions = struct { is_grown: bool = false, is_shown: bool = true };

/// What an optional colour row changed to.
pub const ColorChange = union(enum) { cleared, set: u32 };

/// A finished drag: item `from` now goes before what was item `before`.
pub const Move = struct { from: usize, before: usize };

/// A row being dragged, drawn under the cursor with a gap where it would land.
const Lifted = struct {
    from: usize,
    /// The gap's place among the other rows.
    slot: usize,
    /// Where the row's top is drawn, in window coordinates.
    top: f32,
    row_height: f32,
};

/// A reorderable list's drawing order: call next for each row, then end, then draw the row end returns last, with liftedStyle.
pub const ReorderList = struct {
    lifted: ?Lifted,
    /// Rows before this can't be moved, so the gap never opens among them.
    first_slot: usize,
    slot: usize = 0,

    pub fn begin(context: *ui.Frame, base: ui.Key, count: usize, first_slot: usize) ReorderList {
        const lifted = reorderLifted(context, base);
        const is_valid = if (lifted) |row| row.from < count else false;
        return .{ .lifted = if (is_valid) lifted else null, .first_slot = first_slot };
    }

    /// Whether to draw row `index` in its place; false for the lifted row, which is drawn after end.
    pub fn next(self: *ReorderList, context: *ui.Frame, index: usize) !bool {
        const lifted = self.lifted orelse return true;
        if (index == lifted.from) return false;
        try self.gapIfDue(context, lifted);
        self.slot += 1;
        return true;
    }

    /// After the rows; returns the lifted row's index, if one is being dragged.
    pub fn end(self: *const ReorderList, context: *ui.Frame) !?usize {
        const lifted = self.lifted orelse return null;
        try self.gapIfDue(context, lifted);
        return lifted.from;
    }

    /// `row_style` raised and under the cursor, over the rows container keyed `container`; unchanged when no row is lifted.
    pub fn liftedStyle(self: *const ReorderList, context: *ui.Frame, container: ui.Key, row_style: *const ui.Style) !*const ui.Style {
        const lifted = self.lifted orelse return row_style;
        const box = measuredBox(context.ui(), container);
        const lifted_style = try context.arena().create(ui.Style);
        lifted_style.* = row_style.with(style.lifted_row);
        lifted_style.width = .fixed(box.w());
        lifted_style.offset = .{ 0, lifted.top - box.y() };
        return lifted_style;
    }

    fn gapIfDue(self: *const ReorderList, context: *ui.Frame, lifted: Lifted) !void {
        if (self.slot != @max(lifted.slot, self.first_slot)) return;
        const gap_style = try context.arena().create(ui.Style);
        gap_style.* = style.reorder_gap.with(.{ .height = .fixed(lifted.row_height) });
        try context.e(Rect{ .key = .src(@src()), .style = gap_style });
    }
};

/// Set by useAlignedRows: rows put their label left and their control at the right edge.
var g_is_aligned: bool = false;
/// Set by useDetailRows: the label column of unaligned rows.
var g_label_style: *const ui.Style = &style.label;
/// Set by openFieldGroup: its rows go undivided, with softer labels.
var g_is_in_field_group: bool = false;
/// Aligned rows drawn so far in the open section; every one after the first gets a divider above it.
var g_section_row_count: usize = 0;
/// This frame's row hints, registered after their rows are drawn.
var g_row_hints: RowHints = .{};
/// Last frame's row hints, which this frame's rows show as tooltips on their labels.
var g_row_hints_before: RowHints = .{};
/// For a hintText straight after; null after anything else a hint could be about.
var g_last_labelled_row: ?ui.Key = null;
var g_open_section: ?u64 = null;
var g_confirm_key: ?u64 = null;
/// The rows of the roster that just had a row added, to scroll to its end when next drawn.
var g_scroll_to_end: ?u64 = null;
var g_confirm_until_ms: i64 = 0;
/// Fits last frame's longest label word, so a long translated word doesn't break.
var g_detail_column: f32 = style.DETAIL_LABEL_WIDTH;
/// What this frame's labels need, taking over at the next beginFrame.
var g_detail_column_next: f32 = style.DETAIL_LABEL_WIDTH;
/// Every master list's width this frame: wide enough for last frame's widest footer and row names.
var g_roster_width: f32 = style.ROSTER_WIDTH;
var g_roster_width_next: f32 = style.ROSTER_WIDTH;
/// `grab_y` and `row_height` let the lifted row be drawn where it was picked up.
var g_reorder: ?struct { list: u64, from: usize, start_y: f64, grab_y: f32, row_height: f32, insert: usize, has_moved: bool = false } = null;

pub fn beginFrame() void {
    g_row_hints_before = g_row_hints;
    g_row_hints = .{};
    g_last_labelled_row = null;
    g_detail_column = g_detail_column_next;
    g_detail_column_next = style.DETAIL_LABEL_WIDTH;
    g_roster_width = g_roster_width_next;
    g_roster_width_next = style.ROSTER_WIDTH;
}

/// Once the window has closed.
pub fn reset() void {
    g_row_hints = .{};
    g_row_hints_before = .{};
    g_last_labelled_row = null;
    g_open_section = null;
    g_confirm_key = null;
    g_scroll_to_end = null;
    g_detail_column = style.DETAIL_LABEL_WIDTH;
    g_detail_column_next = style.DETAIL_LABEL_WIDTH;
    g_roster_width = style.ROSTER_WIDTH;
    g_roster_width_next = style.ROSTER_WIDTH;
}

/// A panel with its heading and the intro hint; the caller closes it.
pub fn openSection(context: *ui.Frame, comptime title: []const u8, comptime hint: []const u8, section_style: *const ui.Style) !Section {
    return openAnySection(context, title, hint, section_style, null);
}

/// openSection with an on/off switch for the whole section at the right of its heading.
pub fn openSwitchedSection(context: *ui.Frame, comptime title: []const u8, comptime hint: []const u8, section_style: *const ui.Style, header_switch: SectionSwitch) !Section {
    return openAnySection(context, title, hint, section_style, header_switch);
}

/// A label-then-controls row; the caller adds the controls and closes it.
pub fn openBinding(context: *ui.Frame, key: ui.Key, label: []const u8) !Row {
    const row = try openSettingsRow(context, key, if (g_is_aligned) &style.aligned_row else &style.binding_row);
    const shown = lang.text(label);
    search.captureText(shown);
    try rowLabel(context, key, key.indexed(1), shown, try rowLabelStyle(context, shown));
    return row;
}

/// `mark` ends the label column, so controls start where other rows' do.
pub fn openMarkedBinding(context: *ui.Frame, key: ui.Key, label: []const u8, mark: []const u8) !Row {
    const row = try openSettingsRow(context, key, &style.aligned_row);
    const cell = Rect{ .key = key.indexed(2), .style = if (g_is_aligned) &style.inline_row else &style.label_cell };
    _ = try cell.open(context);
    const shown = lang.text(label);
    search.captureText(shown);
    try rowLabel(context, key, key.indexed(1), shown, try rowLabelStyle(context, shown));
    try context.e(Text{ .selectable = false, .key = key.indexed(3), .content = mark, .style = &style.binding_arrow });
    try cell.close(context);
    return row;
}

/// The rest of the dialog dims and blurs behind it; the caller opens and closes it.
pub fn modal(key: ui.Key, is_open: *bool, panel_style: *const ui.Style) Dialog {
    return .{ .is_open = is_open, .key = key, .style = panel_style, .parts = .{ .backdrop = &style.modal_backdrop } };
}

/// On whichever side of `anchor` has room; in closeResponse, `.backdrop` is a click outside.
pub fn openPopover(context: *ui.Frame, key: ui.Key, is_open: *bool, anchor: Box) !Dialog {
    const ui_state = context.ui();
    const extent = context.input().logical_extent;
    const viewport = [2]f32{ @floatFromInt(extent.width), @floatFromInt(extent.height) };
    const panel_key = key.indexed(DIALOG_PANEL_INDEX);
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, panel_key.hash());
    const panel_box = measuredBox(ui_state, panel_key);
    const panel_size = [2]f32{ style.POPOVER_WIDTH, if (panel_box.h() > 0) panel_box.h() else POPOVER_HEIGHT_GUESS };

    const right_of_anchor = anchor.x() + anchor.w() + POPOVER_GAP;
    const x = if (right_of_anchor + panel_size[0] + POPOVER_MARGIN <= viewport[0])
        right_of_anchor
    else
        @max(POPOVER_MARGIN, anchor.x() - POPOVER_GAP - panel_size[0]);
    const y = std.math.clamp(anchor.y(), POPOVER_MARGIN, @max(POPOVER_MARGIN, viewport[1] - panel_size[1] - POPOVER_MARGIN));
    return openPlaced(context, key, is_open, &style.popover, .{ x, y });
}

/// Aligned to `anchor`'s left edge, or its right where there's no room; the caller fills and closes it.
pub fn openMenu(context: *ui.Frame, key: ui.Key, is_open: *bool, anchor: Box) !Dialog {
    const viewport_width: f32 = @floatFromInt(context.input().logical_extent.width);
    const max_x = @max(POPOVER_MARGIN, viewport_width - style.MENU_WIDTH - POPOVER_MARGIN);
    const left_aligned = anchor.x();
    const x = std.math.clamp(if (left_aligned <= max_x) left_aligned else anchor.x() + anchor.w() - style.MENU_WIDTH, POPOVER_MARGIN, max_x);
    return openPlaced(context, key, is_open, &style.menu, .{ x, anchor.y() + anchor.h() + MENU_GAP });
}

/// A popover's heading beside its close button; returns whether close was clicked.
pub fn popoverTitle(context: *ui.Frame, key: ui.Key, title: []const u8) !bool {
    const row = Rect{ .key = key, .style = &style.popover_title };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = lang.text(title), .style = &style.heading });
    const is_close_clicked = (try context.interact(Button{ .key = key.indexed(2), .label = "\u{00D7}", .style = &style.popover_close })).clicked;
    try row.close(context);
    return is_close_clicked;
}

/// Zero until `key` has been laid out with a measured state.
pub fn measuredBox(ui_state: *ui.UI, key: ui.Key) Box {
    const measured = ui_state.state.get(.measured, key.hash()) orelse return .zero;
    return measured.box;
}

/// style.select as wide as the longest of `labels`, with SelectInput's padding, arrow and border around it.
pub fn fittedSelect(context: *ui.Frame, labels: []const []const u8) !*const ui.Style {
    return selectStyle(context, labels, 0);
}

/// fittedSelect for a row's only control, at least SELECT_MIN_WIDTH so a section's dropdowns line up.
pub fn rowSelect(context: *ui.Frame, labels: []const []const u8) !*const ui.Style {
    return selectStyle(context, labels, SELECT_MIN_WIDTH);
}

/// A label beside a column of aligned rows without dividers, e.g. a set of switches; the caller closes it.
pub fn openFieldGroup(context: *ui.Frame, key: ui.Key, label: []const u8) !FieldGroup {
    return openAnyFieldGroup(context, key, label, &style.field_group, &style.field_group_column);
}

/// openFieldGroup taking the rest of its pane's height, e.g. for a list that scrolls inside it.
pub fn openFillFieldGroup(context: *ui.Frame, key: ui.Key, label: []const u8) !FieldGroup {
    return openAnyFieldGroup(context, key, label, &style.field_group_fill, &style.field_group_column_fill);
}

/// A rule between runs of unaligned rows, which draw no dividers of their own.
pub fn separator(context: *ui.Frame, key: ui.Key) !void {
    g_last_labelled_row = null;
    try context.e(Rect{ .key = key, .style = &style.separator });
}

/// A master-detail pane's rows: a narrow label column, controls straight after; returns what it replaced, for restoreRows.
pub fn useDetailRows() RowSettings {
    const previous: RowSettings = .{ .is_aligned = g_is_aligned, .label_style = g_label_style };
    g_is_aligned = false;
    g_label_style = &style.detail_label;
    return previous;
}

pub fn restoreRows(previous: RowSettings) void {
    g_is_aligned = previous.is_aligned;
    g_label_style = previous.label_style;
}

/// A detail pane's own label, e.g. a name box's, in the label column every detail row shares.
pub fn detailLabelStyle(context: *ui.Frame, shown: []const u8) !*const ui.Style {
    try fitDetailColumn(context, shown, 0);
    return withWidth(context, &style.detail_label, g_detail_column);
}

/// How wide `text` draws in `text_style`'s font and size, in the window's logical pixels.
pub fn textWidth(context: *ui.Frame, text: []const u8, text_style: *const ui.Style) !f32 {
    const ui_state = context.ui();
    // Unset, text takes the theme's base size, as knots' own style resolution does.
    const font_size = if (text_style.font_size) |size| size.resolve(&ui_state.theme) else ui_state.theme.font_size[1];
    const face = try ui_state.font.getFace(text_style.font);
    const scale = ui_state.content_scale;
    return (try face.measure(text, font_size * scale)).width / scale;
}

/// From the next frame, so `name` doesn't break beside `lead` (portrait or dot, 0 for none) and `badge` ("" for none).
pub fn fitRosterRow(context: *ui.Frame, name: []const u8, lead: f32, badge: []const u8) !void {
    const frame_padding = comptime style.roster.padding.?;
    const row_padding = comptime style.roster_row.padding.?;
    const gap = comptime style.roster_row.gap.?;
    var widest: f32 = 0;
    var words = std.mem.tokenizeScalar(u8, name, ' ');
    while (words.next()) |word| widest = @max(widest, try textWidth(context, word, &style.roster_name_selected));
    var needed = frame_padding.left() + frame_padding.right() + style.ROW_SCROLLBAR_GUTTER + row_padding.left() + row_padding.right() + widest;
    if (lead > 0) needed += lead + gap;
    if (badge.len > 0) needed += gap + try textWidth(context, badge, &style.roster_badge);
    widenRosters(context, needed);
}

/// `base` at a fixed `width`, made in the frame's arena.
pub fn withWidth(context: *ui.Frame, base: *const ui.Style, width: f32) !*const ui.Style {
    const sized = try context.arena().create(ui.Style);
    sized.* = base.with(.{ .width = .fixed(width) });
    return sized;
}

/// A master list whose rows scroll, or fit when `is_filling` is false, above a pinned footer of add buttons.
pub fn openRoster(context: *ui.Frame, key: ui.Key, frame_style: *const ui.Style, is_filling: bool) !Roster {
    return openAnyRoster(context, key, frame_style, is_filling, null);
}

/// openRoster with a searchBox above its rows; the caller filters the rows by `query`.
pub fn openSearchedRoster(context: *ui.Frame, key: ui.Key, frame_style: *const ui.Style, is_filling: bool, query: *std.ArrayList(u8), placeholder: []const u8) !Roster {
    return openAnyRoster(context, key, frame_style, is_filling, .{ .query = query, .placeholder = placeholder });
}

/// A search box with a button to clear it, e.g. at the top of a master list; `query` is owned by the caller.
pub fn searchBox(context: *ui.Frame, key: ui.Key, query: *std.ArrayList(u8), placeholder: []const u8) !void {
    const row = Rect{ .key = key, .style = &style.search_row };
    _ = try row.open(context);
    try context.e(TextInput{ .key = key.indexed(1), .buf = query, .style = &style.text_input, .placeholder = lang.text(placeholder) });
    if (query.items.len > 0) {
        if ((try context.interact(Button{ .key = key.indexed(2), .label = "\u{00D7}", .style = &style.icon_button_danger_text })).clicked) {
            query.clearRetainingCapacity();
            context.requestRedraw();
        }
    }
    try row.close(context);
}

/// Centred where the list and details would be: `title`, `message`, then the caller's buttons; the caller closes it.
pub fn openEmptyState(context: *ui.Frame, key: ui.Key, title: []const u8, message: []const u8) !EmptyState {
    const state = Rect{ .key = key, .style = &style.empty_state };
    _ = try state.open(context);
    const shown_title = lang.text(title);
    const shown_message = lang.text(message);
    search.captureText(shown_title);
    search.captureText(shown_message);
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = shown_title, .style = &style.heading });
    try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = shown_message, .style = &style.muted_text });
    const actions = Rect{ .key = key.indexed(3), .style = &style.empty_state_actions };
    _ = try actions.open(context);
    return .{ .state = state, .actions = actions };
}

/// The refresh icon that adds every open EVE client; a tooltip names it, since the icon alone doesn't.
pub fn addOpenClientsButton(context: *ui.Frame, key: ui.Key, button_style: *const ui.Style) !bool {
    const label = lang.text("Add Open Clients");
    search.captureText(label);
    const tip = Tooltip{ .key = key, .content = label };
    _ = try tip.open(context);
    const is_clicked = try glyphButton(context, key.indexed(3), .refresh, "", button_style, false);
    try tip.close(context);
    return is_clicked;
}

/// A master list's row, showing the hand cursor while hovered; the caller closes it.
pub fn openRosterRow(context: *ui.Frame, row: Button) !Button.Response {
    const response = try row.openResponse(context);
    if (response.hovered) context.ui().requestCursor(.pointer);
    return response;
}

/// A detail pane's top row, whose rule replaces the next row's divider; the caller closes it.
pub fn openDetailHeader(context: *ui.Frame, key: ui.Key) !Rect {
    const header = Rect{ .key = key, .style = &style.detail_header };
    _ = try header.open(context);
    g_section_row_count = 0;
    return header;
}

/// Puts row labels left and controls at the right edge; returns the previous setting, for putting back.
pub fn useAlignedRows(is_aligned: bool) bool {
    const previous = g_is_aligned;
    g_is_aligned = is_aligned;
    return previous;
}

pub fn isAligned() bool {
    return g_is_aligned;
}

/// The width laid over a hotkey box in these rows, like slider's track; null keeps it growing.
pub fn hotkeyWidth() ?*const ui.Style {
    if (g_is_in_field_group) return &style.hotkey_width_grouped;
    if (g_is_aligned) return &style.hotkey_width_aligned;
    return null;
}

/// The caller's own cells, spaced and divided like aligned rows; the caller closes it.
pub fn openRow(context: *ui.Frame, key: ui.Key) !Row {
    return openSettingsRow(context, key, &style.aligned_row);
}

/// Keeps a scrollbar gutter only while scrolling, so rows otherwise reach the edge.
pub fn openScrollPane(context: *ui.Frame, key: ui.Key, styles: style.ScrollPane) !ScrollPane {
    const content_key = key.indexed(1);
    const ui_state = context.ui();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, key.hash());
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, content_key.hash());
    // Measured last frame; the content column fits its rows, so it outgrows the pane once the pane scrolls.
    const is_scrolling = blk: {
        const pane = ui_state.state.get(.measured, key.hash()) orelse break :blk false;
        const content = ui_state.state.get(.measured, content_key.hash()) orelse break :blk false;
        break :blk content.height > pane.height;
    };
    if (ui_state.state.get(.measured, key.hash())) |pane| {
        if (pane.height == 0) context.requestRedraw();
    }
    const pane = Rect{ .key = key, .style = if (is_scrolling) styles.scrolling else styles.pane };
    _ = try pane.open(context);
    const content = Rect{ .key = content_key, .style = styles.content };
    _ = try content.open(context);
    return .{ .pane = pane, .content = content };
}

/// Returns the index clicked, unless it's `selected`.
pub fn segmented(context: *ui.Frame, key: ui.Key, options: []const []const u8, selected: usize) !?usize {
    const group = Rect{ .key = key, .style = &style.segmented };
    _ = try group.open(context);
    var clicked_index: ?usize = null;
    for (options, 0..) |option, index| {
        const shown = lang.text(option);
        search.captureText(shown);
        const is_selected = index == selected;
        if ((try context.interact(Button{
            .key = key.indexed(index + 1),
            .label = shown,
            .style = if (is_selected) &style.segment_selected else &style.segment,
            .parts = .{ .label = if (is_selected) &style.segment_label_selected else &style.segment_label },
        })).clicked and !is_selected) clicked_index = index;
    }
    try group.close(context);
    return clicked_index;
}

/// `label` left, the caller's controls right, lit on hover; the caller closes it.
pub fn openModalRow(context: *ui.Frame, key: ui.Key, label: []const u8) !Row {
    const row = try openRow(context, key);
    try rowLabel(context, key, key.indexed(1), lang.text(label), &style.label_aligned);
    return row;
}

/// style.ACCENT_PRESETS and a rainbow picker; `is_custom` rings the picker even when `color` matches a preset.
pub fn accentChoices(context: *ui.Frame, key: ui.Key, color: *ui.Color, is_custom: *bool) !void {
    const row = Rect{ .key = key, .style = &style.accent_choices };
    _ = try row.open(context);
    const chosen_preset = if (is_custom.*) null else presetIndex(color_convert.toArgb(color.*));
    for (style.ACCENT_PRESETS, 0..) |accent, index| {
        const is_chosen = if (chosen_preset) |preset| preset == index else false;
        const preset_key = key.indexed(ACCENT_PRESET_INDEX + index);
        const ring = Rect{ .key = preset_key, .style = if (is_chosen) &style.accent_ring_chosen else &style.accent_ring };
        _ = try ring.open(context);
        const swatch_style = try context.arena().create(ui.Style);
        swatch_style.* = style.accent_preset.with(.{ .background = color_convert.solid(accent) });
        if ((try context.interact(Button{ .key = preset_key.indexed(1), .style = swatch_style })).clicked) {
            color.* = color_convert.fromArgb(accent);
            is_custom.* = false;
            context.requestRedraw();
        }
        try ring.close(context);
    }
    const custom_ring = Rect{ .key = key.indexed(1), .style = if (chosen_preset == null) &style.accent_ring_chosen else &style.accent_ring };
    _ = try custom_ring.open(context);
    const tip = Tooltip{ .key = key.indexed(2), .content = lang.text("Any other colour") };
    _ = try tip.open(context);
    const picker_key = key.indexed(3);
    _ = try context.interact(ColorPicker{
        .key = picker_key,
        .value = color,
        .style = &style.accent_custom,
        .parts = .{ .swatch = &style.accent_custom_fill, .popup = &style.color_popup },
        .show_hex = false,
        .show_alpha = false,
        .show_rainbow = true,
    });
    try tip.close(context);
    try custom_ring.close(context);
    try row.close(context);
    // Opening the picker chooses it, though its colour may still be a preset's.
    const picker = context.ui().state.get(.color_picker, picker_key.hash()) orelse return;
    if (picker.open and !is_custom.*) {
        is_custom.* = true;
        context.requestRedraw();
    }
}

/// Whether accentChoices offers `argb` as a preset.
pub fn isPresetAccent(argb: u32) bool {
    return presetIndex(argb) != null;
}

/// The swatch, its popup and the popup's Reset button, as every colour setting draws them.
pub fn colorParts(is_aligned: bool) ColorPicker.Parts {
    return .{
        .swatch = if (is_aligned) &style.color_swatch_fill else &style.color_swatch,
        .popup = &style.color_popup,
        .reset = &style.full_width_button,
        .reset_label = &style.button_text,
    };
}

/// Unset inherits `fallback`, shown struck through; Reset unsets it.
pub fn optionalColor(context: *ui.Frame, key: ui.Key, label: []const u8, current: ?u32, fallback: u32) !?ColorChange {
    const row = try openBinding(context, key, label);
    var change: ?ColorChange = null;
    var value = color_convert.fromArgb(current orelse fallback);
    var is_reset = false;
    if ((try context.interact(ColorPicker{
        .key = key.indexed(3),
        .value = &value,
        .style = if (g_is_aligned) &style.color_picker_swatch else &style.color_picker,
        .parts = colorParts(g_is_aligned),
        .show_hex = !g_is_aligned,
        .show_alpha = false,
        .is_unset = current == null,
        .reset = &is_reset,
    })).changed) change = .{ .set = color_convert.toArgb(value) };
    if (is_reset) change = .cleared;
    try row.close(context);
    return change;
}

/// Call for each row, keyed `base.indexed(index)`, before drawing it: a press on it starts dragging it.
pub fn reorderRow(context: *ui.Frame, base: ui.Key, index: usize) !void {
    try reorderRowByHandle(context, base, index, base.indexed(index));
}

/// Only a press on `handle` starts the drag, for rows whose controls take the press.
pub fn reorderRowByHandle(context: *ui.Frame, base: ui.Key, index: usize, handle: ui.Key) !void {
    const ui_state = context.ui();
    const id = base.indexed(index).hash();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, id);
    if (ui_state.leftPressed(handle.hash(), .within)) {
        const box = measuredBox(ui_state, base.indexed(index));
        const mouse_y = ui_state.input.mouse_pos[1];
        g_reorder = .{ .list = base.hash(), .from = index, .start_y = mouse_y, .grab_y = @as(f32, @floatCast(mouse_y)) - box.y(), .row_height = box.h(), .insert = index };
    }
}

/// Call once the rows are drawn: follows the drag, and returns the move once it's dropped somewhere new.
pub fn reorderFinish(context: *ui.Frame, base: ui.Key, count: usize) ?Move {
    const drag = if (g_reorder) |*active| active else return null;
    if (drag.list != base.hash()) return null;
    const ui_state = context.ui();
    const mouse_y = ui_state.input.mouse_pos[1];
    if (ui_state.input.mouseButton(.left).down) {
        if (@abs(mouse_y - drag.start_y) > DRAG_THRESHOLD) drag.has_moved = true;
        if (drag.has_moved) {
            ui_state.requestCursor(.move);
            // Counted without the dragged row, which may be drawn under the cursor; rows moving to open a gap move away from it, so this settles.
            var slot: usize = 0;
            for (0..count) |index| {
                if (index == drag.from) continue;
                const measured = ui_state.state.get(.measured, base.indexed(index).hash()) orelse continue;
                if (mouse_y > measured.box.y() + measured.box.h() / 2) slot += 1;
            }
            drag.insert = if (slot >= drag.from) slot + 1 else slot;
            context.requestRedraw();
        }
        return null;
    }
    const finished = drag.*;
    g_reorder = null;
    context.requestRedraw();
    if (!finished.has_moved or finished.insert == finished.from or finished.insert == finished.from + 1) return null;
    return .{ .from = finished.from, .before = finished.insert };
}

/// A run of settings that dims, and takes no clicks or keyboard focus, while `is_enabled` is false.
pub fn openGroup(context: *ui.Frame, key: ui.Key, is_enabled: bool) !Group {
    return openAnyGroup(context, key, &style.group, is_enabled);
}

/// Like openGroup, filling the rest of a filling tab's section.
pub fn openFillGroup(context: *ui.Frame, key: ui.Key, is_enabled: bool) !Group {
    return openAnyGroup(context, key, &style.group_fill, is_enabled);
}

/// Like openGroup, for controls side by side inside one row.
pub fn openInlineGroup(context: *ui.Frame, key: ui.Key, is_enabled: bool) !Group {
    return openAnyGroup(context, key, &style.group_inline, is_enabled);
}

/// The first click arms it and shows `confirm_label`; a second within two seconds returns true.
pub fn confirmButton(context: *ui.Frame, key: ui.Key, label: []const u8, confirm_label: []const u8, button_style: *const ui.Style, armed_style: *const ui.Style) !bool {
    const id = key.hash();
    const now = context.ui().input.now_ms;
    if (g_confirm_key == id and now >= g_confirm_until_ms) g_confirm_key = null;
    const is_armed = g_confirm_key == id;
    // Nothing else redraws the window when the wait runs out.
    if (is_armed) context.requestRedraw();
    const is_clicked = (try context.interact(Button{
        .key = key,
        .label = lang.text(if (is_armed) confirm_label else label),
        .style = if (is_armed) armed_style else button_style,
    })).clicked;
    if (!is_clicked) return false;
    if (is_armed) {
        g_confirm_key = null;
        return true;
    }
    g_confirm_key = id;
    g_confirm_until_ms = now + CONFIRM_TIMEOUT_MS;
    // This frame already drew the unarmed label.
    context.requestRedraw();
    return false;
}

/// A grip that a row is dragged by, for reorderRowByHandle.
pub fn dragHandle(context: *ui.Frame, key: ui.Key) !void {
    const handle = Button{ .key = key, .style = &style.drag_handle };
    if ((try handle.openResponse(context)).hovered) context.ui().requestCursor(.move);
    const glyph_key = key.indexed(1);
    try context.e(Canvas{
        .key = glyph_key,
        .commands = try glyphs.commands(context.arena(), .grip, style.DRAG_GRIP_SIZE, try glyphs.snapOffset(context, glyph_key), style.MUTED.value),
        .style = &style.drag_grip,
    });
    try handle.close(context);
}

/// A button whose label starts with a drawn glyph, for symbols Geist lacks.
pub fn glyphButton(context: *ui.Frame, key: ui.Key, glyph: glyphs.Glyph, label: []const u8, button_style: *const ui.Style, is_disabled: bool) !bool {
    const button = Button{ .key = key, .disabled = is_disabled, .style = if (is_disabled) try disabledLook(context, button_style) else button_style };
    const response = try button.openResponse(context);
    const color = if (is_disabled) style.MUTED else style.TEXT;
    const glyph_key = key.indexed(1);
    try context.e(Canvas{
        .key = glyph_key,
        .commands = try glyphs.commands(context.arena(), glyph, glyphs.TAB_SIZE, try glyphs.snapOffset(context, glyph_key), color.value),
        .style = &style.tab_glyph,
    });
    if (label.len > 0) try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = lang.text(label), .style = if (is_disabled) &style.muted_text else &style.button_text });
    try button.close(context);
    return response.clicked and !is_disabled;
}

/// Always shown, since a tooltip can't hold a link; returns whether it was clicked.
pub fn hintWithLink(context: *ui.Frame, key: ui.Key, content: []const u8, link_label: []const u8) !bool {
    const shown = lang.text(content);
    search.captureText(shown);
    const row = Rect{ .key = key, .style = &style.hint_link_row };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = shown, .style = &style.hint_inline });
    const is_clicked = (try context.interact(Button{ .key = key.indexed(2), .label = lang.text(link_label), .style = &style.link })).clicked;
    try row.close(context);
    return is_clicked;
}

/// Text in the hint style that always shows, inset to start where rows' labels do.
pub fn paragraph(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    search.captureText(lang.text(content));
    try boxedText(context, key, content, &style.hint_box, &style.hint);
}

/// On the previous row's label, else a paragraph; `content` must outlive the frame.
pub fn hintText(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    const row = g_last_labelled_row orelse return paragraph(context, key, content);
    search.captureText(lang.text(content));
    const row_id = row.hash();
    if (!g_row_hints.append(row_id, content)) return;
    // Registered after its row was drawn, so the tooltip shows from the next frame.
    if (g_row_hints_before.find(row_id) == null) context.requestRedraw();
}

/// A warning above a tab's sections, e.g. that it needs another setting turned on.
pub fn notice(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    try boxedText(context, key, content, &style.notice, &style.notice_text);
}

/// knots lays out a Text without padding, border or background, so they go on a surrounding Rect.
pub fn boxedText(context: *ui.Frame, key: ui.Key, content: []const u8, box_style: *const ui.Style, text_style: *const ui.Style) !void {
    const box = Rect{ .key = key, .style = box_style };
    _ = try box.open(context);
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = lang.text(content), .style = text_style });
    try box.close(context);
}

pub fn subheading(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    search.captureText(lang.text(content));
    try boxedText(context, key, content, &style.subheading_box, &style.subheading);
    g_section_row_count = 0;
    g_last_labelled_row = null;
}

/// Returns whether the user moved it this frame.
pub fn slider(context: *ui.Frame, key: ui.Key, value: *f32, min: f32, max: f32, steps: f32) !bool {
    const track_style = if (g_is_in_field_group) &style.slider_box_grouped else if (g_is_aligned) &style.slider_box_aligned else &style.slider_box;
    const track = Rect{ .key = key, .style = track_style };
    _ = try track.open(context);
    const response = try context.interact(SliderInput{
        .key = key.indexed(1),
        .value = value,
        .min = min,
        .max = max,
        .steps = steps,
        .parts = .{ .track = &style.slider_track, .fill = &style.slider_fill, .thumb = if (context.ui().inert_depth > 0) &style.slider_thumb_inert else &style.slider_thumb },
    });
    try track.close(context);
    return response.changed;
}

/// Returns whether the user toggled it this frame.
pub fn checkbox(context: *ui.Frame, key: ui.Key, label: []const u8, is_checked: *bool) !bool {
    const shown = lang.text(label);
    search.captureText(shown);
    if (!g_is_aligned) return (try context.interact(Checkbox{
        .key = key,
        .checked = is_checked,
        .label = shown,
        .style = &style.checkbox,
        .parts = .{ .box = &style.checkbox_box, .label = &style.checkbox_label },
    })).changed;
    if (shown.len == 0) return toggleSwitch(context, key, is_checked);

    const row = try openRow(context, key.indexed(9));
    try rowLabel(context, key.indexed(9), key.indexed(8), shown, alignedLabelStyle());
    const is_flipped = try toggleSwitch(context, key, is_checked);
    try row.close(context);
    if (is_flipped) return true;
    if (!row.is_clicked) return false;
    is_checked.* = !is_checked.*;
    return true;
}

/// A click anywhere on the row flips the switch; returns whether it flipped.
pub fn switchRow(context: *ui.Frame, key: ui.Key, label: []const u8, is_checked: *bool) !bool {
    const row = try openBinding(context, key, label);
    try context.e(Rect{ .key = key.indexed(3), .style = &style.spacer });
    const is_flipped = try toggleSwitch(context, key.indexed(4), is_checked);
    try row.close(context);
    if (is_flipped) return true;
    if (!row.is_clicked) return false;
    is_checked.* = !is_checked.*;
    return true;
}

/// A preview's text at `size` px in `color`, made in `arena`.
pub fn textStyle(arena: std.mem.Allocator, color: u32, size: f32, options: TextOptions) !*const ui.Style {
    const text_style = try arena.create(ui.Style);
    text_style.* = .{
        .foreground = color_convert.solid(color),
        .font_size = .{ .px = size },
        .opacity = if (options.is_shown) 1 else style.OFF_TEXT_OPACITY,
    };
    if (options.is_grown) text_style.width = .grow();
    return text_style;
}

/// knots has no switch: a pill button with a sliding knob; returns whether it flipped.
fn toggleSwitch(context: *ui.Frame, key: ui.Key, is_checked: *bool) !bool {
    // knots never animates layout, so the knob is pushed along by a spacer whose width is eased here.
    const position = context.ui().anim(key.hash(), "knob", if (is_checked.*) 1 else 0, .{ .duration_ms = style.SWITCH_ANIMATION_MS });
    const spacer = try context.arena().create(ui.Style);
    spacer.* = .{ .width = .fixed(position * style.SWITCH_TRAVEL) };
    const on_style = if (context.ui().inert_depth > 0) &style.switch_on_inert else &style.switch_on;
    const button = Button{ .key = key, .style = if (is_checked.*) on_style else &style.switch_off };
    const response = try button.openResponse(context);
    try context.e(Rect{ .key = key.indexed(2), .style = spacer });
    try context.e(Rect{ .key = key.indexed(1), .style = if (is_checked.*) &style.switch_knob_on else &style.switch_knob_off });
    try button.close(context);
    if (!response.clicked) return false;
    is_checked.* = !is_checked.*;
    context.requestRedraw();
    return true;
}

/// A Dialog with its panel's top-left corner at `corner`, over a backdrop that doesn't dim.
fn openPlaced(context: *ui.Frame, key: ui.Key, is_open: *bool, panel_style: *const ui.Style, corner: [2]f32) !Dialog {
    // The backdrop's padding is how far the panel sits from the window's top-left corner.
    const backdrop = try context.arena().create(ui.Style);
    backdrop.* = .{
        .@"align" = .start,
        .justify = .start,
        .padding = .init(corner[1], POPOVER_MARGIN, POPOVER_MARGIN, corner[0]),
        .background = .transparent,
    };
    const dialog = Dialog{ .is_open = is_open, .key = key, .style = panel_style, .parts = .{ .backdrop = backdrop } };
    _ = try dialog.open(context);
    return dialog;
}

/// Which of style.ACCENT_PRESETS `argb` is, alpha aside since the window draws the accent opaque.
fn presetIndex(argb: u32) ?usize {
    for (style.ACCENT_PRESETS, 0..) |accent, index| {
        if (accent & 0x00FFFFFF == argb & 0x00FFFFFF) return index;
    }
    return null;
}

fn selectStyle(context: *ui.Frame, labels: []const []const u8, min_width: f32) !*const ui.Style {
    const ui_state = context.ui();
    const font_size = (style.select.font_size orelse .sm).resolve(&ui_state.theme);
    var widest: f32 = 0;
    for (labels) |label| widest = @max(widest, try textWidth(context, label, &style.select));
    const padding = comptime style.select.padding.?;
    // SelectInput's own arrow sizing.
    const arrow = @max(10, font_size * 0.55);
    const border = 2;
    const width = padding.left() + widest + SELECT_ARROW_GAP + arrow + padding.right() + border;
    const fitted = try context.arena().create(ui.Style);
    fitted.* = style.select.with(.{ .width = .fixed(std.math.clamp(@ceil(width), min_width, SELECT_MAX_WIDTH)), .overflow = .hidden });
    return fitted;
}

/// Keeps `button_style`'s width and alignment, so a disabled full-width button doesn't shrink.
fn disabledLook(context: *ui.Frame, button_style: *const ui.Style) !*const ui.Style {
    const look = try context.arena().create(ui.Style);
    look.* = style.disabled_button.with(.{ .width = button_style.width, .justify = button_style.justify, .gap = button_style.gap });
    return look;
}

fn reorderLifted(context: *ui.Frame, base: ui.Key) ?Lifted {
    const drag = g_reorder orelse return null;
    if (drag.list != base.hash() or !drag.has_moved) return null;
    const mouse_y: f32 = @floatCast(context.ui().input.mouse_pos[1]);
    return .{ .from = drag.from, .slot = if (drag.insert > drag.from) drag.insert - 1 else drag.insert, .top = mouse_y - drag.grab_y, .row_height = drag.row_height };
}

fn openAnyRoster(context: *ui.Frame, key: ui.Key, frame_style: *const ui.Style, is_filling: bool, roster_search: ?RosterSearch) !Roster {
    const frame = Rect{ .key = key, .style = try withWidth(context, frame_style, g_roster_width) };
    _ = try frame.open(context);
    if (roster_search) |box| try searchBox(context, key.indexed(5), box.query, box.placeholder);
    const ui_state = context.ui();
    const pane_key = key.indexed(1);
    if (g_scroll_to_end == pane_key.hash()) {
        g_scroll_to_end = null;
        (try ui_state.state.getOrCreate(.scroll, ui_state.allocator, pane_key.hash())).offset = .{ 0, SCROLL_TO_END };
    }
    const rows = try openScrollPane(context, pane_key, if (is_filling) style.roster_scroll else style.roster_fit);
    return .{ .key = key, .frame = frame, .rows = rows };
}

fn openAnySection(context: *ui.Frame, comptime title: []const u8, comptime hint: []const u8, section_style: *const ui.Style, header_switch: ?SectionSwitch) !Section {
    const key: ui.Key = .str("knots.section:" ++ title);
    const id = key.hash();
    const ui_state = context.ui();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, id);
    const shown_title = lang.text(title);
    search.captureSection(id);
    search.captureText(shown_title);
    search.captureText(lang.text(hint));
    // A section the search doesn't match is laid out of sight rather than skipped, so its caller needn't know.
    const is_hidden = !search.sectionMatches(id);
    const section = Rect{ .key = key, .style = if (is_hidden) &style.section_hidden else section_style };
    _ = try section.open(context);
    g_open_section = id;
    g_section_row_count = 0;
    g_last_labelled_row = null;

    const heading = Rect{ .key = .str("knots.heading:" ++ title), .style = &style.section_heading };
    _ = try heading.open(context);
    const title_row = Rect{ .key = .str("knots.heading.title:" ++ title), .style = &style.section_heading_title };
    _ = try title_row.open(context);
    try context.e(Text{ .selectable = false, .key = .str("knots.title:" ++ title), .content = shown_title, .style = &style.heading });
    try title_row.close(context);
    var is_flipped = false;
    if (header_switch) |toggle| {
        const group = try openInlineGroup(context, .str("knots.section.switch.group:" ++ title), toggle.is_available);
        is_flipped = try toggleSwitch(context, .str("knots.section.switch:" ++ title), toggle.is_on);
        try group.close(context);
    }
    try heading.close(context);

    if (hint.len > 0) try boxedText(context, .str("knots.hint:" ++ title), hint, &style.hint_box, &style.hint);
    return .{ .rect = section, .is_flipped = is_flipped };
}

fn openAnyFieldGroup(context: *ui.Frame, key: ui.Key, label: []const u8, row_style: *const ui.Style, column_style: *const ui.Style) !FieldGroup {
    g_last_labelled_row = null;
    const row = Rect{ .key = key, .style = row_style };
    _ = try row.open(context);
    const shown = lang.text(label);
    search.captureText(shown);
    // The group's label sits a row's inset in, so its column is that much narrower.
    try fitDetailColumn(context, shown, style.ROW_INSET);
    const label_style = try withWidth(context, &style.field_group_label_text, g_detail_column - style.ROW_INSET);
    try boxedText(context, key.indexed(1), label, &style.field_group_label, label_style);
    const column = Rect{ .key = key.indexed(2), .style = column_style };
    _ = try column.open(context);
    const group: FieldGroup = .{ .row = row, .column = column, .was_aligned = g_is_aligned, .was_in_field_group = g_is_in_field_group };
    g_is_aligned = true;
    g_is_in_field_group = true;
    return group;
}

fn openAnyGroup(context: *ui.Frame, key: ui.Key, group_style: *const ui.Style, is_enabled: bool) !Group {
    const ui_state = context.ui();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, key.hash());
    const rect = Rect{ .key = key, .style = group_style };
    _ = try rect.open(context);
    if (!is_enabled) ui_state.inert_depth += 1;
    return .{ .key = key, .rect = rect, .is_enabled = is_enabled };
}

/// Inside a tooltip when last frame gave the row a hint.
fn rowLabel(context: *ui.Frame, row_key: ui.Key, label_key: ui.Key, shown: []const u8, label_style: *const ui.Style) !void {
    g_last_labelled_row = row_key;
    const label = Text{ .selectable = false, .key = label_key, .content = shown, .style = label_style };
    const hint = g_row_hints_before.find(row_key.hash()) orelse return context.e(label);
    // Sized like the label, so a label that grows still pushes the row's controls to its end.
    const trigger = try context.arena().create(ui.Style);
    trigger.* = .{ .width = label_style.width };
    const tip = Tooltip{ .key = row_key.indexed(ROW_TOOLTIP_INDEX), .content = lang.text(hint), .style = trigger, .align_start = true, .parts = .{ .popup = &style.row_tooltip } };
    // A disabled row still explains itself, so its label takes hover though the rest of the row is inert.
    const ui_state = context.ui();
    const inert_depth = ui_state.inert_depth;
    ui_state.inert_depth = 0;
    _ = try tip.open(context);
    ui_state.inert_depth = inert_depth;
    try context.e(label);
    try tip.close(context);
}

/// Against the controls when aligned, else in the label column, which a detail pane widens.
fn rowLabelStyle(context: *ui.Frame, shown: []const u8) !*const ui.Style {
    if (g_is_aligned) return alignedLabelStyle();
    if (g_label_style == &style.detail_label) return detailLabelStyle(context, shown);
    return g_label_style;
}

/// Widens the detail label column, from the next frame, to `shown`'s longest word plus `inset`.
fn fitDetailColumn(context: *ui.Frame, shown: []const u8, inset: f32) !void {
    var widest: f32 = 0;
    var words = std.mem.tokenizeScalar(u8, shown, ' ');
    while (words.next()) |word| widest = @max(widest, try textWidth(context, word, &style.detail_label));
    const needed = @min(@ceil(widest) + inset, style.DETAIL_LABEL_MAX_WIDTH);
    g_detail_column_next = @max(g_detail_column_next, needed);
    if (needed > g_detail_column) context.requestRedraw();
}

/// Widens every master list, from the next frame, to fit `footer`'s buttons.
fn fitRoster(context: *ui.Frame, footer: RosterFooter) !void {
    const add_padding = comptime style.roster_add.padding.?;
    const frame_padding = comptime style.roster.padding.?;
    const button_border = 2;
    const label_width = try textWidth(context, lang.text(footer.add_label), &style.button_text);
    var needed = frame_padding.left() + add_padding.left() + glyphs.TAB_SIZE + style.roster_add.gap.? + label_width + add_padding.right() + button_border + frame_padding.right();
    if (footer.has_open_clients) needed += style.roster_footer.gap.? + style.CONTROL_HEIGHT;
    widenRosters(context, needed);
}

/// Every master list takes this frame's widest `needed` from the next frame, up to style.ROSTER_MAX_WIDTH.
fn widenRosters(context: *ui.Frame, needed: f32) void {
    const width = @min(@ceil(needed), style.ROSTER_MAX_WIDTH);
    g_roster_width_next = @max(g_roster_width_next, width);
    if (width > g_roster_width) context.requestRedraw();
}

fn alignedLabelStyle() *const ui.Style {
    return if (g_is_in_field_group) &style.label_aligned_grouped else &style.label_aligned;
}

/// Counts the row: the section's first has no divider above it.
fn nextRowHasDivider() bool {
    defer g_section_row_count += 1;
    return !g_is_in_field_group and g_open_section != null and g_section_row_count > 0;
}

/// Lit anywhere in last frame's box, since knots only hovers the innermost element.
fn openSettingsRow(context: *ui.Frame, key: ui.Key, row_style: *const ui.Style) !Row {
    const divider: ?Rect = if (g_is_aligned and nextRowHasDivider()) Rect{ .key = key.indexed(ROW_DIVIDER_INDEX), .style = &style.row_divider } else null;
    if (divider) |rect| _ = try rect.open(context);

    // A row without a label leaves nothing for a hint after it to sit on.
    g_last_labelled_row = null;
    const ui_state = context.ui();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, key.hash());
    // Rows in a disabled group are inert, so they don't light up or take label clicks.
    const is_live = ui_state.inert_depth == 0 and ui_state.acceptsInput(key.hash());
    const mouse = ui_state.input.mouse_pos;
    const is_lit = is_live and measuredBox(ui_state, key).contains(.{ @floatCast(mouse[0]), @floatCast(mouse[1]) });
    const lit_style = try context.arena().create(ui.Style);
    lit_style.* = row_style.with(.{ .padding = .xy(style.ROW_INSET, 0), .radius = .sm, .background = if (is_lit) .{ .color = style.ROW_HOVER } else .transparent });
    // Interactive, so the cursor moving onto another row redraws, and a click on the label lands on the row.
    _ = try ui_state.openStyled(key, .{ .base = &Rect.base.root, .user = lit_style }, .{}, .{ .interactive = true });
    return .{ .rect = .{ .key = key, .style = lit_style }, .divider = divider, .is_clicked = is_live and (ui_state.leftClicked(key.hash(), .exact) or ui_state.leftClicked(key.indexed(ROW_TOOLTIP_INDEX).hash(), .exact)) };
}
