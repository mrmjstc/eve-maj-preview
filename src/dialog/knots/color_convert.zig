//! Conversions between the profile's ARGB colours and knots' linear colours.
const std = @import("std");
const ui = @import("ui");

const Color = ui.Color;

/// `argb` as a style colour, fully opaque whatever its alpha.
pub fn solid(argb: u32) Color.Input {
    return .{ .color = fromArgb(argb | 0xFF000000) };
}

pub fn fromArgb(argb: u32) Color {
    return .rgba(@truncate(argb >> 16), @truncate(argb >> 8), @truncate(argb), @truncate(argb >> 24));
}

pub fn toArgb(color: Color) u32 {
    const r: u32 = channelToByte(Color.linearToSrgb(color.value[0]));
    const g: u32 = channelToByte(Color.linearToSrgb(color.value[1]));
    const b: u32 = channelToByte(Color.linearToSrgb(color.value[2]));
    const a: u32 = channelToByte(color.value[3]);
    return (a << 24) | (r << 16) | (g << 8) | b;
}

fn channelToByte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

test "an ARGB colour survives the round trip through a linear colour" {
    for ([_]u32{ 0x00000000, 0xFFFFFFFF, 0xFFD9A441, 0x80123456, 0x01FE0102 }) |argb| {
        try std.testing.expectEqual(argb, toArgb(fromArgb(argb)));
    }
}

test "solid makes a translucent colour opaque" {
    const input = solid(0x40D9A441);
    try std.testing.expectEqual(@as(u32, 0xFFD9A441), toArgb(input.color));
}

test "out-of-range channels clamp to the byte range" {
    const color: Color = .{ .value = .{ 2, -1, 0, 1.5 } };
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), toArgb(color));
}
