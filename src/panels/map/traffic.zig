//! The Map Panel's Eve Stars traffic: kills and jumps summed over the picked span, and NPC kills' hour before for the delta; main thread only.
const std = @import("std");
const types = @import("../../config/types.zig");
const activity_mod = @import("../../map/activity.zig");
const activity_feed = @import("../../map/activity_feed.zig");
const stats_mod = @import("../../map/stats.zig");

const Activity = activity_mod.Activity;
const Snapshot = stats_mod.Snapshot;
const TrafficSpan = types.TrafficSpan;

/// Lives as long as the app, like its feed.
pub const Traffic = struct {
    feed: activity_feed.ActivityFeed = .{},
    /// The newest sums for each span, kept so going back to one shows it at once; owned, destroyed in deinit.
    activities: std.EnumArray(TrafficSpan, ?*Activity) = .initFill(null),
    /// Raised by anything shown changing, for the render signature.
    revision: u32 = 0,

    /// Only once the feed's threads have finished.
    pub fn deinit(self: *Traffic) void {
        self.feed.deinit();
        for (&self.activities.values) |*slot| {
            if (slot.*) |activity| activity.destroy();
            slot.* = null;
        }
    }

    pub fn isWaiting(self: *const Traffic) bool {
        return self.feed.isBusy();
    }

    /// Takes any replies, giving `stats` its NPC delta's hour before when Eve Stars' last hour is the one it holds.
    pub fn poll(self: *Traffic, stats: ?*Snapshot) void {
        if (self.feed.takeTotals()) |fresh| {
            const slot = self.activities.getPtr(fresh.span);
            if (slot.*) |old| old.destroy();
            slot.* = fresh;
            self.revision +%= 1;
        }
        const hours = self.feed.takeNpcHours() orelse return;
        defer hours.destroy();
        const snapshot = stats orelse return;
        if (snapshot.applyHourBefore(hours.last_hour, hours.hour_before)) self.revision +%= 1;
    }

    /// Per tick while the map shows `span`'s figures.
    pub fn refreshTotals(self: *Traffic, allocator: std.mem.Allocator, token: []const u8, span: TrafficSpan, now_ms: u64) void {
        self.feed.pollTotals(allocator, token, span, now_ms);
    }

    /// Per tick while NPC delta shows and `stats` hasn't its hour before.
    pub fn refreshNpcHours(self: *Traffic, allocator: std.mem.Allocator, token: []const u8, stats: *const Snapshot, now_ms: u64) void {
        if (!stats.has_kills or stats.has_npc_delta) return;
        self.feed.pollNpcHours(allocator, token, now_ms);
    }

    /// The sums, once they've come for `span`.
    pub fn activityFor(self: *const Traffic, span: TrafficSpan) ?*const Activity {
        return self.activities.get(span);
    }
};
