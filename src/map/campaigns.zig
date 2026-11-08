//! Sovereignty campaigns: which systems have a sov timer, when it starts and how its scores stand, parsed from ESI's reply; no I/O.
const std = @import("std");
const universe = @import("universe.zig");
const log = @import("../log.zig");

const SystemIndex = universe.SystemIndex;
const slog = log.Scoped("map");

/// Well past the hundred or so ESI lists at a busy time; any beyond it go unshown.
pub const MAX_CAMPAIGNS = 256;

pub const Kind = enum {
    ihub_defense,
    tcu_defense,
    station_defense,
    station_freeport,
    /// One ESI added after this was written.
    other,
};

const Row = struct {
    solar_system_id: u32,
    event_type: []const u8,
    start_time: []const u8,
    defender_id: ?u32 = null,
    defender_score: ?f32 = null,
    attackers_score: ?f32 = null,
};

pub const Campaign = struct {
    system: SystemIndex,
    kind: Kind,
    /// An alliance's ID; 0 when ESI names none.
    defender_id: u32,
    defender_percent: u8,
    attackers_percent: u8,
    /// Seconds since 1970, UTC.
    start_seconds: i64,

    pub fn hasStarted(self: *const Campaign, now_seconds: i64) bool {
        return now_seconds >= self.start_seconds;
    }
};

pub const Campaigns = struct {
    campaigns: [MAX_CAMPAIGNS]Campaign = undefined,
    count: usize = 0,

    /// `body` is /sovereignty/campaigns/'s reply; a campaign with an unreadable start, or in a system with no gates, is skipped.
    pub fn parse(allocator: std.mem.Allocator, body: []const u8) !Campaigns {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const rows = try std.json.parseFromSliceLeaky([]const Row, arena.allocator(), body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });

        var parsed: Campaigns = .{};
        for (rows) |row| {
            if (parsed.count == MAX_CAMPAIGNS) break;
            const system = universe.findSystemById(row.solar_system_id) orelse continue;
            const start_seconds = parseUtcSeconds(row.start_time) catch |err| {
                slog.warn("Failed to read a sov campaign's start '{s}': {}", .{ row.start_time, err });
                continue;
            };
            parsed.campaigns[parsed.count] = .{
                .system = system,
                .kind = std.meta.stringToEnum(Kind, row.event_type) orelse .other,
                .defender_id = row.defender_id orelse 0,
                .defender_percent = percentOf(row.defender_score orelse 0),
                .attackers_percent = percentOf(row.attackers_score orelse 0),
                .start_seconds = start_seconds,
            };
            parsed.count += 1;
        }
        return parsed;
    }

    pub fn slice(self: *const Campaigns) []const Campaign {
        return self.campaigns[0..self.count];
    }

    /// The soonest to start, or the one running, of those in `system`.
    pub fn soonestIn(self: *const Campaigns, system: SystemIndex) ?*const Campaign {
        var soonest: ?*const Campaign = null;
        for (self.slice()) |*campaign| {
            if (campaign.system != system) continue;
            if (soonest == null or campaign.start_seconds < soonest.?.start_seconds) soonest = campaign;
        }
        return soonest;
    }
};

/// "2026-11-09T22:54:09Z", as ESI writes times, to seconds since 1970.
pub fn parseUtcSeconds(text: []const u8) !i64 {
    if (text.len < 19 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':' or text[16] != ':') return error.InvalidTimestamp;
    const year = try std.fmt.parseInt(i64, text[0..4], 10);
    const month = try std.fmt.parseInt(i64, text[5..7], 10);
    const day = try std.fmt.parseInt(i64, text[8..10], 10);
    const hour = try std.fmt.parseInt(i64, text[11..13], 10);
    const minute = try std.fmt.parseInt(i64, text[14..16], 10);
    const second = try std.fmt.parseInt(i64, text[17..19], 10);
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) return error.InvalidTimestamp;
    return daysFromCivil(year, month, day) * std.time.s_per_day + hour * std.time.s_per_hour + minute * std.time.s_per_min + second;
}

/// Days since 1970-01-01 in the proleptic Gregorian calendar, by Howard Hinnant's published algorithm.
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    const day_of_year = @divFloor(153 * (if (month > 2) month - 3 else month + 9) + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

/// ESI gives scores from 0 to 1.
fn percentOf(score: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(score, 0, 1) * 100));
}

const testing = std.testing;

const REPLY =
    \\[{"attackers_score":0.4,"campaign_id":112477,"constellation_id":20000155,"defender_id":99013045,"defender_score":0.6,"event_type":"ihub_defense","solar_system_id":30001057,"start_time":"2026-11-09T22:54:09Z","structure_id":1051368520655},
    \\{"campaign_id":1,"constellation_id":1,"event_type":"station_freeport","solar_system_id":30001057,"start_time":"2026-11-09T20:00:00Z","structure_id":2},
    \\{"campaign_id":2,"constellation_id":1,"event_type":"ihub_defense","solar_system_id":31000005,"start_time":"2026-11-09T20:00:00Z","structure_id":3},
    \\{"campaign_id":3,"constellation_id":1,"event_type":"ihub_defense","solar_system_id":30005151,"start_time":"soon","structure_id":4}]
;
const SYSTEM_ID = 30001057;

test "parse reads each campaign's system, kind, defender, scores and start" {
    const parsed: Campaigns = try .parse(testing.allocator, REPLY);
    try testing.expectEqual(@as(usize, 2), parsed.count);
    const campaign = parsed.campaigns[0];
    try testing.expectEqual(universe.findSystemById(SYSTEM_ID).?, campaign.system);
    try testing.expectEqual(Kind.ihub_defense, campaign.kind);
    try testing.expectEqual(@as(u32, 99013045), campaign.defender_id);
    try testing.expectEqual(@as(u8, 60), campaign.defender_percent);
    try testing.expectEqual(@as(u8, 40), campaign.attackers_percent);
    try testing.expectEqual(try parseUtcSeconds("2026-11-09T22:54:09Z"), campaign.start_seconds);
    try testing.expectEqual(@as(u32, 0), parsed.campaigns[1].defender_id);
}

test "soonestIn picks the campaign starting first in a system" {
    const parsed: Campaigns = try .parse(testing.allocator, REPLY);
    try testing.expectEqual(Kind.station_freeport, parsed.soonestIn(universe.findSystemById(SYSTEM_ID).?).?.kind);
    try testing.expect(parsed.soonestIn(universe.findSystem("Jita").?) == null);
}

test "parse fails on a malformed reply" {
    try testing.expectError(error.SyntaxError, Campaigns.parse(testing.allocator, "[{not json"));
}

test "parseUtcSeconds reads ESI's times" {
    try testing.expectEqual(@as(i64, 0), try parseUtcSeconds("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(i64, 951782400), try parseUtcSeconds("2000-02-29T00:00:00Z"));
    try testing.expectEqual(@as(i64, 1794264849), try parseUtcSeconds("2026-11-09T22:54:09Z"));
    try testing.expectError(error.InvalidTimestamp, parseUtcSeconds("2026-11-09 22:54"));
}
