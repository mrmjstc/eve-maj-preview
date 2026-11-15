//! Eve Stars' sums of each system's kills and jumps over the last hours, and its NPC kills an hour at a time; no I/O.
const std = @import("std");
const types = @import("../config/types.zig");
const universe = @import("universe.zig");
const stats = @import("stats.zig");
const evestars = @import("evestars.zig");

const SystemStats = stats.SystemStats;
const TrafficSpan = types.TrafficSpan;

/// The newest hour and the one before, which NPC delta compares.
const NPC_HOURS = 2;

/// Eve Stars' sums over a span, by SystemIndex.
pub const Activity = struct {
    allocator: std.mem.Allocator,
    /// By SystemIndex; owned; npc_delta and holder stay unset, as those come from ESI.
    systems: []SystemStats,
    span: TrafficSpan,
    /// Fewer than the span's where Eve Stars hasn't kept that many hours yet.
    kill_hours: u32,
    /// 0 past the week Eve Stars keeps jumps for.
    jump_hours: u32,

    /// `body` is GET /activity's answer for every system; a system the map doesn't have is skipped; caller destroys.
    pub fn create(allocator: std.mem.Allocator, span: TrafficSpan, body: []const u8) !*Activity {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const answer = try parseAnswer(arena.allocator(), body);

        const activity = try allocator.create(Activity);
        errdefer allocator.destroy(activity);
        const systems = try allocator.alloc(SystemStats, universe.SYSTEM_COUNT);
        @memset(systems, .{});
        activity.* = .{
            .allocator = allocator,
            .systems = systems,
            .span = span,
            .kill_hours = answer.kills.hours,
            .jump_hours = if (answer.jumps) |jumps| jumps.hours else 0,
        };
        for (answer.systems) |row| {
            const system = universe.findSystemById(row.id) orelse continue;
            systems[system] = .{ .ship_kills = row.shipKills, .pod_kills = row.podKills, .npc_kills = row.npcKills, .jumps = row.jumps orelse 0 };
        }
        return activity;
    }

    pub fn destroy(self: *Activity) void {
        const allocator = self.allocator;
        allocator.free(self.systems);
        allocator.destroy(self);
    }
};

/// Each system's NPC kills in the newest hour Eve Stars keeps and the hour before, for NPC delta before ESI has shown two.
pub const NpcHours = struct {
    allocator: std.mem.Allocator,
    /// By SystemIndex; owned.
    last_hour: []u32,
    /// By SystemIndex; owned.
    hour_before: []u32,

    /// `last_hour_body` and `two_hours_body` are GET /activity's answers for the last one and two hours; null when Eve Stars hasn't kept two, or the answers end at different hours; caller destroys.
    pub fn create(allocator: std.mem.Allocator, last_hour_body: []const u8, two_hours_body: []const u8) !?*NpcHours {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const last_hour = try parseAnswer(arena.allocator(), last_hour_body);
        const two_hours = try parseAnswer(arena.allocator(), two_hours_body);
        if (last_hour.kills.hours != 1 or two_hours.kills.hours != NPC_HOURS) return null;
        const last_end = last_hour.kills.to orelse return null;
        const two_end = two_hours.kills.to orelse return null;
        if (!std.mem.eql(u8, last_end, two_end)) return null;

        const hours = try allocator.create(NpcHours);
        errdefer allocator.destroy(hours);
        const last = try allocator.alloc(u32, universe.SYSTEM_COUNT);
        errdefer allocator.free(last);
        const before = try allocator.alloc(u32, universe.SYSTEM_COUNT);
        @memset(last, 0);
        @memset(before, 0);
        hours.* = .{ .allocator = allocator, .last_hour = last, .hour_before = before };
        for (last_hour.systems) |row| {
            const system = universe.findSystemById(row.id) orelse continue;
            last[system] = row.npcKills;
        }
        for (two_hours.systems) |row| {
            const system = universe.findSystemById(row.id) orelse continue;
            before[system] = row.npcKills -| last[system];
        }
        return hours;
    }

    pub fn destroy(self: *NpcHours) void {
        const allocator = self.allocator;
        allocator.free(self.last_hour);
        allocator.free(self.hour_before);
        allocator.destroy(self);
    }
};

const SpanRow = struct { hours: u32 = 0, to: ?[]const u8 = null };
const SystemRow = struct { id: u32 = 0, shipKills: u32 = 0, podKills: u32 = 0, npcKills: u32 = 0, jumps: ?u32 = null };
const Answer = struct { kills: SpanRow = .{}, jumps: ?SpanRow = null, systems: []const SystemRow = &.{} };

pub fn spanHours(span: TrafficSpan) u32 {
    return switch (span) {
        .Hour => 1,
        .Day => 24,
        .Week => 7 * 24,
    };
}

/// Every system with anything in the last `hours`, totals only; caller frees.
pub fn totalsUrl(allocator: std.mem.Allocator, hours: u32) ![]u8 {
    return allocator.print(evestars.ACTIVITY_URL ++ "?hours={d}", .{hours});
}

/// The two NpcHours.create reads, the last hour's first; caller frees each.
pub fn npcHoursUrls(allocator: std.mem.Allocator) ![2][]u8 {
    const last_hour = try totalsUrl(allocator, 1);
    errdefer allocator.free(last_hour);
    return .{ last_hour, try totalsUrl(allocator, NPC_HOURS) };
}

/// Borrows from `arena`.
fn parseAnswer(arena: std.mem.Allocator, body: []const u8) !Answer {
    return std.json.parseFromSliceLeaky(Answer, arena, body, .{ .ignore_unknown_fields = true });
}

const testing = std.testing;

test "Activity sums each system it knows, and says how many hours each figure covers" {
    const activity = try Activity.create(testing.allocator, .Day,
        \\{"hours":24,"in":null,
        \\"kills":{"hours":1,"from":"2026-11-14T22:07:13.000Z","to":"2026-11-14T23:07:13.000Z"},
        \\"jumps":{"hours":1,"from":"2026-11-14T21:50:20.000Z","to":"2026-11-14T22:50:20.000Z"},
        \\"systems":[{"id":30002813,"name":"Tama","security":0.3,"shipKills":5,"podKills":1,"npcKills":13,"jumps":265},
        \\{"id":30000142,"name":"Jita","security":0.9,"shipKills":103,"podKills":40,"npcKills":188,"jumps":2703},
        \\{"id":31000005,"name":"Thera","shipKills":2,"podKills":0,"npcKills":0,"jumps":0}]}
    );
    defer activity.destroy();
    try testing.expectEqual(@as(u32, 1), activity.kill_hours);
    try testing.expectEqual(@as(u32, 1), activity.jump_hours);
    const jita = activity.systems[universe.findSystem("Jita").?];
    try testing.expectEqual(@as(u32, 103), jita.ship_kills);
    try testing.expectEqual(@as(u32, 40), jita.pod_kills);
    try testing.expectEqual(@as(u32, 2703), jita.jumps);
    try testing.expectEqual(@as(u32, 0), activity.systems[universe.findSystem("Amarr").?].ship_kills);
}

test "past a week Activity keeps the kills though Eve Stars has no jumps" {
    const activity = try Activity.create(testing.allocator, .Week, "{\"kills\":{\"hours\":200},\"jumps\":null,\"systems\":[{\"id\":30000142,\"shipKills\":9,\"jumps\":null}]}");
    defer activity.destroy();
    try testing.expectEqual(@as(u32, 0), activity.jump_hours);
    try testing.expectEqual(@as(u32, 9), activity.systems[universe.findSystem("Jita").?].ship_kills);
    try testing.expectEqual(@as(u32, 0), activity.systems[universe.findSystem("Jita").?].jumps);
}

test "NpcHours takes the hour before from the two hours' sum" {
    const hours = (try NpcHours.create(testing.allocator,
        \\{"kills":{"hours":1,"to":"2026-11-15T10:00:00.000Z"},"systems":[{"id":30000142,"npcKills":40}]}
    ,
        \\{"kills":{"hours":2,"to":"2026-11-15T10:00:00.000Z"},"systems":[{"id":30000142,"npcKills":65},{"id":30002187,"npcKills":3}]}
    )).?;
    defer hours.destroy();
    const jita = universe.findSystem("Jita").?;
    try testing.expectEqual(@as(u32, 40), hours.last_hour[jita]);
    try testing.expectEqual(@as(u32, 25), hours.hour_before[jita]);
    try testing.expectEqual(@as(u32, 3), hours.hour_before[universe.findSystem("Amarr").?]);
}

test "NpcHours is null until Eve Stars keeps two hours, or while its answers end apart" {
    const one_kept = try NpcHours.create(testing.allocator, "{\"kills\":{\"hours\":1,\"to\":\"a\"}}", "{\"kills\":{\"hours\":1,\"to\":\"a\"}}");
    try testing.expectEqual(@as(?*NpcHours, null), one_kept);
    const apart = try NpcHours.create(testing.allocator, "{\"kills\":{\"hours\":1,\"to\":\"b\"}}", "{\"kills\":{\"hours\":2,\"to\":\"a\"}}");
    try testing.expectEqual(@as(?*NpcHours, null), apart);
}

test "the addresses ask for the hours wanted" {
    const totals = try totalsUrl(testing.allocator, spanHours(.Week));
    defer testing.allocator.free(totals);
    try testing.expectEqualStrings(evestars.ACTIVITY_URL ++ "?hours=168", totals);
    const urls = try npcHoursUrls(testing.allocator);
    defer for (urls) |url| testing.allocator.free(url);
    try testing.expectEqualStrings(evestars.ACTIVITY_URL ++ "?hours=1", urls[0]);
    try testing.expectEqualStrings(evestars.ACTIVITY_URL ++ "?hours=2", urls[1]);
}
