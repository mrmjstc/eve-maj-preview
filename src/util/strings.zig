//! Helpers for lists of strings.
const std = @import("std");

pub fn indexOfString(list: []const []const u8, name: []const u8) ?usize {
    for (list, 0..) |item, i| {
        if (std.mem.eql(u8, item, name)) return i;
    }
    return null;
}

const testing = std.testing;

test "indexOfString finds an exact match or returns null" {
    const list = [_][]const u8{ "Jita", "Amarr", "Jita" };
    try testing.expectEqual(@as(?usize, 0), indexOfString(&list, "Jita"));
    try testing.expectEqual(@as(?usize, 1), indexOfString(&list, "Amarr"));
    try testing.expectEqual(@as(?usize, null), indexOfString(&list, "amarr"));
    try testing.expectEqual(@as(?usize, null), indexOfString(&.{}, "Jita"));
}
