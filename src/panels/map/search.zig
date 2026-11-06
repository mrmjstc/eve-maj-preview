//! The Map Panel's search: what's typed, what it finds, and the result picked; no I/O.
const std = @import("std");
const list_look = @import("../list_look.zig");
const look = @import("look.zig");
const text_mod = @import("text.zig");
const popup_look = @import("../popup_look.zig");
const search = @import("../../map/search.zig");
const universe = @import("../../map/universe.zig");
const fixed_text = @import("../../util/fixed_text.zig");

const FixedText = fixed_text.FixedText;
const PopupRow = popup_look.PopupRow;

/// One a hit, or the status line while there are none.
pub const MAX_ROWS = search.MAX_HITS;
/// WM_CHAR's character for the Backspace key.
const BACKSPACE = 0x08;

pub const Search = struct {
    buffer: [search.MAX_QUERY_LENGTH]u8 = undefined,
    length: usize = 0,
    hits: search.Hits = .{},
    /// Moved by the keys and the mouse: what's lit is what Enter opens.
    picked_index: usize = 0,

    pub fn query(self: *const Search) []const u8 {
        return self.buffer[0..self.length];
    }

    /// Whether the query changed: `char` is WM_CHAR's, and names are ASCII, so anything else is ignored, as is what would overrun the box.
    pub fn typeChar(self: *Search, char: usize) bool {
        if (char == BACKSPACE) {
            self.length -|= 1;
        } else if (char >= ' ' and char < 0x7F and self.length < self.buffer.len) {
            self.buffer[self.length] = @intCast(char);
            self.length += 1;
        } else {
            return false;
        }
        self.hits = search.find(self.query());
        self.picked_index = 0;
        return true;
    }

    pub fn pickPrevious(self: *Search) void {
        self.picked_index -|= 1;
    }

    pub fn pickNext(self: *Search) void {
        self.picked_index = @min(self.picked_index + 1, self.hits.count -| 1);
    }

    /// Null past the hits, as a list can shrink under the cursor.
    pub fn hitAt(self: *const Search, index: usize) ?search.Hit {
        const hits = self.hits.slice();
        return if (index < hits.len) hits[index] else null;
    }

    /// The status line is never lit.
    pub fn litRow(self: *const Search) ?usize {
        return if (self.hits.count > 0) self.picked_index else null;
    }

    /// `buffer` holds what's returned.
    pub fn fill(self: *const Search, buffer: *[MAX_ROWS]PopupRow) []const PopupRow {
        const hits = self.hits.slice();
        if (hits.len == 0) {
            buffer[0] = .{ .text = .print("{s}", .{if (self.length == 0) "Type a name" else "Nothing found"}), .color = list_look.MUTED };
            return buffer[0..1];
        }
        for (hits, buffer[0..hits.len]) |hit, *row| {
            const label = hitLabel(hit);
            row.* = .{ .text = label.text, .color = list_look.NAME, .accent = label.security };
        }
        return buffer[0..hits.len];
    }

    pub fn hash(self: *const Search, hasher: *std.hash.Wyhash) void {
        hasher.update(std.mem.asBytes(&self.picked_index));
        hasher.update(self.query());
    }
};

const HitLabel = struct {
    text: FixedText,
    /// Null for a region, which has none.
    security: ?popup_look.Accent = null,
};

fn hitLabel(hit: search.Hit) HitLabel {
    const system = switch (hit) {
        .region => |region| return .{ .text = .print("{s}" ++ popup_look.POPUP_PART_GAP ++ "Region", .{universe.regionName(region)}) },
        .system => |system| system,
    };
    const info = universe.systemInfo(system);
    const name = universe.systemName(system);
    var security_buf: [text_mod.SECURITY_TEXT_MAX]u8 = undefined;
    const security = text_mod.securityText(&security_buf, info.security_tenths);
    const start = name.len + popup_look.POPUP_PART_GAP.len;
    return .{
        .text = .print("{s}" ++ popup_look.POPUP_PART_GAP ++ "{s}" ++ popup_look.POPUP_PART_GAP ++ "{s}", .{ name, security, universe.regionName(info.region) }),
        .security = .{ .start = start, .end = start + security.len, .color = look.securityTextColor(info.security_tenths) },
    };
}

const testing = std.testing;

fn typeText(shown: *Search, text: []const u8) void {
    for (text) |char| _ = shown.typeChar(char);
}

test "typing finds what starts with the query, and Backspace takes a letter off" {
    var shown: Search = .{};
    typeText(&shown, "Jit");
    try testing.expectEqualStrings("Jit", shown.query());
    try testing.expect(shown.hits.count > 0);
    try testing.expect(shown.typeChar(BACKSPACE));
    try testing.expectEqualStrings("Ji", shown.query());
}

test "Backspace on an empty query leaves it empty" {
    var shown: Search = .{};
    try testing.expect(shown.typeChar(BACKSPACE));
    try testing.expectEqual(@as(usize, 0), shown.length);
}

test "characters names can't hold are ignored, as is typing past the box" {
    var shown: Search = .{};
    try testing.expect(!shown.typeChar(0x0D));
    try testing.expect(!shown.typeChar(0xE9));
    for (0..search.MAX_QUERY_LENGTH) |_| _ = shown.typeChar('a');
    try testing.expect(!shown.typeChar('a'));
    try testing.expectEqual(search.MAX_QUERY_LENGTH, shown.length);
}

test "the picked result stays among the hits, and typing goes back to the first" {
    var shown: Search = .{};
    typeText(&shown, "a");
    try testing.expect(shown.hits.count > 1);
    shown.pickPrevious();
    try testing.expectEqual(@as(usize, 0), shown.picked_index);
    for (0..search.MAX_HITS + 2) |_| shown.pickNext();
    try testing.expectEqual(shown.hits.count - 1, shown.picked_index);
    _ = shown.typeChar('m');
    try testing.expectEqual(@as(usize, 0), shown.picked_index);
}

test "with no hits there's one unlit status line, and nothing to pick" {
    var shown: Search = .{};
    var buffer: [MAX_ROWS]PopupRow = undefined;
    try testing.expectEqualStrings("Type a name", shown.fill(&buffer)[0].text.slice());
    typeText(&shown, "zzzzzz");
    const rows = shown.fill(&buffer);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("Nothing found", rows[0].text.slice());
    try testing.expectEqual(@as(?usize, null), shown.litRow());
    try testing.expectEqual(@as(?search.Hit, null), shown.hitAt(0));
}

test "a search result names the system, its security and its region" {
    try testing.expectEqualStrings("Jita  0.9  The Forge", hitLabel(.{ .system = universe.findSystem("Jita").? }).text.slice());
}

test "a search result's accent covers its security alone" {
    const hit = hitLabel(.{ .system = universe.findSystem("Jita").? });
    const accent = hit.security.?;
    try testing.expectEqualStrings("0.9", hit.text.slice()[accent.start..accent.end]);
    try testing.expectEqual(look.securityColor(9), accent.color);
}

test "a region's search result says it's a region" {
    const hit = hitLabel(.{ .region = 0 });
    try testing.expect(std.mem.endsWith(u8, hit.text.slice(), "  Region"));
    try testing.expect(hit.security == null);
}
