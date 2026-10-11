//! Per-character combat, mining and bounty rates over a sliding window.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.Scoped("activity_tracker");

/// Ring-buffer capacity per character; a window holding more events is rated over the time the newest 512 span.
const RING_CAPACITY = 512;

/// Guards against simultaneous multi-module/multi-weapon log lines spiking a warm-up rate computed over a near-zero span.
const MIN_RATE_SPAN_MS: i64 = 3 * std.time.ms_per_s;

/// Lines landing this soon after a streak's first one (lasers cycling in step, one volley) count as its first moment.
const FIRST_MOMENT_MS: i64 = 1 * std.time.ms_per_s;

const WindowSum = struct {
    total: f32 = 0,
    after_first_moment: f32 = 0,
    event_count: usize = 0,
    after_first_moment_count: usize = 0,
    newest_ms: i64 = 0,

    /// With nothing after the first moment, `to_now` rates the window's total as it will read once the streak is that old, and `to_newest` waits.
    const WarmUp = enum { to_now, to_newest };

    fn add(self: *WindowSum, amount: f32, timestamp_ms: i64, streak_start_ms: i64) void {
        self.total += amount;
        self.event_count += 1;
        self.newest_ms = @max(self.newest_ms, timestamp_ms);
        if (timestamp_ms - streak_start_ms >= FIRST_MOMENT_MS) {
            self.after_first_moment += amount;
            self.after_first_moment_count += 1;
        }
    }

    /// The window's total (a young streak's from its first moment) rated to now or the newest event, within what a full ring still covers; null while too short to trust.
    fn rate(self: WindowSum, streak_start_ms: i64, now_ms: i64, window_ms: i64, ring_full_from_ms: ?i64, warm_up: WarmUp) ?f32 {
        if (self.event_count == 0) return 0.0;
        if (ring_full_from_ms) |from_ms| {
            const covered_ms = now_ms - from_ms;
            if (covered_ms < MIN_RATE_SPAN_MS) return null;
            return self.total / seconds(covered_ms);
        }
        if (now_ms - streak_start_ms >= window_ms) return self.total / seconds(window_ms);
        if (self.after_first_moment_count == 0) {
            if (warm_up == .to_newest or now_ms - streak_start_ms < MIN_RATE_SPAN_MS) return null;
            return self.total / seconds(window_ms);
        }
        const end_ms = switch (warm_up) {
            .to_now => now_ms,
            .to_newest => self.newest_ms,
        };
        const elapsed_ms = end_ms - streak_start_ms;
        if (elapsed_ms < MIN_RATE_SPAN_MS) return null;
        return self.after_first_moment / seconds(elapsed_ms);
    }

    fn seconds(ms: i64) f32 {
        return @as(f32, @floatFromInt(ms)) / std.time.ms_per_s;
    }
};

pub const CombatEvent = struct {
    timestamp_ms: i64,
    amount: u32,
    is_incoming: bool,
};

pub const Dps = struct { incoming: ?f32, outgoing: ?f32 };

pub const CombatWindow = struct {
    ring: Ring(CombatEvent),
    last_incoming_hit_ms: i64 = 0,
    /// 0 = never fired.
    last_damage_alert_ms: i64 = 0,

    pub fn init(window_seconds: u32) CombatWindow {
        return .{ .ring = .init(window_seconds) };
    }

    /// One damage line. `counts_for_alert` only gates `last_incoming_hit_ms` (checkDamageAlert's trigger): the hit is always kept so DPS stays accurate for filtered hits.
    pub const Hit = struct { amount: u32, timestamp_ms: i64, is_incoming: bool, counts_for_alert: bool = true };

    pub fn addEntry(self: *CombatWindow, hit: Hit) void {
        self.ring.push(.{ .timestamp_ms = hit.timestamp_ms, .amount = hit.amount, .is_incoming = hit.is_incoming });
        if (hit.is_incoming and hit.counts_for_alert and hit.timestamp_ms > self.last_incoming_hit_ms) self.last_incoming_hit_ms = hit.timestamp_ms;
    }

    /// Fires once per burst of incoming damage and stays silent once combat stops; how often it repeats is the Notifications tab's throttle.
    pub fn checkDamageAlert(self: *CombatWindow) bool {
        if (self.last_incoming_hit_ms == 0) return false;
        if (self.last_incoming_hit_ms <= self.last_damage_alert_ms) return false;
        self.last_damage_alert_ms = self.last_incoming_hit_ms;
        return true;
    }

    /// Per second, or null while the span is too short to trust (see WindowSum.rate); warm-up runs to now, since hits arrive irregularly.
    pub fn computeDps(self: *const CombatWindow, now_ms: i64) Dps {
        const ring = &self.ring;
        if (ring.isQuiet(ring.window_ms, now_ms)) return .{ .incoming = 0.0, .outgoing = 0.0 };
        var incoming: WindowSum = .{};
        var outgoing: WindowSum = .{};
        var it = ring.recent(ring.window_ms, now_ms);
        while (it.next()) |entry| {
            const sum = if (entry.is_incoming) &incoming else &outgoing;
            sum.add(@floatFromInt(entry.amount), entry.timestamp_ms, ring.streak_start_ms);
        }
        return .{
            .incoming = incoming.rate(ring.streak_start_ms, now_ms, ring.window_ms, it.ringFullFrom(), .to_now),
            .outgoing = outgoing.rate(ring.streak_start_ms, now_ms, ring.window_ms, it.ringFullFrom(), .to_now),
        };
    }
};

pub const MiningEvent = struct {
    timestamp_ms: i64,
    m3: f32,
    isk: f32,
};

pub const MiningRates = struct { m3: ?f32, isk: ?f32 };

pub const MiningWindow = struct {
    ring: Ring(MiningEvent),
    /// When the idle alert fired, or 0; cleared once mining picks up again.
    last_idle_alert_ms: i64 = 0,
    /// When the stopped alert fired, or 0; cleared by the next yield.
    last_stopped_alert_ms: i64 = 0,

    pub fn init(window_seconds: u32) MiningWindow {
        return .{ .ring = .init(window_seconds) };
    }

    pub fn addEntry(self: *MiningWindow, m3: f32, isk: f32, timestamp_ms: i64) void {
        self.ring.push(.{ .timestamp_ms = timestamp_ms, .m3 = m3, .isk = isk });
        // Mining resumed, so the stopped alert can fire again.
        self.last_stopped_alert_ms = 0;
    }

    pub fn countEvents(self: *const MiningWindow, window_ms: i64, now_ms: i64) usize {
        return self.ring.countRecent(window_ms, now_ms);
    }

    /// m3 per second (see WindowSum.rate); warm-up runs to the newest yield, since yields come in cycles.
    pub fn computeRate(self: *const MiningWindow, now_ms: i64) ?f32 {
        return self.ring.rate("m3", now_ms, .to_newest);
    }

    /// ISK per second; see computeRate.
    pub fn computeIskRate(self: *const MiningWindow, now_ms: i64) ?f32 {
        return self.ring.rate("isk", now_ms, .to_newest);
    }

    pub fn computeRates(self: *const MiningWindow, now_ms: i64) MiningRates {
        return .{ .m3 = self.computeRate(now_ms), .isk = self.computeIskRate(now_ms) };
    }

    /// True once per idle stretch: at most `threshold` yields within `alert_window_ms`.
    pub fn checkIdleAlert(self: *MiningWindow, now_ms: i64, alert_window_ms: i64, threshold: u32) bool {
        // Never mined yet, so not idle: avoids alerting at startup.
        if (self.ring.last_hit_ms == 0) return false;
        if (self.countEvents(alert_window_ms, now_ms) > threshold) {
            self.last_idle_alert_ms = 0;
            return false;
        }
        if (now_ms - self.ring.streak_start_ms < alert_window_ms) return false;
        if (self.last_idle_alert_ms != 0) return false;
        self.last_idle_alert_ms = now_ms;
        return true;
    }

    /// True once when nothing has been mined for `stopped_window_ms`; the next yield re-arms it.
    pub fn checkStoppedAlert(self: *MiningWindow, now_ms: i64, stopped_window_ms: i64) bool {
        if (self.ring.last_hit_ms == 0) return false;
        if (now_ms - self.ring.last_hit_ms < stopped_window_ms) return false;
        if (self.last_stopped_alert_ms != 0) return false;
        self.last_stopped_alert_ms = now_ms;
        return true;
    }
};

pub const BountyEvent = struct {
    timestamp_ms: i64,
    isk: f32,
};

/// MiningWindow's ISK half, as payouts already arrive in ISK.
pub const BountyWindow = struct {
    ring: Ring(BountyEvent),

    pub fn init(window_seconds: u32) BountyWindow {
        return .{ .ring = .init(window_seconds) };
    }

    pub fn addEntry(self: *BountyWindow, isk: f32, timestamp_ms: i64) void {
        self.ring.push(.{ .timestamp_ms = timestamp_ms, .isk = isk });
    }

    /// ISK per second; see MiningWindow.computeRate.
    pub fn computeIskRate(self: *const BountyWindow, now_ms: i64) ?f32 {
        return self.ring.rate("isk", now_ms, .to_newest);
    }
};

pub const CombatTracker = Tracker(CombatWindow);
pub const MiningTracker = Tracker(MiningWindow);
pub const BountyTracker = Tracker(BountyWindow);

/// One locked Window per character, read by the main thread and fed by the chatlog worker; `Window` needs `init(window_seconds: u32)`, `addEntry` and a `ring` field.
pub fn Tracker(comptime Window: type) type {
    return struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        /// Guarded by mutex.
        windows: std.StringHashMap(Window),
        /// Changed only while the worker is stopped.
        window_seconds: u32,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, io: std.Io, window_seconds: u32) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .windows = .init(allocator),
                .window_seconds = window_seconds,
            };
        }

        /// Must only be called after the worker thread has stopped (no lock needed).
        pub fn deinit(self: *Self) void {
            var it = self.windows.keyIterator();
            while (it.next()) |key| self.allocator.free(key.*);
            self.windows.deinit();
        }

        /// Worker thread stopped only; existing history is kept and rated over the new length.
        pub fn setWindowSeconds(self: *Self, window_seconds: u32) void {
            self.window_seconds = window_seconds;
            var it = self.windows.valueIterator();
            while (it.next()) |window| window.ring.window_ms = @as(i64, window_seconds) * std.time.ms_per_s;
        }

        pub fn removeCharacter(self: *Self, character_name: []const u8) void {
            self.mutex.lock(self.io) catch |err| {
                slog.warn("Failed to lock tracker mutex removing '{s}': {}", .{ character_name, err });
                return;
            };
            defer self.mutex.unlock(self.io);
            if (self.windows.fetchRemove(character_name)) |entry| self.allocator.free(entry.key);
        }

        /// `args` are Window.addEntry's, after the window itself; the character's window is created on its first event.
        pub fn addEntry(self: *Self, character_name: []const u8, args: anytype) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            const window = try self.getOrCreate(character_name);
            @call(.auto, Window.addEntry, .{window} ++ args);
        }

        /// Runs `method` (a Window method) with `args` on the character's window under the lock; `fallback` when it has no window yet or the lock fails.
        pub fn query(
            self: *Self,
            character_name: []const u8,
            comptime method: anytype,
            args: anytype,
            fallback: @typeInfo(@TypeOf(method)).@"fn".return_type.?,
        ) @typeInfo(@TypeOf(method)).@"fn".return_type.? {
            self.mutex.lock(self.io) catch |err| {
                slog.warn("Failed to lock tracker mutex for '{s}': {}", .{ character_name, err });
                return fallback;
            };
            defer self.mutex.unlock(self.io);
            const window = self.windows.getPtr(character_name) orelse return fallback;
            return @call(.auto, method, .{window} ++ args);
        }

        /// Caller holds mutex.
        fn getOrCreate(self: *Self, character_name: []const u8) !*Window {
            if (self.windows.getPtr(character_name)) |window| return window;
            const key = try self.allocator.dupe(u8, character_name);
            errdefer self.allocator.free(key);
            try self.windows.put(key, Window.init(self.window_seconds));
            return self.windows.getPtr(character_name).?;
        }
    };
}

/// A fixed ring of recent events, so recording never allocates, with the streak and recency rates are measured from; `Event` needs a `timestamp_ms: i64` field.
fn Ring(comptime Event: type) type {
    return struct {
        entries: [RING_CAPACITY]Event = undefined,
        /// Next write slot, wraps mod RING_CAPACITY.
        head: usize = 0,
        /// Valid entry count, saturates at RING_CAPACITY.
        entry_count: usize = 0,
        window_ms: i64,
        last_hit_ms: i64 = 0,
        streak_start_ms: i64 = 0,

        const Self = @This();

        fn init(window_seconds: u32) Self {
            return .{ .window_ms = @as(i64, window_seconds) * std.time.ms_per_s };
        }

        /// Overwrites the oldest event once full; a whole window of quiet before it starts a new streak.
        fn push(self: *Self, event: Event) void {
            self.entries[self.head] = event;
            self.head = (self.head + 1) % RING_CAPACITY;
            if (self.entry_count < RING_CAPACITY) self.entry_count += 1;
            if (self.isQuiet(self.window_ms, event.timestamp_ms)) self.streak_start_ms = event.timestamp_ms;
            if (event.timestamp_ms > self.last_hit_ms) self.last_hit_ms = event.timestamp_ms;
        }

        /// Nothing has landed in the `window_ms` before now_ms.
        fn isQuiet(self: *const Self, window_ms: i64, now_ms: i64) bool {
            return self.last_hit_ms == 0 or now_ms - self.last_hit_ms >= window_ms;
        }

        /// The events in the `window_ms` before now_ms, newest first.
        fn recent(self: *const Self, window_ms: i64, now_ms: i64) Recent {
            return .{ .ring = self, .cutoff_ms = now_ms - window_ms, .oldest_ms = now_ms };
        }

        const Recent = struct {
            ring: *const Self,
            cutoff_ms: i64,
            index: usize = 0,
            oldest_ms: i64,

            fn next(self: *Recent) ?*const Event {
                if (self.index == self.ring.entry_count) return null;
                const entry = &self.ring.entries[(self.ring.head + RING_CAPACITY - 1 - self.index) % RING_CAPACITY];
                // The ring is in time order, so every older entry has expired too.
                if (entry.timestamp_ms < self.cutoff_ms) return null;
                self.index += 1;
                self.oldest_ms = entry.timestamp_ms;
                return entry;
            }

            /// Once iterated: the oldest event kept, if the ring filled up inside the window; see WindowSum.rate.
            fn ringFullFrom(self: *const Recent) ?i64 {
                return if (self.index == RING_CAPACITY) self.oldest_ms else null;
            }
        };

        /// `field` per second over the window ending at now_ms; see WindowSum.rate.
        fn rate(self: *const Self, comptime field: []const u8, now_ms: i64, warm_up: WindowSum.WarmUp) ?f32 {
            if (self.isQuiet(self.window_ms, now_ms)) return 0.0;
            var sum: WindowSum = .{};
            var it = self.recent(self.window_ms, now_ms);
            while (it.next()) |entry| sum.add(@field(entry, field), entry.timestamp_ms, self.streak_start_ms);
            return sum.rate(self.streak_start_ms, now_ms, self.window_ms, it.ringFullFrom(), warm_up);
        }

        fn countRecent(self: *const Self, window_ms: i64, now_ms: i64) usize {
            if (self.isQuiet(window_ms, now_ms)) return 0;
            var it = self.recent(window_ms, now_ms);
            var event_count: usize = 0;
            while (it.next()) |_| event_count += 1;
            return event_count;
        }
    };
}

const testing = std.testing;

test "CombatWindow withholds a rate until hits span three seconds, only for a direction with hits" {
    var window: CombatWindow = .init(10);
    window.addEntry(.{ .amount = 100, .timestamp_ms = 1_000, .is_incoming = true });
    window.addEntry(.{ .amount = 100, .timestamp_ms = 2_000, .is_incoming = true });
    const dps = window.computeDps(2_000);
    try testing.expect(dps.incoming == null);
    try testing.expectEqual(@as(f32, 0.0), dps.outgoing.?);
}

test "CombatWindow warms up on the hits after the first moment, over the time since" {
    var window: CombatWindow = .init(10);
    window.addEntry(.{ .amount = 100, .timestamp_ms = 1_000, .is_incoming = true });
    window.addEntry(.{ .amount = 50, .timestamp_ms = 3_000, .is_incoming = false });
    window.addEntry(.{ .amount = 100, .timestamp_ms = 5_000, .is_incoming = true });
    const dps = window.computeDps(5_000);
    try testing.expectEqual(@as(f32, 25.0), dps.incoming.?);
    try testing.expectEqual(@as(f32, 12.5), dps.outgoing.?);
}

test "CombatWindow shows a lone first-second volley over the window after 3 seconds" {
    var window: CombatWindow = .init(10);
    window.addEntry(.{ .amount = 100, .timestamp_ms = 1_000, .is_incoming = true });
    try testing.expect(window.computeDps(2_000).incoming == null);
    try testing.expectEqual(@as(f32, 10.0), window.computeDps(4_500).incoming.?);
}

test "MiningWindow waits for a second cycle after a lone first one" {
    var window: MiningWindow = .init(60);
    window.addEntry(30, 3_000, 1_000);
    try testing.expect(window.computeRate(10_000) == null);
}

test "CombatWindow rates a streak a window old as its total over the window" {
    var window: CombatWindow = .init(10);
    var timestamp_ms: i64 = 1_000;
    while (timestamp_ms <= 20_000) : (timestamp_ms += 1_000) window.addEntry(.{ .amount = 100, .timestamp_ms = timestamp_ms, .is_incoming = true });
    try testing.expectEqual(@as(f32, 100.0), window.computeDps(20_500).incoming.?);
}

test "CombatWindow reports zero once the last hit leaves the window" {
    var window: CombatWindow = .init(10);
    window.addEntry(.{ .amount = 100, .timestamp_ms = 1_000, .is_incoming = true });
    window.addEntry(.{ .amount = 100, .timestamp_ms = 5_000, .is_incoming = true });
    const dps = window.computeDps(15_000);
    try testing.expectEqual(@as(f32, 0.0), dps.incoming.?);
    try testing.expectEqual(@as(f32, 0.0), dps.outgoing.?);
}

test "CombatWindow keeps only the newest hits once the ring wraps" {
    var window: CombatWindow = .init(10);
    for (0..RING_CAPACITY + 88) |i| {
        window.addEntry(.{ .amount = 1, .timestamp_ms = 1_000 + @as(i64, @intCast(i)) * 10, .is_incoming = true });
    }
    try testing.expectEqual(@as(usize, RING_CAPACITY), window.ring.entry_count);
    const newest_ms = 1_000 + @as(i64, RING_CAPACITY + 87) * 10;
    const oldest_ms = 1_000 + @as(i64, 88) * 10;
    const span_seconds = @as(f32, @floatFromInt(newest_ms - oldest_ms)) / std.time.ms_per_s;
    try testing.expectApproxEqAbs(@as(f32, RING_CAPACITY) / span_seconds, window.computeDps(newest_ms).incoming.?, 0.01);
}

test "CombatWindow alerts once per burst of incoming damage" {
    var window: CombatWindow = .init(10);
    try testing.expect(!window.checkDamageAlert());

    window.addEntry(.{ .amount = 100, .timestamp_ms = 1_000, .is_incoming = true });
    try testing.expect(window.checkDamageAlert());
    try testing.expect(!window.checkDamageAlert());

    window.addEntry(.{ .amount = 100, .timestamp_ms = 2_000, .is_incoming = true, .counts_for_alert = false });
    try testing.expect(!window.checkDamageAlert());

    window.addEntry(.{ .amount = 100, .timestamp_ms = 3_000, .is_incoming = true });
    try testing.expect(window.checkDamageAlert());
}

test "MiningWindow warms up on the yields after the first, to the newest" {
    var window: MiningWindow = .init(60);
    window.addEntry(30, 3_000, 1_000);
    window.addEntry(30, 3_000, 4_000);
    try testing.expectEqual(@as(f32, 10.0), window.computeRate(4_000).?);
    try testing.expectEqual(@as(f32, 1_000.0), window.computeIskRate(4_000).?);
    try testing.expectEqual(@as(f32, 10.0), window.computeRate(9_000).?);
    try testing.expectEqual(@as(usize, 2), window.countEvents(60_000, 4_000));
    try testing.expectEqual(@as(usize, 1), window.countEvents(1_000, 4_000));
}

test "MiningWindow counts two lasers yielding together as one cycle" {
    var window: MiningWindow = .init(60);
    var timestamp_ms: i64 = 1_000;
    while (timestamp_ms <= 37_000) : (timestamp_ms += 12_000) {
        window.addEntry(110, 0, timestamp_ms);
        window.addEntry(110, 0, timestamp_ms);
    }
    try testing.expectApproxEqAbs(@as(f32, 220.0 / 12.0), window.computeRate(40_000).?, 0.001);
}

test "MiningWindow rates a streak a window old as its total over the window" {
    var window: MiningWindow = .init(60);
    var timestamp_ms: i64 = 1_000;
    while (timestamp_ms <= 121_000) : (timestamp_ms += 12_000) window.addEntry(110, 0, timestamp_ms);
    try testing.expectApproxEqAbs(@as(f32, 550.0 / 60.0), window.computeRate(121_500).?, 0.001);
}

test "MiningWindow starts a new streak after a whole window of quiet" {
    var window: MiningWindow = .init(60);
    window.addEntry(110, 0, 1_000);
    window.addEntry(110, 0, 13_000);
    window.addEntry(110, 0, 100_000);
    try testing.expect(window.computeRate(100_000) == null);
}

test "BountyWindow reports zero before the first payout" {
    const window: BountyWindow = .init(60);
    try testing.expectEqual(@as(f32, 0.0), window.computeIskRate(1_000).?);
}

test "MiningTracker idle alert fires once per idle stretch" {
    var tracker: MiningTracker = .init(testing.allocator, testing.io, 60);
    defer tracker.deinit();

    try testing.expect(!tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ 1_000, 60_000, 2 }, false));

    try tracker.addEntry("Some Pilot", .{ 10, 0, 1_000 });
    try testing.expect(tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ 61_000, 60_000, 2 }, false));
    try testing.expect(!tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ 61_500, 60_000, 2 }, false));

    for ([_]i64{ 62_000, 63_000, 64_000 }) |timestamp_ms| try tracker.addEntry("Some Pilot", .{ 10, 0, timestamp_ms });
    try testing.expect(!tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ 64_000, 60_000, 2 }, false));
    try testing.expect(tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ 200_000, 60_000, 2 }, false));
}

test "MiningTracker idle alert waits until mining has run a whole detection window" {
    var tracker: MiningTracker = .init(testing.allocator, testing.io, 60);
    defer tracker.deinit();
    try tracker.addEntry("Some Pilot", .{ 110, 0, 1_000 });
    try testing.expect(!tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ 1_000, 30_000, 1 }, false));
    try testing.expect(!tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ 30_000, 30_000, 1 }, false));
    try testing.expect(tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ 31_000, 30_000, 1 }, false));
}

test "MiningTracker stopped alert fires once until mining resumes" {
    var tracker: MiningTracker = .init(testing.allocator, testing.io, 60);
    defer tracker.deinit();

    try tracker.addEntry("Some Pilot", .{ 10, 0, 4_000 });
    try testing.expect(!tracker.query("Some Pilot", MiningWindow.checkStoppedAlert, .{ 5_000, 30_000 }, false));
    try testing.expect(tracker.query("Some Pilot", MiningWindow.checkStoppedAlert, .{ 40_000, 30_000 }, false));
    try testing.expect(!tracker.query("Some Pilot", MiningWindow.checkStoppedAlert, .{ 41_000, 30_000 }, false));

    try tracker.addEntry("Some Pilot", .{ 10, 0, 42_000 });
    try testing.expect(tracker.query("Some Pilot", MiningWindow.checkStoppedAlert, .{ 80_000, 30_000 }, false));
}

test "CombatTracker reports zero for a character it hasn't seen" {
    var tracker: CombatTracker = .init(testing.allocator, testing.io, 10);
    defer tracker.deinit();
    const dps = tracker.query("Nobody", CombatWindow.computeDps, .{1_000}, .{ .incoming = 0.0, .outgoing = 0.0 });
    try testing.expectEqual(@as(f32, 0.0), dps.incoming.?);
    try testing.expect(!tracker.query("Nobody", CombatWindow.checkDamageAlert, .{}, false));
}

test "MiningTracker keeps its history and rates it over a new window length" {
    var tracker: MiningTracker = .init(testing.allocator, testing.io, 60);
    defer tracker.deinit();
    var timestamp_ms: i64 = 1_000;
    while (timestamp_ms <= 121_000) : (timestamp_ms += 12_000) try tracker.addEntry("Some Pilot", .{ 110, 0, timestamp_ms });

    try testing.expectApproxEqAbs(@as(f32, 550.0 / 60.0), tracker.query("Some Pilot", MiningWindow.computeRates, .{121_500}, .{ .m3 = 0.0, .isk = 0.0 }).m3.?, 0.001);

    tracker.setWindowSeconds(120);
    try testing.expectApproxEqAbs(@as(f32, 1_100.0 / 120.0), tracker.query("Some Pilot", MiningWindow.computeRates, .{121_500}, .{ .m3 = 0.0, .isk = 0.0 }).m3.?, 0.001);
}
