//! Which item of a dialog list shows its details, kept on that item as the list shrinks or reorders; no I/O.
const std = @import("std");

/// An index into a list its tab owns.
pub const Selection = struct {
    index: usize = 0,

    /// The list can shrink while the window is open, e.g. on a profile switch; `count` must be above 0.
    pub fn clamp(self: *Selection, count: usize) void {
        if (self.index >= count) self.index = count - 1;
    }

    /// Onto the item that took `removed`'s place, else the new last, once the list is `count` long.
    pub fn afterRemove(self: *Selection, removed: usize, count: usize) void {
        self.index = @min(removed, count -| 1);
    }

    /// Follows the selected item, not its slot, after the item at `from` moved to just before `before`.
    pub fn afterMove(self: *Selection, from: usize, before: usize) void {
        const to = if (before > from) before - 1 else before;
        if (self.index == from) {
            self.index = to;
        } else if (from < self.index and to >= self.index) {
            self.index -= 1;
        } else if (from > self.index and to <= self.index) {
            self.index += 1;
        }
    }
};

const testing = std.testing;

test "clamp pulls a selection past the end back onto the last item" {
    var selection: Selection = .{ .index = 5 };
    selection.clamp(3);
    try testing.expectEqual(2, selection.index);
    selection.clamp(3);
    try testing.expectEqual(2, selection.index);
}

test "removing the last item selects the new last one" {
    var selection: Selection = .{ .index = 3 };
    selection.afterRemove(3, 3);
    try testing.expectEqual(2, selection.index);
}

test "removing the only item leaves the selection at 0" {
    var selection: Selection = .{};
    selection.afterRemove(0, 0);
    try testing.expectEqual(0, selection.index);
}

test "moving the selected item carries the selection with it" {
    var selection: Selection = .{ .index = 1 };
    selection.afterMove(1, 4);
    try testing.expectEqual(3, selection.index);
}

test "moving an item from above to below the selection shifts it up" {
    var selection: Selection = .{ .index = 2 };
    selection.afterMove(0, 4);
    try testing.expectEqual(1, selection.index);
}

test "moving an item from below to above the selection shifts it down" {
    var selection: Selection = .{ .index = 1 };
    selection.afterMove(3, 0);
    try testing.expectEqual(2, selection.index);
}

test "moving items on one side of the selection leaves it alone" {
    var selection: Selection = .{ .index = 0 };
    selection.afterMove(2, 4);
    try testing.expectEqual(0, selection.index);
}
