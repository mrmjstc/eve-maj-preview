//! Starts the app's threads with a stack sized for what they do.
const std = @import("std");

/// Windows' own default; std.Thread's 16 MB is committed in full, not just reserved.
const STACK_SIZE = 1024 * 1024;

/// `std.Thread.spawn` with STACK_SIZE.
pub fn spawn(comptime function: anytype, args: anytype) std.Thread.SpawnError!std.Thread {
    return std.Thread.spawn(.{ .stack_size = STACK_SIZE }, function, args);
}
