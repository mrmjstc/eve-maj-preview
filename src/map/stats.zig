//! A snapshot of ESI's public figures, faction warfare, incursions and sov campaigns and EVE-Scout's storms and Thera and Turnur connections, parsed from their JSON replies; no I/O.
const std = @import("std");
const universe = @import("universe.zig");
const campaigns_mod = @import("campaigns.zig");
const incursions_mod = @import("incursions.zig");
const storms_mod = @import("storms.zig");
const wormholes_mod = @import("wormholes.zig");
const faction_warfare = @import("faction_warfare.zig");
const log = @import("../log.zig");

const SystemIndex = universe.SystemIndex;
const slog = log.Scoped("map");

/// In SystemStats.holder: nobody holds it.
pub const NO_HOLDER = std.math.maxInt(u16);

/// Each count covers ESI's last hour.
pub const SystemStats = struct {
    ship_kills: u16 = 0,
    pod_kills: u16 = 0,
    npc_kills: u16 = 0,
    /// npc_kills less the hour before's; 0 until Snapshot.has_npc_delta.
    npc_delta: i32 = 0,
    jumps: u16 = 0,
    /// Into Snapshot.holder_ids.
    holder: u16 = NO_HOLDER,
};

const KillRow = struct { system_id: u32, ship_kills: u32 = 0, pod_kills: u32 = 0, npc_kills: u32 = 0 };
const JumpRow = struct { system_id: u32, ship_jumps: u32 = 0 };
const SovereigntyRow = struct { system_id: u32, alliance_id: ?u32 = null, faction_id: ?u32 = null };
const NameRow = struct { id: u32, name: []const u8 };

/// Filled by the fetch thread, then the main thread's once it's handed over.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    /// By SystemIndex; owned.
    systems: []SystemStats,
    /// By SystemIndex; owned.
    warfare: []faction_warfare.System,
    /// Who holds systems, as ESI names them, then any campaign's defender holding none shown; owned.
    holder_ids: std.ArrayList(u32) = .empty,
    /// By place in holder_ids, each owned; empty until applyNames finds it.
    holder_names: std.ArrayList([]const u8) = .empty,
    storms: storms_mod.Storms = .{},
    incursions: incursions_mod.Incursions = .{},
    campaigns: campaigns_mod.Campaigns = .{},
    wormholes: wormholes_mod.Connections = .{},
    has_kills: bool = false,
    has_jumps: bool = false,
    has_sovereignty: bool = false,
    has_storms: bool = false,
    has_incursions: bool = false,
    has_campaigns: bool = false,
    /// Set once either hub's connections arrived.
    has_wormholes: bool = false,
    has_warfare: bool = false,
    /// Set once two hours' NPC kills were seen; see carryNpcDelta.
    has_npc_delta: bool = false,
    /// Raised each time live campaigns change the scores, for the render signature.
    campaigns_revision: u32 = 0,
    /// When it was fetched, in ms since boot.
    fetched_ms: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !Snapshot {
        const systems = try allocator.alloc(SystemStats, universe.SYSTEM_COUNT);
        errdefer allocator.free(systems);
        @memset(systems, .{});
        const warfare = try allocator.alloc(faction_warfare.System, universe.SYSTEM_COUNT);
        @memset(warfare, .{});
        return .{ .allocator = allocator, .systems = systems, .warfare = warfare };
    }

    pub fn deinit(self: *Snapshot) void {
        for (self.holder_names.items) |name| self.allocator.free(name);
        self.holder_names.deinit(self.allocator);
        self.holder_ids.deinit(self.allocator);
        self.allocator.free(self.systems);
        self.allocator.free(self.warfare);
    }

    /// Whether any of its figures arrived.
    pub fn hasAnything(self: *const Snapshot) bool {
        return self.has_kills or self.has_jumps or self.has_sovereignty or self.has_storms or self.has_incursions or self.has_campaigns or self.has_wormholes or self.has_warfare;
    }

    /// `body` is /incursions/'s reply.
    pub fn applyIncursions(self: *Snapshot, body: []const u8) !void {
        self.incursions = try .parse(self.allocator, body);
        self.has_incursions = true;
    }

    /// `body` is /sovereignty/campaigns/'s reply; after applySovereignty, so each defender joins holder_ids to be named.
    pub fn applyCampaigns(self: *Snapshot, body: []const u8) !void {
        self.campaigns = try .parse(self.allocator, body);
        for (self.campaigns.slice()) |campaign| {
            if (campaign.defender_id != 0) _ = try self.holderOf(campaign.defender_id);
        }
        self.has_campaigns = true;
    }

    /// Campaigns fetched between snapshots, for a running timer's scores; a defender new since the snapshot stays unnamed until the next.
    pub fn applyLiveCampaigns(self: *Snapshot, fresh: *const campaigns_mod.Campaigns) void {
        if (self.has_campaigns and sameCampaigns(&self.campaigns, fresh)) return;
        self.campaigns = fresh.*;
        self.has_campaigns = true;
        self.campaigns_revision +%= 1;
    }

    /// `body` is /fw/systems/'s reply.
    pub fn applyWarfare(self: *Snapshot, body: []const u8) !void {
        try faction_warfare.apply(self.allocator, body, self.warfare);
        self.has_warfare = true;
    }

    /// `body` is EVE-Scout's signatures reply for Thera.
    pub fn applyThera(self: *Snapshot, body: []const u8) !void {
        try self.wormholes.add(self.allocator, body, .thera);
        self.has_wormholes = true;
    }

    /// `body` is EVE-Scout's signatures reply for Turnur.
    pub fn applyTurnur(self: *Snapshot, body: []const u8) !void {
        try self.wormholes.add(self.allocator, body, .turnur);
        self.has_wormholes = true;
    }

    /// `body` is EVE-Scout's observations reply.
    pub fn applyStorms(self: *Snapshot, body: []const u8) !void {
        self.storms = try .parse(self.allocator, body);
        self.has_storms = true;
    }

    /// `body` is /universe/system_kills/'s reply; rows for wormhole systems are skipped.
    pub fn applyKills(self: *Snapshot, body: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const rows = try parseRows(KillRow, arena.allocator(), body);
        for (rows) |row| {
            const stats = self.statsOf(row.system_id) orelse continue;
            stats.ship_kills = capped(row.ship_kills);
            stats.pod_kills = capped(row.pod_kills);
            stats.npc_kills = capped(row.npc_kills);
        }
        self.has_kills = true;
    }

    /// `older` is the snapshot this replaces: within the same hour its change carries over, and a new hour's is measured against it.
    pub fn carryNpcDelta(self: *Snapshot, older: *const Snapshot) void {
        if (!self.has_kills or !older.has_kills) return;
        var is_same_hour = true;
        for (self.systems, older.systems) |stats, old| {
            if (stats.npc_kills == old.npc_kills) continue;
            is_same_hour = false;
            break;
        }
        if (is_same_hour) {
            for (self.systems, older.systems) |*stats, old| stats.npc_delta = old.npc_delta;
            self.has_npc_delta = older.has_npc_delta;
            return;
        }
        for (self.systems, older.systems) |*stats, old| stats.npc_delta = @as(i32, stats.npc_kills) - old.npc_kills;
        self.has_npc_delta = true;
    }

    /// `body` is /universe/system_jumps/'s reply.
    pub fn applyJumps(self: *Snapshot, body: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const rows = try parseRows(JumpRow, arena.allocator(), body);
        for (rows) |row| {
            const stats = self.statsOf(row.system_id) orelse continue;
            stats.jumps = capped(row.ship_jumps);
        }
        self.has_jumps = true;
    }

    /// `body` is /sovereignty/map/'s reply; an alliance wins over the faction it fights for.
    pub fn applySovereignty(self: *Snapshot, body: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const rows = try parseRows(SovereigntyRow, arena.allocator(), body);

        var known: std.AutoHashMap(u32, u16) = .init(arena.allocator());
        for (rows) |row| {
            const holder_id = row.alliance_id orelse row.faction_id orelse continue;
            const stats = self.statsOf(row.system_id) orelse continue;
            const entry = try known.getOrPut(holder_id);
            if (!entry.found_existing) entry.value_ptr.* = try self.holderOf(holder_id);
            stats.holder = entry.value_ptr.*;
        }
        self.has_sovereignty = true;
    }

    /// `id`'s place in holder_ids, added there unless it already is; searched linearly, so applySovereignty keeps its own map.
    fn holderOf(self: *Snapshot, id: u32) !u16 {
        if (std.mem.indexOfScalar(u32, self.holder_ids.items, id)) |index| return @intCast(index);
        try self.holder_ids.ensureUnusedCapacity(self.allocator, 1);
        try self.holder_names.append(self.allocator, "");
        self.holder_ids.appendAssumeCapacity(id);
        return @intCast(self.holder_ids.items.len - 1);
    }

    /// Borrows from the snapshot; null while unknown.
    pub fn allianceName(self: *const Snapshot, id: u32) ?[]const u8 {
        const index = std.mem.indexOfScalar(u32, self.holder_ids.items, id) orelse return null;
        const name = self.holder_names.items[index];
        return if (name.len > 0) name else null;
    }

    /// `body` is /universe/names/'s reply for holder_ids.
    pub fn applyNames(self: *Snapshot, body: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const rows = try parseRows(NameRow, arena.allocator(), body);
        for (rows) |row| {
            const index = std.mem.indexOfScalar(u32, self.holder_ids.items, row.id) orelse continue;
            if (self.holder_names.items[index].len > 0) continue;
            self.holder_names.items[index] = try self.allocator.dupe(u8, row.name);
        }
    }

    /// Borrows from the snapshot; null while unknown.
    pub fn holderName(self: *const Snapshot, system: SystemIndex) ?[]const u8 {
        const holder = self.systems[system].holder;
        if (holder == NO_HOLDER) return null;
        const name = self.holder_names.items[holder];
        return if (name.len > 0) name else null;
    }

    fn statsOf(self: *Snapshot, system_id: u32) ?*SystemStats {
        const system = universe.findSystemById(system_id) orelse return null;
        return &self.systems[system];
    }
};

/// The JSON array of ids to ask /universe/names/ about, in `arena`.
pub fn namesRequest(arena: std.mem.Allocator, holder_ids: []const u32) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, holder_ids, .{});
}

fn parseRows(comptime Row: type, arena: std.mem.Allocator, body: []const u8) ![]const Row {
    return std.json.parseFromSliceLeaky([]const Row, arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
        slog.warn("Failed to parse an ESI reply: {}", .{err});
        return err;
    };
}

fn capped(count: u32) u16 {
    return @intCast(@min(count, std.math.maxInt(u16)));
}

/// Field by field, as the padding between them is undefined.
fn sameCampaigns(first: *const campaigns_mod.Campaigns, second: *const campaigns_mod.Campaigns) bool {
    if (first.count != second.count) return false;
    for (first.slice(), second.slice()) |first_campaign, second_campaign| {
        if (!std.meta.eql(first_campaign, second_campaign)) return false;
    }
    return true;
}

const testing = std.testing;

const JITA_ID = 30000142;
const AMARR_ID = 30002187;

test "applyKills and applyJumps fill the systems they name and skip wormholes" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    try snapshot.applyKills("[{\"npc_kills\":41,\"pod_kills\":2,\"ship_kills\":7,\"system_id\":30000142},{\"npc_kills\":9,\"pod_kills\":0,\"ship_kills\":0,\"system_id\":31000005}]");
    try snapshot.applyJumps("[{\"ship_jumps\":5000,\"system_id\":30000142}]");

    const jita = snapshot.systems[universe.findSystemById(JITA_ID).?];
    try testing.expectEqual(@as(u16, 7), jita.ship_kills);
    try testing.expectEqual(@as(u16, 2), jita.pod_kills);
    try testing.expectEqual(@as(u16, 41), jita.npc_kills);
    try testing.expectEqual(@as(u16, 5000), jita.jumps);
    try testing.expectEqual(@as(u16, 0), snapshot.systems[universe.findSystemById(AMARR_ID).?].ship_kills);
    try testing.expect(snapshot.has_kills and snapshot.has_jumps and !snapshot.has_sovereignty);
}

test "carryNpcDelta measures a new hour against the last, and keeps it within an hour" {
    var first: Snapshot = try .init(testing.allocator);
    defer first.deinit();
    try first.applyKills("[{\"npc_kills\":40,\"system_id\":30000142}]");
    var second: Snapshot = try .init(testing.allocator);
    defer second.deinit();
    try second.applyKills("[{\"npc_kills\":40,\"system_id\":30000142}]");
    second.carryNpcDelta(&first);
    try testing.expect(!second.has_npc_delta);

    var third: Snapshot = try .init(testing.allocator);
    defer third.deinit();
    try third.applyKills("[{\"npc_kills\":25,\"system_id\":30000142}]");
    third.carryNpcDelta(&second);
    const jita = universe.findSystemById(JITA_ID).?;
    try testing.expect(third.has_npc_delta);
    try testing.expectEqual(@as(i32, -15), third.systems[jita].npc_delta);

    var fourth: Snapshot = try .init(testing.allocator);
    defer fourth.deinit();
    try fourth.applyKills("[{\"npc_kills\":25,\"system_id\":30000142}]");
    fourth.carryNpcDelta(&third);
    try testing.expectEqual(@as(i32, -15), fourth.systems[jita].npc_delta);
}

test "a count past u16 saturates" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    try snapshot.applyJumps("[{\"ship_jumps\":70000,\"system_id\":30000142}]");
    try testing.expectEqual(@as(u16, 65535), snapshot.systems[universe.findSystemById(JITA_ID).?].jumps);
}

test "applySovereignty shares a holder between its systems and prefers the alliance" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    try snapshot.applySovereignty("[{\"system_id\":30000142,\"alliance_id\":99,\"corporation_id\":5,\"faction_id\":500001},{\"system_id\":30002187,\"alliance_id\":99},{\"system_id\":30000001,\"faction_id\":500007},{\"system_id\":30000002}]");
    try testing.expectEqualSlices(u32, &.{ 99, 500007 }, snapshot.holder_ids.items);

    try snapshot.applyNames("[{\"category\":\"alliance\",\"id\":99,\"name\":\"Test Alliance\"}]");
    try testing.expectEqualStrings("Test Alliance", snapshot.holderName(universe.findSystemById(AMARR_ID).?).?);
    try testing.expect(snapshot.holderName(universe.findSystemById(30000001).?) == null);
    try testing.expect(snapshot.holderName(universe.findSystemById(30000002).?) == null);
}

test "applyCampaigns names each defender through holder_ids without giving it systems" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    try snapshot.applySovereignty("[{\"system_id\":30000142,\"alliance_id\":99}]");
    try snapshot.applyCampaigns("[{\"defender_id\":99,\"event_type\":\"ihub_defense\",\"solar_system_id\":30000142,\"start_time\":\"2026-11-09T22:54:09Z\"},{\"defender_id\":77,\"event_type\":\"ihub_defense\",\"solar_system_id\":30002187,\"start_time\":\"2026-11-09T22:54:09Z\"}]");
    try testing.expectEqualSlices(u32, &.{ 99, 77 }, snapshot.holder_ids.items);
    try snapshot.applyNames("[{\"id\":77,\"name\":\"Defenders\"}]");
    try testing.expectEqualStrings("Defenders", snapshot.allianceName(77).?);
    try testing.expect(snapshot.holderName(universe.findSystemById(AMARR_ID).?) == null);
    try testing.expect(snapshot.has_campaigns);
}

test "live campaigns raise the revision only when the scores change" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    const reply = "[{\"defender_id\":99,\"defender_score\":0.6,\"attackers_score\":0.4,\"event_type\":\"ihub_defense\",\"solar_system_id\":30000142,\"start_time\":\"2026-11-09T22:54:09Z\"}]";
    try snapshot.applyCampaigns(reply);
    var fresh: campaigns_mod.Campaigns = try .parse(testing.allocator, reply);
    snapshot.applyLiveCampaigns(&fresh);
    try testing.expectEqual(@as(u32, 0), snapshot.campaigns_revision);
    fresh.campaigns[0].defender_percent = 70;
    snapshot.applyLiveCampaigns(&fresh);
    try testing.expectEqual(@as(u32, 1), snapshot.campaigns_revision);
    try testing.expectEqual(@as(u8, 70), snapshot.campaigns.campaigns[0].defender_percent);
}

test "a malformed reply fails without marking its figures as present" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    try testing.expectError(error.SyntaxError, snapshot.applyKills("[{not json"));
    try testing.expect(!snapshot.hasAnything());
}

test "namesRequest writes the ids as a JSON array" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("[99,500007]", try namesRequest(arena.allocator(), &.{ 99, 500007 }));
}
