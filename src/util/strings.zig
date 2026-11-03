//! Helpers for strings and lists of them.
const std = @import("std");

pub fn indexOfString(list: []const []const u8, name: []const u8) ?usize {
    for (list, 0..) |item, i| {
        if (std.mem.eql(u8, item, name)) return i;
    }
    return null;
}

/// `text`'s first `max_length` bytes, shortened further so a multi-byte UTF-8 character isn't cut in two.
pub fn utf8Prefix(text: []const u8, max_length: usize) []const u8 {
    if (text.len <= max_length) return text;
    var length = max_length;
    while (length > 0 and (text[length] & 0xC0) == 0x80) length -= 1;
    return text[0..length];
}

const testing = std.testing;

test "indexOfString finds an exact match or returns null" {
    const list = [_][]const u8{ "Jita", "Amarr", "Jita" };
    try testing.expectEqual(@as(?usize, 0), indexOfString(&list, "Jita"));
    try testing.expectEqual(@as(?usize, 1), indexOfString(&list, "Amarr"));
    try testing.expectEqual(@as(?usize, null), indexOfString(&list, "amarr"));
    try testing.expectEqual(@as(?usize, null), indexOfString(&.{}, "Jita"));
}

test "utf8Prefix doesn't cut a character in two" {
    try testing.expectEqualStrings("Main", utf8Prefix("Main", 16));
    try testing.expectEqualStrings("Ma", utf8Prefix("Main", 2));
    // "Ко" is four bytes; three would end inside the "о".
    try testing.expectEqualStrings("К", utf8Prefix("Копия", 3));
}
