//! How Barrage draws a tank's body and barrel in each style a pilot can pick, and the Painter it draws with.
const std = @import("std");
const ui = @import("ui");
const game = @import("../../barrage/game.zig");
const messages = @import("../../barrage/messages.zig");

const DrawCmd = ui.component.Canvas.DrawCmd;
const TankStyle = messages.TankStyle;

/// How strongly a tank's outline colour fills it.
const FILL_ALPHA = 0.12;
/// Segments in a half circle.
const ARC_SEGMENTS = 8;

/// Draw commands in field units, which run up from the drawing's bottom; flipped and scaled onto the canvas.
pub const Painter = struct {
    arena: std.mem.Allocator,
    /// Added to every point on the canvas, e.g. glyphs.snapOffset's shift.
    origin: [2]f32,
    /// The drawing's height in field units.
    height: f32,
    /// Canvas pixels per field unit; also scales thicknesses and radii.
    scale: f32 = 1,
    commands: std.ArrayList(DrawCmd) = .empty,

    pub fn line(self: *Painter, from: [2]f32, to: [2]f32, thickness: f32, color: [4]f32) !void {
        try self.commands.append(self.arena, .{ .line = .{ .from = self.place(from), .to = self.place(to), .thickness = thickness * self.scale, .color = color } });
    }

    pub fn ring(self: *Painter, centre: [2]f32, radius: f32, color: [4]f32) !void {
        const placed = self.place(centre);
        try self.commands.append(self.arena, .{ .stroke_circle = .{ .cx = placed[0], .cy = placed[1], .radius = radius * self.scale, .color = color, .thickness = self.scale } });
    }

    /// Closed, through `points` in order.
    pub fn outline(self: *Painter, points: []const [2]f32, color: [4]f32) !void {
        for (points, 0..) |point, index| try self.line(point, points[(index + 1) % points.len], 1, color);
    }

    /// Filled with `fill` unless it's transparent, then outlined; `points` must make a convex shape, and are copied into the arena.
    pub fn shape(self: *Painter, points: []const [2]f32, color: [4]f32, fill: [4]f32) !void {
        if (fill[3] > 0) {
            const placed = try self.arena.alloc([2]f32, points.len);
            for (points, placed) |point, *slot| slot.* = self.place(point);
            try self.commands.append(self.arena, .{ .fill_convex_polygon = .{ .points = placed, .color = fill } });
        }
        try self.outline(points, color);
    }

    fn place(self: *const Painter, point: [2]f32) [2]f32 {
        return .{ self.origin[0] + point[0] * self.scale, self.origin[1] + (self.height - point[1]) * self.scale };
    }
};

/// From the turret's edge to game.BARREL_LENGTH from the pivot.
const Barrel = struct {
    start: f32,
    thickness: f32,
    has_muzzle_brake: bool = false,
};

/// One tank being drawn: where, in what colours, with `top` its barrel's pivot height.
const Look = struct {
    painter: *Painter,
    x: f32,
    y: f32,
    top: f32,
    color: [4]f32,
    fill: [4]f32,

    /// Tracks, a hull overhanging them, and a round dome.
    fn standard(self: *const Look) !Barrel {
        try self.trackBelt(5, &.{ -8, -2.7, 2.7, 8 }, 1.5);
        try self.shape(&.{ self.point(-12, 5), self.point(12, 5), self.point(15, 9), self.point(-15, 9) });
        try self.dome(6);
        return .{ .start = 5, .thickness = 2.5 };
    }

    /// Tall tracks on five wheels, a slab hull, an angular turret and a thick barrel with a muzzle brake.
    fn heavy(self: *const Look) !Barrel {
        try self.trackBelt(6, &.{ -10, -5, 0, 5, 10 }, 1.4);
        try self.shape(&.{ self.point(-14, 6), self.point(14, 6), self.point(14, 9), self.point(-14, 9) });
        try self.shape(&.{ self.point(-8, 9), self.point(8, 9), self.point(6, 14), self.point(-6, 14) });
        return .{ .start = 4, .thickness = 3.5, .has_muzzle_brake = true };
    }

    /// Three big wheels under a wedge hull, with a small dome and a thin barrel.
    fn scout(self: *const Look) !Barrel {
        for ([_]f32{ -9, 0, 9 }) |offset| try self.painter.ring(self.point(offset, 3), 3, self.color);
        try self.shape(&.{ self.point(-13, 5), self.point(13, 5), self.point(9, 9), self.point(-11, 9) });
        try self.dome(4.5);
        return .{ .start = 3.5, .thickness = 1.8 };
    }

    /// A rounded skirt over three lift jets, under a dome.
    fn hover(self: *const Look) !Barrel {
        const skirt_segments = 12;
        var points: [skirt_segments + 3][2]f32 = undefined;
        arc(points[0 .. skirt_segments + 1], self.point(0, 5), .{ 14, 3.5 }, std.math.pi, 2 * std.math.pi);
        points[skirt_segments + 1] = self.point(11, 9);
        points[skirt_segments + 2] = self.point(-11, 9);
        try self.shape(&points);
        for ([_]f32{ -7, 0, 7 }) |offset| try self.painter.line(self.point(offset, 0), self.point(offset, 0.8), 1, self.color);
        try self.dome(6);
        return .{ .start = 5, .thickness = 2.2 };
    }

    /// Four jointed legs under a body and dome.
    fn walker(self: *const Look) !Barrel {
        for ([_]f32{ -1, 1 }) |side| {
            try self.leg(.{ side * 9, 6 }, .{ side * 14, 3.5 }, .{ side * 12, 0 });
            try self.leg(.{ side * 4, 6 }, .{ side * 7, 3 }, .{ side * 6, 0 });
        }
        try self.shape(&.{ self.point(-11, 6), self.point(11, 6), self.point(12, 9), self.point(-12, 9) });
        try self.dome(6);
        return .{ .start = 5, .thickness = 2.2 };
    }

    /// The old artillery-game look: a trapezoid with tread marks under a dome.
    fn classic(self: *const Look) !Barrel {
        try self.shape(&.{ self.point(-14, 0), self.point(14, 0), self.point(10, 9), self.point(-10, 9) });
        var offset: f32 = -10;
        while (offset <= 10) : (offset += 4) try self.painter.line(self.point(offset, 0), self.point(offset, 2), 1, self.color);
        try self.dome(6);
        return .{ .start = 5, .thickness = 2.5 };
    }

    /// Straight runs joined by half circles round the end wheels, with `wheel_offsets` from the middle.
    fn trackBelt(self: *const Look, height: f32, wheel_offsets: []const f32, wheel_radius: f32) !void {
        const half = game.TANK_HALF_WIDTH;
        const radius = height / 2;
        var points: [2 * (ARC_SEGMENTS + 1)][2]f32 = undefined;
        arc(points[0 .. ARC_SEGMENTS + 1], self.point(-half + radius, radius), .{ radius, radius }, std.math.pi / 2.0, 3 * std.math.pi / 2.0);
        arc(points[ARC_SEGMENTS + 1 ..], self.point(half - radius, radius), .{ radius, radius }, -std.math.pi / 2.0, std.math.pi / 2.0);
        try self.shape(&points);
        for (wheel_offsets) |offset| try self.painter.ring(self.point(offset, radius), wheel_radius, self.color);
    }

    /// Centred on the barrel's pivot.
    fn dome(self: *const Look, radius: f32) !void {
        var points: [ARC_SEGMENTS + 1][2]f32 = undefined;
        arc(&points, .{ self.x, self.top }, .{ radius, radius }, 0, std.math.pi);
        try self.shape(&points);
    }

    fn leg(self: *const Look, hip: [2]f32, knee: [2]f32, foot: [2]f32) !void {
        try self.painter.line(self.point(hip[0], hip[1]), self.point(knee[0], knee[1]), 1.2, self.color);
        try self.painter.line(self.point(knee[0], knee[1]), self.point(foot[0], foot[1]), 1.2, self.color);
    }

    /// Ends game.BARREL_LENGTH from the pivot, where shells leave the muzzle.
    fn drawBarrel(self: *const Look, angle_degrees: f32, barrel: Barrel) !void {
        const radians = angle_degrees * (std.math.pi / 180.0);
        const direction = [2]f32{ @cos(radians), @sin(radians) };
        const from = [2]f32{ self.x + direction[0] * barrel.start, self.top + direction[1] * barrel.start };
        const tip = [2]f32{ self.x + direction[0] * game.BARREL_LENGTH, self.top + direction[1] * game.BARREL_LENGTH };
        try self.painter.line(from, tip, barrel.thickness, self.color);
        if (!barrel.has_muzzle_brake) return;
        const across = [2]f32{ -direction[1] * 2.5, direction[0] * 2.5 };
        const brake = [2]f32{ tip[0] - direction[0] * 2, tip[1] - direction[1] * 2 };
        try self.painter.line(.{ brake[0] + across[0], brake[1] + across[1] }, .{ brake[0] - across[0], brake[1] - across[1] }, 1.5, self.color);
    }

    fn shape(self: *const Look, points: []const [2]f32) !void {
        try self.painter.shape(points, self.color, self.fill);
    }

    /// A point `dx` across from the tank's middle and `dy` up from its bottom.
    fn point(self: *const Look, dx: f32, dy: f32) [2]f32 {
        return .{ self.x + dx, self.y + dy };
    }
};

/// (x, y) is the middle of the tank's bottom; a wreck is unfilled and has no barrel.
pub fn drawTank(painter: *Painter, tank_style: TankStyle, x: f32, y: f32, angle_degrees: f32, color: [4]f32, is_alive: bool) !void {
    var fill = color;
    fill[3] = if (is_alive) FILL_ALPHA else 0;
    const look: Look = .{ .painter = painter, .x = x, .y = y, .top = y + game.TANK_HEIGHT, .color = color, .fill = fill };
    const barrel = switch (tank_style) {
        .standard => try look.standard(),
        .heavy => try look.heavy(),
        .scout => try look.scout(),
        .hover => try look.hover(),
        .walker => try look.walker(),
        .classic => try look.classic(),
    };
    if (!is_alive) return;
    try look.drawBarrel(angle_degrees, barrel);
}

pub fn styleName(tank_style: TankStyle) []const u8 {
    return switch (tank_style) {
        .standard => "Standard",
        .heavy => "Heavy",
        .scout => "Scout",
        .hover => "Hover",
        .walker => "Walker",
        .classic => "Classic",
    };
}

/// Fills `points` evenly along an ellipse's arc from `from` to `to` radians.
fn arc(points: [][2]f32, centre: [2]f32, radii: [2]f32, from: f32, to: f32) void {
    const last: f32 = @floatFromInt(points.len - 1);
    for (points, 0..) |*point, index| {
        const angle = from + (to - from) * @as(f32, @floatFromInt(index)) / last;
        point.* = .{ centre[0] + @cos(angle) * radii[0], centre[1] + @sin(angle) * radii[1] };
    }
}
