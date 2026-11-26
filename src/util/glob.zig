//! Case-insensitive wildcard matching for names typed into the settings.
const std = @import("std");

/// `*` any run, `?` any character, `#` any digit.
pub fn matches(pattern: []const u8, text: []const u8) bool {
    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star_pattern_index: ?usize = null;
    var star_text_index: usize = 0;
    while (text_index < text.len) {
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_pattern_index = pattern_index;
            star_text_index = text_index;
            pattern_index += 1;
        } else if (pattern_index < pattern.len and charMatches(pattern[pattern_index], text[text_index])) {
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

fn charMatches(pattern_char: u8, text_char: u8) bool {
    return switch (pattern_char) {
        '?' => true,
        '#' => std.ascii.isDigit(text_char),
        else => std.ascii.toLower(pattern_char) == std.ascii.toLower(text_char),
    };
}

const testing = std.testing;

test "matches treats # as a digit, ? as any character and * as any run" {
    try testing.expect(matches("J######", "j123456"));
    try testing.expect(!matches("J######", "J12345"));
    try testing.expect(!matches("J######", "J12345A"));
    try testing.expect(matches("a*b*c", "aXXbYc"));
    try testing.expect(matches("a*b", "ab"));
    try testing.expect(matches("*", ""));
    try testing.expect(!matches("a?c", "ac"));
    try testing.expect(!matches("*-C?", "5-CQDA"));
}
