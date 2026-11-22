//! Eve Stars' route API: its addresses, and what its answers mean to the Map Panel; no I/O.
const std = @import("std");
const types = @import("../config/types.zig");
const universe = @import("universe.zig");
const fixed_text = @import("../util/fixed_text.zig");
const log = @import("../log.zig");

const RegionIndex = universe.RegionIndex;
const SystemIndex = universe.SystemIndex;
const SystemSet = universe.SystemSet;
const slog = log.Scoped("map");
pub const Text = fixed_text.FixedText;

pub const SITE_URL = "https://evestars.net";
const BASE_URL = SITE_URL ++ "/api/v1";
/// More groups and characters than this go unlisted.
pub const MAX_TARGETS = 64;
/// A send's result and the Ansiblex warning.
const NOTICE_MAX_LINES = 2;
pub const ANSIBLEX_ZONE_COUNT = 5;

pub const CHARACTERS_URL = BASE_URL ++ "/characters";
pub const ANSIBLEX_URL = BASE_URL ++ "/ansiblex";
pub const AVOID_URL = BASE_URL ++ "/avoid";
pub const ACTIVITY_URL = BASE_URL ++ "/activity";
/// Eve Stars keeps no more than this.
pub const MAX_AVOIDED_PLACES = 1000;
/// The fastest and two others, as many as fit the map's card.
pub const MAX_ROUTES = 3;
/// Past the longest gate route New Eden has; a longer one is cut short on the map.
pub const MAX_ROUTE_SYSTEMS = 256;
/// Past the few hundred one-way gates the biggest coalition's network has; any beyond it go unshown.
pub const MAX_BRIDGES = 1024;

const FAILED_TO_REACH = "Couldn't reach Eve Stars";
const FAILED_TO_READ = "Couldn't read Eve Stars' answer";
const NO_ONE_ONLINE = "Nobody in this group is online";
/// Eve Stars loads an account's gates on the first ask in an hour, and plots that route without them.
const ANSIBLEX_NOT_READY = "Ansiblex gates weren't loaded, so they weren't used: send again in a few seconds";
/// A send's row for a character already at the destination, which has nothing to set.
const ALREADY_THERE_CODE = "already_there";
const READ_ONLY_TOKEN_CODE = "token_read_only";

/// Why a call came to nothing, for the user to read.
pub const Failure = struct {
    text: Text,

    pub fn unreachedService() Failure {
        return .{ .text = .print(FAILED_TO_REACH, .{}) };
    }

    pub fn unreadableAnswer() Failure {
        return .{ .text = .print(FAILED_TO_READ, .{}) };
    }
};

/// How a sent route is planned.
pub const RouteOptions = struct {
    preference: types.RoutePreference,
    uses_ansiblex: bool,
    /// Every system on the route, rather than only those it needs.
    sets_every_waypoint: bool = false,
    /// Ansiblex landing zones refused, zone 1 first.
    avoids_zone: [ANSIBLEX_ZONE_COUNT]bool = @splat(false),
    /// CCP's id of a system a sent route must pass through, as an alternative is pinned; null for the fastest.
    via_id: ?u32 = null,
};

/// One way from the start to the destination.
pub const Route = struct {
    /// Start first, destination last.
    systems: [MAX_ROUTE_SYSTEMS]SystemIndex = undefined,
    system_count: usize = 0,
    jumps: u32 = 0,
    /// Ships and capsules lost in the last hour in the systems it enters.
    kills_last_hour: u32 = 0,
    /// The system an alternative is pinned through, which sending it passes on; null for the fastest.
    via: ?SystemIndex = null,

    pub fn slice(self: *const Route) []const SystemIndex {
        return self.systems[0..self.system_count];
    }

    fn add(self: *Route, system: SystemIndex) void {
        if (self.system_count == MAX_ROUTE_SYSTEMS) return;
        self.systems[self.system_count] = system;
        self.system_count += 1;
    }
};

/// The ways GET /route offers, the fastest first.
pub const Routes = struct {
    from: SystemIndex,
    to: SystemIndex,
    routes: [MAX_ROUTES]Route = undefined,
    count: usize = 0,
    /// Eve Stars hadn't loaded the Ansiblex gates yet, so the routes went without them.
    is_missing_ansiblex: bool = false,

    pub fn slice(self: *const Routes) []const Route {
        return self.routes[0..self.count];
    }
};

/// A place the account's routes keep out of.
pub const AvoidedPlace = struct {
    /// CCP's id, which PUT /avoid takes whatever the kind.
    id: u32,
    kind: Kind,
    /// Which one, for a constellation the map knows.
    constellation: ?u16 = null,
    /// Which one, for a region the map knows.
    region: ?RegionIndex = null,

    /// `other` for a kind Eve Stars has added since, which is kept so a change doesn't drop it.
    pub const Kind = enum { system, constellation, region, other };
};

/// How a system stands on the avoid list.
pub const Avoidance = enum {
    none,
    /// Named on the list, so it can be taken off.
    listed,
    /// Only inside a constellation or region on the list.
    in_area,
};

/// The account's saved avoid list, which every sent route keeps out of.
pub const AvoidList = struct {
    places: [MAX_AVOIDED_PLACES]AvoidedPlace = undefined,
    count: usize = 0,
    /// By SystemIndex, those named on the list.
    listed: SystemSet = .empty,
    /// By SystemIndex, those inside a constellation or region on the list.
    in_area: SystemSet = .empty,

    pub fn slice(self: *const AvoidList) []const AvoidedPlace {
        return self.places[0..self.count];
    }

    pub fn avoidanceOf(self: *const AvoidList, system: SystemIndex) Avoidance {
        if (self.listed.isSet(system)) return .listed;
        return if (self.in_area.isSet(system)) .in_area else .none;
    }

    pub fn isAvoided(self: *const AvoidList, system: SystemIndex) bool {
        return self.avoidanceOf(system) != .none;
    }

    /// The constellation or region on the list that covers `system`; null when none does.
    pub fn areaName(self: *const AvoidList, system: SystemIndex) ?[]const u8 {
        const info = universe.systemInfo(system);
        for (self.slice()) |place| {
            if (place.region) |region| {
                if (region == info.region) return universe.regionName(region);
            }
            if (place.constellation) |constellation| {
                if (constellation == info.constellation) return universe.constellationName(constellation);
            }
        }
        return null;
    }

    /// With `system` named on it, or taken off; error.AvoidListFull past Eve Stars' limit.
    pub fn toggled(self: *const AvoidList, system: SystemIndex) !AvoidList {
        var changed = self.*;
        const system_id = universe.systemInfo(system).id;
        if (self.listed.isSet(system)) {
            changed.count = 0;
            for (self.slice()) |place| {
                if (place.kind == .system and place.id == system_id) continue;
                changed.places[changed.count] = place;
                changed.count += 1;
            }
            changed.listed.unset(system);
            return changed;
        }
        if (self.count == MAX_AVOIDED_PLACES) return error.AvoidListFull;
        changed.places[changed.count] = .{ .id = system_id, .kind = .system };
        changed.count += 1;
        changed.listed.set(system);
        return changed;
    }

    /// Places past Eve Stars' own limit, which it shouldn't send, go unkept.
    fn add(self: *AvoidList, place: AvoidedPlace) void {
        if (self.count == MAX_AVOIDED_PLACES) {
            slog.warn("Failed to keep every avoided place: more than {d}", .{MAX_AVOIDED_PLACES});
            return;
        }
        self.places[self.count] = place;
        self.count += 1;
    }
};

/// Who a destination can be sent to.
pub const Target = struct {
    /// Goes to Eve Stars rather than the name, which a group and a character can share.
    id: u64,
    name: Text,
    kind: Kind,
    /// How many of a group's characters could take the route; 1 for a character.
    character_count: usize = 1,
    can_send: bool = true,
    /// Why it can't be sent to.
    why: Text = .{},

    pub const Kind = enum { group, character };

    /// Counted one by one for "All", since a group's members can be in other groups too.
    pub fn isSendableCharacter(self: *const Target) bool {
        return self.kind == .character and self.can_send;
    }
};

/// Groups first, then the characters not known to be offline, in the account's order.
pub const Targets = struct {
    items: [MAX_TARGETS]Target = undefined,
    count: usize = 0,

    pub fn slice(self: *const Targets) []const Target {
        return self.items[0..self.count];
    }

    pub fn groupCount(self: *const Targets) usize {
        var count: usize = 0;
        for (self.slice()) |*target| {
            if (target.kind == .group) count += 1;
        }
        return count;
    }

    pub fn sendableCharacterCount(self: *const Targets) usize {
        var count: usize = 0;
        for (self.slice()) |*target| {
            if (target.isSendableCharacter()) count += 1;
        }
        return count;
    }

    fn add(self: *Targets, target: Target) void {
        if (self.count == MAX_TARGETS) return;
        self.items[self.count] = target;
        self.count += 1;
    }
};

/// Lines for the panel to show, the first as a title.
pub const Notice = struct {
    lines: [NOTICE_MAX_LINES]Text = undefined,
    line_count: usize = 0,
    /// Stays up longer, so it can be read.
    is_failure: bool = false,

    pub fn line(self: *const Notice, index: usize) []const u8 {
        return self.lines[index].slice();
    }

    pub fn add(self: *Notice, text: Text) void {
        if (self.line_count == NOTICE_MAX_LINES) return;
        self.lines[self.line_count] = text;
        self.line_count += 1;
    }
};

const Place = struct { id: u64 = 0, name: []const u8 = "" };
const CharacterRow = struct { id: u64, name: []const u8 = "", online: ?bool = null, canSend: bool = false, why: ?[]const u8 = null };
const GroupRow = struct { id: u64, name: []const u8 = "", characters: []const u64 = &.{} };
const CharactersAnswer = struct { characters: []const CharacterRow = &.{}, groups: []const GroupRow = &.{} };
const SentRow = struct { character: Place = .{}, set: bool = false, said: []const u8 = "", code: []const u8 = "" };
const AnsiblexRow = struct { ready: bool = true };
const SendAnswer = struct { to: Place = .{}, sent: []const SentRow = &.{}, ansiblex: ?AnsiblexRow = null };
/// A gate's or a leg's end, by CCP's system id.
const EndRow = struct { id: u32 = 0 };
const BridgeRow = struct { from: EndRow = .{}, to: EndRow = .{} };
const BridgesAnswer = struct { ready: bool = false, ansiblex: []const BridgeRow = &.{} };
const LegRow = struct { from: EndRow = .{}, to: EndRow = .{} };
const RouteRow = struct { jumps: u32 = 0, killsLastHour: u32 = 0, via: ?Place = null, legs: []const LegRow = &.{} };
const RouteAnswer = struct { from: Place = .{}, to: Place = .{}, ansiblex: ?AnsiblexRow = null, routes: []const RouteRow = &.{} };
const AvoidRow = struct { id: u32 = 0, name: []const u8 = "", kind: []const u8 = "" };
const AvoidAnswer = struct { avoid: []const AvoidRow = &.{} };
const ErrorAnswer = struct { @"error": []const u8 = "", code: []const u8 = "" };

/// One way through an Ansiblex gate.
pub const Bridge = struct {
    from: SystemIndex,
    to: SystemIndex,
};

/// The account's Ansiblex gates its characters may jump.
pub const Bridges = struct {
    bridges: [MAX_BRIDGES]Bridge = undefined,
    count: usize = 0,
    /// False while Eve Stars is still reading them from the game, so the list is empty or partial.
    is_ready: bool = false,

    pub fn slice(self: *const Bridges) []const Bridge {
        return self.bridges[0..self.count];
    }

    /// Whether the way back from `bridge`'s far end is listed too.
    pub fn isTwoWay(self: *const Bridges, bridge: Bridge) bool {
        for (self.slice()) |other| {
            if (other.from == bridge.to and other.to == bridge.from) return true;
        }
        return false;
    }
};

/// Leaves out `from`, so each character starts where it is, and goes to every target in one call; caller frees.
pub fn sendUrl(allocator: std.mem.Allocator, system_id: u32, target_ids: []const u64, options: *const RouteOptions) ![]u8 {
    var url: std.Io.Writer.Allocating = .init(allocator);
    defer url.deinit();
    try url.writer.print(BASE_URL ++ "/route?to={d}&send=", .{system_id});
    for (target_ids, 0..) |target_id, index| {
        try url.writer.print("{s}{d}", .{ if (index == 0) "" else ",", target_id });
    }
    try writeRouteOptions(&url.writer, options);
    if (options.sets_every_waypoint) try url.writer.writeAll("&waypoints=every");
    if (options.via_id) |via_id| try url.writer.print("&via={d}", .{via_id});
    return allocator.dupe(u8, url.written());
}

/// Plans from `from_id` to `to_id` with the fastest's MAX_ROUTES - 1 others, and sets nothing; caller frees.
pub fn routeUrl(allocator: std.mem.Allocator, from_id: u32, to_id: u32, options: *const RouteOptions) ![]u8 {
    var url: std.Io.Writer.Allocating = .init(allocator);
    defer url.deinit();
    try url.writer.print(BASE_URL ++ "/route?from={d}&to={d}&others={d}", .{ from_id, to_id, MAX_ROUTES - 1 });
    try writeRouteOptions(&url.writer, options);
    return allocator.dupe(u8, url.written());
}

/// `body` is GET /route's answer, leaving any system the map doesn't have out of its route; `arena` is scratch.
pub fn parseRoutes(arena: std.mem.Allocator, body: []const u8) !Routes {
    const answer = try parseAnswer(RouteAnswer, arena, body);
    const from = systemOf(answer.from) orelse return error.InvalidSystem;
    const to = systemOf(answer.to) orelse return error.InvalidSystem;
    var routes: Routes = .{ .from = from, .to = to, .is_missing_ansiblex = if (answer.ansiblex) |ansiblex| !ansiblex.ready else false };
    for (answer.routes) |row| {
        if (routes.count == MAX_ROUTES) break;
        var route: Route = .{ .jumps = row.jumps, .kills_last_hour = row.killsLastHour };
        if (row.via) |via| route.via = systemOf(via);
        route.add(from);
        for (row.legs) |leg| {
            if (universe.findSystemById(leg.to.id)) |system| route.add(system);
        }
        routes.routes[routes.count] = route;
        routes.count += 1;
    }
    return routes;
}

/// PUT /avoid's body, naming every place by id; caller frees.
pub fn avoidBody(allocator: std.mem.Allocator, list: *const AvoidList) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try body.writer.writeAll("{\"avoid\":[");
    for (list.slice(), 0..) |place, index| {
        try body.writer.print("{s}{d}", .{ if (index == 0) "" else ",", place.id });
    }
    try body.writer.writeAll("]}");
    return allocator.dupe(u8, body.written());
}

/// `body` is GET or PUT /avoid's answer, keeping a place the map doesn't have though it marks no system; `arena` is scratch.
pub fn parseAvoid(arena: std.mem.Allocator, body: []const u8) !AvoidList {
    const answer = try parseAnswer(AvoidAnswer, arena, body);
    var list: AvoidList = .{};
    for (answer.avoid) |row| {
        var place: AvoidedPlace = .{ .id = row.id, .kind = std.meta.stringToEnum(AvoidedPlace.Kind, row.kind) orelse .other };
        switch (place.kind) {
            .system => if (universe.findSystemById(row.id)) |system| list.listed.set(system),
            .constellation => place.constellation = findConstellation(row.name),
            .region => place.region = universe.findRegionById(row.id),
            .other => {},
        }
        list.add(place);
    }
    markAreas(&list);
    return list;
}

/// The header's value; caller frees.
pub fn authorization(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    return allocator.print("Bearer {s}", .{std.mem.trim(u8, token, " \t\r\n")});
}

/// `body` is /characters' answer; `arena` is scratch.
pub fn parseTargets(arena: std.mem.Allocator, body: []const u8) !Targets {
    const answer = try parseAnswer(CharactersAnswer, arena, body);
    var targets: Targets = .{};
    for (answer.groups) |row| {
        const reachable_count = reachableCount(answer.characters, row.characters);
        targets.add(.{
            .id = row.id,
            .name = .print("{s}", .{row.name}),
            .kind = .group,
            .character_count = reachable_count,
            .can_send = reachable_count > 0,
            .why = .print(NO_ONE_ONLINE, .{}),
        });
    }
    for (answer.characters) |row| {
        if (isOffline(row)) continue;
        targets.add(.{
            .id = row.id,
            .name = .print("{s}", .{row.name}),
            .kind = .character,
            .can_send = row.canSend,
            .why = .print("{s}", .{row.why orelse ""}),
        });
    }
    return targets;
}

/// `body` is GET /ansiblex's answer, skipping a gate at a system the map doesn't have; `arena` is scratch.
pub fn parseBridges(arena: std.mem.Allocator, body: []const u8) !Bridges {
    const answer = try parseAnswer(BridgesAnswer, arena, body);
    var parsed: Bridges = .{ .is_ready = answer.ready };
    for (answer.ansiblex) |row| {
        if (parsed.count == MAX_BRIDGES) {
            slog.warn("Failed to show every Ansiblex gate: more than {d}", .{MAX_BRIDGES});
            break;
        }
        const from = universe.findSystemById(row.from.id) orelse continue;
        const to = universe.findSystemById(row.to.id) orelse continue;
        parsed.bridges[parsed.count] = .{ .from = from, .to = to };
        parsed.count += 1;
    }
    return parsed;
}

/// `body` is POST /route's answer, whose status says nothing of how each character fared; `arena` is scratch.
pub fn parseSend(arena: std.mem.Allocator, body: []const u8) !Notice {
    const answer = try parseAnswer(SendAnswer, arena, body);
    var set_count: usize = 0;
    for (answer.sent) |row| {
        if (row.set or std.mem.eql(u8, row.code, ALREADY_THERE_CODE)) {
            set_count += 1;
        } else {
            // Logged rather than shown, as a few misses are normal and they swamped the map.
            slog.info("Eve Stars didn't set '{s}' for '{s}': {s}", .{ answer.to.name, row.character.name, row.said });
        }
    }

    var notice: Notice = .{ .is_failure = set_count == 0 };
    notice.add(.print("{s}: set for {d} of {d}", .{ answer.to.name, set_count, answer.sent.len }));
    if (answer.ansiblex) |ansiblex| {
        if (!ansiblex.ready) notice.add(.print(ANSIBLEX_NOT_READY, .{}));
    }
    return notice;
}

/// A reply other than 200, in words; a status's meaning is promised, but `error`'s wording isn't, so it's only passed on.
pub fn failureOf(arena: std.mem.Allocator, status: u32, body: []const u8) Failure {
    const answer = errorAnswerOf(arena, body);
    const text: Text = switch (status) {
        401 => .print("Eve Stars refused the token: make a new one in its Pilot section", .{}),
        403 => if (std.mem.eql(u8, answer.code, READ_ONLY_TOKEN_CODE))
            .print("This Eve Stars token only reads: make one that reads and sends", .{})
        else
            .print("Eve Stars has withdrawn this account's access", .{}),
        429 => .print("Too many calls to Eve Stars: try again shortly", .{}),
        503 => .print("Eve Stars can't send routes right now", .{}),
        else => if (answer.@"error".len > 0) .print("{s}", .{answer.@"error"}) else .print("Eve Stars answered {d}", .{status}),
    };
    return .{ .text = text };
}

/// Empty for a body that isn't one, as the status still says it failed; borrows from `arena`.
fn errorAnswerOf(arena: std.mem.Allocator, body: []const u8) ErrorAnswer {
    return parseAnswer(ErrorAnswer, arena, body) catch |err| blk: {
        slog.debug("No reason in Eve Stars' answer: {}", .{err});
        break :blk .{};
    };
}

/// Eve Stars names constellations, which the map knows only by name; searched linearly, as this runs once per answer.
fn findConstellation(name: []const u8) ?u16 {
    for (0..universe.SYSTEM_COUNT) |index| {
        const constellation = universe.systemInfo(@intCast(index)).constellation;
        if (std.mem.eql(u8, universe.constellationName(constellation), name)) return constellation;
    }
    return null;
}

fn markAreas(list: *AvoidList) void {
    for (list.slice()) |place| {
        if (place.constellation == null and place.region == null) continue;
        for (0..universe.SYSTEM_COUNT) |index| {
            const info = universe.systemInfo(@intCast(index));
            const is_inside = if (place.region) |region| region == info.region else if (place.constellation) |constellation| constellation == info.constellation else false;
            if (is_inside) list.in_area.set(index);
        }
    }
}

/// Null for an id that isn't a system the map has.
fn systemOf(place: Place) ?SystemIndex {
    return universe.findSystemById(std.math.cast(u32, place.id) orelse return null);
}

/// What a plan and a send share: the security, the gates, and the account's saved avoid list, which Eve Stars leaves the route's own ends out of.
fn writeRouteOptions(writer: *std.Io.Writer, options: *const RouteOptions) !void {
    try writer.print("&security={s}&bridges={s}", .{
        securityParameter(options.preference),
        if (options.uses_ansiblex) "true" else "false",
    });
    try writer.writeAll("&avoid=saved");
    if (options.uses_ansiblex) try writeAvoidZones(writer, options);
}

fn writeAvoidZones(writer: *std.Io.Writer, options: *const RouteOptions) !void {
    var separator: []const u8 = "&avoidZones=";
    for (options.avoids_zone, 1..) |is_avoided, zone| {
        if (!is_avoided) continue;
        try writer.print("{s}{d}", .{ separator, zone });
        separator = ",";
    }
}

fn securityParameter(preference: types.RoutePreference) []const u8 {
    return switch (preference) {
        .Shorter => "shortest",
        .Safer => "safest",
        .LessSecure => "unsafest",
    };
}

/// One that doesn't share whether it's online still gets sent routes, so only a known offline counts.
fn isOffline(row: CharacterRow) bool {
    return row.online == false;
}

/// Of `member_ids`; searched linearly, as an account has only a few dozen characters.
fn reachableCount(characters: []const CharacterRow, member_ids: []const u64) usize {
    var count: usize = 0;
    for (characters) |row| {
        if (!isOffline(row) and std.mem.indexOfScalar(u64, member_ids, row.id) != null) count += 1;
    }
    return count;
}

/// The answer's strings borrow from `arena`.
fn parseAnswer(comptime T: type, arena: std.mem.Allocator, body: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{ .ignore_unknown_fields = true });
}

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return .init(testing.allocator);
}

test "parseBridges reads each gate's ends, and whether the list is ready" {
    var arena = testArena();
    defer arena.deinit();
    const bridges = try parseBridges(arena.allocator(),
        \\{"ready":true,"readAt":"2026-11-09T08:00:00Z","count":3,"barred":0,"ansiblex":[
        \\{"id":1,"from":{"id":30000142,"name":"Jita","security":0.9},"to":{"id":30002187,"name":"Amarr","security":1.0},"zone":2,"standsIn":1},
        \\{"id":2,"from":{"id":30002187},"to":{"id":30000142},"zone":null,"standsIn":null},
        \\{"id":3,"from":{"id":30000142},"to":{"id":31000005}}]}
    );
    try testing.expect(bridges.is_ready);
    try testing.expectEqual(@as(usize, 2), bridges.count);
    try testing.expectEqual(universe.findSystem("Jita").?, bridges.bridges[0].from);
    try testing.expect(bridges.isTwoWay(bridges.bridges[0]));
    try testing.expect(!(try parseBridges(arena.allocator(), "{\"ready\":false}")).is_ready);
}

test "sendUrl leaves out the start, so each character sets off from where it is" {
    const url = try sendUrl(testing.allocator, 30002187, &.{98000001}, &.{ .preference = .Shorter, .uses_ansiblex = false });
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(BASE_URL ++ "/route?to=30002187&send=98000001&security=shortest&bridges=false&avoid=saved", url);
}

test "sendUrl lists every target in the one call" {
    const url = try sendUrl(testing.allocator, 30002187, &.{ 1, 2, 3 }, &.{ .preference = .Shorter, .uses_ansiblex = false });
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(BASE_URL ++ "/route?to=30002187&send=1,2,3&security=shortest&bridges=false&avoid=saved", url);
}

test "sendUrl carries the route's options" {
    const url = try sendUrl(testing.allocator, 30002187, &.{98000001}, &.{ .preference = .LessSecure, .uses_ansiblex = true });
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(BASE_URL ++ "/route?to=30002187&send=98000001&security=unsafest&bridges=true&avoid=saved", url);
}

test "sendUrl asks for every waypoint only when set to" {
    const url = try sendUrl(testing.allocator, 30002187, &.{98000001}, &.{ .preference = .Shorter, .uses_ansiblex = false, .sets_every_waypoint = true });
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(BASE_URL ++ "/route?to=30002187&send=98000001&security=shortest&bridges=false&avoid=saved&waypoints=every", url);
}

test "sendUrl sends refused zones only with Ansiblex on" {
    var options: RouteOptions = .{ .preference = .Shorter, .uses_ansiblex = true, .avoids_zone = .{ true, false, false, false, true } };
    const with_gates = try sendUrl(testing.allocator, 1, &.{2}, &options);
    defer testing.allocator.free(with_gates);
    try testing.expectEqualStrings(BASE_URL ++ "/route?to=1&send=2&security=shortest&bridges=true&avoid=saved&avoidZones=1,5", with_gates);

    options.uses_ansiblex = false;
    const without_gates = try sendUrl(testing.allocator, 1, &.{2}, &options);
    defer testing.allocator.free(without_gates);
    try testing.expectEqualStrings(BASE_URL ++ "/route?to=1&send=2&security=shortest&bridges=false&avoid=saved", without_gates);
}

test "sendUrl pins an alternative through its via" {
    const url = try sendUrl(testing.allocator, 30002187, &.{98000001}, &.{ .preference = .Safer, .uses_ansiblex = false, .via_id = 30004080 });
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(BASE_URL ++ "/route?to=30002187&send=98000001&security=safest&bridges=false&avoid=saved&via=30004080", url);
}

test "routeUrl plans from a start with the others, and sends nothing" {
    const url = try routeUrl(testing.allocator, 30000142, 30002187, &.{ .preference = .Shorter, .uses_ansiblex = true, .avoids_zone = .{ true, false, false, false, false } });
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(BASE_URL ++ "/route?from=30000142&to=30002187&others=2&security=shortest&bridges=true&avoid=saved&avoidZones=1", url);
}

test "parseRoutes walks each route's legs from the start, and keeps an alternative's pin" {
    var arena = testArena();
    defer arena.deinit();
    const routes = try parseRoutes(arena.allocator(),
        \\{"from":{"id":30000142,"name":"Jita"},"to":{"id":30000144,"name":"Perimeter"},"ansiblex":{"ready":false,"count":0,"barred":0},
        \\"routes":[{"rank":1,"extraJumps":0,"jumps":1,"via":null,"killsLastHour":66,
        \\"legs":[{"from":{"id":30000142},"to":{"id":30000144},"by":"gate"}],"waypoints":[],"link":null},
        \\{"rank":2,"jumps":2,"killsLastHour":3,"via":{"id":30000139,"name":"Urlen"},
        \\"legs":[{"from":{"id":30000142},"to":{"id":30000139}},{"from":{"id":30000139},"to":{"id":30000144}}]}]}
    );
    try testing.expectEqual(@as(usize, 2), routes.count);
    try testing.expect(routes.is_missing_ansiblex);
    const fastest = &routes.slice()[0];
    try testing.expectEqual(@as(u32, 66), fastest.kills_last_hour);
    try testing.expectEqual(@as(?SystemIndex, null), fastest.via);
    try testing.expectEqualSlices(SystemIndex, &.{ universe.findSystem("Jita").?, universe.findSystem("Perimeter").? }, fastest.slice());
    const other = &routes.slice()[1];
    try testing.expectEqual(universe.findSystem("Urlen"), other.via);
    try testing.expectEqual(@as(usize, 3), other.system_count);
}

test "parseAvoid marks named systems apart from those inside an avoided area, and keeps kinds it doesn't know" {
    var arena = testArena();
    defer arena.deinit();
    const list = try parseAvoid(arena.allocator(),
        \\{"avoid":[{"id":30002813,"name":"Tama","kind":"system"},{"id":10000002,"name":"The Forge","kind":"region"},
        \\{"id":1,"name":"Somewhere","kind":"faction"}],"changedAt":"2026-11-02T18:20:00.000Z"}
    );
    try testing.expectEqual(@as(usize, 3), list.count);
    try testing.expectEqual(Avoidance.listed, list.avoidanceOf(universe.findSystem("Tama").?));
    try testing.expectEqual(Avoidance.in_area, list.avoidanceOf(universe.findSystem("Jita").?));
    try testing.expectEqual(Avoidance.none, list.avoidanceOf(universe.findSystem("Amarr").?));
    try testing.expectEqualStrings("The Forge", list.areaName(universe.findSystem("Jita").?).?);
    try testing.expectEqual(AvoidedPlace.Kind.other, list.slice()[2].kind);
}

test "parseAvoid finds a constellation by its name" {
    var arena = testArena();
    defer arena.deinit();
    const list = try parseAvoid(arena.allocator(), "{\"avoid\":[{\"id\":20000020,\"name\":\"Kimotoro\",\"kind\":\"constellation\"}]}");
    try testing.expectEqual(Avoidance.in_area, list.avoidanceOf(universe.findSystem("Jita").?));
    try testing.expectEqualStrings("Kimotoro", list.areaName(universe.findSystem("Jita").?).?);
}

test "toggled names a system, then takes it off again, leaving the rest in order" {
    var arena = testArena();
    defer arena.deinit();
    const list = try parseAvoid(arena.allocator(), "{\"avoid\":[{\"id\":30002813,\"kind\":\"system\"},{\"id\":10000002,\"kind\":\"region\"}]}");
    const amarr = universe.findSystem("Amarr").?;
    const added = try list.toggled(amarr);
    try testing.expectEqual(Avoidance.listed, added.avoidanceOf(amarr));
    const body = try avoidBody(testing.allocator, &added);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"avoid\":[30002813,10000002,30002187]}", body);

    const removed = try added.toggled(universe.findSystem("Tama").?);
    try testing.expectEqual(Avoidance.none, removed.avoidanceOf(universe.findSystem("Tama").?));
    try testing.expectEqual(@as(usize, 2), removed.count);
    try testing.expectEqual(@as(u32, 10000002), removed.slice()[0].id);
}

test "a system inside an avoided area is listed on its own when toggled" {
    var arena = testArena();
    defer arena.deinit();
    const list = try parseAvoid(arena.allocator(), "{\"avoid\":[{\"id\":10000002,\"kind\":\"region\"}]}");
    const jita = universe.findSystem("Jita").?;
    try testing.expectEqual(Avoidance.listed, (try list.toggled(jita)).avoidanceOf(jita));
}

test "avoidBody of an empty list clears it" {
    const body = try avoidBody(testing.allocator, &.{});
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"avoid\":[]}", body);
}

test "authorization drops whitespace pasted with the token" {
    const header = try authorization(testing.allocator, "  evestars_abc\r\n");
    defer testing.allocator.free(header);
    try testing.expectEqualStrings("Bearer evestars_abc", header);
}

test "parseTargets lists groups first, drops offline characters and carries why one can't be sent to" {
    var arena = testArena();
    defer arena.deinit();
    const body =
        \\{"characters":[
        \\{"id":1,"name":"Alpha","main":true,"online":true,"location":{"id":30000142,"name":"Jita"},"canSend":true},
        \\{"id":2,"name":"Bravo","main":false,"online":false,"location":null,"canSend":true},
        \\{"id":3,"name":"Charlie","main":false,"online":null,"location":null,"canSend":false,"why":"Sign in again."}],
        \\"groups":[{"id":9,"name":"Haulers","characters":[1,2]},{"id":8,"name":"Scouts","characters":[2]}]}
    ;
    const targets = try parseTargets(arena.allocator(), body);
    try testing.expectEqual(@as(usize, 4), targets.count);
    const items = targets.slice();
    try testing.expectEqual(Target.Kind.group, items[0].kind);
    try testing.expectEqual(@as(usize, 1), items[0].character_count);
    try testing.expect(items[0].can_send);
    try testing.expectEqual(@as(usize, 0), items[1].character_count);
    try testing.expect(!items[1].can_send);
    try testing.expectEqualStrings(NO_ONE_ONLINE, items[1].why.slice());
    try testing.expectEqualStrings("Alpha", items[2].name.slice());
    try testing.expectEqualStrings("Charlie", items[3].name.slice());
    try testing.expect(!items[3].can_send);
    try testing.expectEqualStrings("Sign in again.", items[3].why.slice());
    try testing.expectEqual(@as(usize, 1), targets.sendableCharacterCount());
    try testing.expectEqual(@as(usize, 2), targets.groupCount());
}

test "parseSend sums up a partial send in one line, and only nobody set counts as failing" {
    var arena = testArena();
    defer arena.deinit();
    const body =
        \\{"to":{"id":30002187,"name":"Amarr"},"sent":[
        \\{"character":{"id":1,"name":"Alpha"},"from":null,"route":null,"set":true,"waypointsSet":1,"said":"The waypoint is set."},
        \\{"character":{"id":2,"name":"Bravo"},"from":null,"route":null,"set":false,"waypointsSet":0,"said":"Not logged in."}]}
    ;
    const notice = try parseSend(arena.allocator(), body);
    try testing.expect(!notice.is_failure);
    try testing.expectEqualStrings("Amarr: set for 1 of 2", notice.line(0));
    try testing.expectEqual(@as(usize, 1), notice.line_count);

    const nobody = try parseSend(arena.allocator(), "{\"to\":{\"name\":\"Amarr\"},\"sent\":[{\"character\":{\"name\":\"Bravo\"},\"set\":false,\"said\":\"Not logged in.\"}]}");
    try testing.expect(nobody.is_failure);
}

test "parseSend counts a character already at the destination as done" {
    var arena = testArena();
    defer arena.deinit();
    const notice = try parseSend(arena.allocator(), "{\"to\":{\"name\":\"Amarr\"},\"sent\":[{\"character\":{\"name\":\"Alpha\"},\"set\":false,\"code\":\"already_there\",\"said\":\"Already in Amarr: there is nothing to set.\"}]}");
    try testing.expect(!notice.is_failure);
    try testing.expectEqualStrings("Amarr: set for 1 of 1", notice.line(0));
}

test "parseSend says when Eve Stars had no Ansiblex gates to plot with" {
    var arena = testArena();
    defer arena.deinit();
    const body = "{\"to\":{\"name\":\"Amarr\"},\"ansiblex\":{\"ready\":false,\"count\":0,\"barred\":0},\"sent\":[{\"character\":{\"name\":\"Alpha\"},\"set\":true,\"said\":\"The waypoint is set.\"}]}";
    const notice = try parseSend(arena.allocator(), body);
    try testing.expect(!notice.is_failure);
    try testing.expectEqualStrings(ANSIBLEX_NOT_READY, notice.line(1));

    const without = try parseSend(arena.allocator(), "{\"to\":{\"name\":\"Amarr\"},\"ansiblex\":null,\"sent\":[]}");
    try testing.expectEqual(@as(usize, 1), without.line_count);
}

test "failureOf words what a status means, and passes on a 400's reason" {
    var arena = testArena();
    defer arena.deinit();
    const refused = failureOf(arena.allocator(), 401, "{\"error\":\"whatever\"}");
    try testing.expectEqualStrings("Eve Stars refused the token: make a new one in its Pilot section", refused.text.slice());
    const bad = failureOf(arena.allocator(), 400, "{\"error\":\"No such group.\"}");
    try testing.expectEqualStrings("No such group.", bad.text.slice());
    const unreadable = failureOf(arena.allocator(), 500, "<html>");
    try testing.expectEqualStrings("Eve Stars answered 500", unreadable.text.slice());
}

test "failureOf tells a read-only token from an account shut out" {
    var arena = testArena();
    defer arena.deinit();
    const read_only = failureOf(arena.allocator(), 403, "{\"error\":\"x\",\"code\":\"token_read_only\"}");
    try testing.expectEqualStrings("This Eve Stars token only reads: make one that reads and sends", read_only.text.slice());
    const shut_out = failureOf(arena.allocator(), 403, "{\"error\":\"x\",\"code\":\"not_on_access_list\"}");
    try testing.expectEqualStrings("Eve Stars has withdrawn this account's access", shut_out.text.slice());
}
