//! Characters with a recent game-event notification, oldest first, for the cycle-to-notified hotkey.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");

const slog = log.Scoped("notified_queue");

pub const NotifiedQueue = struct {
    const Entry = struct {
        /// Owned, since it outlives ThumbnailWindow.character_name, which is freed on window close.
        character_name: []const u8,
        notified_at: win32.Ticks,
    };

    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *NotifiedQueue, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.character_name);
        self.entries.deinit(allocator);
    }

    /// Re-notifying bumps the character to the back instead of duplicating.
    pub fn track(self: *NotifiedQueue, allocator: std.mem.Allocator, character_name: []const u8, now: win32.Ticks) void {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.character_name, character_name)) {
                const existing = self.entries.orderedRemove(i);
                self.entries.append(allocator, .{
                    .character_name = existing.character_name,
                    .notified_at = now,
                }) catch |err| {
                    slog.err("Failed to requeue notified character '{s}': {}", .{ character_name, err });
                    allocator.free(existing.character_name);
                };
                return;
            }
        }

        const owned_name = allocator.dupe(u8, character_name) catch |err| {
            slog.err("Failed to track notified character '{s}': {}", .{ character_name, err });
            return;
        };
        self.entries.append(allocator, .{ .character_name = owned_name, .notified_at = now }) catch |err| {
            slog.err("Failed to queue notified character '{s}': {}", .{ character_name, err });
            allocator.free(owned_name);
        };
    }

    /// Oldest first, borrowing the queue's storage until the next track call; the caller frees the list with out_allocator.
    pub fn namesWithin(self: *const NotifiedQueue, out_allocator: std.mem.Allocator, retention_ms: u64, now: win32.Ticks) !std.ArrayList([]const u8) {
        var result: std.ArrayList([]const u8) = .empty;
        errdefer result.deinit(out_allocator);

        for (self.entries.items) |entry| {
            if (now.elapsedSince(entry.notified_at) <= retention_ms) {
                try result.append(out_allocator, entry.character_name);
            }
        }
        return result;
    }
};

const testing = std.testing;

fn expectNames(queue: *const NotifiedQueue, retention_ms: u64, now_ms: u64, expected: []const []const u8) !void {
    var names = try queue.namesWithin(testing.allocator, retention_ms, .{ .ms = now_ms });
    defer names.deinit(testing.allocator);
    try testing.expectEqual(expected.len, names.items.len);
    for (expected, names.items) |expected_name, name| try testing.expectEqualStrings(expected_name, name);
}

test "names come oldest first" {
    var queue: NotifiedQueue = .{};
    defer queue.deinit(testing.allocator);
    queue.track(testing.allocator, "Alpha", .{ .ms = 1_000 });
    queue.track(testing.allocator, "Bravo", .{ .ms = 2_000 });

    try expectNames(&queue, 10_000, 3_000, &.{ "Alpha", "Bravo" });
}

test "a character notified again moves to the back instead of repeating" {
    var queue: NotifiedQueue = .{};
    defer queue.deinit(testing.allocator);
    queue.track(testing.allocator, "Alpha", .{ .ms = 1_000 });
    queue.track(testing.allocator, "Bravo", .{ .ms = 2_000 });
    queue.track(testing.allocator, "Alpha", .{ .ms = 3_000 });

    try expectNames(&queue, 10_000, 4_000, &.{ "Bravo", "Alpha" });
}

test "a notification older than the retention is left out" {
    var queue: NotifiedQueue = .{};
    defer queue.deinit(testing.allocator);
    queue.track(testing.allocator, "Alpha", .{ .ms = 1_000 });
    queue.track(testing.allocator, "Bravo", .{ .ms = 5_000 });

    try expectNames(&queue, 3_000, 6_000, &.{"Bravo"});
    try expectNames(&queue, 5_000, 6_000, &.{ "Alpha", "Bravo" });
}

test "a requeue refreshes the time the retention counts from" {
    var queue: NotifiedQueue = .{};
    defer queue.deinit(testing.allocator);
    queue.track(testing.allocator, "Alpha", .{ .ms = 1_000 });
    queue.track(testing.allocator, "Alpha", .{ .ms = 5_000 });

    try expectNames(&queue, 3_000, 6_000, &.{"Alpha"});
}

test "the queue keeps its own copy of each name" {
    var queue: NotifiedQueue = .{};
    defer queue.deinit(testing.allocator);
    var name_buf = "Alpha".*;
    queue.track(testing.allocator, &name_buf, .{ .ms = 1_000 });
    name_buf[0] = 'X';

    try expectNames(&queue, 10_000, 2_000, &.{"Alpha"});
}
