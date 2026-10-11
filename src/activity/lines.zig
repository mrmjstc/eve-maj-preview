//! Parsers for the gamelog's combat, mining and bounty lines; no I/O.
const std = @import("std");

/// Room for one gamelog line's text once its HTML is stripped.
pub const MAX_STRIPPED_LENGTH = 512;

/// Separates a combat line's target, weapon and hit quality.
const DASH = " - ";

const THOUSANDS_SEPARATORS = [_][]const u8{ ",", " ", "\u{00A0}", "\u{202F}" };

const ENTITIES = [_]Entity{
    .{ .name = "&lt;", .char = '<' },
    .{ .name = "&gt;", .char = '>' },
    .{ .name = "&amp;", .char = '&' },
    .{ .name = "&quot;", .char = '"' },
    .{ .name = "&#39;", .char = '\'' },
    .{ .name = "&apos;", .char = '\'' },
};

const Entity = struct { name: []const u8, char: u8 };

/// Raw unit count plus the mined ore/ice/gas name, copied by value since parseMiningLine's buffer is stack-local.
pub const ParsedMiningEvent = struct {
    amount: u32,
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,

    pub fn name(self: *const ParsedMiningEvent) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// `weapon` borrows from the already-stripped line; an incoming miss counts as a zero-amount hit for Taking Damage, and an outgoing one is dropped.
pub fn parseCombatLine(stripped_line: []const u8) ?struct { amount: u32, is_incoming: bool, weapon: []const u8 } {
    const combat_prefix = "(combat)";
    const combat_index = std.mem.find(u8, stripped_line, combat_prefix) orelse return null;
    const stripped = std.mem.trimStart(u8, stripped_line[combat_index + combat_prefix.len ..], " \t");

    // Remote repairs and capacitor transfers aren't damage.
    if (std.mem.find(u8, stripped, "boosts your") != null or
        std.mem.find(u8, stripped, "shields your") != null or
        std.mem.find(u8, stripped, "repairs your") != null or
        std.mem.find(u8, stripped, "transfers") != null)
    {
        return null;
    }

    if (std.mem.find(u8, stripped, " misses you completely")) |miss_index| {
        const weapon_dash = std.mem.findPos(u8, stripped, miss_index, DASH) orelse return .{ .amount = 0, .is_incoming = true, .weapon = "" };
        return .{ .amount = 0, .is_incoming = true, .weapon = std.mem.trim(u8, stripped[weapon_dash + DASH.len ..], " \t") };
    }

    const leading = parseLeadingAmount(stripped) orelse return null;

    const rest = stripped[leading.end..];
    const is_incoming = if (std.mem.find(u8, rest, " from ") != null)
        true
    else if (std.mem.find(u8, rest, " to ") != null)
        false
    else
        return null;

    // The weapon is the segment before the hit quality, found from the end since target names can contain " - " too.
    var weapon: []const u8 = "";
    if (std.mem.findLast(u8, rest, DASH)) |quality_dash| {
        const before_quality = rest[0..quality_dash];
        if (std.mem.findLast(u8, before_quality, DASH)) |weapon_dash| {
            weapon = std.mem.trim(u8, before_quality[weapon_dash + DASH.len ..], " \t");
        }
    }

    return .{ .amount = leading.amount, .is_incoming = is_incoming, .weapon = weapon };
}

/// True if `weapon` case-insensitively contains any comma-separated entry of `excluded_csv`; empty entries are skipped so trailing/stray commas don't match everything.
pub fn isWeaponExcluded(weapon: []const u8, excluded_csv: []const u8) bool {
    if (weapon.len == 0 or excluded_csv.len == 0) return false;
    var it = std.mem.splitScalar(u8, excluded_csv, ',');
    while (it.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t");
        if (entry.len == 0) continue;
        if (std.ascii.findIgnoreCase(weapon, entry) != null) return true;
    }
    return false;
}

/// The ISK added to the next payout; unlike combat and mining amounts, it has thousands separators ("246,153 ISK", or "246 153 ISK" on some Windows locales).
pub fn parseBountyLine(line: []const u8) ?f32 {
    const bounty_prefix = "(bounty)";
    const bounty_index = std.mem.find(u8, line, bounty_prefix) orelse return null;
    const payload = std.mem.trimStart(u8, line[bounty_index + bounty_prefix.len ..], " \t");

    var stripped_buf: [MAX_STRIPPED_LENGTH]u8 = undefined;
    const stripped = stripHtml(payload, &stripped_buf);

    // u64, as a single payout can pass u32's 4.3 billion.
    var amount: u64 = 0;
    var found_digit = false;
    var i: usize = 0;
    while (i < stripped.len) {
        const byte = stripped[i];
        if (std.ascii.isDigit(byte)) {
            amount = appendDigit(u64, amount, byte) orelse return null;
            found_digit = true;
            i += 1;
        } else if (found_digit) {
            const separator_len = thousandsSeparatorLen(stripped[i..]);
            if (separator_len == 0) break;
            i += separator_len;
        } else if (byte == ' ' or byte == '\t') {
            i += 1;
        } else {
            return null;
        }
    }
    if (!found_digit or amount == 0) return null;
    return @floatFromInt(amount);
}

/// Null for residue lines, which the player doesn't gain.
pub fn parseMiningLine(line: []const u8) ?ParsedMiningEvent {
    const mining_prefix = "(mining)";
    const mining_index = std.mem.find(u8, line, mining_prefix) orelse return null;
    const payload = std.mem.trimStart(u8, line[mining_index + mining_prefix.len ..], " \t");

    var stripped_buf: [MAX_STRIPPED_LENGTH]u8 = undefined;
    const stripped = stripHtml(payload, &stripped_buf);

    if (std.mem.find(u8, stripped, "depleted from asteroid as residue") != null) return null;

    // "You mined" starts both normal and critical yields.
    const mined_keyword = "You mined";
    const mined_index = std.mem.find(u8, stripped, mined_keyword) orelse return null;
    var cursor = std.mem.trimStart(u8, stripped[mined_index + mined_keyword.len ..], " \t");

    // A critical yield says "an additional".
    const additional_keyword = "an additional ";
    if (std.mem.startsWith(u8, cursor, additional_keyword)) {
        cursor = cursor[additional_keyword.len..];
    }

    const leading = parseLeadingAmount(cursor) orelse return null;

    const units_of_keyword = "units of ";
    const rest = cursor[leading.end..];
    const units_index = std.mem.find(u8, rest, units_of_keyword) orelse return null;
    const name_start = rest[units_index + units_of_keyword.len ..];
    const name_end = std.mem.findScalar(u8, name_start, '.') orelse name_start.len;
    const ore_name = std.mem.trim(u8, name_start[0..name_end], " \t");
    if (ore_name.len == 0) return null;

    var result: ParsedMiningEvent = .{ .amount = leading.amount };
    if (ore_name.len > result.name_buf.len) return null;
    @memcpy(result.name_buf[0..ore_name.len], ore_name);
    result.name_len = @intCast(ore_name.len);
    return result;
}

/// Drops tags and decodes entities in one pass, so a decoded "<ALLY>" isn't then taken for a tag; truncated to `out_buf`'s length.
pub fn stripHtml(html: []const u8, out_buf: []u8) []const u8 {
    var out_len: usize = 0;
    var in_tag = false;
    var i: usize = 0;
    while (i < html.len and out_len < out_buf.len) : (i += 1) {
        const byte = html[i];
        switch (byte) {
            '<' => in_tag = true,
            '>' => in_tag = false,
            else => if (!in_tag) {
                out_buf[out_len] = byte;
                if (byte == '&') {
                    if (decodeEntity(html[i..])) |entity| {
                        out_buf[out_len] = entity.char;
                        i += entity.len - 1;
                    }
                }
                out_len += 1;
            },
        }
    }
    return out_buf[0..out_len];
}

/// The whole number after leading spaces and tabs, and where its digits end; null for none, zero or one too large for u32.
fn parseLeadingAmount(text: []const u8) ?struct { amount: u32, end: usize } {
    var amount: u32 = 0;
    var digits_end: usize = 0;
    for (text, 0..) |c, i| {
        if (std.ascii.isDigit(c)) {
            amount = appendDigit(u32, amount, c) orelse return null;
            digits_end = i + 1;
        } else if (digits_end != 0) {
            break;
        } else if (c != ' ' and c != '\t') {
            return null;
        }
    }
    if (digits_end == 0 or amount == 0) return null;
    return .{ .amount = amount, .end = digits_end };
}

fn thousandsSeparatorLen(text: []const u8) usize {
    for (THOUSANDS_SEPARATORS) |separator| {
        if (std.mem.startsWith(u8, text, separator)) return separator.len;
    }
    return 0;
}

fn decodeEntity(text: []const u8) ?struct { char: u8, len: usize } {
    for (ENTITIES) |entity| {
        if (std.mem.startsWith(u8, text, entity.name)) return .{ .char = entity.char, .len = entity.name.len };
    }
    return null;
}

/// Null when another digit would overflow, so an absurdly long number is skipped rather than wrapping.
fn appendDigit(comptime T: type, amount: T, digit_char: u8) ?T {
    const shifted = std.math.mul(T, amount, 10) catch return null;
    return std.math.add(T, shifted, digit_char - '0') catch null;
}

const testing = std.testing;

test "parseCombatLine reads incoming and outgoing damage and the weapon" {
    const incoming = parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) 484 from Gist Seraphim - Heavy Missile - Hits").?;
    try testing.expectEqual(@as(u32, 484), incoming.amount);
    try testing.expect(incoming.is_incoming);
    try testing.expectEqualStrings("Heavy Missile", incoming.weapon);

    const outgoing = parseCombatLine("[ 2026.09.17 19:28:07 ] (combat) 312 to Gist Seraphim - Hammerhead II - Smashes").?;
    try testing.expectEqual(@as(u32, 312), outgoing.amount);
    try testing.expect(!outgoing.is_incoming);
    try testing.expectEqualStrings("Hammerhead II", outgoing.weapon);
}

test "parseCombatLine counts a miss against you as incoming with no damage" {
    const miss = parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) Gist Seraphim misses you completely - Heavy Missile").?;
    try testing.expectEqual(@as(u32, 0), miss.amount);
    try testing.expect(miss.is_incoming);
    try testing.expectEqualStrings("Heavy Missile", miss.weapon);

    const npc_miss = parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) CONCORD Police Captain - CONCORD Police Captain misses you completely").?;
    try testing.expect(npc_miss.is_incoming);
    try testing.expectEqualStrings("", npc_miss.weapon);
}

test "parseCombatLine drops an outgoing miss on a target whose name starts with you" {
    try testing.expect(parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) Your group of 650mm Artillery Cannon II misses youngling completely - 650mm Artillery Cannon II") == null);
}

test "parseCombatLine ignores repairs, transfers and malformed lines" {
    try testing.expect(parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) 350 energy transfers to Some Pilot - Large Remote Capacitor Transmitter") == null);
    try testing.expect(parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) 200 remote armor repairs your ship - Some Pilot") == null);
    try testing.expect(parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) 100 hit points of something") == null);
    try testing.expect(parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) 0 from Gist Seraphim - Heavy Missile - Hits") == null);
    try testing.expect(parseCombatLine("[ 2026.09.17 19:28:06 ] (notify) 484 from Gist Seraphim - Heavy Missile - Hits") == null);
}

test "parseCombatLine skips an amount too large for u32 instead of wrapping" {
    try testing.expect(parseCombatLine("[ 2026.09.17 19:28:06 ] (combat) 99999999999 from Gist Seraphim - Heavy Missile - Hits") == null);
}

test "parseBountyLine reads comma-separated ISK, including payouts past u32" {
    try testing.expectEqual(@as(f32, 120272), parseBountyLine("[ 2026.09.17 19:28:07 ] (bounty) <b>120,272 ISK</b> added to next bounty payout").?);
    try testing.expectEqual(@as(f32, 5_000_000_000), parseBountyLine("[ 2026.09.17 19:28:07 ] (bounty) <b>5,000,000,000 ISK</b> added to next bounty payout").?);
    try testing.expect(parseBountyLine("[ 2026.09.17 19:28:07 ] (bounty) <b>0 ISK</b> added to next bounty payout") == null);
    try testing.expect(parseBountyLine("[ 2026.09.17 19:28:07 ] (bounty) Bounty payout pending") == null);
}

test "parseBountyLine reads space, no-break and narrow no-break space separators" {
    try testing.expectEqual(@as(f32, 258_300), parseBountyLine("[ 2026.10.05 16:00:00 ] (bounty) <b>258 300 ISK</b> added to next bounty payout").?);
    try testing.expectEqual(@as(f32, 3_000_000), parseBountyLine("[ 2026.10.05 16:00:00 ] (bounty) <b>3\u{00A0}000\u{00A0}000 ISK</b> added to next bounty payout").?);
    try testing.expectEqual(@as(f32, 1_200_000), parseBountyLine("[ 2026.10.05 16:00:00 ] (bounty) <b>1\u{202F}200\u{202F}000 ISK</b> added to next bounty payout").?);
    try testing.expectEqual(@as(f32, 1_000), parseBountyLine("[ 2026.10.05 16:00:00 ] (bounty) <b> 1,000 ISK</b> added to next bounty payout").?);
}

test "parseMiningLine reads normal and critical yields but not residue" {
    const normal = parseMiningLine("[ 2026.08.09 23:45:29 ] (mining) <color=0x77ffffff>You mined <b>1</b> units of Dark Glitter").?;
    try testing.expectEqual(@as(u32, 1), normal.amount);
    try testing.expectEqualStrings("Dark Glitter", normal.name());

    const critical = parseMiningLine("[ 2026.08.09 23:45:30 ] (mining) You mined an additional <b>52</b> units of Veldspar.").?;
    try testing.expectEqual(@as(u32, 52), critical.amount);
    try testing.expectEqualStrings("Veldspar", critical.name());

    try testing.expect(parseMiningLine("[ 2026.08.09 23:45:31 ] (mining) 12 units of Veldspar depleted from asteroid as residue") == null);
    try testing.expect(parseMiningLine("[ 2026.08.09 23:45:31 ] (mining) You mined <b>5</b> units of ") == null);
}

test "stripHtml decodes an alliance ticker's entities without taking it for a tag" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Skiff <IR-W>[B0RT] Killer Madullier ", stripHtml("<b>Skiff &lt;IR-W&gt;[B0RT] Killer Madullier </b>", &buf));
    try testing.expectEqualStrings("A & B \"q\" 'x' &unknown; &", stripHtml("A &amp; B &quot;q&quot; &#39;x&#39; &unknown; &", &buf));
}

test "stripHtml drops tags and truncates to the buffer" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("You mined 1 units", stripHtml("<color=0x77ffffff>You mined <b>1</b> units", &buf));
    var small: [3]u8 = undefined;
    try testing.expectEqualStrings("abc", stripHtml("<b>abcdef</b>", &small));
}

test "isWeaponExcluded matches case-insensitive substrings and skips blank entries" {
    try testing.expect(isWeaponExcluded("Hammerhead II", "drone, hammerhead"));
    try testing.expect(isWeaponExcluded("Heavy Missile", " , missile "));
    try testing.expect(!isWeaponExcluded("Heavy Missile", ",,"));
    try testing.expect(!isWeaponExcluded("", "missile"));
    try testing.expect(!isWeaponExcluded("Heavy Missile", "Heavy Missile Launcher"));
}
