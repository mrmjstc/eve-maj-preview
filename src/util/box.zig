//! A rectangle in pixels.
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
