//! How the game shows a system's security status: its colour on EVE's scale, and its text.
const std = @import("std");
const universe = @import("universe.zig");
const color = @import("../util/color.zig");

/// Fits securityText's longest result.
pub const SECURITY_TEXT_MAX = 8;
/// Lifts -1.0 from 1.7:1 to 4.3:1 against a popup's fill.
const SECURITY_TEXT_LIGHTEN_PERCENT = 40;
/// EVE's own colours, by shown security in tenths from 0 up.
const SECURITY_COLORS = [_]u32{ 0xFFF00000, 0xFFD73000, 0xFFF04800, 0xFFF06000, 0xFFD77700, 0xFFEFEF00, 0xFF8FEF2F, 0xFF00F000, 0xFF00EF47, 0xFF48F0C0, 0xFF2FEFEF };
/// Where null security ends at -1.0, a darker red than 0.0's: EVE paints it all one red, which says nothing across a null region.
const DEEPEST_NULL: u32 = 0xFF8E0A12;

/// As the game shows it, e.g. "0.5" or "-0.4"; `buffer` holds what's returned.
pub fn securityText(buffer: *[SECURITY_TEXT_MAX]u8, security_tenths: i8) []const u8 {
    const magnitude = @abs(security_tenths);
    const sign = if (security_tenths < 0) "-" else "";
    return std.fmt.bufPrint(buffer, "{s}{d}.{d}", .{ sign, magnitude / 10, magnitude % 10 }) catch unreachable;
}

/// EVE's scale from 0.0 up, carried on through null security so a region's depths show.
pub fn securityColor(security_tenths: i8) u32 {
    if (security_tenths >= 0) return SECURITY_COLORS[@intCast(@min(security_tenths, SECURITY_COLORS.len - 1))];
    const depth: u32 = @min(@abs(@as(i32, security_tenths)), 10);
    return color.mix(DEEPEST_NULL, SECURITY_COLORS[0], depth * 10);
}

/// For text on the dark panels: `securityColor`, lightened below high security, whose reds and oranges are too dark to read.
pub fn securityTextColor(security_tenths: i8) u32 {
    const shade = securityColor(security_tenths);
    return if (security_tenths >= universe.HIGH_SECURITY_TENTHS) shade else color.lighten(shade, SECURITY_TEXT_LIGHTEN_PERCENT);
}

const testing = std.testing;

test "securityText reads as the game shows it" {
    var buffer: [SECURITY_TEXT_MAX]u8 = undefined;
    try testing.expectEqualStrings("0.5", securityText(&buffer, 5));
    try testing.expectEqualStrings("1.0", securityText(&buffer, 10));
    try testing.expectEqualStrings("-0.4", securityText(&buffer, -4));
}

test "securityColor keeps EVE's scale from 0.0 up" {
    try testing.expectEqual(SECURITY_COLORS[0], securityColor(0));
    try testing.expectEqual(SECURITY_COLORS[5], securityColor(5));
    try testing.expectEqual(SECURITY_COLORS[10], securityColor(10));
    try testing.expectEqual(SECURITY_COLORS[10], securityColor(14));
}

test "securityColor tells null security's depths apart" {
    try testing.expectEqual(DEEPEST_NULL | 0xFF000000, securityColor(-10));
    try testing.expect(securityColor(-1) != securityColor(-5));
    try testing.expect(securityColor(-5) != securityColor(-10));
    try testing.expectEqual(securityColor(-10), securityColor(-12));
}

test "security text lightens only what's below high security" {
    try testing.expectEqual(securityColor(5), securityTextColor(5));
    try testing.expectEqual(securityColor(9), securityTextColor(9));
    try testing.expect(securityTextColor(4) != securityColor(4));
    try testing.expect(securityTextColor(-10) != securityColor(-10));
}
