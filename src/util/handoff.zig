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

/// Results from any number of threads, all taken at once by one; `T` has a `next: ?*T` field for the stack's use.
pub fn Stack(comptime T: type) type {
    return struct {
        /// Pushed by any thread, emptied by the taking one; ownership passes with each item.
        head: std.atomic.Value(?*T) = .init(null),

        const Self = @This();

        /// Any thread; `item` passes to the stack.
        pub fn push(self: *Self, item: *T) void {
            var head = self.head.load(.monotonic);
            while (true) {
                item.next = head;
                head = self.head.cmpxchgWeak(head, item, .release, .monotonic) orelse return;
            }
        }

        /// Everything pushed so far, oldest first through `next`; the caller owns each item.
        pub fn takeAll(self: *Self) ?*T {
            var newest = self.head.swap(null, .acquire);
            var oldest: ?*T = null;
            while (newest) |item| {
                newest = item.next;
                item.next = oldest;
                oldest = item;
            }
            return oldest;
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

const PUSHING_THREAD_COUNT = 4;
const PUSHES_PER_THREAD = 1000;

const TestNode = struct {
    value: u32,
    next: ?*TestNode = null,
};

fn pushMany(stack: *Stack(TestNode), nodes: []TestNode) void {
    for (nodes) |*node| stack.push(node);
}

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

test "a stack hands back everything pushed, oldest first, and is then empty" {
    var stack: Stack(TestNode) = .{};
    var nodes = [_]TestNode{ .{ .value = 1 }, .{ .value = 2 }, .{ .value = 3 } };
    for (&nodes) |*node| stack.push(node);

    var next = stack.takeAll();
    for (1..4) |expected| {
        const node = next orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u32, @intCast(expected)), node.value);
        next = node.next;
    }
    try testing.expect(next == null);
    try testing.expect(stack.takeAll() == null);
}

test "a stack loses nothing pushed from several threads at once" {
    var stack: Stack(TestNode) = .{};
    var nodes: [PUSHING_THREAD_COUNT][PUSHES_PER_THREAD]TestNode = undefined;
    var threads: [PUSHING_THREAD_COUNT]std.Thread = undefined;
    for (&nodes, &threads) |*thread_nodes, *thread| {
        for (thread_nodes) |*node| node.* = .{ .value = 0 };
        thread.* = try std.Thread.spawn(.{}, pushMany, .{ &stack, thread_nodes });
    }
    for (threads) |thread| thread.join();

    var count: usize = 0;
    var next = stack.takeAll();
    while (next) |node| : (next = node.next) count += 1;
    try testing.expectEqual(@as(usize, PUSHING_THREAD_COUNT * PUSHES_PER_THREAD), count);
}

test "a failure is reported once" {
    var job: Job(u32) = .{};
    try testing.expect(!job.takeFailure());
    job.fail();
    try testing.expect(job.takeFailure());
    try testing.expect(!job.takeFailure());
}
