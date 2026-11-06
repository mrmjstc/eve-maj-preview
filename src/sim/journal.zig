//! The simulator's activity feed: what it wrote, what to expect, and what went wrong, newest last; no I/O.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.Scoped("sim");

/// Older entries are dropped past this.
const CAPACITY = 400;
/// Longer text is cut, so an entry never needs more than one allocation.
const MAX_TEXT_LENGTH = 600;

/// "HH:mm:ss" local time.
pub const Clock = [8]u8;

pub const Kind = enum {
    info,
    success,
    /// What the app should now show; read against the thumbnails.
    expect,
    warning,
    failure,
};

pub const Entry = struct {
    kind: Kind,
    /// When it was added.
    clock: Clock,
    /// Owned; freed when the entry is dropped.
    text: []const u8,
};

pub const Journal = struct {
    allocator: std.mem.Allocator,
    /// Oldest first.
    entries: std.ArrayList(Entry) = .empty,
    /// Bumped by every add, so a view can tell new entries arrived.
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Journal {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Journal) void {
        for (self.entries.items) |entry| self.allocator.free(entry.text);
        self.entries.deinit(self.allocator);
    }

    /// An entry that can't be stored is dropped, since the feed is only a view.
    pub fn add(self: *Journal, kind: Kind, clock: Clock, comptime text_format: []const u8, args: anytype) void {
        var text_buf: [MAX_TEXT_LENGTH]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&text_buf);
        writer.print(text_format, args) catch |err| switch (err) {
            // Full: what fits is kept.
            error.WriteFailed => {},
        };
        const owned = self.allocator.dupe(u8, writer.buffered()) catch |err| {
            slog.warn("Failed to add to the activity feed: {}", .{err});
            return;
        };
        if (self.entries.items.len == CAPACITY) {
            self.allocator.free(self.entries.orderedRemove(0).text);
        }
        self.entries.append(self.allocator, .{ .kind = kind, .clock = clock, .text = owned }) catch |err| {
            slog.warn("Failed to add to the activity feed: {}", .{err});
            self.allocator.free(owned);
            return;
        };
        self.revision += 1;
    }

    pub fn clear(self: *Journal) void {
        for (self.entries.items) |entry| self.allocator.free(entry.text);
        self.entries.clearRetainingCapacity();
        self.revision += 1;
    }
};

const testing = std.testing;
const TEST_CLOCK: Clock = "21:04:05".*;

test "the journal keeps only its newest entries" {
    var journal: Journal = .init(testing.allocator);
    defer journal.deinit();
    for (0..CAPACITY + 3) |index| journal.add(.info, TEST_CLOCK, "entry {d}", .{index});
    try testing.expectEqual(@as(usize, CAPACITY), journal.entries.items.len);
    try testing.expectEqualStrings("entry 3", journal.entries.items[0].text);
}

test "an overlong entry is cut rather than dropped" {
    var journal: Journal = .init(testing.allocator);
    defer journal.deinit();
    const long: [MAX_TEXT_LENGTH + 50]u8 = @splat('x');
    journal.add(.warning, TEST_CLOCK, "{s}", .{&long});
    try testing.expectEqual(@as(usize, MAX_TEXT_LENGTH), journal.entries.items[0].text.len);
}
