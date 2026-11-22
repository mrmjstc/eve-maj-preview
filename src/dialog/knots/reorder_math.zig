//! Where a row dragged through a reorderable list lands, from the rows' measured places; no I/O.
const std = @import("std");

/// A drag's place over the rows, all in window pixels.
pub const Drag = struct {
    /// The lifted row's index.
    from: usize,
    /// Where the gap sat in the layout the rows were measured from, which lags the drawn one by a frame.
    measured_slot: usize,
    /// The lifted row's top.
    top: f32,
    row_height: f32,
};

/// The index the lifted row goes before; `middles` holds each row's measured middle, null for one not yet measured.
pub fn insertIndex(middles: []const ?f32, drag: Drag) usize {
    var passed_count: usize = 0;
    var other_index: usize = 0;
    for (middles, 0..) |measured_middle, index| {
        if (index == drag.from) continue;
        const is_above_gap = other_index < drag.measured_slot;
        other_index += 1;
        const middle = measured_middle orelse continue;
        // Rows above the gap swap at the lifted row's top and rows below at its bottom, so each swap falls halfway, wherever the row was grabbed.
        const edge = if (is_above_gap) drag.top else drag.top + drag.row_height;
        if (edge > middle) passed_count += 1;
    }
    return if (passed_count >= drag.from) passed_count + 1 else passed_count;
}

/// False when putting `from` before `before` leaves it where it is.
pub fn isMove(from: usize, before: usize) bool {
    return before != from and before != from + 1;
}

/// The index item `from` ends up at once it's put before what was item `before`.
pub fn landingIndex(from: usize, before: usize) usize {
    return if (before > from) before - 1 else before;
}

const testing = std.testing;

/// Four 10 px rows, top to bottom.
const ROW_MIDDLES = [_]?f32{ 5, 15, 25, 35 };

fn dragOfSecondRow(top: f32) Drag {
    return .{ .from = 1, .measured_slot = 1, .top = top, .row_height = 10 };
}

test "a row dragged down past the next row's middle goes after it" {
    const before = insertIndex(&ROW_MIDDLES, dragOfSecondRow(16));
    try testing.expectEqual(@as(usize, 3), before);
    try testing.expect(isMove(1, before));
    try testing.expectEqual(@as(usize, 2), landingIndex(1, before));
}

test "a row not dragged past a neighbour's middle stays put" {
    try testing.expect(!isMove(1, insertIndex(&ROW_MIDDLES, dragOfSecondRow(12))));
    try testing.expect(!isMove(1, insertIndex(&ROW_MIDDLES, dragOfSecondRow(6))));
}

test "a row dragged up past the row above's middle goes first" {
    const before = insertIndex(&ROW_MIDDLES, dragOfSecondRow(4));
    try testing.expectEqual(@as(usize, 0), before);
    try testing.expectEqual(@as(usize, 0), landingIndex(1, before));
}

test "a row dragged past the last goes to the end" {
    const before = insertIndex(&ROW_MIDDLES, dragOfSecondRow(30));
    try testing.expectEqual(ROW_MIDDLES.len, before);
    try testing.expectEqual(ROW_MIDDLES.len - 1, landingIndex(1, before));
}

test "a row not yet measured is never counted as passed" {
    var middles = ROW_MIDDLES;
    middles[2] = null;
    try testing.expect(!isMove(1, insertIndex(&middles, dragOfSecondRow(16))));
}

test "rows above the gap swap at the lifted row's top, and rows below at its bottom" {
    // Measured with the gap under row 2, row 2 is above it, so the lifted top hasn't reached its middle.
    const lagged: Drag = .{ .from = 1, .measured_slot = 2, .top = 16, .row_height = 10 };
    try testing.expect(!isMove(1, insertIndex(&ROW_MIDDLES, lagged)));
    try testing.expectEqual(@as(usize, 3), insertIndex(&ROW_MIDDLES, dragOfSecondRow(16)));
}
