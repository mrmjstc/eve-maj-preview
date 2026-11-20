//! What the activity trackers last pushed for one thumbnail, and whether each reading is shown.
const std = @import("std");

/// What the trackers last pushed; a null rate has too short a span yet (see activity/tracker.zig).
pub const ActivityStats = struct {
    incoming_dps: ?f32 = null,
    outgoing_dps: ?f32 = null,
    mining_rate: ?f32 = null,
    mining_isk_rate: ?f32 = null,
    bounty_isk_rate: ?f32 = null,
    cpu_percent: f32 = 0.0,
    ram_mb: f32 = 0.0,
    vram_mb: f32 = 0.0,
    /// Null until the server's first reply, and after a timeout.
    ping_ms: ?u32 = null,

    /// Whether the tracker has reported, so its first report counts as a change.
    has_dps: bool = false,
    has_mining: bool = false,
    has_bounty: bool = false,
    has_resources: bool = false,
    /// VRAM can stay unavailable once CPU and RAM are known.
    has_vram: bool = false,
    /// Connected to a game server, so there's a ping to show.
    has_ping: bool = false,

    /// Null, so hidden, while the rate is still being measured or is zero.
    pub fn shownIncoming(self: *const ActivityStats) ?f32 {
        return shown(self.incoming_dps);
    }

    pub fn shownOutgoing(self: *const ActivityStats) ?f32 {
        return shown(self.outgoing_dps);
    }

    pub fn shownMining(self: *const ActivityStats) ?f32 {
        return shown(self.mining_rate);
    }

    /// Only while the mined volume shows too.
    pub fn shownMiningIsk(self: *const ActivityStats) ?f32 {
        if (self.shownMining() == null) return null;
        return shown(self.mining_isk_rate);
    }

    pub fn shownBounty(self: *const ActivityStats) ?f32 {
        return shown(self.bounty_isk_rate);
    }

    fn shown(rate: ?f32) ?f32 {
        const value = rate orelse return null;
        return if (value > 0) value else null;
    }

    /// Each setter returns whether anything shown changed.
    pub fn setDps(self: *ActivityStats, incoming: ?f32, outgoing: ?f32) bool {
        const changed = !self.has_dps or self.incoming_dps != incoming or self.outgoing_dps != outgoing;
        self.has_dps = true;
        self.incoming_dps = incoming;
        self.outgoing_dps = outgoing;
        return changed;
    }

    pub fn setMining(self: *ActivityStats, rate: ?f32, isk_rate: ?f32) bool {
        const changed = !self.has_mining or self.mining_rate != rate or self.mining_isk_rate != isk_rate;
        self.has_mining = true;
        self.mining_rate = rate;
        self.mining_isk_rate = isk_rate;
        return changed;
    }

    pub fn setBounty(self: *ActivityStats, isk_rate: ?f32) bool {
        const changed = !self.has_bounty or self.bounty_isk_rate != isk_rate;
        self.has_bounty = true;
        self.bounty_isk_rate = isk_rate;
        return changed;
    }

    /// Back to never heard from the combat, mining and bounty trackers, keeping resource usage and ping.
    pub fn clearLogReadings(self: *ActivityStats) bool {
        const had_any = self.has_dps or self.has_mining or self.has_bounty;
        self.* = .{
            .cpu_percent = self.cpu_percent,
            .ram_mb = self.ram_mb,
            .vram_mb = self.vram_mb,
            .has_resources = self.has_resources,
            .has_vram = self.has_vram,
            .ping_ms = self.ping_ms,
            .has_ping = self.has_ping,
        };
        return had_any;
    }

    pub fn setResources(self: *ActivityStats, cpu_percent: f32, ram_mb: f32, vram_mb: f32, has_vram: bool) bool {
        const changed = !self.has_resources or self.cpu_percent != cpu_percent or self.ram_mb != ram_mb or
            self.vram_mb != vram_mb or self.has_vram != has_vram;
        self.has_resources = true;
        self.cpu_percent = cpu_percent;
        self.ram_mb = ram_mb;
        self.vram_mb = vram_mb;
        self.has_vram = has_vram;
        return changed;
    }

    pub fn setPing(self: *ActivityStats, is_connected: bool, ping_ms: ?u32) bool {
        const changed = self.has_ping != is_connected or self.ping_ms != ping_ms;
        self.has_ping = is_connected;
        self.ping_ms = ping_ms;
        return changed;
    }
};

const testing = std.testing;

test "a stat never reported shows nothing" {
    const stats: ActivityStats = .{};
    try testing.expectEqual(@as(?f32, null), stats.shownIncoming());
    try testing.expectEqual(@as(?f32, null), stats.shownOutgoing());
    try testing.expectEqual(@as(?f32, null), stats.shownMining());
    try testing.expectEqual(@as(?f32, null), stats.shownBounty());
}

test "a reported rate hides while still being measured and at zero, and shows above it" {
    var stats: ActivityStats = .{};
    _ = stats.setDps(null, 0);
    try testing.expectEqual(@as(?f32, null), stats.shownIncoming());
    try testing.expectEqual(@as(?f32, null), stats.shownOutgoing());
    _ = stats.setDps(0, 12.5);
    try testing.expectEqual(@as(?f32, null), stats.shownIncoming());
    try testing.expectEqual(@as(?f32, 12.5), stats.shownOutgoing());
    _ = stats.setBounty(null);
    try testing.expectEqual(@as(?f32, null), stats.shownBounty());
    _ = stats.setBounty(0);
    try testing.expectEqual(@as(?f32, null), stats.shownBounty());
}

test "mining ISK shows only with a measured volume beside it" {
    var stats: ActivityStats = .{};
    _ = stats.setMining(null, 100);
    try testing.expectEqual(@as(?f32, null), stats.shownMiningIsk());
    _ = stats.setMining(4, null);
    try testing.expectEqual(@as(?f32, 4), stats.shownMining());
    try testing.expectEqual(@as(?f32, null), stats.shownMiningIsk());
    _ = stats.setMining(4, 100);
    try testing.expectEqual(@as(?f32, 100), stats.shownMiningIsk());
}

test "a setter reports a change on its first report, and then only when a value changes" {
    var stats: ActivityStats = .{};
    try testing.expect(stats.setDps(null, null));
    try testing.expect(!stats.setDps(null, null));
    try testing.expect(stats.setDps(10, null));
    try testing.expect(stats.setMining(null, null));
    try testing.expect(!stats.setMining(null, null));
    try testing.expect(stats.setMining(null, 50));
    try testing.expect(stats.setBounty(null));
    try testing.expect(!stats.setBounty(null));
}

test "resources count as changed when VRAM becomes available" {
    var stats: ActivityStats = .{};
    try testing.expect(stats.setResources(5, 1024, 0, false));
    try testing.expect(!stats.setResources(5, 1024, 0, false));
    try testing.expect(stats.setResources(5, 1024, 0, true));
}

test "ping changes only when the connection or the reading does" {
    var stats: ActivityStats = .{};
    try testing.expect(!stats.setPing(false, null));
    try testing.expect(stats.setPing(true, null));
    try testing.expect(stats.setPing(true, 30));
    try testing.expect(!stats.setPing(true, 30));
    try testing.expect(stats.setPing(false, null));
}

test "clearLogReadings forgets combat, mining and bounty but keeps resources and ping" {
    var stats: ActivityStats = .{};
    _ = stats.setDps(10, 20);
    _ = stats.setMining(3, 900);
    _ = stats.setBounty(1000);
    _ = stats.setResources(5, 1024, 256, true);
    _ = stats.setPing(true, 30);

    try testing.expect(stats.clearLogReadings());
    try testing.expect(!stats.has_dps and !stats.has_mining and !stats.has_bounty);
    try testing.expectEqual(@as(?f32, null), stats.incoming_dps);
    try testing.expect(stats.has_resources and stats.has_vram);
    try testing.expectEqual(@as(f32, 1024), stats.ram_mb);
    try testing.expect(stats.has_ping);
    try testing.expectEqual(@as(?u32, 30), stats.ping_ms);
    try testing.expect(!stats.clearLogReadings());
}
