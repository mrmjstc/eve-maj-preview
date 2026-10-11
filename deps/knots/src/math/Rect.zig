const std = @import("std");
const root = @import("root.zig");
const Vec2 = root.Vec2;
const Vec4 = root.Vec4;

v: Vec4,

const Rect = @This();

pub const zero: Rect = .{ .v = .{ 0, 0, 0, 0 } };

pub fn init(x_: f32, y_: f32, w_: f32, h_: f32) Rect {
    return .{ .v = .{ x_, y_, w_, h_ } };
}

pub fn fromVec4(v: Vec4) Rect {
    return .{ .v = v };
}

pub fn fromMinMax(lo: Vec2, hi: Vec2) Rect {
    return .{ .v = .{ lo[0], lo[1], hi[0] - lo[0], hi[1] - lo[1] } };
}

pub fn x(self: Rect) f32 {
    return self.v[0];
}

pub fn y(self: Rect) f32 {
    return self.v[1];
}

pub fn w(self: Rect) f32 {
    return self.v[2];
}

pub fn h(self: Rect) f32 {
    return self.v[3];
}

pub fn eql(self: Rect, b: Rect) bool {
    return @reduce(.And, self.v == b.v);
}

pub fn setX(self: *Rect, val: f32) void {
    self.v[0] = val;
}

pub fn setY(self: *Rect, val: f32) void {
    self.v[1] = val;
}

pub fn setW(self: *Rect, val: f32) void {
    self.v[2] = val;
}

pub fn setH(self: *Rect, val: f32) void {
    self.v[3] = val;
}

pub fn pos(self: Rect) Vec2 {
    return .{ self.v[0], self.v[1] };
}

pub fn size(self: Rect) Vec2 {
    return .{ self.v[2], self.v[3] };
}

pub fn min(self: Rect) Vec2 {
    return .{ self.v[0], self.v[1] };
}

pub fn max(self: Rect) Vec2 {
    return .{ self.v[0] + self.v[2], self.v[1] + self.v[3] };
}

pub fn isEmpty(self: Rect) bool {
    return self.v[2] <= 0 or self.v[3] <= 0;
}

pub fn intersect(self: Rect, other: Rect) Rect {
    const a_lo = self.min();
    const a_hi = self.max();
    const b_lo = other.min();
    const b_hi = other.max();
    const lo = @max(a_lo, b_lo);
    const hi = @max(lo, @min(a_hi, b_hi));
    return fromMinMax(lo, hi);
}

pub fn expand(self: Rect, amount: f32) Rect {
    const a: Vec4 = .{ -amount, -amount, 2 * amount, 2 * amount };
    return .{ .v = self.v + a };
}

pub fn contains(self: Rect, point: Vec2) bool {
    const lo = self.min();
    const hi = self.max();
    return point[0] >= lo[0] and point[0] < hi[0] and
        point[1] >= lo[1] and point[1] < hi[1];
}

pub fn overlaps(self: Rect, other: Rect) bool {
    return !(self.v[0] >= other.v[0] + other.v[2] or
        self.v[0] + self.v[2] <= other.v[0] or
        self.v[1] >= other.v[1] + other.v[3] or
        self.v[1] + self.v[3] <= other.v[1]);
}
