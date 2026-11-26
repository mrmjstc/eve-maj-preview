//! Opt-in copies of what each window last drew, for the end-to-end tests' state file; only App creates one, and only while the state file is on.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.Scoped("recorder");

/// `T` is what one render records, with defaults for every field.
pub fn Recorder(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        /// Keyed by window handle; each value owned, freed in deinit.
        by_window: std.AutoHashMapUnmanaged(usize, *T) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            var it = self.by_window.valueIterator();
            while (it.next()) |recorded| self.allocator.destroy(recorded.*);
            self.by_window.deinit(self.allocator);
        }

        /// The window's record, reset for a new render; null, logged, when it can't be made.
        pub fn begin(self: *Self, window: usize) ?*T {
            const entry = self.by_window.getOrPut(self.allocator, window) catch |err| {
                slog.warn("Failed to make room to record a window's render: {}", .{err});
                return null;
            };
            if (!entry.found_existing) {
                entry.value_ptr.* = self.allocator.create(T) catch |err| {
                    slog.warn("Failed to record a window's render: {}", .{err});
                    _ = self.by_window.remove(window);
                    return null;
                };
            }
            entry.value_ptr.*.* = .{};
            return entry.value_ptr.*;
        }

        /// Null before the window's first recorded render.
        pub fn find(self: *const Self, window: usize) ?*const T {
            return self.by_window.get(window);
        }
    };
}

const testing = std.testing;

const Sample = struct { value: u32 = 0 };

test "begin resets a window's record and find returns it" {
    var recorder: Recorder(Sample) = .init(testing.allocator);
    defer recorder.deinit();
    recorder.begin(7).?.value = 3;
    try testing.expectEqual(3, recorder.find(7).?.value);
    try testing.expectEqual(0, recorder.begin(7).?.value);
    try testing.expectEqual(null, recorder.find(8));
}
