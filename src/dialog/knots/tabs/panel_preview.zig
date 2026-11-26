//! What the previews share: the bench holding a preview, its parts list and the selected part's settings, the parts clicked to select them, and the frame and header every panel draws; main thread only.
const std = @import("std");
const ui = @import("ui");
const list_look = @import("../../../panels/list_look.zig");
const palette = @import("../../../palette.zig");
const panel_header = @import("../../../panels/panel_header.zig");
const glyphs = @import("../glyphs.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const color_convert = @import("../color_convert.zig");
const lang = @import("../../../lang/lang.zig");

const Button = ui.component.Button;
const Canvas = ui.component.Canvas;
const Rect = ui.component.Rect;
const Text = ui.component.Text;

/// Where the panels' header draws its chevron and title.
const HEADER_PADDING_X: i32 = 9;
const HEADER_GAP: i32 = 6;
/// How much a part's outline pads what it holds, in real pixels.
pub const PART_PADDING: i32 = 3;
const PART_RADIUS: f32 = 3;
/// style.bench_stage's padding either side of the preview.
const STAGE_PADDING_X: f32 = 12;
/// Under the part keys, so a row's key can't meet a part's.
const ROW_KEY_INDEX = 1000;

/// A preview's stage across the top, then its parts list beside the selected part's settings; the caller fills it in that order and closes it.
pub const Bench = struct {
    key: ui.Key,
    outer: Rect,
    stage: ?Rect = null,
    preview_row: ?Rect = null,
    desk: ?Rect = null,
    part_list: ?Rect = null,
    inspector: ?Rect = null,
    /// The room the stage gives its preview; 0 until laid out.
    available_width: f32,

    pub fn open(context: *ui.Frame, key: ui.Key) !Bench {
        const ui_state = context.ui();
        _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, key.hash());
        const width = widgets.measuredBox(ui_state, key).w();
        // Not laid out yet, so draw once more knowing the room there is.
        if (width == 0) context.requestRedraw();
        const outer = Rect{ .key = key, .style = &style.bench };
        _ = try outer.open(context);
        return .{ .key = key, .outer = outer, .available_width = @max(0, width - 2 * STAGE_PADDING_X) };
    }

    /// How much a preview `panel_width` wide shrinks to fit the stage; 1 at real size.
    pub fn scaleFor(self: *const Bench, panel_width: f32) f32 {
        return if (self.available_width > 0 and panel_width > self.available_width) self.available_width / panel_width else 1;
    }

    /// The stage's tools, then a row the caller centres its preview in and ends with closeStage.
    pub fn openStage(self: *Bench, context: *ui.Frame, scale: f32, shows_off: *bool) !void {
        const stage = Rect{ .key = self.key.indexed(2), .style = &style.bench_stage };
        _ = try stage.open(context);
        try stageTools(context, self.key.indexed(3), scale, shows_off);
        const row = Rect{ .key = self.key.indexed(4), .style = &style.stage_row };
        _ = try row.open(context);
        self.stage = stage;
        self.preview_row = row;
    }

    /// Ends the stage, and starts the column the caller fills with Picker.partList.
    pub fn closeStage(self: *Bench, context: *ui.Frame) !void {
        if (self.preview_row) |row| try row.close(context);
        if (self.stage) |stage| try stage.close(context);
        self.preview_row = null;
        self.stage = null;
        const desk = Rect{ .key = self.key.indexed(6), .style = &style.bench_desk };
        _ = try desk.open(context);
        const part_list = Rect{ .key = self.key.indexed(1), .style = &style.part_list };
        _ = try part_list.open(context);
        self.desk = desk;
        self.part_list = part_list;
    }

    /// Ends the parts list, and starts the column the caller fills with the selected part's settings.
    pub fn openInspector(self: *Bench, context: *ui.Frame) !void {
        if (self.part_list) |part_list| try part_list.close(context);
        self.part_list = null;
        const inspector = Rect{ .key = self.key.indexed(5), .style = &style.bench_inspector };
        _ = try inspector.open(context);
        self.inspector = inspector;
    }

    pub fn close(self: *const Bench, context: *ui.Frame) !void {
        if (self.inspector) |inspector| try inspector.close(context);
        if (self.desk) |desk| try desk.close(context);
        try self.outer.close(context);
    }
};

/// A preview part clicked to select it, which the caller closes; while off, State says whether it's a ghost or unseen.
pub const Part = struct {
    button: Button,
    state: State,
    inset: [2]f32,
    is_hovered: bool,
    is_clicked: bool,

    pub const State = struct {
        /// Whether the panel draws it with the current settings.
        is_shown: bool,
        is_selected: bool,
        /// Its row in the parts list is hovered.
        is_lit: bool,
        /// The stage's Show Off is on.
        shows_off: bool,

        /// Off, unselected and not asked for: drawn unseen, keeping its room.
        pub fn isHidden(self: State) bool {
            return !self.is_shown and !self.is_selected and !self.shows_off;
        }

        /// For what the part holds, which the part's own opacity doesn't reach: none while hidden, faded while off.
        pub fn contentOpacity(self: State) f32 {
            if (self.isHidden()) return 0;
            return if (self.is_shown) 1 else style.OFF_TEXT_OPACITY;
        }
    };

    /// `base` sets the part's layout, background and padding; `inset` is that padding's left and top, where its absolute children start.
    pub fn open(context: *ui.Frame, key: ui.Key, base: ui.Style, inset: [2]f32, state: State) !Part {
        const ui_state = context.ui();
        _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, key.hash());
        const is_hidden = state.isHidden();
        const part_style = try context.arena().create(ui.Style);
        part_style.* = base.with(.{
            // A Button centres its content, which pushes a row with a growing name off its right edge.
            .justify = .start,
            .border_width = .all(1),
            .border_color = if (state.is_selected or state.is_lit) .accent else .transparent,
            .radius = .{ .fixed = PART_RADIUS },
            .opacity = if (is_hidden) 0 else 1,
            .hover = if (is_hidden) &.{ .state_layer = 0 } else &.{ .border_color = .accent, .state_layer = 0 },
            .active = &.{ .state_layer = 0 },
        });
        const button = Button{ .key = key, .style = part_style };
        const response = try button.openResponse(context);
        if (response.hovered and !is_hidden) ui_state.requestCursor(.pointer);
        return .{ .button = button, .state = state, .inset = inset, .is_hovered = response.hovered, .is_clicked = response.clicked };
    }

    pub fn close(self: Part, context: *ui.Frame) !void {
        const is_outlined = self.is_hovered or self.state.is_selected or self.state.is_lit;
        if (!self.state.is_shown and !self.state.isHidden() and !is_outlined) {
            const box = widgets.measuredBox(context.ui(), self.button.key);
            // First frame: not laid out yet, so draw once more with its real size.
            if (box.w() == 0) {
                context.requestRedraw();
            } else {
                try widgets.dashedOutline(context, self.button.key.indexed(1), .{ box.w(), box.h() }, self.inset);
            }
        }
        try self.button.close(context);
    }
};

/// Which of a preview's parts is selected, and the parts list that picks one; `Kind` is the tab's enum of parts.
pub fn Picker(comptime Kind: type) type {
    return struct {
        part_key: ui.Key,
        selected: Kind,
        /// The stage's Show Off: off parts are drawn as ghosts.
        shows_off: bool = false,
        /// The part whose row was hovered last frame, lit on the preview.
        lit: ?Kind = null,

        const Self = @This();

        /// One part's row in the parts list.
        pub const Row = struct {
            part: Kind,
            /// English; translated when drawn.
            label: []const u8,
            is_shown: bool,
            /// The dot's, e.g. the part's text colour.
            color: u32,
            /// A rule goes above it.
            starts_group: bool = false,
        };

        /// As Part.open, keyed for `part`; a click selects it.
        pub fn openPart(self: *Self, context: *ui.Frame, base: ui.Style, inset: [2]f32, part: Kind, is_shown: bool) !Part {
            const open = try Part.open(context, self.keyOf(part), base, inset, self.stateOf(part, is_shown));
            if (open.is_clicked) self.select(context, part);
            return open;
        }

        /// A panel's header bar, as `part`: its chevron, `title` and muted `count` in the configuration window's font, as the panels draw it.
        pub fn header(self: *Self, context: *ui.Frame, part: Kind, key: ui.Key, title: []const u8, count: []const u8, scale: f32) !void {
            const header_part = try self.openPart(context, .{ .width = .grow(), .padding = .all(1), .background = .transparent }, .{ 1, 1 }, part, true);
            try headerBar(context, key, title, count, scale);
            try header_part.close(context);
        }

        pub fn stateOf(self: *const Self, part: Kind, is_shown: bool) Part.State {
            return .{ .is_shown = is_shown, .is_selected = self.selected == part, .is_lit = self.lit == part, .shows_off = self.shows_off };
        }

        /// State.contentOpacity for `part`.
        pub fn contentOpacity(self: *const Self, part: Kind, is_shown: bool) f32 {
            return self.stateOf(part, is_shown).contentOpacity();
        }

        pub fn keyOf(self: *const Self, part: Kind) ui.Key {
            return self.part_key.indexed(@backingInt(part));
        }

        pub fn select(self: *Self, context: *ui.Frame, part: Kind) void {
            if (self.selected == part) return;
            self.selected = part;
            context.requestRedraw();
        }

        /// One row per part: its dot and name, which select it, then whatever on switch `draw_switch` draws for it, named after the part.
        pub fn partList(self: *Self, context: *ui.Frame, rows: []const Row, comptime draw_switch: fn (*ui.Frame, Kind) anyerror!void) !void {
            var hovered: ?Kind = null;
            for (rows, 0..) |row, index| {
                if (index > 0 and row.starts_group) try context.e(Rect{ .key = self.rowKey(row.part).indexed(3), .style = &style.part_list_divider });
                if (try self.partRow(context, row, draw_switch)) hovered = row.part;
            }
            if (hovered != self.lit) {
                self.lit = hovered;
                context.requestRedraw();
            }
        }

        /// Returns whether its name is hovered.
        fn partRow(self: *Self, context: *ui.Frame, row: Row, comptime draw_switch: fn (*ui.Frame, Kind) anyerror!void) !bool {
            const arena = context.arena();
            const key = self.rowKey(row.part);
            const is_selected = self.selected == row.part;
            const line = Rect{ .key = key.indexed(4), .style = if (is_selected) &style.part_row_selected else &style.part_row };
            _ = try line.open(context);
            const button = Button{ .key = key, .style = &style.part_row_button };
            const response = try button.openResponse(context);
            const shown = lang.text(row.label);
            try context.ui().setAccessibilityName(response.id, shown);
            if (response.hovered) context.ui().requestCursor(.pointer);
            const dot = try arena.create(ui.Style);
            dot.* = if (row.is_shown) style.part_dot.with(.{ .background = color_convert.solid(row.color) }) else style.part_dot_off;
            try context.e(Rect{ .key = key.indexed(1), .style = dot });
            const label_style = if (is_selected) &style.part_row_label_selected else if (row.is_shown) &style.part_row_label else &style.part_row_label_off;
            try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = shown, .style = label_style });
            try button.close(context);
            const previous_name = widgets.useControlName(shown);
            try draw_switch(context, row.part);
            _ = widgets.useControlName(previous_name);
            try line.close(context);
            if (response.clicked) self.select(context, row.part);
            return response.hovered;
        }

        fn rowKey(self: *const Self, part: Kind) ui.Key {
            return self.part_key.indexed(ROW_KEY_INDEX).indexed(@backingInt(part));
        }
    };
}

/// The inspector's heading: the selected part's `title`.
pub fn inspectorTitle(context: *ui.Frame, key: ui.Key, title: []const u8) !void {
    const row = Rect{ .key = key, .style = &style.inspector_title };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = lang.text(title), .style = &style.inspector_title_text });
    try row.close(context);
}

/// `pixels` real pixels at `scale`.
pub fn scaled(scale: f32, pixels: i32) f32 {
    return @as(f32, @floatFromInt(pixels)) * scale;
}

/// A panel's frame in list_look's colours at `scale`, sized by `size`'s width and height or padding.
pub fn frameStyle(arena: std.mem.Allocator, scale: f32, opacity: u8, size: ui.Style) !*const ui.Style {
    const frame = try arena.create(ui.Style);
    frame.* = size.with(.{
        .direction = .column,
        .background = color_convert.solid(list_look.PANEL),
        .border_width = .all(1),
        .border_color = color_convert.solid(list_look.BORDER),
        .radius = .{ .fixed = scaled(scale, @intCast(list_look.CORNER_RADIUS)) },
        .opacity = @as(f32, @floatFromInt(opacity)) / 255.0,
        .overflow = .hidden,
    });
    return frame;
}

/// One of the shared glyphs `size` pixels square, as the panels draw it.
pub fn panelGlyph(context: *ui.Frame, key: ui.Key, glyph: glyphs.Glyph, size: i32, argb: u32) !void {
    const arena = context.arena();
    const side: f32 = @floatFromInt(size);
    const glyph_style = try arena.create(ui.Style);
    glyph_style.* = .{ .width = .fixed(side), .height = .fixed(side) };
    try context.e(Canvas{ .key = key, .commands = try glyphs.commands(arena, glyph, side, try glyphs.snapOffset(context, key), color_convert.fromArgb(argb).value), .style = glyph_style });
}

fn headerBar(context: *ui.Frame, key: ui.Key, title: []const u8, count: []const u8, scale: f32) !void {
    const arena = context.arena();
    const header_style = try arena.create(ui.Style);
    header_style.* = .{
        .width = .grow(),
        .height = .fixed(scaled(scale, panel_header.HEIGHT)),
        .direction = .row,
        .@"align" = .center,
        .gap = scaled(scale, HEADER_GAP),
        .padding = .xy(scaled(scale, HEADER_PADDING_X), 0),
        .background = color_convert.solid(palette.CHROME),
        .border_width = .edges(0, 0, 1, 0),
        .border_color = color_convert.solid(list_look.DIVIDER),
    };
    const row = Rect{ .key = key, .style = header_style };
    _ = try row.open(context);
    const glyph_style = try arena.create(ui.Style);
    glyph_style.* = .{ .width = .fixed(glyphs.ICON_SIZE), .height = .fixed(glyphs.ICON_SIZE) };
    try context.e(Canvas{
        .key = key.indexed(1),
        .commands = try glyphs.commands(arena, .chevron_down, glyphs.ICON_SIZE, try glyphs.snapOffset(context, key.indexed(1)), color_convert.fromArgb(palette.MUTED).value),
        .style = glyph_style,
    });
    try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = title, .style = try widgets.textStyle(arena, palette.TEXT, scaled(scale, palette.FONT_SIZE), .{ .is_bold = true }) });
    if (count.len > 0) try context.e(Text{ .selectable = false, .key = key.indexed(3), .content = count, .style = try widgets.textStyle(arena, palette.MUTED, scaled(scale, palette.SMALL_FONT_SIZE), .{}) });
    try row.close(context);
}

/// "Preview" and the scale on the left, Show Off at the right.
fn stageTools(context: *ui.Frame, key: ui.Key, scale: f32, shows_off: *bool) !void {
    const arena = context.arena();
    const row = Rect{ .key = key, .style = &style.bench_tools };
    _ = try row.open(context);
    const percent: u32 = @intFromFloat(@round(scale * 100));
    const caption = try arena.print("{s} \u{00B7} {d}%", .{ lang.text("Preview"), percent });
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = caption, .style = &style.bench_tools_text });
    const button = Button{ .key = key.indexed(2), .style = if (shows_off.*) &style.bench_eye_on else &style.bench_eye };
    const response = try button.openResponse(context);
    const label = lang.text("Show Off");
    try context.ui().setAccessibility(response.id, .{ .role = .checkbox, .name = label, .state = .{ .checked = shows_off.* } });
    const glyph_key = key.indexed(3);
    try context.e(Canvas{
        .key = glyph_key,
        .commands = try glyphs.commands(arena, .eye, glyphs.TAB_SIZE, try glyphs.snapOffset(context, glyph_key), (if (shows_off.*) style.TEXT else style.MUTED).value),
        .style = &style.bench_eye_glyph,
    });
    try context.e(Text{ .selectable = false, .key = key.indexed(4), .content = label });
    try button.close(context);
    try row.close(context);
    if (!response.clicked) return;
    shows_off.* = !shows_off.*;
    context.requestRedraw();
}
