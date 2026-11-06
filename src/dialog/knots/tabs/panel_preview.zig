//! What the panels' previews share: the stage that shrinks a preview to fit its section, and the frame and header every panel draws; main thread only.
const std = @import("std");
const ui = @import("ui");
const list_look = @import("../../../panels/list_look.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const color_convert = @import("../color_convert.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;

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

/// A panel's header row with `content` in its muted small text, `height` real pixels tall.
pub fn header(context: *ui.Frame, key: ui.Key, content: []const u8, height: i32, scale: f32, small_size: f32) !void {
    const arena = context.arena();
    const header_style = try arena.create(ui.Style);
    header_style.* = .{
        .width = .grow(),
        .height = .fixed(scaled(scale, height)),
        .direction = .row,
        .@"align" = .center,
        .padding = .xy(scaled(scale, list_look.PADDING_X), 0),
        .border_width = .edges(0, 0, 1, 0),
        .border_color = color_convert.solid(list_look.DIVIDER),
    };
    const row = Rect{ .key = key, .style = header_style };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = content, .style = try widgets.textStyle(arena, list_look.MUTED, small_size, .{}) });
    try row.close(context);
}
