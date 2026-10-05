//! The knots configuration window's layout pieces and low-level controls, styled like the WebView2 page; main thread only.
const std = @import("std");
const ui = @import("ui");
const style = @import("style.zig");

const glyphs = @import("glyphs.zig");
const search = @import("search.zig");
const log = @import("../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Canvas = ui.component.Canvas;
const SliderInput = ui.component.SliderInput;
const ColorPicker = ui.component.ColorPicker;
const Checkbox = ui.component.Checkbox;
const Button = ui.component.Button;
const Color = ui.Color;
const slog = log.scoped("dialog_knots");

/// Most sections a tab has; past this they still draw, but miss the sidebar and their hint button.
const MAX_SECTIONS = 32;
/// The gap the page's scroll-margin-top leaves above a section jumped to.
const JUMP_MARGIN = 8;
/// Movement under this is a click on a row, not a drag.
const REORDER_THRESHOLD = 4;
/// How long a confirm button waits for its second click, as the page's confirmRemove does.
const CONFIRM_TIMEOUT_MS = 2000;

/// Which settings file a section's settings are saved to, shown as a chip beside its heading.
pub const Scope = enum {
    none,
    profile,
    global,
    /// Files outside the app, e.g. EVE's own settings.
    external,
};

/// A drawn section, for the sidebar to list and jump to.
pub const SectionEntry = struct {
    /// Comptime, so it outlives every frame.
    title: []const u8,
    id: u64,
};

const SectionList = struct {
    entries: [MAX_SECTIONS]SectionEntry = undefined,
    count: usize = 0,

    fn append(self: *SectionList, entry: SectionEntry) void {
        if (self.count == MAX_SECTIONS) return;
        self.entries[self.count] = entry;
        self.count += 1;
    }

    fn contains(self: *const SectionList, id: u64) bool {
        for (self.entries[0..self.count]) |entry| {
            if (entry.id == id) return true;
        }
        return false;
    }

    fn remove(self: *SectionList, id: u64) void {
        for (self.entries[0..self.count], 0..) |entry, index| {
            if (entry.id != id) continue;
            self.entries[index] = self.entries[self.count - 1];
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

/// What an optional colour row changed to.
pub const ColorChange = union(enum) { cleared, set: u32 };

/// A finished drag: item `from` now goes before what was item `before`.
pub const Move = struct { from: usize, before: usize };

/// Where a dragged row would land, drawn by the rows as a line above themselves.
pub const DropMark = enum { none, above, below };

/// What openBinding styles its label with; narrowed in tight spots like a popover by useLabelStyle.
var g_label_style: *const ui.Style = &style.label;
var g_drawn: SectionList = .{};
/// Last frame's sections: the sidebar is drawn before this frame's.
var g_drawn_before: SectionList = .{};
var g_hinted: SectionList = .{};
/// Last frame's sections with field hints, which get a button to show them.
var g_hinted_before: SectionList = .{};
/// Sections whose field hints the user turned on.
var g_hints_shown: SectionList = .{};
var g_open_section: ?u64 = null;
/// The section last jumped to from the sidebar, outlined until the tab changes.
var g_active_section: ?u64 = null;
var g_pending_jump: ?u64 = null;
/// The last section listed in the sidebar, which a linked section outlines along with.
var g_last_listed: ?u64 = null;
var g_confirm_key: ?u64 = null;
/// The row being dragged to a new place in its list.
var g_reorder: ?struct { list: u64, from: usize, start_y: f64, insert: usize, moved: bool = false } = null;
var g_confirm_until_ms: i64 = 0;

pub fn beginFrame() void {
    g_drawn_before = g_drawn;
    g_drawn = .{};
    g_hinted_before = g_hinted;
    g_hinted = .{};
}

/// Once the window has closed.
pub fn reset() void {
    g_drawn = .{};
    g_drawn_before = .{};
    g_hinted = .{};
    g_hinted_before = .{};
    g_hints_shown = .{};
    g_open_section = null;
    g_active_section = null;
    g_pending_jump = null;
    g_last_listed = null;
    g_confirm_key = null;
}

/// The sections the open tab drew last frame.
pub fn drawnSections() []const SectionEntry {
    return g_drawn_before.entries[0..g_drawn_before.count];
}

pub fn isActiveSection(id: u64) bool {
    return g_active_section == id;
}

/// Scrolls the section to the top of the pane on the next applyJump, and outlines it.
pub fn jumpTo(id: u64) void {
    g_active_section = id;
    g_pending_jump = id;
}

/// When the tab changes.
pub fn clearActiveSection() void {
    g_active_section = null;
    g_pending_jump = null;
}

/// Before the scrolling pane opens; positions are last frame's, which the jump was clicked from.
pub fn applyJump(context: *ui.Frame, pane_key: ui.Key) void {
    const id = g_pending_jump orelse return;
    g_pending_jump = null;
    const ui_state = context.ui();
    const pane = ui_state.state.get(.measured, pane_key.hash()) orelse return;
    const section = ui_state.state.get(.measured, id) orelse return;
    const scroll = ui_state.state.getOrCreate(.scroll, ui_state.allocator, pane_key.hash()) catch |err| {
        slog.warn("Failed to jump to a section: {}", .{err});
        return;
    };
    scroll.offset[1] = @max(0, scroll.offset[1] + section.box.y() - pane.box.y() - JUMP_MARGIN);
    context.requestRedraw();
}

/// A panel with its heading, the scope chip, a button for its field hints when it has any, and the intro hint; the caller closes it.
pub fn openSection(context: *ui.Frame, comptime title: []const u8, comptime hint: []const u8, scope: Scope, section_style: *const ui.Style) !Section {
    return openAnySection(context, title, hint, scope, section_style, true);
}

/// Like the page's no-subheader sections: left out of the sidebar, and outlined along with the section before it.
pub fn openLinkedSection(context: *ui.Frame, comptime title: []const u8, comptime hint: []const u8, scope: Scope, section_style: *const ui.Style) !Section {
    return openAnySection(context, title, hint, scope, section_style, false);
}

fn openAnySection(context: *ui.Frame, comptime title: []const u8, comptime hint: []const u8, scope: Scope, section_style: *const ui.Style, is_listed: bool) !Section {
    const key: ui.Key = .str("knots.section:" ++ title);
    const id = key.hash();
    const ui_state = context.ui();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, id);
    search.captureSection(id);
    search.captureText(title);
    search.captureText(hint);
    // A section the search doesn't match is laid out of sight rather than skipped, so its caller needn't know.
    const is_hidden = !search.sectionMatches(id);
    if (is_listed and !is_hidden) {
        g_drawn.append(.{ .title = title, .id = id });
        g_last_listed = id;
    }
    const outline_id = if (is_listed) id else g_last_listed;

    var shown_style = if (is_hidden) &style.section_hidden else section_style;
    if (!is_hidden and g_active_section != null and g_active_section == outline_id) {
        const active = try context.arena().create(ui.Style);
        active.* = section_style.with(.{ .border_color = .accent });
        shown_style = active;
    }
    const section = Rect{ .key = key, .style = shown_style };
    _ = try section.open(context);
    g_open_section = id;

    const heading = Rect{ .key = .str("knots.heading:" ++ title), .style = &style.section_heading };
    _ = try heading.open(context);
    try context.e(Text{ .selectable = false, .key = .str("knots.title:" ++ title), .content = title, .style = &style.heading });
    const actions = Rect{ .key = .str("knots.heading.actions:" ++ title), .style = &style.section_heading_actions };
    _ = try actions.open(context);
    if (scope != .none) try context.e(Text{ .selectable = false, .key = .str("knots.scope:" ++ title), .content = switch (scope) {
        .none => "",
        .profile => "PROFILE",
        .global => "ALL PROFILES",
        .external => "EVE SETTINGS",
    }, .style = &style.scope_chip });
    if (g_hinted_before.contains(id)) {
        const is_shown = g_hints_shown.contains(id);
        if ((try context.interact(Button{
            .key = .str("knots.hint.toggle:" ++ title),
            .label = "?",
            .style = if (is_shown) &style.hint_toggle_on else &style.hint_toggle,
        })).clicked) {
            if (is_shown) g_hints_shown.remove(id) else g_hints_shown.append(.{ .title = title, .id = id });
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
    const row = Rect{ .key = key, .style = &.{
        .width = .grow(),
        .direction = .row,
        .@"align" = .center,
        .gap = 8,
    } };
    _ = try row.open(context);
    search.captureText(label);
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = label, .style = g_label_style });
    return row;
}

/// Styles the labels of rows opened after it; returns the style it replaced, for putting back.
pub fn useLabelStyle(label_style: *const ui.Style) *const ui.Style {
    const previous = g_label_style;
    g_label_style = label_style;
    return previous;
}

/// A colour that can be left unset to inherit `fallback`: a tick sets it, and picking a colour ticks it.
pub fn optionalColor(context: *ui.Frame, key: ui.Key, label: []const u8, current: ?u32, fallback: u32) !?ColorChange {
    const row = Rect{ .key = key, .style = &style.inline_row };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = label, .style = &style.inline_label_wide });
    var change: ?ColorChange = null;
    var is_set = current != null;
    if (try checkbox(context, key.indexed(2), "", &is_set)) change = if (is_set) .{ .set = current orelse fallback } else .cleared;
    var value = colorFromArgb(current orelse fallback);
    if ((try context.interact(ColorPicker{
        .key = key.indexed(3),
        .value = &value,
        .style = &style.color_picker,
        .parts = .{ .swatch = &style.color_swatch, .popup = &style.color_popup },
    })).changed) change = .{ .set = argbFromColor(value) };
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

/// A run of settings that dims, and stops taking clicks, while `is_enabled` is false, like the page's .is-disabled.
pub fn openGroup(context: *ui.Frame, key: ui.Key, is_enabled: bool) !Group {
    const ui_state = context.ui();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, key.hash());
    const rect = Rect{ .key = key, .style = if (is_enabled) &style.group else &style.group_disabled };
    _ = try rect.open(context);
    return .{ .key = key, .rect = rect, .is_enabled = is_enabled };
}

/// Like the page's confirmRemove: the first click arms it and shows `confirm_label`; a second within two seconds returns true.
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
    return false;
}

/// A button whose label starts with a drawn glyph, for the page's labels whose symbol Cascadia Code lacks.
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

/// A field hint ending in a link, like the page's "Learn more"; returns whether the link was clicked.
pub fn hintWithLink(context: *ui.Frame, key: ui.Key, content: []const u8, link_label: []const u8) !bool {
    search.captureText(content);
    if (g_open_section) |id| {
        if (!g_hinted.contains(id)) g_hinted.append(.{ .title = "", .id = id });
        if (!g_hints_shown.contains(id)) return false;
    }
    const row = Rect{ .key = key, .style = &style.hint_row };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = content, .style = &style.hint_inline });
    const clicked = (try context.interact(Button{ .key = key.indexed(2), .label = link_label, .style = &style.link })).clicked;
    try row.close(context);
    return clicked;
}

/// Text in the hint style that always shows, like the page's plain p.hint.
pub fn paragraph(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    search.captureText(content);
    try context.e(Text{ .selectable = false, .key = key, .content = content, .style = &style.hint });
}

/// Inside a section, a field hint like the page's hint-extra: hidden until the section's ? button shows it.
pub fn hintText(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    search.captureText(content);
    if (g_open_section) |id| {
        if (!g_hinted.contains(id)) g_hinted.append(.{ .title = "", .id = id });
        if (!g_hints_shown.contains(id)) return;
    }
    try context.e(Text{ .selectable = false, .key = key, .content = content, .style = &style.hint });
}

/// A warning above a tab's sections, e.g. that it needs another setting turned on.
pub fn notice(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    try context.e(Text{ .selectable = false, .key = key, .content = content, .style = &style.notice });
}

pub fn subheading(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    search.captureText(content);
    try context.e(Text{ .selectable = false, .key = key, .content = content, .style = &style.subheading });
}

/// Returns whether the user moved it this frame.
pub fn slider(context: *ui.Frame, key: ui.Key, value: *f32, min: f32, max: f32, steps: f32) !bool {
    const track = Rect{ .key = key, .style = &.{ .width = .grow(), .padding = .xy(8, 0) } };
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
    return (try context.interact(Checkbox{
        .key = key,
        .checked = checked,
        .label = label,
        .style = &style.checkbox,
        .parts = .{ .box = &style.checkbox_box, .label = &style.checkbox_label },
    })).changed;
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

fn channelToByte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}
