//! What the main thread and the chatlog worker send each other.
const std = @import("std");
const notification_mod = @import("../notifications/notification.zig");

/// Main thread to worker; each name is owned by the command.
pub const Command = union(enum) {
    add_character: []const u8,
    remove_character: []const u8,
    /// Learns the character's ID from its logs without following them.
    resolve_character_id: []const u8,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |name| allocator.free(name),
        }
    }
};

/// Worker to main thread, which resolves the hwnd: only the main thread may touch Scout and Painter.
pub const SystemUpdate = struct {
    character_name: []const u8,
    system_name: []const u8,
    /// 0 skips the staleness check; live-tail lines arrive in order.
    event_ts: u64,
    /// Stargate and conduit jumps only, for Travel Mode.
    is_jump: bool = false,

    pub fn deinit(self: *SystemUpdate, allocator: std.mem.Allocator) void {
        allocator.free(self.character_name);
        allocator.free(self.system_name);
    }
};

/// Worker to main thread: when a character's session began, by its gamelog's name.
pub const SessionStart = struct {
    character_name: []const u8,
    /// UTC Unix seconds.
    started_at: i64,

    pub fn deinit(self: *SessionStart, allocator: std.mem.Allocator) void {
        allocator.free(self.character_name);
    }
};

/// Worker to main thread, where the text is rendered from per-type config.
pub const NotificationEvent = struct {
    character_name: []const u8,
    /// source/target are owned copies.
    notification: notification_mod.Notification,

    pub fn deinit(self: *NotificationEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.character_name);
        if (self.notification.source) |s| allocator.free(s);
        if (self.notification.target) |t| allocator.free(t);
    }
};

/// `T` owns memory it frees with `deinit(allocator)`.
pub fn Queue(comptime T: type) type {
    return struct {
        mutex: std.Io.Mutex = .init,
        items: std.ArrayList(T) = .empty,
        allocator: std.mem.Allocator,
        io: std.Io,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
            return .{ .allocator = allocator, .io = io };
        }

        /// Frees anything still queued; only once neither thread uses the queue.
        pub fn deinit(self: *Self) void {
            for (self.items.items) |*item| item.deinit(self.allocator);
            self.items.deinit(self.allocator);
        }

        /// Takes ownership of `item`, freeing it if it can't be queued.
        pub fn push(self: *Self, item: T) !void {
            var owned = item;
            errdefer owned.deinit(self.allocator);
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            try self.items.append(self.allocator, owned);
        }

        /// Moves everything queued into `out`, which then owns it.
        pub fn drain(self: *Self, out: *std.ArrayList(T)) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            try out.appendSlice(self.allocator, self.items.items);
            self.items.clearRetainingCapacity();
        }
    };
}
