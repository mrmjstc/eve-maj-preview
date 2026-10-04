//! What EVE's log lines and file names say, with no I/O.
const std = @import("std");
const gamelog_events = @import("../notifications/gamelog_events.zig");

/// Longer lines are dropped; combat lines with colour tags run to 2-3KB.
pub const MAX_LINE_LENGTH = 4000;
const LOCAL_CHANGE = "EVE System > Channel changed to Local";
const JUMP = "Jumping from ";
const UNDOCK = "Undocking from ";

pub const SystemSource = enum { chatlog, jump, undock, conduit };

/// `system` borrows from the parsed line.
pub const SystemChange = struct { system: []const u8, source: SystemSource };

pub const Activity = enum { event, mining, bounty };

pub const GameLine = struct {
    system: ?SystemChange = null,
    activity: ?Activity = null,
};

/// With its line's timestamp, so chatlog and gamelog finds can be compared for recency.
pub const SystemMatch = struct {
    /// Borrows from the scanned text.
    system: []const u8,
    /// See lineTimestamp; 0 if it couldn't be read.
    event_ts: u64,
};

/// Joins lines split across reads, holding a trailing incomplete one until its newline arrives.
pub const LineAssembler = struct {
    partial: std.ArrayList(u8) = .empty,
    /// Set once a held line outgrows max_len; the rest of it is dropped up to its newline.
    skipping: bool = false,
    max_len: usize = MAX_LINE_LENGTH,

    pub fn deinit(self: *LineAssembler, allocator: std.mem.Allocator) void {
        self.partial.deinit(allocator);
    }

    pub fn reset(self: *LineAssembler) void {
        self.partial.clearRetainingCapacity();
        self.skipping = false;
    }

    /// Calls `handler.onLine` per complete line, valid only during the call, and `handler.onLongLine` per line too long to keep.
    pub fn feed(self: *LineAssembler, allocator: std.mem.Allocator, text: []const u8, handler: anytype) !void {
        var rest = text;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |newline| {
            const piece = rest[0..newline];
            rest = rest[newline + 1 ..];
            if (self.partial.items.len == 0 and !self.skipping) {
                handler.onLine(piece);
                continue;
            }
            try self.hold(allocator, piece, handler);
            if (!self.skipping) handler.onLine(self.partial.items);
            self.reset();
        }
        if (rest.len > 0) try self.hold(allocator, rest, handler);
    }

    fn hold(self: *LineAssembler, allocator: std.mem.Allocator, bytes: []const u8, handler: anytype) !void {
        if (self.skipping) return;
        if (self.partial.items.len + bytes.len > self.max_len) {
            handler.onLongLine(self.partial.items.len + bytes.len);
            self.partial.clearRetainingCapacity();
            self.skipping = true;
            return;
        }
        try self.partial.appendSlice(allocator, bytes);
    }
};

/// "[ time ] EVE System > Channel changed to Local : Jita" gives "Jita"; a player typing the same text doesn't match.
pub fn parseChatLine(line: []const u8) ?[]const u8 {
    const stamped = std.mem.trimStart(u8, line, "\u{FEFF}");
    if (!std.mem.startsWith(u8, stamped, "[ ")) return null;
    const close = std.mem.indexOf(u8, stamped, " ] ") orelse return null;
    const message = stamped[close + " ] ".len ..];
    if (!std.mem.startsWith(u8, message, LOCAL_CHANGE)) return null;
    return localSystem(message);
}

/// Dispatches on the message's first characters, so each line is scanned once.
pub fn parseGameLine(line: []const u8) GameLine {
    const close = std.mem.indexOf(u8, line, "] ") orelse return .{};
    const message = line[close + 2 ..];
    if (message.len < 2) return .{};

    // EVE tags jumps and undocks "(None)"; untagged ones are accepted too.
    const untagged = if (std.mem.startsWith(u8, message, "(None) ")) message["(None) ".len..] else message;
    if (std.mem.startsWith(u8, untagged, JUMP)) {
        const system = jumpDestination(untagged) orelse return .{};
        return .{ .system = .{ .system = system, .source = .jump } };
    }
    if (std.mem.startsWith(u8, untagged, UNDOCK)) {
        const system = undockDestination(untagged) orelse return .{ .activity = .event };
        // Still an event too, since undocks raised a generic notification before they were parsed.
        return .{ .system = .{ .system = system, .source = .undock }, .activity = .event };
    }

    if (message[0] != '(') return .{};
    const tag = message[0 .. (std.mem.indexOfScalar(u8, message, ')') orelse return .{}) + 1];
    if (std.mem.eql(u8, tag, "(notify)")) {
        // A conduit jump moves the character as well as showing a notification.
        const conduit: ?SystemChange = if (gamelog_events.conduitDestination(line)) |system| .{ .system = system, .source = .conduit } else null;
        return .{ .system = conduit, .activity = .event };
    }
    if (std.mem.eql(u8, tag, "(question)") or std.mem.eql(u8, tag, "(combat)") or std.mem.eql(u8, tag, "(None)")) return .{ .activity = .event };
    if (std.mem.eql(u8, tag, "(mining)")) return .{ .activity = .mining };
    if (std.mem.eql(u8, tag, "(bounty)")) return .{ .activity = .bounty };
    return .{};
}

/// `text` starts at "EVE System > Channel changed to Local"; the system follows the colon.
fn localSystem(text: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    return nonEmpty(untilLineEnd(text[colon + 1 ..]));
}

/// `text` starts at "Jumping from A to B".
fn jumpDestination(text: []const u8) ?[]const u8 {
    const to = std.mem.indexOf(u8, text, " to ") orelse return null;
    return nonEmpty(untilLineEnd(text[to + " to ".len ..]));
}

/// The last " to ", since a station's name can contain one.
fn undockDestination(text: []const u8) ?[]const u8 {
    const line = untilLineEnd(text);
    const to = std.mem.lastIndexOf(u8, line, " to ") orelse return null;
    var system = std.mem.trimEnd(u8, line[to + " to ".len ..], ". ");
    if (std.mem.endsWith(u8, system, " solar system")) system = system[0 .. system.len - " solar system".len];
    return nonEmpty(std.mem.trim(u8, system, " \t"));
}

fn untilLineEnd(text: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, text, "\r\n\x00") orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t");
}

fn nonEmpty(text: []const u8) ?[]const u8 {
    return if (text.len == 0) null else text;
}

/// The latest genuine Local change, skipping any a player typed.
pub fn lastSystemInChat(text: []const u8) ?SystemMatch {
    var end = text.len;
    while (std.mem.lastIndexOf(u8, text[0..end], LOCAL_CHANGE)) |pos| {
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..pos], '\n')) |newline| newline + 1 else 0;
        if (parseChatLine(text[line_start..])) |system| return .{ .system = system, .event_ts = lineTimestamp(text, pos) };
        end = line_start;
    }
    return null;
}

/// Whichever of jump and undock is later, skipping a line cut off before its timestamp.
pub fn lastSystemInGame(text: []const u8) ?SystemMatch {
    var end = text.len;
    while (true) {
        const jump = std.mem.lastIndexOf(u8, text[0..end], JUMP);
        const undock = std.mem.lastIndexOf(u8, text[0..end], UNDOCK);
        const use_jump = if (jump) |j| (if (undock) |u| j > u else true) else false;
        const pos = (if (use_jump) jump else undock) orelse return null;
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..pos], '\n')) |newline| newline + 1 else 0;
        if (isTimestampPrefix(text[line_start..pos])) {
            const system = (if (use_jump) jumpDestination(text[pos..]) else undockDestination(text[pos..])) orelse return null;
            return .{ .system = system, .event_ts = lineTimestamp(text, pos) };
        }
        end = line_start;
    }
}

/// "[ time ] ", optionally followed by EVE's "(None) " tag.
fn isTimestampPrefix(prefix: []const u8) bool {
    const stamped = std.mem.trimStart(u8, prefix, "\u{FEFF}");
    if (!std.mem.startsWith(u8, stamped, "[ ")) return false;
    const close = std.mem.indexOf(u8, stamped, " ] ") orelse return false;
    const rest = stamped[close + " ] ".len ..];
    return rest.len == 0 or std.mem.eql(u8, rest, "(None) ");
}

/// YYYYMMDDHHMMSS, or 0; looks only 64 bytes back, so a chunk cut mid-line can't borrow an earlier line's bracket.
pub fn lineTimestamp(text: []const u8, pos: usize) u64 {
    const window_start = pos -| 64;
    const open = window_start + (std.mem.lastIndexOfScalar(u8, text[window_start..pos], '[') orelse return 0);
    const close = std.mem.indexOfScalarPos(u8, text, open, ']') orelse return 0;
    const inner = std.mem.trim(u8, text[open + 1 .. close], " \t");

    if (inner.len < 19) return 0;
    if (inner[4] != '.' or inner[7] != '.' or inner[10] != ' ' or inner[13] != ':' or inner[16] != ':') return 0;

    const year = std.fmt.parseInt(u64, inner[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(u64, inner[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(u64, inner[8..10], 10) catch return 0;
    const hour = std.fmt.parseInt(u64, inner[11..13], 10) catch return 0;
    const minute = std.fmt.parseInt(u64, inner[14..16], 10) catch return 0;
    const second = std.fmt.parseInt(u64, inner[17..19], 10) catch return 0;
    return (year * 10000 + month * 100 + day) * 1000000 + (hour * 10000 + minute * 100 + second);
}

/// YYYYMMDDHHMMSS from "[Local_]YYYYMMDD_HHMMSS[_<id>].txt", or 0 for any other name, such as a sync client's conflict copy.
pub fn logFileTimestamp(file_name: []const u8, is_chatlog: bool) u64 {
    if (!std.mem.endsWith(u8, file_name, ".txt")) return 0;
    var stamp = withoutTxt(file_name);
    if (is_chatlog) {
        if (!std.mem.startsWith(u8, stamp, "Local_")) return 0;
        stamp = stamp["Local_".len..];
    }
    if (stamp.len < 15 or stamp[8] != '_') return 0;
    if (stamp.len > 15 and (stamp[15] != '_' or characterIdFromFileName(stamp) == null)) return 0;
    const date = std.fmt.parseInt(u64, stamp[0..8], 10) catch return 0;
    const time = std.fmt.parseInt(u64, stamp[9..15], 10) catch return 0;
    return date * 1000000 + time;
}

/// UTC Unix seconds for a logFileTimestamp; null for 0 or an impossible date.
pub fn logTimestampToUnixSeconds(ts: u64) ?i64 {
    const date: i64 = @intCast(ts / 1000000);
    const time: i64 = @intCast(ts % 1000000);
    const year = @divTrunc(date, 10000);
    const month = @mod(@divTrunc(date, 100), 100);
    const day = @mod(date, 100);
    const hour = @divTrunc(time, 10000);
    const minute = @mod(@divTrunc(time, 100), 100);
    const second = @mod(time, 100);
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59) return null;

    // Howard Hinnant's days_from_civil.
    const march_year = if (month <= 2) year - 1 else year;
    const era = @divFloor(march_year, 400);
    const year_of_era = march_year - era * 400;
    const day_of_year = @divTrunc(153 * @mod(month + 9, 12) + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100) + day_of_year;
    const days = era * 146097 + day_of_era - 719468;
    return days * std.time.s_per_day + hour * std.time.s_per_hour + minute * std.time.s_per_min + second;
}

pub fn characterIdFromFileName(file_name: []const u8) ?[]const u8 {
    const name = withoutTxt(file_name);
    const underscore = std.mem.lastIndexOfScalar(u8, name, '_') orelse return null;
    const id = name[underscore + 1 ..];
    if (id.len < 8 or id.len > 13) return null;
    for (id) |c| if (!std.ascii.isDigit(c)) return null;
    return id;
}

fn withoutTxt(file_name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, file_name, ".txt")) file_name[0 .. file_name.len - ".txt".len] else file_name;
}

pub fn listenerName(header: []const u8) ?[]const u8 {
    const needle = "Listener:";
    const pos = std.mem.indexOf(u8, header, needle) orelse return null;
    return nonEmpty(untilLineEnd(header[pos + needle.len ..]));
}

const testing = std.testing;

test "parseChatLine reads the system from a Local channel change" {
    try testing.expectEqualStrings("Jita", parseChatLine("\u{FEFF}[ 2026.09.21 21:10:31 ] EVE System > Channel changed to Local : Jita").?);
    try testing.expect(parseChatLine("[ 2026.09.21 21:10:31 ] Someone > Channel changed to Local : Jita") == null);
}

test "parseChatLine ignores a Local change typed by a player" {
    try testing.expect(parseChatLine("\u{FEFF}[ 2026.09.21 21:10:31 ] Some Pilot > EVE System > Channel changed to Local : Jita") == null);
    try testing.expect(parseChatLine("\u{FEFF}[ 2026.09.21 21:10:31 ] Some Pilot > [ 2099.01.01 00:00:00 ] EVE System > Channel changed to Local : Jita") == null);
}

test "parseGameLine reads EVE's (None) jump lines and untagged ones" {
    const tagged = parseGameLine("[ 2026.09.05 01:16:08 ] (None) Jumping from C-J6MT to 8-WYQZ");
    try testing.expectEqualStrings("8-WYQZ", tagged.system.?.system);
    try testing.expectEqual(SystemSource.jump, tagged.system.?.source);
    try testing.expect(tagged.activity == null);

    try testing.expectEqualStrings("Rancer", parseGameLine("[ 2026.09.29 00:15:23 ] Jumping from Amarr to Rancer").system.?.system);
}

test "parseGameLine reads the system from EVE's undock line" {
    const line = parseGameLine("[ 2026.09.20 23:26:36 ] (None) Undocking from Floseswin VIII - Moon 2 - TransStellar Shipping Storage to Floseswin solar system.");
    try testing.expectEqualStrings("Floseswin", line.system.?.system);
    try testing.expectEqual(SystemSource.undock, line.system.?.source);
    try testing.expectEqual(Activity.event, line.activity.?);
}

test "parseGameLine routes activity lines by type" {
    try testing.expectEqual(Activity.mining, parseGameLine("[ 2026.08.09 23:45:29 ] (mining) <color=0x77ffffff>You mined <b>1</b> units of Dark Glitter").activity.?);
    try testing.expectEqual(Activity.bounty, parseGameLine("[ 2026.09.17 19:28:07 ] (bounty) <b>120,272 ISK</b> added to next bounty payout").activity.?);
    try testing.expectEqual(Activity.event, parseGameLine("[ 2026.09.17 19:28:06 ] (combat) <b>484</b> from Gist Seraphim - Heavy Missile - Hits").activity.?);
    try testing.expectEqual(Activity.event, parseGameLine("[ 2026.09.06 16:13:00 ] (question) Someone wants you to join their fleet, do you accept?").activity.?);
    const hint = parseGameLine("[ 2026.09.06 23:07:39 ] (hint) Attempting to join a channel");
    try testing.expect(hint.activity == null and hint.system == null);
}

test "parseGameLine treats a conduit notify as a move and an event" {
    const line = parseGameLine("[ 2026.09.06 16:13:01 ] (notify) The Conduit Field jumps you to Ahbazon.");
    try testing.expectEqualStrings("Ahbazon", line.system.?.system);
    try testing.expectEqual(SystemSource.conduit, line.system.?.source);
    try testing.expectEqual(Activity.event, line.activity.?);
}

test "lineTimestamp reads the bracketed time before a position" {
    const line = "[ 2026.09.21 21:10:31 ] EVE System > Channel changed to Local : Jita";
    try testing.expectEqual(@as(u64, 20260921211031), lineTimestamp(line, std.mem.indexOf(u8, line, "EVE").?));
    try testing.expectEqual(@as(u64, 0), lineTimestamp("no bracket here", 10));
}

test "lastSystemInGame picks whichever of jump and undock came last" {
    const text =
        \\[ 2026.09.05 01:16:08 ] (None) Jumping from C-J6MT to 8-WYQZ
        \\[ 2026.09.20 23:26:36 ] (None) Undocking from Some Station to Floseswin solar system.
        \\
    ;
    const found = lastSystemInGame(text).?;
    try testing.expectEqualStrings("Floseswin", found.system);
    try testing.expectEqual(@as(u64, 20260920232636), found.event_ts);
    try testing.expectEqualStrings("8-WYQZ", lastSystemInGame(text[0..std.mem.indexOfScalar(u8, text, '\n').?]).?.system);
}

test "lastSystemInGame skips a jump whose line was cut before its timestamp" {
    try testing.expect(lastSystemInGame("6.09.05 01:16:08 ] (None) Jumping from C-J6MT to 8-WYQZ\r\n[ 2026.09.05 01:16:20 ] (combat) 25 from Some Rat - Hits\r\n") == null);
}

test "lastSystemInChat picks the latest Local change" {
    const text =
        \\[ 2026.09.21 21:10:31 ] EVE System > Channel changed to Local : Jita
        \\[ 2026.09.21 21:10:37 ] EVE System > Channel changed to Local : Perimeter
        \\
    ;
    try testing.expectEqualStrings("Perimeter", lastSystemInChat(text).?.system);
}

test "a system name stops at the zeros of a damaged log's end" {
    const text = "[ 2026.09.21 21:10:37 ] EVE System > Channel changed to Local : Perimeter" ++ "\x00" ** 32;
    try testing.expectEqualStrings("Perimeter", lastSystemInChat(text).?.system);
    try testing.expectEqualStrings("Perimeter", parseChatLine(text).?);
}

test "lastSystemInChat skips Local changes typed by a player" {
    const text =
        \\[ 2026.09.21 21:10:37 ] EVE System > Channel changed to Local : Perimeter
        \\[ 2026.09.21 21:11:02 ] Some Pilot > EVE System > Channel changed to Local : Jita
        \\[ 2026.09.21 21:11:05 ] Some Pilot > [ 2099.01.01 00:00:00 ] EVE System > Channel changed to Local : Amarr
        \\
    ;
    const found = lastSystemInChat(text).?;
    try testing.expectEqualStrings("Perimeter", found.system);
    try testing.expectEqual(@as(u64, 20260921211037), found.event_ts);
}

test "logFileTimestamp and characterIdFromFileName read EVE's log names" {
    try testing.expectEqual(@as(u64, 20260906230739), logFileTimestamp("Local_20260906_230739_1351059806.txt", true));
    try testing.expectEqual(@as(u64, 20260906230739), logFileTimestamp("20260906_230739_1351059806.txt", false));
    try testing.expectEqual(@as(u64, 0), logFileTimestamp("Corp_20260906_230739_1351059806.txt", true));
    try testing.expectEqualStrings("1351059806", characterIdFromFileName("Local_20260906_230739_1351059806.txt").?);
    try testing.expect(characterIdFromFileName("20260906_230739.txt") == null);
}

test "logFileTimestamp rejects names EVE didn't write" {
    try testing.expectEqual(@as(u64, 0), logFileTimestamp("20261002_173212_912054032 (# Edit conflict 2026-10-02 74s5jzC #).txt", false));
    try testing.expectEqual(@as(u64, 0), logFileTimestamp("20261002_173212_912054032 (1).txt", false));
    try testing.expectEqual(@as(u64, 0), logFileTimestamp("Local_20261002_173212_912054032 - Copy.txt", true));
    try testing.expectEqual(@as(u64, 0), logFileTimestamp("20261002_173212_912054032.txt.bak", false));
}

test "logTimestampToUnixSeconds reads EVE's UTC log timestamps" {
    try testing.expectEqual(@as(?i64, 0), logTimestampToUnixSeconds(19700101000000));
    try testing.expectEqual(@as(?i64, 1788736059), logTimestampToUnixSeconds(20260906230739));
    try testing.expectEqual(@as(?i64, 951825600), logTimestampToUnixSeconds(20000229120000));
    try testing.expectEqual(@as(?i64, 1735689599), logTimestampToUnixSeconds(20241231235959));
}

test "logTimestampToUnixSeconds rejects 0 and impossible times" {
    try testing.expectEqual(@as(?i64, null), logTimestampToUnixSeconds(0));
    try testing.expectEqual(@as(?i64, null), logTimestampToUnixSeconds(20261301000000));
    try testing.expectEqual(@as(?i64, null), logTimestampToUnixSeconds(20260906240000));
}

test "listenerName reads gamelog and chatlog headers" {
    try testing.expectEqualStrings("Test Client 10", listenerName("  Gamelog\r\n  Listener: Test Client 10\r\n  Session Started: 2026.09.06").?);
    try testing.expectEqualStrings("Test Client 10", listenerName("          Channel Name:    Local\n          Listener:        Test Client 10\n").?);
}

const Collector = struct {
    lines: *std.ArrayList([]const u8),
    long_lines: *usize,

    fn onLine(self: Collector, line: []const u8) void {
        self.lines.append(testing.allocator, testing.allocator.dupe(u8, line) catch unreachable) catch unreachable;
    }

    fn onLongLine(self: Collector, _: usize) void {
        self.long_lines.* += 1;
    }
};

fn freeLines(lines: *std.ArrayList([]const u8)) void {
    for (lines.items) |line| testing.allocator.free(line);
    lines.deinit(testing.allocator);
}

test "LineAssembler joins a line split across reads" {
    var lines: std.ArrayList([]const u8) = .empty;
    defer freeLines(&lines);
    var long_lines: usize = 0;
    const collector: Collector = .{ .lines = &lines, .long_lines = &long_lines };
    var assembler: LineAssembler = .{};
    defer assembler.deinit(testing.allocator);

    try assembler.feed(testing.allocator, "first\nsec", collector);
    try assembler.feed(testing.allocator, "ond half\nthi", collector);
    try assembler.feed(testing.allocator, "rd\n", collector);
    try testing.expectEqual(@as(usize, 3), lines.items.len);
    try testing.expectEqualStrings("first", lines.items[0]);
    try testing.expectEqualStrings("second half", lines.items[1]);
    try testing.expectEqualStrings("third", lines.items[2]);
}

test "LineAssembler keeps a long line split across reads whole" {
    var lines: std.ArrayList([]const u8) = .empty;
    defer freeLines(&lines);
    var long_lines: usize = 0;
    const collector: Collector = .{ .lines = &lines, .long_lines = &long_lines };
    var assembler: LineAssembler = .{};
    defer assembler.deinit(testing.allocator);

    const long = "x" ** 3000;
    try assembler.feed(testing.allocator, long[0..1500], collector);
    try assembler.feed(testing.allocator, long[1500..] ++ "\n", collector);
    try testing.expectEqual(@as(usize, 1), lines.items.len);
    try testing.expectEqual(@as(usize, 3000), lines.items[0].len);
}

test "LineAssembler drops a line over its limit up to the next newline" {
    var lines: std.ArrayList([]const u8) = .empty;
    defer freeLines(&lines);
    var long_lines: usize = 0;
    const collector: Collector = .{ .lines = &lines, .long_lines = &long_lines };
    var assembler: LineAssembler = .{ .max_len = 8 };
    defer assembler.deinit(testing.allocator);

    try assembler.feed(testing.allocator, "12345", collector);
    try assembler.feed(testing.allocator, "67890", collector);
    try assembler.feed(testing.allocator, "abc\nok\n", collector);
    try testing.expectEqual(@as(usize, 1), long_lines);
    try testing.expectEqual(@as(usize, 1), lines.items.len);
    try testing.expectEqualStrings("ok", lines.items[0]);
}
