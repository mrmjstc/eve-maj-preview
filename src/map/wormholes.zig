//! Thera's and Turnur's wormhole connections into known space, parsed from EVE-Scout's replies; no I/O.
const std = @import("std");
const universe = @import("universe.zig");
const fixed_text = @import("../util/fixed_text.zig");
const log = @import("../log.zig");

const FixedText = fixed_text.FixedText;
const SystemIndex = universe.SystemIndex;
const slog = log.Scoped("map");

/// Well past the forty or so the two hubs have open at once; any beyond it go unshown.
pub const MAX_CONNECTIONS = 96;
/// Turnur has gates, so it's on the map, unlike Thera.
pub const TURNUR_ID = 30002086;

pub const Hub = enum { thera, turnur };

/// The largest ship a connection lets through, as EVE-Scout names it.
pub const ShipSize = enum { small, medium, large, xlarge, capital, unknown };

const Row = struct {
    in_system_id: u32,
    in_signature: ?[]const u8 = null,
    out_signature: ?[]const u8 = null,
    max_ship_size: ?[]const u8 = null,
    remaining_hours: ?i32 = null,
};

pub const Connection = struct {
    hub: Hub,
    /// The known-space end.
    system: SystemIndex,
    /// The signature in `system`, e.g. "UQL-360"; empty while unscanned.
    signature: FixedText,
    /// The signature in the hub.
    hub_signature: FixedText,
    ship_size: ShipSize,
    remaining_hours: u16,
};

pub const Connections = struct {
    connections: [MAX_CONNECTIONS]Connection = undefined,
    count: usize = 0,

    /// Adds `hub`'s connections from `body`, its signatures reply; ends in wormhole space, with no gates, are skipped.
    pub fn add(self: *Connections, allocator: std.mem.Allocator, body: []const u8, hub: Hub) !void {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const rows = try std.json.parseFromSliceLeaky([]const Row, arena.allocator(), body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        for (rows) |row| {
            if (self.count == MAX_CONNECTIONS) {
                slog.warn("Failed to show every wormhole connection: more than {d}", .{MAX_CONNECTIONS});
                return;
            }
            const system = universe.findSystemById(row.in_system_id) orelse continue;
            self.connections[self.count] = .{
                .hub = hub,
                .system = system,
                .signature = .print("{s}", .{row.in_signature orelse ""}),
                .hub_signature = .print("{s}", .{row.out_signature orelse ""}),
                .ship_size = std.meta.stringToEnum(ShipSize, row.max_ship_size orelse "") orelse .unknown,
                .remaining_hours = @intCast(std.math.clamp(row.remaining_hours orelse 0, 0, std.math.maxInt(u16))),
            };
            self.count += 1;
        }
    }

    pub fn slice(self: *const Connections) []const Connection {
        return self.connections[0..self.count];
    }

    /// Whether `system` has a connection to `hub`.
    pub fn links(self: *const Connections, system: SystemIndex, hub: Hub) bool {
        for (self.slice()) |connection| {
            if (connection.system == system and connection.hub == hub) return true;
        }
        return false;
    }

    pub fn countTo(self: *const Connections, hub: Hub) usize {
        var count: usize = 0;
        for (self.slice()) |connection| count += @intFromBool(connection.hub == hub);
        return count;
    }
};

const testing = std.testing;

const THERA_REPLY =
    \\[{"id":"77964","wh_type":"V898","max_ship_size":"xlarge","remaining_hours":2,"signature_type":"wormhole","out_system_id":31000005,"out_system_name":"Thera","out_signature":"WJF-372","in_system_id":30000205,"in_system_class":"ls","in_system_name":"Obe","in_signature":"UQL-360"},
    \\{"id":"1","max_ship_size":"medium","remaining_hours":4,"out_system_id":31000005,"out_signature":"BJT-990","in_system_id":31000400,"in_signature":"TOS-437"},
    \\{"id":"2","max_ship_size":"huge","out_system_id":31000005,"in_system_id":30003007}]
;
const OBE_ID = 30000205;

test "add reads each connection into known space and skips wormhole space" {
    var connections: Connections = .{};
    try connections.add(testing.allocator, THERA_REPLY, .thera);
    try testing.expectEqual(@as(usize, 2), connections.count);
    const first = connections.connections[0];
    try testing.expectEqual(universe.findSystemById(OBE_ID).?, first.system);
    try testing.expectEqualStrings("UQL-360", first.signature.slice());
    try testing.expectEqualStrings("WJF-372", first.hub_signature.slice());
    try testing.expectEqual(ShipSize.xlarge, first.ship_size);
    try testing.expectEqual(@as(u16, 2), first.remaining_hours);
    try testing.expectEqual(ShipSize.unknown, connections.connections[1].ship_size);
    try testing.expectEqualStrings("", connections.connections[1].signature.slice());
}

test "links and countTo tell the hubs apart" {
    var connections: Connections = .{};
    try connections.add(testing.allocator, THERA_REPLY, .thera);
    try connections.add(testing.allocator, "[{\"in_system_id\":30000205}]", .turnur);
    const obe = universe.findSystemById(OBE_ID).?;
    try testing.expect(connections.links(obe, .thera) and connections.links(obe, .turnur));
    try testing.expect(!connections.links(universe.findSystem("Jita").?, .thera));
    try testing.expectEqual(@as(usize, 2), connections.countTo(.thera));
    try testing.expectEqual(@as(usize, 1), connections.countTo(.turnur));
}

test "add fails on a malformed reply" {
    var connections: Connections = .{};
    try testing.expectError(error.SyntaxError, connections.add(testing.allocator, "[{not json", .thera));
}

test "TURNUR_ID names Turnur" {
    try testing.expectEqual(universe.findSystem("Turnur").?, universe.findSystemById(TURNUR_ID).?);
}
