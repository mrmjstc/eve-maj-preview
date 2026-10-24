//! The category bar's line icons, built from rounded rectangles and circles, which knots antialiases, unlike its lines.
const std = @import("std");
const ui = @import("ui");

const DrawCmd = ui.component.Canvas.DrawCmd;
const Radius = ui.Radius;
const BorderWidth = ui.BorderWidth;

/// Icons are drawn on a 24-unit grid, like the line icon sets they follow, then scaled to their box.
const GRID: f32 = 24;
/// In grid units.
const STROKE: f32 = 1.75;

pub const Icon = enum { people, display, keyboard, bell, sliders };

/// Corner radii in grid units, and whether the bottom edge is drawn.
const Shape = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,
    is_closed: bool = false,
};

/// Draws in grid units, scaled to the icon's box.
const Pen = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(DrawCmd) = .empty,
    scale: f32,
    color: [4]f32,
    ground: [4]f32,

    /// A rectangle's outline, left open at the bottom unless the shape is closed.
    fn outline(self: *Pen, x: f32, y: f32, width: f32, height: f32, shape: Shape) !void {
        const stroke = STROKE * self.scale;
        try self.list.append(self.arena, .{ .stroke_rect = .{
            .x = x * self.scale,
            .y = y * self.scale,
            .w = width * self.scale,
            .h = height * self.scale,
            .color = self.color,
            .corner_radius = Radius.corners(shape.top_left * self.scale, shape.top_right * self.scale, shape.bottom_right * self.scale, shape.bottom_left * self.scale),
            .edge_widths = BorderWidth.edges(stroke, stroke, if (shape.is_closed) stroke else 0, stroke),
        } });
    }

    /// A filled bar with rounded ends.
    fn bar(self: *Pen, x: f32, y: f32, width: f32, height: f32) !void {
        try self.fill(x, y, width, height, @min(width, height) / 2, self.color);
    }

    /// Paints the ground over a rounded area, hiding the shapes drawn under it.
    fn cover(self: *Pen, x: f32, y: f32, width: f32, height: f32, radius: f32) !void {
        try self.fill(x, y, width, height, radius, self.ground);
    }

    fn fill(self: *Pen, x: f32, y: f32, width: f32, height: f32, radius: f32, color: [4]f32) !void {
        try self.list.append(self.arena, .{ .fill_rect = .{
            .x = x * self.scale,
            .y = y * self.scale,
            .w = width * self.scale,
            .h = height * self.scale,
            .color = color,
            .corner_radius = Radius.all(radius * self.scale),
        } });
    }

    fn ring(self: *Pen, cx: f32, cy: f32, radius: f32) !void {
        try self.list.append(self.arena, .{ .stroke_circle = .{ .cx = cx * self.scale, .cy = cy * self.scale, .radius = radius * self.scale, .color = self.color, .thickness = STROKE * self.scale } });
    }

    fn dot(self: *Pen, cx: f32, cy: f32, radius: f32) !void {
        try self.list.append(self.arena, .{ .fill_circle = .{ .cx = cx * self.scale, .cy = cy * self.scale, .radius = radius * self.scale, .color = self.color } });
    }
};

/// `icon` filling a `size`-sized square in `color`; `ground` is what's behind it, painted where one shape hides another.
pub fn commands(arena: std.mem.Allocator, icon: Icon, size: f32, color: [4]f32, ground: [4]f32) ![]const DrawCmd {
    var pen: Pen = .{ .arena = arena, .scale = size / GRID, .color = color, .ground = ground };
    switch (icon) {
        .people => {
            // The one behind first, so the one in front can cover where they overlap.
            try pen.ring(16.5, 8, 2.75);
            try pen.outline(13, 14.5, 9, 8, .{ .top_left = 4.5, .top_right = 4.5 });
            try pen.cover(2, 13.5, 13, 10, 5.5);
            try pen.ring(9, 7.5, 3.5);
            try pen.outline(3, 14.5, 12, 8, .{ .top_left = 5.5, .top_right = 5.5 });
        },
        .display => {
            try pen.outline(2.5, 4, 19, 13, .{ .top_left = 2, .top_right = 2, .bottom_right = 2, .bottom_left = 2, .is_closed = true });
            try pen.bar(11.125, 17, STROKE, 3.75);
            try pen.bar(7.5, 20.25, 9, STROKE);
        },
        .keyboard => {
            try pen.outline(2.5, 6, 19, 12, .{ .top_left = 2, .top_right = 2, .bottom_right = 2, .bottom_left = 2, .is_closed = true });
            for ([_]f32{ 6, 9.5, 13, 16.5 }) |x| try pen.bar(x, 9.25, 1.75, 1.75);
            try pen.bar(7.5, 13.25, 9, STROKE);
        },
        .bell => {
            try pen.outline(6, 4, 12, 13, .{ .top_left = 6, .top_right = 6, .bottom_right = 1, .bottom_left = 1 });
            try pen.bar(3.5, 16.25, 17, STROKE);
            try pen.bar(11.125, 2, STROKE, 2);
            try pen.dot(12, 20.25, 1.6);
        },
        .sliders => {
            try slider(&pen, 6, 15);
            try slider(&pen, 12, 9);
            try slider(&pen, 18, 16);
        },
    }
    return pen.list.items;
}

/// A slider's track across the icon with its knob at `knob_x`, the track stopping short of the knob.
fn slider(pen: *Pen, y: f32, knob_x: f32) !void {
    const knob = 2.25;
    const gap = knob + STROKE;
    try pen.bar(3, y - STROKE / 2, knob_x - gap - 3, STROKE);
    try pen.bar(knob_x + gap, y - STROKE / 2, 21 - knob_x - gap, STROKE);
    try pen.ring(knob_x, y, knob);
}
