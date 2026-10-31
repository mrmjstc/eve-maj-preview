//! Pixel drawing for thumbnail overlays: text placement, borders and the exclusion overlay.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const types = @import("../config/types.zig");
const color_mod = @import("../util/color.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");

const Canvas = pixel_buffer.Canvas;
const TextPosition = types.TextPosition;
const BorderStyle = types.BorderStyle;

const TEXT_BUFFER_SIZE = 256;
/// Around each text run's background, in real pixels; the config dialog's preview pads the same.
pub const TEXT_PADDING_X = 5;
pub const TEXT_PADDING_Y = 2;
const HATCH_PATTERN_LENGTH = 6;
const HATCH_MARK_LENGTH = 3;
const DASH_LENGTH = 8;
const DASH_GAP = 4;

pub const TextDimensions = struct {
    width: usize,
    height: usize,
};

pub const TextOrigin = struct {
    x: i32,
    y: i32,
};

pub const HorizontalAlign = enum { left, center, right };

const VerticalAlign = enum { top, middle, bottom };

const Diagonal = enum { backslash, slash };

const BorderRegion = struct {
    x_start: usize,
    y_start: usize,
    x_end: usize,
    y_end: usize,
};

/// A mark and a gap, repeated along each edge, then optionally a second mark and gap in the same repeat.
const LengthwisePattern = struct {
    mark: usize,
    gap: usize,
    second_mark: usize = 0,
    second_gap: usize = 0,

    fn length(self: LengthwisePattern) usize {
        return self.mark + self.gap + self.second_mark + self.second_gap;
    }

    fn marks(self: LengthwisePattern, distance: usize) bool {
        const phase = distance % self.length();
        const second_start = self.mark + self.gap;
        return phase < self.mark or (phase >= second_start and phase < second_start + self.second_mark);
    }
};

pub fn horizontalAlignOf(position: TextPosition) HorizontalAlign {
    return switch (position) {
        .TopLeft, .LeftCenter, .BottomLeft => .left,
        .TopCenter, .Center, .BottomCenter => .center,
        .TopRight, .RightCenter, .BottomRight => .right,
    };
}

/// Puts a `line_width` line against the block edge `alignment` names.
pub fn alignedLineX(block_x: i32, block_width: usize, line_width: usize, alignment: HorizontalAlign) i32 {
    return switch (alignment) {
        .left => block_x,
        .center => block_x + @as(i32, @intCast((block_width -| line_width) / 2)),
        .right => block_x + @as(i32, @intCast(block_width -| line_width)),
    };
}

/// Where `text` sits in an `overlay`-sized box at `position`, moved by the offset and kept inside the box.
pub fn calculateTextPosition(position: TextPosition, text: TextDimensions, overlay: TextDimensions, offset_x: i32, offset_y: i32) TextOrigin {
    var x = alignedLineX(0, overlay.width, text.width, horizontalAlignOf(position));
    var y = alignedLineY(0, overlay.height, text.height, verticalAlignOf(position));

    x += offset_x;
    y += offset_y;

    x = @max(0, @min(x, @as(i32, @intCast(overlay.width)) - @as(i32, @intCast(text.width))));
    y = @max(0, @min(y, @as(i32, @intCast(overlay.height)) - @as(i32, @intCast(text.height))));

    return .{ .x = x, .y = y };
}

/// Clipped to the buffer.
pub fn fillTextBackground(canvas: Canvas, x: i32, y: i32, text_width: usize, text_height: usize, color: u32) void {
    const start_x: usize = @intCast(@max(0, x));
    const start_y: usize = @intCast(@max(0, y));
    const end_y = @min(start_y + text_height, canvas.height);
    const end_x = @min(start_x + text_width, canvas.width);
    if (end_x <= start_x or end_y <= start_y) return;
    // Premultiplied, or fixTextAlphaRect would make a transparent non-black background opaque.
    pixel_buffer.fillRect(canvas, start_x, start_y, end_x - start_x, end_y - start_y, color_mod.premultiplyAlpha(color));
}

/// Onto an already-cleared buffer.
pub fn drawExclusionOverlay(canvas: Canvas, color: u32, style: types.ExclusionOverlayStyle) void {
    const pixels = canvas.pixels;
    const width = canvas.width;
    const height = canvas.height;
    const alpha = (color >> 24) & 0xFF;
    if (alpha == 0) return;
    const blended = color_mod.premultiplyAlpha(color);

    switch (style) {
        .None => {},
        .SolidTint => @memset(pixels[0 .. width * height], blended),
        .CircleSlash => {
            const center_x: f32 = @as(f32, @floatFromInt(width)) / 2;
            const center_y: f32 = @as(f32, @floatFromInt(height)) / 2;
            const radius = @min(center_x, center_y) * 0.7;
            const thickness = @max(2.0, radius * 0.18);
            // Slash extends a bit past the ring, matching the standard "no entry" glyph.
            const slash_reach = radius * 1.15;
            const sqrt2 = @sqrt(@as(f32, 2.0));
            for (0..height) |y| {
                const row_start = y * width;
                const pixel_y: f32 = @floatFromInt(y);
                for (0..width) |x| {
                    const pixel_x: f32 = @floatFromInt(x);
                    const dx = pixel_x - center_x;
                    const dy = pixel_y - center_y;
                    const distance = @sqrt(dx * dx + dy * dy);
                    const is_on_ring = @abs(distance - radius) <= thickness / 2;
                    // Lower-left to upper-right, where dx + dy = 0.
                    const is_on_slash = @abs(dx + dy) / sqrt2 <= thickness / 2 and distance <= slash_reach;
                    if (is_on_ring or is_on_slash) pixels[row_start + x] = blended;
                }
            }
        },
        .DiagonalHatch => {
            for (0..height) |y| {
                const row_start = y * width;
                for (0..width) |x| {
                    if (((x + y) % HATCH_PATTERN_LENGTH) < HATCH_MARK_LENGTH) {
                        pixels[row_start + x] = blended;
                    }
                }
            }
        },
        .Checkerboard => {
            const square_size = 8;
            for (0..height) |y| {
                const row_start = y * width;
                for (0..width) |x| {
                    if (((x / square_size) + (y / square_size)) % 2 == 0) {
                        pixels[row_start + x] = blended;
                    }
                }
            }
        },
        .X => {
            drawDiagonalBand(canvas, blended, .backslash);
            drawDiagonalBand(canvas, blended, .slash);
        },
        .DiagonalSlash => drawDiagonalBand(canvas, blended, .slash),
    }
}

pub fn drawBorder(canvas: Canvas, border_width: usize, color: u32, style: BorderStyle) void {
    const pixels = canvas.pixels;
    const width = canvas.width;
    const height = canvas.height;
    switch (style) {
        .Solid => {
            @memset(pixels[0 .. border_width * width], color);
            @memset(pixels[(height - border_width) * width .. height * width], color);

            // Corners are already covered by the bands.
            for (border_width..(height - border_width)) |y| {
                const row = y * width;
                @memset(pixels[row .. row + border_width], color);
                @memset(pixels[row + width - border_width .. row + width], color);
            }
        },
        .Dashed => drawLengthwisePattern(canvas, border_width, color, .{ .mark = DASH_LENGTH, .gap = DASH_GAP }),
        .Dotted => {
            const dot_length = if (border_width == 0) 0 else @max(1, border_width);
            drawLengthwisePattern(canvas, border_width, color, .{ .mark = dot_length, .gap = dot_length * 2 });
        },
        .Double => {
            // CSS-style double border; too thin for a gap, it renders solid.
            const line_width = if (border_width == 0) 0 else @max(1, border_width / 3);
            const inner_start = border_width - line_width;

            @memset(pixels[0 .. line_width * width], color);
            @memset(pixels[inner_start * width .. border_width * width], color);

            @memset(pixels[(height - line_width) * width .. height * width], color);
            @memset(pixels[(height - border_width) * width .. (height - border_width + line_width) * width], color);

            // Corners are already covered by the bands.
            for (border_width..(height - border_width)) |y| {
                const row = y * width;
                @memset(pixels[row .. row + line_width], color);
                @memset(pixels[row + inner_start .. row + border_width], color);
                @memset(pixels[row + width - border_width .. row + width - border_width + line_width], color);
                @memset(pixels[row + width - line_width .. row + width], color);
            }
        },
        .DiagonalHatch => {
            for (borderRegions(width, height, border_width)) |region| {
                for (region.y_start..region.y_end) |y| {
                    const row_start = y * width;
                    for (region.x_start..region.x_end) |x| {
                        if (((x + y) % HATCH_PATTERN_LENGTH) < HATCH_MARK_LENGTH) {
                            pixels[row_start + x] = color;
                        }
                    }
                }
            }
        },
        .DashDot => {
            const dot_length: usize = if (border_width == 0) 0 else @max(1, border_width);
            drawLengthwisePattern(canvas, border_width, color, .{ .mark = DASH_LENGTH, .gap = DASH_GAP, .second_mark = dot_length, .second_gap = DASH_GAP });
        },
        .CornerBrackets => {
            // Capped at a third of the shorter side so adjacent corners' brackets never meet.
            const arm_length = @min(border_width * 4, @min(width, height) / 3);

            pixel_buffer.fillRect(canvas, 0, 0, arm_length, border_width, color);
            pixel_buffer.fillRect(canvas, 0, 0, border_width, arm_length, color);
            pixel_buffer.fillRect(canvas, width - arm_length, 0, arm_length, border_width, color);
            pixel_buffer.fillRect(canvas, width - border_width, 0, border_width, arm_length, color);
            pixel_buffer.fillRect(canvas, 0, height - border_width, arm_length, border_width, color);
            pixel_buffer.fillRect(canvas, 0, height - arm_length, border_width, arm_length, color);
            pixel_buffer.fillRect(canvas, width - arm_length, height - border_width, arm_length, border_width, color);
            pixel_buffer.fillRect(canvas, width - border_width, height - arm_length, border_width, arm_length, color);
        },
    }
}

/// With padding, in the font already selected into `dc`.
pub fn measureText(dc: win32.HDC, text: []const u8) TextDimensions {
    const text_size = gdi_overlay.measureTextSize(TEXT_BUFFER_SIZE, dc, text);
    return .{
        .width = @intCast(@max(0, text_size.cx) + (TEXT_PADDING_X * 2)),
        .height = @intCast(@max(0, text_size.cy) + (TEXT_PADDING_Y * 2)),
    };
}

/// In the font already selected into `dc`, inside measureText's padding.
pub fn renderText(dc: win32.HDC, text: []const u8, x: i32, y: i32, color: u32) void {
    gdi_overlay.drawText(TEXT_BUFFER_SIZE, dc, x + TEXT_PADDING_X, y + TEXT_PADDING_Y, text, color);
}

/// Like renderText, with the first `lead_length` bytes in `lead_color`.
pub fn renderTextWithLead(dc: win32.HDC, text: []const u8, lead_length: usize, lead_color: u32, x: i32, y: i32, color: u32) void {
    renderText(dc, text[0..lead_length], x, y, lead_color);
    const lead_width = gdi_overlay.measureTextSize(TEXT_BUFFER_SIZE, dc, text[0..lead_length]).cx;
    renderText(dc, text[lead_length..], x + lead_width, y, color);
}

fn verticalAlignOf(position: TextPosition) VerticalAlign {
    return switch (position) {
        .TopLeft, .TopCenter, .TopRight => .top,
        .LeftCenter, .Center, .RightCenter => .middle,
        .BottomLeft, .BottomCenter, .BottomRight => .bottom,
    };
}

/// Puts a `line_height` line against the block edge `alignment` names.
fn alignedLineY(block_y: i32, block_height: usize, line_height: usize, alignment: VerticalAlign) i32 {
    return switch (alignment) {
        .top => block_y,
        .middle => block_y + @as(i32, @intCast((block_height -| line_height) / 2)),
        .bottom => block_y + @as(i32, @intCast(block_height -| line_height)),
    };
}

fn drawDiagonalBand(canvas: Canvas, color: u32, diagonal: Diagonal) void {
    const pixels = canvas.pixels;
    const width = canvas.width;
    const height = canvas.height;
    const signed_width: i32 = @intCast(width);
    const signed_height: i32 = @intCast(height);
    const half_width: i32 = @max(1, @divTrunc(5 * signed_width, signed_height));
    for (0..height) |y| {
        const signed_y: i32 = @intCast(y);
        const row = pixels[y * width .. y * width + width];
        const center_x = switch (diagonal) {
            .backslash => @divTrunc(signed_y * signed_width, signed_height),
            .slash => @divTrunc((signed_height - signed_y) * signed_width, signed_height),
        };
        const start: usize = @intCast(@max(0, center_x - half_width));
        const end: usize = @intCast(@max(0, @min(signed_width, center_x + half_width + 1)));
        if (start < end) @memset(row[start..end], color);
    }
}

/// Top, bottom, left, right; each runs its edge's full length.
fn borderRegions(width: usize, height: usize, border_width: usize) [4]BorderRegion {
    return .{
        .{ .x_start = 0, .y_start = 0, .x_end = width, .y_end = border_width },
        .{ .x_start = 0, .y_start = height - border_width, .x_end = width, .y_end = height },
        .{ .x_start = 0, .y_start = 0, .x_end = border_width, .y_end = height },
        .{ .x_start = width - border_width, .y_start = 0, .x_end = width, .y_end = height },
    };
}

fn drawLengthwisePattern(canvas: Canvas, border_width: usize, color: u32, pattern: LengthwisePattern) void {
    const pixels = canvas.pixels;
    const width = canvas.width;
    const height = canvas.height;

    for (borderRegions(width, height, border_width)) |region| {
        const is_horizontal = (region.x_end - region.x_start) == width;

        for (region.y_start..region.y_end) |y| {
            const row_start = y * width;
            for (region.x_start..region.x_end) |x| {
                if (pattern.marks(if (is_horizontal) x else y)) pixels[row_start + x] = color;
            }
        }
    }
}

test "calculateTextPosition centres text and clamps it inside the overlay" {
    const text: TextDimensions = .{ .width = 20, .height = 10 };
    const overlay: TextDimensions = .{ .width = 100, .height = 50 };
    try std.testing.expectEqual(TextOrigin{ .x = 40, .y = 20 }, calculateTextPosition(.Center, text, overlay, 0, 0));
    try std.testing.expectEqual(TextOrigin{ .x = 80, .y = 40 }, calculateTextPosition(.BottomRight, text, overlay, 30, 30));
}

test "alignedLineX keeps a line wider than its block at the block's start" {
    try std.testing.expectEqual(@as(i32, 7), alignedLineX(7, 10, 30, .center));
    try std.testing.expectEqual(@as(i32, 7), alignedLineX(7, 10, 30, .right));
}

test "borderRegions covers each edge at the border's width" {
    const regions = borderRegions(100, 50, 3);
    try std.testing.expectEqual(@as(usize, 3), regions[0].y_end);
    try std.testing.expectEqual(@as(usize, 47), regions[1].y_start);
    try std.testing.expectEqual(@as(usize, 3), regions[2].x_end);
    try std.testing.expectEqual(@as(usize, 97), regions[3].x_start);
}

test "a dash-dot border repeats a dash, a gap, a dot and a gap" {
    var pixels: [40 * 6]u32 = @splat(0);
    drawBorder(.{ .pixels = &pixels, .width = 40, .height = 6 }, 1, 0xFFFFFFFF, .DashDot);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[DASH_LENGTH - 1]);
    try std.testing.expectEqual(@as(u32, 0), pixels[DASH_LENGTH]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[DASH_LENGTH + DASH_GAP]);
    try std.testing.expectEqual(@as(u32, 0), pixels[DASH_LENGTH + DASH_GAP + 1]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[DASH_LENGTH + DASH_GAP + 1 + DASH_GAP]);
}

test "a solid border leaves the inside untouched" {
    var pixels: [8 * 6]u32 = @splat(0);
    drawBorder(.{ .pixels = &pixels, .width = 8, .height = 6 }, 1, 0xFFFFFFFF, .Solid);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0), pixels[2 * 8 + 3]);
}
