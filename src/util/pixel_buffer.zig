//! Filling, outlining and alpha-fixing rects in a raw 0xAARRGGBB pixel buffer; no I/O.
const std = @import("std");

/// A rect's part inside a pixel buffer, and how thick its outline can be.
const ClippedRect = struct { left: usize, top: usize, right: usize, bottom: usize, thickness: usize };

/// GDI text rendering leaves the alpha byte at 0; sets alpha=255 on every pixel with non-zero RGB still at alpha 0 within the given rect, without touching alpha other drawing code already set.
pub fn fixTextAlphaRect(pixels: [*]u32, width: usize, height: usize, x: i32, y: i32, rect_width: usize, rect_height: usize) void {
    const start_x: usize = @intCast(@max(0, x));
    const start_y: usize = @intCast(@max(0, y));
    const end_x = @min(start_x + rect_width, width);
    const end_y = @min(start_y + rect_height, height);
    if (end_x <= start_x or end_y <= start_y) return;

    for (start_y..end_y) |pixel_y| {
        const row = pixels[pixel_y * width + start_x .. pixel_y * width + end_x];
        for (row) |*pixel| {
            const value = pixel.*;
            if ((value >> 24) == 0 and (value & 0x00FF_FFFF) != 0) {
                pixel.* = value | 0xFF00_0000;
            }
        }
    }
}

/// Same as fixTextAlphaRect but over the whole buffer.
pub fn fixTextAlpha(pixels: [*]u32, width: usize, height: usize) void {
    fixTextAlphaRect(pixels, width, height, 0, 0, width, height);
}

/// No-ops if the rect would overrun the buffer's row width or its height.
pub fn fillRect(pixels: [*]u32, stride: usize, height: usize, x: usize, y: usize, rect_width: usize, rect_height: usize, argb: u32) void {
    const end_y = y + rect_height;
    const end_x = x + rect_width;
    if (end_x > stride or end_y > height) return;
    for (y..end_y) |pixel_y| {
        @memset(pixels[pixel_y * stride + x .. pixel_y * stride + end_x], argb);
    }
}

/// Corners are cut with per-row insets (no anti-aliasing), which is fine at the small radii UI buttons use.
pub fn fillRoundedRect(pixels: [*]u32, stride: usize, height: usize, x: usize, y: usize, rect_width: usize, rect_height: usize, radius: usize, argb: u32) void {
    const corner_radius = @min(radius, @min(rect_width, rect_height) / 2);
    const radius_f: f32 = @floatFromInt(corner_radius);
    for (0..rect_height) |row| {
        const from_edge = @min(row, rect_height - 1 - row);
        var inset: usize = 0;
        if (from_edge < corner_radius) {
            const dy = radius_f - @as(f32, @floatFromInt(from_edge)) - 0.5;
            inset = @intFromFloat(@round(radius_f - @sqrt(radius_f * radius_f - dy * dy)));
        }
        fillRect(pixels, stride, height, x + inset, y + row, rect_width - 2 * inset, 1, argb);
    }
}

/// Draws a `thickness`-px outline of a rect placed anywhere inside a `buffer_width`x`buffer_height` pixel buffer, clamped to the buffer bounds.
pub fn drawRectOutline(pixels: [*]u32, buffer_width: usize, buffer_height: usize, x: i32, y: i32, rect_width: usize, rect_height: usize, thickness: usize, color: u32) void {
    const clipped = clipToBuffer(buffer_width, buffer_height, x, y, rect_width, rect_height, thickness) orelse return;
    const line = clipped.thickness;
    fillRect(pixels, buffer_width, buffer_height, clipped.left, clipped.top, clipped.right - clipped.left, line, color);
    fillRect(pixels, buffer_width, buffer_height, clipped.left, clipped.bottom - line, clipped.right - clipped.left, line, color);
    fillRect(pixels, buffer_width, buffer_height, clipped.left, clipped.top, line, clipped.bottom - clipped.top, color);
    fillRect(pixels, buffer_width, buffer_height, clipped.right - line, clipped.top, line, clipped.bottom - clipped.top, color);
}

/// Like drawRectOutline, in `dash`-px dashes with gaps as long, each side starting from its top or left corner.
pub fn drawDashedRectOutline(pixels: [*]u32, buffer_width: usize, buffer_height: usize, x: i32, y: i32, rect_width: usize, rect_height: usize, thickness: usize, dash: usize, color: u32) void {
    if (dash == 0) return;
    const clipped = clipToBuffer(buffer_width, buffer_height, x, y, rect_width, rect_height, thickness) orelse return;
    const line = clipped.thickness;
    var pixel_x = clipped.left;
    while (pixel_x < clipped.right) : (pixel_x += 2 * dash) {
        const run = @min(dash, clipped.right - pixel_x);
        fillRect(pixels, buffer_width, buffer_height, pixel_x, clipped.top, run, line, color);
        fillRect(pixels, buffer_width, buffer_height, pixel_x, clipped.bottom - line, run, line, color);
    }
    var pixel_y = clipped.top;
    while (pixel_y < clipped.bottom) : (pixel_y += 2 * dash) {
        const run = @min(dash, clipped.bottom - pixel_y);
        fillRect(pixels, buffer_width, buffer_height, clipped.left, pixel_y, line, run, color);
        fillRect(pixels, buffer_width, buffer_height, clipped.right - line, pixel_y, line, run, color);
    }
}

/// A 1px border round the whole buffer with `radius` rounded corners; outside them the pixels are cleared so the desktop shows through.
pub fn drawRoundedFrame(pixels: [*]u32, width: usize, height: usize, radius: usize, argb: u32) void {
    fillRect(pixels, width, height, 0, 0, width, 1, argb);
    fillRect(pixels, width, height, 0, height - 1, width, 1, argb);
    fillRect(pixels, width, height, 0, 0, 1, height, argb);
    fillRect(pixels, width, height, width - 1, 0, 1, height, argb);
    if (width < 2 * radius or height < 2 * radius) return;

    const radius_f: f32 = @floatFromInt(radius);
    for (0..radius) |dy| {
        for (0..radius) |dx| {
            // From the corner arc's centre to this pixel's centre.
            const offset_x = radius_f - @as(f32, @floatFromInt(dx)) - 0.5;
            const offset_y = radius_f - @as(f32, @floatFromInt(dy)) - 0.5;
            const distance = @sqrt(offset_x * offset_x + offset_y * offset_y);
            const pixel: u32 = if (distance > radius_f) 0 else if (distance > radius_f - 1) argb else continue;
            pixels[dy * width + dx] = pixel;
            pixels[dy * width + width - 1 - dx] = pixel;
            pixels[(height - 1 - dy) * width + dx] = pixel;
            pixels[(height - 1 - dy) * width + width - 1 - dx] = pixel;
        }
    }
}

/// Null when nothing of the rect is inside the buffer.
fn clipToBuffer(buffer_width: usize, buffer_height: usize, x: i32, y: i32, rect_width: usize, rect_height: usize, thickness: usize) ?ClippedRect {
    const left: usize = @intCast(std.math.clamp(x, 0, @as(i32, @intCast(buffer_width))));
    const top: usize = @intCast(std.math.clamp(y, 0, @as(i32, @intCast(buffer_height))));
    const right = @min(buffer_width, left + rect_width);
    const bottom = @min(buffer_height, top + rect_height);
    if (right <= left or bottom <= top) return null;
    return .{ .left = left, .top = top, .right = right, .bottom = bottom, .thickness = @min(thickness, @min(right - left, bottom - top)) };
}

const testing = std.testing;

test "fillRect fills only its rect and skips one that would overrun" {
    var buffer: [4 * 3]u32 = @splat(0);
    fillRect(&buffer, 4, 3, 1, 1, 2, 1, 7);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0, 0, 7, 7, 0, 0, 0, 0, 0 }, &buffer);
    fillRect(&buffer, 4, 3, 3, 0, 2, 1, 9);
    try testing.expectEqual(@as(u32, 0), buffer[3]);
}

test "drawRectOutline moves a rect starting off the buffer onto its edge" {
    var buffer: [4 * 4]u32 = @splat(0);
    drawRectOutline(&buffer, 4, 4, -1, -1, 3, 3, 1, 5);
    try testing.expectEqualSlices(u32, &.{ 5, 5, 5, 0, 5, 0, 5, 0, 5, 5, 5, 0, 0, 0, 0, 0 }, &buffer);
}

test "fixTextAlphaRect makes drawn text opaque without touching blank or already-set pixels" {
    var buffer = [_]u32{ 0x00000000, 0x00123456, 0x80123456 };
    fixTextAlphaRect(&buffer, 3, 1, 0, 0, 3, 1);
    try testing.expectEqualSlices(u32, &.{ 0x00000000, 0xFF123456, 0x80123456 }, &buffer);
}

test "drawRoundedFrame borders the buffer and clears outside its corners" {
    var buffer: [8 * 8]u32 = @splat(0xFFFFFFFF);
    drawRoundedFrame(&buffer, 8, 8, 3, 0xFF000000);
    try testing.expectEqual(@as(u32, 0), buffer[0]);
    try testing.expectEqual(@as(u32, 0xFF000000), buffer[4]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), buffer[4 * 8 + 4]);
}
