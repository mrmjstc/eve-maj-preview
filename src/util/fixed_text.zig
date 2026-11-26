//! A line of text that owns its bytes, cut to fit, so it can cross threads.
const std = @import("std");
const utf8 = @import("utf8.zig");

pub const MAX_LENGTH = 160;

pub const FixedText = struct {
    bytes: [MAX_LENGTH]u8 = undefined,
    length: usize = 0,

    pub fn print(comptime format: []const u8, args: anytype) FixedText {
        var text: FixedText = .{};
        var writer: std.Io.Writer = .fixed(&text.bytes);
        // A long line is cut, which the reader can see.
        writer.print(format, args) catch {};
        const written = writer.buffered();
        text.length = utf8.prefixLength(written, if (written.len == MAX_LENGTH) MAX_LENGTH - 1 else written.len);
        return text;
    }

    pub fn slice(self: *const FixedText) []const u8 {
        return self.bytes[0..self.length];
    }
};

const testing = std.testing;

test "a long line is cut to fit" {
    const long: [MAX_LENGTH * 2]u8 = @splat('x');
    try testing.expectEqual(MAX_LENGTH - 1, FixedText.print("{s}", .{&long}).length);
}
