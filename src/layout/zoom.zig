//! Where a hover zoom goes: a thumbnail's rect scaled around an anchor and kept on its monitor.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const types = @import("../config/types.zig");

const TextPosition = types.TextPosition;

/// How many halves of the growth go left (x) and up (y): 0 grows away from that edge, 2 grows toward it.
const Halves = struct { x: i32, y: i32 };

/// `base` scaled by `percent` so `anchor` stays put, shrunk (keeping its aspect) to fit `bounds`, then shifted inside them.
pub fn zoomedRect(base: win32.RECT, percent: u16, anchor: TextPosition, bounds: win32.RECT) win32.RECT {
    const base_width = win32.rectWidth(base);
    const base_height = win32.rectHeight(base);
    const bounds_width = win32.rectWidth(bounds);
    const bounds_height = win32.rectHeight(bounds);
    if (base_width <= 0 or base_height <= 0 or bounds_width <= 0 or bounds_height <= 0) return base;

    const fit_percent = @min(@divTrunc(bounds_width * 100, base_width), @divTrunc(bounds_height * 100, base_height));
    const scale = @min(@as(i32, percent), fit_percent);
    const width = @divTrunc(base_width * scale, 100);
    const height = @divTrunc(base_height * scale, 100);

    const halves = anchorHalves(anchor);
    const left = base.left - @divTrunc((width - base_width) * halves.x, 2);
    const top = base.top - @divTrunc((height - base_height) * halves.y, 2);
    const x = std.math.clamp(left, bounds.left, bounds.right - width);
    const y = std.math.clamp(top, bounds.top, bounds.bottom - height);
    return .{ .left = x, .top = y, .right = x + width, .bottom = y + height };
}

fn anchorHalves(anchor: TextPosition) Halves {
    return switch (anchor) {
        .TopLeft => .{ .x = 0, .y = 0 },
        .TopCenter => .{ .x = 1, .y = 0 },
        .TopRight => .{ .x = 2, .y = 0 },
        .LeftCenter => .{ .x = 0, .y = 1 },
        .Center => .{ .x = 1, .y = 1 },
        .RightCenter => .{ .x = 2, .y = 1 },
        .BottomLeft => .{ .x = 0, .y = 2 },
        .BottomCenter => .{ .x = 1, .y = 2 },
        .BottomRight => .{ .x = 2, .y = 2 },
    };
}

const testing = std.testing;

const MONITOR = win32.RECT{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };

fn rect(left: i32, top: i32, width: i32, height: i32) win32.RECT {
    return .{ .left = left, .top = top, .right = left + width, .bottom = top + height };
}

test "top-left anchor keeps the top-left corner and doubles the size" {
    try testing.expectEqual(rect(500, 300, 400, 200), zoomedRect(rect(500, 300, 200, 100), 200, .TopLeft, MONITOR));
}

test "center anchor grows evenly on every side" {
    try testing.expectEqual(rect(450, 275, 300, 150), zoomedRect(rect(500, 300, 200, 100), 150, .Center, MONITOR));
}

test "bottom-right anchor keeps the bottom-right corner" {
    try testing.expectEqual(rect(300, 200, 400, 200), zoomedRect(rect(500, 300, 200, 100), 200, .BottomRight, MONITOR));
}

test "a zoom past the monitor edge is pushed back inside" {
    try testing.expectEqual(rect(1520, 880, 400, 200), zoomedRect(rect(1800, 950, 200, 100), 200, .TopLeft, MONITOR));
    try testing.expectEqual(rect(0, 0, 400, 200), zoomedRect(rect(0, 0, 200, 100), 200, .BottomRight, MONITOR));
}

test "a zoom bigger than the monitor shrinks to fit, keeping its aspect" {
    try testing.expectEqual(rect(0, 100, 1920, 960), zoomedRect(rect(100, 100, 400, 200), 1000, .TopLeft, MONITOR));
}

test "a monitor not at the origin bounds the zoom" {
    const second = win32.RECT{ .left = 1920, .top = -200, .right = 3840, .bottom = 880 };
    try testing.expectEqual(rect(1920, -200, 400, 200), zoomedRect(rect(1920, -200, 200, 100), 200, .Center, second));
}
