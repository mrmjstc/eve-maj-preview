//! Pure operations on RGBA pixel buffers; no I/O.
const std = @import("std");

/// Fades the four corners to transparent along a `radius`-pixel arc, anti-aliased; scales every channel, so it suits premultiplied blending too.
pub fn roundCorners(pixels: []u8, width: u32, height: u32, radius: u32) void {
    std.debug.assert(pixels.len == @as(usize, width) * height * 4);
    const corner = @min(radius, width / 2, height / 2);
    const corner_radius: f32 = @floatFromInt(corner);
    for (0..corner) |y| {
        for (0..corner) |x| {
            const dx = corner_radius - (@as(f32, @floatFromInt(x)) + 0.5);
            const dy = corner_radius - (@as(f32, @floatFromInt(y)) + 0.5);
            const coverage = std.math.clamp(corner_radius - @sqrt(dx * dx + dy * dy) + 0.5, 0, 1);
            if (coverage >= 1) continue;
            const right = width - 1 - x;
            const bottom = height - 1 - y;
            for ([_][2]usize{ .{ x, y }, .{ right, y }, .{ x, bottom }, .{ right, bottom } }) |point| {
                const offset = (point[1] * width + point[0]) * 4;
                for (pixels[offset..][0..4]) |*channel| {
                    channel.* = @intFromFloat(@round(@as(f32, @floatFromInt(channel.*)) * coverage));
                }
            }
        }
    }
}

fn solidPixels(comptime size: u32) [size * size * 4]u8 {
    return @splat(255);
}

fn alphaAt(pixels: []const u8, width: u32, x: usize, y: usize) u8 {
    return pixels[(y * width + x) * 4 + 3];
}

const testing = std.testing;

test "roundCorners clears every corner pixel and keeps the middle" {
    var pixels = solidPixels(8);
    roundCorners(&pixels, 8, 8, 3);
    try testing.expectEqual(@as(u8, 0), alphaAt(&pixels, 8, 0, 0));
    try testing.expectEqual(@as(u8, 0), alphaAt(&pixels, 8, 7, 0));
    try testing.expectEqual(@as(u8, 0), alphaAt(&pixels, 8, 0, 7));
    try testing.expectEqual(@as(u8, 0), alphaAt(&pixels, 8, 7, 7));
    try testing.expectEqual(@as(u8, 255), alphaAt(&pixels, 8, 4, 4));
    try testing.expectEqual(@as(u8, 255), alphaAt(&pixels, 8, 3, 0));
}

test "roundCorners leaves a partly covered edge pixel partly opaque" {
    var pixels = solidPixels(8);
    roundCorners(&pixels, 8, 8, 3);
    const edge = alphaAt(&pixels, 8, 1, 0);
    try testing.expect(edge > 0 and edge < 255);
}

test "roundCorners with a radius of 0 changes nothing" {
    var pixels = solidPixels(4);
    roundCorners(&pixels, 4, 4, 0);
    try testing.expectEqualSlices(u8, &solidPixels(4), &pixels);
}
