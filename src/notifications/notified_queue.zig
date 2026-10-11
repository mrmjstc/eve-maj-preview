//! Characters with a recent game-event notification, oldest first, for the cycle-to-notified hotkey.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");

const slog = log.Scoped("notified_queue");

pub const NotifiedQueue = struct {
    /// Owns a copy of the name since it must outlive ThumbnailWindow.character_name, which is freed on window close.
    const Entry = struct {
        character_name: []const u8,
        notified_at: win32.Ticks,
    };

    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *NotifiedQueue, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.character_name);
        self.entries.deinit(allocator);
    }

    /// Re-notifying bumps the character to the back instead of duplicating.
    pub fn track(self: *NotifiedQueue, allocator: std.mem.Allocator, character_name: []const u8) void {
        const now = win32.Ticks.now();

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

    /// Names notified within retention_ms, oldest first, borrowing the queue's storage until the next track call; the caller frees the list with out_allocator.
    pub fn namesWithin(self: *const NotifiedQueue, out_allocator: std.mem.Allocator, retention_ms: u64) !std.ArrayList([]const u8) {
        const now = win32.Ticks.now();
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
