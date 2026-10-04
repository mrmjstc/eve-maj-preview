//! When periodic work run from the timer tick is due.
const std = @import("std");

/// On the tick nearest `interval_ms` rather than the first past it, so a tick landing a few ms early doesn't push the work a whole tick later.
pub fn isDue(elapsed_ms: i64, interval_ms: i64, tick_interval_ms: i64) bool {
    return elapsed_ms + @divTrunc(tick_interval_ms, 2) >= interval_ms;
}

/// For work whose gaps must never pass `interval_ms`: true on the last tick before waiting one more would.
pub fn nextTickWouldBeLate(elapsed_ms: i64, interval_ms: i64, tick_interval_ms: i64) bool {
    return elapsed_ms + tick_interval_ms > interval_ms;
}

const testing = std.testing;

test "isDue runs a once-a-second check on a one-second tick that lands early" {
    try testing.expect(isDue(984, 1000, 1000));
    try testing.expect(isDue(1016, 1000, 1000));
}

test "isDue waits for the tick nearest the interval" {
    try testing.expect(!isDue(950, 1000, 50));
    try testing.expect(isDue(1000, 1000, 50));
    try testing.expect(!isDue(600, 1000, 600));
    try testing.expect(isDue(1200, 1000, 600));
}

test "nextTickWouldBeLate keeps every gap within the interval" {
    try testing.expect(!nextTickWouldBeLate(950, 1000, 50));
    try testing.expect(nextTickWouldBeLate(951, 1000, 50));
    try testing.expect(!nextTickWouldBeLate(300, 1000, 600));
    try testing.expect(nextTickWouldBeLate(600, 1000, 600));
    try testing.expect(nextTickWouldBeLate(984, 1000, 1000));
}
