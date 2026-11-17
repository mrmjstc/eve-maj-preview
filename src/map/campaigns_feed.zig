//! Fetches ESI's sov campaigns on their own, fast enough for a running timer's scores, on a background thread, and hands each to the main thread.
const std = @import("std");
const campaigns_mod = @import("campaigns.zig");
const http_client = @import("../util/http_client.zig");
const detached = @import("../util/detached.zig");
const handoff = @import("../util/handoff.zig");
const log = @import("../log.zig");

const Campaigns = campaigns_mod.Campaigns;
const slog = log.Scoped("map");

const CAMPAIGNS_URL = "https://esi.evetech.net/latest/sovereignty/campaigns/?datasource=tranquility";
/// ESI renews the reply every 5 s, and its sovereignty group allows a full reply every 3 s; this spends about a third of that.
const LIVE_INTERVAL_MS: u64 = 10 * std.time.ms_per_s;
const RETRY_INTERVAL_MS: u64 = std.time.ms_per_min;

/// Lives as long as the app, since its thread may outlast the panel's window.
pub const CampaignsFeed = struct {
    /// Main thread only.
    next_fetch_ms: u64 = 0,
    /// Shared with the fetch thread.
    job: handoff.Job(Campaigns) = .{},

    /// After the fetch thread has finished; `allocator` is the one poll was given.
    pub fn deinit(self: *CampaignsFeed, allocator: std.mem.Allocator) void {
        if (self.take()) |campaigns| allocator.destroy(campaigns);
    }

    /// Per tick while a running timer shows: starts a fetch once one is due.
    pub fn poll(self: *CampaignsFeed, allocator: std.mem.Allocator, now_ms: u64) void {
        if (self.job.takeFailure()) self.next_fetch_ms = now_ms + RETRY_INTERVAL_MS;
        if (now_ms < self.next_fetch_ms or !self.job.claim()) return;
        self.next_fetch_ms = now_ms + LIVE_INTERVAL_MS;
        detached.spawn(fetchThread, .{ self, allocator }) catch |err| {
            slog.err("Failed to fetch sov campaigns: {}", .{err});
            self.job.finish();
        };
    }

    /// The caller owns the result, and frees it with the allocator poll was given.
    pub fn take(self: *CampaignsFeed) ?*Campaigns {
        return self.job.take();
    }
};

/// The fetch's thread; touches nothing of the main thread's but the feed's job and the allocator.
fn fetchThread(feed: *CampaignsFeed, allocator: std.mem.Allocator) void {
    defer feed.job.finish();
    const campaigns = fetchCampaigns(allocator) catch |err| {
        slog.warn("Failed to fetch sov campaigns: {}", .{err});
        feed.job.fail();
        return;
    };
    if (feed.job.deliver(campaigns)) |unclaimed| allocator.destroy(unclaimed);
}

/// Caller destroys the result.
fn fetchCampaigns(allocator: std.mem.Allocator) !*Campaigns {
    var session = try http_client.Session.init();
    defer session.deinit();
    const body = try session.fetch(allocator, CAMPAIGNS_URL, .{});
    defer allocator.free(body);
    const campaigns = try allocator.create(Campaigns);
    errdefer allocator.destroy(campaigns);
    campaigns.* = try .parse(allocator, body);
    return campaigns;
}
