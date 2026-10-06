//! The English strings in lang/en.json, for names the window shows from data rather than its own code, e.g. each notification type's label; main thread only.
const std = @import("std");
const log = @import("../../log.zig");

const slog = log.scoped("dialog_knots");

const EN_JSON = @embedFile("../../lang/en.json");

var g_allocator: std.mem.Allocator = undefined;
/// Parsed on first use. Owned; freed in deinit.
var g_strings: ?std.json.Parsed(std.json.Value) = null;
var g_failed: bool = false;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn deinit() void {
    if (g_strings) |*strings| strings.deinit();
    g_strings = null;
    g_failed = false;
}

/// The string for `key`, or `fallback` when it's missing. Borrows from the parsed file until deinit.
pub fn text(key: []const u8, fallback: []const u8) []const u8 {
    const strings = load() orelse return fallback;
    if (strings != .object) return fallback;
    const value = strings.object.get(key) orelse return fallback;
    return if (value == .string) value.string else fallback;
}

/// Formats the key into a stack buffer, e.g. textFmt("notification.{s}.label", .{name}, name).
pub fn textFmt(comptime fmt: []const u8, args: anytype, fallback: []const u8) []const u8 {
    var buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, fmt, args) catch return fallback;
    return text(key, fallback);
}

fn load() ?std.json.Value {
    if (g_strings) |strings| return strings.value;
    if (g_failed) return null;
    g_strings = std.json.parseFromSlice(std.json.Value, g_allocator, EN_JSON, .{}) catch |err| {
        slog.warn("Failed to read the English strings: {}", .{err});
        g_failed = true;
        return null;
    };
    return g_strings.?.value;
}
