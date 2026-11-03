//! What Barrage's players send each other through the relay, and decoding that trusts no byte of it; no I/O.
const std = @import("std");
const wire = @import("../multiplayer/wire.zig");
const game = @import("game.zig");

/// The most a lobby can ask for; anything more is refused as malformed.
pub const MAX_ROUNDS = 20;
/// EVE's longest character name.
pub const MAX_NAME_CHARACTERS = 37;
/// What a relay frame has left after a pilot message's tag, seat, style and name length.
pub const MAX_NAME_BYTES = wire.MAX_MESSAGE_BYTES - 4;

/// Who plays a seat; `human` is the player the relay put there.
pub const SeatKind = enum(u8) { empty, human, ai_easy, ai_normal, ai_hard };

pub const Lobby = struct {
    /// By relay seat, the host's first.
    seats: [wire.MAX_SEATS]SeatKind,
    round_count: u8,
};

/// A pilot's chosen name; empty for the default.
pub const PilotName = struct {
    /// Zeroed past `length`, so equal names compare equal whole.
    bytes: [MAX_NAME_BYTES]u8 = @splat(0),
    length: u8 = 0,

    /// Trimmed of spaces; refused if too long or holding control characters or broken UTF-8.
    pub fn fromText(text: []const u8) !PilotName {
        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len > MAX_NAME_BYTES) return error.NameTooLong;
        if (!isPrintable(trimmed)) return error.InvalidName;
        if (characterCount(trimmed) > MAX_NAME_CHARACTERS) return error.NameTooLong;
        var name: PilotName = .{ .length = @intCast(trimmed.len) };
        @memcpy(name.bytes[0..trimmed.len], trimmed);
        return name;
    }

    /// Borrows from the name.
    pub fn slice(self: *const PilotName) []const u8 {
        return self.bytes[0..self.length];
    }

    pub fn eql(self: *const PilotName, other: *const PilotName) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

/// How a pilot's tank is drawn; every style has the same hitbox.
pub const TankStyle = enum(u8) { standard, heavy, scout, hover, walker, classic };

/// What a pilot chose for themselves.
pub const Pilot = struct {
    seat: wire.Seat,
    tank_style: TankStyle,
    name: PilotName,
};

pub const Start = struct {
    /// Every player builds the same match from it.
    seed: u64,
    lobby: Lobby,
};

pub const Aim = struct {
    round: u8,
    /// game.Game's turn when the shot is taken.
    turn: u16,
    shot: game.Shot,
    weapon: game.Weapon,
};

pub const Fired = struct {
    aim: Aim,
    /// The shooter's game.stateHash just before firing.
    state_hash: u32,
};

pub const Message = union(enum(u8)) {
    /// Keeps the relay's sockets from timing out.
    keepalive,
    /// Host only: who sits where, sent whenever that changes.
    lobby: Lobby,
    /// Host only.
    start: Start,
    /// The player whose turn it is, turning the barrel; only shown.
    aim: Aim,
    fired: Fired,
    /// Host only: on from the end of this round.
    next_round: u8,
    /// Host only: the same players again from round 1.
    restart,
    /// A pilot's own choices, or any seat's from the host, which repeats them all for each guest who joins.
    pilot: Pilot,
};

/// One message's bytes; a pilot with the longest name fills the relay's limit exactly.
pub const Encoded = struct {
    buf: [wire.MAX_MESSAGE_BYTES]u8 = undefined,
    length: usize = 0,

    /// Borrows from the encoded message.
    pub fn slice(self: *const Encoded) []const u8 {
        return self.buf[0..self.length];
    }

    fn int(self: *Encoded, comptime T: type, value: T) void {
        std.mem.writeInt(T, self.buf[self.length..][0..@sizeOf(T)], value, .little);
        self.length += @sizeOf(T);
    }

    fn float(self: *Encoded, value: f32) void {
        self.int(u32, @bitCast(value));
    }

    fn lobby(self: *Encoded, value: Lobby) void {
        for (value.seats) |seat| self.int(u8, @backingInt(seat));
        self.int(u8, value.round_count);
    }

    fn pilot(self: *Encoded, value: Pilot) void {
        self.int(u8, value.seat);
        self.int(u8, @backingInt(value.tank_style));
        self.int(u8, value.name.length);
        @memcpy(self.buf[self.length..][0..value.name.length], value.name.slice());
        self.length += value.name.length;
    }

    fn aim(self: *Encoded, value: Aim) void {
        self.int(u8, value.round);
        self.int(u16, value.turn);
        self.float(value.shot.angle_degrees);
        self.float(value.shot.power);
        self.int(u8, @backingInt(value.weapon));
    }
};

const Reader = struct {
    bytes: []const u8,
    index: usize = 0,

    fn int(self: *Reader, comptime T: type) !T {
        if (self.bytes.len - self.index < @sizeOf(T)) return error.MessageTooShort;
        const value = std.mem.readInt(T, self.bytes[self.index..][0..@sizeOf(T)], .little);
        self.index += @sizeOf(T);
        return value;
    }

    /// Refuses NaN, the infinities, and anything outside `min` to `max`.
    fn float(self: *Reader, min: f32, max: f32) !f32 {
        const value: f32 = @bitCast(try self.int(u32));
        if (!std.math.isFinite(value) or value < min or value > max) return error.InvalidValue;
        return value;
    }

    fn enumValue(self: *Reader, comptime E: type) !E {
        return std.enums.fromInt(E, try self.int(u8)) orelse error.InvalidValue;
    }

    fn lobby(self: *Reader) !Lobby {
        var value: Lobby = undefined;
        for (&value.seats) |*seat| seat.* = try self.enumValue(SeatKind);
        value.round_count = try self.int(u8);
        if (value.round_count < 1 or value.round_count > MAX_ROUNDS) return error.InvalidValue;
        return value;
    }

    fn pilot(self: *Reader) !Pilot {
        const seat = try self.int(u8);
        if (seat >= wire.MAX_SEATS) return error.InvalidValue;
        const tank_style = try self.enumValue(TankStyle);
        const length = try self.int(u8);
        if (length > MAX_NAME_BYTES) return error.InvalidValue;
        if (self.bytes.len - self.index < length) return error.MessageTooShort;
        const bytes = self.bytes[self.index..][0..length];
        self.index += length;
        // Exactly as sent: a name with spaces around it is malformed rather than trimmed.
        if (!isPrintable(bytes) or std.mem.trim(u8, bytes, " ").len != bytes.len) return error.InvalidValue;
        if (characterCount(bytes) > MAX_NAME_CHARACTERS) return error.InvalidValue;
        var value: Pilot = .{ .seat = seat, .tank_style = tank_style, .name = .{ .length = length } };
        @memcpy(value.name.bytes[0..length], bytes);
        return value;
    }

    fn aim(self: *Reader) !Aim {
        return .{
            .round = try self.int(u8),
            .turn = try self.int(u16),
            .shot = .{ .angle_degrees = try self.float(0, 180), .power = try self.float(0, game.MAX_POWER) },
            .weapon = try self.enumValue(game.Weapon),
        };
    }
};

comptime {
    std.debug.assert(game.MAX_TANKS == wire.MAX_SEATS);
}

pub fn encode(message: Message) Encoded {
    var encoded: Encoded = .{};
    encoded.int(u8, @backingInt(message));
    switch (message) {
        .keepalive, .restart => {},
        .lobby => |lobby| encoded.lobby(lobby),
        .start => |start| {
            encoded.int(u64, start.seed);
            encoded.lobby(start.lobby);
        },
        .aim => |aim| encoded.aim(aim),
        .fired => |fired| {
            encoded.aim(fired.aim);
            encoded.int(u32, fired.state_hash);
        },
        .next_round => |round| encoded.int(u8, round),
        .pilot => |pilot| encoded.pilot(pilot),
    }
    return encoded;
}

/// Refuses an unknown tag, a value out of range, and a message too short or too long for its tag.
pub fn decode(bytes: []const u8) !Message {
    var reader: Reader = .{ .bytes = bytes };
    const message: Message = switch (try reader.enumValue(std.meta.Tag(Message))) {
        .keepalive => .keepalive,
        .restart => .restart,
        .lobby => .{ .lobby = try reader.lobby() },
        .start => .{ .start = .{ .seed = try reader.int(u64), .lobby = try reader.lobby() } },
        .aim => .{ .aim = try reader.aim() },
        .fired => .{ .fired = .{ .aim = try reader.aim(), .state_hash = try reader.int(u32) } },
        .next_round => .{ .next_round = try reader.int(u8) },
        .pilot => .{ .pilot = try reader.pilot() },
    };
    if (reader.index != bytes.len) return error.MessageTooLong;
    return message;
}

/// Valid UTF-8 with no control characters.
fn isPrintable(bytes: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(bytes)) return false;
    for (bytes) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

/// `bytes` must be valid UTF-8.
fn characterCount(bytes: []const u8) usize {
    var count: usize = 0;
    for (bytes) |byte| {
        if (byte & 0xC0 != 0x80) count += 1;
    }
    return count;
}

const testing = std.testing;

fn reencode(message: Message) !Message {
    const encoded = encode(message);
    return decode(encoded.slice());
}

const TEST_AIM: Aim = .{ .round = 2, .turn = 7, .shot = .{ .angle_degrees = 42.5, .power = 63 }, .weapon = .cluster };

test "every message survives encoding and decoding" {
    const lobby: Lobby = .{ .seats = .{ .human, .human, .ai_hard, .empty, .ai_easy, .ai_normal }, .round_count = 5 };
    const messages = [_]Message{
        .keepalive,
        .restart,
        .{ .lobby = lobby },
        .{ .start = .{ .seed = 0x0123_4567_89ab_cdef, .lobby = lobby } },
        .{ .aim = TEST_AIM },
        .{ .fired = .{ .aim = TEST_AIM, .state_hash = 0xdead_beef } },
        .{ .next_round = 3 },
        .{ .pilot = .{ .seat = 4, .tank_style = .hover, .name = try .fromText("Ripley") } },
        .{ .pilot = .{ .seat = 1, .tank_style = .standard, .name = .{} } },
    };
    for (messages) |message| try testing.expectEqualDeep(message, try reencode(message));
}

test "an unknown tag, a short message or a trailing byte is refused" {
    try testing.expectError(error.InvalidValue, decode(&.{200}));
    try testing.expectError(error.MessageTooShort, decode(&.{}));
    const encoded = encode(.{ .aim = TEST_AIM });
    try testing.expectError(error.MessageTooShort, decode(encoded.slice()[0 .. encoded.length - 1]));
    var longer = encoded;
    longer.int(u8, 0);
    try testing.expectError(error.MessageTooLong, decode(longer.slice()));
}

test "a shot with a NaN angle, too much power or no such weapon is refused" {
    var aim = TEST_AIM;
    aim.shot.angle_degrees = std.math.nan(f32);
    try testing.expectError(error.InvalidValue, reencode(.{ .aim = aim }));
    aim = TEST_AIM;
    aim.shot.power = game.MAX_POWER + 1;
    try testing.expectError(error.InvalidValue, reencode(.{ .aim = aim }));
    var encoded = encode(.{ .aim = TEST_AIM });
    encoded.buf[encoded.length - 1] = 99;
    try testing.expectError(error.InvalidValue, decode(encoded.slice()));
}

test "a name is trimmed, and one too long or with a control character is refused" {
    const name = try PilotName.fromText("  Ripley ");
    try testing.expectEqualStrings("Ripley", name.slice());
    try testing.expectError(error.NameTooLong, PilotName.fromText("A name far too long to fit, even for EVE"));
    try testing.expectError(error.InvalidName, PilotName.fromText("Rip\nley"));
}

test "a name is limited to 37 characters, and to the bytes that fit a frame" {
    _ = try PilotName.fromText("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    try testing.expectError(error.NameTooLong, PilotName.fromText("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
    _ = try PilotName.fromText("€€€€€€€€€€€€€€€€€€€€");
    try testing.expectError(error.NameTooLong, PilotName.fromText("€€€€€€€€€€€€€€€€€€€€€"));
}

test "a pilot with the longest name fits a frame" {
    const pilot: Pilot = .{ .seat = 5, .tank_style = .classic, .name = try .fromText("€€€€€€€€€€€€€€€€€€€€") };
    const encoded = encode(.{ .pilot = pilot });
    try testing.expectEqual(wire.MAX_MESSAGE_BYTES, encoded.length);
    const decoded = try decode(encoded.slice());
    try testing.expect(decoded.pilot.name.eql(&pilot.name));
}

test "a pilot message with broken UTF-8, a seat past the last, no such style or a length past its bytes is refused" {
    const tag = @backingInt(std.meta.Tag(Message).pilot);
    try testing.expectError(error.InvalidValue, decode(&.{ tag, 1, 0, 2, 0xC3, 0x28 }));
    try testing.expectError(error.InvalidValue, decode(&.{ tag, wire.MAX_SEATS, 0, 0 }));
    try testing.expectError(error.InvalidValue, decode(&.{ tag, 1, 99, 0 }));
    try testing.expectError(error.MessageTooShort, decode(&.{ tag, 1, 0, 5, 'a' }));
}

test "a lobby asking for no rounds or too many is refused" {
    var lobby: Lobby = .{ .seats = @splat(.empty), .round_count = 0 };
    try testing.expectError(error.InvalidValue, reencode(.{ .lobby = lobby }));
    lobby.round_count = MAX_ROUNDS + 1;
    try testing.expectError(error.InvalidValue, reencode(.{ .lobby = lobby }));
}
