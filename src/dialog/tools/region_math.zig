//! Snapping and sizing math for the region-select overlay; no I/O.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");

const RECT = win32.RECT;

pub const SNAP_DISTANCE_PX: i32 = 8;

pub const Axis = enum { x, y };

/// The edge of `others` or `bounds` along `axis` nearest `value`, if one is within `distance`.
pub fn nearestEdge(value: i32, axis: Axis, others: []const RECT, bounds: RECT, distance: i32) ?i32 {
    var best: ?i32 = null;
    var best_gap = distance;
    considerRect(value, axis, bounds, &best, &best_gap);
    for (others) |other| considerRect(value, axis, other, &best, &best_gap);
    return best;
}

/// `value` moved onto the nearest edge within `distance`, else unchanged.
pub fn snapEdge(value: i32, axis: Axis, others: []const RECT, bounds: RECT, distance: i32) i32 {
    return nearestEdge(value, axis, others, bounds, distance) orelse value;
}

/// The shift that lands the nearer end of `low`..`high` on an edge within `distance`, else 0.
pub fn snapSpanOffset(low: i32, high: i32, axis: Axis, others: []const RECT, bounds: RECT, distance: i32) i32 {
    const low_shift = if (nearestEdge(low, axis, others, bounds, distance)) |edge| edge - low else null;
    const high_shift = if (nearestEdge(high, axis, others, bounds, distance)) |edge| edge - high else null;
    const low_value = low_shift orelse return high_shift orelse 0;
    const high_value = high_shift orelse return low_value;
    return if (@abs(low_value) <= @abs(high_value)) low_value else high_value;
}

/// `rect` resized to `length` along `axis`, keeping its left or top edge unless that would run it past `bounds`; never under `min_length`.
pub fn withLength(rect: RECT, axis: Axis, length: i32, bounds: RECT, min_length: i32) RECT {
    var r = rect;
    switch (axis) {
        .x => {
            const span = resizedSpan(r.left, length, bounds.left, bounds.right, min_length);
            r.left = span[0];
            r.right = span[1];
        },
        .y => {
            const span = resizedSpan(r.top, length, bounds.top, bounds.bottom, min_length);
            r.top = span[0];
            r.bottom = span[1];
        },
    }
    return r;
}

fn considerRect(value: i32, axis: Axis, rect: RECT, best: *?i32, best_gap: *i32) void {
    const edges = switch (axis) {
        .x => [2]i32{ rect.left, rect.right },
        .y => [2]i32{ rect.top, rect.bottom },
    };
    for (edges) |edge| {
        const gap: i32 = @intCast(@abs(edge - value));
        if (gap > best_gap.* or (gap == best_gap.* and best.* != null)) continue;
        best.* = edge;
        best_gap.* = gap;
    }
}

fn resizedSpan(start: i32, length: i32, low: i32, high: i32, min_length: i32) [2]i32 {
    const clamped = @min(@max(length, min_length), high - low);
    const new_start = @max(low, @min(start, high - clamped));
    return .{ new_start, new_start + clamped };
}

const testing = std.testing;

const MONITOR = RECT{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };

test "an edge within the snap distance of another region's edge snaps onto it" {
    const others = [_]RECT{.{ .left = 100, .top = 100, .right = 500, .bottom = 400 }};
    try testing.expectEqual(@as(i32, 500), snapEdge(505, .x, &others, MONITOR, SNAP_DISTANCE_PX));
    try testing.expectEqual(@as(i32, 400), snapEdge(394, .y, &others, MONITOR, SNAP_DISTANCE_PX));
}

test "an edge past the snap distance stays where it is" {
    const others = [_]RECT{.{ .left = 100, .top = 100, .right = 500, .bottom = 400 }};
    try testing.expectEqual(@as(i32, 520), snapEdge(520, .x, &others, MONITOR, SNAP_DISTANCE_PX));
}

test "the monitor's own edges are snap targets" {
    try testing.expectEqual(@as(i32, 1920), snapEdge(1914, .x, &.{}, MONITOR, SNAP_DISTANCE_PX));
    try testing.expectEqual(@as(i32, 0), snapEdge(3, .y, &.{}, MONITOR, SNAP_DISTANCE_PX));
}

test "the nearer of two candidate edges wins" {
    const others = [_]RECT{
        .{ .left = 200, .top = 0, .right = 300, .bottom = 100 },
        .{ .left = 306, .top = 0, .right = 400, .bottom = 100 },
    };
    try testing.expectEqual(@as(i32, 306), snapEdge(304, .x, &others, MONITOR, SNAP_DISTANCE_PX));
}

test "a moved span snaps by whichever end is nearer an edge" {
    const others = [_]RECT{.{ .left = 600, .top = 0, .right = 900, .bottom = 100 }};
    // Right end 597 is 3 from 600; left end 297 has nothing near.
    try testing.expectEqual(@as(i32, 3), snapSpanOffset(297, 597, .x, &others, MONITOR, SNAP_DISTANCE_PX));
    try testing.expectEqual(@as(i32, 0), snapSpanOffset(250, 550, .x, &others, MONITOR, SNAP_DISTANCE_PX));
}

test "a span already on an edge doesn't shift to snap its other end" {
    const others = [_]RECT{.{ .left = 600, .top = 0, .right = 900, .bottom = 100 }};
    try testing.expectEqual(@as(i32, 0), snapSpanOffset(600, 895, .x, &others, MONITOR, SNAP_DISTANCE_PX));
}

test "a typed width keeps the left edge when it fits" {
    const rect = RECT{ .left = 100, .top = 100, .right = 300, .bottom = 300 };
    const resized = withLength(rect, .x, 500, MONITOR, 10);
    try testing.expectEqual(RECT{ .left = 100, .top = 100, .right = 600, .bottom = 300 }, resized);
}

test "a typed height too tall for the space below moves the top up" {
    const rect = RECT{ .left = 0, .top = 900, .right = 100, .bottom = 1000 };
    const resized = withLength(rect, .y, 400, MONITOR, 10);
    try testing.expectEqual(RECT{ .left = 0, .top = 680, .right = 100, .bottom = 1080 }, resized);
}

test "a typed length is held between the minimum and the monitor" {
    const rect = RECT{ .left = 100, .top = 100, .right = 300, .bottom = 300 };
    try testing.expectEqual(@as(i32, 10), win32.rectWidth(withLength(rect, .x, 2, MONITOR, 10)));
    try testing.expectEqual(RECT{ .left = 0, .top = 100, .right = 1920, .bottom = 300 }, withLength(rect, .x, 5000, MONITOR, 10));
}
