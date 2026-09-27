const std = @import("std");

/// Index of the first slice in `list` equal to `name`, or null.
pub fn indexOfString(list: []const []const u8, name: []const u8) ?usize {
    for (list, 0..) |item, i| {
        if (std.mem.eql(u8, item, name)) return i;
    }
    return null;
}
