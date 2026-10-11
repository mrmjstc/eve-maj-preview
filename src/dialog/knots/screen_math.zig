//! Scaling desktop rectangles onto a screen preview; no I/O.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");

const RECT = win32.RECT;

/// x, y, width, height on the preview.
pub const Box = [4]f32;

/// The virtual desktop's origin and how it's shrunk onto a preview.
pub const Frame = struct {
    left: f32,
    top: f32,
    scale: f32,
    width: f32,
    height: f32,

    /// `desktop` shrunk to fit within `max_width` by `max_height`, keeping its shape.
    pub fn fit(desktop: RECT, max_width: f32, max_height: f32) Frame {
        const desktop_width: f32 = @floatFromInt(@max(1, win32.rectWidth(desktop)));
        const desktop_height: f32 = @floatFromInt(@max(1, win32.rectHeight(desktop)));
        const scale = @min(max_height / desktop_height, max_width / desktop_width);
        return .{
            .left = @floatFromInt(desktop.left),
            .top = @floatFromInt(desktop.top),
            .scale = scale,
            .width = @max(1, @round(desktop_width * scale)),
            .height = @max(1, @round(desktop_height * scale)),
        };
    }

    /// `rect`, in desktop pixels, on the preview in whole pixels, clamped to it.
    pub fn box(self: Frame, rect: RECT) Box {
        const x0 = @round(std.math.clamp((@as(f32, @floatFromInt(rect.left)) - self.left) * self.scale, 0, self.width));
        const y0 = @round(std.math.clamp((@as(f32, @floatFromInt(rect.top)) - self.top) * self.scale, 0, self.height));
        const x1 = @round(std.math.clamp((@as(f32, @floatFromInt(rect.right)) - self.left) * self.scale, 0, self.width));
        const y1 = @round(std.math.clamp((@as(f32, @floatFromInt(rect.bottom)) - self.top) * self.scale, 0, self.height));
        return .{ x0, y0, x1 - x0, y1 - y0 };
    }

    /// Like box, but null when `rect` would be under a pixel across, e.g. entirely off the desktop.
    pub fn visibleBox(self: Frame, rect: RECT) ?Box {
        const result = self.box(rect);
        if (result[2] < 1 or result[3] < 1) return null;
        return result;
    }
};

/// Half-open like GDI: the left/top edges are inside, right/bottom aren't.
pub fn contains(box: Box, point: [2]f32) bool {
    const x, const y, const width, const height = box;
    return point[0] >= x and point[0] < x + width and point[1] >= y and point[1] < y + height;
}

const testing = std.testing;

const TWO_SIDE_BY_SIDE = RECT{ .left = -1920, .top = 0, .right = 1920, .bottom = 1080 };

test "a wide desktop is held to the maximum width" {
    const frame = Frame.fit(TWO_SIDE_BY_SIDE, 560, 400);
    try testing.expectEqual(@as(f32, 560), frame.width);
    try testing.expectEqual(@as(f32, 158), frame.height);
}

test "a single monitor is held to the maximum height" {
    const frame = Frame.fit(.{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 }, 560, 120);
    try testing.expectEqual(@as(f32, 213), frame.width);
    try testing.expectEqual(@as(f32, 120), frame.height);
}

test "a monitor left of the primary lands at the preview's left edge" {
    const frame = Frame.fit(TWO_SIDE_BY_SIDE, 384, 1000);
    try testing.expectEqual(Box{ 0, 0, 192, 108 }, frame.box(.{ .left = -1920, .top = 0, .right = 0, .bottom = 1080 }));
    try testing.expectEqual(Box{ 192, 0, 192, 108 }, frame.box(.{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 }));
}

test "a rect off the desktop has no visible box" {
    const frame = Frame.fit(TWO_SIDE_BY_SIDE, 384, 1000);
    try testing.expectEqual(@as(?Box, null), frame.visibleBox(.{ .left = 5000, .top = 0, .right = 6000, .bottom = 100 }));
}

test "contains takes the top-left edges but not the bottom-right" {
    const box = Box{ 10, 10, 20, 20 };
    try testing.expect(contains(box, .{ 10, 10 }));
    try testing.expect(!contains(box, .{ 30, 15 }));
    try testing.expect(!contains(box, .{ 15, 30 }));
}
