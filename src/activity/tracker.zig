//! Per-character combat, mining and bounty rates over a sliding window, and the gamelog line parsers that feed them.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.scoped("activity_tracker");

/// Ring-buffer capacity per character; 512 entries covers ~8 min at 1 hit/sec, within window_seconds ≤ 600.
const RING_CAPACITY = 512;

/// Guards against simultaneous multi-module/multi-weapon log lines spiking a rate computed over a near-zero span.
const MIN_RATE_SPAN_MS: i64 = 3 * std.time.ms_per_s;

pub const CombatEvent = struct {
    timestamp_ms: i64,
    amount: u32,
    is_incoming: bool,
};

/// A fixed ring of recent hits, so recording one never allocates.
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

    // Null means not enough span yet to trust a rate.
    last_incoming_dps: ?f32 = null,
    last_outgoing_dps: ?f32 = null,

    pub fn init(window_seconds: u32) CombatWindow {
        return .{
            .window_ms = @as(i64, window_seconds) * std.time.ms_per_s,
        };
    }

    /// Overwrites the oldest hit once full. `counts_for_alert` only gates `last_incoming_hit_ms` (checkDamageAlert's trigger) — the hit is always ring-buffered so DPS stays accurate for filtered hits.
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

    /// Fires when incoming damage has landed since the last alert; repeat-rate is the Notifications tab's throttle, not this. Stays silent once combat stops instead of repeating on a timer.
    pub fn checkDamageAlert(self: *CombatWindow, now_ms: i64) bool {
        if (self.last_incoming_hit_ms == 0) return false;
        if (self.last_incoming_hit_ms <= self.last_damage_alert_ms) return false;
        self.last_damage_alert_ms = now_ms;
        return true;
    }

    /// Null when the span is too short to trust a rate.
    pub fn computeDps(self: *const CombatWindow, now_ms: i64) struct { incoming: ?f32, outgoing: ?f32 } {
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
            // The ring is in time order, so every older entry has expired too.
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

    /// Whether either rate moved by 0.1 or more, or to or from null.
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

/// Locked: the main thread reads it while the chatlog worker adds hits and removes characters.
pub const CombatTracker = struct {
    base: TrackerBase(CombatWindow),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, window_seconds: u32) CombatTracker {
        return .{ .base = TrackerBase(CombatWindow).init(allocator, io, window_seconds) };
    }

    pub fn deinit(self: *CombatTracker) void {
        self.base.deinit();
    }

    pub fn addEntry(
        self: *CombatTracker,
        character_name: []const u8,
        amount: u32,
        is_incoming: bool,
        timestamp_ms: i64,
        counts_for_alert: bool,
    ) !void {
        try self.base.mutex.lock(self.base.io);
        defer self.base.mutex.unlock(self.base.io);
        const window = try self.base.getOrCreate(character_name);
        window.addEntry(amount, is_incoming, timestamp_ms, counts_for_alert);
    }

    pub fn removeCharacter(self: *CombatTracker, character_name: []const u8) void {
        self.base.removeCharacter(character_name);
    }

    /// As of the last refresh; null when the span is too short to trust a rate.
    pub fn getDps(self: *CombatTracker, character_name: []const u8) struct { incoming: ?f32, outgoing: ?f32 } {
        self.base.mutex.lock(self.base.io) catch |err| {
            slog.warn("Failed to lock combat tracker mutex for '{s}': {}", .{ character_name, err });
            return .{ .incoming = 0.0, .outgoing = 0.0 };
        };
        defer self.base.mutex.unlock(self.base.io);
        if (self.base.windows.get(character_name)) |window| {
            return .{ .incoming = window.last_incoming_dps, .outgoing = window.last_outgoing_dps };
        }
        return .{ .incoming = 0.0, .outgoing = 0.0 };
    }

    /// Whether any rate moved enough to redraw.
    pub fn refreshAll(self: *CombatTracker, now_ms: i64) bool {
        return self.base.refreshAll(now_ms);
    }

    /// See CombatWindow.checkDamageAlert. Returns false if character_name has no window yet.
    pub fn checkDamageAlert(self: *CombatTracker, character_name: []const u8, now_ms: i64) bool {
        self.base.mutex.lock(self.base.io) catch |err| {
            slog.warn("Failed to lock combat tracker mutex for '{s}': {}", .{ character_name, err });
            return false;
        };
        defer self.base.mutex.unlock(self.base.io);
        const window = self.base.windows.getPtr(character_name) orelse return false;
        return window.checkDamageAlert(now_ms);
    }
};

pub const MiningEvent = struct {
    timestamp_ms: i64,
    m3: f32,
    isk: f32,
};

/// A fixed ring of recent yields, so recording one never allocates.
pub const MiningWindow = struct {
    entries: [RING_CAPACITY]MiningEvent = undefined,
    head: usize = 0,
    count: usize = 0,
    window_ms: i64,
    last_hit_ms: i64 = 0,

    // Null means not enough span yet to trust a rate.
    last_m3_per_sec: ?f32 = null,
    last_isk_per_sec: ?f32 = null,
    /// When the idle alert fired, or 0; cleared once mining picks up again.
    last_alert_ms: i64 = 0,
    /// When the stopped alert fired, or 0; cleared by the next yield.
    last_stopped_alert_ms: i64 = 0,

    pub fn init(window_seconds: u32) MiningWindow {
        return .{
            .window_ms = @as(i64, window_seconds) * std.time.ms_per_s,
        };
    }

    pub fn addEntry(self: *MiningWindow, m3: f32, isk: f32, timestamp_ms: i64) void {
        self.entries[self.head] = .{
            .timestamp_ms = timestamp_ms,
            .m3 = m3,
            .isk = isk,
        };
        self.head = (self.head + 1) % RING_CAPACITY;
        if (self.count < RING_CAPACITY) self.count += 1;
        if (timestamp_ms > self.last_hit_ms) self.last_hit_ms = timestamp_ms;
        // Mining resumed, so the stopped alert can fire again.
        self.last_stopped_alert_ms = 0;
    }

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

    /// m3 per second; null when the span is too short to trust a rate.
    pub fn computeRate(self: *const MiningWindow, now_ms: i64) ?f32 {
        return computeWindowRate(MiningEvent, "m3", &self.entries, self.head, self.count, self.window_ms, self.last_hit_ms, now_ms);
    }

    /// ISK per second; null when the span is too short to trust a rate.
    pub fn computeIskRate(self: *const MiningWindow, now_ms: i64) ?f32 {
        return computeWindowRate(MiningEvent, "isk", &self.entries, self.head, self.count, self.window_ms, self.last_hit_ms, now_ms);
    }

    /// Whether the m3 rate moved by 0.1 or more, or to or from null; the ISK rate comes from the same entries, so it's covered.
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

/// Locked: the main thread reads it and checks alerts while the chatlog worker adds yields and removes characters.
pub const MiningTracker = struct {
    base: TrackerBase(MiningWindow),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, window_seconds: u32) MiningTracker {
        return .{ .base = TrackerBase(MiningWindow).init(allocator, io, window_seconds) };
    }

    pub fn deinit(self: *MiningTracker) void {
        self.base.deinit();
    }

    pub fn addEntry(
        self: *MiningTracker,
        character_name: []const u8,
        m3: f32,
        isk: f32,
        timestamp_ms: i64,
    ) !void {
        try self.base.mutex.lock(self.base.io);
        defer self.base.mutex.unlock(self.base.io);
        const window = try self.base.getOrCreate(character_name);
        window.addEntry(m3, isk, timestamp_ms);
    }

    pub fn removeCharacter(self: *MiningTracker, character_name: []const u8) void {
        self.base.removeCharacter(character_name);
    }

    /// m3 per second as of the last refresh; null when the span is too short to trust a rate.
    pub fn getRate(self: *MiningTracker, character_name: []const u8) ?f32 {
        self.base.mutex.lock(self.base.io) catch |err| {
            slog.warn("Failed to lock mining tracker mutex for '{s}': {}", .{ character_name, err });
            return 0.0;
        };
        defer self.base.mutex.unlock(self.base.io);
        if (self.base.windows.get(character_name)) |window| {
            return window.last_m3_per_sec;
        }
        return 0.0;
    }

    /// ISK per second as of the last refresh; null when the span is too short to trust a rate.
    pub fn getIskRate(self: *MiningTracker, character_name: []const u8) ?f32 {
        self.base.mutex.lock(self.base.io) catch |err| {
            slog.warn("Failed to lock mining tracker mutex for '{s}': {}", .{ character_name, err });
            return 0.0;
        };
        defer self.base.mutex.unlock(self.base.io);
        if (self.base.windows.get(character_name)) |window| {
            return window.last_isk_per_sec;
        }
        return 0.0;
    }

    /// Whether any rate moved enough to redraw.
    pub fn refreshAll(self: *MiningTracker, now_ms: i64) bool {
        return self.base.refreshAll(now_ms);
    }

    /// True once per idle stretch: at most `threshold` yields within `alert_window_ms`.
    pub fn checkIdleAlert(
        self: *MiningTracker,
        character_name: []const u8,
        now_ms: i64,
        alert_window_ms: i64,
        threshold: u32,
    ) bool {
        self.base.mutex.lock(self.base.io) catch |err| {
            slog.warn("Failed to lock mining tracker mutex for '{s}': {}", .{ character_name, err });
            return false;
        };
        defer self.base.mutex.unlock(self.base.io);
        const window = self.base.windows.getPtr(character_name) orelse return false;
        // Never mined yet, so not idle: avoids alerting at startup.
        if (window.last_hit_ms == 0) return false;
        const count = window.countEvents(alert_window_ms, now_ms);
        if (count > threshold) {
            window.last_alert_ms = 0;
            return false;
        }
        if (window.last_alert_ms != 0) {
            return false;
        }
        window.last_alert_ms = now_ms;
        return true;
    }

    /// True once when nothing has been mined for `stopped_window_ms`; the next yield re-arms it.
    pub fn checkStoppedAlert(
        self: *MiningTracker,
        character_name: []const u8,
        now_ms: i64,
        stopped_window_ms: i64,
    ) bool {
        self.base.mutex.lock(self.base.io) catch |err| {
            slog.warn("Failed to lock mining tracker mutex for '{s}': {}", .{ character_name, err });
            return false;
        };
        defer self.base.mutex.unlock(self.base.io);
        const window = self.base.windows.getPtr(character_name) orelse return false;
        if (window.last_hit_ms == 0) return false;
        if (now_ms - window.last_hit_ms < stopped_window_ms) return false;
        if (window.last_stopped_alert_ms != 0) return false;
        window.last_stopped_alert_ms = now_ms;
        return true;
    }
};

pub const BountyEvent = struct {
    timestamp_ms: i64,
    isk: f32,
};

/// A fixed ring of recent payouts, so recording one never allocates; MiningWindow's ISK half, as payouts already arrive in ISK.
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

    pub fn addEntry(self: *BountyWindow, isk: f32, timestamp_ms: i64) void {
        self.entries[self.head] = .{
            .timestamp_ms = timestamp_ms,
            .isk = isk,
        };
        self.head = (self.head + 1) % RING_CAPACITY;
        if (self.count < RING_CAPACITY) self.count += 1;
        if (timestamp_ms > self.last_hit_ms) self.last_hit_ms = timestamp_ms;
    }

    /// ISK per second; null when the span is too short to trust a rate.
    pub fn computeIskRate(self: *const BountyWindow, now_ms: i64) ?f32 {
        return computeWindowRate(BountyEvent, "isk", &self.entries, self.head, self.count, self.window_ms, self.last_hit_ms, now_ms);
    }

    /// Whether the rate moved by 0.1 or more, or to or from null.
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

/// Locked: the main thread reads it while the chatlog worker adds payouts and removes characters.
pub const BountyTracker = struct {
    base: TrackerBase(BountyWindow),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, window_seconds: u32) BountyTracker {
        return .{ .base = TrackerBase(BountyWindow).init(allocator, io, window_seconds) };
    }

    pub fn deinit(self: *BountyTracker) void {
        self.base.deinit();
    }

    pub fn addEntry(
        self: *BountyTracker,
        character_name: []const u8,
        isk: f32,
        timestamp_ms: i64,
    ) !void {
        try self.base.mutex.lock(self.base.io);
        defer self.base.mutex.unlock(self.base.io);
        const window = try self.base.getOrCreate(character_name);
        window.addEntry(isk, timestamp_ms);
    }

    pub fn removeCharacter(self: *BountyTracker, character_name: []const u8) void {
        self.base.removeCharacter(character_name);
    }

    /// ISK per second as of the last refresh; null when the span is too short to trust a rate.
    pub fn getIskRate(self: *BountyTracker, character_name: []const u8) ?f32 {
        self.base.mutex.lock(self.base.io) catch |err| {
            slog.warn("Failed to lock bounty tracker mutex for '{s}': {}", .{ character_name, err });
            return 0.0;
        };
        defer self.base.mutex.unlock(self.base.io);
        if (self.base.windows.get(character_name)) |window| {
            return window.last_isk_per_sec;
        }
        return 0.0;
    }

    /// Whether any rate moved enough to redraw.
    pub fn refreshAll(self: *BountyTracker, now_ms: i64) bool {
        return self.base.refreshAll(now_ms);
    }
};

/// Raw unit count plus the mined ore/ice/gas name, copied by value since parseMiningLine's buffer is stack-local.
pub const ParsedMiningEvent = struct {
    amount: u32,
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,

    pub fn name(self: *const ParsedMiningEvent) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Shared allocator/mutex/hashmap plumbing for a per-character sliding-window tracker.
/// WindowT must expose `fn init(window_seconds: u32) WindowT` and `fn refresh(*WindowT, now_ms: i64) bool`.
fn TrackerBase(comptime WindowT: type) type {
    return struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        windows: std.StringHashMap(WindowT),
        window_seconds: u32,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, io: std.Io, window_seconds: u32) Self {
            return .{
                .allocator = allocator,
                .io = io,
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
            self.mutex.lock(self.io) catch |err| {
                slog.warn("Failed to lock tracker mutex removing '{s}': {}", .{ character_name, err });
                return;
            };
            defer self.mutex.unlock(self.io);
            if (self.windows.fetchRemove(character_name)) |entry| {
                self.allocator.free(entry.key);
            }
        }

        fn refreshAll(self: *Self, now_ms: i64) bool {
            self.mutex.lock(self.io) catch |err| {
                slog.warn("Failed to lock tracker mutex refreshing windows: {}", .{err});
                return false;
            };
            defer self.mutex.unlock(self.io);
            var any_changed = false;
            var iter = self.windows.valueIterator();
            while (iter.next()) |window| {
                if (window.refresh(now_ms)) any_changed = true;
            }
            return any_changed;
        }

        /// Caller holds mutex.
        fn getOrCreate(self: *Self, character_name: []const u8) !*WindowT {
            if (self.windows.getPtr(character_name)) |window| return window;
            const key = try self.allocator.dupe(u8, character_name);
            errdefer self.allocator.free(key);
            try self.windows.put(key, WindowT.init(self.window_seconds));
            return self.windows.getPtr(character_name).?;
        }
    };
}

/// `stripped_line` has its HTML stripped already, and `weapon` borrows from it. An incoming miss is a zero-amount hit, so it still counts for the Taking Damage alert; outgoing misses are dropped.
pub fn parseCombatLine(stripped_line: []const u8) ?struct { amount: u32, is_incoming: bool, weapon: []const u8 } {
    const combat_prefix = "(combat)";
    const combat_pos = std.mem.indexOf(u8, stripped_line, combat_prefix) orelse return null;
    const stripped = std.mem.trimStart(u8, stripped_line[combat_pos + combat_prefix.len ..], " \t");

    // Remote repairs and capacitor transfers aren't damage.
    if (std.mem.indexOf(u8, stripped, "boosts your") != null or
        std.mem.indexOf(u8, stripped, "shields your") != null or
        std.mem.indexOf(u8, stripped, "repairs your") != null or
        std.mem.indexOf(u8, stripped, "transfers") != null)
    {
        return null;
    }

    if (std.mem.indexOf(u8, stripped, "misses you") != null and !std.mem.startsWith(u8, stripped, "You ")) {
        return .{ .amount = 0, .is_incoming = true, .weapon = "" };
    }

    var amount: u32 = 0;
    var digits_end: usize = 0;
    var found_digit = false;
    for (stripped, 0..) |c, i| {
        if (c >= '0' and c <= '9') {
            amount = appendDigit(u32, amount, c) orelse return null;
            digits_end = i + 1;
            found_digit = true;
        } else if (found_digit) {
            break;
        } else {
            if (c != ' ' and c != '\t') return null;
        }
    }
    if (!found_digit or amount == 0) return null;

    const rest = stripped[digits_end..];
    const is_incoming = if (std.mem.indexOf(u8, rest, " from ") != null)
        true
    else if (std.mem.indexOf(u8, rest, " to ") != null)
        false
    else
        return null;

    // The weapon is the segment before the hit quality, found from the end since target names can contain " - " too.
    var weapon: []const u8 = "";
    if (std.mem.lastIndexOf(u8, rest, " - ")) |quality_dash| {
        const before_quality = rest[0..quality_dash];
        if (std.mem.lastIndexOf(u8, before_quality, " - ")) |weapon_dash| {
            weapon = std.mem.trim(u8, before_quality[weapon_dash + 3 ..], " \t");
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

/// The ISK added to the next payout; unlike combat and mining amounts, it has comma separators ("246,153 ISK").
pub fn parseBountyLine(line: []const u8) ?f32 {
    const bounty_prefix = "(bounty)";
    const bounty_pos = std.mem.indexOf(u8, line, bounty_prefix) orelse return null;
    const payload = std.mem.trimStart(u8, line[bounty_pos + bounty_prefix.len ..], " \t");

    var stripped_buf: [512]u8 = undefined;
    const stripped = stripHtml(payload, &stripped_buf);

    // u64, as a single payout can pass u32's 4.3 billion.
    var amount: u64 = 0;
    var found_digit = false;
    for (stripped) |c| {
        if (c >= '0' and c <= '9') {
            amount = appendDigit(u64, amount, c) orelse return null;
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

/// Null for residue lines, which the player doesn't gain.
pub fn parseMiningLine(line: []const u8) ?ParsedMiningEvent {
    const mining_prefix = "(mining)";
    const mining_pos = std.mem.indexOf(u8, line, mining_prefix) orelse return null;
    const payload = std.mem.trimStart(u8, line[mining_pos + mining_prefix.len ..], " \t");

    var stripped_buf: [512]u8 = undefined;
    const stripped = stripHtml(payload, &stripped_buf);

    if (std.mem.indexOf(u8, stripped, "depleted from asteroid as residue") != null) {
        return null;
    }

    // "You mined" starts both normal and critical yields.
    const mined_kw = "You mined";
    const mined_pos = std.mem.indexOf(u8, stripped, mined_kw) orelse return null;
    var cursor = std.mem.trimStart(u8, stripped[mined_pos + mined_kw.len ..], " \t");

    // A critical yield says "an additional".
    const additional_kw = "an additional ";
    if (std.mem.startsWith(u8, cursor, additional_kw)) {
        cursor = cursor[additional_kw.len..];
    }

    var amount: u32 = 0;
    var found_digit = false;
    var digit_end: usize = 0;
    for (cursor, 0..) |c, i| {
        if (c >= '0' and c <= '9') {
            amount = appendDigit(u32, amount, c) orelse return null;
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

/// Truncated to `out_buf`'s length.
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

/// Null when another digit would overflow, so an absurdly long number is skipped rather than wrapping.
fn appendDigit(comptime T: type, amount: T, digit_char: u8) ?T {
    const shifted = std.math.mul(T, amount, 10) catch return null;
    return std.math.add(T, shifted, digit_char - '0') catch null;
}

/// Rate multiplier that decays 1.0 -> 0.0 as idle time crosses the window's second half, instead of holding flat then cutting to zero.
fn idleDecayFactor(now_ms: i64, last_activity_ms: i64, window_ms: i64) f32 {
    const idle_ms = now_ms - last_activity_ms;
    const grace_ms = @divTrunc(window_ms, 2);
    if (idle_ms <= grace_ms) return 1.0;
    const decay_span_ms = window_ms - grace_ms;
    const over_ms = @min(idle_ms - grace_ms, decay_span_ms);
    return 1.0 - @as(f32, @floatFromInt(over_ms)) / @as(f32, @floatFromInt(decay_span_ms));
}

/// Sums `@field(entry, field)` over the window ending at now_ms, decayed by idleDecayFactor. Null means not enough span yet to trust a rate.
fn computeWindowRate(
    comptime T: type,
    comptime field: []const u8,
    entries: []const T,
    head: usize,
    count: usize,
    window_ms: i64,
    last_hit_ms: i64,
    now_ms: i64,
) ?f32 {
    if (last_hit_ms == 0 or now_ms - last_hit_ms >= window_ms) return 0.0;
    const cutoff = now_ms - window_ms;
    var total: f32 = 0;
    var newest_ms: i64 = 0;
    var oldest_ms: i64 = 0;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const idx = (head + entries.len - 1 - i) % entries.len;
        const entry = &entries[idx];
        if (entry.timestamp_ms < cutoff) break;
        if (i == 0) newest_ms = entry.timestamp_ms;
        oldest_ms = entry.timestamp_ms;
        total += @field(entry, field);
    }
    const span_ms = newest_ms - oldest_ms;
    if (span_ms < MIN_RATE_SPAN_MS) return null;

    const window_secs = @as(f32, @floatFromInt(@min(window_ms, span_ms))) / 1000.0;
    return (total / window_secs) * idleDecayFactor(now_ms, last_hit_ms, window_ms);
}
