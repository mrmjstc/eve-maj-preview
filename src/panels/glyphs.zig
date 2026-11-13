//! The one icon set the dialog, map and panels all draw: strokes on a 16-unit grid, built at any size with the same 1.5px line.
const std = @import("std");
const pixel_buffer = @import("../util/pixel_buffer.zig");

/// The panels' and menus' size, and the grid every glyph is drawn on.
pub const SIZE: i32 = 16;
const GRID: f32 = 16;
/// Half every glyph's 1.5px line, at every size, so all of them weigh the same.
const LINE: f32 = 0.75;
/// A dot never shrinks below this radius, so a small glyph's dots still show.
const MIN_DOT_RADIUS: f32 = 0.9;
/// A circle's sides, enough that none shows as a corner at this size.
const ARC_STEPS = 24;
const CENTER: Point = .{ 8, 8 };
const GLYPH_COUNT = std.enums.values(Glyph).len;
/// A keyboard glyph's keys.
const KEY_RADIUS: f32 = 0.8;

const TITAN = [_]Stroke{
    line(&.{ .{ 3, 8.5 }, .{ 3, 6.5 }, .{ 8, 1.5 }, .{ 13, 6.5 }, .{ 13, 8.5 } }),
    line(&.{ .{ 3, 14.5 }, .{ 3, 12.5 }, .{ 8, 7.5 }, .{ 13, 12.5 }, .{ 13, 14.5 } }),
};
const FREIGHTER = [_]Stroke{
    line(&.{ .{ 2.5, 7.5 }, .{ 2.5, 3 }, .{ 4, 1.5 }, .{ 12, 1.5 }, .{ 13.5, 3 }, .{ 13.5, 7.5 }, .{ 2.5, 7.5 } }),
    line(&.{ .{ 4, 11.5 }, .{ 5.5, 10 }, .{ 10.5, 10 }, .{ 12, 11.5 }, .{ 10.5, 13 }, .{ 5.5, 13 }, .{ 4, 11.5 } }),
};
const CARRIER = [_]Stroke{
    line(&.{ .{ 8, 1.5 }, .{ 13.5, 7.5 }, .{ 8, 13.5 }, .{ 2.5, 7.5 }, .{ 8, 1.5 } }),
};
const DREADNOUGHT = [_]Stroke{
    line(&.{ .{ 8, 2.5 }, .{ 1.5, 8.5 }, .{ 1.5, 11 }, .{ 6, 11 }, .{ 8, 13 }, .{ 10, 11 }, .{ 14.5, 11 }, .{ 14.5, 8.5 }, .{ 8, 2.5 } }),
};
const BATTLESHIP = [_]Stroke{
    line(&.{ .{ 3.5, 13.5 }, .{ 3.5, 6.5 }, .{ 8, 2.5 }, .{ 12.5, 6.5 }, .{ 12.5, 13.5 } }),
    line(&.{ .{ 3.5, 13 }, .{ 8, 8.5 }, .{ 12.5, 13 } }),
};
const SET_DESTINATION = [_]Stroke{
    dot(CENTER, 2),
    line(&.{ .{ 2.5, 5.5 }, .{ 4.5, 8 }, .{ 2.5, 10.5 } }),
    line(&.{ .{ 13.5, 5.5 }, .{ 11.5, 8 }, .{ 13.5, 10.5 } }),
};
const OPEN_WINDOW = [_]Stroke{
    line(&.{ .{ 8, 3 }, .{ 3, 3 }, .{ 3, 13 }, .{ 13, 13 }, .{ 13, 8 } }),
    line(&.{ .{ 8, 8 }, .{ 13.5, 2.5 } }),
    line(&.{ .{ 9.5, 2.5 }, .{ 13.5, 2.5 }, .{ 13.5, 6.5 } }),
};
const JUMP_RANGE = [_]Stroke{
    dot(CENTER, 1.6),
    line(&arc(CENTER, 4.5, 0, 360)),
    line(&arc(CENTER, 7, 140, 220)),
    line(&arc(CENTER, 7, -40, 40)),
};
const AVOID = [_]Stroke{
    line(&arc(CENTER, 5.5, 0, 360)),
    line(&.{ .{ 4.3, 4.3 }, .{ 11.7, 11.7 } }),
};
const COPY = [_]Stroke{
    line(&.{ .{ 3, 10 }, .{ 3, 3 }, .{ 10, 3 } }),
    line(&.{ .{ 7, 7 }, .{ 13, 7 }, .{ 13, 13 }, .{ 7, 13 }, .{ 7, 7 } }),
};
const MAP = [_]Stroke{
    line(&.{ .{ 2, 4 }, .{ 6, 2.5 }, .{ 10, 4 }, .{ 14, 2.5 }, .{ 14, 12 }, .{ 10, 13.5 }, .{ 6, 12 }, .{ 2, 13.5 }, .{ 2, 4 } }),
    line(&.{ .{ 6, 2.5 }, .{ 6, 12 } }),
    line(&.{ .{ 10, 4 }, .{ 10, 13.5 } }),
};
const CROSSHAIR = [_]Stroke{
    line(&arc(CENTER, 5, 0, 360)),
    line(&.{ .{ 8, 1 }, .{ 8, 5 } }),
    line(&.{ .{ 8, 11 }, .{ 8, 15 } }),
    line(&.{ .{ 1, 8 }, .{ 5, 8 } }),
    line(&.{ .{ 11, 8 }, .{ 15, 8 } }),
};
const STAR = [_]Stroke{
    line(&star(6.5, 2.8)),
};
const OFF = [_]Stroke{
    line(&.{ .{ 4, 4 }, .{ 12, 12 } }),
    line(&.{ .{ 12, 4 }, .{ 4, 12 } }),
};
const ROUTE = [_]Stroke{
    dot(.{ 3.5, 12.5 }, 1.5),
    dot(.{ 12.5, 3.5 }, 1.5),
    line(&.{ .{ 3.5, 12.5 }, .{ 3.5, 8 }, .{ 12.5, 8 }, .{ 12.5, 3.5 } }),
};
const PERSON = [_]Stroke{
    line(&arc(.{ 8, 5 }, 2.75, 0, 360)),
    line(&arc(.{ 8, 14.5 }, 5, 180, 360)),
};
const GROUP = [_]Stroke{
    line(&arc(.{ 11, 4 }, 2.25, 0, 360)),
    line(&arc(.{ 11, 11.5 }, 3.5, 250, 360)),
    line(&arc(.{ 5.5, 6.5 }, 2.25, 0, 360)),
    line(&arc(.{ 5.5, 14.5 }, 4, 180, 360)),
};
const CHEVRON_DOWN = [_]Stroke{
    line(&.{ .{ 4.5, 6.5 }, .{ 8, 10 }, .{ 11.5, 6.5 } }),
};
const CHEVRON_UP = [_]Stroke{
    line(&.{ .{ 4.5, 9.5 }, .{ 8, 6 }, .{ 11.5, 9.5 } }),
};
const CHEVRON_RIGHT = [_]Stroke{
    line(&.{ .{ 6.5, 4.5 }, .{ 10, 8 }, .{ 6.5, 11.5 } }),
};
const PIN = [_]Stroke{
    line(&.{ .{ 5, 2 }, .{ 11, 2 } }),
    line(&.{ .{ 6.5, 2 }, .{ 6.5, 6.5 }, .{ 4, 9 }, .{ 12, 9 }, .{ 9.5, 6.5 }, .{ 9.5, 2 } }),
    line(&.{ .{ 8, 9 }, .{ 8, 14 } }),
};
const SPEAKER = [_]Stroke{
    line(&.{ .{ 2, 6 }, .{ 4.5, 6 }, .{ 8, 3 }, .{ 8, 13 }, .{ 4.5, 10 }, .{ 2, 10 }, .{ 2, 6 } }),
    line(&arc(.{ 8, 8 }, 3, -45, 45)),
    line(&arc(.{ 8, 8 }, 5.5, -45, 45)),
};
const MUTED = [_]Stroke{
    line(&.{ .{ 2, 6 }, .{ 4.5, 6 }, .{ 8, 3 }, .{ 8, 13 }, .{ 4.5, 10 }, .{ 2, 10 }, .{ 2, 6 } }),
    line(&.{ .{ 10.5, 6 }, .{ 14.5, 10 } }),
    line(&.{ .{ 14.5, 6 }, .{ 10.5, 10 } }),
};
const MORE = [_]Stroke{
    dot(.{ 3.5, 8 }, 1.4),
    dot(.{ 8, 8 }, 1.4),
    dot(.{ 12.5, 8 }, 1.4),
};
const DELETE = [_]Stroke{
    line(&.{ .{ 2.5, 4.5 }, .{ 13.5, 4.5 } }),
    line(&.{ .{ 6, 4.5 }, .{ 6, 2.5 }, .{ 10, 2.5 }, .{ 10, 4.5 } }),
    line(&.{ .{ 4, 4.5 }, .{ 4.8, 13.5 }, .{ 11.2, 13.5 }, .{ 12, 4.5 } }),
};
const ORE = [_]Stroke{
    line(&.{ .{ 8, 1.8 }, .{ 13.2, 6 }, .{ 8, 14.2 }, .{ 2.8, 6 }, .{ 8, 1.8 } }),
    line(&.{ .{ 2.8, 6 }, .{ 13.2, 6 } }),
};
const ARROW_RIGHT = [_]Stroke{
    line(&.{ .{ 2.5, 8 }, .{ 13, 8 } }),
    line(&.{ .{ 9, 4 }, .{ 13, 8 }, .{ 9, 12 } }),
};
const SPEECH = [_]Stroke{
    line(&.{ .{ 2, 3 }, .{ 14, 3 }, .{ 14, 11 }, .{ 7, 11 }, .{ 4, 13.5 }, .{ 4, 11 }, .{ 2, 11 }, .{ 2, 3 } }),
};
const BELL = [_]Stroke{
    line(&.{ .{ 4, 11 }, .{ 4, 7.5 } }),
    line(&arc(.{ 8, 7.5 }, 4, 180, 360)),
    line(&.{ .{ 12, 7.5 }, .{ 12, 11 }, .{ 13.2, 12.5 }, .{ 2.8, 12.5 }, .{ 4, 11 } }),
    line(&.{ .{ 6.5, 14.5 }, .{ 9.5, 14.5 } }),
};
const GEAR = gear();
const THUMBNAIL = [_]Stroke{
    line(&.{ .{ 2, 3.5 }, .{ 14, 3.5 }, .{ 14, 12.5 }, .{ 2, 12.5 }, .{ 2, 3.5 } }),
};
const LIST = [_]Stroke{
    dot(.{ 3, 4 }, 1),
    dot(.{ 3, 8 }, 1),
    dot(.{ 3, 12 }, 1),
    line(&.{ .{ 6, 4 }, .{ 13.5, 4 } }),
    line(&.{ .{ 6, 8 }, .{ 13.5, 8 } }),
    line(&.{ .{ 6, 12 }, .{ 13.5, 12 } }),
};
const POINTER = [_]Stroke{
    line(&.{ .{ 4, 2.5 }, .{ 4, 13 }, .{ 6.8, 10.3 }, .{ 9, 14 }, .{ 10.8, 13.2 }, .{ 8.7, 9.5 }, .{ 12.3, 9.5 }, .{ 4, 2.5 } }),
};
const KEYBOARD = [_]Stroke{
    line(&.{ .{ 1.5, 4 }, .{ 14.5, 4 }, .{ 14.5, 12 }, .{ 1.5, 12 }, .{ 1.5, 4 } }),
    dot(.{ 4.5, 6.8 }, KEY_RADIUS),
    dot(.{ 7, 6.8 }, KEY_RADIUS),
    dot(.{ 9.5, 6.8 }, KEY_RADIUS),
    dot(.{ 12, 6.8 }, KEY_RADIUS),
    line(&.{ .{ 5, 9.5 }, .{ 11, 9.5 } }),
};
const SPLIT_SQUARE = [_]Stroke{
    line(&.{ .{ 2.5, 2.5 }, .{ 13.5, 2.5 }, .{ 13.5, 13.5 }, .{ 2.5, 13.5 }, .{ 2.5, 2.5 } }),
    line(&.{ .{ 8, 2.5 }, .{ 8, 13.5 } }),
};
const ENVELOPE = [_]Stroke{
    line(&.{ .{ 2, 3.5 }, .{ 14, 3.5 }, .{ 14, 12.5 }, .{ 2, 12.5 }, .{ 2, 3.5 } }),
    line(&.{ .{ 2, 3.5 }, .{ 8, 8.5 }, .{ 14, 3.5 } }),
};
const PICKAXE = [_]Stroke{
    line(&.{ .{ 3.5, 3.5 }, .{ 7, 2.8 }, .{ 10, 3.4 }, .{ 12.6, 6 }, .{ 13.2, 9 }, .{ 12.5, 12.5 } }),
    line(&.{ .{ 10, 6 }, .{ 2.5, 13.5 } }),
};
const TILES = [_]Stroke{
    line(&.{ .{ 2.5, 2.5 }, .{ 6.5, 2.5 }, .{ 6.5, 6.5 }, .{ 2.5, 6.5 }, .{ 2.5, 2.5 } }),
    line(&.{ .{ 9.5, 2.5 }, .{ 13.5, 2.5 }, .{ 13.5, 6.5 }, .{ 9.5, 6.5 }, .{ 9.5, 2.5 } }),
    line(&.{ .{ 2.5, 9.5 }, .{ 6.5, 9.5 }, .{ 6.5, 13.5 }, .{ 2.5, 13.5 }, .{ 2.5, 9.5 } }),
    line(&.{ .{ 9.5, 9.5 }, .{ 13.5, 9.5 }, .{ 13.5, 13.5 }, .{ 9.5, 13.5 }, .{ 9.5, 9.5 } }),
};
const CLOCK = [_]Stroke{
    line(&arc(CENTER, 5.75, 0, 360)),
    line(&.{ .{ 8, 4.5 }, .{ 8, 8 }, .{ 10.5, 9.5 } }),
};
const ADD = [_]Stroke{
    line(&.{ .{ 8, 3 }, .{ 8, 13 } }),
    line(&.{ .{ 3, 8 }, .{ 13, 8 } }),
};
const MINUS = [_]Stroke{
    line(&.{ .{ 3, 8 }, .{ 13, 8 } }),
};
/// Four corners, as a frame the map is fitted back into.
const FIT = [_]Stroke{
    line(&.{ .{ 3, 6 }, .{ 3, 3 }, .{ 6, 3 } }),
    line(&.{ .{ 10, 3 }, .{ 13, 3 }, .{ 13, 6 } }),
    line(&.{ .{ 13, 10 }, .{ 13, 13 }, .{ 10, 13 } }),
    line(&.{ .{ 6, 13 }, .{ 3, 13 }, .{ 3, 10 } }),
};
const SEARCH = [_]Stroke{
    line(&arc(.{ 7, 7 }, 4.25, 0, 360)),
    line(&.{ .{ 10.2, 10.2 }, .{ 13.5, 13.5 } }),
};
/// Two sheets, one above the other, as the Layers menu stacks what it shows.
const LAYERS = [_]Stroke{
    line(&.{ .{ 8, 3 }, .{ 14, 6 }, .{ 8, 9 }, .{ 2, 6 }, .{ 8, 3 } }),
    line(&.{ .{ 2, 9.5 }, .{ 8, 12.5 }, .{ 14, 9.5 } }),
};
const RESET = [_]Stroke{
    line(&arc(CENTER, 6, 180, -135)),
    line(&.{ .{ 2, 2.5 }, .{ 2, 5.5 }, .{ 5, 5.5 } }),
};
const REFRESH = [_]Stroke{
    line(&arc(CENTER, 6, 0, 315)),
    line(&.{ .{ 14, 2.5 }, .{ 14, 5.5 }, .{ 11, 5.5 } }),
};
const IMPORT = [_]Stroke{
    line(&.{ .{ 8, 2.5 }, .{ 8, 10 } }),
    line(&.{ .{ 4.5, 6.5 }, .{ 8, 10 }, .{ 11.5, 6.5 } }),
    line(&.{ .{ 2.5, 10.5 }, .{ 2.5, 13.5 }, .{ 13.5, 13.5 }, .{ 13.5, 10.5 } }),
};
const PENCIL = [_]Stroke{
    line(&.{ .{ 11, 2.5 }, .{ 13.5, 5 }, .{ 5, 13.5 }, .{ 2.5, 13.5 }, .{ 2.5, 11 }, .{ 11, 2.5 } }),
    line(&.{ .{ 9.5, 4 }, .{ 12, 6.5 } }),
};
const GRIP = [_]Stroke{
    dot(.{ 6, 4 }, 1.1),
    dot(.{ 10, 4 }, 1.1),
    dot(.{ 6, 8 }, 1.1),
    dot(.{ 10, 8 }, 1.1),
    dot(.{ 6, 12 }, 1.1),
    dot(.{ 10, 12 }, 1.1),
};
const CHECK = [_]Stroke{
    line(&.{ .{ 3, 8.5 }, .{ 6.5, 12 }, .{ 13, 4.5 } }),
};
const INFO = [_]Stroke{
    line(&arc(CENTER, 5.75, 0, 360)),
    dot(.{ 8, 5.25 }, 1),
    line(&.{ .{ 8, 7.5 }, .{ 8, 11 } }),
};

/// Ships by their overview bracket, then actions and controls, then what a row is.
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
    chevron_down,
    chevron_up,
    chevron_right,
    pin,
    speaker,
    muted,
    more,
    delete,
    ore,
    arrow_right,
    speech,
    bell,
    gear,
    thumbnail,
    list,
    pointer,
    keyboard,
    split_square,
    envelope,
    pickaxe,
    tiles,
    clock,
    add,
    minus,
    fit,
    search,
    layers,
    reset,
    refresh,
    import,
    pencil,
    grip,
    check,
    info,
};

/// A point on the 16-unit grid, x then y, from its corner.
const Point = [2]f32;

/// Lines joining `points`; a single point is a dot of radius `half_width`, which scales with the glyph where a line's width doesn't.
const Stroke = struct {
    half_width: f32,
    points: []const Point,
};

/// At SIZE pixels, `left` and `top` its corner; clipped to the canvas.
pub fn draw(canvas: pixel_buffer.Canvas, glyph: Glyph, left: i32, top: i32, argb: u32) void {
    drawSized(canvas, glyph, @intCast(SIZE), left, top, argb);
}

/// At `size` pixels square, its line as thick as at any other size.
pub fn drawSized(canvas: pixel_buffer.Canvas, glyph: Glyph, comptime size: usize, left: i32, top: i32, argb: u32) void {
    pixel_buffer.fillCoverage(canvas, left, top, mask(glyph, size), @intCast(size), argb);
}

/// `size` by `size` coverage, row by row, for drawing a glyph outside a panel.
pub fn mask(glyph: Glyph, comptime size: usize) *const [size * size]u8 {
    return &Masks(size).all[@backingInt(glyph)];
}

/// Every glyph at `size`, built once at compile time.
fn Masks(comptime size: usize) type {
    return struct {
        const all = build();

        fn build() [GLYPH_COUNT][size * size]u8 {
            @setEvalBranchQuota(100_000_000);
            var masks: [GLYPH_COUNT][size * size]u8 = undefined;
            for (std.enums.values(Glyph), &masks) |glyph, *out| out.* = strokedMask(size, strokesOf(glyph));
            return masks;
        }
    };
}

fn strokesOf(glyph: Glyph) []const Stroke {
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
        .chevron_down => &CHEVRON_DOWN,
        .chevron_up => &CHEVRON_UP,
        .chevron_right => &CHEVRON_RIGHT,
        .pin => &PIN,
        .speaker => &SPEAKER,
        .muted => &MUTED,
        .more => &MORE,
        .delete => &DELETE,
        .ore => &ORE,
        .arrow_right => &ARROW_RIGHT,
        .speech => &SPEECH,
        .bell => &BELL,
        .gear => &GEAR,
        .thumbnail => &THUMBNAIL,
        .list => &LIST,
        .pointer => &POINTER,
        .keyboard => &KEYBOARD,
        .split_square => &SPLIT_SQUARE,
        .envelope => &ENVELOPE,
        .pickaxe => &PICKAXE,
        .tiles => &TILES,
        .clock => &CLOCK,
        .add => &ADD,
        .minus => &MINUS,
        .fit => &FIT,
        .search => &SEARCH,
        .layers => &LAYERS,
        .reset => &RESET,
        .refresh => &REFRESH,
        .import => &IMPORT,
        .pencil => &PENCIL,
        .grip => &GRIP,
        .check => &CHECK,
        .info => &INFO,
    };
}

fn line(comptime points: []const Point) Stroke {
    return .{ .half_width = LINE, .points = points };
}

fn dot(comptime center: Point, comptime radius: f32) Stroke {
    return .{ .half_width = radius, .points = &.{center} };
}

/// A hub and its rim, with six teeth out from the rim.
fn gear() [8]Stroke {
    var strokes: [8]Stroke = undefined;
    strokes[0] = line(&arc(CENTER, 1.8, 0, 360));
    strokes[1] = line(&arc(CENTER, 4.4, 0, 360));
    for (strokes[2..], 0..) |*tooth, index| {
        const degrees = 30 + 60 * @as(f32, @floatFromInt(index));
        const points = [_]Point{ onCircle(CENTER, 4.4, degrees), onCircle(CENTER, 6.8, degrees) };
        tooth.* = line(&points);
    }
    return strokes;
}

/// Measured from each pixel's centre on the grid scaled to `size`, so a line on a whole number covers the two pixels beside it.
fn strokedMask(comptime size: usize, comptime strokes: []const Stroke) [size * size]u8 {
    @setEvalBranchQuota(10_000_000);
    const scale = @as(f32, @floatFromInt(size)) / GRID;
    var coverage_mask: [size * size]u8 = @splat(0);
    for (&coverage_mask, 0..) |*pixel, index| {
        // Back onto the grid, where the strokes are.
        const center: Point = .{ (@as(f32, @floatFromInt(index % size)) + 0.5) / scale, (@as(f32, @floatFromInt(index / size)) + 0.5) / scale };
        var coverage: f32 = 0;
        for (strokes) |stroke| coverage = @max(coverage, strokeCoverage(stroke, center, scale));
        pixel.* = @intFromFloat(@round(coverage * 255));
    }
    return coverage_mask;
}

/// In pixels: a line keeps its width at any `scale`, and a dot scales with the glyph.
fn strokeCoverage(stroke: Stroke, point: Point, scale: f32) f32 {
    var distance = distanceToSegment(point, stroke.points[0], stroke.points[0]);
    for (stroke.points[0 .. stroke.points.len - 1], stroke.points[1..]) |from, to| distance = @min(distance, distanceToSegment(point, from, to));
    const half_width = if (stroke.points.len == 1) @max(MIN_DOT_RADIUS, stroke.half_width * scale) else stroke.half_width;
    return std.math.clamp(half_width + 0.5 - distance * scale, 0, 1);
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

/// From `start_degrees` to `end_degrees`, either way round, 0 pointing right and 90 down.
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
    const across = comptime strokedMask(16, &.{line(&.{ .{ 2, 8.5 }, .{ 14, 8.5 } })});
    try testing.expectEqual(@as(u8, 255), across[8 * 16 + 8]);
    try testing.expectEqual(@as(u8, 0), across[4 * 16 + 8]);
    try testing.expectEqual(@as(u8, 0), across[8 * 16 + 15]);
}

test "a stroke of one point is a dot" {
    const disc = comptime strokedMask(16, &.{dot(CENTER, 2)});
    try testing.expectEqual(@as(u8, 255), disc[7 * 16 + 7]);
    try testing.expectEqual(@as(u8, 0), disc[2 * 16 + 2]);
}

test "a line keeps its weight in a smaller glyph" {
    const full = comptime strokedMask(16, &.{line(&.{ .{ 8.5, 2 }, .{ 8.5, 14 } })});
    const small = comptime strokedMask(12, &.{line(&.{ .{ 8.5, 2 }, .{ 8.5, 14 } })});
    var full_ink: u32 = 0;
    for (full[8 * 16 ..][0..16]) |coverage| full_ink += coverage;
    var small_ink: u32 = 0;
    for (small[6 * 12 ..][0..12]) |coverage| small_ink += coverage;
    try testing.expect(small_ink * 10 >= full_ink * 9);
}
