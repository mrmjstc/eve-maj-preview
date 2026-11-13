//! Per-character combat, mining and bounty rates over a sliding window.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");

const Ticks = win32.Ticks;
const slog = log.Scoped("activity_tracker");

/// Ring-buffer capacity per character; a window holding more events is rated over the time the newest 512 span.
const RING_CAPACITY = 512;

/// Keeps several modules' simultaneous lines from spiking a warm-up rate over a near-zero span.
const MIN_RATE_SPAN_MS: u64 = 3 * std.time.ms_per_s;

/// Lines landing this soon after a streak's first one (lasers cycling in step, one volley) count as its first moment.
const FIRST_MOMENT_MS: u64 = 1 * std.time.ms_per_s;

const WindowSum = struct {
    total: f32 = 0,
    after_first_moment: f32 = 0,
    event_count: usize = 0,
    after_first_moment_count: usize = 0,
    newest: Ticks = .{},

    /// With nothing after the first moment, `to_now` rates the window's total as it will read once the streak is that old, and `to_newest` waits.
    const WarmUp = enum { to_now, to_newest };

    fn add(self: *WindowSum, amount: f32, timestamp: Ticks, streak_start: Ticks) void {
        self.total += amount;
        self.event_count += 1;
        if (timestamp.ms > self.newest.ms) self.newest = timestamp;
        if (timestamp.elapsedSince(streak_start) >= FIRST_MOMENT_MS) {
            self.after_first_moment += amount;
            self.after_first_moment_count += 1;
        }
    }

    /// The window's total (a young streak's from its first moment) rated to now or the newest event, within what a full ring still covers; null while too short to trust.
    fn rate(self: WindowSum, streak_start: Ticks, now: Ticks, window_ms: u64, ring_full_from: ?Ticks, warm_up: WarmUp) ?f32 {
        if (self.event_count == 0) return 0.0;
        if (ring_full_from) |from| {
            const covered_ms = now.elapsedSince(from);
            if (covered_ms < MIN_RATE_SPAN_MS) return null;
            return self.total / seconds(covered_ms);
        }
        const streak_ms = now.elapsedSince(streak_start);
        if (streak_ms >= window_ms) return self.total / seconds(window_ms);
        if (self.after_first_moment_count == 0) {
            if (warm_up == .to_newest or streak_ms < MIN_RATE_SPAN_MS) return null;
            return self.total / seconds(window_ms);
        }
        const end = switch (warm_up) {
            .to_now => now,
            .to_newest => self.newest,
        };
        const elapsed_ms = end.elapsedSince(streak_start);
        if (elapsed_ms < MIN_RATE_SPAN_MS) return null;
        return self.after_first_moment / seconds(elapsed_ms);
    }

    fn seconds(ms: u64) f32 {
        return @as(f32, @floatFromInt(ms)) / std.time.ms_per_s;
    }
};

pub const CombatEvent = struct {
    timestamp: Ticks,
    amount: u32,
    is_incoming: bool,
};

pub const Dps = struct { incoming: ?f32, outgoing: ?f32 };

pub const CombatWindow = struct {
    ring: Ring(CombatEvent),
    last_incoming_hit: Ticks = .{},
    /// Zero = never fired.
    last_damage_alert: Ticks = .{},

    pub fn init(window_seconds: u32) CombatWindow {
        return .{ .ring = .init(window_seconds) };
    }

    /// `counts_for_alert` only gates checkDamageAlert; the hit always counts toward DPS.
    pub const Hit = struct { amount: u32, timestamp: Ticks, is_incoming: bool, counts_for_alert: bool = true };

    pub fn addEntry(self: *CombatWindow, hit: Hit) void {
        self.ring.push(.{ .timestamp = hit.timestamp, .amount = hit.amount, .is_incoming = hit.is_incoming });
        if (hit.is_incoming and hit.counts_for_alert and hit.timestamp.ms > self.last_incoming_hit.ms) self.last_incoming_hit = hit.timestamp;
    }

    /// Fires once per burst of incoming damage and stays silent once combat stops; how often it repeats is its Cooldown on the Game Events tab.
    pub fn checkDamageAlert(self: *CombatWindow) bool {
        if (self.last_incoming_hit.isZero()) return false;
        if (self.last_incoming_hit.ms <= self.last_damage_alert.ms) return false;
        self.last_damage_alert = self.last_incoming_hit;
        return true;
    }

    /// Per second, or null while the span is too short to trust (see WindowSum.rate); warm-up runs to now, since hits arrive irregularly.
    pub fn computeDps(self: *const CombatWindow, now: Ticks) Dps {
        const ring = &self.ring;
        if (ring.isQuiet(ring.window_ms, now)) return .{ .incoming = 0.0, .outgoing = 0.0 };
        var incoming: WindowSum = .{};
        var outgoing: WindowSum = .{};
        var it = ring.recent(ring.window_ms, now);
        while (it.next()) |entry| {
            const sum = if (entry.is_incoming) &incoming else &outgoing;
            sum.add(@floatFromInt(entry.amount), entry.timestamp, ring.streak_start);
        }
        return .{
            .incoming = incoming.rate(ring.streak_start, now, ring.window_ms, it.ringFullFrom(), .to_now),
            .outgoing = outgoing.rate(ring.streak_start, now, ring.window_ms, it.ringFullFrom(), .to_now),
        };
    }
};

pub const MiningEvent = struct {
    timestamp: Ticks,
    m3: f32,
    isk: f32,
};

pub const MiningRates = struct { m3: ?f32, isk: ?f32 };

pub const MiningWindow = struct {
    ring: Ring(MiningEvent),
    /// When the idle alert fired, or zero; cleared once mining picks up again.
    last_idle_alert: Ticks = .{},
    /// When the stopped alert fired, or zero; cleared by the next yield.
    last_stopped_alert: Ticks = .{},

    pub fn init(window_seconds: u32) MiningWindow {
        return .{ .ring = .init(window_seconds) };
    }

    pub fn addEntry(self: *MiningWindow, m3: f32, isk: f32, timestamp: Ticks) void {
        self.ring.push(.{ .timestamp = timestamp, .m3 = m3, .isk = isk });
        self.last_stopped_alert = .{};
    }

    fn countEvents(self: *const MiningWindow, window_ms: u64, now: Ticks) usize {
        return self.ring.countRecent(window_ms, now);
    }

    /// m3 per second (see WindowSum.rate); warm-up runs to the newest yield, since yields come in cycles.
    fn computeRate(self: *const MiningWindow, now: Ticks) ?f32 {
        return self.ring.rate("m3", now, .to_newest);
    }

    /// ISK per second; see computeRate.
    pub fn computeIskRate(self: *const MiningWindow, now: Ticks) ?f32 {
        return self.ring.rate("isk", now, .to_newest);
    }

    pub fn computeRates(self: *const MiningWindow, now: Ticks) MiningRates {
        return .{ .m3 = self.computeRate(now), .isk = self.computeIskRate(now) };
    }

    /// True once per idle stretch: at most `threshold` yields within `alert_window_ms`.
    pub fn checkIdleAlert(self: *MiningWindow, now: Ticks, alert_window_ms: u64, threshold: u32) bool {
        // Never mined yet, so not idle: avoids alerting at startup.
        if (self.ring.last_hit.isZero()) return false;
        if (self.countEvents(alert_window_ms, now) > threshold) {
            self.last_idle_alert = .{};
            return false;
        }
        if (now.elapsedSince(self.ring.streak_start) < alert_window_ms) return false;
        if (!self.last_idle_alert.isZero()) return false;
        self.last_idle_alert = now;
        return true;
    }

    /// True once when nothing has been mined for `stopped_window_ms`; the next yield re-arms it.
    pub fn checkStoppedAlert(self: *MiningWindow, now: Ticks, stopped_window_ms: u64) bool {
        if (self.ring.last_hit.isZero()) return false;
        if (now.elapsedSince(self.ring.last_hit) < stopped_window_ms) return false;
        if (!self.last_stopped_alert.isZero()) return false;
        self.last_stopped_alert = now;
        return true;
    }
};

pub const BountyEvent = struct {
    timestamp: Ticks,
    isk: f32,
};

/// MiningWindow's ISK half, as payouts already arrive in ISK.
pub const BountyWindow = struct {
    ring: Ring(BountyEvent),

    pub fn init(window_seconds: u32) BountyWindow {
        return .{ .ring = .init(window_seconds) };
    }

    pub fn addEntry(self: *BountyWindow, isk: f32, timestamp: Ticks) void {
        self.ring.push(.{ .timestamp = timestamp, .isk = isk });
    }

    /// ISK per second; see MiningWindow.computeRate.
    pub fn computeIskRate(self: *const BountyWindow, now: Ticks) ?f32 {
        return self.ring.rate("isk", now, .to_newest);
    }
};

pub const CombatTracker = Tracker(CombatWindow);
pub const MiningTracker = Tracker(MiningWindow);
pub const BountyTracker = Tracker(BountyWindow);

/// One locked Window per character, read by the main thread and fed by the chatlog worker; `Window` needs `init(window_seconds: u32)`, `addEntry` and a `ring` field.
fn Tracker(comptime Window: type) type {
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

        /// Must only be called after the worker thread has stopped.
        pub fn deinit(self: *Self) void {
            var it = self.windows.keyIterator();
            while (it.next()) |key| self.allocator.free(key.*);
            self.windows.deinit();
        }

        /// Worker thread stopped only; existing history is kept and rated over the new length.
        pub fn setWindowSeconds(self: *Self, window_seconds: u32) void {
            self.window_seconds = window_seconds;
            var it = self.windows.valueIterator();
            while (it.next()) |window| window.ring.window_ms = @as(u64, window_seconds) * std.time.ms_per_s;
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
            const slot = try self.windows.getOrPut(character_name);
            if (slot.found_existing) return slot.value_ptr;
            // A new entry's key borrows character_name until it's swapped for an owned copy.
            slot.key_ptr.* = self.allocator.dupe(u8, character_name) catch |err| {
                self.windows.removeByPtr(slot.key_ptr);
                return err;
            };
            slot.value_ptr.* = Window.init(self.window_seconds);
            return slot.value_ptr;
        }
    };
}

/// Fixed-size so recording never allocates; `Event` needs a `timestamp: Ticks` field.
fn Ring(comptime Event: type) type {
    return struct {
        entries: [RING_CAPACITY]Event = undefined,
        /// Next write slot.
        head: usize = 0,
        entry_count: usize = 0,
        window_ms: u64,
        last_hit: Ticks = .{},
        streak_start: Ticks = .{},

        const Self = @This();

        fn init(window_seconds: u32) Self {
            return .{ .window_ms = @as(u64, window_seconds) * std.time.ms_per_s };
        }

        /// Overwrites the oldest event once full; a whole window of quiet before it starts a new streak.
        fn push(self: *Self, event: Event) void {
            self.entries[self.head] = event;
            self.head = (self.head + 1) % RING_CAPACITY;
            if (self.entry_count < RING_CAPACITY) self.entry_count += 1;
            if (self.isQuiet(self.window_ms, event.timestamp)) self.streak_start = event.timestamp;
            if (event.timestamp.ms > self.last_hit.ms) self.last_hit = event.timestamp;
        }

        fn isQuiet(self: *const Self, window_ms: u64, now: Ticks) bool {
            return self.last_hit.isZero() or now.elapsedSince(self.last_hit) >= window_ms;
        }

        /// The events in the `window_ms` before `now`, newest first.
        fn recent(self: *const Self, window_ms: u64, now: Ticks) Recent {
            return .{ .ring = self, .cutoff = .{ .ms = now.ms -| window_ms }, .oldest = now };
        }

        const Recent = struct {
            ring: *const Self,
            cutoff: Ticks,
            index: usize = 0,
            oldest: Ticks,

            fn next(self: *Recent) ?*const Event {
                if (self.index == self.ring.entry_count) return null;
                const entry = &self.ring.entries[(self.ring.head + RING_CAPACITY - 1 - self.index) % RING_CAPACITY];
                // The ring is in time order, so every older entry has expired too.
                if (entry.timestamp.ms < self.cutoff.ms) return null;
                self.index += 1;
                self.oldest = entry.timestamp;
                return entry;
            }

            /// Once iterated: the oldest event kept, if the ring filled up inside the window; see WindowSum.rate.
            fn ringFullFrom(self: *const Recent) ?Ticks {
                return if (self.index == RING_CAPACITY) self.oldest else null;
            }
        };

        /// `field` per second over the window ending at `now`; see WindowSum.rate.
        fn rate(self: *const Self, comptime field: []const u8, now: Ticks, warm_up: WindowSum.WarmUp) ?f32 {
            if (self.isQuiet(self.window_ms, now)) return 0.0;
            var sum: WindowSum = .{};
            var it = self.recent(self.window_ms, now);
            while (it.next()) |entry| sum.add(@field(entry, field), entry.timestamp, self.streak_start);
            return sum.rate(self.streak_start, now, self.window_ms, it.ringFullFrom(), warm_up);
        }

        fn countRecent(self: *const Self, window_ms: u64, now: Ticks) usize {
            if (self.isQuiet(window_ms, now)) return 0;
            var it = self.recent(window_ms, now);
            var event_count: usize = 0;
            while (it.next()) |_| event_count += 1;
            return event_count;
        }
    };
}

const testing = std.testing;

fn ticksAt(ms: u64) Ticks {
    return .{ .ms = ms };
}

test "CombatWindow withholds a rate until hits span three seconds, only for a direction with hits" {
    var window: CombatWindow = .init(10);
    window.addEntry(.{ .amount = 100, .timestamp = ticksAt(1_000), .is_incoming = true });
    window.addEntry(.{ .amount = 100, .timestamp = ticksAt(2_000), .is_incoming = true });
    const dps = window.computeDps(ticksAt(2_000));
    try testing.expect(dps.incoming == null);
    try testing.expectEqual(@as(f32, 0.0), dps.outgoing.?);
}

test "CombatWindow warms up on the hits after the first moment, over the time since" {
    var window: CombatWindow = .init(10);
    window.addEntry(.{ .amount = 100, .timestamp = ticksAt(1_000), .is_incoming = true });
    window.addEntry(.{ .amount = 50, .timestamp = ticksAt(3_000), .is_incoming = false });
    window.addEntry(.{ .amount = 100, .timestamp = ticksAt(5_000), .is_incoming = true });
    const dps = window.computeDps(ticksAt(5_000));
    try testing.expectEqual(@as(f32, 25.0), dps.incoming.?);
    try testing.expectEqual(@as(f32, 12.5), dps.outgoing.?);
}

test "CombatWindow shows a lone first-second volley over the window after 3 seconds" {
    var window: CombatWindow = .init(10);
    window.addEntry(.{ .amount = 100, .timestamp = ticksAt(1_000), .is_incoming = true });
    try testing.expect(window.computeDps(ticksAt(2_000)).incoming == null);
    try testing.expectEqual(@as(f32, 10.0), window.computeDps(ticksAt(4_500)).incoming.?);
}

test "CombatWindow withholds a rate rather than misreading a hit logged after now" {
    var window: CombatWindow = .init(10);
    window.addEntry(.{ .amount = 100, .timestamp = ticksAt(5_000), .is_incoming = true });
    try testing.expect(window.computeDps(ticksAt(4_000)).incoming == null);
}

test "MiningWindow waits for a second cycle after a lone first one" {
    var window: MiningWindow = .init(60);
    window.addEntry(30, 3_000, ticksAt(1_000));
    try testing.expect(window.computeRate(ticksAt(10_000)) == null);
}

test "CombatWindow rates a streak a window old as its total over the window" {
    var window: CombatWindow = .init(10);
    var timestamp_ms: u64 = 1_000;
    while (timestamp_ms <= 20_000) : (timestamp_ms += 1_000) window.addEntry(.{ .amount = 100, .timestamp = ticksAt(timestamp_ms), .is_incoming = true });
    try testing.expectEqual(@as(f32, 100.0), window.computeDps(ticksAt(20_500)).incoming.?);
}

test "CombatWindow reports zero once the last hit leaves the window" {
    var window: CombatWindow = .init(10);
    window.addEntry(.{ .amount = 100, .timestamp = ticksAt(1_000), .is_incoming = true });
    window.addEntry(.{ .amount = 100, .timestamp = ticksAt(5_000), .is_incoming = true });
    const dps = window.computeDps(ticksAt(15_000));
    try testing.expectEqual(@as(f32, 0.0), dps.incoming.?);
    try testing.expectEqual(@as(f32, 0.0), dps.outgoing.?);
}

test "CombatWindow keeps only the newest hits once the ring wraps" {
    var window: CombatWindow = .init(10);
    for (0..RING_CAPACITY + 88) |i| {
        window.addEntry(.{ .amount = 1, .timestamp = ticksAt(1_000 + @as(u64, i) * 10), .is_incoming = true });
    }
    try testing.expectEqual(@as(usize, RING_CAPACITY), window.ring.entry_count);
    const newest_ms = 1_000 + @as(u64, RING_CAPACITY + 87) * 10;
    const oldest_ms = 1_000 + @as(u64, 88) * 10;
    const span_seconds = @as(f32, @floatFromInt(newest_ms - oldest_ms)) / std.time.ms_per_s;
    try testing.expectApproxEqAbs(@as(f32, RING_CAPACITY) / span_seconds, window.computeDps(ticksAt(newest_ms)).incoming.?, 0.01);
}

test "CombatWindow alerts once per burst of incoming damage" {
    var window: CombatWindow = .init(10);
    try testing.expect(!window.checkDamageAlert());

    window.addEntry(.{ .amount = 100, .timestamp = ticksAt(1_000), .is_incoming = true });
    try testing.expect(window.checkDamageAlert());
    try testing.expect(!window.checkDamageAlert());

    window.addEntry(.{ .amount = 100, .timestamp = ticksAt(2_000), .is_incoming = true, .counts_for_alert = false });
    try testing.expect(!window.checkDamageAlert());

    window.addEntry(.{ .amount = 100, .timestamp = ticksAt(3_000), .is_incoming = true });
    try testing.expect(window.checkDamageAlert());
}

test "MiningWindow warms up on the yields after the first, to the newest" {
    var window: MiningWindow = .init(60);
    window.addEntry(30, 3_000, ticksAt(1_000));
    window.addEntry(30, 3_000, ticksAt(4_000));
    try testing.expectEqual(@as(f32, 10.0), window.computeRate(ticksAt(4_000)).?);
    try testing.expectEqual(@as(f32, 1_000.0), window.computeIskRate(ticksAt(4_000)).?);
    try testing.expectEqual(@as(f32, 10.0), window.computeRate(ticksAt(9_000)).?);
    try testing.expectEqual(@as(usize, 2), window.countEvents(60_000, ticksAt(4_000)));
    try testing.expectEqual(@as(usize, 1), window.countEvents(1_000, ticksAt(4_000)));
}

test "MiningWindow counts two lasers yielding together as one cycle" {
    var window: MiningWindow = .init(60);
    var timestamp_ms: u64 = 1_000;
    while (timestamp_ms <= 37_000) : (timestamp_ms += 12_000) {
        window.addEntry(110, 0, ticksAt(timestamp_ms));
        window.addEntry(110, 0, ticksAt(timestamp_ms));
    }
    try testing.expectApproxEqAbs(@as(f32, 220.0 / 12.0), window.computeRate(ticksAt(40_000)).?, 0.001);
}

test "MiningWindow rates a streak a window old as its total over the window" {
    var window: MiningWindow = .init(60);
    var timestamp_ms: u64 = 1_000;
    while (timestamp_ms <= 121_000) : (timestamp_ms += 12_000) window.addEntry(110, 0, ticksAt(timestamp_ms));
    try testing.expectApproxEqAbs(@as(f32, 550.0 / 60.0), window.computeRate(ticksAt(121_500)).?, 0.001);
}

test "MiningWindow starts a new streak after a whole window of quiet" {
    var window: MiningWindow = .init(60);
    window.addEntry(110, 0, ticksAt(1_000));
    window.addEntry(110, 0, ticksAt(13_000));
    window.addEntry(110, 0, ticksAt(100_000));
    try testing.expect(window.computeRate(ticksAt(100_000)) == null);
}

test "BountyWindow reports zero before the first payout" {
    const window: BountyWindow = .init(60);
    try testing.expectEqual(@as(f32, 0.0), window.computeIskRate(ticksAt(1_000)).?);
}

test "MiningTracker idle alert fires once per idle stretch" {
    var tracker: MiningTracker = .init(testing.allocator, testing.io, 60);
    defer tracker.deinit();

    try testing.expect(!tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ ticksAt(1_000), 60_000, 2 }, false));

    try tracker.addEntry("Some Pilot", .{ 10, 0, ticksAt(1_000) });
    try testing.expect(tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ ticksAt(61_000), 60_000, 2 }, false));
    try testing.expect(!tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ ticksAt(61_500), 60_000, 2 }, false));

    for ([_]u64{ 62_000, 63_000, 64_000 }) |timestamp_ms| try tracker.addEntry("Some Pilot", .{ 10, 0, ticksAt(timestamp_ms) });
    try testing.expect(!tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ ticksAt(64_000), 60_000, 2 }, false));
    try testing.expect(tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ ticksAt(200_000), 60_000, 2 }, false));
}

test "MiningTracker idle alert waits until mining has run a whole detection window" {
    var tracker: MiningTracker = .init(testing.allocator, testing.io, 60);
    defer tracker.deinit();
    try tracker.addEntry("Some Pilot", .{ 110, 0, ticksAt(1_000) });
    try testing.expect(!tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ ticksAt(1_000), 30_000, 1 }, false));
    try testing.expect(!tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ ticksAt(30_000), 30_000, 1 }, false));
    try testing.expect(tracker.query("Some Pilot", MiningWindow.checkIdleAlert, .{ ticksAt(31_000), 30_000, 1 }, false));
}

test "MiningTracker stopped alert fires once until mining resumes" {
    var tracker: MiningTracker = .init(testing.allocator, testing.io, 60);
    defer tracker.deinit();

    try tracker.addEntry("Some Pilot", .{ 10, 0, ticksAt(4_000) });
    try testing.expect(!tracker.query("Some Pilot", MiningWindow.checkStoppedAlert, .{ ticksAt(5_000), 30_000 }, false));
    try testing.expect(tracker.query("Some Pilot", MiningWindow.checkStoppedAlert, .{ ticksAt(40_000), 30_000 }, false));
    try testing.expect(!tracker.query("Some Pilot", MiningWindow.checkStoppedAlert, .{ ticksAt(41_000), 30_000 }, false));

    try tracker.addEntry("Some Pilot", .{ 10, 0, ticksAt(42_000) });
    try testing.expect(tracker.query("Some Pilot", MiningWindow.checkStoppedAlert, .{ ticksAt(80_000), 30_000 }, false));
}

test "CombatTracker reports zero for a character it hasn't seen" {
    var tracker: CombatTracker = .init(testing.allocator, testing.io, 10);
    defer tracker.deinit();
    const dps = tracker.query("Nobody", CombatWindow.computeDps, .{ticksAt(1_000)}, .{ .incoming = 0.0, .outgoing = 0.0 });
    try testing.expectEqual(@as(f32, 0.0), dps.incoming.?);
    try testing.expect(!tracker.query("Nobody", CombatWindow.checkDamageAlert, .{}, false));
}

test "MiningTracker keeps its history and rates it over a new window length" {
    var tracker: MiningTracker = .init(testing.allocator, testing.io, 60);
    defer tracker.deinit();
    var timestamp_ms: u64 = 1_000;
    while (timestamp_ms <= 121_000) : (timestamp_ms += 12_000) try tracker.addEntry("Some Pilot", .{ 110, 0, ticksAt(timestamp_ms) });

    try testing.expectApproxEqAbs(@as(f32, 550.0 / 60.0), tracker.query("Some Pilot", MiningWindow.computeRates, .{ticksAt(121_500)}, .{ .m3 = 0.0, .isk = 0.0 }).m3.?, 0.001);

    tracker.setWindowSeconds(120);
    try testing.expectApproxEqAbs(@as(f32, 1_100.0 / 120.0), tracker.query("Some Pilot", MiningWindow.computeRates, .{ticksAt(121_500)}, .{ .m3 = 0.0, .isk = 0.0 }).m3.?, 0.001);
}
