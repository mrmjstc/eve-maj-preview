//! A rectangle in pixels.
const std = @import("std");

/// `right` and `bottom` exclusive.
pub const Box = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn overlaps(self: Box, other: Box) bool {
        return self.left < other.right and other.left < self.right and self.top < other.bottom and other.top < self.bottom;
    }

    pub fn contains(self: Box, other: Box) bool {
        return other.left >= self.left and other.top >= self.top and other.right <= self.right and other.bottom <= self.bottom;
    }

    pub fn overlapsAny(self: Box, others: []const Box) bool {
        for (others) |other| {
            if (self.overlaps(other)) return true;
        }
        return false;
    }

    /// A negative `amount` grows it.
    pub fn inset(self: Box, amount: i32) Box {
        return .{ .left = self.left + amount, .top = self.top + amount, .right = self.right - amount, .bottom = self.bottom - amount };
    }

    pub fn containsPoint(self: Box, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and y >= self.top and y < self.bottom;
    }
};

const testing = std.testing;

const TEST_BOX: Box = .{ .left = 10, .top = 20, .right = 110, .bottom = 70 };

test "boxes that only share an edge don't overlap" {
    try testing.expect(!TEST_BOX.overlaps(.{ .left = 110, .top = 20, .right = 150, .bottom = 70 }));
    try testing.expect(!TEST_BOX.overlaps(.{ .left = 10, .top = 0, .right = 110, .bottom = 20 }));
    try testing.expect(TEST_BOX.overlaps(.{ .left = 109, .top = 69, .right = 150, .bottom = 90 }));
    try testing.expect(TEST_BOX.overlaps(.{ .left = 0, .top = 0, .right = 200, .bottom = 200 }));
}

test "contains takes a box flush with its edges, not one past them" {
    try testing.expect(TEST_BOX.contains(TEST_BOX));
    try testing.expect(TEST_BOX.contains(.{ .left = 50, .top = 30, .right = 110, .bottom = 70 }));
    try testing.expect(!TEST_BOX.contains(.{ .left = 50, .top = 30, .right = 111, .bottom = 70 }));
    try testing.expect(!TEST_BOX.contains(.{ .left = 0, .top = 0, .right = 200, .bottom = 200 }));
}

test "overlapsAny finds one overlapping box among several" {
    const clear = [_]Box{ .{ .left = 200, .top = 0, .right = 250, .bottom = 50 }, .{ .left = 0, .top = 100, .right = 50, .bottom = 150 } };
    try testing.expect(!TEST_BOX.overlapsAny(&clear));
    try testing.expect(TEST_BOX.overlapsAny(&(clear ++ [_]Box{.{ .left = 100, .top = 60, .right = 120, .bottom = 80 }})));
    try testing.expect(!TEST_BOX.overlapsAny(&.{}));
}

test "inset shrinks every side and a negative amount grows it" {
    try testing.expectEqual(Box{ .left = 15, .top = 25, .right = 105, .bottom = 65 }, TEST_BOX.inset(5));
    try testing.expectEqual(Box{ .left = 8, .top = 18, .right = 112, .bottom = 72 }, TEST_BOX.inset(-2));
}

test "containsPoint excludes the right and bottom edges" {
    try testing.expect(TEST_BOX.containsPoint(10, 20));
    try testing.expect(TEST_BOX.containsPoint(109, 69));
    try testing.expect(!TEST_BOX.containsPoint(110, 50));
    try testing.expect(!TEST_BOX.containsPoint(50, 70));
    try testing.expect(!TEST_BOX.containsPoint(9, 50));
}
