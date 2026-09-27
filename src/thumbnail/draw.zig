const win32 = @import("../platform/win32.zig");
const types = @import("../types.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");

const TextPosition = types.TextPosition;
const BorderStyle = types.BorderStyle;

const TEXT_BUFFER_SIZE = 256;
const TEXT_PADDING_X = 5;
const TEXT_PADDING_Y = 2;

pub const TextDimensions = struct {
    width: usize,
    height: usize,
};

pub const TextPos = struct {
    x: i32,
    y: i32,
};

pub const HorizontalAlign = enum { left, center, right };

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

pub const VerticalAlign = enum { top, middle, bottom };

pub fn verticalAlignOf(position: TextPosition) VerticalAlign {
    return switch (position) {
        .TopLeft, .TopCenter, .TopRight => .top,
        .LeftCenter, .Center, .RightCenter => .middle,
        .BottomLeft, .BottomCenter, .BottomRight => .bottom,
    };
}

/// y for a line of `line_height` so it sits flush against whichever edge `alignment` anchors to, within a block of `block_height` starting at `block_y`; same shape as alignedLineX for the vertical axis.
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
) TextPos {
    var x = alignedLineX(0, overlay_width, text_width, horizontalAlignOf(position));
    var y = alignedLineY(0, overlay_height, text_height, verticalAlignOf(position));

    x += offset_x;
    y += offset_y;

    x = @max(0, @min(x, @as(i32, @intCast(overlay_width)) - @as(i32, @intCast(text_width))));
    y = @max(0, @min(y, @as(i32, @intCast(overlay_height)) - @as(i32, @intCast(text_height))));

    return .{ .x = x, .y = y };
}

/// Fills a text run's background rect, clipped to the buffer.
pub fn fillTextBackground(pixels: [*]u32, width: usize, height: usize, x: i32, y: i32, text_width: usize, bar_height: usize, color: u32) void {
    const start_x: usize = @intCast(@max(0, x));
    const start_y: usize = @intCast(@max(0, y));
    const end_y = @min(start_y + bar_height, height);
    const end_x = @min(start_x + text_width, width);
    if (end_x <= start_x or end_y <= start_y) return;
    // Must be premultiplied, or fixTextAlphaRect's "alpha==0 but rgb!=0" heuristic mistakes a
    // transparent non-black background for unfixed GDI text and forces it fully opaque.
    gdi_overlay.fillRect(pixels, width, height, start_x, start_y, end_x - start_x, end_y - start_y, premultiplyAlpha(color));
}

/// Pre-multiplies color by alpha, valid only when blending onto an already-transparent buffer.
pub fn premultiplyAlpha(color: u32) u32 {
    const fg_alpha = (color >> 24) & 0xFF;
    if (fg_alpha == 255) return color;
    const r = ((color >> 16) & 0xFF) * fg_alpha / 255;
    const g = ((color >> 8) & 0xFF) * fg_alpha / 255;
    const b = (color & 0xFF) * fg_alpha / 255;
    return (fg_alpha << 24) | (r << 16) | (g << 8) | b;
}

/// Draws one diagonal band; is_diag2 selects top-right→bottom-left over top-left→bottom-right. Shared by X (both bands) and DiagonalSlash (diag2 only).
fn drawDiagonalBand(pixels: [*]u32, width: usize, height: usize, color: u32, is_diag2: bool) void {
    const iw: i32 = @intCast(width);
    const ih: i32 = @intCast(height);
    // Line half-width in pixels, scaled proportionally with the aspect ratio.
    const half: i32 = @max(1, @divTrunc(5 * iw, ih));
    for (0..height) |y| {
        const iy: i32 = @intCast(y);
        const row = pixels[y * width .. y * width + width];
        const cx = if (is_diag2) @divTrunc((ih - iy) * iw, ih) else @divTrunc(iy * iw, ih);
        const lo: usize = @intCast(@max(0, cx - half));
        const hi: usize = @intCast(@max(0, @min(iw, cx + half + 1)));
        if (lo < hi) @memset(row[lo..hi], color);
    }
}

/// Draws the exclusion overlay onto an already-cleared buffer.
pub fn drawExclusionOverlay(pixels: [*]u32, width: usize, height: usize, color: u32, style: types.ExclusionOverlayStyle) void {
    const fg_alpha = (color >> 24) & 0xFF;
    if (fg_alpha == 0) return;
    const blended = premultiplyAlpha(color);

    switch (style) {
        .None => {},
        .SolidTint => @memset(pixels[0 .. width * height], blended),
        .CircleSlash => {
            const cx: f32 = @as(f32, @floatFromInt(width)) / 2;
            const cy: f32 = @as(f32, @floatFromInt(height)) / 2;
            const radius = @min(cx, cy) * 0.7;
            const thickness = @max(2.0, radius * 0.18);
            // Slash extends a bit past the ring, matching the standard "no entry" glyph.
            const slash_reach = radius * 1.15;
            const sqrt2 = @sqrt(@as(f32, 2.0));
            for (0..height) |y| {
                const row_start = y * width;
                const fy: f32 = @floatFromInt(y);
                for (0..width) |x| {
                    const fx: f32 = @floatFromInt(x);
                    const dx = fx - cx;
                    const dy = fy - cy;
                    const dist = @sqrt(dx * dx + dy * dy);
                    const on_ring = @abs(dist - radius) <= thickness / 2;
                    // Slash direction runs lower-left to upper-right (dx + dy = 0 through centre).
                    const on_slash = @abs(dx + dy) / sqrt2 <= thickness / 2 and dist <= slash_reach;
                    if (on_ring or on_slash) pixels[row_start + x] = blended;
                }
            }
        },
        .DiagonalHatch => {
            // Same ratio as BorderStyle.DiagonalHatch, but filling the whole area.
            const pattern_length = 6;
            const mark_length = 3;
            for (0..height) |y| {
                const row_start = y * width;
                for (0..width) |x| {
                    if (((x + y) % pattern_length) < mark_length) {
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
            drawDiagonalBand(pixels, width, height, blended, false);
            drawDiagonalBand(pixels, width, height, blended, true);
        },
        .DiagonalSlash => drawDiagonalBand(pixels, width, height, blended, true),
    }
}

const BorderRegion = struct {
    x_start: usize,
    y_start: usize,
    x_end: usize,
    y_end: usize,
};

/// The four border bands (top/bottom/left/right), each `border_width` thick and running the full length of its edge. Shared by every style that walks the border pixel-by-pixel instead of memset-ing solid runs.
fn borderRegions(width: usize, height: usize, border_width: usize) [4]BorderRegion {
    return .{
        .{ .x_start = 0, .y_start = 0, .x_end = width, .y_end = border_width },
        .{ .x_start = 0, .y_start = height - border_width, .x_end = width, .y_end = height },
        .{ .x_start = 0, .y_start = 0, .x_end = border_width, .y_end = height },
        .{ .x_start = width - border_width, .y_start = 0, .x_end = width, .y_end = height },
    };
}

/// Marks pixels along the border's length using a repeating mark/gap pattern, where `pos` runs along the edge; shared by Dashed and Dotted, which differ only in the mark/gap lengths.
fn drawLengthwisePattern(pixels: [*]u32, width: usize, height: usize, border_width: usize, color: u32, mark_length: usize, gap_length: usize) void {
    const pattern_length = mark_length + gap_length;

    for (borderRegions(width, height, border_width)) |region| {
        const is_horizontal = (region.x_end - region.x_start) == width;

        for (region.y_start..region.y_end) |y| {
            const row_start = y * width;
            for (region.x_start..region.x_end) |x| {
                const pos = if (is_horizontal) x else y;

                if ((pos % pattern_length) < mark_length) {
                    pixels[row_start + x] = color;
                }
            }
        }
    }
}

pub fn drawBorder(pixels: [*]u32, width: usize, height: usize, border_width: usize, color: u32, style: BorderStyle) void {
    switch (style) {
        .Solid => {
            // Top and bottom bands — each is a contiguous run of (border_width * width) pixels.
            @memset(pixels[0 .. border_width * width], color);
            @memset(pixels[(height - border_width) * width .. height * width], color);

            // Left and right strips for the middle rows (corners already covered above).
            for (border_width..(height - border_width)) |y| {
                const row = y * width;
                @memset(pixels[row .. row + border_width], color);
                @memset(pixels[row + width - border_width .. row + width], color);
            }
        },
        .Dashed => drawLengthwisePattern(pixels, width, height, border_width, color, 8, 4),
        .Dotted => {
            // Square-ish dots roughly one border-width wide, spaced two border-widths apart, distinct from Dashed's fixed 8px marks.
            const dot_length = if (border_width == 0) 0 else @max(1, border_width);
            drawLengthwisePattern(pixels, width, height, border_width, color, dot_length, dot_length * 2);
        },
        .Double => {
            // Mirrors the CSS "double" border look; at very thin widths the lines abut with no visible gap and just render as solid.
            const line_width = if (border_width == 0) 0 else @max(1, border_width / 3);
            const inner_start = border_width - line_width;

            // Top band: outer line at the edge, inner line just before the band ends.
            @memset(pixels[0 .. line_width * width], color);
            @memset(pixels[inner_start * width .. border_width * width], color);

            // Bottom band: mirrored from the far edge.
            @memset(pixels[(height - line_width) * width .. height * width], color);
            @memset(pixels[(height - border_width) * width .. (height - border_width + line_width) * width], color);

            // Left/right double lines for the middle rows (corners already covered above).
            for (border_width..(height - border_width)) |y| {
                const row = y * width;
                @memset(pixels[row .. row + line_width], color);
                @memset(pixels[row + inner_start .. row + border_width], color);
                @memset(pixels[row + width - border_width .. row + width - border_width + line_width], color);
                @memset(pixels[row + width - line_width .. row + width], color);
            }
        },
        .DiagonalHatch => {
            // Fixed mark/gap ratio regardless of border_width so the 45-degree hatch angle stays consistent.
            const pattern_length = 6;
            const mark_length = 3;

            for (borderRegions(width, height, border_width)) |region| {
                for (region.y_start..region.y_end) |y| {
                    const row_start = y * width;
                    for (region.x_start..region.x_end) |x| {
                        if (((x + y) % pattern_length) < mark_length) {
                            pixels[row_start + x] = color;
                        }
                    }
                }
            }
        },
        .DashDot => {
            // Dash, gap, dot, gap: a four-phase pattern, so it needs its own test rather than drawLengthwisePattern's single mark/gap pair.
            const dash_length: usize = 8;
            const gap_length: usize = 4;
            const dot_length: usize = if (border_width == 0) 0 else @max(1, border_width);
            const pattern_length = dash_length + gap_length + dot_length + gap_length;
            const dot_start = dash_length + gap_length;

            for (borderRegions(width, height, border_width)) |region| {
                const is_horizontal = (region.x_end - region.x_start) == width;

                for (region.y_start..region.y_end) |y| {
                    const row_start = y * width;
                    for (region.x_start..region.x_end) |x| {
                        const pos = if (is_horizontal) x else y;
                        const phase = pos % pattern_length;
                        const in_dash = phase < dash_length;
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

            // Top-left
            gdi_overlay.fillRect(pixels, width, height, 0, 0, arm_length, border_width, color);
            gdi_overlay.fillRect(pixels, width, height, 0, 0, border_width, arm_length, color);
            // Top-right
            gdi_overlay.fillRect(pixels, width, height, width - arm_length, 0, arm_length, border_width, color);
            gdi_overlay.fillRect(pixels, width, height, width - border_width, 0, border_width, arm_length, color);
            // Bottom-left
            gdi_overlay.fillRect(pixels, width, height, 0, height - border_width, arm_length, border_width, color);
            gdi_overlay.fillRect(pixels, width, height, 0, height - arm_length, border_width, arm_length, color);
            // Bottom-right
            gdi_overlay.fillRect(pixels, width, height, width - arm_length, height - border_width, arm_length, border_width, color);
            gdi_overlay.fillRect(pixels, width, height, width - border_width, height - arm_length, border_width, arm_length, color);
        },
    }
}

/// Measures text dimensions without rendering; the correct font must already be selected into `dc` by the caller.
pub fn measureText(dc: win32.HDC, text: []const u8) TextDimensions {
    const text_size = gdi_overlay.measureTextSize(TEXT_BUFFER_SIZE, dc, text);
    return .{
        .width = @intCast(@max(0, text_size.cx) + (TEXT_PADDING_X * 2)),
        .height = @intCast(@max(0, text_size.cy) + (TEXT_PADDING_Y * 2)),
    };
}

/// Renders text onto the device context at the specified position; the correct font must already be selected into `dc` by the caller.
pub fn renderText(dc: win32.HDC, text: []const u8, x: i32, y: i32, color: u32) void {
    gdi_overlay.drawText(TEXT_BUFFER_SIZE, dc, x + TEXT_PADDING_X, y + TEXT_PADDING_Y, text, color);
}
