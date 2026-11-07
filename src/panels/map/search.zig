//! The Map Panel's search: what's typed and selected, what it finds, and the result picked; no I/O.
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

/// How a cursor move treats the selection.
pub const Extent = enum {
    /// Drops the selection.
    move,
    /// Keeps the selection's other end, as Shift does.
    extend,
};

pub const Motion = enum { left, right, word_left, word_right, home, end };

/// Indices into the query, `end` exclusive.
pub const Range = struct { start: usize, end: usize };

/// Where the last render drew each gap between the query's characters, for placing the cursor with the mouse.
pub const Stops = struct {
    /// Client x by gap; [0] is before the first character.
    x_positions: [search.MAX_QUERY_LENGTH + 1]i32 = undefined,
    /// The query's length plus one, or 0 until the search is drawn open.
    count: usize = 0,

    /// The gap nearest `x`; 0 before the box's first render.
    pub fn indexAt(self: *const Stops, x: i32) usize {
        if (self.count == 0) return 0;
        var nearest: usize = 0;
        for (self.x_positions[0..self.count], 0..) |stop, i| {
            if (@abs(stop - x) < @abs(self.x_positions[nearest] - x)) nearest = i;
        }
        return nearest;
    }
};

pub const Search = struct {
    buffer: [search.MAX_QUERY_LENGTH]u8 = undefined,
    length: usize = 0,
    /// Where typing goes, from 0 to `length`.
    cursor: usize = 0,
    /// The selection's other end, at `cursor` when nothing's selected.
    anchor: usize = 0,
    /// While the left button drags out a selection.
    is_selecting: bool = false,
    hits: search.Hits = .{},
    /// Moved by the keys and the mouse: what's lit is what Enter opens.
    picked_index: usize = 0,

    pub fn query(self: *const Search) []const u8 {
        return self.buffer[0..self.length];
    }

    pub fn selection(self: *const Search) Range {
        return .{ .start = @min(self.cursor, self.anchor), .end = @max(self.cursor, self.anchor) };
    }

    /// Borrows from the search; empty when nothing's selected.
    pub fn selectedText(self: *const Search) []const u8 {
        const range = self.selection();
        return self.buffer[range.start..range.end];
    }

    /// Whether the query changed: `char` is WM_CHAR's, and names are ASCII, so anything else is ignored, as is what would overrun the box.
    pub fn typeChar(self: *Search, char: usize) bool {
        if (char == BACKSPACE) {
            if (!self.deleteSelection() and self.cursor > 0) {
                self.anchor = self.cursor - 1;
                _ = self.deleteSelection();
            }
            self.refreshHits();
            return true;
        }
        if (!isNameChar(char)) return false;
        const byte: u8 = @intCast(char);
        return self.insert(&.{byte});
    }

    /// Whether the query changed: `text` replaces the selection, less what names can't hold and what would overrun the box.
    pub fn insert(self: *Search, text: []const u8) bool {
        var changed = self.deleteSelection();
        for (text) |char| {
            if (!isNameChar(char) or self.length == self.buffer.len) continue;
            std.mem.copyBackwards(u8, self.buffer[self.cursor + 1 .. self.length + 1], self.buffer[self.cursor..self.length]);
            self.buffer[self.cursor] = char;
            self.length += 1;
            self.cursor += 1;
            changed = true;
        }
        self.anchor = self.cursor;
        if (changed) self.refreshHits();
        return changed;
    }

    /// Whether the query changed, as Delete does.
    pub fn deleteForward(self: *Search) bool {
        if (!self.deleteSelection()) {
            if (self.cursor == self.length) return false;
            self.anchor = self.cursor + 1;
            _ = self.deleteSelection();
        }
        self.refreshHits();
        return true;
    }

    pub fn move(self: *Search, motion: Motion, extent: Extent) void {
        const range = self.selection();
        if (extent == .move and range.start != range.end) {
            switch (motion) {
                .left => return self.placeCursor(range.start, .move),
                .right => return self.placeCursor(range.end, .move),
                .word_left, .word_right, .home, .end => {},
            }
        }
        self.placeCursor(self.motionTarget(motion), extent);
    }

    /// `index` past the query is taken as its end.
    pub fn placeCursor(self: *Search, index: usize, extent: Extent) void {
        self.cursor = @min(index, self.length);
        switch (extent) {
            .move => self.anchor = self.cursor,
            .extend => {},
        }
    }

    pub fn selectAll(self: *Search) void {
        self.anchor = 0;
        self.cursor = self.length;
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
        hasher.update(std.mem.asBytes(&self.cursor));
        hasher.update(std.mem.asBytes(&self.anchor));
        hasher.update(self.query());
    }

    fn refreshHits(self: *Search) void {
        self.hits = search.find(self.query());
        self.picked_index = 0;
    }

    /// Whether there was a selection to delete; leaves the hits for the caller to refresh.
    fn deleteSelection(self: *Search) bool {
        const range = self.selection();
        if (range.start == range.end) return false;
        std.mem.copyForwards(u8, self.buffer[range.start..], self.buffer[range.end..self.length]);
        self.length -= range.end - range.start;
        self.cursor = range.start;
        self.anchor = range.start;
        return true;
    }

    /// Words end at spaces alone, so a name like 4-HWWF moves as one.
    fn motionTarget(self: *const Search, motion: Motion) usize {
        const text = self.query();
        var index = self.cursor;
        switch (motion) {
            .left => return index -| 1,
            .right => return @min(index + 1, self.length),
            .home => return 0,
            .end => return self.length,
            .word_left => {
                while (index > 0 and text[index - 1] == ' ') index -= 1;
                while (index > 0 and text[index - 1] != ' ') index -= 1;
            },
            .word_right => {
                while (index < text.len and text[index] != ' ') index += 1;
                while (index < text.len and text[index] == ' ') index += 1;
            },
        }
        return index;
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

fn isNameChar(char: usize) bool {
    return char >= ' ' and char < 0x7F;
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

test "typing replaces the selection, and Backspace deletes it whole" {
    var shown: Search = .{};
    typeText(&shown, "Amarr");
    shown.selectAll();
    try testing.expectEqualStrings("Amarr", shown.selectedText());
    typeText(&shown, "Ji");
    try testing.expectEqualStrings("Ji", shown.query());
    shown.move(.home, .extend);
    _ = shown.typeChar(BACKSPACE);
    try testing.expectEqualStrings("", shown.query());
}

test "typing and Delete work at the cursor, mid-query" {
    var shown: Search = .{};
    typeText(&shown, "Jta");
    shown.placeCursor(1, .move);
    typeText(&shown, "i");
    try testing.expectEqualStrings("Jita", shown.query());
    try testing.expect(shown.deleteForward());
    try testing.expectEqualStrings("Jia", shown.query());
    shown.move(.end, .move);
    try testing.expect(!shown.deleteForward());
}

test "a paste keeps what names can hold and stops at the box's end" {
    var shown: Search = .{};
    try testing.expect(shown.insert("Jita\r\n"));
    try testing.expectEqualStrings("Jita", shown.query());
    try testing.expect(!shown.insert("\t\n"));
    for (0..search.MAX_QUERY_LENGTH) |_| _ = shown.insert("ab");
    try testing.expectEqual(search.MAX_QUERY_LENGTH, shown.length);
}

test "an arrow without Shift collapses the selection to its side" {
    var shown: Search = .{};
    typeText(&shown, "Old Man Star");
    shown.placeCursor(4, .move);
    shown.move(.word_right, .extend);
    try testing.expectEqualStrings("Man ", shown.selectedText());
    shown.move(.left, .move);
    try testing.expectEqual(@as(usize, 4), shown.cursor);
    try testing.expectEqualStrings("", shown.selectedText());
    shown.move(.word_left, .move);
    try testing.expectEqual(@as(usize, 0), shown.cursor);
}

test "a click picks the gap nearest it" {
    var stops: Stops = .{};
    try testing.expectEqual(@as(usize, 0), stops.indexAt(50));
    stops.x_positions[0..3].* = .{ 10, 20, 30 };
    stops.count = 3;
    try testing.expectEqual(@as(usize, 0), stops.indexAt(0));
    try testing.expectEqual(@as(usize, 1), stops.indexAt(23));
    try testing.expectEqual(@as(usize, 2), stops.indexAt(99));
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
