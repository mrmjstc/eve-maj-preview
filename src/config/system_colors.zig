//! Per-system name colour overrides, matched by exact name or wildcard pattern.
const std = @import("std");
const wire = @import("wire.zig");

pub const SystemColorConfig = struct {
    /// Comma-separated exact names and `*`/`?`/`#` patterns.
    systemName: []const u8 = "",
    color: u32 = 0,

    pub const Wire = wire.Wire(SystemColorConfig);

    /// `uses_wildcards` selects which kind of token in `systemName` is tried.
    pub fn matches(self: SystemColorConfig, system_name: []const u8, uses_wildcards: bool) bool {
        var tokens = std.mem.tokenizeScalar(u8, self.systemName, ',');
        while (tokens.next()) |raw| {
            const token = std.mem.trim(u8, raw, " \t");
            if (token.len == 0) continue;
            const is_pattern = std.mem.findAny(u8, token, "*?#") != null;
            if (is_pattern != uses_wildcards) continue;
            const is_match = if (is_pattern) globMatch(token, system_name) else std.ascii.eqlIgnoreCase(token, system_name);
            if (is_match) return true;
        }
        return false;
    }
};

/// Case-insensitive glob: `*` any run, `?` any character, `#` any digit.
fn globMatch(pattern: []const u8, text: []const u8) bool {
    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star_pattern_index: ?usize = null;
    var star_text_index: usize = 0;
    while (text_index < text.len) {
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_pattern_index = pattern_index;
            star_text_index = text_index;
            pattern_index += 1;
        } else if (pattern_index < pattern.len and globCharMatches(pattern[pattern_index], text[text_index])) {
            pattern_index += 1;
            text_index += 1;
        } else if (star_pattern_index) |star_index| {
            pattern_index = star_index + 1;
            star_text_index += 1;
            text_index = star_text_index;
        } else return false;
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

fn globCharMatches(pattern_char: u8, text_char: u8) bool {
    return switch (pattern_char) {
        '?' => true,
        '#' => std.ascii.isDigit(text_char),
        else => std.ascii.toLower(pattern_char) == std.ascii.toLower(text_char),
    };
}

const testing = std.testing;

test "matches tries exact names or patterns, whichever uses_wildcards selects" {
    const entry: SystemColorConfig = .{ .systemName = "Jita, amarr ,J######, *-C?", .color = 0xFFFF0000 };
    try testing.expect(entry.matches("Jita", false));
    try testing.expect(entry.matches("AMARR", false));
    try testing.expect(!entry.matches("Jita", true));
    try testing.expect(entry.matches("J123456", true));
    try testing.expect(!entry.matches("J123456", false));
    try testing.expect(entry.matches("5-CQ", true));
    try testing.expect(!entry.matches("Perimeter", false) and !entry.matches("Perimeter", true));
}

test "matches ignores empty tokens" {
    const entry: SystemColorConfig = .{ .systemName = " , ,", .color = 0xFFFF0000 };
    try testing.expect(!entry.matches("", false) and !entry.matches("Jita", true));
}

test "globMatch treats # as a digit, ? as any character and * as any run" {
    try testing.expect(globMatch("J######", "j123456"));
    try testing.expect(!globMatch("J######", "J12345"));
    try testing.expect(!globMatch("J######", "J12345A"));
    try testing.expect(globMatch("a*b*c", "aXXbYc"));
    try testing.expect(globMatch("a*b", "ab"));
    try testing.expect(globMatch("*", ""));
    try testing.expect(!globMatch("a?c", "ac"));
    try testing.expect(!globMatch("*-C?", "5-CQDA"));
}
