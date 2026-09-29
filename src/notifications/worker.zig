//! A lazily started thread that runs queued commands in order on an engine it owns; shared by speech and sound alerts.
const std = @import("std");
const log = @import("../log.zig");

const POLL_MS: i64 = 50;

/// `Engine` has `init() !Engine`, `run(*Engine, Command)` and `deinit(*Engine)`, all called on the worker thread.
/// `Command` has `deinit(Command)`, which frees whatever it owns once it has run or been dropped at shutdown.
/// `description` names the feature in log messages, e.g. "text-to-speech".
pub fn Worker(comptime Command: type, comptime Engine: type, comptime scope: []const u8, comptime description: []const u8) type {
    const slog = log.scoped(scope);

    return struct {
        /// Set once, before the first command.
        io: std.Io = undefined,
        mutex: std.Io.Mutex = .init,
        /// Guarded by mutex.
        queue: std.ArrayList(Command) = .empty,
        /// Main thread only.
        thread: ?std.Thread = null,
        /// Main thread only; set once the worker can't start, so it isn't retried.
        failed: bool = false,
        should_exit: std.atomic.Value(bool) = .init(false),
        /// Set by the worker when its engine fails to start.
        engine_failed: std.atomic.Value(bool) = .init(false),

        const Self = @This();

        /// Starts the thread on first use; false if it isn't running and won't be.
        pub fn start(self: *Self) bool {
            if (self.thread) |thread| {
                if (!self.engine_failed.load(.acquire)) return true;
                thread.join();
                self.thread = null;
                self.failed = true;
                return false;
            }
            if (self.failed) return false;

            self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
                slog.warn("Failed to start the {s} thread: {}", .{ description, err });
                self.failed = true;
                return false;
            };
            return true;
        }

        /// Takes ownership of `command`, freeing it if it can't be queued.
        pub fn push(self: *Self, command: Command) void {
            self.append(command) catch |err| {
                slog.warn("Failed to queue a {s} command: {}", .{ description, err });
                command.deinit();
            };
        }

        /// Call once during app shutdown; drops anything still queued.
        pub fn shutdown(self: *Self) void {
            const thread = self.thread orelse return;
            self.should_exit.store(true, .release);
            thread.join();
            self.thread = null;
            while (self.pop()) |command| command.deinit();
        }

        fn append(self: *Self, command: Command) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            try self.queue.append(std.heap.page_allocator, command);
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

        fn run(self: *Self) void {
            var engine = Engine.init() catch |err| {
                slog.warn("Failed to start {s}, so its alerts won't play: {}", .{ description, err });
                self.engine_failed.store(true, .release);
                return;
            };
            defer engine.deinit();
            slog.info("Started {s}", .{description});

            while (!self.should_exit.load(.acquire)) {
                const command = self.pop() orelse {
                    std.Io.sleep(self.io, .fromMilliseconds(POLL_MS), .awake) catch |err| {
                        slog.debug("Failed to sleep between {s} polls: {}", .{ description, err });
                    };
                    continue;
                };
                defer command.deinit();
                engine.run(command);
            }
        }
    };
}
