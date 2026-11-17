//! Hands results from background threads to the main thread through atomics, so neither side waits on a lock.
const std = @import("std");

/// The newest result not yet taken; a newer one replaces it.
pub fn Slot(comptime T: type) type {
    return struct {
        /// Swapped by both threads; ownership passes with the swap.
        ready: std.atomic.Value(?*T) = .init(null),

        const Self = @This();

        /// Producer; `result` passes to the slot, and the result it replaced, never taken, passes back for the caller to free.
        pub fn put(self: *Self, result: *T) ?*T {
            return self.ready.swap(result, .acq_rel);
        }

        /// The caller owns the result.
        pub fn take(self: *Self) ?*T {
            return self.ready.swap(null, .acq_rel);
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.ready.load(.acquire) == null;
        }
    };
}

/// One background job at a time, and its newest result.
pub fn Job(comptime T: type) type {
    return struct {
        /// Set by the main thread's claim, cleared by finish.
        is_busy: std.atomic.Value(bool) = .init(false),
        /// Set by the job's thread when nothing arrived; cleared by takeFailure.
        has_failed: std.atomic.Value(bool) = .init(false),
        /// Filled by the job's thread, emptied by the main thread.
        result: Slot(T) = .{},

        const Self = @This();

        /// Main thread: whether the job was idle and is now the caller's to start; call finish if it then can't.
        pub fn claim(self: *Self) bool {
            return !self.is_busy.swap(true, .acq_rel);
        }

        /// The job's thread as it ends, or the main thread when a claimed job couldn't start.
        pub fn finish(self: *Self) void {
            self.is_busy.store(false, .release);
        }

        pub fn isBusy(self: *const Self) bool {
            return self.is_busy.load(.acquire);
        }

        /// The job's thread.
        pub fn fail(self: *Self) void {
            self.has_failed.store(true, .release);
        }

        /// Main thread: whether the job failed since this was last asked.
        pub fn takeFailure(self: *Self) bool {
            return self.has_failed.swap(false, .acq_rel);
        }

        /// The job's thread; as Slot.put.
        pub fn deliver(self: *Self, result: *T) ?*T {
            return self.result.put(result);
        }

        /// The caller owns the result.
        pub fn take(self: *Self) ?*T {
            return self.result.take();
        }

        pub fn hasResult(self: *const Self) bool {
            return !self.result.isEmpty();
        }
    };
}

const testing = std.testing;

test "a claimed job can't be claimed again until it finishes" {
    var job: Job(u32) = .{};
    try testing.expect(job.claim());
    try testing.expect(!job.claim());
    try testing.expect(job.isBusy());
    job.finish();
    try testing.expect(job.claim());
}

test "a delivery hands back the result it replaced, and take empties the slot" {
    var job: Job(u32) = .{};
    var first: u32 = 1;
    var second: u32 = 2;
    try testing.expect(job.deliver(&first) == null);
    try testing.expectEqual(&first, job.deliver(&second).?);
    try testing.expectEqual(&second, job.take().?);
    try testing.expect(job.take() == null);
    try testing.expect(!job.hasResult());
}

test "a failure is reported once" {
    var job: Job(u32) = .{};
    try testing.expect(!job.takeFailure());
    job.fail();
    try testing.expect(job.takeFailure());
    try testing.expect(!job.takeFailure());
}
