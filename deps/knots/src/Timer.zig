const std = @import("std");

ts: std.Io.Timestamp,
delta: std.Io.Duration,
clock: std.Io.Clock,

const Timer = @This();

pub fn init(clock: std.Io.Clock) Timer {
    return Timer{
        .delta = .{ .nanoseconds = 0 },
        .ts = .{ .nanoseconds = 0 },
        .clock = clock,
    };
}

pub fn start(self: *Timer, io: std.Io) void {
    self.ts = .now(io, self.clock);
}

pub fn tick(self: *Timer, io: std.Io) void {
    const now: std.Io.Timestamp = .now(io, self.clock);
    self.delta = self.ts.durationTo(now);
    self.ts = now;
}

pub fn ms(self: *const Timer) i64 {
    return self.ts.toMilliseconds();
}
