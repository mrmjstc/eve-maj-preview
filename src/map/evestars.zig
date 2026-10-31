//! Eve Stars' route API: its addresses, and what its answers mean to the Map Panel; no I/O.
const std = @import("std");
const universe = @import("universe.zig");
const utf8 = @import("../util/utf8.zig");
const log = @import("../log.zig");

const SystemIndex = universe.SystemIndex;
const slog = log.Scoped("map");

/// evestars.net answers 404 until the site leaves preview.
const BASE_URL = "https://preview.evestars.net/api/v1";
/// /search refuses a longer `q`.
pub const MAX_QUERY_LENGTH = 64;
pub const MAX_HITS = 8;
/// More groups and characters than this go unlisted.
pub const MAX_TARGETS = 64;
pub const MAX_TEXT_LENGTH = 160;
pub const NOTICE_MAX_LINES = 6;

pub const CHARACTERS_URL = BASE_URL ++ "/characters";

const FAILED_TO_REACH = "Couldn't reach Eve Stars";
const FAILED_TO_READ = "Couldn't read Eve Stars' answer";
const NO_ONE_ONLINE = "Nobody in this group is online";

/// A line of text that owns its bytes, cut to fit, so it can cross threads.
pub const Text = struct {
    bytes: [MAX_TEXT_LENGTH]u8 = undefined,
    length: usize = 0,

    pub fn print(comptime format: []const u8, args: anytype) Text {
        var text: Text = .{};
        var writer: std.Io.Writer = .fixed(&text.bytes);
        // A long line is cut, which the reader can see.
        writer.print(format, args) catch {};
        const written = writer.buffered();
        text.length = utf8.prefixLength(written, if (written.len == MAX_TEXT_LENGTH) MAX_TEXT_LENGTH - 1 else written.len);
        return text;
    }

    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.length];
    }
};

/// Why a call came to nothing, for the user to read.
pub const Failure = struct {
    text: Text,
    /// Null unless Eve Stars said to wait.
    retry_after_seconds: ?u32 = null,

    pub fn unreachedService() Failure {
        return .{ .text = .print(FAILED_TO_REACH, .{}) };
    }

    pub fn unreadableAnswer() Failure {
        return .{ .text = .print(FAILED_TO_READ, .{}) };
    }
};

/// What a search found, best first; wormhole systems aren't on the map, so they're left out.
pub const Hits = struct {
    systems: [MAX_HITS]SystemIndex = undefined,
    count: usize = 0,

    pub fn slice(self: *const Hits) []const SystemIndex {
        return self.systems[0..self.count];
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
};

/// Groups first, then the characters not known to be offline, in the account's order.
pub const Targets = struct {
    items: [MAX_TARGETS]Target = undefined,
    count: usize = 0,

    pub fn slice(self: *const Targets) []const Target {
        return self.items[0..self.count];
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
const HitRow = struct { id: u32 };
const SearchAnswer = struct { hits: []const HitRow = &.{} };
const CharacterRow = struct { id: u64, name: []const u8 = "", online: ?bool = null, canSend: bool = false, why: ?[]const u8 = null };
const GroupRow = struct { id: u64, name: []const u8 = "", characters: []const u64 = &.{} };
const CharactersAnswer = struct { characters: []const CharacterRow = &.{}, groups: []const GroupRow = &.{} };
const SentRow = struct { character: Place = .{}, set: bool = false, said: []const u8 = "" };
const SendAnswer = struct { to: Place = .{}, sent: []const SentRow = &.{} };
const ErrorAnswer = struct { @"error": []const u8 = "" };

/// Caller frees.
pub fn searchUrl(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    var url: std.Io.Writer.Allocating = .init(allocator);
    defer url.deinit();
    try url.writer.print(BASE_URL ++ "/search?kind=system&limit={d}&q=", .{MAX_HITS});
    for (query) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try url.writer.writeByte(char);
        } else {
            try url.writer.print("%{X:0>2}", .{char});
        }
    }
    return allocator.dupe(u8, url.written());
}

/// Leaves out `from`, so each character starts where it is; caller frees.
pub fn sendUrl(allocator: std.mem.Allocator, system_id: u32, target_id: u64) ![]u8 {
    return allocator.print(BASE_URL ++ "/route?to={d}&send={d}", .{ system_id, target_id });
}

/// The header's value; caller frees.
pub fn authorization(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    return allocator.print("Bearer {s}", .{std.mem.trim(u8, token, " \t\r\n")});
}

/// `body` is /search's answer; `arena` is scratch.
pub fn parseHits(arena: std.mem.Allocator, body: []const u8) !Hits {
    const answer = try parseAnswer(SearchAnswer, arena, body);
    var hits: Hits = .{};
    for (answer.hits) |row| {
        if (hits.count == MAX_HITS) break;
        hits.systems[hits.count] = universe.findSystemById(row.id) orelse continue;
        hits.count += 1;
    }
    return hits;
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

/// `body` is POST /route's answer, whose status says nothing of how each character fared; `arena` is scratch.
pub fn parseSend(arena: std.mem.Allocator, body: []const u8) !Notice {
    const answer = try parseAnswer(SendAnswer, arena, body);
    var set_count: usize = 0;
    for (answer.sent) |row| {
        if (row.set) set_count += 1;
    }

    // A group's misses are logged rather than shown, as a few are normal and they swamped the map.
    for (answer.sent) |row| {
        if (!row.set) slog.info("Eve Stars didn't set '{s}' for '{s}': {s}", .{ answer.to.name, row.character.name, row.said });
    }
    var notice: Notice = .{ .is_failure = set_count == 0 };
    notice.add(.print("{s}: set for {d} of {d}", .{ answer.to.name, set_count, answer.sent.len }));
    return notice;
}

/// A reply other than 200, in words; a status's meaning is promised, but `error`'s wording isn't, so it's only passed on.
pub fn failureOf(arena: std.mem.Allocator, status: u32, body: []const u8, retry_after_seconds: ?u32) Failure {
    const text: Text = switch (status) {
        401 => .print("Eve Stars refused the token: make a new one in its Pilot section", .{}),
        403 => .print("Eve Stars has withdrawn this account's access", .{}),
        429 => .print("Too many calls to Eve Stars: try again shortly", .{}),
        503 => .print("Eve Stars can't send routes right now", .{}),
        else => if (reasonOf(arena, body)) |reason| .print("{s}", .{reason}) else .print("Eve Stars answered {d}", .{status}),
    };
    return .{ .text = text, .retry_after_seconds = retry_after_seconds };
}

/// Null for a body that doesn't give one, as the status still says it failed; borrows from `arena`.
fn reasonOf(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const answer = parseAnswer(ErrorAnswer, arena, body) catch |err| {
        slog.debug("No reason in Eve Stars' answer: {}", .{err});
        return null;
    };
    return if (answer.@"error".len > 0) answer.@"error" else null;
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

test "searchUrl asks for systems and encodes what the user typed" {
    const url = try searchUrl(testing.allocator, "c-j6 &x");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(BASE_URL ++ "/search?kind=system&limit=8&q=c%2Dj6%20%26x", url);
}

test "sendUrl leaves out the start, so each character sets off from where it is" {
    const url = try sendUrl(testing.allocator, 30002187, 98000001);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(BASE_URL ++ "/route?to=30002187&send=98000001", url);
}

test "authorization drops whitespace pasted with the token" {
    const header = try authorization(testing.allocator, "  evestars_abc\r\n");
    defer testing.allocator.free(header);
    try testing.expectEqualStrings("Bearer evestars_abc", header);
}

test "parseHits keeps systems on the map and skips the rest" {
    var arena = testArena();
    defer arena.deinit();
    const hits = try parseHits(arena.allocator(), "{\"q\":\"x\",\"hits\":[{\"id\":31000005,\"name\":\"J100001\",\"kind\":\"system\",\"region\":null,\"lookalike\":null},{\"id\":30000142,\"name\":\"Jita\",\"kind\":\"system\",\"region\":\"The Forge\",\"security\":0.9,\"lookalike\":null}]}");
    try testing.expectEqual(@as(usize, 1), hits.count);
    try testing.expectEqualStrings("Jita", universe.systemName(hits.slice()[0]));
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

test "failureOf words what a status means, and passes on a 400's reason" {
    var arena = testArena();
    defer arena.deinit();
    const refused = failureOf(arena.allocator(), 401, "{\"error\":\"whatever\"}", null);
    try testing.expectEqualStrings("Eve Stars refused the token: make a new one in its Pilot section", refused.text.slice());
    const bad = failureOf(arena.allocator(), 400, "{\"error\":\"No such group.\"}", null);
    try testing.expectEqualStrings("No such group.", bad.text.slice());
    const unreadable = failureOf(arena.allocator(), 500, "<html>", null);
    try testing.expectEqualStrings("Eve Stars answered 500", unreadable.text.slice());
}

test "a long line is cut to fit" {
    const long: [MAX_TEXT_LENGTH * 2]u8 = @splat('x');
    try testing.expectEqual(MAX_TEXT_LENGTH - 1, Text.print("{s}", .{&long}).length);
}
