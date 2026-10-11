const std = @import("std");

samples: [120]f32 = @splat(0),
index: usize = 0,
count: usize = 0,
latest_ms: f32 = 0,

const Perf = @This();

pub fn update(self: *Perf, duration: std.Io.Duration) void {
    const ns = duration.toNanoseconds();
    if (ns <= 0) return;

    const ms = @as(f32, @floatFromInt(ns)) / std.time.ns_per_ms;
    self.latest_ms = ms;
    self.samples[self.index] = ms;
    self.index = (self.index + 1) % self.samples.len;
    self.count = @min(self.count + 1, self.samples.len);
}

pub fn latestFps(self: *const Perf) f32 {
    return if (self.latest_ms > 0) 1000.0 / self.latest_ms else 0;
}

pub fn averageMs(self: *const Perf) f32 {
    if (self.count == 0) return 0;

    var sum: f32 = 0;
    for (0..self.count) |i| sum += self.sampleAt(i);
    return sum / @as(f32, @floatFromInt(self.count));
}

pub fn averageFps(self: *const Perf) f32 {
    const avg = self.averageMs();
    return if (avg > 0) 1000.0 / avg else 0;
}

pub fn minMaxMs(self: *const Perf) struct { min: f32, max: f32 } {
    if (self.count == 0) return .{ .min = 0, .max = 0 };

    var min = self.sampleAt(0);
    var max = min;
    for (1..self.count) |i| {
        const v = self.sampleAt(i);
        min = @min(min, v);
        max = @max(max, v);
    }
    return .{ .min = min, .max = max };
}

pub fn sampleAt(self: *const Perf, i: usize) f32 {
    const clamped = @min(i, self.count - 1);
    if (self.count < self.samples.len) return self.samples[clamped];
    return self.samples[(self.index + clamped) % self.samples.len];
}
