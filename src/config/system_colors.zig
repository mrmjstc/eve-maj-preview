//! Per-system name colour overrides, matched by exact name or wildcard pattern.
const std = @import("std");
const wire = @import("wire.zig");
const glob = @import("../util/glob.zig");

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
            const is_match = if (is_pattern) glob.matches(token, system_name) else std.ascii.eqlIgnoreCase(token, system_name);
            if (is_match) return true;
        }
        return false;
    }
};

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
