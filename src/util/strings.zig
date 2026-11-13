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

/// Case-insensitive, with digit runs compared by value, so "Client 2" sorts before "Client 10".
pub fn naturalOrder(first: []const u8, second: []const u8) std.math.Order {
    var first_index: usize = 0;
    var second_index: usize = 0;
    while (first_index < first.len and second_index < second.len) {
        if (std.ascii.isDigit(first[first_index]) and std.ascii.isDigit(second[second_index])) {
            const first_digits = digitRun(first, &first_index);
            const second_digits = digitRun(second, &second_index);
            const by_length = std.math.order(first_digits.len, second_digits.len);
            if (by_length != .eq) return by_length;
            const by_digits = std.mem.order(u8, first_digits, second_digits);
            if (by_digits != .eq) return by_digits;
            continue;
        }
        const by_byte = std.math.order(std.ascii.toLower(first[first_index]), std.ascii.toLower(second[second_index]));
        if (by_byte != .eq) return by_byte;
        first_index += 1;
        second_index += 1;
    }
    return std.math.order(first.len - first_index, second.len - second_index);
}

/// The digits from `index.*` on without leading zeros, leaving `index` past them.
fn digitRun(text: []const u8, index: *usize) []const u8 {
    while (index.* + 1 < text.len and text[index.*] == '0' and std.ascii.isDigit(text[index.* + 1])) index.* += 1;
    const start = index.*;
    while (index.* < text.len and std.ascii.isDigit(text[index.*])) index.* += 1;
    return text[start..index.*];
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

test "naturalOrder sorts numbers by value and ignores case" {
    try testing.expectEqual(std.math.Order.lt, naturalOrder("Test Client 2", "Test Client 10"));
    try testing.expectEqual(std.math.Order.gt, naturalOrder("Test Client 10", "Test Client 9"));
    try testing.expectEqual(std.math.Order.lt, naturalOrder("alpha", "Beta"));
    try testing.expectEqual(std.math.Order.eq, naturalOrder("Pilot 007", "pilot 7"));
    try testing.expectEqual(std.math.Order.lt, naturalOrder("Pilot", "Pilot 1"));
    try testing.expectEqual(std.math.Order.lt, naturalOrder("Pilot 1a", "Pilot 1b"));
}
