//! Eve Stars' route API: its addresses, and what its answers mean to the Map Panel; no I/O.
const std = @import("std");
const types = @import("../config/types.zig");
const universe = @import("universe.zig");
const fixed_text = @import("../util/fixed_text.zig");
const log = @import("../log.zig");

const SystemIndex = universe.SystemIndex;
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
    avoid_ids: [types.MAX_AVOIDED_SYSTEMS]u32 = undefined,
    avoid_count: usize = 0,

    pub fn avoidIds(self: *const RouteOptions) []const u32 {
        return self.avoid_ids[0..self.avoid_count];
    }

    /// Ignores what's past the list's size, which only a hand-edited profile can reach.
    pub fn avoid(self: *RouteOptions, system_id: u32) void {
        if (self.avoid_count == self.avoid_ids.len) return;
        self.avoid_ids[self.avoid_count] = system_id;
        self.avoid_count += 1;
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
const BridgeEnd = struct { id: u32 = 0 };
const BridgeRow = struct { from: BridgeEnd = .{}, to: BridgeEnd = .{} };
const BridgesAnswer = struct { ready: bool = false, ansiblex: []const BridgeRow = &.{} };
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
    try url.writer.print("&security={s}&bridges={s}", .{
        securityParameter(options.preference),
        if (options.uses_ansiblex) "true" else "false",
    });
    if (options.sets_every_waypoint) try url.writer.writeAll("&waypoints=every");
    try writeAvoid(&url.writer, options, system_id);
    if (options.uses_ansiblex) try writeAvoidZones(&url.writer, options);
    return allocator.dupe(u8, url.written());
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

/// `body` is GET /ansiblex's answer; a gate at a system the map doesn't have is skipped; `arena` is scratch.
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

/// Leaves out the destination, which Eve Stars refuses in `avoid`; choosing it outranks the list.
fn writeAvoid(writer: *std.Io.Writer, options: *const RouteOptions, destination_id: u32) !void {
    var separator: []const u8 = "&avoid=";
    for (options.avoidIds()) |system_id| {
        if (system_id == destination_id) continue;
        try writer.print("{s}{d}", .{ separator, system_id });
        separator = ",";
    }
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
    try testing.expectEqualStrings(BASE_URL ++ "/route?to=30002187&send=98000001&security=shortest&bridges=false", url);
}

test "sendUrl lists every target in the one call" {
    const url = try sendUrl(testing.allocator, 30002187, &.{ 1, 2, 3 }, &.{ .preference = .Shorter, .uses_ansiblex = false });
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(BASE_URL ++ "/route?to=30002187&send=1,2,3&security=shortest&bridges=false", url);
}

test "sendUrl carries the route's options" {
    const url = try sendUrl(testing.allocator, 30002187, &.{98000001}, &.{ .preference = .LessSecure, .uses_ansiblex = true });
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(BASE_URL ++ "/route?to=30002187&send=98000001&security=unsafest&bridges=true", url);
}

test "sendUrl asks for every waypoint only when set to" {
    const url = try sendUrl(testing.allocator, 30002187, &.{98000001}, &.{ .preference = .Shorter, .uses_ansiblex = false, .sets_every_waypoint = true });
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(BASE_URL ++ "/route?to=30002187&send=98000001&security=shortest&bridges=false&waypoints=every", url);
}

test "sendUrl lists what to avoid, leaving out the destination itself" {
    var options: RouteOptions = .{ .preference = .Shorter, .uses_ansiblex = false };
    options.avoid(30002187);
    options.avoid(30005196);
    options.avoid(30000142);
    const url = try sendUrl(testing.allocator, 30002187, &.{98000001}, &options);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(BASE_URL ++ "/route?to=30002187&send=98000001&security=shortest&bridges=false&avoid=30005196,30000142", url);
}

test "sendUrl sends refused zones only with Ansiblex on" {
    var options: RouteOptions = .{ .preference = .Shorter, .uses_ansiblex = true, .avoids_zone = .{ true, false, false, false, true } };
    const with_gates = try sendUrl(testing.allocator, 1, &.{2}, &options);
    defer testing.allocator.free(with_gates);
    try testing.expectEqualStrings(BASE_URL ++ "/route?to=1&send=2&security=shortest&bridges=true&avoidZones=1,5", with_gates);

    options.uses_ansiblex = false;
    const without_gates = try sendUrl(testing.allocator, 1, &.{2}, &options);
    defer testing.allocator.free(without_gates);
    try testing.expectEqualStrings(BASE_URL ++ "/route?to=1&send=2&security=shortest&bridges=false", without_gates);
}

test "a route's avoid list stops at its size" {
    var options: RouteOptions = .{ .preference = .Shorter, .uses_ansiblex = false };
    for (0..types.MAX_AVOIDED_SYSTEMS + 1) |index| options.avoid(@intCast(index));
    try testing.expectEqual(@as(usize, types.MAX_AVOIDED_SYSTEMS), options.avoidIds().len);
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
