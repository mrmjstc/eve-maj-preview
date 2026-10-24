//! Capitalising text for small-caps headings, in the scripts the window's languages use; no I/O.
const std = @import("std");

/// `text` in capitals, made in `arena`; letters without a simple capital, like ß, and invalid UTF-8 are kept as they are.
pub fn upper(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, text.len);
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const end = @min(index + length, text.len);
        const codepoint = std.unicode.utf8Decode(text[index..end]) catch {
            try out.appendSlice(arena, text[index..end]);
            index = end;
            continue;
        };
        var buf: [4]u8 = undefined;
        // A decoded scalar maps to another valid one, which always encodes.
        const written = std.unicode.utf8Encode(upperCodepoint(codepoint), &buf) catch unreachable;
        try out.appendSlice(arena, buf[0..written]);
        index = end;
    }
    return out.items;
}

/// Basic Latin, Latin-1, Latin Extended-A and Cyrillic: enough for English, German, Spanish, French, Polish, Portuguese and Russian.
fn upperCodepoint(codepoint: u21) u21 {
    return switch (codepoint) {
        'a'...'z' => codepoint - 0x20,
        // Latin-1 lower case, past the division sign.
        0xE0...0xF6, 0xF8...0xFE => codepoint - 0x20,
        0xFF => 0x178,
        // Latin Extended-A pairs a capital with the small letter after it, except in two runs where the capital comes second.
        0x100...0x137, 0x14A...0x177 => if (codepoint % 2 == 1) codepoint - 1 else codepoint,
        0x139...0x148, 0x179...0x17E => if (codepoint % 2 == 0) codepoint - 1 else codepoint,
        0x430...0x44F => codepoint - 0x20,
        0x450...0x45F => codepoint - 0x50,
        else => codepoint,
    };
}

const testing = std.testing;

test "upper capitalises English and keeps punctuation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("OUTSIDE EVE & POLLING", try upper(arena.allocator(), "Outside EVE & Polling"));
}

test "upper capitalises accented Latin letters, Polish ones and Cyrillic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try testing.expectEqualStrings("ÉVÉNEMENTS", try upper(allocator, "événements"));
    try testing.expectEqualStrings("ŁĄCZNOŚĆ ŻÓŁTA", try upper(allocator, "łączność żółta"));
    try testing.expectEqualStrings("УВЕДОМЛЕНИЯ ЁЖ", try upper(allocator, "уведомления ёж"));
}

test "upper keeps letters without a simple capital" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("GRÖßE", try upper(arena.allocator(), "größe"));
}
