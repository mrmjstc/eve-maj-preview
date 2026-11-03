//! Cutting UTF-8 text without splitting a character; no I/O.
const std = @import("std");

/// The longest prefix of at most `limit` bytes that doesn't split a character.
pub fn prefixLength(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    var length = limit;
    while (length > 0 and (text[length] & 0xC0) == 0x80) length -= 1;
    return length;
}

const testing = std.testing;

test "prefixLength cuts a long text without splitting a character" {
    try testing.expectEqual(@as(usize, 1), prefixLength("a\u{0416}b", 2));
    try testing.expectEqual(@as(usize, 3), prefixLength("a\u{0416}b", 3));
    try testing.expectEqual(@as(usize, 2), prefixLength("ab", 5));
}
