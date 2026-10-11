//! Pixel drawing for thumbnail overlays: text placement, borders and the exclusion overlay.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const types = @import("../config/types.zig");
const color_mod = @import("../util/color.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");

const TextPosition = types.TextPosition;
const BorderStyle = types.BorderStyle;

const TEXT_BUFFER_SIZE = 256;
/// Around each text run's background, in real pixels; the config dialog's preview pads the same.
pub const TEXT_PADDING_X = 5;
pub const TEXT_PADDING_Y = 2;
/// The hatch's mark/gap ratio, fixed regardless of size so its 45-degree angle stays the same.
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

pub const VerticalAlign = enum { top, middle, bottom };

const Diagonal = enum { backslash, slash };

const BorderRegion = struct {
    x_start: usize,
    y_start: usize,
    x_end: usize,
    y_end: usize,
};

pub fn horizontalAlignOf(position: TextPosition) HorizontalAlign {
    return switch (position) {
        .TopLeft, .LeftCenter, .BottomLeft => .left,
        .TopCenter, .Center, .BottomCenter => .center,
        .TopRight, .RightCenter, .BottomRight => .right,
    };
}

/// x for a line of `line_width` so it sits flush against whichever edge `alignment` anchors to, within a block of `block_width` starting at `block_x`.
pub fn alignedLineX(block_x: i32, block_width: usize, line_width: usize, alignment: HorizontalAlign) i32 {
    return switch (alignment) {
        .left => block_x,
        .center => block_x + @as(i32, @intCast((block_width -| line_width) / 2)),
        .right => block_x + @as(i32, @intCast(block_width -| line_width)),
    };
}

pub fn verticalAlignOf(position: TextPosition) VerticalAlign {
    return switch (position) {
        .TopLeft, .TopCenter, .TopRight => .top,
        .LeftCenter, .Center, .RightCenter => .middle,
        .BottomLeft, .BottomCenter, .BottomRight => .bottom,
    };
}

/// y for a line of `line_height` so it sits flush against whichever edge `alignment` anchors to, within a block of `block_height` starting at `block_y`.
pub fn alignedLineY(block_y: i32, block_height: usize, line_height: usize, alignment: VerticalAlign) i32 {
    return switch (alignment) {
        .top => block_y,
        .middle => block_y + @as(i32, @intCast((block_height -| line_height) / 2)),
        .bottom => block_y + @as(i32, @intCast(block_height -| line_height)),
    };
}

pub fn calculateTextPosition(
    position: TextPosition,
    text_width: usize,
    text_height: usize,
    overlay_width: usize,
    overlay_height: usize,
    offset_x: i32,
    offset_y: i32,
) TextOrigin {
    var x = alignedLineX(0, overlay_width, text_width, horizontalAlignOf(position));
    var y = alignedLineY(0, overlay_height, text_height, verticalAlignOf(position));

    x += offset_x;
    y += offset_y;

    x = @max(0, @min(x, @as(i32, @intCast(overlay_width)) - @as(i32, @intCast(text_width))));
    y = @max(0, @min(y, @as(i32, @intCast(overlay_height)) - @as(i32, @intCast(text_height))));

    return .{ .x = x, .y = y };
}

/// Fills a text run's background rect, clipped to the buffer.
pub fn fillTextBackground(pixels: [*]u32, width: usize, height: usize, x: i32, y: i32, text_width: usize, text_height: usize, color: u32) void {
    const start_x: usize = @intCast(@max(0, x));
    const start_y: usize = @intCast(@max(0, y));
    const end_y = @min(start_y + text_height, height);
    const end_x = @min(start_x + text_width, width);
    if (end_x <= start_x or end_y <= start_y) return;
    // Premultiplied, or fixTextAlphaRect would take a transparent non-black background for unfixed GDI text and make it opaque.
    pixel_buffer.fillRect(pixels, width, height, start_x, start_y, end_x - start_x, end_y - start_y, color_mod.premultiplyAlpha(color));
}

/// Draws the exclusion overlay onto an already-cleared buffer.
pub fn drawExclusionOverlay(pixels: [*]u32, width: usize, height: usize, color: u32, style: types.ExclusionOverlayStyle) void {
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
                const fy: f32 = @floatFromInt(y);
                for (0..width) |x| {
                    const fx: f32 = @floatFromInt(x);
                    const dx = fx - center_x;
                    const dy = fy - center_y;
                    const dist = @sqrt(dx * dx + dy * dy);
                    const on_ring = @abs(dist - radius) <= thickness / 2;
                    // Slash direction runs lower-left to upper-right (dx + dy = 0 through centre).
                    const on_slash = @abs(dx + dy) / sqrt2 <= thickness / 2 and dist <= slash_reach;
                    if (on_ring or on_slash) pixels[row_start + x] = blended;
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
            drawDiagonalBand(pixels, width, height, blended, .backslash);
            drawDiagonalBand(pixels, width, height, blended, .slash);
        },
        .DiagonalSlash => drawDiagonalBand(pixels, width, height, blended, .slash),
    }
}

pub fn drawBorder(pixels: [*]u32, width: usize, height: usize, border_width: usize, color: u32, style: BorderStyle) void {
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
        .Dashed => drawLengthwisePattern(pixels, width, height, border_width, color, DASH_LENGTH, DASH_GAP),
        .Dotted => {
            // Square-ish dots roughly one border-width wide, spaced two border-widths apart, distinct from Dashed's fixed 8px marks.
            const dot_length = if (border_width == 0) 0 else @max(1, border_width);
            drawLengthwisePattern(pixels, width, height, border_width, color, dot_length, dot_length * 2);
        },
        .Double => {
            // Mirrors the CSS "double" border look; at very thin widths the lines abut with no visible gap and just render as solid.
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
            // Dash, gap, dot, gap: a four-phase pattern, so it needs its own test rather than drawLengthwisePattern's single mark/gap pair.
            const dot_length: usize = if (border_width == 0) 0 else @max(1, border_width);
            const pattern_length = DASH_LENGTH + DASH_GAP + dot_length + DASH_GAP;
            const dot_start = DASH_LENGTH + DASH_GAP;

            for (borderRegions(width, height, border_width)) |region| {
                const is_horizontal = (region.x_end - region.x_start) == width;

                for (region.y_start..region.y_end) |y| {
                    const row_start = y * width;
                    for (region.x_start..region.x_end) |x| {
                        const distance = if (is_horizontal) x else y;
                        const phase = distance % pattern_length;
                        const in_dash = phase < DASH_LENGTH;
                        const in_dot = phase >= dot_start and phase < dot_start + dot_length;

                        if (in_dash or in_dot) {
                            pixels[row_start + x] = color;
                        }
                    }
                }
            }
        },
        .CornerBrackets => {
            // Arm length scales with border_width but is capped at a third of the shorter dimension so brackets from adjacent corners never meet.
            const arm_length = @min(border_width * 4, @min(width, height) / 3);

            pixel_buffer.fillRect(pixels, width, height, 0, 0, arm_length, border_width, color);
            pixel_buffer.fillRect(pixels, width, height, 0, 0, border_width, arm_length, color);
            pixel_buffer.fillRect(pixels, width, height, width - arm_length, 0, arm_length, border_width, color);
            pixel_buffer.fillRect(pixels, width, height, width - border_width, 0, border_width, arm_length, color);
            pixel_buffer.fillRect(pixels, width, height, 0, height - border_width, arm_length, border_width, color);
            pixel_buffer.fillRect(pixels, width, height, 0, height - arm_length, border_width, arm_length, color);
            pixel_buffer.fillRect(pixels, width, height, width - arm_length, height - border_width, arm_length, border_width, color);
            pixel_buffer.fillRect(pixels, width, height, width - border_width, height - arm_length, border_width, arm_length, color);
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

fn drawDiagonalBand(pixels: [*]u32, width: usize, height: usize, color: u32, diagonal: Diagonal) void {
    const signed_width: i32 = @intCast(width);
    const signed_height: i32 = @intCast(height);
    // Scaled with the aspect ratio.
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

/// The four border bands (top/bottom/left/right), each `border_width` thick and running the full length of its edge.
fn borderRegions(width: usize, height: usize, border_width: usize) [4]BorderRegion {
    return .{
        .{ .x_start = 0, .y_start = 0, .x_end = width, .y_end = border_width },
        .{ .x_start = 0, .y_start = height - border_width, .x_end = width, .y_end = height },
        .{ .x_start = 0, .y_start = 0, .x_end = border_width, .y_end = height },
        .{ .x_start = width - border_width, .y_start = 0, .x_end = width, .y_end = height },
    };
}

/// Marks pixels along the border's length using a repeating mark/gap pattern, where `distance` runs along the edge.
fn drawLengthwisePattern(pixels: [*]u32, width: usize, height: usize, border_width: usize, color: u32, mark_length: usize, gap_length: usize) void {
    const pattern_length = mark_length + gap_length;

    for (borderRegions(width, height, border_width)) |region| {
        const is_horizontal = (region.x_end - region.x_start) == width;

        for (region.y_start..region.y_end) |y| {
            const row_start = y * width;
            for (region.x_start..region.x_end) |x| {
                const distance = if (is_horizontal) x else y;

                if ((distance % pattern_length) < mark_length) {
                    pixels[row_start + x] = color;
                }
            }
        }
    }
}

test "calculateTextPosition centres text and clamps it inside the overlay" {
    try std.testing.expectEqual(TextOrigin{ .x = 40, .y = 20 }, calculateTextPosition(.Center, 20, 10, 100, 50, 0, 0));
    try std.testing.expectEqual(TextOrigin{ .x = 80, .y = 40 }, calculateTextPosition(.BottomRight, 20, 10, 100, 50, 30, 30));
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

test "a solid border leaves the inside untouched" {
    var pixels: [8 * 6]u32 = @splat(0);
    drawBorder(&pixels, 8, 6, 1, 0xFFFFFFFF, .Solid);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0), pixels[2 * 8 + 3]);
}
