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
    if (abs_value >= 1_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.1}m", .{value / 1_000_000.0}) catch "?";
    } else if (abs_value >= 1_000.0) {
        return std.fmt.bufPrint(buf, "{d:.0}k", .{value / 1_000.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.0}", .{value}) catch "?";
    }
}
