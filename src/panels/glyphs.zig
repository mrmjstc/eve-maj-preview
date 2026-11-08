//! The menus' 16px icons, drawn after EVE's own: ships after their overview brackets, then actions and what they act on.
const std = @import("std");
const pixel_buffer = @import("../util/pixel_buffer.zig");

pub const SIZE: i32 = 16;
const MASK_LENGTH = SIZE * SIZE;
/// Half every glyph's 1.5px line, so all of them weigh the same.
const LINE: f32 = 0.75;
/// A circle's sides, enough that none shows as a corner at this size.
const ARC_STEPS = 24;
const CENTER: Point = .{ 8, 8 };

const TITAN = strokedMask(&.{
    line(&.{ .{ 3, 8.5 }, .{ 3, 6.5 }, .{ 8, 1.5 }, .{ 13, 6.5 }, .{ 13, 8.5 } }),
    line(&.{ .{ 3, 14.5 }, .{ 3, 12.5 }, .{ 8, 7.5 }, .{ 13, 12.5 }, .{ 13, 14.5 } }),
});
const FREIGHTER = strokedMask(&.{
    line(&.{ .{ 2.5, 7.5 }, .{ 2.5, 3 }, .{ 4, 1.5 }, .{ 12, 1.5 }, .{ 13.5, 3 }, .{ 13.5, 7.5 }, .{ 2.5, 7.5 } }),
    line(&.{ .{ 4, 11.5 }, .{ 5.5, 10 }, .{ 10.5, 10 }, .{ 12, 11.5 }, .{ 10.5, 13 }, .{ 5.5, 13 }, .{ 4, 11.5 } }),
});
const CARRIER = strokedMask(&.{
    line(&.{ .{ 8, 1.5 }, .{ 13.5, 7.5 }, .{ 8, 13.5 }, .{ 2.5, 7.5 }, .{ 8, 1.5 } }),
});
const DREADNOUGHT = strokedMask(&.{
    line(&.{ .{ 8, 2.5 }, .{ 1.5, 8.5 }, .{ 1.5, 11 }, .{ 6, 11 }, .{ 8, 13 }, .{ 10, 11 }, .{ 14.5, 11 }, .{ 14.5, 8.5 }, .{ 8, 2.5 } }),
});
const BATTLESHIP = strokedMask(&.{
    line(&.{ .{ 3.5, 13.5 }, .{ 3.5, 6.5 }, .{ 8, 2.5 }, .{ 12.5, 6.5 }, .{ 12.5, 13.5 } }),
    line(&.{ .{ 3.5, 13 }, .{ 8, 8.5 }, .{ 12.5, 13 } }),
});
const SET_DESTINATION = strokedMask(&.{
    .{ .half_width = 2, .points = &.{CENTER} },
    line(&.{ .{ 2.5, 5.5 }, .{ 4.5, 8 }, .{ 2.5, 10.5 } }),
    line(&.{ .{ 13.5, 5.5 }, .{ 11.5, 8 }, .{ 13.5, 10.5 } }),
});
const OPEN_WINDOW = strokedMask(&.{
    line(&.{ .{ 8, 3 }, .{ 3, 3 }, .{ 3, 13 }, .{ 13, 13 }, .{ 13, 8 } }),
    line(&.{ .{ 8, 8 }, .{ 13.5, 2.5 } }),
    line(&.{ .{ 9.5, 2.5 }, .{ 13.5, 2.5 }, .{ 13.5, 6.5 } }),
});
const JUMP_RANGE = strokedMask(&.{
    .{ .half_width = 1.6, .points = &.{CENTER} },
    line(&arc(CENTER, 4.5, 0, 360)),
    line(&arc(CENTER, 7, 140, 220)),
    line(&arc(CENTER, 7, -40, 40)),
});
const AVOID = strokedMask(&.{
    line(&arc(CENTER, 5.5, 0, 360)),
    line(&.{ .{ 4.3, 4.3 }, .{ 11.7, 11.7 } }),
});
const COPY = strokedMask(&.{
    line(&.{ .{ 3, 10 }, .{ 3, 3 }, .{ 10, 3 } }),
    line(&.{ .{ 7, 7 }, .{ 13, 7 }, .{ 13, 13 }, .{ 7, 13 }, .{ 7, 7 } }),
});
const MAP = strokedMask(&.{
    line(&.{ .{ 2, 4 }, .{ 6, 2.5 }, .{ 10, 4 }, .{ 14, 2.5 }, .{ 14, 12 }, .{ 10, 13.5 }, .{ 6, 12 }, .{ 2, 13.5 }, .{ 2, 4 } }),
    line(&.{ .{ 6, 2.5 }, .{ 6, 12 } }),
    line(&.{ .{ 10, 4 }, .{ 10, 13.5 } }),
});
const CROSSHAIR = strokedMask(&.{
    line(&arc(CENTER, 5, 0, 360)),
    line(&.{ .{ 8, 1 }, .{ 8, 5 } }),
    line(&.{ .{ 8, 11 }, .{ 8, 15 } }),
    line(&.{ .{ 1, 8 }, .{ 5, 8 } }),
    line(&.{ .{ 11, 8 }, .{ 15, 8 } }),
});
const STAR = strokedMask(&.{
    line(&star(6.5, 2.8)),
});
const OFF = strokedMask(&.{
    line(&.{ .{ 4, 4 }, .{ 12, 12 } }),
    line(&.{ .{ 12, 4 }, .{ 4, 12 } }),
});
const ROUTE = strokedMask(&.{
    .{ .half_width = 1.5, .points = &.{.{ 3.5, 12.5 }} },
    .{ .half_width = 1.5, .points = &.{.{ 12.5, 3.5 }} },
    line(&.{ .{ 3.5, 12.5 }, .{ 3.5, 8 }, .{ 12.5, 8 }, .{ 12.5, 3.5 } }),
});
const PERSON = strokedMask(&.{
    line(&arc(.{ 8, 5 }, 2.75, 0, 360)),
    line(&arc(.{ 8, 14.5 }, 5, 180, 360)),
});
const GROUP = strokedMask(&.{
    line(&arc(.{ 11, 4 }, 2.25, 0, 360)),
    line(&arc(.{ 11, 11.5 }, 3.5, 250, 360)),
    line(&arc(.{ 5.5, 6.5 }, 2.25, 0, 360)),
    line(&arc(.{ 5.5, 14.5 }, 4, 180, 360)),
});

/// Ships by their overview bracket, then actions, then what a row is.
pub const Glyph = enum {
    titan,
    freighter,
    carrier,
    dreadnought,
    battleship,
    set_destination,
    open_window,
    jump_range,
    avoid,
    copy,
    map,
    crosshair,
    star,
    off,
    route,
    person,
    group,
};

/// A point in the glyph's box, x then y, in pixels from its corner.
const Point = [2]f32;

/// Lines joining `points`; a single point is a disc.
const Stroke = struct {
    half_width: f32,
    points: []const Point,
};

/// `left` and `top` are its corner; clipped to the canvas.
pub fn draw(canvas: pixel_buffer.Canvas, glyph: Glyph, left: i32, top: i32, argb: u32) void {
    pixel_buffer.fillCoverage(canvas, left, top, mask(glyph), SIZE, argb);
}

fn mask(glyph: Glyph) *const [MASK_LENGTH]u8 {
    return switch (glyph) {
        .titan => &TITAN,
        .freighter => &FREIGHTER,
        .carrier => &CARRIER,
        .dreadnought => &DREADNOUGHT,
        .battleship => &BATTLESHIP,
        .set_destination => &SET_DESTINATION,
        .open_window => &OPEN_WINDOW,
        .jump_range => &JUMP_RANGE,
        .avoid => &AVOID,
        .copy => &COPY,
        .map => &MAP,
        .crosshair => &CROSSHAIR,
        .star => &STAR,
        .off => &OFF,
        .route => &ROUTE,
        .person => &PERSON,
        .group => &GROUP,
    };
}

fn line(comptime points: []const Point) Stroke {
    return .{ .half_width = LINE, .points = points };
}

/// Measured from each pixel's centre, so a line on a whole number covers the two pixels beside it.
fn strokedMask(comptime strokes: []const Stroke) [MASK_LENGTH]u8 {
    @setEvalBranchQuota(1_000_000);
    var coverage_mask: [MASK_LENGTH]u8 = @splat(0);
    for (&coverage_mask, 0..) |*pixel, index| {
        const center: Point = .{ @as(f32, @floatFromInt(index % SIZE)) + 0.5, @as(f32, @floatFromInt(index / SIZE)) + 0.5 };
        var coverage: f32 = 0;
        for (strokes) |stroke| coverage = @max(coverage, strokeCoverage(stroke, center));
        pixel.* = @intFromFloat(@round(coverage * 255));
    }
    return coverage_mask;
}

fn strokeCoverage(stroke: Stroke, point: Point) f32 {
    var distance = distanceToSegment(point, stroke.points[0], stroke.points[0]);
    for (stroke.points[0 .. stroke.points.len - 1], stroke.points[1..]) |from, to| distance = @min(distance, distanceToSegment(point, from, to));
    return std.math.clamp(stroke.half_width + 0.5 - distance, 0, 1);
}

fn distanceToSegment(point: Point, from: Point, to: Point) f32 {
    const delta_x = to[0] - from[0];
    const delta_y = to[1] - from[1];
    const length_squared = delta_x * delta_x + delta_y * delta_y;
    const along = if (length_squared == 0) 0 else std.math.clamp(((point[0] - from[0]) * delta_x + (point[1] - from[1]) * delta_y) / length_squared, 0, 1);
    const offset_x = point[0] - (from[0] + along * delta_x);
    const offset_y = point[1] - (from[1] + along * delta_y);
    return @sqrt(offset_x * offset_x + offset_y * offset_y);
}

/// Clockwise from `start_degrees`, 0 pointing right.
fn arc(comptime center: Point, comptime radius: f32, comptime start_degrees: f32, comptime end_degrees: f32) [ARC_STEPS + 1]Point {
    var points: [ARC_STEPS + 1]Point = undefined;
    for (&points, 0..) |*point, step| {
        const degrees = start_degrees + (end_degrees - start_degrees) * @as(f32, @floatFromInt(step)) / ARC_STEPS;
        point.* = onCircle(center, radius, degrees);
    }
    return points;
}

/// Five points, the first straight up, closed back on itself; a little below CENTER so it looks centred.
fn star(comptime outer_radius: f32, comptime inner_radius: f32) [11]Point {
    var points: [11]Point = undefined;
    for (&points, 0..) |*point, index| {
        const radius = if (index % 2 == 0) outer_radius else inner_radius;
        point.* = onCircle(.{ CENTER[0], CENTER[1] + 0.5 }, radius, -90 + 36 * @as(f32, @floatFromInt(index)));
    }
    return points;
}

fn onCircle(center: Point, radius: f32, degrees: f32) Point {
    const radians = std.math.degreesToRadians(degrees);
    return .{ center[0] + radius * @cos(radians), center[1] + radius * @sin(radians) };
}

const testing = std.testing;

test "a stroke is solid along its line and empty away from it" {
    const across = comptime strokedMask(&.{line(&.{ .{ 2, 8.5 }, .{ 14, 8.5 } })});
    try testing.expectEqual(@as(u8, 255), across[8 * SIZE + 8]);
    try testing.expectEqual(@as(u8, 0), across[4 * SIZE + 8]);
    try testing.expectEqual(@as(u8, 0), across[8 * SIZE + 15]);
}

test "a stroke of one point is a disc" {
    const disc = comptime strokedMask(&.{.{ .half_width = 2, .points = &.{CENTER} }});
    try testing.expectEqual(@as(u8, 255), disc[7 * SIZE + 7]);
    try testing.expectEqual(@as(u8, 0), disc[2 * SIZE + 2]);
}
