//! Fetches the Map Panel's ESI figures on a background thread, and hands each snapshot to the main thread.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const stats = @import("stats.zig");
const http_client = @import("../util/http_client.zig");
const detached = @import("../util/detached.zig");
const log = @import("../log.zig");

const Snapshot = stats.Snapshot;
const slog = log.Scoped("map");

const ESI_BASE = "https://esi.evetech.net/latest";
const ESI_QUERY = "/?datasource=tranquility";
/// ESI refreshes these hourly; asked more often so a new hour shows soon after it lands.
const REFRESH_INTERVAL_MS: u64 = 15 * std.time.ms_per_min;
const RETRY_INTERVAL_MS: u64 = 2 * std.time.ms_per_min;
/// /universe/names/ takes at most this many ids.
const MAX_NAMES_REQUESTED = 1000;

/// Lives as long as the app, since its thread may outlast the panel's window.
pub const StatsFeed = struct {
    /// Main thread only.
    next_fetch: win32.Ticks = .{},
    /// Set while the fetch thread runs.
    is_busy: std.atomic.Value(bool) = .init(false),
    /// Set by the fetch thread when nothing arrived; the main thread clears it.
    has_failed: std.atomic.Value(bool) = .init(false),
    /// The newest snapshot not yet taken; ownership passes with the swap.
    ready: std.atomic.Value(?*Snapshot) = .init(null),

    /// After the fetch thread has finished.
    pub fn deinit(self: *StatsFeed) void {
        if (self.take()) |snapshot| destroySnapshot(snapshot);
    }

    /// Per tick while the panel shows: starts a fetch once one is due.
    pub fn poll(self: *StatsFeed, allocator: std.mem.Allocator, now: win32.Ticks) void {
        if (self.has_failed.swap(false, .acq_rel)) self.next_fetch = .{ .ms = now.ms + RETRY_INTERVAL_MS };
        if (now.ms < self.next_fetch.ms or self.is_busy.swap(true, .acq_rel)) return;
        self.next_fetch = .{ .ms = now.ms + REFRESH_INTERVAL_MS };
        detached.spawn(fetchThread, .{ self, allocator }) catch |err| {
            slog.err("Failed to fetch map stats: {}", .{err});
            self.is_busy.store(false, .release);
        };
    }

    /// The caller owns the result, and frees it with destroySnapshot.
    pub fn take(self: *StatsFeed) ?*Snapshot {
        return self.ready.swap(null, .acq_rel);
    }
};

pub fn destroySnapshot(snapshot: *Snapshot) void {
    const allocator = snapshot.allocator;
    snapshot.deinit();
    allocator.destroy(snapshot);
}

/// The fetch's thread; touches nothing of the main thread's but the feed's atomics and the allocator.
fn fetchThread(feed: *StatsFeed, allocator: std.mem.Allocator) void {
    defer feed.is_busy.store(false, .release);
    const snapshot = fetchSnapshot(allocator) catch |err| {
        slog.warn("Failed to fetch map stats: {}", .{err});
        feed.has_failed.store(true, .release);
        return;
    };
    if (feed.ready.swap(snapshot, .acq_rel)) |unclaimed| destroySnapshot(unclaimed);
}

/// Keeps what arrived, each reply's failure logged where it happened; an error only when nothing did.
fn fetchSnapshot(allocator: std.mem.Allocator) !*Snapshot {
    var session = try http_client.Session.init();
    defer session.deinit();

    const snapshot = try allocator.create(Snapshot);
    errdefer allocator.destroy(snapshot);
    snapshot.* = try .init(allocator);
    errdefer snapshot.deinit();

    fetchInto(&session, snapshot, "/universe/system_kills", Snapshot.applyKills);
    fetchInto(&session, snapshot, "/universe/system_jumps", Snapshot.applyJumps);
    fetchInto(&session, snapshot, "/sovereignty/map", Snapshot.applySovereignty);
    if (!snapshot.hasAnything()) return error.StatsFetchFailed;

    if (snapshot.has_sovereignty) fetchHolderNames(&session, snapshot);
    snapshot.fetched_ms = win32.Ticks.now().ms;
    return snapshot;
}

fn fetchInto(session: *const http_client.Session, snapshot: *Snapshot, comptime path: []const u8, comptime apply: fn (*Snapshot, []const u8) anyerror!void) void {
    const allocator = snapshot.allocator;
    // Logs its own failures.
    const body = session.fetch(allocator, ESI_BASE ++ path ++ ESI_QUERY, .{}) catch return;
    defer allocator.free(body);
    apply(snapshot, body) catch |err| {
        slog.warn("Failed to read ESI's '{s}': {}", .{ path, err });
    };
}

/// Without names the panel only leaves out who holds a system, so a failure isn't one worth retrying.
fn fetchHolderNames(session: *const http_client.Session, snapshot: *Snapshot) void {
    var arena: std.heap.ArenaAllocator = .init(snapshot.allocator);
    defer arena.deinit();
    const ids = snapshot.holder_ids.items;
    if (ids.len == 0) return;
    const request = stats.namesRequest(arena.allocator(), ids[0..@min(ids.len, MAX_NAMES_REQUESTED)]) catch |err| {
        slog.warn("Failed to ask ESI who holds systems: {}", .{err});
        return;
    };
    // Logs its own failures.
    const body = session.fetch(arena.allocator(), ESI_BASE ++ "/universe/names" ++ ESI_QUERY, .{ .content_type = "application/json", .payload = request }) catch return;
    snapshot.applyNames(body) catch |err| {
        slog.warn("Failed to read who holds systems: {}", .{err});
    };
}
