//! One-shot background threads that nothing joins, counted so shutdown can give them time to finish.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.Scoped("detached");

const WAIT_POLL_MS = 10;

/// Raised by the spawning thread, lowered by each thread as it returns.
var g_running_count: std.atomic.Value(u32) = .init(0);

/// `std.Thread.spawn` then detach, counted until `function` returns; `function` returns void.
pub fn spawn(comptime function: anytype, args: anytype) !void {
    _ = g_running_count.fetchAdd(1, .monotonic);
    errdefer _ = g_running_count.fetchSub(1, .monotonic);
    const thread = try std.Thread.spawn(.{}, Counted(function, @TypeOf(args)).run, .{args});
    thread.detach();
}

/// At shutdown, before what the threads use is torn down; any still running after `timeout_ms` are left to end with the process.
pub fn waitForAll(io: std.Io, timeout_ms: u32) void {
    var waited_ms: u32 = 0;
    while (g_running_count.load(.acquire) > 0) : (waited_ms += WAIT_POLL_MS) {
        if (waited_ms >= timeout_ms) {
            slog.info("Exiting with {d} background thread(s) still running", .{g_running_count.load(.acquire)});
            return;
        }
        std.Io.sleep(io, .fromMilliseconds(WAIT_POLL_MS), .awake) catch |err| {
            slog.warn("Failed to wait for background threads to finish: {}", .{err});
            return;
        };
    }
}

/// `function` takes the fields of `Args` as its parameters.
fn Counted(comptime function: anytype, comptime Args: type) type {
    return struct {
        fn run(args: Args) void {
            defer _ = g_running_count.fetchSub(1, .release);
            @call(.auto, function, args);
        }
    };
}
