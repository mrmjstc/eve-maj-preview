//! A snapshot of ESI's public per-system figures, parsed from its JSON replies; no I/O.
const std = @import("std");
const universe = @import("universe.zig");
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
    jumps: u16 = 0,
    /// Into Snapshot.holder_ids.
    holder: u16 = NO_HOLDER,
};

const KillRow = struct { system_id: u32, ship_kills: u32 = 0, pod_kills: u32 = 0, npc_kills: u32 = 0 };
const JumpRow = struct { system_id: u32, ship_jumps: u32 = 0 };
const SovereigntyRow = struct { system_id: u32, alliance_id: ?u32 = null, faction_id: ?u32 = null };
const NameRow = struct { id: u32, name: []const u8 };

/// Filled by the fetch thread, then only read by the main thread once it's handed over.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    /// By SystemIndex; owned.
    systems: []SystemStats,
    /// Who holds systems, as ESI names them; owned.
    holder_ids: std.ArrayList(u32) = .empty,
    /// By place in holder_ids, each owned; empty until applyNames finds it.
    holder_names: std.ArrayList([]const u8) = .empty,
    has_kills: bool = false,
    has_jumps: bool = false,
    has_sovereignty: bool = false,
    /// When it was fetched, in ms since boot.
    fetched_ms: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !Snapshot {
        const systems = try allocator.alloc(SystemStats, universe.SYSTEM_COUNT);
        @memset(systems, .{});
        return .{ .allocator = allocator, .systems = systems };
    }

    pub fn deinit(self: *Snapshot) void {
        for (self.holder_names.items) |name| self.allocator.free(name);
        self.holder_names.deinit(self.allocator);
        self.holder_ids.deinit(self.allocator);
        self.allocator.free(self.systems);
    }

    /// Whether any of its figures arrived.
    pub fn hasAnything(self: *const Snapshot) bool {
        return self.has_kills or self.has_jumps or self.has_sovereignty;
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
            if (!entry.found_existing) {
                entry.value_ptr.* = @intCast(self.holder_ids.items.len);
                try self.holder_ids.append(self.allocator, holder_id);
                try self.holder_names.append(self.allocator, "");
            }
            stats.holder = entry.value_ptr.*;
        }
        self.has_sovereignty = true;
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
