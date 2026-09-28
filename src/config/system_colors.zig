//! Per-system name colour overrides, matched by exact name or wildcard pattern.
const std = @import("std");
const wire = @import("wire.zig");

pub const SystemColorConfig = struct {
    /// Comma-separated exact names and `*`/`?`/`#` patterns.
    systemName: []const u8 = "",
    color: u32 = 0,

    pub const Wire = wire.Wire(SystemColorConfig);

    /// `wildcards` selects which kind of token in `systemName` is tried.
    pub fn matches(self: SystemColorConfig, system_name: []const u8, wildcards: bool) bool {
        var tokens = std.mem.tokenizeScalar(u8, self.systemName, ',');
        while (tokens.next()) |raw| {
            const token = std.mem.trim(u8, raw, " \t");
            if (token.len == 0) continue;
            const is_pattern = std.mem.indexOfAny(u8, token, "*?#") != null;
            if (is_pattern != wildcards) continue;
            const hit = if (is_pattern) globMatch(token, system_name) else std.ascii.eqlIgnoreCase(token, system_name);
            if (hit) return true;
        }
        return false;
    }
};

/// Case-insensitive glob: `*` any run, `?` any character, `#` any digit.
fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star_p = p;
            star_t = t;
            p += 1;
        } else if (p < pattern.len and globCharMatches(pattern[p], text[t])) {
            p += 1;
            t += 1;
        } else if (star_p) |sp| {
            p = sp + 1;
            star_t += 1;
            t = star_t;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn globCharMatches(pattern_char: u8, text_char: u8) bool {
    return switch (pattern_char) {
        '?' => true,
        '#' => std.ascii.isDigit(text_char),
        else => std.ascii.toLower(pattern_char) == std.ascii.toLower(text_char),
    };
}
