//! Fetches Eve Stars' kill and jump sums, and its NPC kills for the last two hours, on background threads, and hands each to the main thread.
const std = @import("std");
const types = @import("../config/types.zig");
const activity_mod = @import("activity.zig");
const evestars = @import("evestars.zig");
const http_client = @import("../util/http_client.zig");
const detached = @import("../util/detached.zig");
const handoff = @import("../util/handoff.zig");
const log = @import("../log.zig");

const Activity = activity_mod.Activity;
const NpcHours = activity_mod.NpcHours;
const TrafficSpan = types.TrafficSpan;
const slog = log.Scoped("map");

/// Eve Stars adds an hour at a time, so this catches each within a few minutes.
const TOTALS_INTERVAL_MS: u64 = 10 * std.time.ms_per_min;
const RETRY_INTERVAL_MS: u64 = std.time.ms_per_min;
/// Asked only until NPC delta has its hour before, which Eve Stars keeps a few minutes after CCP shows it.
const NPC_HOURS_INTERVAL_MS: u64 = 2 * std.time.ms_per_min;

/// Lives as long as the app, since its threads may outlast the panel's window.
pub const ActivityFeed = struct {
    /// When the sums are next asked for, in ms since boot; main thread only.
    next_totals_ms: u64 = 0,
    /// What the newest sums were asked for; null before the first; main thread only.
    asked_span: ?TrafficSpan = null,
    /// Shared with the sums' thread.
    totals: handoff.Job(Activity) = .{},
    /// When the NPC hours are next asked for, in ms since boot; main thread only.
    next_npc_hours_ms: u64 = 0,
    /// Shared with the NPC hours' thread.
    npc_hours: handoff.Job(NpcHours) = .{},

    /// After the threads have finished.
    pub fn deinit(self: *ActivityFeed) void {
        if (self.takeTotals()) |activity| activity.destroy();
        if (self.takeNpcHours()) |hours| hours.destroy();
    }

    pub fn isBusy(self: *const ActivityFeed) bool {
        return self.totals.isBusy() or self.npc_hours.isBusy();
    }

    /// Per tick while the map shows a span past the hour: asks at once for a span not yet asked for, then every TOTALS_INTERVAL_MS.
    pub fn pollTotals(self: *ActivityFeed, allocator: std.mem.Allocator, token: []const u8, span: TrafficSpan, now_ms: u64) void {
        if (self.totals.takeFailure()) self.next_totals_ms = now_ms + RETRY_INTERVAL_MS;
        const is_new_span = if (self.asked_span) |asked| asked != span else true;
        if (!is_new_span and now_ms < self.next_totals_ms) return;
        if (!self.totals.claim()) return;
        self.asked_span = span;
        self.next_totals_ms = now_ms + TOTALS_INTERVAL_MS;
        startTotals(self, allocator, token, span) catch |err| {
            slog.err("Failed to fetch Eve Stars' kills and jumps: {}", .{err});
            self.totals.finish();
        };
    }

    /// Per tick while NPC delta shows and waits for its hour before: asks every NPC_HOURS_INTERVAL_MS.
    pub fn pollNpcHours(self: *ActivityFeed, allocator: std.mem.Allocator, token: []const u8, now_ms: u64) void {
        if (now_ms < self.next_npc_hours_ms or !self.npc_hours.claim()) return;
        self.next_npc_hours_ms = now_ms + NPC_HOURS_INTERVAL_MS;
        startNpcHours(self, allocator, token) catch |err| {
            slog.err("Failed to fetch Eve Stars' NPC kills by the hour: {}", .{err});
            self.npc_hours.finish();
        };
    }

    /// The caller destroys it.
    pub fn takeTotals(self: *ActivityFeed) ?*Activity {
        return self.totals.take();
    }

    /// The caller destroys it.
    pub fn takeNpcHours(self: *ActivityFeed) ?*NpcHours {
        return self.npc_hours.take();
    }
};

fn startTotals(feed: *ActivityFeed, allocator: std.mem.Allocator, token: []const u8, span: TrafficSpan) !void {
    const url = try activity_mod.totalsUrl(allocator, activity_mod.spanHours(span));
    errdefer allocator.free(url);
    const header = try evestars.authorization(allocator, token);
    errdefer allocator.free(header);
    try detached.spawn(totalsThread, .{ feed, allocator, url, header, span });
}

fn startNpcHours(feed: *ActivityFeed, allocator: std.mem.Allocator, token: []const u8) !void {
    const urls = try activity_mod.npcHoursUrls(allocator);
    errdefer for (urls) |url| allocator.free(url);
    const header = try evestars.authorization(allocator, token);
    errdefer allocator.free(header);
    try detached.spawn(npcHoursThread, .{ feed, allocator, urls, header });
}

/// The sums' thread, which owns `url` and `header`; touches nothing of the main thread's but the feed's totals job and the allocator.
fn totalsThread(feed: *ActivityFeed, allocator: std.mem.Allocator, url: []u8, header: []u8, span: TrafficSpan) void {
    defer feed.totals.finish();
    defer allocator.free(url);
    defer allocator.free(header);
    // Logs its own failures.
    const body = fetch(allocator, url, header) catch {
        feed.totals.fail();
        return;
    };
    defer allocator.free(body);
    const activity = Activity.create(allocator, span, body) catch |err| {
        slog.warn("Failed to read Eve Stars' kills and jumps: {}", .{err});
        feed.totals.fail();
        return;
    };
    if (feed.totals.deliver(activity)) |unclaimed| unclaimed.destroy();
}

/// The NPC hours' thread, which owns `urls` and `header`; touches nothing of the main thread's but the feed's NPC hours job and the allocator.
fn npcHoursThread(feed: *ActivityFeed, allocator: std.mem.Allocator, urls: [2][]u8, header: []u8) void {
    defer feed.npc_hours.finish();
    defer for (urls) |url| allocator.free(url);
    defer allocator.free(header);
    // Logs its own failures.
    const last_hour = fetch(allocator, urls[0], header) catch return;
    defer allocator.free(last_hour);
    // Logs its own failures.
    const two_hours = fetch(allocator, urls[1], header) catch return;
    defer allocator.free(two_hours);
    const created = NpcHours.create(allocator, last_hour, two_hours) catch |err| {
        slog.warn("Failed to read Eve Stars' NPC kills by the hour: {}", .{err});
        return;
    };
    const hours = created orelse {
        slog.debug("Eve Stars doesn't keep two matching hours of NPC kills yet", .{});
        return;
    };
    if (feed.npc_hours.deliver(hours)) |unclaimed| unclaimed.destroy();
}

/// The answer's body, which the caller frees; logs its own failures, a status other than 200 included.
fn fetch(allocator: std.mem.Allocator, url: []const u8, header: []const u8) ![]u8 {
    var session = try http_client.Session.init();
    defer session.deinit();
    const headers = [_]http_client.Header{.{ .name = "Authorization", .value = header }};
    return session.fetch(allocator, url, .{ .extra_headers = &headers });
}
