//! What crosses the game relay: its notices, join codes, and players' messages as raw bytes; no I/O.
const std = @import("std");

/// The relay seats only players sending the same one; bump it whenever players' messages change (1 was Pong, 2 Tanks, 3 Barrage).
pub const PROTOCOL_VERSION = 3;
pub const CODE_LENGTH = 6;
/// Leaves out 0/O and 1/I/L, which read alike; the relay's alphabet must match.
pub const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
/// The relay drops a binary frame any longer.
pub const MAX_MESSAGE_BYTES = 64;
/// Players in one room, the host included; the relay's limit must match.
pub const MAX_SEATS = 6;

pub const Code = [CODE_LENGTH]u8;

/// The host is seat 0 and guests take the lowest free seat above it.
pub const Seat = u8;

/// A player's message as another player sent it, for the game to decode; check every byte, since it comes from another machine.
pub const Message = struct {
    sender: Seat,
    buf: [MAX_MESSAGE_BYTES]u8,
    length: u8,

    /// A frame as the relay passes it on: the sender's seat, then their bytes.
    pub fn fromFrame(frame: []const u8) !Message {
        if (frame.len == 0) return error.MissingSender;
        if (frame[0] >= MAX_SEATS) return error.InvalidSender;
        const bytes = frame[1..];
        if (bytes.len > MAX_MESSAGE_BYTES) return error.MessageTooLong;
        var message: Message = .{ .sender = frame[0], .buf = undefined, .length = @intCast(bytes.len) };
        @memcpy(message.buf[0..bytes.len], bytes);
        return message;
    }

    /// Borrows from the message.
    pub fn slice(self: *const Message) []const u8 {
        return self.buf[0..self.length];
    }
};

/// Why the relay turned a player away.
pub const Refusal = enum {
    /// No one is hosting that code, or the match on it has ended.
    not_found,
    /// Every seat on that code is taken.
    full,
    /// The host has already started the match.
    started,
    /// The other player runs a different protocol version.
    version,
    rate_limited,
    /// The code went unjoined too long.
    expired,
    unknown,
};

/// A notice from the relay itself, sent as a text frame of JSON.
pub const Notice = union(enum) {
    /// The host's code, to pass to guests; the host is seat 0.
    code: Code,
    /// This guest is in, in the seat it holds.
    welcome: Seat,
    /// Another guest is in.
    joined: Seat,
    /// A guest has gone, freeing its seat.
    left: Seat,
    /// The relay's answer to a keepalive while no one else is in.
    waiting,
    /// The host has gone, and the relay closes every socket.
    host_left,
    refused: Refusal,
};

/// Parses a relay text frame such as `{"type":"joined","seat":2}`; `allocator` is only used while parsing.
pub fn parseNotice(allocator: std.mem.Allocator, text: []const u8) !Notice {
    const Raw = struct {
        type: []const u8,
        code: ?[]const u8 = null,
        seat: ?i64 = null,
        reason: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(Raw, allocator, text, .{ .ignore_unknown_fields = true }) catch return error.InvalidNotice;
    defer parsed.deinit();
    const raw = parsed.value;
    if (std.mem.eql(u8, raw.type, "code")) return .{ .code = try normalizeCode(raw.code orelse return error.InvalidNotice) };
    if (std.mem.eql(u8, raw.type, "welcome")) return .{ .welcome = try parseSeat(raw.seat) };
    if (std.mem.eql(u8, raw.type, "joined")) return .{ .joined = try parseSeat(raw.seat) };
    if (std.mem.eql(u8, raw.type, "left")) return .{ .left = try parseSeat(raw.seat) };
    if (std.mem.eql(u8, raw.type, "waiting")) return .waiting;
    if (std.mem.eql(u8, raw.type, "host_left")) return .host_left;
    if (std.mem.eql(u8, raw.type, "refused")) return .{ .refused = std.meta.stringToEnum(Refusal, raw.reason orelse "") orelse .unknown };
    return error.InvalidNotice;
}

/// A code as typed or pasted, e.g. " k7q-x4m", in the relay's form.
pub fn normalizeCode(typed: []const u8) !Code {
    var code: Code = undefined;
    var length: usize = 0;
    for (typed) |char| {
        if (char == ' ' or char == '-' or char == '\t') continue;
        const upper = std.ascii.toUpper(char);
        if (std.mem.indexOfScalar(u8, CODE_ALPHABET, upper) == null) return error.InvalidCode;
        if (length == CODE_LENGTH) return error.InvalidCode;
        code[length] = upper;
        length += 1;
    }
    if (length != CODE_LENGTH) return error.InvalidCode;
    return code;
}

/// A guest's seat; the host's is never announced.
fn parseSeat(seat: ?i64) !Seat {
    const value = seat orelse return error.InvalidNotice;
    if (value < 1 or value >= MAX_SEATS) return error.InvalidNotice;
    return @intCast(value);
}

const testing = std.testing;

test "a frame splits into its sender's seat and their bytes" {
    const message = try Message.fromFrame(&.{ 2, 1, 2, 3 });
    try testing.expectEqual(@as(Seat, 2), message.sender);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, message.slice());
}

test "a frame with no sender, a seat past the last, or too many bytes is refused" {
    try testing.expectError(error.MissingSender, Message.fromFrame(&.{}));
    try testing.expectError(error.InvalidSender, Message.fromFrame(&.{MAX_SEATS}));
    const frame: [MAX_MESSAGE_BYTES + 2]u8 = @splat(0);
    try testing.expectError(error.MessageTooLong, Message.fromFrame(&frame));
}

test "a code typed in lower case with a dash and spaces is normalized" {
    try testing.expectEqualStrings("K7QX4M", &try normalizeCode(" k7q-x4m "));
}

test "a code with a look-alike character or the wrong length is refused" {
    try testing.expectError(error.InvalidCode, normalizeCode("K7QX4O"));
    try testing.expectError(error.InvalidCode, normalizeCode("K7QX4"));
    try testing.expectError(error.InvalidCode, normalizeCode("K7QX4MM"));
}

test "the relay's notices are parsed" {
    try testing.expectEqualStrings("ABCDEF", &(try parseNotice(testing.allocator, "{\"type\":\"code\",\"code\":\"ABCDEF\"}")).code);
    try testing.expectEqual(@as(Seat, 3), (try parseNotice(testing.allocator, "{\"type\":\"joined\",\"seat\":3}")).joined);
    try testing.expectEqual(Notice.host_left, try parseNotice(testing.allocator, "{\"type\":\"host_left\"}"));
    try testing.expectError(error.InvalidNotice, parseNotice(testing.allocator, "{\"type\":\"welcome\",\"seat\":0}"));
    try testing.expectEqual(Refusal.full, (try parseNotice(testing.allocator, "{\"type\":\"refused\",\"reason\":\"full\"}")).refused);
    try testing.expectEqual(Refusal.unknown, (try parseNotice(testing.allocator, "{\"type\":\"refused\",\"reason\":\"new\"}")).refused);
    try testing.expectError(error.InvalidNotice, parseNotice(testing.allocator, "{\"type\":\"bogus\"}"));
}
