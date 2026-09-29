//! Helpers for lists of strings.
const std = @import("std");

pub fn indexOfString(list: []const []const u8, name: []const u8) ?usize {
    for (list, 0..) |item, i| {
        if (std.mem.eql(u8, item, name)) return i;
    }
    return null;
}
