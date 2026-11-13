//! What the panels' previews share: the stage that shrinks a preview to fit its section, and the frame and header every panel draws; main thread only.
const std = @import("std");
const ui = @import("ui");
const list_look = @import("../../../panels/list_look.zig");
const palette = @import("../../../panels/palette.zig");
const panel_header = @import("../../../panels/panel_header.zig");
const glyphs = @import("../glyphs.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const color_convert = @import("../color_convert.zig");

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

/// The row a preview is centred in, measured so the preview can shrink to fit it; the caller closes it.
pub const Stage = struct {
    rect: Rect,
    /// 0 until the stage has been laid out once.
    available_width: f32,

    pub fn open(context: *ui.Frame, key: ui.Key) !Stage {
        const ui_state = context.ui();
        _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, key.hash());
        const available_width = widgets.measuredBox(ui_state, key).w();
        // Not laid out yet, so draw once more knowing the room there is.
        if (available_width == 0) context.requestRedraw();
        const rect = Rect{ .key = key, .style = &style.stage_row };
        _ = try rect.open(context);
        return .{ .rect = rect, .available_width = available_width };
    }

    /// How much a preview `panel_width` wide shrinks to fit; 1 at real size.
    pub fn scaleFor(self: Stage, panel_width: f32) f32 {
        return if (self.available_width > 0 and panel_width > self.available_width) self.available_width / panel_width else 1;
    }

    /// `shrunk_note` says so under the preview while `scale` is below 1.
    pub fn close(self: Stage, context: *ui.Frame, scale: f32, shrunk_note: []const u8) !void {
        try self.rect.close(context);
        if (scale < 1) try widgets.paragraph(context, self.rect.key.indexed(1), shrunk_note);
    }
};

/// A part of a preview clicked to edit it, outlined as the thumbnail preview's chips are: solid while the panel shows it, dashed while it's off, and accent while hovered or open; the caller closes it.
pub const Part = struct {
    button: Button,
    state: State,
    inset: [2]f32,
    is_hovered: bool,
    is_clicked: bool,

    pub const State = struct {
        /// Whether the panel draws it with the current settings.
        is_shown: bool,
        /// Its popover is open.
        is_selected: bool,
    };

    /// `base` sets the part's layout, background and padding; `inset` is that padding's left and top, where its absolute children start.
    pub fn open(context: *ui.Frame, key: ui.Key, base: ui.Style, inset: [2]f32, state: State) !Part {
        const ui_state = context.ui();
        _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, key.hash());
        const part_style = try context.arena().create(ui.Style);
        part_style.* = base.with(.{
            // A Button centres its content, which pushes a row with a growing name off its right edge.
            .justify = .start,
            .border_width = .all(1),
            .border_color = if (state.is_selected) .accent else if (state.is_shown) .{ .color = style.CHIP_OUTLINE } else .transparent,
            .radius = .{ .fixed = PART_RADIUS },
            .hover = &.{ .border_color = .accent, .state_layer = 0 },
            .active = &.{ .state_layer = 0 },
        });
        const button = Button{ .key = key, .style = part_style };
        const response = try button.openResponse(context);
        if (response.hovered) ui_state.requestCursor(.pointer);
        return .{ .button = button, .state = state, .inset = inset, .is_hovered = response.hovered, .is_clicked = response.clicked };
    }

    pub fn close(self: Part, context: *ui.Frame) !void {
        if (!self.state.is_shown and !self.is_hovered and !self.state.is_selected) {
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

/// A panel's header bar: its chevron, `title` and muted `count` in the configuration window's font, as the panels draw it.
pub fn header(context: *ui.Frame, key: ui.Key, title: []const u8, count: []const u8, scale: f32) !void {
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

/// One of the shared glyphs `size` pixels square, as the panels draw it.
pub fn panelGlyph(context: *ui.Frame, key: ui.Key, glyph: glyphs.Glyph, size: i32, argb: u32) !void {
    const arena = context.arena();
    const side: f32 = @floatFromInt(size);
    const glyph_style = try arena.create(ui.Style);
    glyph_style.* = .{ .width = .fixed(side), .height = .fixed(side) };
    try context.e(Canvas{ .key = key, .commands = try glyphs.commands(arena, glyph, side, try glyphs.snapOffset(context, key), color_convert.fromArgb(argb).value), .style = glyph_style });
}
