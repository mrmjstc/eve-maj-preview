//! Splits a release's Markdown notes into the lines the update prompt draws: headings, bullets and plain text; no I/O.
const std = @import("std");

pub const Kind = enum { heading, bullet, text };

/// One line to draw; `text` borrows from the notes, its Markdown marker and line ending gone.
pub const Line = struct { kind: Kind, text: []const u8 };

/// Skips blank lines, as the prompt spaces its lines itself.
pub const Lines = struct {
    rest: std.mem.SplitIterator(u8, .scalar),

    pub fn init(notes: []const u8) Lines {
        return .{ .rest = std.mem.splitScalar(u8, notes, '\n') };
    }

    pub fn next(self: *Lines) ?Line {
        while (self.rest.next()) |raw| {
            // GitHub's notes end their lines in CRLF, whose \r the font draws as a box.
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (line[0] == '#') return .{ .kind = .heading, .text = std.mem.trim(u8, std.mem.trimStart(u8, line, "#"), " \t") };
            if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ")) return .{ .kind = .bullet, .text = std.mem.trimStart(u8, line[2..], " \t") };
            return .{ .kind = .text, .text = line };
        }
        return null;
    }
};

const testing = std.testing;

test "a heading and its bullets lose their markers and line endings" {
    var lines: Lines = .init("v1.0.9\r\n\r\n### Changed\r\n- Config redesign.\r\n* Faster start.\r\n");
    try testing.expectEqualDeep(Line{ .kind = .text, .text = "v1.0.9" }, lines.next().?);
    try testing.expectEqualDeep(Line{ .kind = .heading, .text = "Changed" }, lines.next().?);
    try testing.expectEqualDeep(Line{ .kind = .bullet, .text = "Config redesign." }, lines.next().?);
    try testing.expectEqualDeep(Line{ .kind = .bullet, .text = "Faster start." }, lines.next().?);
    try testing.expectEqual(@as(?Line, null), lines.next());
}

test "a hyphen inside a word doesn't make a bullet" {
    var lines: Lines = .init("-fixed\nre-check interval");
    try testing.expectEqual(Kind.text, lines.next().?.kind);
    try testing.expectEqual(Kind.text, lines.next().?.kind);
}
