//! Per-character combat, mining and bounty rates over a sliding window, and the gamelog line parsers that feed them.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.scoped("activity_tracker");

/// Ring-buffer capacity per character; a window holding more events is rated over the time the newest 512 span.
const RING_CAPACITY = 512;

/// Guards against simultaneous multi-module/multi-weapon log lines spiking a warm-up rate computed over a near-zero span.
const MIN_RATE_SPAN_MS: i64 = 3 * std.time.ms_per_s;

/// Lines landing this soon after a streak's first one (lasers cycling in step, one volley) count as its first moment.
const FIRST_MOMENT_MS: i64 = 1 * std.time.ms_per_s;

const WindowSum = struct {
    total: f32 = 0,
    after_first_moment: f32 = 0,
    count: usize = 0,
    count_after_first_moment: usize = 0,
    newest_ms: i64 = 0,

    const WarmUp = enum { to_now, to_newest };

    fn add(self: *WindowSum, amount: f32, timestamp_ms: i64, streak_start_ms: i64) void {
        self.total += amount;
        self.count += 1;
        self.newest_ms = @max(self.newest_ms, timestamp_ms);
        if (timestamp_ms - streak_start_ms >= FIRST_MOMENT_MS) {
            self.after_first_moment += amount;
            self.count_after_first_moment += 1;
        }
    }

    /// Total over the window once the streak is a window old; before that, what came after its first moment over the time since, to now or to the newest event. Null while that's too short to trust.
    /// `ring_full_from_ms` is the oldest event kept when the ring filled up inside the window, so only the time it covers counts.
    fn rate(self: WindowSum, streak_start_ms: i64, now_ms: i64, window_ms: i64, ring_full_from_ms: ?i64, warm_up: WarmUp) ?f32 {
        if (self.count == 0) return 0.0;
        if (ring_full_from_ms) |from_ms| {
            const covered_ms = now_ms - from_ms;
            if (covered_ms < MIN_RATE_SPAN_MS) return null;
            return self.total / seconds(covered_ms);
        }
        if (now_ms - streak_start_ms >= window_ms) return self.total / seconds(window_ms);
        if (self.count_after_first_moment == 0) return null;
        const end_ms = switch (warm_up) {
            .to_now => now_ms,
            .to_newest => self.newest_ms,
        };
        const elapsed_ms = end_ms - streak_start_ms;
        if (elapsed_ms < MIN_RATE_SPAN_MS) return null;
        return self.after_first_moment / seconds(elapsed_ms);
    }

    fn seconds(ms: i64) f32 {
        return @as(f32, @floatFromInt(ms)) / 1000.0;
    }
};

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
    streak_start_ms: i64 = 0,
    last_incoming_hit_ms: i64 = 0,
    /// 0 = never fired.
    last_damage_alert_ms: i64 = 0,

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
        self.streak_start_ms = streakStart(self.streak_start_ms, self.last_hit_ms, timestamp_ms, self.window_ms);
        if (timestamp_ms > self.last_hit_ms) self.last_hit_ms = timestamp_ms;
        if (is_incoming and counts_for_alert and timestamp_ms > self.last_incoming_hit_ms) self.last_incoming_hit_ms = timestamp_ms;
    }

    /// Fires when incoming damage has landed since the last alert; repeat-rate is the Notifications tab's throttle, not this. Stays silent once combat stops instead of repeating on a timer.
    pub fn checkDamageAlert(self: *CombatWindow) bool {
        if (self.last_incoming_hit_ms == 0) return false;
        if (self.last_incoming_hit_ms <= self.last_damage_alert_ms) return false;
        self.last_damage_alert_ms = self.last_incoming_hit_ms;
        return true;
    }

    /// Per second; see WindowSum.rate. Hits arrive irregularly, so warm-up runs to now.
    pub fn computeDps(self: *const CombatWindow, now_ms: i64) struct { incoming: ?f32, outgoing: ?f32 } {
        if (self.last_hit_ms == 0 or now_ms - self.last_hit_ms >= self.window_ms) {
            return .{ .incoming = 0.0, .outgoing = 0.0 };
        }
        const cutoff = now_ms - self.window_ms;
        var incoming: WindowSum = .{};
        var outgoing: WindowSum = .{};
        var oldest_ms: i64 = now_ms;

        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + RING_CAPACITY - 1 - i) % RING_CAPACITY;
            const entry = &self.entries[idx];
            // The ring is in time order, so every older entry has expired too.
            if (entry.timestamp_ms < cutoff) break;
            oldest_ms = entry.timestamp_ms;
            const sum = if (entry.is_incoming) &incoming else &outgoing;
            sum.add(@floatFromInt(entry.amount), entry.timestamp_ms, self.streak_start_ms);
        }
        const ring_full_from_ms: ?i64 = if (i == RING_CAPACITY) oldest_ms else null;
        return .{
            .incoming = incoming.rate(self.streak_start_ms, now_ms, self.window_ms, ring_full_from_ms, .to_now),
            .outgoing = outgoing.rate(self.streak_start_ms, now_ms, self.window_ms, ring_full_from_ms, .to_now),
        };
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

    /// Worker thread stopped only; existing history is kept and rated over the new length.
    pub fn setWindowSeconds(self: *CombatTracker, window_seconds: u32) void {
        self.base.setWindowSeconds(window_seconds);
    }

    /// Null when the span is too short to trust a rate.
    pub fn getDps(self: *CombatTracker, character_name: []const u8, now_ms: i64) struct { incoming: ?f32, outgoing: ?f32 } {
        self.base.mutex.lock(self.base.io) catch |err| {
            slog.warn("Failed to lock combat tracker mutex for '{s}': {}", .{ character_name, err });
            return .{ .incoming = 0.0, .outgoing = 0.0 };
        };
        defer self.base.mutex.unlock(self.base.io);
        if (self.base.windows.getPtr(character_name)) |window| {
            const dps = window.computeDps(now_ms);
            return .{ .incoming = dps.incoming, .outgoing = dps.outgoing };
        }
        return .{ .incoming = 0.0, .outgoing = 0.0 };
    }

    /// See CombatWindow.checkDamageAlert. Returns false if character_name has no window yet.
    pub fn checkDamageAlert(self: *CombatTracker, character_name: []const u8) bool {
        self.base.mutex.lock(self.base.io) catch |err| {
            slog.warn("Failed to lock combat tracker mutex for '{s}': {}", .{ character_name, err });
            return false;
        };
        defer self.base.mutex.unlock(self.base.io);
        const window = self.base.windows.getPtr(character_name) orelse return false;
        return window.checkDamageAlert();
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
    streak_start_ms: i64 = 0,
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
        self.streak_start_ms = streakStart(self.streak_start_ms, self.last_hit_ms, timestamp_ms, self.window_ms);
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

    /// m3 per second; see WindowSum.rate.
    pub fn computeRate(self: *const MiningWindow, now_ms: i64) ?f32 {
        return computeWindowRate(MiningEvent, "m3", &self.entries, self.head, self.count, self.window_ms, self.last_hit_ms, self.streak_start_ms, now_ms);
    }

    /// ISK per second; see WindowSum.rate.
    pub fn computeIskRate(self: *const MiningWindow, now_ms: i64) ?f32 {
        return computeWindowRate(MiningEvent, "isk", &self.entries, self.head, self.count, self.window_ms, self.last_hit_ms, self.streak_start_ms, now_ms);
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

    /// Worker thread stopped only; existing history is kept and rated over the new length.
    pub fn setWindowSeconds(self: *MiningTracker, window_seconds: u32) void {
        self.base.setWindowSeconds(window_seconds);
    }

    /// m3 and ISK per second; null when the span is too short to trust a rate.
    pub fn getRates(self: *MiningTracker, character_name: []const u8, now_ms: i64) struct { m3: ?f32, isk: ?f32 } {
        self.base.mutex.lock(self.base.io) catch |err| {
            slog.warn("Failed to lock mining tracker mutex for '{s}': {}", .{ character_name, err });
            return .{ .m3 = 0.0, .isk = 0.0 };
        };
        defer self.base.mutex.unlock(self.base.io);
        if (self.base.windows.getPtr(character_name)) |window| {
            return .{ .m3 = window.computeRate(now_ms), .isk = window.computeIskRate(now_ms) };
        }
        return .{ .m3 = 0.0, .isk = 0.0 };
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
        if (now_ms - window.streak_start_ms < alert_window_ms) return false;
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
    streak_start_ms: i64 = 0,

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
        self.streak_start_ms = streakStart(self.streak_start_ms, self.last_hit_ms, timestamp_ms, self.window_ms);
        if (timestamp_ms > self.last_hit_ms) self.last_hit_ms = timestamp_ms;
    }

    /// ISK per second; see WindowSum.rate.
    pub fn computeIskRate(self: *const BountyWindow, now_ms: i64) ?f32 {
        return computeWindowRate(BountyEvent, "isk", &self.entries, self.head, self.count, self.window_ms, self.last_hit_ms, self.streak_start_ms, now_ms);
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

    /// Worker thread stopped only; existing history is kept and rated over the new length.
    pub fn setWindowSeconds(self: *BountyTracker, window_seconds: u32) void {
        self.base.setWindowSeconds(window_seconds);
    }

    /// Null when the span is too short to trust a rate.
    pub fn getIskRate(self: *BountyTracker, character_name: []const u8, now_ms: i64) ?f32 {
        self.base.mutex.lock(self.base.io) catch |err| {
            slog.warn("Failed to lock bounty tracker mutex for '{s}': {}", .{ character_name, err });
            return 0.0;
        };
        defer self.base.mutex.unlock(self.base.io);
        if (self.base.windows.getPtr(character_name)) |window| return window.computeIskRate(now_ms);
        return 0.0;
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
/// WindowT must expose `fn init(window_seconds: u32) WindowT` and a `window_ms` field.
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

        fn setWindowSeconds(self: *Self, window_seconds: u32) void {
            self.window_seconds = window_seconds;
            var iter = self.windows.valueIterator();
            while (iter.next()) |window| window.window_ms = @as(i64, window_seconds) * std.time.ms_per_s;
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

    if (std.mem.indexOf(u8, stripped, "misses you")) |miss_pos| {
        if (!std.mem.startsWith(u8, stripped, "You ")) {
            const weapon_dash = std.mem.indexOfPos(u8, stripped, miss_pos, " - ") orelse return .{ .amount = 0, .is_incoming = true, .weapon = "" };
            return .{ .amount = 0, .is_incoming = true, .weapon = std.mem.trim(u8, stripped[weapon_dash + 3 ..], " \t") };
        }
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

fn streakStart(current_start_ms: i64, last_hit_ms: i64, timestamp_ms: i64, window_ms: i64) i64 {
    if (last_hit_ms == 0 or timestamp_ms - last_hit_ms >= window_ms) return timestamp_ms;
    return current_start_ms;
}

/// Mining yields and bounty payouts per second over the window ending at now_ms; yields come in cycles, so warm-up runs to the newest.
fn computeWindowRate(
    comptime T: type,
    comptime field: []const u8,
    entries: []const T,
    head: usize,
    count: usize,
    window_ms: i64,
    last_hit_ms: i64,
    streak_start_ms: i64,
    now_ms: i64,
) ?f32 {
    if (last_hit_ms == 0 or now_ms - last_hit_ms >= window_ms) return 0.0;
    const cutoff = now_ms - window_ms;
    var sum: WindowSum = .{};
    var oldest_ms: i64 = now_ms;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const idx = (head + entries.len - 1 - i) % entries.len;
        const entry = &entries[idx];
        if (entry.timestamp_ms < cutoff) break;
        oldest_ms = entry.timestamp_ms;
        sum.add(@field(entry, field), entry.timestamp_ms, streak_start_ms);
    }
    const ring_full_from_ms: ?i64 = if (i == entries.len) oldest_ms else null;
    return sum.rate(streak_start_ms, now_ms, window_ms, ring_full_from_ms, .to_newest);
}

const testing = std.testing;

test "parseCombatLine reads incoming and outgoing damage and the weapon" {
    const incoming = parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) 484 from Gist Seraphim - Heavy Missile - Hits").?;
    try testing.expectEqual(@as(u32, 484), incoming.amount);
    try testing.expect(incoming.is_incoming);
    try testing.expectEqualStrings("Heavy Missile", incoming.weapon);

    const outgoing = parseCombatLine("[ 2026.09.17 19:28:07 ] (combat) 312 to Gist Seraphim - Hammerhead II - Smashes").?;
    try testing.expectEqual(@as(u32, 312), outgoing.amount);
    try testing.expect(!outgoing.is_incoming);
    try testing.expectEqualStrings("Hammerhead II", outgoing.weapon);
}

test "parseCombatLine counts a miss against you as incoming with no damage" {
    const miss = parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) Gist Seraphim misses you completely - Heavy Missile").?;
    try testing.expectEqual(@as(u32, 0), miss.amount);
    try testing.expect(miss.is_incoming);
    try testing.expectEqualStrings("Heavy Missile", miss.weapon);

    const npc_miss = parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) CONCORD Police Captain - CONCORD Police Captain misses you completely").?;
    try testing.expect(npc_miss.is_incoming);
    try testing.expectEqualStrings("", npc_miss.weapon);
}

test "parseCombatLine ignores repairs, transfers and malformed lines" {
    try testing.expect(parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) 350 energy transfers to Some Pilot - Large Remote Capacitor Transmitter") == null);
    try testing.expect(parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) 200 remote armor repairs your ship - Some Pilot") == null);
    try testing.expect(parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) 100 hit points of something") == null);
    try testing.expect(parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) 0 from Gist Seraphim - Heavy Missile - Hits") == null);
    try testing.expect(parseCombatLine("[ 2026.09.17 19:28:06 ] (notify) 484 from Gist Seraphim - Heavy Missile - Hits") == null);
}

test "parseCombatLine skips an amount too large for u32 instead of wrapping" {
    try testing.expect(parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) 99999999999 from Gist Seraphim - Heavy Missile - Hits") == null);
}

test "parseBountyLine reads comma-separated ISK, including payouts past u32" {
    try testing.expectEqual(@as(f32, 120272), parseBountyLine("[ 2026.09.17 19:28:07 ] (bounty) <b>120,272 ISK</b> added to next bounty payout").?);
    try testing.expectEqual(@as(f32, 5_000_000_000), parseBountyLine("[ 2026.09.17 19:28:07 ] (bounty) <b>5,000,000,000 ISK</b> added to next bounty payout").?);
    try testing.expect(parseBountyLine("[ 2026.09.17 19:28:07 ] (bounty) <b>0 ISK</b> added to next bounty payout") == null);
    try testing.expect(parseBountyLine("[ 2026.09.17 19:28:07 ] (bounty) Bounty payout pending") == null);
}

test "parseMiningLine reads normal and critical yields but not residue" {
    const normal = parseMiningLine("[ 2026.08.09 23:45:29 ] (mining) <color=0x77ffffff>You mined <b>1</b> units of Dark Glitter").?;
    try testing.expectEqual(@as(u32, 1), normal.amount);
    try testing.expectEqualStrings("Dark Glitter", normal.name());

    const critical = parseMiningLine("[ 2026.08.09 23:45:30 ] (mining) You mined an additional <b>52</b> units of Veldspar.").?;
    try testing.expectEqual(@as(u32, 52), critical.amount);
    try testing.expectEqualStrings("Veldspar", critical.name());

    try testing.expect(parseMiningLine("[ 2026.08.09 23:45:31 ] (mining) 12 units of Veldspar depleted from asteroid as residue") == null);
    try testing.expect(parseMiningLine("[ 2026.08.09 23:45:31 ] (mining) You mined <b>5</b> units of ") == null);
}

test "stripHtml drops tags and truncates to the buffer" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("You mined 1 units", stripHtml("<color=0x77ffffff>You mined <b>1</b> units", &buf));
    var small: [3]u8 = undefined;
    try testing.expectEqualStrings("abc", stripHtml("<b>abcdef</b>", &small));
}

test "isWeaponExcluded matches case-insensitive substrings and skips blank entries" {
    try testing.expect(isWeaponExcluded("Hammerhead II", "drone, hammerhead"));
    try testing.expect(isWeaponExcluded("Heavy Missile", " , missile "));
    try testing.expect(!isWeaponExcluded("Heavy Missile", ",,"));
    try testing.expect(!isWeaponExcluded("", "missile"));
    try testing.expect(!isWeaponExcluded("Heavy Missile", "Heavy Missile Launcher"));
}

test "CombatWindow withholds a rate until hits span three seconds, only for a direction with hits" {
    var window: CombatWindow = .init(10);
    window.addEntry(100, true, 1_000, true);
    window.addEntry(100, true, 2_000, true);
    const dps = window.computeDps(2_000);
    try testing.expect(dps.incoming == null);
    try testing.expectEqual(@as(f32, 0.0), dps.outgoing.?);
}

test "CombatWindow warms up on the hits after the first moment, over the time since" {
    var window: CombatWindow = .init(10);
    window.addEntry(100, true, 1_000, true);
    window.addEntry(50, false, 3_000, true);
    window.addEntry(100, true, 5_000, true);
    const dps = window.computeDps(5_000);
    try testing.expectEqual(@as(f32, 25.0), dps.incoming.?);
    try testing.expectEqual(@as(f32, 12.5), dps.outgoing.?);
}

test "CombatWindow rates a streak a window old as its total over the window" {
    var window: CombatWindow = .init(10);
    var t: i64 = 1_000;
    while (t <= 20_000) : (t += 1_000) window.addEntry(100, true, t, true);
    try testing.expectEqual(@as(f32, 100.0), window.computeDps(20_500).incoming.?);
}

test "CombatWindow reports zero once the last hit leaves the window" {
    var window: CombatWindow = .init(10);
    window.addEntry(100, true, 1_000, true);
    window.addEntry(100, true, 5_000, true);
    const dps = window.computeDps(15_000);
    try testing.expectEqual(@as(f32, 0.0), dps.incoming.?);
    try testing.expectEqual(@as(f32, 0.0), dps.outgoing.?);
}

test "CombatWindow keeps only the newest hits once the ring wraps" {
    var window: CombatWindow = .init(10);
    for (0..RING_CAPACITY + 88) |i| {
        window.addEntry(1, true, 1_000 + @as(i64, @intCast(i)) * 10, true);
    }
    try testing.expectEqual(@as(usize, RING_CAPACITY), window.count);
    const newest_ms = 1_000 + @as(i64, RING_CAPACITY + 87) * 10;
    const oldest_ms = 1_000 + @as(i64, 88) * 10;
    const span_secs = @as(f32, @floatFromInt(newest_ms - oldest_ms)) / 1000.0;
    try testing.expectApproxEqAbs(@as(f32, RING_CAPACITY) / span_secs, window.computeDps(newest_ms).incoming.?, 0.01);
}

test "CombatWindow alerts once per burst of incoming damage" {
    var window: CombatWindow = .init(10);
    try testing.expect(!window.checkDamageAlert());

    window.addEntry(100, true, 1_000, true);
    try testing.expect(window.checkDamageAlert());
    try testing.expect(!window.checkDamageAlert());

    window.addEntry(100, true, 2_000, false);
    try testing.expect(!window.checkDamageAlert());

    window.addEntry(100, true, 3_000, true);
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
    var t: i64 = 1_000;
    while (t <= 37_000) : (t += 12_000) {
        window.addEntry(110, 0, t);
        window.addEntry(110, 0, t);
    }
    try testing.expectApproxEqAbs(@as(f32, 220.0 / 12.0), window.computeRate(40_000).?, 0.001);
}

test "MiningWindow rates a streak a window old as its total over the window" {
    var window: MiningWindow = .init(60);
    var t: i64 = 1_000;
    while (t <= 121_000) : (t += 12_000) window.addEntry(110, 0, t);
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

    try testing.expect(!tracker.checkIdleAlert("Some Pilot", 1_000, 60_000, 2));

    try tracker.addEntry("Some Pilot", 10, 0, 1_000);
    try testing.expect(tracker.checkIdleAlert("Some Pilot", 61_000, 60_000, 2));
    try testing.expect(!tracker.checkIdleAlert("Some Pilot", 61_500, 60_000, 2));

    for ([_]i64{ 62_000, 63_000, 64_000 }) |ts| try tracker.addEntry("Some Pilot", 10, 0, ts);
    try testing.expect(!tracker.checkIdleAlert("Some Pilot", 64_000, 60_000, 2));
    try testing.expect(tracker.checkIdleAlert("Some Pilot", 200_000, 60_000, 2));
}

test "MiningTracker idle alert waits until mining has run a whole detection window" {
    var tracker: MiningTracker = .init(testing.allocator, testing.io, 60);
    defer tracker.deinit();
    try tracker.addEntry("Some Pilot", 110, 0, 1_000);
    try testing.expect(!tracker.checkIdleAlert("Some Pilot", 1_000, 30_000, 1));
    try testing.expect(!tracker.checkIdleAlert("Some Pilot", 30_000, 30_000, 1));
    try testing.expect(tracker.checkIdleAlert("Some Pilot", 31_000, 30_000, 1));
}

test "MiningTracker stopped alert fires once until mining resumes" {
    var tracker: MiningTracker = .init(testing.allocator, testing.io, 60);
    defer tracker.deinit();

    try tracker.addEntry("Some Pilot", 10, 0, 4_000);
    try testing.expect(!tracker.checkStoppedAlert("Some Pilot", 5_000, 30_000));
    try testing.expect(tracker.checkStoppedAlert("Some Pilot", 40_000, 30_000));
    try testing.expect(!tracker.checkStoppedAlert("Some Pilot", 41_000, 30_000));

    try tracker.addEntry("Some Pilot", 10, 0, 42_000);
    try testing.expect(tracker.checkStoppedAlert("Some Pilot", 80_000, 30_000));
}

test "CombatTracker reports zero for a character it hasn't seen" {
    var tracker: CombatTracker = .init(testing.allocator, testing.io, 10);
    defer tracker.deinit();
    const dps = tracker.getDps("Nobody", 1_000);
    try testing.expectEqual(@as(f32, 0.0), dps.incoming.?);
    try testing.expect(!tracker.checkDamageAlert("Nobody"));
}

test "MiningTracker keeps its history and rates it over a new window length" {
    var tracker: MiningTracker = .init(testing.allocator, testing.io, 60);
    defer tracker.deinit();
    var t: i64 = 1_000;
    while (t <= 121_000) : (t += 12_000) try tracker.addEntry("Some Pilot", 110, 0, t);

    try testing.expectApproxEqAbs(@as(f32, 550.0 / 60.0), tracker.getRates("Some Pilot", 121_500).m3.?, 0.001);

    tracker.setWindowSeconds(120);
    try testing.expectApproxEqAbs(@as(f32, 1_100.0 / 120.0), tracker.getRates("Some Pilot", 121_500).m3.?, 0.001);
}
