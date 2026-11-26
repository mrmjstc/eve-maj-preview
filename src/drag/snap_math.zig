//! Where a dragged window snaps: to the edges of a screen, of other windows, and onto saved positions; no I/O.
const std = @import("std");
const win32 = @import("../platform/win32.zig");

pub const SnapPosition = struct { x: i32, y: i32 };

/// Moves a dragged window onto the saved position whose top-left corner is nearest by Chebyshev distance, within the threshold; later ones win ties.
pub const Dock = struct {
    /// Where the window started; every candidate is measured from here.
    from: SnapPosition,
    position: SnapPosition,
    best_distance: i32,

    pub fn init(x: i32, y: i32, threshold: i32) Dock {
        return .{ .from = .{ .x = x, .y = y }, .position = .{ .x = x, .y = y }, .best_distance = threshold };
    }

    pub fn consider(self: *Dock, saved: win32.RECT) void {
        const distance: i32 = @intCast(@max(@abs(self.from.x - saved.left), @abs(self.from.y - saved.top)));
        if (distance > self.best_distance) return;
        self.best_distance = distance;
        self.position = .{ .x = saved.left, .y = saved.top };
    }
};

/// Pulls a dragged window's edges onto other rects' nearest, a rect at a time; each axis keeps the closest within the threshold, the later on a tie.
pub const EdgeSnap = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    min_x_distance: i32,
    min_y_distance: i32,

    pub fn init(x: i32, y: i32, width: i32, height: i32, threshold: i32) EdgeSnap {
        return .{ .x = x, .y = y, .width = width, .height = height, .min_x_distance = threshold, .min_y_distance = threshold };
    }

    /// Snaps an axis only while the window overlaps `other` along the other axis, so a window far above or beside it isn't pulled in line.
    pub fn toward(self: *EdgeSnap, other: win32.RECT) void {
        const original_x = self.x;
        const original_y = self.y;
        const right = original_x + self.width;
        const bottom = original_y + self.height;

        if (!(bottom < other.top or original_y > other.bottom)) {
            self.snapX(original_x, other.left, other.left);
            self.snapX(original_x, other.right, other.right);
            self.snapX(right, other.left, other.left - self.width);
            self.snapX(right, other.right, other.right - self.width);
        }

        // Against the x just snapped, since a horizontal snap can bring the window into line vertically.
        if (!(self.x + self.width < other.left or self.x > other.right)) {
            self.snapY(original_y, other.top, other.top);
            self.snapY(original_y, other.bottom, other.bottom);
            self.snapY(bottom, other.top, other.top - self.height);
            self.snapY(bottom, other.bottom, other.bottom - self.height);
        }
    }

    pub fn position(self: *const EdgeSnap) SnapPosition {
        return .{ .x = self.x, .y = self.y };
    }

    fn snapX(self: *EdgeSnap, edge: i32, other_edge: i32, snapped_x: i32) void {
        const distance: i32 = @intCast(@abs(edge - other_edge));
        if (distance > self.min_x_distance) return;
        self.min_x_distance = distance;
        self.x = snapped_x;
    }

    fn snapY(self: *EdgeSnap, edge: i32, other_edge: i32, snapped_y: i32) void {
        const distance: i32 = @intCast(@abs(edge - other_edge));
        if (distance > self.min_y_distance) return;
        self.min_y_distance = distance;
        self.y = snapped_y;
    }
};

/// Each edge of a `width` x `height` window at (`x`, `y`) within `threshold` of the same edge of `bounds` moves onto it.
pub fn screenEdges(x: i32, y: i32, width: i32, height: i32, threshold: i32, bounds: win32.RECT) SnapPosition {
    var snapped: SnapPosition = .{ .x = x, .y = y };
    if (@abs(x - bounds.left) < threshold) snapped.x = bounds.left;
    if (@abs(x + width - bounds.right) < threshold) snapped.x = bounds.right - width;
    if (@abs(y - bounds.top) < threshold) snapped.y = bounds.top;
    if (@abs(y + height - bounds.bottom) < threshold) snapped.y = bounds.bottom - height;
    return snapped;
}

const testing = std.testing;

fn rectOf(left: i32, top: i32, right: i32, bottom: i32) win32.RECT {
    return .{ .left = left, .top = top, .right = right, .bottom = bottom };
}

const SCREEN = rectOf(0, 0, 1920, 1080);

/// Docks (`x`, `y`) against `saved` with a 10 px threshold.
fn docked(x: i32, y: i32, saved: []const win32.RECT) SnapPosition {
    var dock: Dock = .init(x, y, 10);
    for (saved) |rect| dock.consider(rect);
    return dock.position;
}

test "a window within the threshold of a screen edge moves onto it" {
    try testing.expectEqual(SnapPosition{ .x = 0, .y = 0 }, screenEdges(5, 9, 200, 100, 10, SCREEN));
    try testing.expectEqual(SnapPosition{ .x = 1720, .y = 980 }, screenEdges(1715, 975, 200, 100, 10, SCREEN));
}

test "a window at or past the threshold from every screen edge stays put" {
    try testing.expectEqual(SnapPosition{ .x = 10, .y = 500 }, screenEdges(10, 500, 200, 100, 10, SCREEN));
}

test "docking takes the nearest saved corner within the threshold" {
    const saved = [_]win32.RECT{ rectOf(100, 100, 300, 200), rectOf(108, 95, 308, 195) };
    try testing.expectEqual(SnapPosition{ .x = 108, .y = 95 }, docked(106, 97, &saved));
    try testing.expectEqual(SnapPosition{ .x = 100, .y = 100 }, docked(102, 101, &saved));
    try testing.expectEqual(SnapPosition{ .x = 150, .y = 150 }, docked(150, 150, &saved));
}

test "a window beside another lines its left edge up with the other's right" {
    var snap: EdgeSnap = .init(305, 120, 200, 100, 10);
    snap.toward(rectOf(100, 100, 300, 200));
    try testing.expectEqual(SnapPosition{ .x = 300, .y = 120 }, snap.position());
}

test "a window that doesn't overlap another along the other axis isn't pulled in line" {
    var snap: EdgeSnap = .init(305, 500, 200, 100, 10);
    snap.toward(rectOf(100, 100, 300, 200));
    try testing.expectEqual(SnapPosition{ .x = 305, .y = 500 }, snap.position());
}

test "across several rects each axis keeps the closest edge" {
    var snap: EdgeSnap = .init(305, 150, 200, 100, 10);
    snap.toward(rectOf(100, 100, 298, 200));
    snap.toward(rectOf(100, 100, 304, 200));
    try testing.expectEqual(SnapPosition{ .x = 304, .y = 150 }, snap.position());
}
