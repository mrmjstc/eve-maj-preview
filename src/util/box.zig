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
};
