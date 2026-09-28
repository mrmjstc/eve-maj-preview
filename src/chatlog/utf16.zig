//! Decoding EVE's UTF-16 LE chatlogs, only ever whole characters.
const std = @import("std");

/// How much of `data` is whole characters: drops an odd trailing byte, and a trailing high surrogate whose pair hasn't been written yet.
pub fn completeLen(data: []const u8) usize {
    var len = data.len & ~@as(usize, 1);
    if (len >= 2) {
        const last = @as(u16, data[len - 2]) | (@as(u16, data[len - 1]) << 8);
        if (std.unicode.utf16IsHighSurrogate(last)) len -= 2;
    }
    return len;
}

/// `out` needs 3 bytes per UTF-16 unit and `units` one per byte pair; an unpaired surrogate becomes U+FFFD rather than losing the rest.
pub fn decodeInto(units: []u16, out: []u8, data: []const u8) ?[]u8 {
    const count = data.len / 2;
    if (count == 0) return null;
    const packed_units = units[0..count];
    for (packed_units, 0..) |*unit, i| unit.* = @as(u16, data[i * 2]) | (@as(u16, data[i * 2 + 1]) << 8);

    const written = std.unicode.utf16LeToUtf8(out, packed_units) catch blk: {
        replaceUnpairedSurrogates(packed_units);
        break :blk std.unicode.utf16LeToUtf8(out, packed_units) catch return null;
    };
    return out[0..written];
}

pub fn decode(allocator: std.mem.Allocator, units: *std.ArrayList(u16), out: *std.ArrayList(u8), data: []const u8) !?[]u8 {
    try units.resize(allocator, data.len / 2);
    try out.resize(allocator, (data.len / 2) * 3);
    return decodeInto(units.items, out.items, data);
}

fn replaceUnpairedSurrogates(units: []u16) void {
    var i: usize = 0;
    while (i < units.len) : (i += 1) {
        const unit = units[i];
        if (std.unicode.utf16IsHighSurrogate(unit) and i + 1 < units.len and std.unicode.utf16IsLowSurrogate(units[i + 1])) {
            i += 1;
        } else if (std.unicode.utf16IsHighSurrogate(unit) or std.unicode.utf16IsLowSurrogate(unit)) {
            units[i] = std.unicode.replacement_character;
        }
    }
}

/// Without decoding; `data` must start on a character boundary.
pub fn containsAscii(data: []const u8, pattern: []const u8) bool {
    if (data.len < pattern.len * 2) return false;
    var i: usize = 0;
    while (i + pattern.len * 2 <= data.len) : (i += 2) {
        for (pattern, 0..) |c, j| {
            if (data[i + j * 2] != c or data[i + j * 2 + 1] != 0) break;
        } else return true;
    }
    return false;
}

const testing = std.testing;

/// Inline, so the result is comptime-known and can be joined with `++`.
inline fn encode(comptime text: []const u8) []const u8 {
    comptime {
        var bytes: [text.len * 2]u8 = undefined;
        for (text, 0..) |c, i| {
            bytes[i * 2] = c;
            bytes[i * 2 + 1] = 0;
        }
        const final = bytes;
        return &final;
    }
}

test "completeLen drops an odd trailing byte" {
    try testing.expectEqual(@as(usize, 4), completeLen(encode("ab") ++ "c"));
    try testing.expectEqual(@as(usize, 0), completeLen("a"));
}

test "completeLen holds back a high surrogate until its pair arrives" {
    // U+1F600 is D83D DE00.
    const high = [_]u8{ 0x3D, 0xD8 };
    const low = [_]u8{ 0x00, 0xDE };
    try testing.expectEqual(@as(usize, 2), completeLen(encode("a") ++ high));
    try testing.expectEqual(@as(usize, 6), completeLen(encode("a") ++ high ++ low));
}

test "decodeInto decodes whole characters and ignores an odd byte" {
    var units: [8]u16 = undefined;
    var out: [24]u8 = undefined;
    try testing.expectEqualStrings("Jita", decodeInto(&units, &out, encode("Jita") ++ "x").?);
}

test "decodeInto replaces an unpaired surrogate instead of failing" {
    var units: [8]u16 = undefined;
    var out: [24]u8 = undefined;
    const lone_high = [_]u8{ 0x3D, 0xD8 };
    try testing.expectEqualStrings("a\u{FFFD}b", decodeInto(&units, &out, encode("a") ++ lone_high ++ encode("b")).?);
}

test "containsAscii finds text only on character boundaries" {
    const data = encode("xx Channel changed");
    try testing.expect(containsAscii(data, "Channel"));
    try testing.expect(!containsAscii(data[1..], "Channel"));
    try testing.expect(!containsAscii(data, "Local"));
}
