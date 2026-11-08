//! Follows zKillboard's live kills on background threads, one run at a time, and hands each run's kills and names to the main thread.
const std = @import("std");
const zkill = @import("zkill.zig");
const http_client = @import("../util/http_client.zig");
const detached = @import("../util/detached.zig");
const log = @import("../log.zig");

const Kill = zkill.Kill;
const slog = log.Scoped("map");

const SEQUENCE_URL = "https://r2z2.zkillboard.com/ephemeral/sequence.json";
const FILE_URL_FORMAT = "https://r2z2.zkillboard.com/ephemeral/{d}.json";
const NAMES_URL = "https://esi.evetech.net/latest/universe/names/?datasource=tranquility";
/// At the newest file, as zKillboard asks.
const LIVE_EDGE_WAIT_MS: u64 = 6 * std.time.ms_per_s;
const RETRY_WAIT_MS: u64 = 30 * std.time.ms_per_s;
/// When zKillboard says it's too busy without saying for how long.
const RATE_LIMIT_WAIT_MS: u64 = 60 * std.time.ms_per_s;
/// A run behind the newest file stops here and the next starts at once, so kills reach the map as they're read.
const MAX_FILES_PER_RUN = 50;
/// /universe/names/ takes at most this many ids.
const MAX_NAMES_REQUESTED = 1000;
/// Paused longer than this, the feed starts again at the newest file rather than catching up.
const RESTART_GAP_MS: u64 = 60 * std.time.ms_per_s;

const NameRow = struct { id: u32, name: []const u8 };

/// One run's kills and the names they brought, handed to the main thread whole.
pub const Batch = struct {
    allocator: std.mem.Allocator,
    kills: std.ArrayList(Kill) = .empty,
    /// Each name owned; take them with takeNames.
    names: std.ArrayList(Name) = .empty,
    /// How long the main thread waits before the next run.
    wait_ms: u64 = RETRY_WAIT_MS,

    pub const Name = struct {
        id: u32,
        /// Owned.
        name: []const u8,
    };

    pub fn destroy(self: *Batch) void {
        const allocator = self.allocator;
        for (self.names.items) |entry| allocator.free(entry.name);
        self.names.deinit(allocator);
        self.kills.deinit(allocator);
        allocator.destroy(self);
    }

    /// Moves each name into `names`, which then owns it.
    pub fn takeNames(self: *Batch, names: *zkill.Names) void {
        for (self.names.items) |entry| {
            names.put(self.allocator, entry.id, entry.name) catch |err| {
                slog.warn("Failed to keep a name for a kill: {}", .{err});
            };
        }
        self.names.clearRetainingCapacity();
    }
};

/// Lives as long as the app, since its thread may outlast the panel's window.
pub const ZkillFeed = struct {
    /// Main thread only; in ms since boot.
    next_run_ms: u64 = 0,
    /// Main thread only: when the last batch was taken, in ms since boot.
    last_taken_ms: u64 = 0,
    /// Set while a run's thread runs.
    is_busy: std.atomic.Value(bool) = .init(false),
    /// The newest batch not yet taken; ownership passes with the swap.
    ready: std.atomic.Value(?*Batch) = .init(null),
    /// The next file to read, 0 to start at the newest; the run's thread only, or the main thread while none runs.
    sequence: u64 = 0,
    /// Ids whose names were asked for; the run's thread only, or the main thread while none runs.
    asked_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,

    /// After the run's thread has finished; `allocator` is the one poll was given.
    pub fn deinit(self: *ZkillFeed, allocator: std.mem.Allocator) void {
        if (self.take()) |batch| batch.destroy();
        self.asked_ids.deinit(allocator);
    }

    /// Per tick while kills show: starts a run once one is due and the last batch was taken.
    pub fn poll(self: *ZkillFeed, allocator: std.mem.Allocator, now_ms: u64) void {
        if (now_ms < self.next_run_ms or self.ready.load(.acquire) != null) return;
        if (self.is_busy.swap(true, .acq_rel)) return;
        if (now_ms -| self.last_taken_ms > RESTART_GAP_MS) self.sequence = 0;
        detached.spawn(run, .{ self, allocator }) catch |err| {
            slog.err("Failed to follow zKillboard's kills: {}", .{err});
            self.is_busy.store(false, .release);
            self.next_run_ms = now_ms + RETRY_WAIT_MS;
        };
    }

    /// The caller owns the result, and frees it with destroy; the next run is due its wait from `now_ms`.
    pub fn takeBatch(self: *ZkillFeed, now_ms: u64) ?*Batch {
        const batch = self.take() orelse return null;
        self.next_run_ms = now_ms + batch.wait_ms;
        self.last_taken_ms = now_ms;
        return batch;
    }

    fn take(self: *ZkillFeed) ?*Batch {
        return self.ready.swap(null, .acq_rel);
    }
};

/// The run's thread; touches nothing of the main thread's but the feed's atomics, its run-owned fields and the allocator.
fn run(feed: *ZkillFeed, allocator: std.mem.Allocator) void {
    defer feed.is_busy.store(false, .release);
    const batch = allocator.create(Batch) catch |err| {
        slog.err("Failed to follow zKillboard's kills: {}", .{err});
        return;
    };
    batch.* = .{ .allocator = allocator };
    defer if (feed.ready.swap(batch, .acq_rel)) |unclaimed| unclaimed.destroy();

    // Logs its own failure; the batch still goes, empty, so the main thread waits before trying again.
    var session = http_client.Session.init() catch return;
    defer session.deinit();
    batch.wait_ms = readFiles(feed, &session, batch);
    nameKills(feed, &session, batch);
}

/// Reads the files from feed.sequence on into `batch`, and returns how long to wait before the next run.
fn readFiles(feed: *ZkillFeed, session: *const http_client.Session, batch: *Batch) u64 {
    const allocator = batch.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    if (feed.sequence == 0) {
        // Logs its own failures.
        const body = session.fetch(arena.allocator(), SEQUENCE_URL, .{}) catch return RETRY_WAIT_MS;
        feed.sequence = zkill.parseSequence(arena.allocator(), body) catch |err| {
            slog.warn("Failed to read zKillboard's newest kill: {}", .{err});
            return RETRY_WAIT_MS;
        };
    }
    for (0..MAX_FILES_PER_RUN) |_| {
        _ = arena.reset(.retain_capacity);
        var url_buf: [96]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, FILE_URL_FORMAT, .{feed.sequence}) catch unreachable;
        // Logs its own failures.
        const response = session.send(arena.allocator(), url, .{}) catch return RETRY_WAIT_MS;
        switch (response.status) {
            200 => {},
            404 => return LIVE_EDGE_WAIT_MS,
            429 => return if (response.retry_after_seconds) |seconds| @as(u64, seconds) * std.time.ms_per_s else RATE_LIMIT_WAIT_MS,
            else => {
                slog.warn("Failed to read zKillboard's kill {d}: status {d}", .{ feed.sequence, response.status });
                return RETRY_WAIT_MS;
            },
        }
        feed.sequence += 1;
        const kill = zkill.parseKill(arena.allocator(), response.body) catch |err| {
            slog.warn("Failed to read zKillboard's kill {d}: {}", .{ feed.sequence - 1, err });
            continue;
        } orelse continue;
        batch.kills.append(allocator, kill) catch |err| {
            slog.warn("Failed to keep a kill from zKillboard: {}", .{err});
            return RETRY_WAIT_MS;
        };
    }
    return 0;
}

/// Asks ESI for the ship and victim names not yet asked for; an id is asked once, so a failed answer leaves those kills unnamed.
fn nameKills(feed: *ZkillFeed, session: *const http_client.Session, batch: *Batch) void {
    const allocator = batch.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var ids: std.ArrayList(u32) = .empty;
    for (batch.kills.items) |kill| {
        for ([_]u32{ kill.ship_type_id, kill.victim_id }) |id| {
            if (id == 0 or ids.items.len == MAX_NAMES_REQUESTED) continue;
            const entry = feed.asked_ids.getOrPut(allocator, id) catch |err| {
                slog.warn("Failed to name a kill's ship or victim: {}", .{err});
                return;
            };
            if (entry.found_existing) continue;
            ids.append(arena.allocator(), id) catch |err| {
                slog.warn("Failed to name a kill's ship or victim: {}", .{err});
                return;
            };
        }
    }
    if (ids.items.len == 0) return;
    const request = std.json.Stringify.valueAlloc(arena.allocator(), ids.items, .{}) catch |err| {
        slog.warn("Failed to name kills' ships and victims: {}", .{err});
        return;
    };
    // Logs its own failures.
    const body = session.fetch(arena.allocator(), NAMES_URL, .{ .content_type = "application/json", .payload = request }) catch return;
    const rows = std.json.parseFromSliceLeaky([]const NameRow, arena.allocator(), body, .{ .ignore_unknown_fields = true }) catch |err| {
        slog.warn("Failed to read the names of kills' ships and victims: {}", .{err});
        return;
    };
    for (rows) |row| {
        const name = allocator.dupe(u8, row.name) catch |err| {
            slog.warn("Failed to keep a name for a kill: {}", .{err});
            return;
        };
        batch.names.append(allocator, .{ .id = row.id, .name = name }) catch |err| {
            allocator.free(name);
            slog.warn("Failed to keep a name for a kill: {}", .{err});
            return;
        };
    }
}
