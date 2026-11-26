//! A thread, started on demand and stopped when idle, that runs queued commands in order on an engine it owns; shared by speech and sound alerts.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const threads = @import("../util/threads.zig");
const log = @import("../log.zig");

/// `Engine`: `init`, `run(command, allocator)` and `deinit`, all called on the worker thread.
/// `Command.deinit(allocator)`: frees what it owns once run or dropped.
/// `Command.isAlert`: whether pushAlert may drop it.
/// `Command.isMinorAlert`: whether it's dropped before other alerts.
/// `description`: names the feature in logs.
pub fn Worker(comptime Command: type, comptime Engine: type, comptime scope: []const u8, comptime description: []const u8) type {
    const slog = log.Scoped(scope);

    return struct {
        /// Set once, before the first command.
        io: std.Io = undefined,
        /// Set once, before the first command; thread-safe, as both threads free commands.
        allocator: std.mem.Allocator = undefined,
        mutex: std.Io.Mutex = .init,
        /// Guarded by mutex.
        queue: std.ArrayList(Command) = .empty,
        /// Guarded by mutex; set while the worker runs a command it has popped.
        is_busy: bool = false,
        /// Main thread only.
        thread: ?std.Thread = null,
        /// Main thread only; set once the worker can't start, so it isn't retried.
        has_failed: bool = false,
        /// Set by the main thread to stop the worker, read by the worker each time it wakes.
        should_exit: std.atomic.Value(bool) = .init(false),
        /// Set by the worker when its engine fails to start.
        has_engine_failed: std.atomic.Value(bool) = .init(false),
        /// Main thread only, the worker getting its own copy; auto-reset, signalled by each push and by stop.
        wake_event: ?win32.HANDLE = null,

        const Self = @This();

        /// Starts the thread on first use; false if it isn't running and won't be.
        pub fn start(self: *Self) bool {
            if (self.thread) |thread| {
                if (!self.has_engine_failed.load(.acquire)) return true;
                thread.join();
                self.thread = null;
                self.closeWakeEvent();
                self.has_failed = true;
                return false;
            }
            if (self.has_failed) return false;

            const wake_event = win32.CreateEventA(null, win32.FALSE, win32.FALSE, null) orelse {
                slog.warn("Failed to create the {s} thread's wake event: error {d}", .{ description, win32.GetLastError() });
                self.has_failed = true;
                return false;
            };
            self.wake_event = wake_event;
            self.should_exit.store(false, .release);
            self.thread = threads.spawn(run, .{ self, wake_event }) catch |err| {
                slog.warn("Failed to start the {s} thread: {}", .{ description, err });
                self.closeWakeEvent();
                self.has_failed = true;
                return false;
            };
            return true;
        }

        /// Takes ownership of `command`, freeing it if it can't be queued.
        pub fn push(self: *Self, command: Command) void {
            self.append(command, null) catch |err| {
                slog.warn("Failed to queue a {s} command: {}", .{ description, err });
                command.deinit(self.allocator);
            };
        }

        /// Like push, then drops the oldest waiting alerts past `max_waiting`, at least 1, minor ones first.
        pub fn pushAlert(self: *Self, command: Command, max_waiting: usize) void {
            self.append(command, @max(max_waiting, 1)) catch |err| {
                slog.warn("Failed to queue a {s} alert: {}", .{ description, err });
                command.deinit(self.allocator);
            };
        }

        /// Call once during app shutdown; drops anything still queued.
        pub fn shutdown(self: *Self) void {
            self.stop();
            while (self.pop()) |command| command.deinit(self.allocator);
        }

        /// Ends the thread and its engine unless it has work the join would wait on; the next start runs it again.
        pub fn stopIfIdle(self: *Self) void {
            if (self.thread == null) return;
            if (!self.isIdle()) return;
            self.stop();
        }

        /// Only the main thread pushes, so the worker can't be handed anything between this and stop.
        fn isIdle(self: *Self) bool {
            self.mutex.lock(self.io) catch |err| {
                slog.warn("Failed to check whether {s} is idle, leaving it running: {}", .{ description, err });
                return false;
            };
            defer self.mutex.unlock(self.io);
            return self.queue.items.len == 0 and !self.is_busy;
        }

        fn stop(self: *Self) void {
            const thread = self.thread orelse return;
            self.should_exit.store(true, .release);
            self.wake();
            thread.join();
            self.thread = null;
            self.closeWakeEvent();
        }

        fn append(self: *Self, command: Command, max_waiting_alerts: ?usize) !void {
            const dropped_count = try self.appendLocked(command, max_waiting_alerts);
            self.wake();
            if (dropped_count > 0) slog.info("Dropped {d} waiting alert(s) for {s}, keeping the newest {d}", .{ dropped_count, description, max_waiting_alerts orelse 0 });
        }

        fn wake(self: *const Self) void {
            const event = self.wake_event orelse return;
            if (!win32.toBool(win32.SetEvent(event))) slog.warn("Failed to wake the {s} thread: error {d}", .{ description, win32.GetLastError() });
        }

        fn closeWakeEvent(self: *Self) void {
            const event = self.wake_event orelse return;
            _ = win32.CloseHandle(event);
            self.wake_event = null;
        }

        /// How many alerts it dropped and freed, which the caller logs outside the lock.
        fn appendLocked(self: *Self, command: Command, max_waiting_alerts: ?usize) !usize {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            try self.queue.append(self.allocator, command);
            const max_waiting = max_waiting_alerts orelse return 0;

            var alert_count: usize = 0;
            for (self.queue.items) |queued| {
                if (queued.isAlert()) alert_count += 1;
            }
            const excess_count = alert_count -| max_waiting;
            const minor_count = self.dropOldest(excess_count, true);
            return minor_count + self.dropOldest(excess_count - minor_count, false);
        }

        /// Up to `excess_count` of the oldest alerts, only minor ones if `is_minor_only`; caller holds mutex.
        fn dropOldest(self: *Self, excess_count: usize, is_minor_only: bool) usize {
            var dropped_count: usize = 0;
            var i: usize = 0;
            while (dropped_count < excess_count and i < self.queue.items.len) {
                const queued = self.queue.items[i];
                if (!queued.isAlert() or (is_minor_only and !queued.isMinorAlert())) {
                    i += 1;
                    continue;
                }
                self.queue.orderedRemove(i).deinit(self.allocator);
                dropped_count += 1;
            }
            return dropped_count;
        }

        fn pop(self: *Self) ?Command {
            self.mutex.lock(self.io) catch |err| {
                slog.warn("Failed to lock the {s} queue: {}", .{ description, err });
                return null;
            };
            defer self.mutex.unlock(self.io);
            if (self.queue.items.len == 0) return null;
            return self.queue.orderedRemove(0);
        }

        /// Worker thread only: pop, marking the worker busy until the next call finds the queue empty.
        fn next(self: *Self) ?Command {
            self.mutex.lock(self.io) catch |err| {
                slog.warn("Failed to lock the {s} queue: {}", .{ description, err });
                return null;
            };
            defer self.mutex.unlock(self.io);
            self.is_busy = self.queue.items.len > 0;
            if (!self.is_busy) return null;
            return self.queue.orderedRemove(0);
        }

        /// `wake_event` stays open until this returns and is joined.
        fn run(self: *Self, wake_event: win32.HANDLE) void {
            var engine = Engine.init() catch |err| {
                slog.warn("Failed to start {s}, so its alerts won't play: {}", .{ description, err });
                self.has_engine_failed.store(true, .release);
                return;
            };
            defer engine.deinit();
            slog.info("Started {s}", .{description});
            defer slog.info("Stopped {s}", .{description});

            while (!self.should_exit.load(.acquire)) {
                const command = self.next() orelse {
                    // A push between the empty pop and this wait leaves the event signalled, so it isn't missed.
                    if (win32.WaitForSingleObject(wake_event, win32.INFINITE) == win32.WAIT_FAILED) {
                        slog.err("Failed to wait for {s}, so its alerts won't play: error {d}", .{ description, win32.GetLastError() });
                        self.has_engine_failed.store(true, .release);
                        return;
                    }
                    continue;
                };
                defer command.deinit(self.allocator);
                engine.run(command, self.allocator);
            }
        }
    };
}

const testing = std.testing;

/// The ids of freed commands, in the order they were freed.
const FreedLog = struct {
    ids: [8]u8 = undefined,
    count: usize = 0,

    fn freed(self: *const FreedLog) []const u8 {
        return self.ids[0..self.count];
    }
};

const TestCommand = struct {
    id: u8,
    is_alert: bool,
    is_minor: bool = false,
    freed_log: *FreedLog,

    fn deinit(self: TestCommand, _: std.mem.Allocator) void {
        self.freed_log.ids[self.freed_log.count] = self.id;
        self.freed_log.count += 1;
    }

    fn isAlert(self: TestCommand) bool {
        return self.is_alert;
    }

    fn isMinorAlert(self: TestCommand) bool {
        return self.is_minor;
    }
};

const TestEngine = struct {
    fn init() !TestEngine {
        return .{};
    }

    fn run(_: *TestEngine, _: TestCommand, _: std.mem.Allocator) void {}

    fn deinit(_: *TestEngine) void {}
};

const TestWorker = Worker(TestCommand, TestEngine, "test_worker", "test");

/// The queued ids in order; frees the queue, since shutdown only does that once the thread has run.
fn drainIds(worker: *TestWorker, buffer: []u8) []const u8 {
    var count: usize = 0;
    for (worker.queue.items) |command| {
        buffer[count] = command.id;
        count += 1;
    }
    worker.queue.deinit(worker.allocator);
    worker.queue = .empty;
    return buffer[0..count];
}

test "pushAlert drops the oldest waiting alerts past max_waiting" {
    var log_entries: FreedLog = .{};
    var worker: TestWorker = .{ .io = testing.io, .allocator = testing.allocator };
    for (1..4) |id| worker.pushAlert(.{ .id = @intCast(id), .is_alert = true, .freed_log = &log_entries }, 2);

    var buffer: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 2, 3 }, drainIds(&worker, &buffer));
    try testing.expectEqualSlices(u8, &.{1}, log_entries.freed());
}

test "pushAlert never drops commands that aren't alerts" {
    var log_entries: FreedLog = .{};
    var worker: TestWorker = .{ .io = testing.io, .allocator = testing.allocator };
    worker.push(.{ .id = 1, .is_alert = false, .freed_log = &log_entries });
    worker.push(.{ .id = 2, .is_alert = true, .freed_log = &log_entries });
    worker.push(.{ .id = 3, .is_alert = false, .freed_log = &log_entries });
    worker.pushAlert(.{ .id = 4, .is_alert = true, .freed_log = &log_entries }, 1);

    var buffer: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 1, 3, 4 }, drainIds(&worker, &buffer));
    try testing.expectEqualSlices(u8, &.{2}, log_entries.freed());
}

test "pushAlert keeps the new alert when max_waiting is 0" {
    var log_entries: FreedLog = .{};
    var worker: TestWorker = .{ .io = testing.io, .allocator = testing.allocator };
    worker.pushAlert(.{ .id = 1, .is_alert = true, .freed_log = &log_entries }, 0);
    worker.pushAlert(.{ .id = 2, .is_alert = true, .freed_log = &log_entries }, 0);

    var buffer: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{2}, drainIds(&worker, &buffer));
    try testing.expectEqualSlices(u8, &.{1}, log_entries.freed());
}

test "pushAlert drops minor alerts before older ones that aren't" {
    var log_entries: FreedLog = .{};
    var worker: TestWorker = .{ .io = testing.io, .allocator = testing.allocator };
    worker.push(.{ .id = 1, .is_alert = true, .freed_log = &log_entries });
    worker.push(.{ .id = 2, .is_alert = true, .is_minor = true, .freed_log = &log_entries });
    worker.pushAlert(.{ .id = 3, .is_alert = true, .freed_log = &log_entries }, 2);

    var buffer: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 1, 3 }, drainIds(&worker, &buffer));
    try testing.expectEqualSlices(u8, &.{2}, log_entries.freed());
}

test "a new minor alert never pushes out one that isn't" {
    var log_entries: FreedLog = .{};
    var worker: TestWorker = .{ .io = testing.io, .allocator = testing.allocator };
    worker.push(.{ .id = 1, .is_alert = true, .freed_log = &log_entries });
    worker.pushAlert(.{ .id = 2, .is_alert = true, .is_minor = true, .freed_log = &log_entries }, 1);

    var buffer: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{1}, drainIds(&worker, &buffer));
    try testing.expectEqualSlices(u8, &.{2}, log_entries.freed());
}

test "the worker is busy from taking a command until it finds the queue empty" {
    var log_entries: FreedLog = .{};
    var worker: TestWorker = .{ .io = testing.io, .allocator = testing.allocator };
    try testing.expect(worker.isIdle());
    worker.push(.{ .id = 1, .is_alert = true, .freed_log = &log_entries });
    try testing.expect(!worker.isIdle());

    const taken = worker.next() orelse return error.TestExpectedCommand;
    taken.deinit(testing.allocator);
    try testing.expect(!worker.isIdle());
    try testing.expectEqual(null, worker.next());
    try testing.expect(worker.isIdle());
    var buffer: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{}, drainIds(&worker, &buffer));
}

test "push keeps every alert" {
    var log_entries: FreedLog = .{};
    var worker: TestWorker = .{ .io = testing.io, .allocator = testing.allocator };
    for (1..4) |id| worker.push(.{ .id = @intCast(id), .is_alert = true, .freed_log = &log_entries });

    var buffer: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, drainIds(&worker, &buffer));
    try testing.expectEqual(@as(usize, 0), log_entries.count);
}
