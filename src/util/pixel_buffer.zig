//! Drawing rects, lines and circles in a raw 0xAARRGGBB pixel buffer, and fixing GDI text's alpha; no I/O.
const std = @import("std");

/// A Mask's steps to the pixel, which caps how deep it can tell apart at about 16 pixels.
const MASK_DEPTH_STEPS: f32 = 16;

/// A `width` x `height` buffer of 0xAARRGGBB pixels, rows packed with no padding.
pub const Canvas = struct {
    /// Borrowed.
    pixels: [*]u32,
    width: usize,
    height: usize,
};

/// A shape built up from discs and bands and then painted as one, so its overlaps don't darken as separate fills would.
pub const Mask = struct {
    allocator: std.mem.Allocator,
    /// By pixel, rows packed, how far in from half a pixel outside the edge in MASK_DEPTH_STEPS, 0 being outside; owned, freed in deinit.
    depth: []u8,
    width: usize,
    height: usize,
    /// The rows touched, so clearing and painting skip the rest.
    top: usize,
    bottom: usize = 0,
    /// The rightmost pixel touched, one past it; empty while 0.
    right: usize = 0,
    /// Each row's touched pixels, so shapes far apart don't have the gap between them scanned; owned, freed in deinit.
    row_spans: []RowSpan,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Mask {
        const depth = try allocator.alloc(u8, width * height);
        errdefer allocator.free(depth);
        @memset(depth, 0);
        const row_spans = try allocator.alloc(RowSpan, height);
        @memset(row_spans, RowSpan.empty);
        return .{ .allocator = allocator, .depth = depth, .width = width, .height = height, .top = height, .row_spans = row_spans };
    }

    pub fn deinit(self: *Mask) void {
        self.allocator.free(self.depth);
        self.allocator.free(self.row_spans);
    }

    pub fn clear(self: *Mask) void {
        if (self.isEmpty()) return;
        for (self.top..self.bottom) |pixel_y| {
            const row = &self.row_spans[pixel_y];
            @memset(self.depth[pixel_y * self.width + row.start .. pixel_y * self.width + row.end], 0);
            row.* = .empty;
        }
        self.top = self.height;
        self.right = 0;
        self.bottom = 0;
    }

    /// Empty, its bounds run backwards, so they can't be looped over.
    fn isEmpty(self: *const Mask) bool {
        return self.right == 0;
    }

    /// Anti-aliased as fillCircle, and clipped to the mask.
    pub fn addDisc(self: *Mask, center_x: i32, center_y: i32, radius: f32) void {
        self.addBand(center_x, center_y, center_x, center_y, radius);
    }

    /// Everything within `radius` of the line, measured to it so a straight side stays straight.
    pub fn addBand(self: *Mask, from_x: i32, from_y: i32, to_x: i32, to_y: i32, radius: f32) void {
        const line: BandLine = .{ .start_x = @floatFromInt(from_x), .start_y = @floatFromInt(from_y), .delta_x = @floatFromInt(to_x - from_x), .delta_y = @floatFromInt(to_y - from_y) };
        const length_squared = line.delta_x * line.delta_x + line.delta_y * line.delta_y;
        const reach: i32 = @intFromFloat(@ceil(radius + 1));
        // From here out a pixel's depth is 0, so it needn't be measured.
        const outside_squared = (radius + 0.5) * (radius + 0.5);

        for (clampedTo(@min(from_y, to_y) - reach, self.height)..clampedTo(@max(from_y, to_y) + reach + 1, self.height)) |pixel_y| {
            const y: f32 = @floatFromInt(pixel_y);
            const span = self.rowSpan(line, y, reach);
            if (span.end <= span.start) continue;
            for (span.start..span.end) |pixel_x| {
                const depth = &self.depth[pixel_y * self.width + pixel_x];
                if (depth.* == 255) continue;
                const x: f32 = @floatFromInt(pixel_x);
                const along = if (length_squared == 0) 0 else std.math.clamp(((x - line.start_x) * line.delta_x + (y - line.start_y) * line.delta_y) / length_squared, 0, 1);
                const offset_x = x - (line.start_x + along * line.delta_x);
                const offset_y = y - (line.start_y + along * line.delta_y);
                const distance_squared = offset_x * offset_x + offset_y * offset_y;
                if (distance_squared >= outside_squared) continue;
                const steps = std.math.clamp((radius + 0.5 - @sqrt(distance_squared)) * MASK_DEPTH_STEPS, 0, 255);
                depth.* = @max(depth.*, @as(u8, @intFromFloat(steps)));
            }
            self.includeRow(pixel_y, span);
        }
    }

    fn includeRow(self: *Mask, pixel_y: usize, span: RowSpan) void {
        const row = &self.row_spans[pixel_y];
        row.* = if (row.end == 0) span else .{ .start = @min(row.start, span.start), .end = @max(row.end, span.end) };
        self.top = @min(self.top, pixel_y);
        self.right = @max(self.right, span.end);
        self.bottom = @max(self.bottom, pixel_y + 1);
    }

    /// Which pixels of the row at `y` a band can touch, so a long diagonal doesn't measure its whole bounding box.
    fn rowSpan(self: *const Mask, line: BandLine, y: f32, reach: i32) RowSpan {
        const margin: f32 = @floatFromInt(reach);
        const first = if (line.delta_y == 0) 0 else std.math.clamp((y - margin - line.start_y) / line.delta_y, 0, 1);
        const last = if (line.delta_y == 0) 1 else std.math.clamp((y + margin - line.start_y) / line.delta_y, 0, 1);
        const first_x = line.start_x + first * line.delta_x;
        const last_x = line.start_x + last * line.delta_x;
        return .{
            .start = clampedTo(@intFromFloat(@floor(@min(first_x, last_x)) - margin), self.width),
            .end = clampedTo(@intFromFloat(@ceil(@max(first_x, last_x)) + margin + 1), self.width),
        };
    }
};

/// The line down a band's middle.
const BandLine = struct { start_x: f32, start_y: f32, delta_x: f32, delta_y: f32 };

/// Pixels `start` up to `end` of a row.
const RowSpan = struct {
    start: usize,
    end: usize,

    const empty: RowSpan = .{ .start = 0, .end = 0 };
};

/// A rect's part inside a pixel buffer, and how thick its outline can be.
const ClippedRect = struct { left: usize, top: usize, right: usize, bottom: usize, thickness: usize };

/// GDI text leaves alpha at 0, so non-black pixels still at 0 become opaque; alpha other drawing set is kept.
pub fn fixTextAlphaRect(canvas: Canvas, x: i32, y: i32, rect_width: usize, rect_height: usize) void {
    const width = canvas.width;
    const start_x: usize = @intCast(@max(0, x));
    const start_y: usize = @intCast(@max(0, y));
    const end_x = @min(start_x + rect_width, width);
    const end_y = @min(start_y + rect_height, canvas.height);
    if (end_x <= start_x or end_y <= start_y) return;

    for (start_y..end_y) |pixel_y| {
        const row = canvas.pixels[pixel_y * width + start_x .. pixel_y * width + end_x];
        for (row) |*pixel| {
            const value = pixel.*;
            if ((value >> 24) == 0 and (value & 0x00FF_FFFF) != 0) {
                pixel.* = value | 0xFF00_0000;
            }
        }
    }
}

pub fn fixTextAlpha(canvas: Canvas) void {
    fixTextAlphaRect(canvas, 0, 0, canvas.width, canvas.height);
}

/// No-ops if the rect would overrun the buffer's row width or its height.
pub fn fillRect(canvas: Canvas, x: usize, y: usize, rect_width: usize, rect_height: usize, argb: u32) void {
    const width = canvas.width;
    const end_y = y + rect_height;
    const end_x = x + rect_width;
    if (end_x > width or end_y > canvas.height) return;
    for (y..end_y) |pixel_y| {
        @memset(canvas.pixels[pixel_y * width + x .. pixel_y * width + end_x], argb);
    }
}

/// Corners anti-aliased as fillCircle; no-ops if the rect would overrun the buffer's row width.
pub fn fillRoundedRect(canvas: Canvas, x: usize, y: usize, rect_width: usize, rect_height: usize, radius: usize, argb: u32) void {
    if (x + rect_width > canvas.width) return;
    const corner_radius = @min(radius, @min(rect_width, rect_height) / 2);
    const arc_radius: f32 = @floatFromInt(corner_radius);
    for (0..rect_height) |row| {
        const from_edge = @min(row, rect_height - 1 - row);
        if (from_edge >= corner_radius) {
            fillRect(canvas, x, y + row, rect_width, 1, argb);
            continue;
        }
        fillRect(canvas, x + corner_radius, y + row, rect_width - 2 * corner_radius, 1, argb);
        const offset_y = arc_radius - @as(f32, @floatFromInt(from_edge)) - 0.5;
        for (0..corner_radius) |column| {
            // From the corner arc's centre to this pixel's centre.
            const offset_x = arc_radius - @as(f32, @floatFromInt(column)) - 0.5;
            const coverage = std.math.clamp(arc_radius + 0.5 - @sqrt(offset_x * offset_x + offset_y * offset_y), 0, 1);
            blendPixel(canvas, @intCast(x + column), @intCast(y + row), argb, coverage);
            blendPixel(canvas, @intCast(x + rect_width - 1 - column), @intCast(y + row), argb, coverage);
        }
    }
}

/// A rect starting off the canvas is moved onto its edge, not clipped.
pub fn drawRectOutline(canvas: Canvas, x: i32, y: i32, rect_width: usize, rect_height: usize, thickness: usize, color: u32) void {
    const clipped = clipToCanvas(canvas, x, y, rect_width, rect_height, thickness) orelse return;
    const line = clipped.thickness;
    fillRect(canvas, clipped.left, clipped.top, clipped.right - clipped.left, line, color);
    fillRect(canvas, clipped.left, clipped.bottom - line, clipped.right - clipped.left, line, color);
    fillRect(canvas, clipped.left, clipped.top, line, clipped.bottom - clipped.top, color);
    fillRect(canvas, clipped.right - line, clipped.top, line, clipped.bottom - clipped.top, color);
}

/// Like drawRectOutline, in `dash`-px dashes with gaps as long, each side starting from its top or left corner.
pub fn drawDashedRectOutline(canvas: Canvas, x: i32, y: i32, rect_width: usize, rect_height: usize, thickness: usize, dash: usize, color: u32) void {
    if (dash == 0) return;
    const clipped = clipToCanvas(canvas, x, y, rect_width, rect_height, thickness) orelse return;
    const line = clipped.thickness;
    var pixel_x = clipped.left;
    while (pixel_x < clipped.right) : (pixel_x += 2 * dash) {
        const run = @min(dash, clipped.right - pixel_x);
        fillRect(canvas, pixel_x, clipped.top, run, line, color);
        fillRect(canvas, pixel_x, clipped.bottom - line, run, line, color);
    }
    var pixel_y = clipped.top;
    while (pixel_y < clipped.bottom) : (pixel_y += 2 * dash) {
        const run = @min(dash, clipped.bottom - pixel_y);
        fillRect(canvas, clipped.left, pixel_y, line, run, color);
        fillRect(canvas, clipped.right - line, pixel_y, line, run, color);
    }
}

/// A 1px border round the whole canvas with `radius` rounded corners; outside them the pixels are cleared so the desktop shows through.
pub fn drawRoundedFrame(canvas: Canvas, radius: usize, argb: u32) void {
    const pixels = canvas.pixels;
    const width = canvas.width;
    const height = canvas.height;
    fillRect(canvas, 0, 0, width, 1, argb);
    fillRect(canvas, 0, height - 1, width, 1, argb);
    fillRect(canvas, 0, 0, 1, height, argb);
    fillRect(canvas, width - 1, 0, 1, height, argb);
    if (width < 2 * radius or height < 2 * radius) return;

    const arc_radius: f32 = @floatFromInt(radius);
    for (0..radius) |row| {
        for (0..radius) |column| {
            // From the corner arc's centre to this pixel's centre.
            const offset_x = arc_radius - @as(f32, @floatFromInt(column)) - 0.5;
            const offset_y = arc_radius - @as(f32, @floatFromInt(row)) - 0.5;
            const distance = @sqrt(offset_x * offset_x + offset_y * offset_y);
            const pixel: u32 = if (distance > arc_radius) 0 else if (distance > arc_radius - 1) argb else continue;
            pixels[row * width + column] = pixel;
            pixels[row * width + width - 1 - column] = pixel;
            pixels[(height - 1 - row) * width + column] = pixel;
            pixels[(height - 1 - row) * width + width - 1 - column] = pixel;
        }
    }
}

/// Anti-aliased, and clipped to the canvas; only the stretch over it is walked, as a zoomed map runs gates far off it.
pub fn drawLine(canvas: Canvas, from_x: i32, from_y: i32, to_x: i32, to_y: i32, argb: u32) void {
    const is_steep = @abs(to_y - from_y) > @abs(to_x - from_x);
    var start_major = if (is_steep) from_y else from_x;
    var start_minor = if (is_steep) from_x else from_y;
    var end_major = if (is_steep) to_y else to_x;
    var end_minor = if (is_steep) to_x else to_y;
    if (start_major > end_major) {
        std.mem.swap(i32, &start_major, &end_major);
        std.mem.swap(i32, &start_minor, &end_minor);
    }
    const major_limit: i32 = @intCast(if (is_steep) canvas.height else canvas.width);
    const minor_limit: i32 = @intCast(if (is_steep) canvas.width else canvas.height);
    // Each step also touches the pixel after its own, so a line one short of the edge still shows.
    if (@max(start_minor, end_minor) < -1 or @min(start_minor, end_minor) >= minor_limit) return;

    const length = end_major - start_major;
    const gradient: f32 = if (length == 0) 0 else @as(f32, @floatFromInt(end_minor - start_minor)) / @as(f32, @floatFromInt(length));
    var major = @max(start_major, 0);
    while (major <= @min(end_major, major_limit - 1)) : (major += 1) {
        const minor = @as(f32, @floatFromInt(start_minor)) + gradient * @as(f32, @floatFromInt(major - start_major));
        const floor = @floor(minor);
        const whole: i32 = @intFromFloat(floor);
        const fraction = minor - floor;
        blendPixel(canvas, if (is_steep) whole else major, if (is_steep) major else whole, argb, 1 - fraction);
        blendPixel(canvas, if (is_steep) whole + 1 else major, if (is_steep) major else whole + 1, argb, fraction);
    }
}

/// Anti-aliased, and clipped to the canvas. `argb`'s alpha fades the whole disc.
pub fn fillCircle(canvas: Canvas, center_x: i32, center_y: i32, radius: f32, argb: u32) void {
    drawRing(canvas, center_x, center_y, radius, radius + 1, argb);
}

/// A band `thickness` wide inside `radius`, anti-aliased as fillCircle.
pub fn drawRing(canvas: Canvas, center_x: i32, center_y: i32, radius: f32, thickness: f32, argb: u32) void {
    const reach: i32 = @intFromFloat(@ceil(radius + 1));
    const last_x: i32 = @as(i32, @intCast(canvas.width)) - 1 - center_x;
    const last_y: i32 = @as(i32, @intCast(canvas.height)) - 1 - center_y;
    var delta_y: i32 = @max(-reach, -center_y);
    while (delta_y <= @min(reach, last_y)) : (delta_y += 1) {
        var delta_x: i32 = @max(-reach, -center_x);
        while (delta_x <= @min(reach, last_x)) : (delta_x += 1) {
            const distance = @sqrt(@as(f32, @floatFromInt(delta_x * delta_x + delta_y * delta_y)));
            const outer = std.math.clamp(radius + 0.5 - distance, 0, 1);
            const inner = std.math.clamp(distance - (radius - thickness) + 0.5, 0, 1);
            blendPixel(canvas, center_x + delta_x, center_y + delta_y, argb, outer * inner);
        }
    }
}

/// `mask` must be the canvas's size.
pub fn fillMask(canvas: Canvas, mask: *const Mask, argb: u32) void {
    if (mask.isEmpty()) return;
    for (mask.top..mask.bottom) |pixel_y| {
        const row = mask.row_spans[pixel_y];
        for (row.start..row.end) |pixel_x| {
            const steps = mask.depth[pixel_y * mask.width + pixel_x];
            if (steps == 0) continue;
            const depth: f32 = @as(f32, @floatFromInt(steps)) / MASK_DEPTH_STEPS;
            blendPixel(canvas, @intCast(pixel_x), @intCast(pixel_y), argb, @min(depth, 1));
        }
    }
}

/// A band `thickness` wide inside the shape's edge, anti-aliased on both sides; a shape the canvas cuts off isn't outlined there. `mask` must be the canvas's size.
pub fn outlineMask(canvas: Canvas, mask: *const Mask, thickness: f32, argb: u32) void {
    if (mask.isEmpty()) return;
    for (mask.top..mask.bottom) |pixel_y| {
        const row = mask.row_spans[pixel_y];
        for (row.start..row.end) |pixel_x| {
            const steps = mask.depth[pixel_y * mask.width + pixel_x];
            if (steps == 0) continue;
            const depth: f32 = @as(f32, @floatFromInt(steps)) / MASK_DEPTH_STEPS;
            const band = @min(depth, 1) * std.math.clamp(thickness + 1 - depth, 0, 1);
            if (band > 0) blendPixel(canvas, @intCast(pixel_x), @intCast(pixel_y), argb, band);
        }
    }
}

/// Over a premultiplied pixel, so it suits a transparent overlay as well as an opaque canvas; `coverage` is 0 to 1, on top of `argb`'s own alpha.
fn blendPixel(canvas: Canvas, x: i32, y: i32, argb: u32, coverage: f32) void {
    if (x < 0 or y < 0) return;
    const pixel_x: usize = @intCast(x);
    const pixel_y: usize = @intCast(y);
    if (pixel_x >= canvas.width or pixel_y >= canvas.height) return;
    // In 255ths from here, as whole numbers blend faster than floats; +127 rounds each division.
    const alpha: u32 = @intFromFloat(@round(std.math.clamp(coverage, 0, 1) * @as(f32, @floatFromInt(argb >> 24))));
    if (alpha == 0) return;

    const pixel = &canvas.pixels[pixel_y * canvas.width + pixel_x];
    const under_alpha = pixel.* >> 24;
    var blended: u32 = (under_alpha + ((255 - under_alpha) * alpha + 127) / 255) << 24;
    inline for (.{ 16, 8, 0 }) |shift| {
        const over = (argb >> shift) & 0xFF;
        const under = (pixel.* >> shift) & 0xFF;
        blended |= ((over * alpha + under * (255 - alpha) + 127) / 255) << shift;
    }
    pixel.* = blended;
}

fn clampedTo(value: i32, limit: usize) usize {
    return @intCast(std.math.clamp(value, 0, @as(i32, @intCast(limit))));
}

/// Null when nothing of the rect is inside the canvas.
fn clipToCanvas(canvas: Canvas, x: i32, y: i32, rect_width: usize, rect_height: usize, thickness: usize) ?ClippedRect {
    const left: usize = @intCast(std.math.clamp(x, 0, @as(i32, @intCast(canvas.width))));
    const top: usize = @intCast(std.math.clamp(y, 0, @as(i32, @intCast(canvas.height))));
    const right = @min(canvas.width, left + rect_width);
    const bottom = @min(canvas.height, top + rect_height);
    if (right <= left or bottom <= top) return null;
    return .{ .left = left, .top = top, .right = right, .bottom = bottom, .thickness = @min(thickness, @min(right - left, bottom - top)) };
}

const testing = std.testing;

test "fillRect fills only its rect and skips one that would overrun" {
    var buffer: [4 * 3]u32 = @splat(0);
    const canvas: Canvas = .{ .pixels = &buffer, .width = 4, .height = 3 };
    fillRect(canvas, 1, 1, 2, 1, 7);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0, 0, 7, 7, 0, 0, 0, 0, 0 }, &buffer);
    fillRect(canvas, 3, 0, 2, 1, 9);
    try testing.expectEqual(@as(u32, 0), buffer[3]);
}

test "fillRoundedRect softens its corners alike and fills its middle" {
    var buffer: [6 * 6]u32 = @splat(0xFF000000);
    fillRoundedRect(.{ .pixels = &buffer, .width = 6, .height = 6 }, 0, 0, 6, 6, 3, 0xFFFFFFFF);
    try testing.expectEqual(@as(u32, 0xFF000000), buffer[0]);
    try testing.expect(buffer[1] != 0xFF000000 and buffer[1] != 0xFFFFFFFF);
    try testing.expectEqual(buffer[1], buffer[4]);
    try testing.expectEqual(buffer[1], buffer[5 * 6 + 1]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), buffer[3 * 6 + 3]);
}

test "fillRoundedRect skips a rect that would overrun the row" {
    var buffer: [4 * 4]u32 = @splat(0xFF000000);
    fillRoundedRect(.{ .pixels = &buffer, .width = 4, .height = 4 }, 2, 0, 4, 4, 1, 0xFFFFFFFF);
    for (buffer) |pixel| try testing.expectEqual(@as(u32, 0xFF000000), pixel);
}

test "drawRectOutline moves a rect starting off the buffer onto its edge" {
    var buffer: [4 * 4]u32 = @splat(0);
    drawRectOutline(.{ .pixels = &buffer, .width = 4, .height = 4 }, -1, -1, 3, 3, 1, 5);
    try testing.expectEqualSlices(u32, &.{ 5, 5, 5, 0, 5, 0, 5, 0, 5, 5, 5, 0, 0, 0, 0, 0 }, &buffer);
}

test "fixTextAlphaRect makes drawn text opaque without touching blank or already-set pixels" {
    var buffer = [_]u32{ 0x00000000, 0x00123456, 0x80123456 };
    fixTextAlphaRect(.{ .pixels = &buffer, .width = 3, .height = 1 }, 0, 0, 3, 1);
    try testing.expectEqualSlices(u32, &.{ 0x00000000, 0xFF123456, 0x80123456 }, &buffer);
}

test "drawLine lands exactly on a straight run and stays inside the canvas" {
    var buffer: [4 * 3]u32 = @splat(0xFF000000);
    const canvas: Canvas = .{ .pixels = &buffer, .width = 4, .height = 3 };
    drawLine(canvas, -2, 1, 9, 1, 0xFFFFFFFF);
    try testing.expectEqualSlices(u32, &.{ 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF }, buffer[4..8]);
    try testing.expectEqual(@as(u32, 0xFF000000), buffer[0]);
    try testing.expectEqual(@as(u32, 0xFF000000), buffer[8]);
}

test "drawLine splits a diagonal step's coverage between two pixels" {
    var buffer: [3 * 3]u32 = @splat(0xFF000000);
    drawLine(.{ .pixels = &buffer, .width = 3, .height = 3 }, 0, 0, 2, 1, 0xFFFFFFFF);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), buffer[0]);
    try testing.expectEqual(@as(u32, 0xFF808080), buffer[1]);
    try testing.expectEqual(@as(u32, 0xFF808080), buffer[3 + 1]);
}

test "fillCircle fills its centre, leaves its corners and clips at the edge" {
    var buffer: [9 * 9]u32 = @splat(0xFF000000);
    const canvas: Canvas = .{ .pixels = &buffer, .width = 9, .height = 9 };
    fillCircle(canvas, 4, 4, 3, 0xFFFFFFFF);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), buffer[4 * 9 + 4]);
    try testing.expectEqual(@as(u32, 0xFF000000), buffer[0]);
    fillCircle(canvas, -1, -1, 2, 0xFFFFFFFF);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), buffer[0]);
}

test "drawing over a transparent pixel leaves it as see-through as the colour" {
    var buffer = [_]u32{0};
    fillCircle(.{ .pixels = &buffer, .width = 1, .height = 1 }, 0, 0, 2, 0x80FFFFFF);
    try testing.expectEqual(@as(u32, 0x80808080), buffer[0]);
}

test "drawRing leaves the middle untouched" {
    var buffer: [11 * 11]u32 = @splat(0xFF000000);
    drawRing(.{ .pixels = &buffer, .width = 11, .height = 11 }, 5, 5, 4, 2, 0xFFFFFFFF);
    try testing.expectEqual(@as(u32, 0xFF000000), buffer[5 * 11 + 5]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), buffer[5 * 11 + 8]);
}

test "a translucent colour blends with what's under it" {
    var buffer = [_]u32{0xFF000000};
    fillCircle(.{ .pixels = &buffer, .width = 1, .height = 1 }, 0, 0, 2, 0x80FFFFFF);
    try testing.expectEqual(@as(u32, 0xFF808080), buffer[0]);
}

test "overlapping discs in a mask paint no darker than one" {
    var mask: Mask = try .init(testing.allocator, 12, 7);
    defer mask.deinit();
    mask.addDisc(4, 3, 3);
    mask.addDisc(7, 3, 3);
    var buffer: [12 * 7]u32 = @splat(0xFF000000);
    fillMask(.{ .pixels = &buffer, .width = 12, .height = 7 }, &mask, 0x80FFFFFF);
    try testing.expectEqual(@as(u32, 0xFF808080), buffer[3 * 12 + 5]);
    try testing.expectEqual(@as(u32, 0xFF808080), buffer[3 * 12 + 2]);
}

test "a mask's band joins its ends with no gap" {
    var mask: Mask = try .init(testing.allocator, 40, 9);
    defer mask.deinit();
    mask.addBand(2, 4, 37, 4, 2);
    for (2..38) |pixel_x| try testing.expect(mask.depth[4 * 40 + pixel_x] >= MASK_DEPTH_STEPS);
    try testing.expectEqual(@as(u8, 0), mask.depth[0]);
}

test "a disc at a band's end adds nothing to it" {
    var band_only: Mask = try .init(testing.allocator, 40, 30);
    defer band_only.deinit();
    var with_disc: Mask = try .init(testing.allocator, 40, 30);
    defer with_disc.deinit();
    band_only.addBand(8, 9, 31, 22, 6.5);
    with_disc.addBand(8, 9, 31, 22, 6.5);
    with_disc.addDisc(8, 9, 6.5);
    with_disc.addDisc(31, 22, 6.5);
    try testing.expectEqualSlices(u8, band_only.depth, with_disc.depth);
}

test "a band's side is the same depth all along, with no scallops" {
    var mask: Mask = try .init(testing.allocator, 60, 30);
    defer mask.deinit();
    mask.addBand(5, 15, 55, 15, 9);
    for (6..54) |pixel_x| {
        try testing.expectEqual(mask.depth[6 * 60 + 6], mask.depth[6 * 60 + pixel_x]);
    }
}

test "a diagonal band measures the same to either side and reaches its far end" {
    var mask: Mask = try .init(testing.allocator, 50, 50);
    defer mask.deinit();
    mask.addBand(5, 5, 44, 44, 6);
    try testing.expectEqual(mask.depth[20 * 50 + 28], mask.depth[28 * 50 + 20]);
    try testing.expect(mask.depth[44 * 50 + 44] > 0);
    try testing.expectEqual(@as(u8, 0), mask.depth[5 * 50 + 44]);
}

test "clearing a mask empties all it touched, and a disc off it touches nothing" {
    var mask: Mask = try .init(testing.allocator, 8, 8);
    defer mask.deinit();
    mask.addDisc(-20, 3, 2);
    try testing.expectEqual(@as(usize, 0), mask.right);
    mask.addDisc(3, 3, 2);
    mask.clear();
    for (mask.depth) |depth| try testing.expectEqual(@as(u8, 0), depth);
    try testing.expectEqual(@as(usize, 0), mask.right);
}

test "a mask with nothing in it clears and paints as nothing" {
    var mask: Mask = try .init(testing.allocator, 4, 3);
    defer mask.deinit();
    var buffer: [4 * 3]u32 = @splat(0xFF000000);
    const canvas: Canvas = .{ .pixels = &buffer, .width = 4, .height = 3 };
    mask.clear();
    fillMask(canvas, &mask, 0xFFFFFFFF);
    outlineMask(canvas, &mask, 2, 0xFFFFFFFF);
    for (buffer) |pixel| try testing.expectEqual(@as(u32, 0xFF000000), pixel);
}

test "outlineMask marks the edge, leaves the middle, and skips where the canvas cuts the shape" {
    var mask: Mask = try .init(testing.allocator, 15, 15);
    defer mask.deinit();
    mask.addDisc(7, 7, 5);
    var buffer: [15 * 15]u32 = @splat(0xFF000000);
    const canvas: Canvas = .{ .pixels = &buffer, .width = 15, .height = 15 };
    outlineMask(canvas, &mask, 1, 0xFFFFFFFF);
    try testing.expectEqual(@as(u32, 0xFF000000), buffer[7 * 15 + 7]);
    try testing.expect(buffer[7 * 15 + 12] != 0xFF000000);

    mask.clear();
    @memset(&buffer, 0xFF000000);
    mask.addDisc(0, 7, 5);
    outlineMask(canvas, &mask, 1, 0xFFFFFFFF);
    try testing.expectEqual(@as(u32, 0xFF000000), buffer[7 * 15]);
}

test "drawRoundedFrame borders the buffer and clears outside its corners" {
    var buffer: [8 * 8]u32 = @splat(0xFFFFFFFF);
    drawRoundedFrame(.{ .pixels = &buffer, .width = 8, .height = 8 }, 3, 0xFF000000);
    try testing.expectEqual(@as(u32, 0), buffer[0]);
    try testing.expectEqual(@as(u32, 0xFF000000), buffer[4]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), buffer[4 * 8 + 4]);
}
