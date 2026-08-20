const std = @import("std");
const log = @import("log.zig");
const slog = log.scoped("activity_tracker");

/// A single parsed combat event (one damage hit, incoming or outgoing).
pub const CombatEvent = struct {
    timestamp_ms: i64,
    amount: u32,
    is_incoming: bool,
};

/// Ring-buffer capacity per character; 512 entries covers ~8 min at 1 hit/sec, within window_seconds ≤ 600.
const RING_CAPACITY = 512;

/// Guards against simultaneous multi-module/multi-weapon log lines spiking a rate computed over a near-zero span.
const MIN_RATE_SPAN_MS: i64 = 3 * std.time.ms_per_s;

/// Rate multiplier that decays 1.0 -> 0.0 as idle time crosses the window's second half, instead of holding flat then cutting to zero.
fn idleDecayFactor(now_ms: i64, last_activity_ms: i64, window_ms: i64) f32 {
    const idle_ms = now_ms - last_activity_ms;
    const grace_ms = @divTrunc(window_ms, 2);
    if (idle_ms <= grace_ms) return 1.0;
    const decay_span_ms = window_ms - grace_ms;
    const over_ms = @min(idle_ms - grace_ms, decay_span_ms);
    return 1.0 - @as(f32, @floatFromInt(over_ms)) / @as(f32, @floatFromInt(decay_span_ms));
}

/// Per-character sliding-window DPS accumulator with zero heap allocations after init.
pub const CombatWindow = struct {
    entries: [RING_CAPACITY]CombatEvent = undefined,
    /// Next write slot, wraps mod RING_CAPACITY.
    head: usize = 0,
    /// Valid entry count, saturates at RING_CAPACITY.
    count: usize = 0,
    window_ms: i64,
    last_hit_ms: i64 = 0,
    last_incoming_hit_ms: i64 = 0,
    /// 0 = never fired.
    last_damage_alert_ms: i64 = 0,
    /// Per-direction activity clocks for idleDecayFactor; unlike last_incoming_hit_ms, not gated by counts_for_alert.
    last_incoming_activity_ms: i64 = 0,
    last_outgoing_activity_ms: i64 = 0,

    // Cached last-computed values, updated by refresh(). Null means not enough span yet to trust a rate.
    last_incoming_dps: ?f32 = null,
    last_outgoing_dps: ?f32 = null,

    pub fn init(window_seconds: u32) CombatWindow {
        return .{
            .window_ms = @as(i64, window_seconds) * std.time.ms_per_s,
        };
    }

    /// Append a new hit to the ring buffer (O(1), overwrites oldest on overflow).
    /// `counts_for_alert` only gates `last_incoming_hit_ms` (checkDamageAlert's trigger) — the hit is always ring-buffered so DPS stays accurate for filtered hits.
    pub fn addEntry(self: *CombatWindow, amount: u32, is_incoming: bool, timestamp_ms: i64, counts_for_alert: bool) void {
        self.entries[self.head] = .{
            .timestamp_ms = timestamp_ms,
            .amount = amount,
            .is_incoming = is_incoming,
        };
        self.head = (self.head + 1) % RING_CAPACITY;
        if (self.count < RING_CAPACITY) self.count += 1;
        if (timestamp_ms > self.last_hit_ms) self.last_hit_ms = timestamp_ms;
        if (is_incoming) {
            if (counts_for_alert and timestamp_ms > self.last_incoming_hit_ms) self.last_incoming_hit_ms = timestamp_ms;
            if (timestamp_ms > self.last_incoming_activity_ms) self.last_incoming_activity_ms = timestamp_ms;
        } else if (timestamp_ms > self.last_outgoing_activity_ms) {
            self.last_outgoing_activity_ms = timestamp_ms;
        }
    }

    /// Fires when incoming damage has landed since the last alert, debounced to at most once per `repeat_ms`; stays silent once combat stops instead of repeating on a timer.
    pub fn checkDamageAlert(self: *CombatWindow, now_ms: i64, repeat_ms: i64) bool {
        if (self.last_incoming_hit_ms == 0) return false;
        if (self.last_incoming_hit_ms <= self.last_damage_alert_ms) return false;
        if (self.last_damage_alert_ms != 0 and now_ms - self.last_damage_alert_ms < repeat_ms) return false;
        self.last_damage_alert_ms = now_ms;
        return true;
    }

    /// Compute incoming and outgoing DPS over the sliding window ending at now_ms. Null means not enough span yet to trust a rate.
    pub fn computeDps(self: *const CombatWindow, now_ms: i64) struct { incoming: ?f32, outgoing: ?f32 } {
        // Short-circuit: if the newest hit is already outside the window, skip the O(n) walk over stale entries.
        if (self.last_hit_ms == 0 or now_ms - self.last_hit_ms >= self.window_ms) {
            return .{ .incoming = 0.0, .outgoing = 0.0 };
        }
        const cutoff = now_ms - self.window_ms;
        var in_total: u64 = 0;
        var out_total: u64 = 0;
        var newest_ms: i64 = 0;
        var oldest_ms: i64 = 0;

        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + RING_CAPACITY - 1 - i) % RING_CAPACITY;
            const entry = &self.entries[idx];
            // Ring is chronologically ordered, so all further entries are also expired
            if (entry.timestamp_ms < cutoff) break;
            if (i == 0) newest_ms = entry.timestamp_ms;
            oldest_ms = entry.timestamp_ms;
            if (entry.is_incoming) {
                in_total += entry.amount;
            } else {
                out_total += entry.amount;
            }
        }
        const span_ms = newest_ms - oldest_ms;
        if (span_ms < MIN_RATE_SPAN_MS) return .{ .incoming = null, .outgoing = null };

        const window_secs = @as(f32, @floatFromInt(@min(self.window_ms, span_ms))) / 1000.0;
        const in_factor = idleDecayFactor(now_ms, self.last_incoming_activity_ms, self.window_ms);
        const out_factor = idleDecayFactor(now_ms, self.last_outgoing_activity_ms, self.window_ms);
        return .{
            .incoming = (@as(f32, @floatFromInt(in_total)) / window_secs) * in_factor,
            .outgoing = (@as(f32, @floatFromInt(out_total)) / window_secs) * out_factor,
        };
    }

    /// Recompute DPS, update last_ fields. Returns true if either value changed by >= 0.1, or crossed to/from null.
    pub fn refresh(self: *CombatWindow, now_ms: i64) bool {
        const new = self.computeDps(now_ms);
        const in_changed = if (self.last_incoming_dps) |old|
            (if (new.incoming) |n| @abs(n - old) >= 0.1 else true)
        else
            new.incoming != null;
        const out_changed = if (self.last_outgoing_dps) |old|
            (if (new.outgoing) |n| @abs(n - old) >= 0.1 else true)
        else
            new.outgoing != null;
        self.last_incoming_dps = new.incoming;
        self.last_outgoing_dps = new.outgoing;
        return in_changed or out_changed;
    }
};

/// Shared allocator/mutex/hashmap plumbing for a per-character sliding-window tracker.
/// WindowT must expose `fn init(window_seconds: u32) WindowT` and `fn refresh(*WindowT, now_ms: i64) bool`.
fn TrackerBase(comptime WindowT: type) type {
    return struct {
        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex = .{},
        windows: std.StringHashMap(WindowT),
        window_seconds: u32,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, window_seconds: u32) Self {
            return .{
                .allocator = allocator,
                .windows = std.StringHashMap(WindowT).init(allocator),
                .window_seconds = window_seconds,
            };
        }

        /// Must only be called after the worker thread has stopped (no lock needed).
        fn deinit(self: *Self) void {
            var iter = self.windows.keyIterator();
            while (iter.next()) |key| {
                self.allocator.free(key.*);
            }
            self.windows.deinit();
        }

        fn removeCharacter(self: *Self, character_name: []const u8) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.windows.fetchRemove(character_name)) |entry| {
                self.allocator.free(entry.key);
            }
        }

        fn refreshAll(self: *Self, now_ms: i64) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            var any_changed = false;
            var iter = self.windows.valueIterator();
            while (iter.next()) |window| {
                if (window.refresh(now_ms)) any_changed = true;
            }
            return any_changed;
        }

        /// Returns character_name's window, creating one via WindowT.init(window_seconds) if absent. Caller must hold mutex.
        fn getOrCreate(self: *Self, character_name: []const u8) !*WindowT {
            if (self.windows.getPtr(character_name)) |window| return window;
            const key = try self.allocator.dupe(u8, character_name);
            errdefer self.allocator.free(key);
            try self.windows.put(key, WindowT.init(self.window_seconds));
            return self.windows.getPtr(character_name).?;
        }
    };
}

/// Multi-character DPS tracker; owns a CombatWindow and duped key string per character.
/// Thread-safe: the main thread calls refreshAll/getDps while the chatlog worker thread calls addEntry/removeCharacter concurrently.
pub const CombatTracker = struct {
    base: TrackerBase(CombatWindow),

    pub fn init(allocator: std.mem.Allocator, window_seconds: u32) CombatTracker {
        return .{ .base = TrackerBase(CombatWindow).init(allocator, window_seconds) };
    }

    pub fn deinit(self: *CombatTracker) void {
        self.base.deinit();
    }

    /// Record a hit for character_name.  Creates a new window on the first call per character.
    pub fn addEntry(
        self: *CombatTracker,
        character_name: []const u8,
        amount: u32,
        is_incoming: bool,
        timestamp_ms: i64,
        counts_for_alert: bool,
    ) !void {
        self.base.mutex.lock();
        defer self.base.mutex.unlock();
        const window = try self.base.getOrCreate(character_name);
        window.addEntry(amount, is_incoming, timestamp_ms, counts_for_alert);
    }

    /// Remove a character's window (call on character logout to free the entry).
    pub fn removeCharacter(self: *CombatTracker, character_name: []const u8) void {
        self.base.removeCharacter(character_name);
    }

    /// Return the last-refreshed DPS values for character_name. Null means not enough span yet to trust a rate.
    pub fn getDps(self: *CombatTracker, character_name: []const u8) struct { incoming: ?f32, outgoing: ?f32 } {
        self.base.mutex.lock();
        defer self.base.mutex.unlock();
        if (self.base.windows.get(character_name)) |window| {
            return .{ .incoming = window.last_incoming_dps, .outgoing = window.last_outgoing_dps };
        }
        return .{ .incoming = 0.0, .outgoing = 0.0 };
    }

    /// Re-evaluate all windows against now_ms.  Returns true if any DPS value changed by >= 0.1.
    pub fn refreshAll(self: *CombatTracker, now_ms: i64) bool {
        return self.base.refreshAll(now_ms);
    }

    /// See CombatWindow.checkDamageAlert. Returns false if character_name has no window yet.
    pub fn checkDamageAlert(self: *CombatTracker, character_name: []const u8, now_ms: i64, repeat_ms: i64) bool {
        self.base.mutex.lock();
        defer self.base.mutex.unlock();
        const window = self.base.windows.getPtr(character_name) orelse return false;
        return window.checkDamageAlert(now_ms, repeat_ms);
    }
};

/// Parse a `(combat)` gamelog line and extract damage amount + direction.
/// Incoming misses return a zero-amount incoming hit (counts for the Taking Damage alert but not DPS); outgoing misses are ignored entirely.
/// Direction: " from " → incoming, " to " → outgoing, matched against the text following the damage number.
/// `weapon_buf` receives the weapon/module name copied out of the function-local stripped-HTML buffer; empty if the line has no weapon segment or the buffer is too small.
pub fn parseCombatLine(line: []const u8, weapon_buf: []u8) ?struct { amount: u32, is_incoming: bool, weapon: []const u8 } {
    const combat_prefix = "(combat)";
    const combat_pos = std.mem.indexOf(u8, line, combat_prefix) orelse return null;
    const payload = std.mem.trimLeft(u8, line[combat_pos + combat_prefix.len ..], " \t");

    // Skip remote-rep / cap-transfer lines (these are not damage hits)
    if (std.mem.indexOf(u8, payload, "boosts your") != null or
        std.mem.indexOf(u8, payload, "shields your") != null or
        std.mem.indexOf(u8, payload, "repairs your") != null or
        std.mem.indexOf(u8, payload, "transfers") != null)
    {
        return null;
    }

    var stripped_buf: [512]u8 = undefined;
    const stripped = stripHtml(payload, &stripped_buf);

    if (std.mem.indexOf(u8, stripped, "misses you") != null and !std.mem.startsWith(u8, stripped, "You ")) {
        return .{ .amount = 0, .is_incoming = true, .weapon = "" };
    }

    // Rejects lines that start with a non-digit and aren't an incoming miss (handled above).
    var amount: u32 = 0;
    var digits_end: usize = 0;
    var found_digit = false;
    for (stripped, 0..) |c, i| {
        if (c >= '0' and c <= '9') {
            amount = amount * 10 + (c - '0');
            digits_end = i + 1;
            found_digit = true;
        } else if (found_digit) {
            break;
        } else {
            // Allow leading whitespace; anything else is not a damage line
            if (c != ' ' and c != '\t') return null;
        }
    }
    if (!found_digit or amount == 0) return null;

    // Direction keyword immediately follows the number (see doc comment above)
    const rest = stripped[digits_end..];
    const is_incoming = if (std.mem.indexOf(u8, rest, " from ") != null)
        true
    else if (std.mem.indexOf(u8, rest, " to ") != null)
        false
    else
        return null;

    // Weapon name sits before the trailing hit-quality word; searched from the end because target names can themselves contain " - " (e.g. structure kills), which would otherwise be misread as the weapon segment.
    var weapon: []const u8 = "";
    if (std.mem.lastIndexOf(u8, rest, " - ")) |quality_dash| {
        const before_quality = rest[0..quality_dash];
        if (std.mem.lastIndexOf(u8, before_quality, " - ")) |weapon_dash| {
            const w = std.mem.trim(u8, before_quality[weapon_dash + 3 ..], " \t");
            const n = @min(w.len, weapon_buf.len);
            @memcpy(weapon_buf[0..n], w[0..n]);
            weapon = weapon_buf[0..n];
        }
    }

    return .{ .amount = amount, .is_incoming = is_incoming, .weapon = weapon };
}

/// True if `weapon` case-insensitively contains any comma-separated entry of `excluded_csv`; empty entries are skipped so trailing/stray commas don't match everything.
pub fn isWeaponExcluded(weapon: []const u8, excluded_csv: []const u8) bool {
    if (weapon.len == 0 or excluded_csv.len == 0) return false;
    var it = std.mem.splitScalar(u8, excluded_csv, ',');
    while (it.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t");
        if (entry.len == 0 or entry.len > weapon.len) continue;
        var i: usize = 0;
        while (i + entry.len <= weapon.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(weapon[i .. i + entry.len], entry)) return true;
        }
    }
    return false;
}

/// A single parsed mining event (one yield from a mining cycle).
pub const MiningEvent = struct {
    timestamp_ms: i64,
    m3: f32,
    isk: f32,
};

/// Per-character sliding-window mining-rate accumulator with zero heap allocations after init.
pub const MiningWindow = struct {
    entries: [RING_CAPACITY]MiningEvent = undefined,
    head: usize = 0,
    count: usize = 0,
    window_ms: i64,
    last_hit_ms: i64 = 0,

    // Cached last-computed values, updated by refresh(). Null means not enough span yet to trust a rate.
    last_m3_per_sec: ?f32 = null,
    last_isk_per_sec: ?f32 = null,
    // Timestamp of the last idle-alert fired for this window (ms). 0 = never.
    last_alert_ms: i64 = 0,
    // Timestamp of the last stopped-alert fired (ms). Reset when mining resumes.
    last_stopped_alert_ms: i64 = 0,

    pub fn init(window_seconds: u32) MiningWindow {
        return .{
            .window_ms = @as(i64, window_seconds) * std.time.ms_per_s,
        };
    }

    /// Append a new yield to the ring buffer (O(1), overwrites oldest on overflow).
    pub fn addEntry(self: *MiningWindow, m3: f32, isk: f32, timestamp_ms: i64) void {
        self.entries[self.head] = .{
            .timestamp_ms = timestamp_ms,
            .m3 = m3,
            .isk = isk,
        };
        self.head = (self.head + 1) % RING_CAPACITY;
        if (self.count < RING_CAPACITY) self.count += 1;
        if (timestamp_ms > self.last_hit_ms) self.last_hit_ms = timestamp_ms;
        // Mining resumed — allow the stopped alert to fire again next time.
        self.last_stopped_alert_ms = 0;
    }

    /// Count the number of events within the sliding window ending at now_ms.
    pub fn countEvents(self: *const MiningWindow, window_ms: i64, now_ms: i64) usize {
        if (self.last_hit_ms == 0 or now_ms - self.last_hit_ms >= window_ms) return 0;
        const cutoff = now_ms - window_ms;
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + RING_CAPACITY - 1 - i) % RING_CAPACITY;
            if (self.entries[idx].timestamp_ms < cutoff) break;
            n += 1;
        }
        return n;
    }

    /// Compute m3-per-second over the sliding window ending at now_ms. Null means not enough span yet to trust a rate.
    pub fn computeRate(self: *const MiningWindow, now_ms: i64) ?f32 {
        // Short-circuit: if the newest yield is already outside the window, skip the O(n) walk over stale entries.
        if (self.last_hit_ms == 0 or now_ms - self.last_hit_ms >= self.window_ms) {
            return 0.0;
        }
        const cutoff = now_ms - self.window_ms;
        var total: f32 = 0;
        var newest_ms: i64 = 0;
        var oldest_ms: i64 = 0;

        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + RING_CAPACITY - 1 - i) % RING_CAPACITY;
            const entry = &self.entries[idx];
            if (entry.timestamp_ms < cutoff) break;
            if (i == 0) newest_ms = entry.timestamp_ms;
            oldest_ms = entry.timestamp_ms;
            total += entry.m3;
        }
        const span_ms = newest_ms - oldest_ms;
        if (span_ms < MIN_RATE_SPAN_MS) return null;

        const window_secs = @as(f32, @floatFromInt(@min(self.window_ms, span_ms))) / 1000.0;
        return (total / window_secs) * idleDecayFactor(now_ms, self.last_hit_ms, self.window_ms);
    }

    /// Compute ISK-per-second over the sliding window ending at now_ms; same walk as computeRate but summing isk instead of m3. Null means not enough span yet to trust a rate.
    pub fn computeIskRate(self: *const MiningWindow, now_ms: i64) ?f32 {
        if (self.last_hit_ms == 0 or now_ms - self.last_hit_ms >= self.window_ms) {
            return 0.0;
        }
        const cutoff = now_ms - self.window_ms;
        var total: f32 = 0;
        var newest_ms: i64 = 0;
        var oldest_ms: i64 = 0;

        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + RING_CAPACITY - 1 - i) % RING_CAPACITY;
            const entry = &self.entries[idx];
            if (entry.timestamp_ms < cutoff) break;
            if (i == 0) newest_ms = entry.timestamp_ms;
            oldest_ms = entry.timestamp_ms;
            total += entry.isk;
        }
        const span_ms = newest_ms - oldest_ms;
        if (span_ms < MIN_RATE_SPAN_MS) return null;

        const window_secs = @as(f32, @floatFromInt(@min(self.window_ms, span_ms))) / 1000.0;
        return (total / window_secs) * idleDecayFactor(now_ms, self.last_hit_ms, self.window_ms);
    }

    /// Recompute m3 and ISK rates, updating both cached values. Returns true if the m3 rate changed by >= 0.1 or crossed to/from null -
    /// the ISK rate is driven by the exact same set of window entries, so an unchanged m3 rate means an unchanged ISK rate too.
    pub fn refresh(self: *MiningWindow, now_ms: i64) bool {
        const new_rate = self.computeRate(now_ms);
        const changed = if (self.last_m3_per_sec) |old|
            (if (new_rate) |new| @abs(new - old) >= 0.1 else true)
        else
            new_rate != null;
        self.last_m3_per_sec = new_rate;
        self.last_isk_per_sec = self.computeIskRate(now_ms);
        return changed;
    }
};

/// Multi-character mining rate tracker; owns a MiningWindow and duped key string per character.
/// Thread-safe: the main thread calls refreshAll/getRate/checkIdleAlert/checkStoppedAlert while the chatlog worker thread calls addEntry/removeCharacter concurrently.
pub const MiningTracker = struct {
    base: TrackerBase(MiningWindow),

    pub fn init(allocator: std.mem.Allocator, window_seconds: u32) MiningTracker {
        return .{ .base = TrackerBase(MiningWindow).init(allocator, window_seconds) };
    }

    pub fn deinit(self: *MiningTracker) void {
        self.base.deinit();
    }

    /// Record a yield (m3 and its ISK value) for character_name. Creates a new window on the first call per character.
    pub fn addEntry(
        self: *MiningTracker,
        character_name: []const u8,
        m3: f32,
        isk: f32,
        timestamp_ms: i64,
    ) !void {
        self.base.mutex.lock();
        defer self.base.mutex.unlock();
        const window = try self.base.getOrCreate(character_name);
        window.addEntry(m3, isk, timestamp_ms);
    }

    /// Remove a character's window (call on character logout to free the entry).
    pub fn removeCharacter(self: *MiningTracker, character_name: []const u8) void {
        self.base.removeCharacter(character_name);
    }

    /// Return the last-refreshed mining rate for character_name (m3/sec). Null means not enough span yet to trust a rate.
    pub fn getRate(self: *MiningTracker, character_name: []const u8) ?f32 {
        self.base.mutex.lock();
        defer self.base.mutex.unlock();
        if (self.base.windows.get(character_name)) |window| {
            return window.last_m3_per_sec;
        }
        return 0.0;
    }

    /// Return the last-refreshed ISK rate for character_name (ISK/sec). Null means not enough span yet to trust a rate.
    pub fn getIskRate(self: *MiningTracker, character_name: []const u8) ?f32 {
        self.base.mutex.lock();
        defer self.base.mutex.unlock();
        if (self.base.windows.get(character_name)) |window| {
            return window.last_isk_per_sec;
        }
        return 0.0;
    }

    /// Re-evaluate all windows against now_ms. Returns true if any rate changed by >= 0.1.
    pub fn refreshAll(self: *MiningTracker, now_ms: i64) bool {
        return self.base.refreshAll(now_ms);
    }

    /// Returns true (and records the alert) if event count within alert_window_ms is <= threshold and the cooldown since the last alert has elapsed.
    pub fn checkIdleAlert(
        self: *MiningTracker,
        character_name: []const u8,
        now_ms: i64,
        alert_window_ms: i64,
        threshold: u32,
    ) bool {
        self.base.mutex.lock();
        defer self.base.mutex.unlock();
        const window = self.base.windows.getPtr(character_name) orelse return false;
        // Only alert if the character has mined at least once (avoids false positives on start-up).
        if (window.last_hit_ms == 0) return false;
        const count = window.countEvents(alert_window_ms, now_ms);
        if (count > threshold) {
            // Active — reset so we alert again if they go idle later.
            window.last_alert_ms = 0;
            return false;
        }
        // Idle: count <= threshold. Fire once per idle episode; re-arms when mining resumes.
        if (window.last_alert_ms != 0) {
            return false;
        }
        window.last_alert_ms = now_ms;
        return true;
    }

    /// Returns true once when mining has stopped for at least stopped_window_ms; rearms when mining resumes (addEntry resets last_stopped_alert_ms).
    pub fn checkStoppedAlert(
        self: *MiningTracker,
        character_name: []const u8,
        now_ms: i64,
        stopped_window_ms: i64,
    ) bool {
        self.base.mutex.lock();
        defer self.base.mutex.unlock();
        const window = self.base.windows.getPtr(character_name) orelse return false;
        // Only alert if the character has mined at least once.
        if (window.last_hit_ms == 0) return false;
        // Still within the grace window — not stopped yet.
        if (now_ms - window.last_hit_ms < stopped_window_ms) return false;
        // Already fired this stopped-episode — wait for mining to resume.
        if (window.last_stopped_alert_ms != 0) return false;
        window.last_stopped_alert_ms = now_ms;
        return true;
    }
};

/// A single parsed bounty payout event.
pub const BountyEvent = struct {
    timestamp_ms: i64,
    isk: f32,
};

/// Per-character sliding-window bounty ISK-rate accumulator with zero heap allocations after init. Mirrors MiningWindow's ISK-rate half; there's no m3 twin since bounty payouts already arrive in ISK.
pub const BountyWindow = struct {
    entries: [RING_CAPACITY]BountyEvent = undefined,
    head: usize = 0,
    count: usize = 0,
    window_ms: i64,
    last_hit_ms: i64 = 0,

    last_isk_per_sec: ?f32 = null,

    pub fn init(window_seconds: u32) BountyWindow {
        return .{
            .window_ms = @as(i64, window_seconds) * std.time.ms_per_s,
        };
    }

    /// Append a new bounty payout to the ring buffer (O(1), overwrites oldest on overflow).
    pub fn addEntry(self: *BountyWindow, isk: f32, timestamp_ms: i64) void {
        self.entries[self.head] = .{
            .timestamp_ms = timestamp_ms,
            .isk = isk,
        };
        self.head = (self.head + 1) % RING_CAPACITY;
        if (self.count < RING_CAPACITY) self.count += 1;
        if (timestamp_ms > self.last_hit_ms) self.last_hit_ms = timestamp_ms;
    }

    /// Compute ISK-per-second over the sliding window ending at now_ms. Null means not enough span yet to trust a rate.
    pub fn computeIskRate(self: *const BountyWindow, now_ms: i64) ?f32 {
        if (self.last_hit_ms == 0 or now_ms - self.last_hit_ms >= self.window_ms) {
            return 0.0;
        }
        const cutoff = now_ms - self.window_ms;
        var total: f32 = 0;
        var newest_ms: i64 = 0;
        var oldest_ms: i64 = 0;

        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + RING_CAPACITY - 1 - i) % RING_CAPACITY;
            const entry = &self.entries[idx];
            if (entry.timestamp_ms < cutoff) break;
            if (i == 0) newest_ms = entry.timestamp_ms;
            oldest_ms = entry.timestamp_ms;
            total += entry.isk;
        }
        const span_ms = newest_ms - oldest_ms;
        if (span_ms < MIN_RATE_SPAN_MS) return null;

        const window_secs = @as(f32, @floatFromInt(@min(self.window_ms, span_ms))) / 1000.0;
        return (total / window_secs) * idleDecayFactor(now_ms, self.last_hit_ms, self.window_ms);
    }

    /// Recompute the ISK rate. Returns true if it changed by >= 0.1 or crossed to/from null.
    pub fn refresh(self: *BountyWindow, now_ms: i64) bool {
        const new_rate = self.computeIskRate(now_ms);
        const changed = if (self.last_isk_per_sec) |old|
            (if (new_rate) |new| @abs(new - old) >= 0.1 else true)
        else
            new_rate != null;
        self.last_isk_per_sec = new_rate;
        return changed;
    }
};

/// Multi-character bounty ISK-rate tracker; owns a BountyWindow and duped key string per character.
/// Thread-safe: the main thread calls refreshAll/getIskRate while the chatlog worker thread calls addEntry/removeCharacter concurrently.
pub const BountyTracker = struct {
    base: TrackerBase(BountyWindow),

    pub fn init(allocator: std.mem.Allocator, window_seconds: u32) BountyTracker {
        return .{ .base = TrackerBase(BountyWindow).init(allocator, window_seconds) };
    }

    pub fn deinit(self: *BountyTracker) void {
        self.base.deinit();
    }

    /// Record a bounty payout (ISK) for character_name. Creates a new window on the first call per character.
    pub fn addEntry(
        self: *BountyTracker,
        character_name: []const u8,
        isk: f32,
        timestamp_ms: i64,
    ) !void {
        self.base.mutex.lock();
        defer self.base.mutex.unlock();
        const window = try self.base.getOrCreate(character_name);
        window.addEntry(isk, timestamp_ms);
    }

    /// Remove a character's window (call on character logout to free the entry).
    pub fn removeCharacter(self: *BountyTracker, character_name: []const u8) void {
        self.base.removeCharacter(character_name);
    }

    /// Return the last-refreshed ISK rate for character_name (ISK/sec). Null means not enough span yet to trust a rate.
    pub fn getIskRate(self: *BountyTracker, character_name: []const u8) ?f32 {
        self.base.mutex.lock();
        defer self.base.mutex.unlock();
        if (self.base.windows.get(character_name)) |window| {
            return window.last_isk_per_sec;
        }
        return 0.0;
    }

    /// Re-evaluate all windows against now_ms. Returns true if any rate changed by >= 0.1.
    pub fn refreshAll(self: *BountyTracker, now_ms: i64) bool {
        return self.base.refreshAll(now_ms);
    }
};

/// Parses a `(bounty)` gamelog line into the ISK amount added to the next payout; returns null for unrecognised formats.
/// Bounty amounts use comma thousand-separators ("246,153 ISK"), unlike the plain digit runs parseCombatLine/parseMiningLine parse.
pub fn parseBountyLine(line: []const u8) ?f32 {
    const bounty_prefix = "(bounty)";
    const bounty_pos = std.mem.indexOf(u8, line, bounty_prefix) orelse return null;
    const payload = std.mem.trimLeft(u8, line[bounty_pos + bounty_prefix.len ..], " \t");

    var stripped_buf: [512]u8 = undefined;
    const stripped = stripHtml(payload, &stripped_buf);

    var amount: u32 = 0;
    var found_digit = false;
    for (stripped) |c| {
        if (c >= '0' and c <= '9') {
            amount = amount * 10 + (c - '0');
            found_digit = true;
        } else if (c == ',' and found_digit) {
            continue;
        } else if (found_digit) {
            break;
        } else if (c != ' ' and c != '\t') {
            return null;
        }
    }
    if (!found_digit or amount == 0) return null;
    return @floatFromInt(amount);
}

/// Raw unit count plus the mined ore/ice/gas name, copied by value since parseMiningLine's buffer is stack-local.
pub const ParsedMiningEvent = struct {
    amount: u32,
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,

    pub fn name(self: *const ParsedMiningEvent) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Parses a `(mining)` gamelog line into the mined unit count and ore/ice/gas name; returns null for residue/waste lines, missing tags, or unrecognised formats.
pub fn parseMiningLine(line: []const u8) ?ParsedMiningEvent {
    const mining_prefix = "(mining)";
    const mining_pos = std.mem.indexOf(u8, line, mining_prefix) orelse return null;
    const payload = std.mem.trimLeft(u8, line[mining_pos + mining_prefix.len ..], " \t");

    var stripped_buf: [512]u8 = undefined;
    const stripped = stripHtml(payload, &stripped_buf);

    // Skip residue/waste lines – the player does not gain those units
    if (std.mem.indexOf(u8, stripped, "depleted from asteroid as residue") != null) {
        return null;
    }

    // Find "You mined" which appears in both normal and critical lines.
    const mined_kw = "You mined";
    const mined_pos = std.mem.indexOf(u8, stripped, mined_kw) orelse return null;
    var cursor = std.mem.trimLeft(u8, stripped[mined_pos + mined_kw.len ..], " \t");

    // Skip optional "an additional " prefix (critical yield)
    const additional_kw = "an additional ";
    if (std.mem.startsWith(u8, cursor, additional_kw)) {
        cursor = cursor[additional_kw.len..];
    }

    var amount: u32 = 0;
    var found_digit = false;
    var digit_end: usize = 0;
    for (cursor, 0..) |c, i| {
        if (c >= '0' and c <= '9') {
            amount = amount * 10 + (c - '0');
            found_digit = true;
            digit_end = i + 1;
        } else if (found_digit) {
            break;
        } else {
            if (c != ' ' and c != '\t') return null;
        }
    }
    if (!found_digit or amount == 0) return null;

    const units_of_kw = "units of ";
    const rest = cursor[digit_end..];
    const units_pos = std.mem.indexOf(u8, rest, units_of_kw) orelse return null;
    const name_start = rest[units_pos + units_of_kw.len ..];
    const name_end = std.mem.indexOfScalar(u8, name_start, '.') orelse name_start.len;
    const ore_name = std.mem.trim(u8, name_start[0..name_end], " \t");
    if (ore_name.len == 0) return null;

    var result: ParsedMiningEvent = .{ .amount = amount };
    if (ore_name.len > result.name_buf.len) return null;
    @memcpy(result.name_buf[0..ore_name.len], ore_name);
    result.name_len = @intCast(ore_name.len);
    return result;
}

/// Strip HTML/XML tags from src into out_buf.  Returns the written slice.
pub fn stripHtml(src: []const u8, out_buf: []u8) []const u8 {
    var out: usize = 0;
    var in_tag = false;
    for (src) |c| {
        if (out >= out_buf.len) break;
        switch (c) {
            '<' => {
                in_tag = true;
            },
            '>' => {
                in_tag = false;
            },
            else => if (!in_tag) {
                out_buf[out] = c;
                out += 1;
            },
        }
    }
    return out_buf[0..out];
}
