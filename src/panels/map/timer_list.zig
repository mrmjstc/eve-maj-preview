//! The sov timer card's list: the campaigns in the regions shown, soonest first; no I/O.
const std = @import("std");
const campaigns_mod = @import("../../map/campaigns.zig");
const layout = @import("../../map/layout.zig");
const universe = @import("../../map/universe.zig");

const Campaign = campaigns_mod.Campaign;
const Campaigns = campaigns_mod.Campaigns;
const Regions = layout.Regions;
const SystemIndex = universe.SystemIndex;

pub const MAX_ENTRIES = campaigns_mod.MAX_CAMPAIGNS;

pub const Entry = struct {
    /// Its place in the Campaigns it was built from.
    index: u16,
    system: SystemIndex,
};

/// `buffer` holds what's returned.
pub fn build(campaigns: *const Campaigns, regions: Regions, buffer: *[MAX_ENTRIES]Entry) []const Entry {
    var count: usize = 0;
    for (campaigns.slice(), 0..) |campaign, index| {
        if (!regions.contains(universe.systemInfo(campaign.system).region)) continue;
        buffer[count] = .{ .index = @intCast(index), .system = campaign.system };
        count += 1;
    }
    std.mem.sort(Entry, buffer[0..count], campaigns, comesFirst);
    return buffer[0..count];
}

/// By start, then system name, so two at once keep their order.
fn comesFirst(campaigns: *const Campaigns, first: Entry, second: Entry) bool {
    const first_campaign = &campaigns.campaigns[first.index];
    const second_campaign = &campaigns.campaigns[second.index];
    if (first_campaign.start_seconds != second_campaign.start_seconds) return first_campaign.start_seconds < second_campaign.start_seconds;
    return std.mem.lessThan(u8, universe.systemName(first_campaign.system), universe.systemName(second_campaign.system));
}

const testing = std.testing;

test "build keeps the shown regions' campaigns, soonest first" {
    const jita = universe.findSystem("Jita").?;
    const perimeter = universe.findSystem("Perimeter").?;
    const amarr = universe.findSystem("Amarr").?;
    var campaigns: Campaigns = .{};
    const rows = [_]Campaign{
        .{ .system = jita, .kind = .tcu_defense, .defender_id = 0, .defender_percent = 60, .attackers_percent = 40, .start_seconds = 300 },
        .{ .system = amarr, .kind = .tcu_defense, .defender_id = 0, .defender_percent = 60, .attackers_percent = 40, .start_seconds = 100 },
        .{ .system = perimeter, .kind = .ihub_defense, .defender_id = 0, .defender_percent = 60, .attackers_percent = 40, .start_seconds = 200 },
    };
    @memcpy(campaigns.campaigns[0..rows.len], &rows);
    campaigns.count = rows.len;
    var buffer: [MAX_ENTRIES]Entry = undefined;
    const entries = build(&campaigns, .one(universe.systemInfo(jita).region), &buffer);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(Entry{ .index = 2, .system = perimeter }, entries[0]);
    try testing.expectEqual(Entry{ .index = 0, .system = jita }, entries[1]);
}
