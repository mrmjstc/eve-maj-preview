//! The segmented control the panels share, after the dialog's: a bordered bar of buttons, the picked one filled with the accent; no I/O.
const std = @import("std");
const palette = @import("palette.zig");
const popup_look = @import("popup_look.zig");
const box = @import("../util/box.zig");
const color = @import("../util/color.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");

const Box = box.Box;

/// From the bar's outer edge to its buttons, its border included.
pub const BAR_INSET: i32 = 2;
/// Between two buttons.
pub const GAP: i32 = 2;
/// The bar's radius less its inset, so the corners nest.
pub const RADIUS: usize = palette.RADIUS - BAR_INSET;
/// Either side of a button's label.
const PADDING_X: i32 = 10;
pub const BAR_FILL: u32 = palette.SURFACE;
pub const BAR_BORDER: u32 = palette.BORDER_STRONG;
/// Behind a hovered button; SURFACE_ALT sits too close to the bar to show.
pub const HOVER: u32 = palette.BORDER;
/// A button's label that's neither picked nor hovered.
pub const TEXT: u32 = palette.TEXT_SECONDARY;

/// The picked button's label is in this face at palette.FONT_SIZE, as the map draws it; the rest keep the panel's own font.
pub const PICKED_FACE = palette.SEMIBOLD_FACE;

/// How a button shows: plain, under the cursor, or the one picked.
pub const State = enum { idle, hovered, picked };

/// A bar round buttons `widths` wide, `gap` apart, with `divider_room` spare for a divider between two of them.
pub fn barWidth(widths: []const i32, gap: i32, divider_room: i32) i32 {
    var total: i32 = 2 * BAR_INSET + divider_room;
    for (widths) |width| total += width;
    if (widths.len > 1) total += gap * @as(i32, @intCast(widths.len - 1));
    return total;
}

/// A button wide enough for a label `label_width` wide.
pub fn buttonWidth(label_width: i32) i32 {
    return label_width + 2 * PADDING_X;
}

/// Lays `widths` out left to right inside `bar`, leaving `divider_room` before the button at `divider_before`.
pub fn placeButtons(bar: Box, widths: []const i32, gap: i32, divider_before: ?usize, divider_room: i32, boxes: []Box) void {
    var x = bar.left + BAR_INSET;
    for (widths, boxes, 0..) |width, *button, index| {
        if (divider_before == index) x += divider_room;
        button.* = .{ .left = x, .top = bar.top + BAR_INSET, .right = x + width, .bottom = bar.bottom - BAR_INSET };
        x += width + gap;
    }
}

pub fn drawBar(canvas: pixel_buffer.Canvas, bar: Box) void {
    popup_look.drawBorderedBox(canvas, bar, palette.RADIUS, BAR_FILL, BAR_BORDER);
}

/// Behind a picked, lit or hovered button.
pub fn fillButton(canvas: pixel_buffer.Canvas, button: Box, fill: u32) void {
    if (button.right <= button.left or button.bottom <= button.top or button.left < 0 or button.top < 0) return;
    pixel_buffer.fillRoundedRect(canvas, @intCast(button.left), @intCast(button.top), @intCast(button.right - button.left), @intCast(button.bottom - button.top), RADIUS, fill);
}

/// The accent behind the picked button, the hover behind a hovered one, else nothing.
pub fn buttonFill(state: State, accent: u32) ?u32 {
    return switch (state) {
        .picked => accent,
        .hovered => HOVER,
        .idle => null,
    };
}

/// Ink that reads on the accent for the picked button, bright for a hovered one, else TEXT.
pub fn labelColor(state: State, accent: u32) u32 {
    return switch (state) {
        .picked => color.inkFor(accent),
        .hovered => palette.TEXT,
        .idle => TEXT,
    };
}

const testing = std.testing;

test "placeButtons fills barWidth exactly, divider room included" {
    const widths = [_]i32{ 30, 40, 50 };
    const width = barWidth(&widths, GAP, 5);
    const bar: Box = .{ .left = 10, .top = 0, .right = 10 + width, .bottom = 28 };
    var buttons: [widths.len]Box = undefined;
    placeButtons(bar, &widths, GAP, 2, 5, &buttons);
    try testing.expectEqual(bar.left + BAR_INSET, buttons[0].left);
    try testing.expectEqual(bar.right - BAR_INSET, buttons[2].right);
    try testing.expectEqual(buttons[0].right + GAP, buttons[1].left);
    try testing.expectEqual(buttons[1].right + GAP + 5, buttons[2].left);
}

test "only the picked button takes the accent" {
    try testing.expectEqual(@as(?u32, 0xFFD9A441), buttonFill(.picked, 0xFFD9A441));
    try testing.expectEqual(@as(?u32, HOVER), buttonFill(.hovered, 0xFFD9A441));
    try testing.expectEqual(@as(?u32, null), buttonFill(.idle, 0xFFD9A441));
}
