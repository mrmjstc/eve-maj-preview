//! zKillboard's live kills: parsing its R2Z2 files, and the recent kills the map shows with the names they need; no I/O.
const std = @import("std");
const universe = @import("universe.zig");
const campaigns = @import("campaigns.zig");
const fixed_text = @import("../util/fixed_text.zig");

const FixedText = fixed_text.FixedText;
const SystemIndex = universe.SystemIndex;

/// Past an hour of New Eden's kills at a busy time; the oldest go first once full, whatever the lifetime.
pub const MAX_KILLS = 4096;
pub const KILL_URL_FORMAT = "https://zkillboard.com/kill/{d}/";

pub const Kill = struct {
    id: u64,
    system: SystemIndex,
    /// Seconds since 1970, UTC, as the killmail gives it.
    time_seconds: i64,
    /// When it arrived, in ms since boot, for its ripple.
    seen_ms: u64 = 0,
    ship_type_id: u32,
    /// The victim's alliance, else its corporation; 0 for neither.
    victim_id: u32,
    value_isk: f64,
};

const SequenceAnswer = struct { sequence: u64 = 0 };
const VictimRow = struct { ship_type_id: u32 = 0, alliance_id: ?u32 = null, corporation_id: ?u32 = null };
const EsiRow = struct { killmail_id: u64 = 0, solar_system_id: u32 = 0, killmail_time: []const u8 = "", victim: VictimRow = .{} };
const ZkbRow = struct { totalValue: f64 = 0, npc: bool = false };
const KillFile = struct { killmail_id: u64 = 0, esi: EsiRow = .{}, zkb: ZkbRow = .{} };

/// The kills still within their lifetime, oldest first, in a ring.
pub const Kills = struct {
    kills: [MAX_KILLS]Kill = undefined,
    /// Where the oldest is.
    start: usize = 0,
    count: usize = 0,
    /// Raised by each change, for the render signature.
    revision: u32 = 0,

    /// Past MAX_KILLS the oldest goes.
    pub fn add(self: *Kills, kill: Kill) void {
        if (self.count == MAX_KILLS) {
            self.start = (self.start + 1) % MAX_KILLS;
            self.count -= 1;
        }
        self.kills[(self.start + self.count) % MAX_KILLS] = kill;
        self.count += 1;
        self.revision +%= 1;
    }

    /// Drops those older than `lifetime_seconds`.
    pub fn prune(self: *Kills, now_seconds: i64, lifetime_seconds: i64) void {
        while (self.count > 0 and now_seconds - self.oldest().time_seconds > lifetime_seconds) {
            self.start = (self.start + 1) % MAX_KILLS;
            self.count -= 1;
            self.revision +%= 1;
        }
    }

    /// `index` 0 is the newest; it must be below `count`.
    pub fn fromNewest(self: *const Kills, index: usize) *const Kill {
        return &self.kills[(self.start + self.count - 1 - index) % MAX_KILLS];
    }

    fn oldest(self: *const Kills) *const Kill {
        return &self.kills[self.start];
    }
};

/// Ship types', alliances' and corporations' names, as ESI gives them; main thread only.
pub const Names = struct {
    /// Each value owned; freed in deinit.
    map: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,

    pub fn deinit(self: *Names, allocator: std.mem.Allocator) void {
        var values = self.map.valueIterator();
        while (values.next()) |name| allocator.free(name.*);
        self.map.deinit(allocator);
    }

    /// Takes ownership of `name`, freeing it on failure or when `id` already has one.
    pub fn put(self: *Names, allocator: std.mem.Allocator, id: u32, name: []const u8) !void {
        errdefer allocator.free(name);
        const entry = try self.map.getOrPut(allocator, id);
        if (entry.found_existing) {
            allocator.free(name);
            return;
        }
        entry.value_ptr.* = name;
    }

    /// Borrows from the map; null while unknown.
    pub fn get(self: *const Names, id: u32) ?[]const u8 {
        return self.map.get(id);
    }
};

/// `body` is sequence.json; the number of the newest file.
pub fn parseSequence(arena: std.mem.Allocator, body: []const u8) !u64 {
    const answer = try std.json.parseFromSliceLeaky(SequenceAnswer, arena, body, .{ .ignore_unknown_fields = true });
    if (answer.sequence == 0) return error.MissingSequence;
    return answer.sequence;
}

/// `body` is one R2Z2 file; null for a kill only NPCs took part in, or one in wormhole space, which the map hasn't.
pub fn parseKill(arena: std.mem.Allocator, body: []const u8) !?Kill {
    const file = try std.json.parseFromSliceLeaky(KillFile, arena, body, .{ .ignore_unknown_fields = true });
    if (file.zkb.npc) return null;
    const system = universe.findSystemById(file.esi.solar_system_id) orelse return null;
    const victim = file.esi.victim;
    return .{
        .id = if (file.killmail_id != 0) file.killmail_id else file.esi.killmail_id,
        .system = system,
        .time_seconds = try campaigns.parseUtcSeconds(file.esi.killmail_time),
        .ship_type_id = victim.ship_type_id,
        .victim_id = victim.alliance_id orelse victim.corporation_id orelse 0,
        .value_isk = file.zkb.totalValue,
    };
}

/// "1.2B", "120M" or "850K" ISK.
pub fn valueText(isk: f64) FixedText {
    if (isk >= 1e9) return .print("{d:.1}B", .{isk / 1e9});
    if (isk >= 1e6) return .print("{d:.0}M", .{isk / 1e6});
    return .print("{d:.0}K", .{isk / 1e3});
}

const testing = std.testing;

const KILL_FILE =
    \\{"killmail_id":139786862,"hash":"98f1","esi":{"attackers":[],"killmail_id":139786862,"killmail_time":"2026-11-09T08:09:50Z","solar_system_id":30000142,"victim":{"alliance_id":1354830081,"character_id":2124818099,"corporation_id":98642382,"damage_taken":496,"items":[],"ship_type_id":11132}},"zkb":{"locationID":50001474,"totalValue":14135.33,"npc":false,"solo":false},"uploaded_at":1794211949,"sequence_id":100463489}
;

test "parseKill reads the system, ship, victim and value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const kill = (try parseKill(arena.allocator(), KILL_FILE)).?;
    try testing.expectEqual(@as(u64, 139786862), kill.id);
    try testing.expectEqual(universe.findSystem("Jita").?, kill.system);
    try testing.expectEqual(try campaigns.parseUtcSeconds("2026-11-09T08:09:50Z"), kill.time_seconds);
    try testing.expectEqual(@as(u32, 11132), kill.ship_type_id);
    try testing.expectEqual(@as(u32, 1354830081), kill.victim_id);
}

test "parseKill leaves out NPC kills and wormhole space" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect(try parseKill(arena.allocator(), "{\"esi\":{\"solar_system_id\":30000142},\"zkb\":{\"npc\":true}}") == null);
    try testing.expect(try parseKill(arena.allocator(), "{\"esi\":{\"solar_system_id\":31000005},\"zkb\":{\"npc\":false}}") == null);
}

test "parseSequence reads the newest file's number" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(u64, 100463490), try parseSequence(arena.allocator(), "{\"sequence\":100463490}"));
    try testing.expectError(error.MissingSequence, parseSequence(arena.allocator(), "{}"));
}

test "the ring keeps the newest kills, and prune drops those past their lifetime" {
    var kills: Kills = .{};
    for (0..MAX_KILLS + 2) |index| kills.add(.{ .id = index, .system = 0, .time_seconds = @intCast(index), .ship_type_id = 0, .victim_id = 0, .value_isk = 0 });
    try testing.expectEqual(@as(usize, MAX_KILLS), kills.count);
    try testing.expectEqual(@as(u64, MAX_KILLS + 1), kills.fromNewest(0).id);
    try testing.expectEqual(@as(u64, 2), kills.fromNewest(MAX_KILLS - 1).id);
    kills.prune(MAX_KILLS + 1, 10);
    try testing.expectEqual(@as(usize, 11), kills.count);
}

test "names keep the first given for an id" {
    var names: Names = .{};
    defer names.deinit(testing.allocator);
    try names.put(testing.allocator, 5, try testing.allocator.dupe(u8, "Rifter"));
    try names.put(testing.allocator, 5, try testing.allocator.dupe(u8, "Other"));
    try testing.expectEqualStrings("Rifter", names.get(5).?);
    try testing.expect(names.get(6) == null);
}

test "valueText shortens ISK" {
    try testing.expectEqualStrings("1.2B", valueText(1.24e9).slice());
    try testing.expectEqualStrings("120M", valueText(120.4e6).slice());
    try testing.expectEqualStrings("14K", valueText(14135.33).slice());
}
