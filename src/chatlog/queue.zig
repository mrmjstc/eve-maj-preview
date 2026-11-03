//! What the main thread and the chatlog worker send each other.
const std = @import("std");
const notification_mod = @import("../notifications/notification.zig");
const universe = @import("../map/universe.zig");

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

/// Worker to main thread, which resolves the hwnd since only it may touch Scout and ThumbnailSet.
pub const SystemUpdate = struct {
    /// Owned; freed in deinit.
    character_name: []const u8,
    /// Owned; freed in deinit.
    system_name: []const u8,
    /// YYYYMMDDHHMMSS of the line it came from; 0 if unreadable, which skips the staleness check.
    event_timestamp: u64,
    /// Stargate and conduit jumps only, for Travel Mode.
    is_jump: bool = false,

    pub fn deinit(self: *SystemUpdate, allocator: std.mem.Allocator) void {
        allocator.free(self.character_name);
        allocator.free(self.system_name);
    }
};

/// Worker to main thread: when a character's session began, from its gamelog's name.
pub const SessionStart = struct {
    /// Owned; freed in deinit.
    character_name: []const u8,
    /// UTC Unix seconds.
    started_at: i64,

    pub fn deinit(self: *SessionStart, allocator: std.mem.Allocator) void {
        allocator.free(self.character_name);
    }
};

/// Worker to main thread: a system named in an intel channel, for the map and Intel Panel.
pub const IntelSighting = struct {
    system: universe.SystemIndex,
    /// The whole message; owned, freed in deinit.
    message: []const u8,
    /// The message calls this system clear, rather than reporting something in it.
    is_clear: bool,
    /// It goes on the map; a rule's exclusions keep a line in the Intel Panel but off the map.
    is_pinned: bool,
    /// The first system its message names, so the Intel Panel lists the message once.
    is_message_first: bool,

    pub fn deinit(self: *IntelSighting, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

/// Worker to main thread, which renders the text from per-type config.
pub const NotificationEvent = struct {
    /// Owned; freed in deinit.
    character_name: []const u8,
    /// Its source, target, channel, message and jumps are owned copies, freed in deinit.
    notification: notification_mod.Notification,

    pub fn deinit(self: *NotificationEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.character_name);
        if (self.notification.source) |s| allocator.free(s);
        if (self.notification.target) |t| allocator.free(t);
        if (self.notification.channel) |channel| allocator.free(channel);
        if (self.notification.message) |message| allocator.free(message);
        if (self.notification.jumps) |jumps| allocator.free(jumps);
    }
};

/// `T` owns memory it frees with `deinit(allocator)`.
pub fn Queue(comptime T: type) type {
    return struct {
        mutex: std.Io.Mutex = .init,
        /// Guarded by mutex.
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

const testing = std.testing;

fn sessionStart(allocator: std.mem.Allocator, character_name: []const u8) !SessionStart {
    return .{ .character_name = try allocator.dupe(u8, character_name), .started_at = 0 };
}

test "drain moves everything queued, in order, and empties the queue" {
    var queue: Queue(SessionStart) = .init(testing.allocator, testing.io);
    defer queue.deinit();
    try queue.push(try sessionStart(testing.allocator, "Alpha"));
    try queue.push(try sessionStart(testing.allocator, "Bravo"));

    var out: std.ArrayList(SessionStart) = .empty;
    defer {
        for (out.items) |*item| item.deinit(testing.allocator);
        out.deinit(testing.allocator);
    }
    try queue.drain(&out);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("Alpha", out.items[0].character_name);
    try testing.expectEqualStrings("Bravo", out.items[1].character_name);
    try testing.expectEqual(@as(usize, 0), queue.items.items.len);
}

test "deinit frees what is still queued" {
    var queue: Queue(SessionStart) = .init(testing.allocator, testing.io);
    defer queue.deinit();
    try queue.push(try sessionStart(testing.allocator, "Alpha"));
}

test "push frees the item when it can't be queued" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    const allocator = failing.allocator();
    var queue: Queue(SessionStart) = .init(allocator, testing.io);
    defer queue.deinit();

    try testing.expectError(error.OutOfMemory, queue.push(try sessionStart(allocator, "Alpha")));
}
