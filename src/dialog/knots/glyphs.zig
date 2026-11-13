//! The window's drawn icons: the panels' glyph set, laid out as canvas pixels, since Geist lacks most of these symbols and knots draws lines without antialiasing.
const std = @import("std");
const ui = @import("ui");
const panel_glyphs = @import("../../panels/glyphs.zig");

const DrawCmd = ui.component.Canvas.DrawCmd;
/// The same set the panels and map draw, so an icon looks alike everywhere.
pub const Glyph = panel_glyphs.Glyph;

/// A sidebar glyph's box.
pub const TAB_SIZE = 14;
pub const ICON_SIZE = 16;
/// The sizes the glyphs are built at; a box gets the largest that fits it.
const SIZES = [_]usize{ 10, 12, 14, 16 };

/// The glyph centred in a `box`-sized square, moved onto whole device pixels by `snap` (see snapOffset); `color`'s alpha is scaled by each pixel's coverage.
pub fn commands(arena: std.mem.Allocator, glyph: Glyph, box: f32, snap: [2]f32, color: [4]f32) ![]const DrawCmd {
    inline for (0..SIZES.len) |position| {
        const size = SIZES[SIZES.len - 1 - position];
        if (box >= @as(f32, @floatFromInt(size)) or position == SIZES.len - 1) return maskCommands(arena, panel_glyphs.mask(glyph, size), size, box, snap, color);
    }
    unreachable;
}

/// The shift that lands a canvas on whole device pixels, from last frame's layout.
pub fn snapOffset(context: *ui.Frame, key: ui.Key) ![2]f32 {
    const ui_state = context.ui();
    const measured = try ui_state.state.getOrCreate(.measured, ui_state.allocator, key.hash());
    const scale = ui_state.content_scale;
    const x = measured.box.x();
    const y = measured.box.y();
    return .{ @round(x * scale) / scale - x, @round(y * scale) / scale - y };
}

/// One square per covered pixel of the `size`-square `coverage`, centred in `box`.
fn maskCommands(arena: std.mem.Allocator, coverage: []const u8, size: usize, box: f32, snap: [2]f32, color: [4]f32) ![]const DrawCmd {
    const side: f32 = @floatFromInt(size);
    const origin = [2]f32{ @floor((box - side) / 2) + snap[0], @floor((box - side) / 2) + snap[1] };
    var list: std.ArrayList(DrawCmd) = .empty;
    for (coverage, 0..) |pixel, index| {
        if (pixel == 0) continue;
        var pixel_color = color;
        pixel_color[3] *= @as(f32, @floatFromInt(pixel)) / 255;
        try list.append(arena, .{ .fill_rect = .{
            .x = origin[0] + @as(f32, @floatFromInt(index % size)),
            .y = origin[1] + @as(f32, @floatFromInt(index / size)),
            .w = 1,
            .h = 1,
            .color = pixel_color,
        } });
    }
    return list.items;
}
