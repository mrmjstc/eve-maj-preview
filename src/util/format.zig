//! Number formatting for on-screen stats.
const std = @import("std");

/// Inserts comma thousands-separators into the leading run of ASCII digits in `text` (e.g. "12405.3 m3/min" -> "12,405.3 m3/min"); returns `text` unchanged if `buf` is too small.
pub fn insertThousandsSeparators(buf: []u8, text: []const u8) []const u8 {
    var digit_end: usize = 0;
    while (digit_end < text.len and std.ascii.isDigit(text[digit_end])) : (digit_end += 1) {}
    if (digit_end <= 3) return text;

    const first_group = if (digit_end % 3 == 0) 3 else digit_end % 3;
    if (first_group > buf.len) return text;
    @memcpy(buf[0..first_group], text[0..first_group]);
    var out = first_group;

    var i = first_group;
    while (i < digit_end) : (i += 3) {
        if (out + 4 > buf.len) return text;
        buf[out] = ',';
        @memcpy(buf[out + 1 ..][0..3], text[i..][0..3]);
        out += 4;
    }

    const rest = text[digit_end..];
    if (out + rest.len > buf.len) return text;
    @memcpy(buf[out..][0..rest.len], rest);
    return buf[0 .. out + rest.len];
}

/// Abbreviates an ISK value with k/m suffixes (e.g. 2_450_000.0 -> "2.5m", 200_000.0 -> "200k", 850.0 -> "850").
pub fn formatIskAbbrev(buf: []u8, value: f32) []const u8 {
    const abs_value = @abs(value);
    if (abs_value >= 999_500.0) {
        return std.fmt.bufPrint(buf, "{d:.1}m", .{value / 1_000_000.0}) catch "?";
    } else if (abs_value >= 999.5) {
        return std.fmt.bufPrint(buf, "{d:.0}k", .{value / 1_000.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.0}", .{value}) catch "?";
    }
}

const testing = std.testing;

test "insertThousandsSeparators groups the leading digits only" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("12,405.3 m3/min", insertThousandsSeparators(&buf, "12405.3 m3/min"));
    try testing.expectEqualStrings("123,456", insertThousandsSeparators(&buf, "123456"));
    try testing.expectEqualStrings("1,234,567 ISK", insertThousandsSeparators(&buf, "1234567 ISK"));
    try testing.expectEqualStrings("123", insertThousandsSeparators(&buf, "123"));
    try testing.expectEqualStrings("-1234", insertThousandsSeparators(&buf, "-1234"));
}

test "insertThousandsSeparators returns the text unchanged when the buffer is too small" {
    var buf: [5]u8 = undefined;
    try testing.expectEqualStrings("12345", insertThousandsSeparators(&buf, "12345"));
}

test "formatIskAbbrev switches suffix at a thousand and a million" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("850", formatIskAbbrev(&buf, 850.0));
    try testing.expectEqualStrings("1k", formatIskAbbrev(&buf, 1_000.0));
    try testing.expectEqualStrings("200k", formatIskAbbrev(&buf, 200_000.0));
    try testing.expectEqualStrings("1.0m", formatIskAbbrev(&buf, 1_000_000.0));
    try testing.expectEqualStrings("2.5m", formatIskAbbrev(&buf, 2_460_000.0));
    try testing.expectEqualStrings("-1.5m", formatIskAbbrev(&buf, -1_500_000.0));
}

test "formatIskAbbrev never shows 1000 before a suffix" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("999", formatIskAbbrev(&buf, 999.4));
    try testing.expectEqualStrings("1k", formatIskAbbrev(&buf, 999.6));
    try testing.expectEqualStrings("999k", formatIskAbbrev(&buf, 999_400.0));
    try testing.expectEqualStrings("1.0m", formatIskAbbrev(&buf, 999_720.0));
    try testing.expectEqualStrings("-1.0m", formatIskAbbrev(&buf, -999_720.0));
}
