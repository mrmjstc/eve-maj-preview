//! What a panel's last render drew as text, for the end-to-end tests' state file; no I/O.
const std = @import("std");

/// Longer texts are cut to this many bytes.
pub const TEXT_SIZE = 64;
/// More texts than this in one render go unrecorded; the map's labels come nearest.
pub const MAX_TEXTS = 256;

pub const Text = struct {
    text_buffer: [TEXT_SIZE]u8,
    text_length: usize,
    left: i32,
    top: i32,
    color: u32,

    pub fn text(self: *const Text) []const u8 {
        return self.text_buffer[0..self.text_length];
    }
};

pub const Record = struct {
    texts: [MAX_TEXTS]Text = undefined,
    text_count: usize = 0,

    pub fn clear(self: *Record) void {
        self.text_count = 0;
    }

    /// The same text again straight after replaces it, so an outline's copies leave only the text drawn over them.
    pub fn add(self: *Record, text: []const u8, left: i32, top: i32, color: u32) void {
        if (text.len == 0) return;
        const length = @min(text.len, TEXT_SIZE);
        const repeats = self.text_count > 0 and std.mem.eql(u8, self.texts[self.text_count - 1].text(), text[0..length]);
        if (!repeats) {
            if (self.text_count == MAX_TEXTS) return;
            self.text_count += 1;
        }
        const entry = &self.texts[self.text_count - 1];
        @memcpy(entry.text_buffer[0..length], text[0..length]);
        entry.text_length = length;
        entry.left = left;
        entry.top = top;
        entry.color = color;
    }

    pub fn items(self: *const Record) []const Text {
        return self.texts[0..self.text_count];
    }
};

test "a text drawn again straight after keeps only its last place and colour" {
    var record: Record = .{};
    record.add("Jita", 9, 9, 0xFF000000);
    record.add("Jita", 10, 10, 0xFFFFFFFF);
    record.add("Amarr", 0, 30, 0xFFFFFFFF);
    try std.testing.expectEqual(2, record.items().len);
    try std.testing.expectEqual(10, record.items()[0].left);
    try std.testing.expectEqual(0xFFFFFFFF, record.items()[0].color);
}

test "a long text is cut and texts past the limit are dropped" {
    var record: Record = .{};
    const long: [TEXT_SIZE + 10]u8 = @splat('x');
    record.add(&long, 0, 0, 0);
    try std.testing.expectEqual(TEXT_SIZE, record.items()[0].text().len);
    for (0..MAX_TEXTS + 5) |i| record.add(if (i % 2 == 0) "a" else "b", 0, 0, 0);
    try std.testing.expectEqual(MAX_TEXTS, record.items().len);
}

test "an empty text isn't recorded" {
    var record: Record = .{};
    record.add("", 0, 0, 0);
    try std.testing.expectEqual(0, record.items().len);
}
