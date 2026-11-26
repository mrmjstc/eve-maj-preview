//! Steps waiting for their time: activity bursts, jump routes and test scenarios; no I/O.
const std = @import("std");
const lines = @import("lines.zig");

/// Which logs a move is written to.
pub const Via = enum {
    /// A gate jump: the gamelog's jump line and Local's change.
    both,
    gamelog,
    /// A pod or filament move, which writes no jump line.
    local,
};

/// What a step belongs to, so a client's running work can be shown and stopped by kind.
pub const Task = enum {
    bounty,
    mining,
    combat,
    route,
    storm,
    scenario,

    pub fn label(self: Task) []const u8 {
        return switch (self) {
            .bounty => "bounties",
            .mining => "mining",
            .combat => "combat",
            .route => "route",
            .storm => "alerts",
            .scenario => "test",
        };
    }
};

pub const Move = struct {
    /// Owned by the schedule once added.
    system: []const u8,
    via: Via = .both,
    /// Stamps the lines this far in the past, as a log read late would be; the character then stays put.
    age_seconds: u32 = 0,
};

pub const Chat = struct {
    /// Owned by the schedule once added.
    channel: []const u8,
    /// Owned by the schedule once added.
    speaker: []const u8,
    /// Owned by the schedule once added.
    text: []const u8,
};

pub const Action = union(enum) {
    move: Move,
    alert: lines.Alert,
    activity: lines.Activity,
    /// One of the combat lines, picked as it runs.
    mixed_combat,
    /// Into lines.MINING_REPLAY.
    mining: usize,
    chat: Chat,
    /// What the app should show now; owned by the schedule once added.
    expect: []const u8,
};

pub const Step = struct {
    /// On the schedule's own clock, e.g. win32.Ticks' ms.
    due_ms: u64,
    /// Owned by the schedule; empty for a step that isn't about one client.
    client: []const u8,
    task: Task,
    action: Action,
};

pub const Schedule = struct {
    allocator: std.mem.Allocator,
    /// Soonest first, and in the order added among steps due together.
    steps: std.ArrayList(Step) = .empty,

    pub fn init(allocator: std.mem.Allocator) Schedule {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Schedule) void {
        for (self.steps.items) |step| self.free(step);
        self.steps.deinit(self.allocator);
    }

    /// Copies `client` and the action's strings.
    pub fn add(self: *Schedule, due_ms: u64, client: []const u8, task: Task, action: Action) !void {
        var step: Step = .{ .due_ms = due_ms, .client = try self.allocator.dupe(u8, client), .task = task, .action = action };
        errdefer self.allocator.free(step.client);
        step.action = try self.ownAction(action);
        errdefer self.freeAction(step.action);
        var at = self.steps.items.len;
        while (at > 0 and self.steps.items[at - 1].due_ms > due_ms) at -= 1;
        try self.steps.insert(self.allocator, at, step);
    }

    /// The soonest step due by `now_ms`, removed; the caller runs it, then passes it to `free`.
    pub fn takeDue(self: *Schedule, now_ms: u64) ?Step {
        if (self.steps.items.len == 0 or self.steps.items[0].due_ms > now_ms) return null;
        return self.steps.orderedRemove(0);
    }

    /// For a step takeDue returned.
    pub fn free(self: *const Schedule, step: Step) void {
        self.allocator.free(step.client);
        self.freeAction(step.action);
    }

    /// Drops the steps for `client` (any when null) belonging to `task` (any when null); returns how many.
    pub fn cancel(self: *Schedule, client: ?[]const u8, task: ?Task) usize {
        var kept_count: usize = 0;
        var dropped_count: usize = 0;
        for (self.steps.items) |step| {
            if (matches(step, client, task)) {
                self.free(step);
                dropped_count += 1;
                continue;
            }
            self.steps.items[kept_count] = step;
            kept_count += 1;
        }
        self.steps.shrinkRetainingCapacity(kept_count);
        return dropped_count;
    }

    pub fn isRunning(self: *const Schedule, client: []const u8, task: Task) bool {
        for (self.steps.items) |step| {
            if (matches(step, client, task)) return true;
        }
        return false;
    }

    /// Steps left of `task`, for any client.
    pub fn pendingCount(self: *const Schedule, task: Task) usize {
        var count: usize = 0;
        for (self.steps.items) |step| {
            if (step.task == task) count += 1;
        }
        return count;
    }

    /// A test's steps still to come, counted by what each expects.
    pub fn expectationCount(self: *const Schedule) usize {
        var count: usize = 0;
        for (self.steps.items) |step| {
            switch (step.action) {
                .expect => count += 1,
                .move, .alert, .activity, .mixed_combat, .mining, .chat => {},
            }
        }
        return count;
    }

    fn ownAction(self: *const Schedule, action: Action) !Action {
        const allocator = self.allocator;
        return switch (action) {
            .move => |move| .{ .move = .{ .system = try allocator.dupe(u8, move.system), .via = move.via, .age_seconds = move.age_seconds } },
            .chat => |chat| blk: {
                const channel = try allocator.dupe(u8, chat.channel);
                errdefer allocator.free(channel);
                const speaker = try allocator.dupe(u8, chat.speaker);
                errdefer allocator.free(speaker);
                break :blk .{ .chat = .{ .channel = channel, .speaker = speaker, .text = try allocator.dupe(u8, chat.text) } };
            },
            .expect => |text| .{ .expect = try allocator.dupe(u8, text) },
            .alert, .activity, .mixed_combat, .mining => action,
        };
    }

    fn freeAction(self: *const Schedule, action: Action) void {
        switch (action) {
            .move => |move| self.allocator.free(move.system),
            .chat => |chat| {
                self.allocator.free(chat.channel);
                self.allocator.free(chat.speaker);
                self.allocator.free(chat.text);
            },
            .expect => |text| self.allocator.free(text),
            .alert, .activity, .mixed_combat, .mining => {},
        }
    }
};

fn matches(step: Step, client: ?[]const u8, task: ?Task) bool {
    if (client) |name| {
        if (!std.mem.eql(u8, step.client, name)) return false;
    }
    if (task) |kind| {
        if (step.task != kind) return false;
    }
    return true;
}

const testing = std.testing;

test "steps come due soonest first, in the order added among equals" {
    var schedule: Schedule = .init(testing.allocator);
    defer schedule.deinit();
    try schedule.add(200, "A", .route, .{ .move = .{ .system = "Amarr" } });
    try schedule.add(100, "A", .route, .{ .move = .{ .system = "Jita" } });
    try schedule.add(100, "B", .route, .{ .move = .{ .system = "Rens" } });
    try testing.expect(schedule.takeDue(99) == null);
    const expected = [_][]const u8{ "Jita", "Rens", "Amarr" };
    for (expected) |system| {
        const step = schedule.takeDue(1000) orelse return error.TestUnexpectedResult;
        defer schedule.free(step);
        try testing.expectEqualStrings(system, step.action.move.system);
    }
}

test "cancelling a client's task leaves its other work and other clients alone" {
    var schedule: Schedule = .init(testing.allocator);
    defer schedule.deinit();
    try schedule.add(100, "A", .bounty, .{ .activity = .bounty });
    try schedule.add(100, "A", .mining, .{ .mining = 0 });
    try schedule.add(100, "B", .bounty, .{ .activity = .bounty });
    try schedule.add(100, "", .scenario, .{ .chat = .{ .channel = "Fleet", .speaker = "FC", .text = "bubble" } });
    try testing.expectEqual(@as(usize, 1), schedule.cancel("A", .bounty));
    try testing.expect(schedule.isRunning("A", .mining));
    try testing.expect(schedule.isRunning("B", .bounty));
    try testing.expectEqual(@as(usize, 1), schedule.pendingCount(.scenario));
    try testing.expectEqual(@as(usize, 3), schedule.cancel(null, null));
}
