//! The configuration window's layout pieces and low-level controls; main thread only.
const std = @import("std");
const ui = @import("ui");
const style = @import("style.zig");

const glyphs = @import("glyphs.zig");
const search = @import("search.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Canvas = ui.component.Canvas;
const SliderInput = ui.component.SliderInput;
const ColorPicker = ui.component.ColorPicker;
const Checkbox = ui.component.Checkbox;
const Button = ui.component.Button;
const Color = ui.Color;

/// Most sections a tab has; past this they still draw, but miss their hint button.
const MAX_SECTIONS = 32;
/// Movement under this is a click on a row, not a drag.
const REORDER_THRESHOLD = 4;
/// How long a confirm button waits for its second click.
const CONFIRM_TIMEOUT_MS = 2000;

/// Section ids.
const SectionList = struct {
    ids: [MAX_SECTIONS]u64 = undefined,
    count: usize = 0,

    fn append(self: *SectionList, id: u64) void {
        if (self.count == MAX_SECTIONS) return;
        self.ids[self.count] = id;
        self.count += 1;
    }

    fn contains(self: *const SectionList, id: u64) bool {
        return std.mem.indexOfScalar(u64, self.ids[0..self.count], id) != null;
    }

    fn remove(self: *SectionList, id: u64) void {
        for (self.ids[0..self.count], 0..) |entry, index| {
            if (entry != id) continue;
            self.ids[index] = self.ids[self.count - 1];
            self.count -= 1;
            return;
        }
    }
};

/// What openGroup returns; closing it covers a disabled group so it can't be clicked.
pub const Group = struct {
    key: ui.Key,
    rect: Rect,
    is_enabled: bool,

    pub fn close(self: Group, context: *ui.Frame) !void {
        if (!self.is_enabled) {
            const ui_state = context.ui();
            const measured = ui_state.state.get(.measured, self.key.hash()) orelse {
                try self.rect.close(context);
                return;
            };
            const blocker = try context.arena().create(ui.Style);
            blocker.* = style.group_blocker.with(.{
                .width = .fixed(measured.box.w()),
                .height = .fixed(measured.box.h()),
            });
            try context.e(Button{ .key = self.key.indexed(1), .style = blocker });
        }
        try self.rect.close(context);
    }
};

/// What openSection returns; closing it ends the section's hints.
pub const Section = struct {
    rect: Rect,

    pub fn close(self: Section, context: *ui.Frame) !void {
        g_open_section = null;
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

/// What openFieldGroup returns; closing it puts back the row settings it replaced.
pub const FieldGroup = struct {
    row: Rect,
    column: Rect,
    was_aligned: bool,
    was_in_field_group: bool,

    pub fn close(self: FieldGroup, context: *ui.Frame) !void {
        g_is_aligned = self.was_aligned;
        g_in_field_group = self.was_in_field_group;
        try self.column.close(context);
        try self.row.close(context);
    }
};

/// What useDetailRows replaced.
pub const RowSettings = struct { is_aligned: bool, label_style: *const ui.Style };

/// What an optional colour row changed to.
pub const ColorChange = union(enum) { cleared, set: u32 };

/// A finished drag: item `from` now goes before what was item `before`.
pub const Move = struct { from: usize, before: usize };

/// Where a dragged row would land, drawn by the rows as a line above themselves.
pub const DropMark = enum { none, above, below };

/// Set by useAlignedRows: rows put their label left and their control at the right edge.
var g_is_aligned: bool = false;
/// Set by useDetailRows: the label column of unaligned rows.
var g_label_style: *const ui.Style = &style.label;
/// Set by openFieldGroup: its rows go undivided, with softer labels.
var g_in_field_group: bool = false;
/// Aligned rows drawn so far in the open section; every one after the first gets a divider above it.
var g_section_row_count: usize = 0;
var g_hinted: SectionList = .{};
/// Last frame's sections with field hints, which get a button to show them.
var g_hinted_before: SectionList = .{};
/// Sections whose field hints the user turned on.
var g_hints_shown: SectionList = .{};
var g_open_section: ?u64 = null;
var g_confirm_key: ?u64 = null;
/// The row being dragged to a new place in its list.
var g_reorder: ?struct { list: u64, from: usize, start_y: f64, insert: usize, moved: bool = false } = null;
var g_confirm_until_ms: i64 = 0;

pub fn beginFrame() void {
    g_hinted_before = g_hinted;
    g_hinted = .{};
}

/// Once the window has closed.
pub fn reset() void {
    g_hinted = .{};
    g_hinted_before = .{};
    g_hints_shown = .{};
    g_open_section = null;
    g_confirm_key = null;
}

/// A panel with its heading, a button for its field hints when it has any, and the intro hint; the caller closes it.
pub fn openSection(context: *ui.Frame, comptime title: []const u8, comptime hint: []const u8, section_style: *const ui.Style) !Section {
    const key: ui.Key = .str("knots.section:" ++ title);
    const id = key.hash();
    const ui_state = context.ui();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, id);
    search.captureSection(id);
    search.captureText(title);
    search.captureText(hint);
    // A section the search doesn't match is laid out of sight rather than skipped, so its caller needn't know.
    const is_hidden = !search.sectionMatches(id);
    const section = Rect{ .key = key, .style = if (is_hidden) &style.section_hidden else section_style };
    _ = try section.open(context);
    g_open_section = id;
    g_section_row_count = 0;

    const heading = Rect{ .key = .str("knots.heading:" ++ title), .style = &style.section_heading };
    _ = try heading.open(context);
    try context.e(Text{ .selectable = false, .key = .str("knots.title:" ++ title), .content = title, .style = &style.heading });
    const actions = Rect{ .key = .str("knots.heading.actions:" ++ title), .style = &style.section_heading_actions };
    _ = try actions.open(context);
    if (g_hinted_before.contains(id)) {
        const is_shown = g_hints_shown.contains(id);
        if ((try context.interact(Button{
            .key = .str("knots.hint.toggle:" ++ title),
            .label = "?",
            .style = if (is_shown) &style.hint_toggle_on else &style.hint_toggle,
        })).clicked) {
            if (is_shown) g_hints_shown.remove(id) else g_hints_shown.append(id);
            context.requestRedraw();
        }
    }
    try actions.close(context);
    try heading.close(context);

    if (hint.len > 0) try context.e(Text{ .selectable = false, .key = .str("knots.hint:" ++ title), .content = hint, .style = &style.hint });
    return .{ .rect = section };
}

/// A label-then-controls row; the caller adds the controls and closes it.
pub fn openBinding(context: *ui.Frame, key: ui.Key, label: []const u8) !Rect {
    const row = Rect{ .key = key, .style = if (g_is_aligned) nextRowStyle() else &.{
        .width = .grow(),
        .direction = .row,
        .@"align" = .center,
        .gap = 8,
    } };
    _ = try row.open(context);
    search.captureText(label);
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = label, .style = if (g_is_aligned) alignedLabelStyle() else g_label_style });
    return row;
}

/// A label beside a column of aligned rows without dividers, e.g. a set of switches; the caller closes it.
pub fn openFieldGroup(context: *ui.Frame, key: ui.Key, label: []const u8) !FieldGroup {
    const row = Rect{ .key = key, .style = &style.field_group };
    _ = try row.open(context);
    search.captureText(label);
    try boxedText(context, key.indexed(1), label, &style.field_group_label, g_label_style);
    const column = Rect{ .key = key.indexed(2), .style = &style.field_group_column };
    _ = try column.open(context);
    const group: FieldGroup = .{ .row = row, .column = column, .was_aligned = g_is_aligned, .was_in_field_group = g_in_field_group };
    g_is_aligned = true;
    g_in_field_group = true;
    return group;
}

/// A rule between runs of unaligned rows, which draw no dividers of their own.
pub fn separator(context: *ui.Frame, key: ui.Key) !void {
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

/// A row of the caller's own cells, e.g. a grid's, spaced and divided like the aligned rows around it; the caller closes it.
pub fn openRow(context: *ui.Frame, key: ui.Key) !Rect {
    const row = Rect{ .key = key, .style = if (g_is_aligned) nextRowStyle() else &style.aligned_row };
    _ = try row.open(context);
    return row;
}

/// A scrolling column that keeps a gutter for its scrollbar only while it has one, so its rows otherwise reach the edge like those around it.
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

/// A row of buttons, one per option, with `selected` highlighted; returns the index clicked, if it isn't the selected one.
pub fn segmented(context: *ui.Frame, key: ui.Key, options: []const []const u8, selected: usize) !?usize {
    const group = Rect{ .key = key, .style = &style.segmented };
    _ = try group.open(context);
    var clicked: ?usize = null;
    for (options, 0..) |option, index| {
        search.captureText(option);
        const is_selected = index == selected;
        if ((try context.interact(Button{
            .key = key.indexed(index + 1),
            .label = option,
            .style = if (is_selected) &style.segment_selected else &style.segment,
            .parts = .{ .label = if (is_selected) &style.segment_label_selected else &style.segment_label },
        })).clicked and !is_selected) clicked = index;
    }
    try group.close(context);
    return clicked;
}

/// A colour row that can be left unset to inherit `fallback`, shown struck through; the popup's Reset unsets it.
pub fn optionalColor(context: *ui.Frame, key: ui.Key, label: []const u8, current: ?u32, fallback: u32) !?ColorChange {
    const row = try openBinding(context, key, label);
    var change: ?ColorChange = null;
    var value = colorFromArgb(current orelse fallback);
    var is_reset = false;
    if ((try context.interact(ColorPicker{
        .key = key.indexed(3),
        .value = &value,
        .style = if (g_is_aligned) &style.color_picker_swatch else &style.color_picker,
        .parts = .{
            .swatch = if (g_is_aligned) &style.color_swatch_fill else &style.color_swatch,
            .popup = &style.color_popup,
            .reset = &style.full_width_button,
            .reset_label = &style.button_text,
        },
        .show_hex = !g_is_aligned,
        .show_alpha = false,
        .is_unset = current == null,
        .reset = &is_reset,
    })).changed) change = .{ .set = argbFromColor(value) };
    if (is_reset) change = .cleared;
    try row.close(context);
    return change;
}

/// Call for each row, keyed `base.indexed(index)`, before drawing it: a press starts dragging it; returns where the drop line goes.
pub fn reorderRow(context: *ui.Frame, base: ui.Key, index: usize, count: usize) !DropMark {
    const ui_state = context.ui();
    const id = base.indexed(index).hash();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, id);
    if (ui_state.leftPressed(id, .within)) {
        g_reorder = .{ .list = base.hash(), .from = index, .start_y = ui_state.input.mouse_pos[1], .insert = index };
    }
    const drag = g_reorder orelse return .none;
    if (drag.list != base.hash() or !drag.moved) return .none;
    if (drag.insert == index) return .above;
    if (drag.insert == count and index == count - 1) return .below;
    return .none;
}

/// Call once the rows are drawn: follows the drag, and returns the move once it's dropped somewhere new.
pub fn reorderFinish(context: *ui.Frame, base: ui.Key, count: usize) ?Move {
    const drag = &(g_reorder orelse return null);
    if (drag.list != base.hash()) return null;
    const ui_state = context.ui();
    const mouse_y = ui_state.input.mouse_pos[1];
    if (ui_state.input.mouseButton(.left).down) {
        if (@abs(mouse_y - drag.start_y) > REORDER_THRESHOLD) drag.moved = true;
        if (drag.moved) {
            var insert: usize = 0;
            for (0..count) |index| {
                const measured = ui_state.state.get(.measured, base.indexed(index).hash()) orelse continue;
                if (mouse_y > measured.box.y() + measured.box.h() / 2) insert = index + 1;
            }
            drag.insert = insert;
            context.requestRedraw();
        }
        return null;
    }
    const finished = drag.*;
    g_reorder = null;
    context.requestRedraw();
    if (!finished.moved or finished.insert == finished.from or finished.insert == finished.from + 1) return null;
    return .{ .from = finished.from, .before = finished.insert };
}

/// Settings that depend on a switch are hidden while it's off, except during a search, so the index and its matches still include them.
pub fn showsDependents(is_enabled: bool) bool {
    return is_enabled or search.isActive();
}

/// A run of settings that dims, and stops taking clicks, while `is_enabled` is false.
pub fn openGroup(context: *ui.Frame, key: ui.Key, is_enabled: bool) !Group {
    return openAnyGroup(context, key, if (is_enabled) &style.group else &style.group_disabled, is_enabled);
}

/// Like openGroup, for controls side by side inside one row.
pub fn openInlineGroup(context: *ui.Frame, key: ui.Key, is_enabled: bool) !Group {
    return openAnyGroup(context, key, if (is_enabled) &style.group_inline else &style.group_inline_disabled, is_enabled);
}

fn openAnyGroup(context: *ui.Frame, key: ui.Key, group_style: *const ui.Style, is_enabled: bool) !Group {
    const ui_state = context.ui();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, key.hash());
    const rect = Rect{ .key = key, .style = group_style };
    _ = try rect.open(context);
    return .{ .key = key, .rect = rect, .is_enabled = is_enabled };
}

/// The first click arms it and shows `confirm_label`; a second within two seconds returns true.
pub fn confirmButton(context: *ui.Frame, key: ui.Key, label: []const u8, confirm_label: []const u8, button_style: *const ui.Style, armed_style: *const ui.Style) !bool {
    const id = key.hash();
    const now = context.ui().input.now_ms;
    if (g_confirm_key == id and now >= g_confirm_until_ms) g_confirm_key = null;
    const is_armed = g_confirm_key == id;
    // Nothing else redraws the window when the wait runs out.
    if (is_armed) context.requestRedraw();
    const clicked = (try context.interact(Button{
        .key = key,
        .label = if (is_armed) confirm_label else label,
        .style = if (is_armed) armed_style else button_style,
    })).clicked;
    if (!clicked) return false;
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

/// A button whose label starts with a drawn glyph, for symbols Geist lacks.
pub fn glyphButton(context: *ui.Frame, key: ui.Key, glyph: glyphs.Glyph, label: []const u8, button_style: *const ui.Style, disabled: bool) !bool {
    const button = Button{ .key = key, .disabled = disabled, .style = if (disabled) &style.disabled_button else button_style };
    const response = try button.openResponse(context);
    const color = if (disabled) style.MUTED else style.TEXT;
    const glyph_key = key.indexed(1);
    try context.e(Canvas{
        .key = glyph_key,
        .commands = try glyphs.commands(context.arena(), glyph, glyphs.TAB_SIZE, try glyphs.snapOffset(context, glyph_key), color.value),
        .style = &style.tab_glyph,
    });
    if (label.len > 0) try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = label, .style = if (disabled) &style.muted_text else &style.button_text });
    try button.close(context);
    return response.clicked and !disabled;
}

/// A field hint ending in a link, e.g. "Learn more"; returns whether the link was clicked.
pub fn hintWithLink(context: *ui.Frame, key: ui.Key, content: []const u8, link_label: []const u8) !bool {
    search.captureText(content);
    if (g_open_section) |id| {
        if (!g_hinted.contains(id)) g_hinted.append(id);
        if (!g_hints_shown.contains(id)) return false;
    }
    const row = Rect{ .key = key, .style = &style.hint_row };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = content, .style = &style.hint_inline });
    const clicked = (try context.interact(Button{ .key = key.indexed(2), .label = link_label, .style = &style.link })).clicked;
    try row.close(context);
    return clicked;
}

/// Text in the hint style that always shows.
pub fn paragraph(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    search.captureText(content);
    try context.e(Text{ .selectable = false, .key = key, .content = content, .style = &style.hint });
}

/// Inside a section, a field hint: hidden until the section's ? button shows it.
pub fn hintText(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    search.captureText(content);
    if (g_open_section) |id| {
        if (!g_hinted.contains(id)) g_hinted.append(id);
        if (!g_hints_shown.contains(id)) return;
    }
    try context.e(Text{ .selectable = false, .key = key, .content = content, .style = &style.hint });
}

/// A warning above a tab's sections, e.g. that it needs another setting turned on.
pub fn notice(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    try boxedText(context, key, content, &style.notice, &style.notice_text);
}

/// Text inside a box: knots lays a Text out without its padding, border or background, so they go on a Rect around it.
pub fn boxedText(context: *ui.Frame, key: ui.Key, content: []const u8, box_style: *const ui.Style, text_style: *const ui.Style) !void {
    const box = Rect{ .key = key, .style = box_style };
    _ = try box.open(context);
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = content, .style = text_style });
    try box.close(context);
}

pub fn subheading(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    search.captureText(content);
    try boxedText(context, key, content, &style.subheading_box, &style.subheading);
    g_section_row_count = 0;
}

/// Returns whether the user moved it this frame.
pub fn slider(context: *ui.Frame, key: ui.Key, value: *f32, min: f32, max: f32, steps: f32) !bool {
    const track = Rect{ .key = key, .style = if (g_is_aligned) &style.slider_box_aligned else &style.slider_box };
    _ = try track.open(context);
    const response = try context.interact(SliderInput{
        .key = key.indexed(1),
        .value = value,
        .min = min,
        .max = max,
        .steps = steps,
        .parts = .{ .track = &style.slider_track, .fill = &style.slider_fill, .thumb = &style.slider_thumb },
    });
    try track.close(context);
    return response.changed;
}

/// A value shown beside a slider.
pub fn valueText(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    try context.e(Text{ .selectable = false, .key = key, .content = content, .style = &style.slider_value });
}

/// Returns whether the user toggled it this frame.
pub fn checkbox(context: *ui.Frame, key: ui.Key, label: []const u8, checked: *bool) !bool {
    search.captureText(label);
    if (!g_is_aligned) return (try context.interact(Checkbox{
        .key = key,
        .checked = checked,
        .label = label,
        .style = &style.checkbox,
        .parts = .{ .box = &style.checkbox_box, .label = &style.checkbox_label },
    })).changed;
    if (label.len == 0) return toggleSwitch(context, key, checked);

    const row = try openRow(context, key.indexed(9));
    try context.e(Text{ .selectable = false, .key = key.indexed(8), .content = label, .style = alignedLabelStyle() });
    const changed = try toggleSwitch(context, key, checked);
    try row.close(context);
    return changed;
}

/// knots has no switch, so it's a pill button whose knob slides across; returns whether it was flipped this frame.
pub fn toggleSwitch(context: *ui.Frame, key: ui.Key, checked: *bool) !bool {
    // knots never animates layout, so the knob is pushed along by a spacer whose width is eased here.
    const position = context.ui().anim(key.hash(), "knob", if (checked.*) 1 else 0, .{ .duration_ms = style.SWITCH_ANIMATION_MS });
    const spacer = try context.arena().create(ui.Style);
    spacer.* = .{ .width = .fixed(position * style.SWITCH_TRAVEL) };
    const button = Button{ .key = key, .style = if (checked.*) &style.switch_on else &style.switch_off };
    const response = try button.openResponse(context);
    try context.e(Rect{ .key = key.indexed(2), .style = spacer });
    try context.e(Rect{ .key = key.indexed(1), .style = if (checked.*) &style.switch_knob_on else &style.switch_knob_off });
    try button.close(context);
    if (!response.clicked) return false;
    checked.* = !checked.*;
    context.requestRedraw();
    return true;
}

pub fn colorFromArgb(argb: u32) Color {
    return .rgba(@truncate(argb >> 16), @truncate(argb >> 8), @truncate(argb), @truncate(argb >> 24));
}

pub fn argbFromColor(color: Color) u32 {
    const r: u32 = channelToByte(Color.linearToSrgb(color.value[0]));
    const g: u32 = channelToByte(Color.linearToSrgb(color.value[1]));
    const b: u32 = channelToByte(Color.linearToSrgb(color.value[2]));
    const a: u32 = channelToByte(color.value[3]);
    return (a << 24) | (r << 16) | (g << 8) | b;
}

fn alignedLabelStyle() *const ui.Style {
    return if (g_in_field_group) &style.label_aligned_grouped else &style.label_aligned;
}

/// Counts the row: the section's first has no divider above it.
fn nextRowStyle() *const ui.Style {
    defer g_section_row_count += 1;
    return if (!g_in_field_group and g_open_section != null and g_section_row_count > 0) &style.divided_row else &style.aligned_row;
}

fn channelToByte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}
